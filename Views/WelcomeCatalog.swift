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

import SwiftUI
import Combine
import Defaults

#if os(iOS)
import UIKit
#endif

enum ArkFileEssentialsDownloadAction: Equatable, Sendable {
    case install
    case restore
    case cellularOverride
    case completeCellularOverride

    var tier: ArkFileContentTier {
        self == .completeCellularOverride ? .complete : .lite
    }

    var usesCellularOverride: Bool {
        self == .cellularOverride || self == .completeCellularOverride
    }
}

enum ArkFileEssentialsDownloadCopy {
    static let warningTitle = "Before Downloading Essentials"
    private static let fallbackEssentialsContentBytes: Int64 = 10_800_000_000

    static func warningMessage() async -> String {
        let estimate = await storageEstimate()
        let contentSize = formattedBytes(estimate.contentBytes)
        let requiredSize = formattedBytes(estimate.requiredAvailableBytes)
        let storageCopy: String
        if let availableBytes = estimate.availableBytes {
            let availableSize = formattedBytes(availableBytes)
            if estimate.hasEnoughReportedStorage == true {
                storageCopy = "This device currently reports \(availableSize) available. ArkFile will re-check storage before each large file."
            } else {
                storageCopy = "This device currently reports only \(availableSize) available. ArkFile will stop before downloading if the exact pack manifest still needs more space."
            }
        } else {
            storageCopy = "ArkFile cannot confirm available storage on this device right now. It will stop before downloading if iOS still cannot report enough space."
        }

        return """
        Essentials is about \(contentSize). ArkFile should have about \(requiredSize) free during installation so it can hold the remaining content, the current download chunk, and a safety buffer. \(storageCopy) Connect to Wi-Fi, plug in your device, and keep ArkFile open for the most reliable progress.
        """
    }

    static func warningTitle(for tier: ArkFileContentTier) -> String {
        tier == .complete ? "Before Downloading Complete" : warningTitle
    }

    static func cellularWarningMessage(
        for tier: ArkFileContentTier = .lite,
        estimatedContentBytes: Int64? = nil
    ) async -> String {
        let contentBytes: Int64
        if let estimatedContentBytes {
            contentBytes = estimatedContentBytes
        } else {
            contentBytes = await storageEstimate(for: tier).contentBytes
        }
        let contentSize = formattedBytes(contentBytes)
        let sizeSubject = tier == .complete
            ? "Your selected ArkFile Complete titles are"
            : "ArkFile Essentials is"
        return """
        \(sizeSubject) about \(contentSize). Downloading on cellular, hotspot, or Low Data Mode can use a large amount of data and may incur charges. Continue only if you understand the data use and want to download now.
        """
    }
    static let removalTitle = "Remove Essentials?"
    static let removalMessage = """
    This removes downloaded ArkFile content from this device. Your Apple Account purchase can be restored, but a title marked “No longer distributed by ArkFile” cannot be downloaded again after removal. Review those titles in Manage Downloads before continuing.
    """

    private static func storageEstimate() async -> ArkFileContentStorageEstimate {
        await storageEstimate(for: .lite)
    }

