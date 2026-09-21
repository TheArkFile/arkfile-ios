// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import BackgroundTasks
import Foundation
import SwiftUI
import Combine
import UserNotifications
import os

/// Bridges system-owned background callbacks into MainActor work while
/// preserving immediate expiration and exactly-once task completion.
enum ArkFileSavedWeatherBackgroundTaskRunner {
    private final class CancellationRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var work: Task<Bool, Never>?

        func attach(_ work: Task<Bool, Never>) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                work.cancel()
                return
            }
            self.work = work
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let work = work
            lock.unlock()
            work?.cancel()
        }

        func clear() {
            lock.lock()
            work = nil
            lock.unlock()
        }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isComplete = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isComplete else { return false }
            isComplete = true
            return true
        }
    }

    static func run(
        installExpirationHandler:
            (@escaping @Sendable () -> Void) -> Void,
        operation: @escaping @MainActor @Sendable () async -> Bool,
        complete: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let cancellation = CancellationRelay()
        let completion = CompletionGate()

        installExpirationHandler {
            cancellation.cancel()
            Task { @MainActor in
                guard completion.claim() else { return }
                cancellation.clear()
                complete(false)
            }
        }

        let work = Task { @MainActor in
            let succeeded = await operation()
            return succeeded && !Task.isCancelled
        }
        cancellation.attach(work)

        Task { @MainActor in
            let succeeded = await work.value && !work.isCancelled
            guard completion.claim() else { return }
            cancellation.clear()
            complete(succeeded)
        }
    }
}

private final class ArkFileSavedWeatherBackgroundTaskBox:
    @unchecked Sendable
{
    let task: BGAppRefreshTask

    init(_ task: BGAppRefreshTask) {
        self.task = task
    }
}

@MainActor
private enum ArkFileSavedWeatherBackgroundRefresh {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.arkfile.ios",
        category: "SavedWeatherBackground"
    )

    static func register() {
        let identifier = ArkFileSavedWeatherController.backgroundTaskIdentifier
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: handleBackgroundRefreshTask
        )
        if !registered {
            logger.error("Saved Weather BGTask registration failed")
        }
        ArkFileWeatherBackgroundDiagnostics.recordRegistration(
            succeeded: registered
        )
        ArkFileSavedWeatherController.shared.installBackgroundSchedulingHooks(
            schedule: schedule(at:),
            cancel: cancel
        )
    }

    private nonisolated static func handleBackgroundRefreshTask(
        _ task: BGTask
    ) {
        // BGTaskScheduler invokes this callback on its own background queue.
        // Keep the boundary nonisolated and bridge only app work to MainActor.
        guard let refreshTask = task as? BGAppRefreshTask else {
            task.setTaskCompleted(success: false)
            return
        }
        let box = ArkFileSavedWeatherBackgroundTaskBox(refreshTask)
        ArkFileSavedWeatherBackgroundTaskRunner.run(
            installExpirationHandler: { handler in
                box.task.expirationHandler = handler
            },
            operation: {
                ArkFileWeatherBackgroundDiagnostics.recordStart()
                guard !Task.isCancelled else { return false }
                let succeeded = await ArkFileSavedWeatherController.shared
                    .performBackgroundRefresh()
                return succeeded
            },
            complete: { succeeded in
                ArkFileWeatherBackgroundDiagnostics.recordCompletion(
                    succeeded: succeeded
                )
                box.task.setTaskCompleted(success: succeeded)
            }
        )
    }

    private static func schedule(at date: Date) {
        let identifier = ArkFileSavedWeatherController.backgroundTaskIdentifier
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: identifier
        )
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = date
        do {
            try BGTaskScheduler.shared.submit(request)
            ArkFileWeatherBackgroundDiagnostics.recordSubmission(
                requestedAt: date,
                errorCode: nil
            )
        } catch {
            let errorCode = (error as NSError).code
            ArkFileWeatherBackgroundDiagnostics.recordSubmission(
                requestedAt: date,
                errorCode: errorCode
            )
            logger.error(
                "Saved Weather BGTask scheduling failed with code \(errorCode, privacy: .public)"
            )
        }
    }

    private static func cancel() {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier:
                ArkFileSavedWeatherController.backgroundTaskIdentifier
        )
        ArkFileWeatherBackgroundDiagnostics.recordCancellation()
    }
}

private actor ArkFileDataProtectionMigrationCoordinator {
    static let shared = ArkFileDataProtectionMigrationCoordinator()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.arkfile.ios",
        category: "DataProtectionMigration"
    )

    func migrateApplicationSupportIfNeeded() {
        let fileManager = FileManager()
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            logger.error(
                "Application Support could not be resolved; migration will retry"
            )
            return
        }
        guard let result =
            ArkFileDataProtection.migrateApplicationSupportIfNeeded(
                at: applicationSupport,
                fileManager: fileManager
            )
        else {
            return
        }

        if result.isComplete {
            logger.info(
                "Application Support migration completed: visited \(result.visitedItemCount, privacy: .public), protected \(result.protectedItemCount, privacy: .public)"
            )
        } else {
            logger.error(
                "Application Support migration incomplete and will retry: apply failures \(result.failedItemCount, privacy: .public), enumeration errors \(result.enumerationErrorCount, privacy: .public), attribute errors \(result.attributeErrorCount, privacy: .public), unprotected items \(result.unprotectedItemCount, privacy: .public)"
            )
        }
    }
}

@main
struct Kiwix: App {
    
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = LibraryViewModel()
    @StateObject private var selection = SelectedZimFileViewModel()
    @StateObject private var navigation = NavigationViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var colorSchemeStore = UserColorSchemeStore()
    @StateObject private var webContentPolicy = WebContentPolicyGatekeeper()
    @State private var pendingOpenURLs = PendingWebContentOpenURLs()

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.arguments.contains("testing")
    }

    private static func scheduleApplicationSupportProtectionMigration() {
        Task.detached(priority: .utility) {
            await ArkFileDataProtectionMigrationCoordinator.shared
                .migrateApplicationSupportIfNeeded()
        }
    }

#if DEBUG
    /// A narrowly-scoped Debug-only UI-test route for exercising the real
    /// Complete download-selection surface without starting the normal app,
    /// StoreKit, catalog networking, or a content transfer.
    private static var showsCompleteSelectionUITestHarness: Bool {
        isRunningTests
            && ProcessInfo.processInfo.arguments.contains(
                "arkfile-ui-test-complete-management-selection"
            )
    }