    private static func storageEstimate(for tier: ArkFileContentTier) async -> ArkFileContentStorageEstimate {
        await Task.detached(priority: .utility) {
            let catalogBytes = (try? ArkFileContentCatalog.loadBundled().estimatedBytes(for: tier))
                .flatMap { $0 > 0 ? $0 : nil }
                ?? fallbackEssentialsContentBytes
            let contentBytes = tier == .lite
                ? max(catalogBytes, fallbackEssentialsContentBytes)
                : catalogBytes
            let availableBytes = try? ArkFileContentStoragePreflight.availableCapacityForDownload()
            return ArkFileContentStoragePreflight.storageEstimate(
                contentBytes: contentBytes,
                maximumTransientBytes: ArkFileContentBackgroundDownloadService.maximumTransientDownloadBytes,
                availableBytes: availableBytes
            )
        }.value
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

enum ArkFileDownloadRuntimeGuard {
    @MainActor
    static func keepScreenAwake(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }
}

enum ArkFileAdaptiveCardGrid {
    enum Mode: Equatable {
        case singleFlexible
        case adaptive(minimum: CGFloat)
    }

    static func mode(
        isAccessibilitySize: Bool,
        standardMinimum: CGFloat
    ) -> Mode {
        isAccessibilitySize
            ? .singleFlexible
            : .adaptive(minimum: standardMinimum)
    }

    static func columns(
        isAccessibilitySize: Bool,
        standardMinimum: CGFloat,
        spacing: CGFloat
    ) -> [GridItem] {
        switch mode(
            isAccessibilitySize: isAccessibilitySize,
            standardMinimum: standardMinimum
        ) {
        case .singleFlexible:
            return [GridItem(.flexible(minimum: 0), spacing: spacing)]
        case .adaptive(let minimum):
            return [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
        }
    }
}

enum ArkFileEmergencyChipGrid {
    static let columnCount = 3
    static let chipSpacing: CGFloat = 8

    static var columns: [GridItem] {
        columns(isAccessibilitySize: false)
    }

    static func columns(isAccessibilitySize: Bool) -> [GridItem] {
        let count = columnCount(isAccessibilitySize: isAccessibilitySize)
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: chipSpacing),
            count: count
        )
    }

    static func columnCount(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 1 : columnCount
    }

    static func rowCounts(
        itemCount: Int,
        isAccessibilitySize: Bool = false
    ) -> [Int] {
        guard itemCount > 0 else { return [] }
        let count = columnCount(isAccessibilitySize: isAccessibilitySize)
        return stride(from: 0, to: itemCount, by: count).map { index in
            min(count, itemCount - index)
        }
    }
}

/// Displays the Logo and onboarding actions.
/// Used on new tab, when no ZIM files are available
enum ArkFileSceneRoute: Equatable, Sendable {
    case library
    case saved
    case map
    case savedWeather
    case preparedness(selectedView: String?)
    case survivalGuide(sectionID: String?, blockID: String?)
    case localSharing
    case downloads(relativePath: String?)
}

struct ArkFileMapPurchaseContext: Equatable {
    let relativePath: String?
    var showDownloadsOnReturn: Bool = true
}

struct WelcomeCatalog: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var library: LibraryViewModel
    @StateObject private var liteInstaller = ArkFileContentPackInstaller.shared
    @StateObject private var accountSession = ArkFileAccountSession.shared
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var locallyShowsPackComparison = false
    @State private var localMapPurchaseContext: ArkFileMapPurchaseContext?
    let viewState: WelcomeViewState
    let showSettings: () -> Void
    let usesParentSettingsToolbar: Bool
    let navigateScene: ((ArkFileSceneRoute) -> Void)?
    let openSceneContent:
        ((ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void)?
    let toggleSidebar: (() -> Void)?
    let packComparisonPresentation: Binding<Bool>?
    let mapPurchaseContext: Binding<ArkFileMapPurchaseContext?>?
    let canPresentInstallerAlerts: @MainActor @Sendable () -> Bool

    init(
        viewState: WelcomeViewState,
        showSettings: @escaping () -> Void = {},
        usesParentSettingsToolbar: Bool = false,
        navigateScene: ((ArkFileSceneRoute) -> Void)? = nil,
        openSceneContent:
            ((ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void)? = nil,
        toggleSidebar: (() -> Void)? = nil,
        packComparisonPresentation: Binding<Bool>? = nil,
        mapPurchaseContext: Binding<ArkFileMapPurchaseContext?>? = nil,
        canPresentInstallerAlerts: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.viewState = viewState
        self.showSettings = showSettings
        self.usesParentSettingsToolbar = usesParentSettingsToolbar
        self.navigateScene = navigateScene
        self.openSceneContent = openSceneContent
        self.toggleSidebar = toggleSidebar
        self.packComparisonPresentation = packComparisonPresentation
        self.mapPurchaseContext = mapPurchaseContext
        self.canPresentInstallerAlerts = canPresentInstallerAlerts
    }

    var body: some View {
        if !FeatureFlags.hasCatalog {
#if os(iOS)
            ArkFileHomeWelcome(
                liteInstaller: liteInstaller,
                accountSession: accountSession,
                accountEmail: $accountEmail,
                accountPassword: $accountPassword,
                showSettings: showSettings,
                showsSettingsButton: !usesParentSettingsToolbar,
                navigateScene: navigateScene,
                openSceneContent: openSceneContent,
                toggleSidebar: toggleSidebar,
                canPresentInstallerAlerts: canPresentInstallerAlerts,
                showPackComparison:
                    packComparisonPresentation
                    ?? $locallyShowsPackComparison,
                mapPurchaseContext: mapPurchaseContext ?? $localMapPurchaseContext
            )
#else
            legacyWelcome
#endif
        } else {
            legacyWelcome
        }
    }

    private var legacyWelcome: some View {
        ZStack {
            LogoView()
            welcomeContent
        }.ignoresSafeArea()
    }

    private var welcomeContent: some View {
        GeometryReader { geometry in
            let logoCalc = LogoCalc(
                geometry: geometry.size,
                originalImageSize: Brand.loadingLogoSize,
                horizontal: horizontalSizeClass,
                vertical: verticalSizeClass
            )
            actions
                .position(
                    x: geometry.size.width * 0.5,
                    y: logoCalc.buttonCenterY)
                .frame(maxWidth: logoCalc.buttonsWidth)
            if viewState == .error {
                Text(LocalString.library_refresh_error_retrieve_description)
                    .foregroundColor(.red)
                    .position(
                        x: geometry.size.width * 0.5,
                        y: logoCalc.errorTextCenterY
                    )
            }
        }
    }

    /// Onboarding actions, open a zim file or refetch catalog
    private var actions: some View {
        if verticalSizeClass == .compact { // iPhone landscape
            AnyView(HStack {
                openFileButton
                accountSection
                catalogOrLiteButton
                restoreLiteButton
            })
        } else {
            AnyView(VStack {
                openFileButton
                accountSection
                catalogOrLiteButton
                restoreLiteButton
            })
        }
    }

    private var openFileButton: some View {
        OpenFileButton(context: .welcomeScreen) {
            HStack {
                Spacer()
                Text(LocalString.welcome_actions_open_file)
                Spacer()
            }.padding(6)
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var accountSection: some View {
        if FeatureFlags.arkFileUnifiedAccountUI && !FeatureFlags.hasCatalog {
            if Brand.hasDeveloperContentAuthToken {
                VStack(spacing: 6) {
                    Text("Developer content token enabled.")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Local fixture downloads can run without account sign-in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(6)
            } else if accountSession.isSignedIn {
                VStack(spacing: 6) {
                    Text(accountSession.user?.email ?? LocalString.arkfile_account_status_signed_in)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(accountSession.hasPurchased
                         ? LocalString.arkfile_account_status_unlocked
                         : LocalString.arkfile_account_status_purchase_needed)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Button(LocalString.arkfile_account_button_sign_out) {
                        accountSession.signOut()
                        liteInstaller.clearTransientPurchaseStatus()
                    }
                    .font(.caption)
                }
                .padding(6)
            } else {
                VStack(spacing: 6) {
                    Text(LocalString.arkfile_account_prompt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    TextField(LocalString.arkfile_account_field_email, text: $accountEmail)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                    SecureField(LocalString.arkfile_account_field_password, text: $accountPassword)
                        .textContentType(.password)
                    Button {
                        Task {
                            await accountSession.signIn(email: accountEmail, password: accountPassword)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text(accountSession.isBusy
                                 ? LocalString.arkfile_account_button_signing_in
                                 : LocalString.arkfile_account_button_sign_in)
                            Spacer()
                        }
                    }
                    .disabled(accountSession.isBusy || accountEmail.isEmpty || accountPassword.isEmpty)
                    if let error = accountSession.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(6)
            }
        }
    }

    @ViewBuilder
    private var catalogOrLiteButton: some View {
        Button {
            if FeatureFlags.hasCatalog {
                Task { [weak library] in
                    await library?.start(isUserInitiated: true)
                }
            } else {
                liteInstaller.installLite()
            }
        } label: {
            VStack(spacing: 4) {
                HStack {
                    Spacer()
                    if FeatureFlags.hasCatalog {
                        if viewState == .loading {
                            Text(LocalString.welcome_button_status_fetching_catalog_text)
                        } else {
                            Text(LocalString.welcome_button_status_fetch_catalog_text)
                        }
                    } else {
                        Text(liteInstaller.liteButtonTitle)
                    }
                    Spacer()
                }
                if !FeatureFlags.hasCatalog,
                   (accountSession.isSignedIn || liteInstaller.state.phase.isBusy),
                   let statusText = liteInstaller.statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                if !FeatureFlags.hasCatalog, let progress = liteInstaller.state.progressFraction,
                   liteInstaller.state.phase.isBusy {
                    ProgressView(value: progress)
                } else {
                    EmptyView()
                }
            }.padding(6)
        }
        .disabled(FeatureFlags.hasCatalog ? viewState == .loading : liteInstaller.isBusy)
        .font(.subheadline)
        .buttonStyle(.bordered)

        if !FeatureFlags.hasCatalog, liteInstaller.canPauseLiteDownload {
            Button(role: .cancel) {
                liteInstaller.cancelLiteDownload()
            } label: {
                HStack {
                    Spacer()
                    Label("Pause Download", systemImage: "pause.circle")
                    Spacer()
                }.padding(6)
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var restoreLiteButton: some View {
        if !FeatureFlags.hasCatalog, liteInstaller.canRestoreLite {
            Button {
                liteInstaller.restoreLite()
            } label: {
                HStack {
                    Spacer()
                    Text(LocalString.arkfile_lite_button_restore)
                    Spacer()
                }.padding(6)
            }
            .disabled(liteInstaller.isBusy)
            .font(.subheadline)
            .buttonStyle(.bordered)
        }
    }
}

#if os(iOS)
private struct ArkFileHomeWelcome: View {
    @ObservedObject var liteInstaller: ArkFileContentPackInstaller
    @ObservedObject var accountSession: ArkFileAccountSession
    @Binding var accountEmail: String
    @Binding var accountPassword: String
    let showSettings: () -> Void
    let showsSettingsButton: Bool
    let navigateScene: ((ArkFileSceneRoute) -> Void)?
    let openSceneContent:
        ((ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void)?
    let toggleSidebar: (() -> Void)?
    let canPresentInstallerAlerts: @MainActor @Sendable () -> Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var purchaseManager = ArkFileLitePurchaseManager.shared
    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared
    @StateObject private var contentFavorites = ArkFileContentFavorites.shared
    @StateObject private var contentBookmarks = ArkFileContentBookmarks.shared
    @StateObject private var updateChecker = ArkFileEssentialsUpdateChecker.shared
    @StateObject private var readingHistory = ArkFileReadingHistory.shared
    @ObservedObject private var readinessChecker = ArkFileOfflineReadinessChecker.shared
    @ObservedObject private var readinessCoordinator = ArkFileOfflineReadinessCoordinator.shared
    @State private var showEmergencyNumbers = false
    @State private var sheet: ArkFileHomeSheet?
    @State private var selectedPreviewItems: [String: ArkFileLibraryContentItem] = [:]
    @State private var selectedBookmark: ArkFileContentBookmark?
    @State private var lockedPreviewItem: ArkFileLibraryContentItem?
    @State private var activeReaderDestination: ArkFileContentReaderDestination?
    @State private var openingPreviewItemID: String?
    @State private var previewOpenError: String?
    @State private var pendingEssentialsDownloadAction: ArkFileEssentialsDownloadAction?
    @State private var showEssentialsDownloadWarning = false
    @State private var essentialsDownloadWarningMessage = ""
    @State private var showCancelCurrentDownloadConfirmation = false
    @State private var libraryScrollRequest = 0
    @State private var isShowingOnboarding = false
    @State private var pendingOnboardingDestination: ArkFileOnboardingDestination?
    @Binding var showPackComparison: Bool
    @Binding var mapPurchaseContext: ArkFileMapPurchaseContext?
    @State private var preservesMapContextAfterComparison = false
    @State private var isAwaitingRestoreOutcome = false
    @State private var pendingPackComparisonTierAfterRestore: ArkFileContentTier?
    @State private var showEssentialsSelectionReview = false
    @State private var showCompleteSelectionReview = false
    @State private var showEssentialsManage = false
    @State private var contentDownloadsTargetRelativePath: String?
    @State private var contentDownloadsGroup: ArkFileContentDisplayGroup?
    @State private var contentCatalog: ArkFileContentCatalog?
    @State private var homeLibraryQuery = ""
    @State private var homeLibraryFilter: ArkFileLibraryFilter = .allContent
    @FocusState private var homeLibrarySearchFocused: Bool

    private static let libraryContentSectionID = "arkfile-home-library-content"
    private static let savedContentSectionID = "arkfile-home-saved-content"
    private static let includedToolsSectionID = "arkfile-home-included-tools"

    private var usesSingleColumnLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var blocksForAppleAccountCheck: Bool {
        ArkFilePurchasePresentation.shouldBlockForAppleAccountCheck(
            isCheckingApplePurchases: liteInstaller.isCheckingApplePurchases,
            hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasLocalPaidContent: hasLocalPaidContent
        )
    }

    private var hasLocalPaidContent: Bool {
        liteInstaller.hasInstalledOrPartialContent
            || contentLibrary.allLibraryItems.contains { item in
                item.isInstalled
                    && !item.isBundledSampleAsset
                    && item.requiredTier.isIOSInstallable
            }
    }

    private var toolColumns: [GridItem] {
        ArkFileAdaptiveCardGrid.columns(
            isAccessibilitySize: usesSingleColumnLayout,
            standardMinimum: 150,
            spacing: 10
        )
    }

    private var previewColumns: [GridItem] {
        ArkFileAdaptiveCardGrid.columns(
            isAccessibilitySize: usesSingleColumnLayout,
            standardMinimum: 300,
            spacing: 12
        )
    }

    @MainActor
    private func loadHome() async {
        await contentLibrary.refresh()
        contentCatalog = await Task.detached(priority: .utility) {
            try? ArkFileContentCatalog.loadBundled()
        }.value
        prunePreviewSelections()
        updateDownloadRuntimeGuard()
        await readinessChecker.refreshCachedState()
        if FeatureFlags.arkFileUnifiedAccountUI {
            await accountSession.refreshIfSignedIn()
        }
        if ArkFileMapLocationRouter.hasPendingLink || ArkFileMapGPXRouter.hasPendingImport {
            isShowingOnboarding = false
            presentSceneRoute(.map, fallback: .map)
        } else {
            let arguments = ProcessInfo.processInfo.arguments
            let forceOnboarding = arguments.contains("arkfile-ui-test-force-onboarding")
            if (
                !UserDefaults.standard.bool(forKey: ArkFileOnboardingView.completedDefaultsKey)
                    || forceOnboarding
            ) && (!arguments.contains("testing") || forceOnboarding) {
                isShowingOnboarding = true
            }
        }
        presentReadinessRequestIfNeeded()
    }

    private var packComparisonSheet: some View {
        NavigationStack {
            ArkFilePackComparisonView(
                catalog: contentCatalog,
                hasEssentialsAccess: hasEssentialsAccess,
                hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
                hasLocalPaidContent: hasLocalPaidContent,
                hasCurrentEssentialsStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .lite),
                hasCurrentCompleteStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .complete),
                hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
                essentialsInstalledCount: packMetrics.installedEssentialsTitleCount,
                completeInstalledCount: completeOwnershipMetrics.installedTitleSlots,
                completeInstalledMapCount: completeOwnershipMetrics.installedMapCount,
                isBusy: liteInstaller.isBusy,
                isCheckingApplePurchases: liteInstaller.isCheckingApplePurchases,
                chooseEssentials: { handlePackComparisonAction(tier: .lite) },
                chooseComplete: { currentEssentialsProof in
                    handlePackComparisonAction(
                        tier: .complete,
                        currentEssentialsProof: currentEssentialsProof
                    )
                },
                manageDownloads: closeComparisonAndShowDownloads,
                restorePurchases: closeComparisonAndRestore,
                initialTier: mapPurchaseContext?.relativePath != nil ? .complete : nil
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showPackComparison = false
                    }
                }
            }
        }
        .tint(Color.arkInteractiveForeground)
    }

    private var onboardingSheet: some View {
        ArkFileOnboardingView { destination in
            pendingOnboardingDestination = destination
            isShowingOnboarding = false
        }
    }

    private func onboardingDismissed() {
        UserDefaults.standard.set(true, forKey: ArkFileOnboardingView.completedDefaultsKey)
        handleCompletedOnboardingDestination()
    }

    private var essentialsSelectionSheet: some View {
        NavigationStack {
            ArkFileEssentialsSelectionReviewView(
                tier: .lite,
                confirmTitle: "Start Download",
                managementMode: liteInstaller.hasSavedLiteAccess,
                purpose: liteInstaller.hasSavedLiteAccess ? .downloadOwnedPack : .purchase,
                initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .lite),
                onConfirm: confirmEssentialsSelection,
                onCancel: cancelEssentialsSelection
            )
        }
    }

    private var completeSelectionSheet: some View {
        NavigationStack {
            ArkFileEssentialsSelectionReviewView(
                tier: .complete,
                confirmTitle: "Download Selected",
                managementMode: liteInstaller.hasSavedCompleteAccess,
                purpose: completeSelectionPurpose,
                initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .complete),
                onConfirm: confirmCompleteSelection,
                onCancel: cancelCompleteSelection
            )
        }
    }

    private var coreContent: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 18)
                .padding(.vertical, 10)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .background(Color.arkAppBackground)
                .zIndex(1)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if homePresentation.showsAcquisitionIntroduction {
                            acquisitionIntroduction(scrollProxy: scrollProxy)
                        }
                        if FeatureFlags.savedWeather {
                            ArkFileSavedWeatherHomeCard {
                                presentSceneRoute(.savedWeather, fallback: .savedWeather)
                            }
                        }
                        continueReadingSection
                        emergencySection
                        if !homePresentation.showsAcquisitionIntroduction {
                            personalLibrarySummary
                        }
                        contentPreview
                        newContentSection
                        freeTools(scrollProxy: scrollProxy)
                            .id(Self.includedToolsSectionID)
                        savedPreview
                        offlineReadinessSection
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 18)
                    .padding(.top, 12)
                    .padding(.bottom, 42)
                    .frame(maxWidth: 1180, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: libraryScrollRequest) { _, _ in
                    scrollToLibrary(using: scrollProxy)
                }
            }
        }
        .background(Color.arkAppBackground.ignoresSafeArea())
        .overlay(alignment: .top) {
            ArkFileHomeStatusBarShield()
        }
        .tint(Color.arkPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 112)
                .allowsHitTesting(false)
        }
        .task {
            await loadHome()
        }
        .sheet(isPresented: $isShowingOnboarding, onDismiss: onboardingDismissed) {
            onboardingSheet
        }
        .sheet(isPresented: $showPackComparison, onDismiss: comparisonDismissed) {
            packComparisonSheet
        }
        .sheet(isPresented: $showEssentialsSelectionReview) {
            essentialsSelectionSheet
        }
        .sheet(isPresented: $showCompleteSelectionReview) {
            completeSelectionSheet
        }
        .sheet(isPresented: $showEmergencyNumbers) {
            NavigationStack {
                ArkFileEmergencyNumbersView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showEmergencyNumbers = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEssentialsManage) {
            NavigationStack {
                ArkFileContentBrowserView(
                    openItem: handleBrowserOpen,
                    initialTargetRelativePath: contentDownloadsTargetRelativePath,
                    initialGroup: contentDownloadsGroup
                )
                .id(contentDownloadsTargetRelativePath ?? contentDownloadsGroup?.id ?? "all")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showEssentialsManage = false
                                contentDownloadsTargetRelativePath = nil
                                contentDownloadsGroup = nil
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
        }
    }

    var body: some View {
        coreContent
        .onChange(of: scenePhase) { _, _ in
            updateDownloadRuntimeGuard()
        }
        .onChange(of: liteInstaller.state.phase) { _, newPhase in
            updateDownloadRuntimeGuard()
            Task {
                await readinessChecker.refreshCachedState()
            }
            if newPhase == .installed {
                updateChecker.revalidateLocally()
            }
        }
        .onChange(of: readinessCoordinator.presentationRequest?.id) { _, _ in
            presentReadinessRequestIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .arkFileOnboardingDestination)
        ) { notification in
            guard let destination = notification.object as? ArkFileOnboardingDestination else {
                return
            }
            pendingOnboardingDestination = destination
            handleCompletedOnboardingDestination()
        }
        .onChange(of: contentLibrary.libraryCategories) { _, _ in
            prunePreviewSelections()
        }
        .onDisappear {
            ArkFileDownloadRuntimeGuard.keepScreenAwake(false)
        }
        .alert(
            ArkFileEssentialsDownloadCopy.warningTitle(
                for: pendingEssentialsDownloadAction?.tier ?? .lite
            ),
            isPresented: $showEssentialsDownloadWarning
        ) {
            Button("Not Now", role: .cancel) {
                pendingEssentialsDownloadAction = nil
                essentialsDownloadWarningMessage = ""
            }
            Button(liteInstaller.warningConfirmationTitle(
                for: pendingEssentialsDownloadAction?.tier ?? .lite
            )) {
                startPendingEssentialsDownload()
            }
        } message: {
            Text(essentialsDownloadWarningMessage)
        }
        .arkFileLockedContentPrompt(
            item: $lockedPreviewItem,
            resolutionInput: { lockedResolutionInput },
            primaryAction: { _, tier in
                handleLockedPrimaryAction(tier: tier)
            },
            restoreAction: { route in
                handleLockedRestoreAction(route)
            },
            downloadOnlyAction: { item, tier in
                liteInstaller.includeItemAndDownload(key: item.id, tier: tier)
            }
        )
        .arkFileRestoreOutcomePrompt(
            installer: liteInstaller,
            isAwaitingOutcome: $isAwaitingRestoreOutcome,
            chooseDownloads: chooseDownloadsAfterRestore,
            successActionTitle: restoreSuccessActionTitle,
            cancel: {
                pendingPackComparisonTierAfterRestore = nil
                mapPurchaseContext = nil
            }
        )
        .alert(
            "Purchase Status",
            isPresented: ArkFileInstallerAlertPresentation.binding(
                message: { liteInstaller.purchaseHelpMessage },
                isOwner: {
                    canPresentInstallerAlerts()
                        && !showEssentialsManage
                        && sheet?.ownsInstallerAlerts != true
                },
                dismiss: { liteInstaller.dismissPurchaseHelpMessage() }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissPurchaseHelpMessage()
            }
        } message: {
            Text(liteInstaller.purchaseHelpMessage ?? "")
        }
        .alert(
            "Download Could Not Start",
            isPresented: ArkFileInstallerAlertPresentation.binding(
                message: { liteInstaller.downloadFailureMessage },
                isOwner: {
                    canPresentInstallerAlerts()
                        && !showEssentialsManage
                        && sheet?.ownsInstallerAlerts != true
                },
                dismiss: { liteInstaller.dismissDownloadFailureMessage() }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissDownloadFailureMessage()
            }
        } message: {
            Text(liteInstaller.downloadFailureMessage ?? "")
        }
        .confirmationDialog(
            "Cancel \(liteInstaller.currentDownloadDisplayName ?? "this title") download?",
            isPresented: $showCancelCurrentDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel & Remove Partial", role: .destructive) {
                Task {
                    _ = await liteInstaller.cancelCurrentDownloadAndDiscard()
                    await contentLibrary.refresh()
                }
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("The unfinished download will be removed. Installed titles stay available, and you can download this title again later.")
        }
        .alert(
            "Could Not Open Content",
            isPresented: Binding(
                get: { previewOpenError != nil },
                set: { if !$0 { previewOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(previewOpenError ?? "")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .map:
                toolSheet {
                    ArkFileOfflineMapView(
                        contentRoot: contentLibrary.contentRoot
                    )
                    .navigationTitle("Map")
                    .navigationBarTitleDisplayMode(.inline)
                }
            case .preparedness:
                toolSheet {
                    ArkFilePreparednessToolkitView()
                }
            case .savedWeather:
                toolSheet {
                    ArkFileSavedWeatherView(
                        contentRoot: contentLibrary.contentRoot
                    )
                }
            case .survivalGuide(let target):
                toolSheet {
                    ArkFileSurvivalGuideView(
                        initialSectionID: target?.sectionID,
                        initialBlockID: target?.blockID
                    )
                }
            case .library:
                toolSheet {
                    ArkFileHomeLibrarySheet()
                }
            case .localSharing:
                toolSheet {
                    HotspotZimFilesSelection()
                }
            case .account:
                toolSheet {
                    ArkFileAccountSignInSheet(
                        accountSession: accountSession,
                        liteInstaller: liteInstaller,
                        accountEmail: $accountEmail,
                        accountPassword: $accountPassword,
                        restoreEssentials: { beginRestore() }
                    )
                }
            case .offlineReadiness(let autoRunQuickCheck, let requestID):
                toolSheet {
                    ArkFileOfflineReadinessView(
                        autoRunQuickCheck: autoRunQuickCheck,
                        presentationRequestID: requestID
                    )
                }
            }
        }
        .navigationDestination(item: $activeReaderDestination) { destination in
            ArkFileContentViewer(
                item: destination.item,
                initialBookmark: destination.bookmark,
                openContentItem: { targetItem, bookmark in
                    openContentItemFromViewer(targetItem, bookmark: bookmark)
                }
            )
            .id(destination.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenMapLocation)) { _ in
            guard ArkFileAdaptiveNotificationRoutePolicy
                .embeddedViewHandles(
                    .arkFileOpenMapLocation,
                    device: Device.current
                ) else {
                return
            }
            isShowingOnboarding = false
            activeReaderDestination = nil
            DispatchQueue.main.async {
                presentSceneRoute(.map, fallback: .map)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileImportMapGPX)) { _ in
            guard ArkFileAdaptiveNotificationRoutePolicy
                .embeddedViewHandles(
                    .arkFileImportMapGPX,
                    device: Device.current
                ) else {
                return
            }
            isShowingOnboarding = false
            activeReaderDestination = nil
            DispatchQueue.main.async {
                presentSceneRoute(.map, fallback: .map)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenContentDownloads)) { notification in
            guard ArkFileAdaptiveNotificationRoutePolicy
                .embeddedViewHandles(
                    .arkFileOpenContentDownloads,
                    device: Device.current
                ) else {
                return
            }
            activeReaderDestination = nil
            sheet = nil
            contentDownloadsTargetRelativePath = notification.userInfo?["relativePath"] as? String
            DispatchQueue.main.async {
                presentContentDownloads(
                    targetRelativePath: contentDownloadsTargetRelativePath
                )
            }
        }

    }

    @ViewBuilder
    private var startHereSection: some View {
        let samples = Array(contentDisplayItems.filter(\.isSampleContent).prefix(3))
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Start here")
                Text("Explore a few included titles. They are ready to use offline.")
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                ForEach(samples) { item in
                    Button { handlePreviewOpen(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed")
                            Text(item.displayName)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .padding(12)
                        .background(Color.arkAppSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.arkTextPrimary)
                }
            }
        }
    }

    private var libraryBrowseActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: browseAllLibrary) {
                Label("Browse Library", systemImage: "books.vertical")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .accessibilityIdentifier("arkfile_home_browse_library")
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        manageDownloadsButton
                        downloadMapsButton
                    }
                } else {
                    HStack {
                        manageDownloadsButton
                        Spacer(minLength: 8)
                        downloadMapsButton
                    }
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(Color.arkInteractiveForeground)
            .frame(minHeight: 44)
            if !liteInstaller.hasSavedCompleteAccess {
                Button(hasEssentialsAccess ? "View Upgrade" : "View Packs") {
                    presentGeneralPackComparison()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.arkInteractiveForeground)
                .frame(minHeight: 44)
            }
        }
    }

    private var manageDownloadsButton: some View {
        Button { presentContentDownloads() } label: {
            Label("Manage Downloads", systemImage: "arrow.down.circle")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("arkfile_home_manage_downloads")
    }

    private var downloadMapsButton: some View {
        Button {
            NotificationCenter.default.post(name: .arkFileOpenMapRegion, object: nil,
                userInfo: ["showDownloads": true])
        } label: {
            Label("Download Maps", systemImage: "map")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private var personalLibrarySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your library")
                        .font(.headline)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(liteInstaller.hasSavedCompleteAccess ? "Complete unlocked" : (hasEssentialsAccess ? "Essentials unlocked" : "Saved on this device"))
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.arkInteractiveForeground)
            }
            libraryBrowseActions
            if liteInstaller.state.phase.isBusy || liteInstaller.queuedDownloadCount > 0 {
                Button { presentContentDownloads() } label: {
                    Label(liteInstaller.queuedDownloadCount > 0
                        ? "Downloads · \(liteInstaller.queuedDownloadCount) queued"
                        : "View download progress", systemImage: "arrow.down.circle")
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(Color.arkAppSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(Brand.loadingLogoImage)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.arkAccent.opacity(0.75), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text("ArkFile")
                    .font(.headline)
                    .foregroundStyle(Color.arkTextPrimary)
                Text("Preparedness library")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .accessibilityIdentifier("arkfile_home_root")
            }
            Spacer()
            if let toggleSidebar {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.headline)
                        .foregroundStyle(Color.arkInteractiveForeground)
                        .frame(width: 44, height: 44)
                        .background(Color.arkAppSurface)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.arkAppBorder, lineWidth: 1)
                        }
                }
                .accessibilityLabel("Show or Hide Sidebar")
                .accessibilityIdentifier(
                    "arkfile_ipad_sidebar_toggle"
                )
            }
            if showsSettingsButton {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .font(.headline)
                        .foregroundStyle(Color.arkInteractiveForeground)
                        .frame(width: 44, height: 44)
                        .background(Color.arkAppSurface)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.arkAppBorder, lineWidth: 1)
                        }
                }
                .accessibilityLabel(Text(LocalString.common_tab_menu_settings))
                .accessibilityIdentifier("arkfile_home_settings_action")
            }
        }
    }

    private func acquisitionIntroduction(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(homePresentation.heroTitle)
                    .font(.title2.bold())
                    .foregroundStyle(Color.arkTextPrimary)
                Text(homePresentation.heroCopy)
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(homePresentation.heroAccessibilityIdentifier)

            Button(action: presentGeneralPackComparison) {
                Text("Compare Essentials & Complete")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .accessibilityIdentifier("arkfile_compare_packs_action")

            VStack(alignment: .leading, spacing: 4) {
                Button(action: showIncludedSamples) {
                    Label("Explore \(includedSampleCount) Included Samples", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.arkInteractiveForeground)
                .accessibilityIdentifier("arkfile_included_samples_action")
                Text("The samples, Survival Guide, preparedness tools and base map are free to use offline.")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_included_samples_section")
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    browseAllLibraryButton
                    Spacer(minLength: 8)
                    includedToolsButton(scrollProxy: scrollProxy)
                }
                VStack(alignment: .leading, spacing: 4) {
                    browseAllLibraryButton
                    includedToolsButton(scrollProxy: scrollProxy)
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.arkAppSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private var browseAllLibraryButton: some View {
        Button(action: browseAllLibrary) {
            Label("Browse Library", systemImage: "books.vertical")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("arkfile_home_browse_library")
    }

    private func includedToolsButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeInOut) {
                scrollProxy.scrollTo(Self.includedToolsSectionID, anchor: .top)
            }
        } label: {
            Label("Included Tools", systemImage: "square.grid.2x2")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("arkfile_home_included_tools_action")
    }

    private func freeTools(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Included Tools")
            LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 10) {
                ArkFileHomeToolButton(
                    title: "Library",
                    copy: "Explore titles and see what is ready offline.",
                    systemImage: "books.vertical",
                    tint: Color.arkPrimary
                ) {
                    presentContentDownloads()
                }
                .accessibilityIdentifier("arkfile_home_library_tool_action")
                ArkFileHomeToolButton(
                    title: "Map",
                    copy: "View the offline vector map and installed Essentials map detail.",
                    systemImage: "map",
                    tint: Color.arkPrimaryHover
                ) {
                    presentSceneRoute(.map, fallback: .map)
                }
                ArkFileHomeToolButton(
                    title: "Preparedness",
                    copy: "Use planning calculators and emergency checklists.",
                    systemImage: "checklist",
                    tint: Color.arkAccentSecondary
                ) {
                    presentSceneRoute(
                        .preparedness(selectedView: nil),
                        fallback: .preparedness
                    )
                }
                ArkFileHomeToolButton(
                    title: "Survival Guide",
                    copy: "Search and explore offline emergency field guidance.",
                    systemImage: "book.closed",
                    tint: Color.arkAccent
                ) {
                    presentSceneRoute(
                        .survivalGuide(
                            sectionID: nil,
                            blockID: nil
                        ),
                        fallback: .survivalGuide(nil)
                    )
                }
                ArkFileHomeToolButton(
                    title: "Local Sharing",
                    copy: "Let nearby devices read included ArkFile content from this device.",
                    systemImage: "wifi",
                    tint: Color.arkPrimary
                ) {
                    presentSceneRoute(
                        .localSharing,
                        fallback: .localSharing
                    )
                }
                ArkFileHomeToolButton(
                    title: "Saved",
                    copy: "Jump to favorites and bookmarks.",
                    systemImage: "bookmark",
                    tint: Color.arkAccentSecondary
                ) {
                    if let navigateScene {
                        navigateScene(.saved)
                    } else {
                        withAnimation(.easeInOut) {
                            scrollProxy.scrollTo(
                                Self.savedContentSectionID,
                                anchor: .top
                            )
                        }
                    }
                }
                .accessibilityIdentifier("arkfile_home_saved_action")
                if FeatureFlags.arkFileUnifiedAccountUI {
                    ArkFileHomeToolButton(
                        title: "Account",
                        copy: accountToolCopy,
                        systemImage: accountSession.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle",
                        tint: accountSession.hasPurchased ? Color.arkPrimaryHover : Color.arkPrimary
                    ) {
                        sheet = .account
                    }
                }
            }
        }
    }

    /// Wraps tool sheets in a NavigationStack with an explicit Done button, so
    /// dismissal never depends on discovering the swipe-down gesture.
    private func toolSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            sheet = nil
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
    }

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Emergency", systemImage: "cross.circle.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.red)
            LazyVGrid(
                columns: ArkFileEmergencyChipGrid.columns(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
                spacing: ArkFileEmergencyChipGrid.chipSpacing
            ) {
                emergencyButton("heart.fill", "CPR") {
                    openGuide(blockID: "medical-cpr")
                }
                emergencyButton("lungs.fill", "Choking") {
                    openGuide(blockID: "medical-choking")
                }
                emergencyButton("bandage.fill", "Bleeding") {
                    openGuide(blockID: "medical-bleeding")
                }
                emergencyButton("waveform.path.ecg", "Heart Attack") {
                    openGuide(blockID: "medical-heart-attack")
                }
                emergencyButton("brain.head.profile", "Stroke") {
                    openGuide(blockID: "medical-stroke")
                }
                emergencyButton("phone.fill", "Emergency Phone Numbers") {
                    showEmergencyNumbers = true
                }
            }
            Text("All guidance works fully offline.")
                .font(.caption2)
                .foregroundStyle(Color.arkTextMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        }
    }

    private func openGuide(blockID: String) {
        presentSceneRoute(
            .survivalGuide(sectionID: nil, blockID: blockID),
            fallback: .survivalGuide(
                ArkFileSurvivalGuideTarget(blockID: blockID)
            )
        )
    }

    private func emergencyButton(
        _ systemImage: String,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(
                        dynamicTypeSize.isAccessibilitySize ? nil : 2
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.arkTextPrimary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 9)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkAppBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var continueReadingSection: some View {
        let availableEntries = readingHistory.availableEntries(in: contentLibrary.allItems)
        if !availableEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Continue Reading")
                ForEach(availableEntries.prefix(2)) { entry in
                    let reading = ArkFileHomeReadingPresentation.make(
                        articleTitle: entry.articleTitle,
                        fileName: entry.fileName,
                        relativePath: entry.relativePath,
                        contentType: entry.contentType,
                        pageNumber: entry.pageNumber
                    )
                    Button {
                        openBookmark(entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: continueReadingIcon(for: entry.contentType))
                                .font(.headline)
                                .foregroundStyle(Color.arkInteractiveForeground)
                                .frame(width: 36, height: 36)
                                .background(Color.arkPrimary.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reading.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.arkTextPrimary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let subtitle = reading.subtitle {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(Color.arkTextMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.forward.circle")
                                .foregroundStyle(Color.arkTextMuted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.arkAppSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.arkAppBorder, lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            readingHistory.remove(relativePath: entry.relativePath)
                        } label: {
                            Label("Remove from Continue Reading", systemImage: "xmark.circle")
                        }
                    }
                    .accessibilityLabel("Continue reading \(reading.title)")
                }
            }
        }
    }

    private func continueReadingIcon(for type: ArkFileLocalContentType) -> String {
        switch type {
        case .zim: "text.book.closed"
        case .pdf: "doc.richtext"
        case .html, .htmlBook: "book"
        case .image: "photo"
        case .map: "map"
        }
    }

    @ViewBuilder
    private var newContentSection: some View {
        if let summary = updateChecker.availableNewContent,
           liteInstaller.state.phase == .installed,
           summary.tier == nil || summary.tier == liteInstaller.installedTier,
           !liteInstaller.isBusy {
            let packName = ArkFileEssentialsUpdateChecker.packName(for: summary.tier ?? liteInstaller.installedTier)
            VStack(alignment: .leading, spacing: 10) {
                Label("\(packName) Update Available", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.arkTextPrimary)
                Text(newContentCopy(for: summary))
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    updateChecker.downloadNewContent()
                } label: {
                    Label("Download Update", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.arkPrimary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.arkPrimary.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func newContentCopy(for summary: ArkFileEssentialsUpdateChecker.NewContentSummary) -> String {
        let sizeText = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        let packName = ArkFileEssentialsUpdateChecker.packName(for: summary.tier ?? liteInstaller.installedTier)
        if summary.itemCount == 1 {
            return "1 new or updated title (\(sizeText)) is available for \(packName). Download it to keep your offline library current."
        }
        return "\(summary.itemCount) new or updated titles (\(sizeText)) are available for \(packName). Download them to keep your offline library current."
    }

    private var accountToolCopy: String {
        if Brand.hasDeveloperContentAuthToken {
            return "Developer content token enabled for local fixture QA."
        }
        if shouldUseRestoreForEssentialsAction {
            return "App Store purchase confirmed. Restore Purchases can re-check access."
        }
        if accountSession.isSignedIn {
            return accountSession.hasPurchased ? "Signed in. Desktop account access available." : "Signed in. ArkFile packs are handled by Apple."
        }
        return LocalString.arkfile_account_copy_signed_out
    }

    private var includedSamplesCallout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(Color.arkPrimaryHover)
                    .frame(width: 42, height: 42)
                    .background(Color.arkPrimaryHover.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Included with ArkFile")
                        .font(.headline)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text("\(includedSampleCount) sample titles, the Survival Guide, preparedness tools, and the offline base map are already on this device. No purchase is required.")
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: showIncludedSamples) {
                Label(
                    "Explore \(includedSampleCount) Included Samples",
                    systemImage: "books.vertical"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .accessibilityIdentifier("arkfile_included_samples_action")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.arkPrimaryHover.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("arkfile_included_samples_section")
    }

    private var includedSampleCount: Int {
        contentLibrary.bundledSampleLibraryItemCount
    }

    private var completeOwnerDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your Complete Access")
            completePackCard
        }
        .accessibilityIdentifier("arkfile_complete_owner_dashboard")
    }

    private var accountAndLite: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("ArkFile Packs")
            if blocksForAppleAccountCheck {
                ArkFileApplePurchaseCheckingView(
                    isBusy: liteInstaller.isBusy,
                    checkAppleAccount: {
                        beginRestore()
                    }
                )
            }
            if homePresentation.showsPackComparison {
                comparePacksButton
            }
            if shouldShowCompletePackCard {
                completePackCard
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.title2)
                            .foregroundStyle(Color.arkInteractiveForeground)
                            .frame(width: 34, height: 34)
                            .background(Color.arkPrimary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(essentialsCardTitle)
                                .font(.headline)
                                .foregroundStyle(Color.arkTextPrimary)
                            Text(essentialsAccountCopy)
                                .font(.subheadline)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    accountSection
                    installControls
                }
                .padding(16)
                .background(Color.arkAppSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.arkAppBorder, lineWidth: 1)
                }
            }
        }
    }

    private var comparePacksButton: some View {
        Button {
            presentGeneralPackComparison()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.2.swap")
                    .font(.title3)
                    .foregroundStyle(Color.arkAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.arkAccent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare Essentials and Complete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                    Text("See both one-time prices, what each pack includes, and the download choices before buying.")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.arkAccent.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("arkfile_compare_packs_action")
    }

    private var completePackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.title2)
                    .foregroundStyle(Color.arkLockedForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkAccentSecondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(completeCardTitle)
                        .font(.headline)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(completeAccountCopy)
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            completeInstallControls
        }
        .padding(16)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAccentSecondary.opacity(0.28), lineWidth: 1)
        }
    }

    private var shouldShowCompletePackCard: Bool {
        liteInstaller.hasSavedCompleteAccess
            || liteInstaller.installedTier == .complete
            || liteInstaller.state.tier == .complete
            || completeInstallNeedsRepair
    }

    @ViewBuilder
    private var accountSection: some View {
        if !FeatureFlags.arkFileUnifiedAccountUI {
            EmptyView()
        } else if Brand.hasDeveloperContentAuthToken {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.arkPrimaryHover)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Developer content token enabled.")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text("Local fixture downloads can run without account sign-in.")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        } else if accountSession.isSignedIn {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: accountSession.hasPurchased ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(accountSession.hasPurchased ? Color.arkPrimaryHover : Color.arkTextMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountSession.user?.email ?? LocalString.arkfile_account_status_signed_in)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.arkTextPrimary)
                        .lineLimit(1)
                    Text(accountStatusCopy)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                Spacer()
                Button(LocalString.arkfile_account_button_sign_out) {
                    accountSession.signOut()
                    liteInstaller.clearTransientPurchaseStatus()
                }
                .font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(LocalString.arkfile_account_prompt)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(Color.arkTextMuted)
                }
                if let error = accountSession.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var accountStatusCopy: String {
        if shouldUseRestoreForEssentialsAction {
            return "App Store purchase confirmed. Restore Purchases can re-check access."
        }
        return accountSession.hasPurchased
            ? LocalString.arkfile_account_status_unlocked
            : LocalString.arkfile_account_status_purchase_needed
    }

    private var essentialsCardTitle: String {
        if essentialsInstallNeedsRepair {
            return "Continue Download"
        }
        if shouldUseRestoreForEssentialsAction {
            return "Finish Purchase"
        }
        if liteInstaller.state.phase == .installed {
            return "\(installedEssentialsTitleCount) Essentials title\(installedEssentialsTitleCount == 1 ? "" : "s") available offline"
        }
        if hasEssentialsAccess {
            return "Essentials unlocked"
        }
        if blocksForAppleAccountCheck {
            return "Checking Apple purchases…"
        }
        return "Buy ArkFile Essentials"
    }

    private var essentialsAccountCopy: String {
        if essentialsInstallNeedsRepair {
            return incompleteEssentialsCopy
        }
        if shouldUseRestoreForEssentialsAction {
            return "App Store purchase confirmed. Restore Purchases re-checks access without downloading; you choose Essentials downloads afterward."
        }
        if liteInstaller.state.tier == .lite,
           liteInstaller.state.phase == .failed,
           let status = liteInstaller.statusText(for: .lite) {
            return status
        }
        if liteInstaller.state.tier == .lite,
           let resumableInstallCopy = liteInstaller.resumableInstallCopy(for: .lite) {
            return resumableInstallCopy
        }
        if liteInstaller.state.tier == .lite,
           liteInstaller.state.phase.isBusy {
            return "Essentials is downloading. ArkFile will keep the files already downloaded if this is interrupted."
        }
        if liteInstaller.state.phase == .installed {
            return packMetrics.essentialsReadyLine
        }
        if hasEssentialsAccess {
            return "Essentials is unlocked. Choose the titles you want on this device and add more whenever you need them."
        }
        if blocksForAppleAccountCheck {
            return "ArkFile is checking this Apple Account before showing purchase or download choices."
        }
        if accountSession.isSignedIn {
            return "Unlock Essentials with one purchase. Choose your downloads afterward."
        }
        return "Unlock Essentials with one purchase. Download only what you need, when you need it."
    }

    private var completeCardTitle: String {
        if liteInstaller.hasSavedCompleteAccess {
            return "ArkFile Complete"
        }
        if completeInstallNeedsRepair {
            return "Continue Complete Download"
        }
        if liteInstaller.installedTier == .complete {
            return "ArkFile Complete"
        }
        if liteInstaller.hasSavedCompleteAccess {
            return "ArkFile Complete"
        }
        if hasEssentialsAccess {
            return "Upgrade to ArkFile Complete"
        }
        if blocksForAppleAccountCheck {
            return "Checking Apple purchases…"
        }
        return "Buy ArkFile Complete"
    }

    private var completeAccountCopy: String {
        if liteInstaller.hasSavedCompleteAccess {
            let summary = completeOwnershipMetrics.purchasedSummary
            return completeInstallNeedsRepair
                ? "\(summary) A download needs attention; everything already here is unchanged."
                : summary
        }
        if completeInstallNeedsRepair {
            return "Complete download did not finish. Continue Download to pick up where it left off."
        }
        if liteInstaller.state.tier == .complete,
           liteInstaller.state.phase == .failed,
           let status = liteInstaller.statusText(for: .complete) {
            return status
        }
        if let resumableInstallCopy = liteInstaller.resumableInstallCopy(for: .complete) {
            return resumableInstallCopy
        }
        if liteInstaller.state.tier == .complete, liteInstaller.state.phase.isBusy {
            return "Complete is downloading. ArkFile will keep the files already downloaded if this is interrupted."
        }
        if liteInstaller.installedTier == .complete {
            return packMetrics.completeReadyLine
        }
        if liteInstaller.hasSavedCompleteAccess {
            return "Complete is unlocked on this device. Download the titles you want, and choose one full-Wikipedia variant."
        }
        if hasEssentialsAccess {
            return "Adds full Wikipedia (your choice of text-only or with images), 27 college and AP textbooks, expanded expert references, and more classics. Apple shows the upgrade price before charging."
        }
        if blocksForAppleAccountCheck {
            return "ArkFile is checking whether this Apple Account already owns Complete."
        }
        return "Includes Essentials plus full Wikipedia options, 27 college and AP textbooks, and the rest of the Complete library. Apple shows the price before charging."
    }

    private var incompleteEssentialsCopy: String {
        "Essentials download did not finish. Continue Download to pick up where it left off."
    }

    private var installControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                handleEssentialsInstallAction()
            } label: {
                Label(
                    litePrimaryButtonTitle,
                    systemImage: litePrimaryButtonSystemImage
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .disabled(
                liteInstaller.isBusy
                    || (
                        blocksForAppleAccountCheck
                            && !hasEssentialsAccess
                    )
            )
            .accessibilityIdentifier("arkfile_essentials_primary_action")

            if shouldShowBrowseAllContentButton {
                Button {
                    presentContentDownloads()
                } label: {
                    Label("Browse Library", systemImage: "rectangle.grid.1x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if liteInstaller.state.phase == .installed && !liteInstaller.isBusy {
                Button {
                    presentContentDownloads()
                } label: {
                    Label("Manage Downloads", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if hasEssentialsAccess && !liteInstaller.hasSavedCompleteAccess {
                    Button {
                        handleCompleteInstallAction()
                    } label: {
                        Label(
                            shouldRestoreEssentialsToUpgrade
                                ? "Restore Essentials to Upgrade"
                                : "Upgrade Content Pack",
                            systemImage: shouldRestoreEssentialsToUpgrade
                                ? "arrow.clockwise.circle"
                                : "books.vertical"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.arkAccentSecondary)
                    .disabled(blocksForAppleAccountCheck)
                    .accessibilityIdentifier("arkfile_upgrade_content_pack_action")
                }
            }

            if liteInstaller.shouldOfferCellularDownloadOverride
                && liteInstaller.cellularDownloadOverrideTier == .lite {
                Button {
                    prepareEssentialsDownloadWarning(for: .cellularOverride)
                } label: {
                    Label("Use Cellular Data...", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.arkAppSurfaceSecondary)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.arkAppBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(liteInstaller.isBusy)
            }

            if shouldShowLiteStatusText, let statusText = liteInstaller.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = liteInstaller.state.progressFraction,
               liteInstaller.shouldShowProgressBar {
                ProgressView(value: progress)
            }
            downloadInterruptionControls
        }
    }

    private var completeInstallControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                handleCompleteInstallAction()
            } label: {
                Label(
                    completePrimaryButtonTitle,
                    systemImage: completePrimaryButtonSystemImage
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
            .disabled(
                liteInstaller.isBusy
                    || (
                        blocksForAppleAccountCheck
                            && completeManagementRoute == .reviewPurchase
                    )
            )
            .accessibilityIdentifier("arkfile_complete_primary_action")

            if shouldShowCompleteManagerSecondaryAction {
                Button {
                    presentContentDownloads()
                } label: {
                    Label(
                        liteInstaller.isBusy ? "View Download Progress" : "Manage Individual Titles",
                        systemImage: "rectangle.grid.1x2"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if liteInstaller.shouldOfferCellularDownloadOverride
                && liteInstaller.cellularDownloadOverrideTier == .complete {
                Button {
                    prepareEssentialsDownloadWarning(for: .completeCellularOverride)
                } label: {
                    Label("Use Cellular Data...", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.arkAppSurfaceSecondary)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.arkAppBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(liteInstaller.isBusy)
            }

            if (liteInstaller.state.tier == .complete || liteInstaller.deferredDownloadTier == .complete),
               shouldShowCompleteStatusText,
               let statusText = liteInstaller.statusText(for: .complete) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if liteInstaller.state.tier == .complete,
               let progress = liteInstaller.state.progressFraction,
               liteInstaller.shouldShowProgressBar {
                ProgressView(value: progress)
            }
            if liteInstaller.state.tier == .complete {
                downloadInterruptionControls
            }
        }
    }

    @ViewBuilder
    private var downloadInterruptionControls: some View {
        if liteInstaller.canPauseLiteDownload {
            Button(role: .cancel) {
                liteInstaller.cancelLiteDownload()
            } label: {
                Label("Pause Download", systemImage: "pause.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Keeps partial progress so the download can resume later.")
            .accessibilityIdentifier("arkfile_download_pause_action")

            if liteInstaller.canCancelCurrentDownload {
                Button(role: .destructive) {
                    showCancelCurrentDownloadConfirmation = true
                } label: {
                    Label("Cancel Download…", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityHint("Stops the current title and removes its unfinished data after confirmation.")
            }
        }
    }

    private var completePrimaryButtonTitle: String {
        if liteInstaller.state.tier == .complete && liteInstaller.state.phase.isBusy {
            return liteInstaller.buttonTitle(for: .complete)
        }
        switch completeManagementRoute {
        case .resumeDownload, .repairDownload:
            return "Continue Download"
        case .manageDownloads:
            return "Manage Downloads"
        case .reviewPurchase:
            if blocksForAppleAccountCheck {
                return "Checking Apple purchases…"
            }
            return ArkFilePackPurchaseCopy.completeReviewTitle(
                hasEssentialsAccess: hasEssentialsAccess,
                hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
                hasCurrentEssentialsProof: liteInstaller.hasCurrentStoreKitProof(for: .lite)
            )
        }
    }

    private var completePrimaryButtonSystemImage: String {
        if liteInstaller.state.tier == .complete && liteInstaller.state.phase.isBusy {
            return "arrow.down.circle"
        }
        switch completeManagementRoute {
        case .resumeDownload, .repairDownload:
            return "arrow.clockwise.circle"
        case .manageDownloads:
            return "internaldrive"
        case .reviewPurchase:
            if blocksForAppleAccountCheck {
                return "clock.arrow.circlepath"
            }
            if ArkFilePackPurchaseCopy.needsEssentialsRestoreToUpgrade(
                hasEssentialsAccess: hasEssentialsAccess,
                hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
                hasCurrentEssentialsProof: liteInstaller.hasCurrentStoreKitProof(for: .lite)
            ) {
                return "arrow.clockwise.circle"
            }
            return hasEssentialsAccess ? "arrow.up.circle" : "lock.open"
        }
    }

    private var completeManagementRoute: ArkFileCompleteManagementRoute {
        ArkFileCompleteManagementRoute.resolve(
            hasSavedCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasInterruptedCompleteDownload: liteInstaller.hasInterruptedInstall(for: .complete),
            hasResumableCompleteDownload: liteInstaller.hasResumableDownload(for: .complete),
            needsCompleteRepair: completeInstallNeedsRepair
        )
    }

    private var shouldShowCompleteManagerSecondaryAction: Bool {
        liteInstaller.hasSavedCompleteAccess
            && (
                liteInstaller.isBusy
                    || completeManagementRoute != .manageDownloads
            )
    }

    private var litePrimaryButtonTitle: String {
        if essentialsInstallNeedsRepair {
            return "Continue Download"
        }
        if liteInstaller.state.phase == .installed {
            return "Go to Library"
        }
        if blocksForAppleAccountCheck, !hasEssentialsAccess {
            return "Checking Apple purchases…"
        }
        if !canStartEssentialsInstall {
            return LocalString.arkfile_lite_button_sign_in_to_install
        }
        if liteInstaller.state.phase.isBusy {
            return liteInstaller.liteButtonTitle
        }
        if shouldUseRestoreForEssentialsAction {
            return liteInstaller.liteButtonTitle
        }
        if liteInstaller.hasResumableDownload(for: .lite) {
            return liteInstaller.liteButtonTitle
        }
        return liteInstaller.liteButtonTitle
    }

    private var litePrimaryButtonSystemImage: String {
        if essentialsInstallNeedsRepair {
            return "arrow.clockwise.circle"
        }
        if liteInstaller.state.phase == .installed {
            return "books.vertical"
        }
        if blocksForAppleAccountCheck, !hasEssentialsAccess {
            return "clock.arrow.circlepath"
        }
        if !canStartEssentialsInstall {
            return "person.crop.circle"
        }
        if shouldUseRestoreForEssentialsAction {
            return "arrow.clockwise.circle"
        }
        if liteInstaller.hasInterruptedInstall(for: .lite) {
            return "arrow.clockwise.circle"
        }
        if liteInstaller.hasResumableDownload(for: .lite) {
            return "arrow.clockwise.circle"
        }
        if hasEssentialsAccess || liteInstaller.state.phase.isBusy {
            return "arrow.down.circle"
        }
        return "lock.open"
    }

    private var canStartEssentialsInstall: Bool {
        true
    }

    private var shouldUseRestoreForEssentialsAction: Bool {
        liteInstaller.hasPendingStoreKitPurchase || liteInstaller.hasTransientPurchaseStatus
    }

    private var shouldShowBrowseAllContentButton: Bool {
        !hasEssentialsAccess
            && !liteInstaller.hasSavedCompleteAccess
            && liteInstaller.installedTier == nil
            && !liteInstaller.isBusy
    }

    private var hasEssentialsAccess: Bool {
        liteInstaller.hasSavedLiteAccess
    }

    private var homePresentation: ArkFileHomePresentation {
        ArkFileHomePresentation.resolve(
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasLocalPaidContent: hasLocalPaidContent
        )
    }

    private var installedEssentialsTitleCount: Int {
        packMetrics.installedEssentialsTitleCount
    }

    private var packMetrics: ArkFileHomePackCardMetrics {
        ArkFileHomePackCardMetrics.make(items: contentLibrary.allLibraryItems)
    }

    private var completeOwnershipMetrics: ArkFileCompleteOwnershipMetrics {
        ArkFileCompleteOwnershipMetrics.make(
            catalog: contentCatalog,
            libraryItems: contentLibrary.allLibraryItems
        )
    }

    private var activeInstallNeedsRepair: Bool {
        liteInstaller.needsLiteRepair
            || ArkFileLocalContentLibrary.installedCatalogNeedsRepair(
                phase: liteInstaller.state.phase,
                installedCount: contentLibrary.installedCatalogItemCount,
                expectedCount: contentLibrary.expectedEssentialsItemCount,
                allowsDeveloperFixtureCatalog: Brand.allowsDeveloperFixtureCatalog
            )
    }

    private var essentialsInstallNeedsRepair: Bool {
        ArkFileContentPackInstaller.isActiveDownloadTier(
            .lite,
            activeTier: liteInstaller.state.tier
        ) && activeInstallNeedsRepair
    }

    private var completeInstallNeedsRepair: Bool {
        ArkFileContentPackInstaller.isActiveDownloadTier(
            .complete,
            activeTier: liteInstaller.state.tier
        ) && activeInstallNeedsRepair
    }

    private var shouldShowLiteStatusText: Bool {
        if liteInstaller.hasTransientPurchaseStatus {
            return true
        }
        // A healthy installed pack already says so in the card title; repeating
        // "ready offline" as a caption is noise.
        if liteInstaller.state.phase == .installed {
            return false
        }
        return hasEssentialsAccess
            || liteInstaller.hasInterruptedInstall(for: .lite)
            || liteInstaller.state.phase.isBusy
            || liteInstaller.state.phase == .readyToDownload
            || liteInstaller.state.phase == .failed
    }

    @ViewBuilder
    private var offlineReadinessSection: some View {
        if readinessChecker.hasManagedContent {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Offline Readiness")
                ArkFileOfflineReadinessCard {
                    sheet = .offlineReadiness(
                        autoRunQuickCheck: !readinessChecker.hasRecentPassingCheck,
                        requestID: nil
                    )
                }
            }
        }
    }

    private func presentReadinessRequestIfNeeded() {
        guard let request = readinessCoordinator.presentationRequest else { return }
        if isShowingOnboarding || sheet != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                presentReadinessRequestIfNeeded()
            }
            return
        }
        activeReaderDestination = nil
        sheet = .offlineReadiness(
            autoRunQuickCheck: request.autoRunQuickCheck,
            requestID: request.id
        )
    }

    private var contentPreview: some View {
        let sections = contentDisplaySections
        let matchingItems = ArkFileLibraryDiscovery.matchingItems(
            sections.flatMap(\.items), filter: homeLibraryFilter, query: homeLibraryQuery
        )
        let matchingIDs = Set(matchingItems.map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Inside ArkFile")
            Text(contentPreviewSummary(for: matchingItems))
                .accessibilityIdentifier("arkfile_home_library_summary")
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            homeLibrarySearch
            homeLibraryFilterControl

            if matchingItems.isEmpty {
                ContentUnavailableView(
                    homeLibraryQuery.isEmpty ? "No titles on this device" : "No matching titles",
                    systemImage: homeLibraryQuery.isEmpty ? "books.vertical" : "magnifyingglass",
                    description: Text(homeLibraryQuery.isEmpty
                        ? "Choose All content to find your next download."
                        : "Try another title or topic.")
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(sections) { section in
                        let visibleItems = section.items.filter { matchingIDs.contains($0.id) }
                        if !visibleItems.isEmpty {
                            ArkFileHomeCategoryMenu(
                                section: section,
                                items: visibleItems,
                                resolutionInput: lockedResolutionInput,
                                onOpen: openHomeLibraryItem
                            )
                        }
                    }
                }
            }
        }
        .id(Self.libraryContentSectionID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arkfile_included_samples_destination")
    }

    @ViewBuilder
    private var homeLibraryFilterControl: some View {
        let picker = Picker("Show content", selection: $homeLibraryFilter) {
            Text("All content").tag(ArkFileLibraryFilter.allContent)
            Text("On this device").tag(ArkFileLibraryFilter.onDevice)
            Text("Samples").tag(ArkFileLibraryFilter.includedSamples)
        }
        .accessibilityIdentifier("arkfile_home_library_filter")
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
                .font(.body)
                .tint(Color.arkInteractiveForeground)
                .frame(minHeight: 44)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var homeLibrarySearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.arkTextMuted)
            TextField("Find a title or topic", text: $homeLibraryQuery,
                prompt: Text("Find a title or topic").foregroundStyle(Color.arkTextMuted))
                .foregroundStyle(Color.arkTextPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($homeLibrarySearchFocused)
                .onSubmit { homeLibrarySearchFocused = false }
                .accessibilityIdentifier("arkfile_home_library_search")
            if !homeLibraryQuery.isEmpty {
                Button {
                    homeLibraryQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.arkTextMuted)
                .accessibilityLabel("Clear library search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(Color.arkAppSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private func contentPreviewSummary(for items: [ArkFileLibraryContentItem]) -> String {
        let presentations = items.map {
            ArkFileLockedContentPresentation.resolve(item: $0, input: lockedResolutionInput)
        }
        let ready = presentations.filter { $0.accessState == .installed || $0.accessState == .sample }.count
        let available = presentations.filter { $0.accessState == .downloadable }.count
        let locked = presentations.filter { $0.accessState == .locked }.count
        var parts = ["\(ready) ready offline"]
        if available > 0 { parts.append("\(available) available to download") }
        if locked > 0 { parts.append("\(locked) require a pack") }
        return parts.joined(separator: " · ")
    }

    private func openHomeLibraryItem(_ item: ArkFileLibraryContentItem) {
        homeLibrarySearchFocused = false
        let presentation = ArkFileLockedContentPresentation.resolve(item: item, input: lockedResolutionInput)
        if ArkFileContentOpenRoute.resolve(presentation: presentation) == .continueOpening {
            handlePreviewOpen(item)
        } else {
            presentContentDownloads(targetRelativePath: item.relativePath)
        }
    }

    private var contentDisplaySections: [ArkFileContentDisplayLibrarySection] {
        let categories = ArkFileContentDisplayLibrarySection.completeCatalogBackedCategories(
            installedCategories: contentLibrary.categories,
            fallbackCategories: contentLibrary.libraryCategories,
            catalog: contentCatalog
        )
        return ArkFileContentDisplayLibrarySection.mainLibrarySections(
            from: ArkFileContentDisplayLibrarySection.makeSections(
                from: categories,
                catalog: contentCatalog,
                resolutionInput: lockedResolutionInput
            )
        )
    }

    private var contentDisplayItems: [ArkFileLibraryContentItem] {
        contentDisplaySections.flatMap(\.items)
    }

    @ViewBuilder
    private var savedPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            favoritePreview
            bookmarkPreview
        }
        .id(Self.savedContentSectionID)
        .accessibilityIdentifier("arkfile_saved_section")
    }

    @ViewBuilder
    private var favoritePreview: some View {
        if contentLibrary.hasLibraryContent {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Favorites")
                LazyVGrid(columns: previewColumns, alignment: .leading, spacing: 12) {
                    ArkFileContentSelectorCard(
                        title: "Favorites",
                        description: "Favorited archives and files",
                        systemImage: "star",
                        accent: Color.arkAccent,
                        items: contentFavorites.favoriteItems(in: contentLibrary.categories).map {
                            ArkFileLibraryContentItem(installed: $0)
                        },
                        selectedItem: selectedPreviewItems["favorites"],
                        emptyMessage: "No favorites yet. Open content and mark it as a favorite.",
                        isOpening: openingPreviewItemID == selectedPreviewItems["favorites"]?.id,
                        resolutionInput: lockedResolutionInput,
                        lockedNoticeTitle: lockedSelectorNoticeTitle,
                        lockedSelectedMessage: { lockedSelectorSelectedMessage(for: $0) },
                        lockedButtonTitle: { lockedSelectorButtonTitle(for: $0) },
                        lockedButtonSystemImage: { lockedSelectorButtonSystemImage(for: $0) },
                        onSelect: { selectedPreviewItems["favorites"] = $0 },
                        onOpen: handlePreviewOpen
                    )
                }
            }
            .accessibilityIdentifier("arkfile_favorites_section")
        }
    }

    @ViewBuilder
    private var bookmarkPreview: some View {
        if contentLibrary.hasLibraryContent || !contentBookmarks.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Bookmarks")
                if contentBookmarks.bookmarks.isEmpty {
                    ArkFileHomeBookmarkEmptyCard()
                } else {
                    ArkFileBookmarkSelectorCard(
                        bookmarks: contentBookmarks.bookmarks,
                        selectedBookmark: selectedBookmark,
                        onSelect: { selectedBookmark = $0 },
                        onOpen: openBookmark
                    )
                }
            }
            .accessibilityIdentifier("arkfile_bookmarks_section")
        }
    }

    private var lockedPreviewPrimaryActionTitle: String {
        guard let lockedPreviewItem else {
            return "Buy Essentials"
        }
        return lockedActionTitle(for: lockedPreviewItem)
    }

    private var lockedPreviewAlertTitle: String {
        guard let lockedPreviewItem else {
            return "Essentials Access"
        }
        return "\(lockedPreviewItem.requiredPackName) Access"
    }

    private var lockedPreviewRestoreTitle: String {
        lockedPreviewItem?.requiredTier == .complete ? "Restore Complete Purchase" : "Restore Purchases"
    }

    private var lockedPreviewRestoreAvailable: Bool {
        guard let lockedPreviewItem else { return false }
        if lockedPreviewItem.requiredTier == .complete {
            return !liteInstaller.isBusy
        }
        return liteInstaller.canRestoreLite
    }

    private var lockedPreviewDownloadOnlyTier: ArkFileContentTier {
        guard let lockedPreviewItem else { return .lite }
        return downloadTier(for: lockedPreviewItem)
    }

    private var lockedResolutionInput: ArkFileLockedContentResolutionInput {
        ArkFileLockedContentResolutionInput(
            installer: liteInstaller,
            hasAuthoritativeNoPurchase: liteInstaller.hasAuthoritativeNoPurchase,
            hasEssentialsAccess: hasEssentialsAccess,
            essentialsInstallNeedsRepair: essentialsInstallNeedsRepair,
            completeInstallNeedsRepair: completeInstallNeedsRepair
        )
    }

    private func lockedActionTitle(for item: ArkFileLibraryContentItem) -> String {
        let tier = downloadTier(for: item)
        if installNeedsRepair(for: tier) {
            return "Continue Download"
        }
        if hasSavedAccess(for: tier) {
            if liteInstaller.state.tier == tier && liteInstaller.hasResumableLiteDownload {
                return "Resume Download"
            }
            return tier == .complete ? "Manage Downloads" : "Choose Downloads"
        }
        if tier == .complete {
            return hasEssentialsAccess ? "Upgrade to Complete" : "Buy Complete"
        }
        return "Buy Essentials"
    }

    private var lockedPreviewMessage: String {
        let title = lockedPreviewItem?.displayName ?? "This title"
        let packName = lockedPreviewItem?.requiredPackName ?? "ArkFile Essentials"
        let tier = downloadTier(for: lockedPreviewItem)
        if installNeedsRepair(for: tier) {
            return "\(title) is part of \(packName), but \(packShortName(for: tier)) did not finish downloading. Continue Download to pick up where it left off."
        }
        if liteInstaller.isLiteAccessRevoked || (tier == .complete && liteInstaller.isCompleteAccessRevoked) {
            return "\(title) is part of \(packName), but ArkFile could not confirm active \(packShortName(for: tier)) access for future downloads. Restore Purchases to re-check access. Valid content already installed on this device remains readable."
        }
        if hasSavedAccess(for: tier) {
            return "\(title) is part of \(packName), but this title is not downloaded on this device yet. \(lockedDownloadVerb(for: tier)) to make it available offline."
        }
        if tier == .complete {
            return "\(title) is locked Complete content. Buy ArkFile Complete with your Apple Account, or restore purchases if you already bought it."
        }
        return "\(title) is locked Essentials content. Buy ArkFile Essentials with your Apple Account, or restore purchases if you already bought it."
    }

    private var lockedSelectorNoticeTitle: String {
        essentialsInstallNeedsRepair
            ? "Download incomplete"
            : "ArkFile pack required"
    }

    private func lockedSelectorSelectedMessage(for item: ArkFileLibraryContentItem) -> String {
        let tier = downloadTier(for: item)
        if installNeedsRepair(for: tier) {
            return incompleteEssentialsCopy
        }
        if hasSavedAccess(for: tier) {
            return "Download \(packShortName(for: tier)) to make this content available offline."
        }
        return "Locked \(packShortName(for: tier)) content. Buy the pack, then choose what to download, or restore ownership without starting a download."
    }

    private func lockedSelectorButtonTitle(for item: ArkFileLibraryContentItem) -> String {
        lockedActionTitle(for: item)
    }

    private func lockedSelectorButtonSystemImage(for item: ArkFileLibraryContentItem) -> String {
        let tier = downloadTier(for: item)
        if installNeedsRepair(for: tier) || hasSavedAccess(for: tier) {
            return "arrow.clockwise.circle"
        }
        return "arrow.down.circle"
    }

    private func downloadTier(for item: ArkFileLibraryContentItem?) -> ArkFileContentTier {
        if liteInstaller.installedTier == .complete {
            return .complete
        }
        return item?.requiredTier ?? .lite
    }

    private func hasSavedAccess(for tier: ArkFileContentTier) -> Bool {
        tier == .complete ? liteInstaller.hasSavedCompleteAccess : hasEssentialsAccess
    }

    private func installNeedsRepair(for tier: ArkFileContentTier) -> Bool {
        tier == .complete ? completeInstallNeedsRepair : essentialsInstallNeedsRepair
    }

    private func packShortName(for tier: ArkFileContentTier) -> String {
        ArkFileContentPackDisplayName.name(for: tier)
    }

    private func lockedDownloadVerb(for tier: ArkFileContentTier) -> String {
        if liteInstaller.state.tier == tier && liteInstaller.hasResumableLiteDownload {
            return "Resume Download"
        }
        return tier == .complete ? "Open Manage Downloads" : "Choose Downloads"
    }

    private func handlePreviewOpen(_ item: ArkFileLibraryContentItem) {
        openingPreviewItemID = nil
        let presentation = ArkFileLockedContentPresentation.resolve(
            item: item,
            input: lockedResolutionInput
        )
        guard ArkFileContentOpenRoute.resolve(
            presentation: presentation
        ) == .continueOpening else {
            lockedPreviewItem = item
            return
        }
        guard let localItem = item.localItem else {
            previewOpenError = "ArkFile could not find \(item.displayName) in the local library."
            return
        }
        if let openSceneContent {
            openSceneContent(localItem, nil)
            return
        }
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        guard localItem.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: localItem)
            return
        }
        Task {
            await openPreviewZim(localItem, continuing: readerOpenIntent)
        }
    }

    private func handleBrowserOpen(_ item: ArkFileLocalContentItem) {
        openingPreviewItemID = nil
        if let openSceneContent {
            openSceneContent(item, nil)
            return
        }
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        guard item.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item)
            return
        }
        Task {
            await openPreviewZim(item, continuing: readerOpenIntent)
        }
    }

    private func openPreviewZim(
        _ item: ArkFileLocalContentItem,
        continuing readerOpenIntent: ArkFileReaderOpenIntent
    ) async {
        openingPreviewItemID = item.id
        defer {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                openingPreviewItemID = nil
            }
        }
        guard let fileID = await LibraryOperations.openFileID(url: item.url) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                previewOpenError = "ArkFile could not register \(item.displayName) as readable content."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard await ZimFileService.shared.openArchive(zimFileID: fileID) != nil else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                previewOpenError = "ArkFile could not open the current local copy of \(item.displayName)."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard let mainPageURL = await ZimFileService.shared.getMainPageURL(zimFileID: fileID) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                previewOpenError = "ArkFile opened \(item.displayName), but could not find its main page."
            }
            return
        }
        NotificationCenter.openURL(mainPageURL, continuing: readerOpenIntent)
    }

    private func openBookmark(_ bookmark: ArkFileContentBookmark) {
        openingPreviewItemID = nil
        guard let item = contentLibrary.allItems.first(where: { $0.relativePath == bookmark.relativePath }) else {
            previewOpenError = "ArkFile could not find \(bookmark.fileName) in the local library."
            return
        }
        if let openSceneContent {
            openSceneContent(item, bookmark)
            return
        }
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        guard item.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item, bookmark: bookmark)
            return
        }
        Task {
            openingPreviewItemID = item.id
            defer {
                if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                    openingPreviewItemID = nil
                }
            }
            switch await ArkFileSavedZIMResolver.resolve(bookmark: bookmark, item: item) {
            case .success(let destination):
                NotificationCenter.openURL(destination.url, continuing: readerOpenIntent)
            case .failure(let failure):
                guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                    return
                }
                previewOpenError = failure.message(itemName: item.displayName)
            }
        }
    }

    private func openContentItemFromViewer(
        _ item: ArkFileLocalContentItem,
        bookmark: ArkFileContentBookmark?
    ) {
        openingPreviewItemID = nil
        activeReaderDestination = nil
        if let openSceneContent {
            openSceneContent(item, bookmark)
            return
        }
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        guard item.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item, bookmark: bookmark)
            return
        }
        if let bookmark {
            openBookmark(bookmark)
        } else {
            Task { await openPreviewZim(item, continuing: readerOpenIntent) }
        }
    }

    private func handleLockedPreviewAction() {
        if downloadTier(for: lockedPreviewItem) == .complete {
            handleCompleteInstallAction()
        } else {
            handleEssentialsInstallAction()
        }
    }

    private func canDownloadItemIndividually(_ item: ArkFileLibraryContentItem) -> Bool {
        let tier = downloadTier(for: item)
        return !item.isInstalled
            && !item.isSampleContent
            && hasSavedAccess(for: tier)
            && !liteInstaller.isBusy
            && !installNeedsRepair(for: tier)
    }

    private var shouldShowCompleteStatusText: Bool {
        if liteInstaller.deferredDownloadTier == .complete {
            return true
        }
        guard shouldShowLiteStatusText else { return false }
        guard liteInstaller.hasSavedCompleteAccess,
              liteInstaller.state.phase == .failed,
              let errorMessage = liteInstaller.state.errorMessage else {
            return true
        }
        return ArkFileContentPackInstaller.sanitizedLegacyManifestFailureMessage(
            errorMessage,
            tier: .complete
        ) != ArkFileContentPackInstaller.safeManifestRejectionMessage(for: .complete)
    }

    private func handleEssentialsInstallAction() {
        if liteInstaller.state.phase == .installed && !essentialsInstallNeedsRepair {
            if let navigateScene {
                navigateScene(.library)
            } else {
                requestLibraryScroll()
            }
            return
        }
        if liteInstaller.hasInterruptedInstall(for: .lite) {
            if liteInstaller.state.hasPendingExplicitDownloadRequest {
                liteInstaller.resumeQueuedDownloads()
            } else {
                liteInstaller.resumeInterruptedInstallByUser()
            }
            return
        }
        if shouldUseRestoreForEssentialsAction {
            beginRestore(tier: .lite)
            return
        }
        if essentialsInstallNeedsRepair {
            liteInstaller.repairLite()
            return
        }
        if !liteInstaller.hasSavedLiteAccess {
            guard !blocksForAppleAccountCheck else { return }
            beginPurchaseWithoutDownload(tier: .lite)
            return
        }
        if liteInstaller.hasResolvedCurrentStoreKitProof,
           !liteInstaller.hasCurrentStoreKitProof(for: .lite) {
            beginRestore()
            return
        }
        showEssentialsSelectionReview = true
    }

    private func handleLockedPrimaryAction(tier: ArkFileContentTier) {
        if !(tier == .complete ? liteInstaller.hasSavedCompleteAccess : hasEssentialsAccess) {
            presentGeneralPackComparison()
            return
        }
        if tier == .complete {
            handleCompleteInstallAction()
        } else {
            handleEssentialsInstallAction()
        }
    }

    private func handleLockedRestoreAction(_ route: ArkFileLockedContentRestoreRoute) {
        switch route {
        case .restore(let tier):
            beginRestore(tier: tier)
        case .restoreEssentialsThenReviewComplete:
            beginRestoreForCompletePurchase()
        }
    }

    private func presentGeneralPackComparison() {
        mapPurchaseContext = nil
        showPackComparison = true
    }

    private func comparisonDismissed() {
        let returnContext = preservesMapContextAfterComparison ? nil : mapPurchaseContext
        if !preservesMapContextAfterComparison { mapPurchaseContext = nil }
        preservesMapContextAfterComparison = false
        guard let returnContext else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .arkFileOpenMapRegion,
                object: nil,
                userInfo: [
                    "relativePath": returnContext.relativePath ?? "",
                    "showDownloads": returnContext.showDownloadsOnReturn
                ]
            )
        }
    }

    private func closeComparisonAndShowDownloads() {
        let mapContext = mapPurchaseContext
        mapPurchaseContext = nil
        showPackComparison = false
        DispatchQueue.main.async {
            if let mapContext {
                NotificationCenter.default.post(name: .arkFileOpenMapRegion, object: nil,
                    userInfo: ["relativePath": mapContext.relativePath ?? "", "showDownloads": true])
            } else {
                presentContentDownloads()
            }
        }
    }

    private func closeComparisonAndRestore() {
        preservesMapContextAfterComparison = true
        showPackComparison = false
        pendingPackComparisonTierAfterRestore = nil
        DispatchQueue.main.async { beginRestore() }
    }

    private func confirmEssentialsSelection(_ result: ArkFilePackSelectionResult) {
        showEssentialsSelectionReview = false
        liteInstaller.includeItemsAndDownload(
            keys: result.selectedMissingItemKeys.sorted(),
            tier: .lite
        )
    }

    private func cancelEssentialsSelection() {
        showEssentialsSelectionReview = false
    }

    private var completeSelectionPurpose: ArkFilePackSelectionPurpose {
        if liteInstaller.hasSavedCompleteAccess { return .downloadOwnedPack }
        return hasEssentialsAccess ? .upgradeFromEssentials : .purchase
    }

    private func confirmCompleteSelection(_ result: ArkFilePackSelectionResult) {
        showCompleteSelectionReview = false
        liteInstaller.includeItemsAndDownload(
            keys: result.selectedMissingItemKeys.sorted(),
            tier: .complete
        )
    }

    private func cancelCompleteSelection() {
        showCompleteSelectionReview = false
    }

    private func handleCompleteInstallAction() {
        switch completeManagementRoute {
        case .resumeDownload:
            if liteInstaller.hasInterruptedInstall(for: .complete) {
                if liteInstaller.state.hasPendingExplicitDownloadRequest {
                    liteInstaller.resumeQueuedDownloads()
                } else {
                    liteInstaller.resumeInterruptedInstallByUser()
                }
            } else {
                liteInstaller.repairComplete()
            }
        case .repairDownload:
            liteInstaller.repairComplete()
        case .manageDownloads:
            presentContentDownloads()
        case .reviewPurchase:
            guard !blocksForAppleAccountCheck else { return }
            if liteInstaller.hasResolvedCurrentStoreKitProof,
               hasEssentialsAccess,
               !liteInstaller.hasCurrentStoreKitProof(for: .lite) {
                beginRestoreForCompletePurchase()
            } else {
                beginPurchaseWithoutDownload(tier: .complete)
            }
        }
    }

    private var shouldRestoreEssentialsToUpgrade: Bool {
        ArkFilePackPurchaseCopy.needsEssentialsRestoreToUpgrade(
            hasEssentialsAccess: hasEssentialsAccess,
            hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsProof: liteInstaller.hasCurrentStoreKitProof(for: .lite)
        )
    }

    private func handlePackComparisonAction(
        tier: ArkFileContentTier,
        currentEssentialsProof: Bool? = nil
    ) {
        let action = ArkFilePackComparisonActionResolver.resolve(
            tier: tier,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: liteInstaller.hasSavedCompleteAccess,
            hasResolvedCurrentStoreKitProof: liteInstaller.hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsStoreKitProof: currentEssentialsProof
                ?? liteInstaller.hasCurrentStoreKitProof(for: .lite),
            hasCurrentCompleteStoreKitProof: liteInstaller.hasCurrentStoreKitProof(for: .complete)
        )
        if action == .manageDownloads {
            closeComparisonAndShowDownloads()
            return
        }
        preservesMapContextAfterComparison = true
        showPackComparison = false
        DispatchQueue.main.async {
            switch action {
            case .restorePurchases:
                if tier == .complete {
                    self.beginRestoreForCompletePurchase()
                } else {
                    self.beginRestore()
                }
            case .manageDownloads:
                self.presentContentDownloads()
            case .purchase(let purchaseTier):
                self.beginPurchaseWithoutDownload(tier: purchaseTier)
            }
        }
    }

    private func beginPurchaseWithoutDownload(tier: ArkFileContentTier) {
        if liteInstaller.purchasePackWithoutDownload(tier: tier) {
            isAwaitingRestoreOutcome = true
        }
    }

    private func prepareEssentialsDownloadWarning(for action: ArkFileEssentialsDownloadAction) {
        pendingEssentialsDownloadAction = action
        showEssentialsDownloadWarning = false
        let estimatedContentBytes = liteInstaller.estimatedSelectedContentBytes(for: action.tier)
        Task {
            let message = action.usesCellularOverride
                ? await ArkFileEssentialsDownloadCopy.cellularWarningMessage(
                    for: action.tier,
                    estimatedContentBytes: estimatedContentBytes
                )
                : await ArkFileEssentialsDownloadCopy.warningMessage()
            await MainActor.run {
                guard pendingEssentialsDownloadAction == action else { return }
                essentialsDownloadWarningMessage = message
                showEssentialsDownloadWarning = true
            }
        }
    }

    private func startPendingEssentialsDownload() {
        switch pendingEssentialsDownloadAction {
        case .restore:
            beginRestore(tier: .lite)
        case .cellularOverride:
            liteInstaller.installLiteAllowingCellularDownload()
        case .completeCellularOverride:
            liteInstaller.installCompleteAllowingCellularDownload()
        case .install:
            if essentialsInstallNeedsRepair {
                liteInstaller.repairLite()
            } else {
                liteInstaller.installLite()
            }
        case .none:
            break
        }
        pendingEssentialsDownloadAction = nil
        essentialsDownloadWarningMessage = ""
    }

    private func updateDownloadRuntimeGuard() {
        ArkFileDownloadRuntimeGuard.keepScreenAwake(
            scenePhase == .active && liteInstaller.canPauseLiteDownload
        )
    }

    private func presentContentDownloads(targetRelativePath: String? = nil) {
        if let navigateScene {
            navigateScene(
                .downloads(relativePath: targetRelativePath)
            )
            return
        }
        NotificationCenter.default.post(name: .arkFileOpenContentDownloads,
            object: nil, userInfo: ["relativePath": targetRelativePath ?? ""])
    }

    private func presentSceneRoute(
        _ route: ArkFileSceneRoute,
        fallback: ArkFileHomeSheet
    ) {
        if let navigateScene {
            navigateScene(route)
        } else if route == .map {
            NotificationCenter.default.post(name: .arkFileOpenMapRegion,
                object: nil, userInfo: ["showDownloads": false])
        } else if route == .library {
            presentContentDownloads()
        } else {
            sheet = fallback
        }
    }

    private func showIncludedSamples() {
        homeLibrarySearchFocused = false
        homeLibraryQuery = ""
        homeLibraryFilter = .includedSamples
        requestLibraryScroll()
    }

    private func browseAllLibrary() {
        homeLibrarySearchFocused = false
        homeLibraryQuery = ""
        homeLibraryFilter = .allContent
        requestLibraryScroll()
    }

    private func requestLibraryScroll() {
        libraryScrollRequest += 1
    }

    private func handleCompletedOnboardingDestination() {
        guard let destination = pendingOnboardingDestination else { return }
        pendingOnboardingDestination = nil
        DispatchQueue.main.async {
            switch destination {
            case .home:
                break
            case .includedSamples:
                showIncludedSamples()
            case .packs:
                presentGeneralPackComparison()
            }
        }
    }

    private func beginRestore(tier: ArkFileContentTier? = nil) {
        if startRestore(tier: tier) {
            pendingPackComparisonTierAfterRestore = nil
        }
    }

    private func beginRestoreForCompletePurchase() {
        if startRestore(tier: nil) {
            pendingPackComparisonTierAfterRestore = .complete
        }
    }

    @discardableResult
    private func startRestore(tier: ArkFileContentTier?) -> Bool {
        let didStart: Bool
        if let tier {
            if tier == .complete {
                didStart = liteInstaller.restoreComplete()
            } else {
                didStart = liteInstaller.restoreOwnedPacks()
            }
        } else {
            didStart = liteInstaller.restoreOwnedPacks()
        }
        if didStart {
            isAwaitingRestoreOutcome = true
        }
        return didStart
    }

    private func chooseDownloadsAfterRestore(outcome: ArkFileContentRestoreOutcome) {
        let continuation = ArkFilePostRestoreContinuation.resolve(
            restoredTier: outcome.tier,
            requestedTier: outcome.requestedTier,
            pendingPurchaseTier: pendingPackComparisonTierAfterRestore
        )
        pendingPackComparisonTierAfterRestore = nil
        DispatchQueue.main.async {
            if let context = mapPurchaseContext,
               continuation != .continueCompletePurchase {
                mapPurchaseContext = nil
                NotificationCenter.default.post(name: .arkFileOpenMapRegion, object: nil,
                    userInfo: ["relativePath": context.relativePath ?? "", "showDownloads": true])
                return
            }
            switch continuation {
            case .chooseDownloads(.complete):
                showCompleteSelectionReview = true
            case .chooseDownloads:
                showEssentialsSelectionReview = true
            case .continueCompletePurchase:
                showPackComparison = true
            }
        }
    }

    private var restoreSuccessActionTitle: String {
        pendingPackComparisonTierAfterRestore == .complete
            ? "Review Upgrade Price"
            : (mapPurchaseContext != nil ? "Choose Map Downloads" : "Choose Downloads")
    }

    private func scrollToLibrary(using scrollProxy: ScrollViewProxy) {
        withAnimation(.easeInOut) {
            scrollProxy.scrollTo(Self.libraryContentSectionID, anchor: .top)
        }
    }

    private func prunePreviewSelections() {
        let itemsByID = Dictionary(
            contentDisplayItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        selectedPreviewItems = selectedPreviewItems.compactMapValues { itemsByID[$0.id] }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.arkTextPrimary)
    }
}