#endif
    
    init() {
        // Complete or roll back any interrupted compatibility-group switch
        // before local-read authority or CoreKiwix observes the active root.
        ArkFileContentActivationCoordinator.recoverPendingActivationIfNeeded()
        // Establish deterministic local-read truth before any StoreKit task can
        // reconcile acquisition state. Purchased and committed offline content
        // must remain usable even when commerce services are unavailable.
        ArkFileInstalledContentAccess.bootstrap()
        if !Self.isRunningTests {
            ArkFileAdMeasurement.shared.start(
                hasReadableContent: ArkFileContentPackInstaller
                    .managedContentRootWithAnyReadableContentIfAvailable() != nil
            )
        }
        // Upgrade existing content, partial downloads, and Core Data sidecars
        // in the app's private Application Support tree. The versioned pass
        // records completion only after every item verifies successfully.
        Self.scheduleApplicationSupportProtectionMigration()
        Task(priority: .utility) {
            await Diagnostics.start()
        }
        UNUserNotificationCenter.current().delegate = appDelegate
        if !Self.isRunningTests {
            Task { @MainActor in
                ArkFileLitePurchaseManager.shared.startObservingTransactions()
                await ArkFileLitePurchaseManager.shared.reconcileLiteEntitlementOnLaunchOrForeground()
            }
        }
        // MARK: - migrations
        if !Self.isRunningTests {
            _ = MigrationService().migrateAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            applicationRoot
                .tint(Color.arkTeal)
                .environment(\.managedObjectContext, Database.shared.viewContext)
                .environmentObject(library)
                .environmentObject(selection)
                .environmentObject(navigation)
                .environmentObject(colorSchemeStore)
                .modifier(AlertHandler())
                .modifier(QuestionHandler())
                .modifier(OpenFileHandler())
                .modifier(FileExportHandler())
                .modifier(SaveContentHandler())
                .onChange(of: scenePhase) { _, newValue in
                    guard !Self.isRunningTests else { return }
                    switch newValue {
                    case .inactive:
                        ArkFileAdMeasurement.shared.appWillResignActive()
                        try? Database.shared.viewContext.save()
                    case .active:
                        ArkFileAdMeasurement.shared.appDidBecomeActive()
                        // A background launch can occur before protected files
                        // are readable. Retry any journal recovery before the
                        // foreground access refresh; unavailable protected data
                        // leaves both content and metadata untouched for the
                        // next active/protected-data opportunity.
                        Self.scheduleApplicationSupportProtectionMigration()
                        ArkFileContentActivationCoordinator.recoverPendingActivationIfNeeded()
                        ArkFileInstalledContentAccess.reloadForForeground()
                        Task {
                            await ArkFileOfflineReadinessReminder.shared.appDidBecomeActive()
                            await ArkFileLitePurchaseManager.shared.reconcileLiteEntitlementOnLaunchOrForeground()
                            ArkFileContentPackInstaller.shared.resumeInterruptedInstallIfPossible()
                            await ArkFileEssentialsUpdateChecker.shared.checkOnForegroundIfNeeded()
                        }
                        if FeatureFlags.savedWeather {
                            Task {
                                await ArkFileSavedWeatherController.shared
                                    .appDidBecomeActive()
                            }
                        }
                        if FeatureFlags.hasLibrary {
                            Task {
                                let revalidation = await LibraryOperations.reValidate()
                                if revalidation.permitsMissingTabDeletion,
                                   !ArkFileContentActivationCoordinator.hasBlockedRecovery {
                                    await navigation.deleteTabsWithMissingZimFiles()
                                }
                                if FeatureFlags.hasCatalog {
                                    await library.start(isUserInitiated: false)
                                }
                                await Hotspot.shared.appDidBecomeActive()
                            }
                        } else {
                            Task {
                                await Hotspot.shared.appDidBecomeActive()
                            }
                        }
                    case .background:
                        ArkFileAdMeasurement.shared.appWillResignActive()
                        Task {
                            await HotspotObservable.shared.stopForAppBackground()
                        }
                        ArkFileEssentialsUpdateChecker.scheduleBackgroundRefresh()
                        if FeatureFlags.savedWeather {
                            ArkFileSavedWeatherController.shared
                                .appDidEnterBackground()
                        }
                    @unknown default:
                        break
                    }
                }
                .onChange(of: webContentPolicy.state) { _, state in
                    guard state == .ready else {
                        return
                    }
                    navigation.observeOpeningFiles()
                    pendingOpenURLs.drain().forEach(handleOpenURL)
                }
                .onOpenURL { url in
                    guard webContentPolicy.isReady else {
                        pendingOpenURLs.enqueue(url)
                        return
                    }
                    navigation.observeOpeningFiles()
                    handleOpenURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else {
                        return
                    }
                    guard webContentPolicy.isReady else {
                        pendingOpenURLs.enqueue(url)
                        return
                    }
                    navigation.observeOpeningFiles()
                    handleOpenURL(url)
                }
                .onAppear {
                    colorSchemeStore.update()
                }
                .modifier(DonationViewModifier())
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                NavigationCommands(goBack: {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }, goForward: {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                })
            }
            CommandGroup(replacing: .textFormatting) {
                PageZoomCommands()
            }
        }
    }

    @ViewBuilder
    private var applicationRoot: some View {
#if DEBUG
        if Self.showsCompleteSelectionUITestHarness {
            completeSelectionUITestHarness
        } else {
            standardApplicationRoot
        }
#else
        standardApplicationRoot
#endif
    }

    private var standardApplicationRoot: some View {
        WebContentPolicyGate(gatekeeper: webContentPolicy) {
            RootViewiOS()
                .task {
                    await startApplication()
                }
        }
        .ignoresSafeArea()
    }