struct ArkFileSurvivalGuideTarget {
    var sectionID: String?
    var blockID: String?
}

enum ArkFileHomeSheet: Identifiable {
    case map
    case preparedness
    case savedWeather
    case survivalGuide(ArkFileSurvivalGuideTarget?)
    case library
    case account
    case localSharing
    case offlineReadiness(autoRunQuickCheck: Bool, requestID: UUID?)

    var ownsInstallerAlerts: Bool {
        if case .library = self { return true }
        return false
    }

    var id: String {
        switch self {
        case .map:
            "map"
        case .preparedness:
            "preparedness"
        case .savedWeather:
            "saved-weather"
        case .survivalGuide(let target):
            "survival-guide-\(target?.blockID ?? target?.sectionID ?? "top")"
        case .library:
            "library"
        case .account:
            "account"
        case .localSharing:
            "local-sharing"
        case .offlineReadiness(let autoRunQuickCheck, let requestID):
            "offline-readiness-\(autoRunQuickCheck ? "auto" : "manual")-\(requestID?.uuidString ?? "direct")"
        }
    }
}

enum ArkFileInstallerAlertPresentation {
    /// A parent must neither present nor clear an alert owned by its library
    /// sheet. SwiftUI may reset the parent's binding as presentations change.
    @MainActor
    static func binding(
        message: @escaping @MainActor @Sendable () -> String?,
        isOwner: @escaping @MainActor @Sendable () -> Bool,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { isOwner() && message() != nil },
            set: { isPresented in
                guard !isPresented, isOwner() else { return }
                dismiss()
            }
        )
    }
}