#if DEBUG
    private var completeSelectionUITestHarness: some View {
        NavigationStack {
            ArkFileEssentialsSelectionReviewView(
                tier: .complete,
                confirmTitle: "Download Selected",
                managementMode: true,
                purpose: .manageDownloads,
                initiallyExcluded: nil,
                startsWithSavedSelection: !ProcessInfo.processInfo.arguments.contains("arkfile-ui-test-empty-download-selection"),
                onConfirm: { _ in },
                onCancel: {}
            )
        }
        .accessibilityIdentifier(
            "arkfile_ui_test_complete_management_selection"
        )
    }
#endif

    private func startApplication() async {
        // Install synchronously before any startup operation can publish a ZIM
        // URL. Repeated calls from the adaptive root are harmless.
        navigation.observeOpeningFiles()
        switch AppType.current {
        case .kiwix:
            await LibraryOperations.reValidate()
            if !DeepLinkService.shared.isRunning() {
                navigation.navigateToMostRecentTab()
            }
            LibraryOperations.applyFileBackupSetting()
            DownloadService.shared.restartHeartbeatIfNeeded()
            await ArkFileOfflineReadinessReminder.shared.appDidBecomeActive()
            if FeatureFlags.hasCatalog {
                await library.start(isUserInitiated: false)
            }
        case let .custom(zimFileURL):
            await LibraryOperations.open(url: zimFileURL)
            await ZimMigration.forCustomApps()
            navigation.navigateToMostRecentTab()
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url.pathExtension.lowercased() == "gpx" {
            ArkFileMapGPXRouter.dispatch(url)
        } else if url.isFileURL {
            let deepLinkId = UUID()
            DeepLinkService.shared.startFor(uuid: deepLinkId)
            NotificationCenter.openFiles([url], context: .file(deepLinkId: deepLinkId))
        } else if let mapLink = ArkFileMapLocationLink.parse(url) {
            ArkFileMapLocationRouter.dispatch(mapLink)
        } else if url.isZIMURL {
            NotificationCenter.openURL(url)
        }
    }

    private class AppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {

        func application(_ application: UIApplication,
                         didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
            guard !ProcessInfo.processInfo.arguments.contains("testing") else {
                return true
            }
            _ = ArkFileContentBackgroundDownloadService.shared
            ArkFileEssentialsUpdateChecker.registerBackgroundRefreshTask()
            if FeatureFlags.savedWeather {
                ArkFileSavedWeatherBackgroundRefresh.register()
            }
            return true
        }
        
        /// Storing background download completion handler sent to application delegate
        func application(_ application: UIApplication,
                         handleEventsForBackgroundURLSession identifier: String,
                         completionHandler: @escaping () -> Void) {
            if identifier == ArkFileContentBackgroundDownloadService.sessionIdentifier {
                ArkFileContentBackgroundDownloadService.shared.backgroundCompletionHandler = completionHandler
            } else {
                DownloadService.shared.sessionDelegate.backgroundCompletionHandler = completionHandler
            }
        }

        /// Handling file download complete notification
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            if response.notification.request.identifier == ArkFileOfflineReadinessReminder.notificationIdentifier {
                ArkFileOfflineReadinessReminder.shared.recordReminderNotificationOpened()
                // Buffer the route so a cold launch cannot post into the void
                // before either SwiftUI home surface is ready to consume it.
                ArkFileOfflineReadinessCoordinator.shared.requestFromReminderNotification()
                completionHandler()
                return
            }
            Task { @MainActor in
                let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
                if let zimFileID = UUID(uuidString: response.notification.request.identifier),
                   let mainPageURL = await ZimFileService.shared.getMainPageURL(zimFileID: zimFileID) {
                    NotificationCenter.openURL(
                        mainPageURL,
                        inNewTab: true,
                        continuing: readerOpenIntent
                    )
                }
                completionHandler()
            }
        }

        /// Purge some cached browser view models when receiving memory warning
        func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
            BrowserViewModel.purgeCache()
            Task { @ZimActor in
                ZimFileService.shared.purgeUnpinnedArchives()
            }
        }
    }
}

#endif