private struct ArkFileHeroBackgroundImage: View {
    var body: some View {
        Image("ArkFileBackground")
            .resizable()
            .scaledToFill()
            .clipped()
            .accessibilityHidden(true)
    }
}

private struct ArkFileHomeStatusBarShield: View {
    var body: some View {
        GeometryReader { proxy in
            Color.arkAppBackground
                .frame(height: max(proxy.safeAreaInsets.top, 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ArkFileHomeToolButton: View {
    let title: String
    let copy: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkAppBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ArkFileHomeBookmarkEmptyCard: View {
    var body: some View {
        Label {
            Text("No bookmarks yet. Saved articles and reading spots will appear here.")
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "bookmark")
                .font(.headline)
                .foregroundStyle(Color.arkInteractiveForeground)
                .frame(width: 32, height: 32)
                .background(Color.arkPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }
}

private struct ArkFileBookmarkSelectorCard: View {
    let bookmarks: [ArkFileContentBookmark]
    let selectedBookmark: ArkFileContentBookmark?
    let onSelect: (ArkFileContentBookmark) -> Void
    let onOpen: (ArkFileContentBookmark) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bookmark")
                    .font(.headline)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bookmarks")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text("Saved articles and reading spots")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label("\(bookmarks.count) saved", systemImage: "checkmark.circle")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkTextMuted)

            Menu {
                ForEach(bookmarks) { bookmark in
                    Button {
                        onSelect(bookmark)
                    } label: {
                        Label(bookmark.articleTitle, systemImage: bookmark.contentType.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(selectedBookmark?.articleTitle ?? "Browse all bookmarks")
                        .font(.subheadline)
                        .foregroundStyle(selectedBookmark == nil ? Color.arkTextMuted : Color.arkTextPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.arkAppSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.arkAppBorder, lineWidth: 1)
                }
            }
            .tint(Color.arkPrimary)

            if let selectedBookmark {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selectedBookmark.contentType.systemImage)
                            .foregroundStyle(Color.arkInteractiveForeground)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedBookmark.articleTitle)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.arkTextPrimary)
                                .lineLimit(2)
                            Text(selectedBookmark.displaySource)
                                .font(.caption2)
                                .foregroundStyle(Color.arkTextMuted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }

                    Button {
                        onOpen(selectedBookmark)
                    } label: {
                        Label("Open selected bookmark", systemImage: "play.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.arkPrimary)
                }
                .padding(10)
                .background(Color.arkPrimary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectedBookmark == nil ? Color.arkAppBorder : Color.arkPrimary, lineWidth: selectedBookmark == nil ? 1 : 2)
        }
    }
}

struct ArkFileHomeLibrarySheet: View {
    var body: some View {
#if os(iOS)
        ArkFileLibraryDashboard(load: nil)
#else
        Message(text: "ArkFile local content is available in the iOS and iPadOS app.")
#endif
    }
}

private enum ArkFileAccountAuthMode: String, CaseIterable, Identifiable {
    case signIn
    case createAccount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn:
            LocalString.arkfile_account_mode_sign_in
        case .createAccount:
            LocalString.arkfile_account_mode_create_account
        }
    }
}

struct ArkFileAccountSignInSheet: View {
    @ObservedObject var accountSession: ArkFileAccountSession
    @ObservedObject var liteInstaller: ArkFileContentPackInstaller = .shared
    @Binding var accountEmail: String
    @Binding var accountPassword: String
    var restoreEssentials: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var authMode: ArkFileAccountAuthMode = .signIn

    var body: some View {
        Form {
            if !FeatureFlags.arkFileUnifiedAccountUI {
                splitPurchaseInfo
            } else if accountSession.isSignedIn {
                Section {
                    Label(
                        accountSession.hasPurchased
                        ? LocalString.arkfile_account_status_unlocked
                        : LocalString.arkfile_account_status_signed_in,
                        systemImage: accountSession.hasPurchased ? "checkmark.seal.fill" : "person.crop.circle"
                    )
                    .foregroundStyle(accountSession.hasPurchased ? Color.arkPrimaryHover : Color.arkPrimary)
                    if let email = accountSession.user?.email {
                        Text(email)
                            .foregroundStyle(Color.arkTextMuted)
                    }
                }

                Section {
                    Button(LocalString.arkfile_account_button_sign_out, role: .destructive) {
                        accountSession.signOut()
                        liteInstaller.clearTransientPurchaseStatus()
                        dismiss()
                    }
                }

                Section("Account Info") {
                    if accountSession.hasPurchased {
                        Text("ArkFile account access is available for desktop purchases. ArkFile Essentials and Complete purchases are restored through Apple.")
                            .foregroundStyle(.secondary)
                        if let arkFileURL = URL(string: Brand.arkFileSiteURL) {
                            Link(destination: arkFileURL) {
                                Label("Learn more at thearkfile.com", systemImage: "safari")
                            }
                        }
                    } else {
                        Text("ArkFile account access is available for desktop purchases. ArkFile Essentials and Complete purchases are bought or restored through Apple.")
                            .foregroundStyle(.secondary)

                        if Bundle.main.usesSandboxAppStoreReceipt {
                            Text("TestFlight note: creating a Sandbox Apple Account in App Store Connect does not switch this device to it. If Apple shows the wrong Apple Account, cancel, sign out under Media & Purchases, then sign in under Settings > Developer > Sandbox Apple Account. Clear that sandbox tester's purchase history before testing a fresh purchase.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            dismiss()
                            restoreEssentials()
                        } label: {
                            Label(LocalString.arkfile_lite_button_restore, systemImage: "arrow.clockwise")
                        }
                        .disabled(liteInstaller.isBusy)
                    }

                    Button {
                        contactSupport()
                    } label: {
                        Label("Contact Support", systemImage: "envelope")
                    }

                    if (accountSession.isSignedIn || liteInstaller.state.phase.isBusy),
                       let statusText = liteInstaller.statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker(LocalString.arkfile_account_picker_action, selection: $authMode) {
                    ForEach(ArkFileAccountAuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    Text(authMode == .signIn
                         ? LocalString.arkfile_account_prompt
                         : LocalString.arkfile_account_prompt_create)
                        .foregroundStyle(.secondary)
                    TextField(LocalString.arkfile_account_field_email, text: $accountEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(LocalString.arkfile_account_field_password, text: $accountPassword)
                        .textContentType(authMode == .signIn ? .password : .newPassword)
                    if authMode == .createAccount {
                        Text(LocalString.arkfile_account_help_password_minimum)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task {
                            switch authMode {
                            case .signIn:
                                await accountSession.signIn(email: accountEmail, password: accountPassword)
                            case .createAccount:
                                await accountSession.createAccount(email: accountEmail, password: accountPassword)
                            }
                            if accountSession.isSignedIn {
                                liteInstaller.clearTransientPurchaseStatus()
                                dismiss()
                            }
                        }
                    } label: {
                        Label(
                            accountButtonTitle,
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(accountSession.isBusy || accountEmail.isEmpty || accountPassword.isEmpty)

                    if let error = accountSession.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(FeatureFlags.arkFileUnifiedAccountUI ? "Account" : "Apple Purchases")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.arkPrimary)
    }

    private var splitPurchaseInfo: some View {
        Group {
            Section {
                Text("No ArkFile account is needed for ArkFile packs. Buy or restore Essentials or Complete in this app with your Apple Account.")
                    .foregroundStyle(.secondary)
            }

            if accountSession.isSignedIn {
                Section {
                    if let email = accountSession.user?.email {
                        Label(email, systemImage: "person.crop.circle")
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    Button(LocalString.arkfile_account_button_sign_out, role: .destructive) {
                        accountSession.signOut()
                        liteInstaller.clearTransientPurchaseStatus()
                        dismiss()
                    }
                } footer: {
                    Text("ArkFile accounts are for desktop purchases. ArkFile packs restore through Apple.")
                }
            }

            Section {
                Button {
                    dismiss()
                    restoreEssentials()
                } label: {
                    Label(LocalString.arkfile_lite_button_restore, systemImage: "arrow.clockwise")
                }
                .disabled(liteInstaller.isBusy)

                Button {
                    contactSupport()
                } label: {
                    Label("Contact Support", systemImage: "envelope")
                }
            }

            if let statusText = liteInstaller.statusText {
                Section {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accountButtonTitle: String {
        switch (authMode, accountSession.isBusy) {
        case (.signIn, true):
            LocalString.arkfile_account_button_signing_in
        case (.signIn, false):
            LocalString.arkfile_account_button_sign_in
        case (.createAccount, true):
            LocalString.arkfile_account_button_creating_account
        case (.createAccount, false):
            LocalString.arkfile_account_button_create_account
        }
    }

    private func contactSupport() {
        let body = """
        ArkFile account: \(accountSession.user?.email ?? "not signed in")

        What happened:

        """
        guard let subject = "ArkFile Account Help".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "mailto:\(Brand.feedbackEmail)?subject=\(subject)&body=\(encodedBody)") else {
            return
        }
        openURL(url)
    }
}

#endif

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeCatalog(viewState: .loading).environmentObject(LibraryViewModel()).preferredColorScheme(.light).padding()
        WelcomeCatalog(viewState: .error).environmentObject(LibraryViewModel()).preferredColorScheme(.dark).padding()
    }
}
