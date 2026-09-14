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

enum ArkFileContentSubcategoryOrder {
    static func travelGuidesFirst<T>(
        _ values: [T],
        name: (T) -> String
    ) -> [T] {
        values.filter { name($0) == "Travel Guides" }
            + values.filter { name($0) != "Travel Guides" }
    }
}

/// Displays a grid of available local ZIM files. Used on new tab.
struct LocalLibraryList: View {
    private let load: (URL) -> Void
    private let canPresentInstallerAlerts: @MainActor @Sendable () -> Bool
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Bookmark.created, ascending: false)],
        animation: .easeInOut
    ) private var bookmarks: FetchedResults<Bookmark>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.openedPredicate(),
        animation: .easeInOut
    ) private var zimFiles: FetchedResults<ZimFile>

    init(
        browser: BrowserViewModel,
        canPresentInstallerAlerts: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        load = browser.load(url:)
        self.canPresentInstallerAlerts = canPresentInstallerAlerts
    }

    var body: some View {
#if os(iOS)
        ArkFileLibraryDashboard(
            load: load,
            canPresentInstallerAlerts: canPresentInstallerAlerts
        )
#else
        LazyVGrid(
            columns: ([GridItem(.adaptive(minimum: 250, maximum: 500), spacing: 12)]),
            alignment: .leading,
            spacing: 12
        ) {
            if !zimFiles.isEmpty {
                GridSection(title: LocalString.welcome_main_page_title) {
                    ForEach(zimFiles, id: \.fileID) { zimFile in
                        AsyncButtonView {
                            guard let url = await ZimFileService.shared
                                .getMainPageURL(zimFileID: zimFile.fileID) else { return }
                            load(url)
                        } label: {
                            ZimFileCell(zimFile, prominent: .name, isSelected: false)
                        } loading: {
                            ZimFileCell(zimFile, prominent: .name, isSelected: true, isLoading: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !bookmarks.isEmpty {
                GridSection(title: LocalString.welcome_grid_bookmarks_title) {
                    ForEach(bookmarks.prefix(6)) { bookmark in
                        Button {
                            load(bookmark.articleURL)
                        } label: {
                            ArticleCell(bookmarkData: BookmarkArticleData(from: bookmark))
                        }
                        .buttonStyle(.plain)
                        .modifier(BookmarkContextMenu(bookmark: bookmark))
                    }
                }
            }
        }
        .modifier(GridCommon(edges: .all))
#endif
    }
}

#if os(iOS)
struct ArkFileHomeLogoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(Brand.loadingLogoImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.arkAccent.opacity(0.75), lineWidth: 1)
                }
                .shadow(color: Color.arkTextPrimary.opacity(0.16), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ArkFile Home")
    }
}

enum ArkFileLibraryInitialSection: Hashable {
    case top
    case saved
}

struct ArkFileLibraryDashboard: View {
    let load: ((URL) -> Void)?
    let showOpenFile: Bool
    let initialSection: ArkFileLibraryInitialSection
    let navigateScene: ((ArkFileSceneRoute) -> Void)?
    let openSceneContent:
        ((ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void)?
    let canPresentInstallerAlerts: @MainActor @Sendable () -> Bool

    init(
        load: ((URL) -> Void)?,
        showOpenFile: Bool = true,
        initialSection: ArkFileLibraryInitialSection = .top,
        navigateScene: ((ArkFileSceneRoute) -> Void)? = nil,
        openSceneContent:
            ((ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void)? = nil,
        canPresentInstallerAlerts: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.load = load
        self.showOpenFile = showOpenFile
        self.initialSection = initialSection
        self.navigateScene = navigateScene
        self.openSceneContent = openSceneContent
        self.canPresentInstallerAlerts = canPresentInstallerAlerts
    }

    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared
    @StateObject private var favorites = ArkFileContentFavorites.shared
    @StateObject private var contentBookmarks = ArkFileContentBookmarks.shared
    @StateObject private var accountSession = ArkFileAccountSession.shared
    @StateObject private var liteInstaller = ArkFileContentPackInstaller.shared
    @ObservedObject private var readinessChecker = ArkFileOfflineReadinessChecker.shared
    @ObservedObject private var readinessCoordinator = ArkFileOfflineReadinessCoordinator.shared
    @State private var selectedItems: [String: ArkFileLibraryContentItem] = [:]
    @State private var selectedBookmark: ArkFileContentBookmark?
    @State private var activeReaderDestination: ArkFileContentReaderDestination?
    @State private var lockedPreviewItem: ArkFileLibraryContentItem?
    @State private var openingItemID: String?
    @State private var openError: String?
    @State private var isRefreshing = true
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var sheet: ArkFileHomeSheet?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var pendingEssentialsDownloadAction: ArkFileEssentialsDownloadAction?
    @State private var showEssentialsDownloadWarning = false
    @State private var essentialsDownloadWarningMessage = ""
    @State private var showCancelCurrentDownloadConfirmation = false
    @State private var showEssentialsSelectionReview = false
    @State private var showCompleteSelectionReview = false
    @State private var showPackComparison = false
    @State private var isAwaitingRestoreOutcome = false
    @State private var pendingPackComparisonTierAfterRestore: ArkFileContentTier?
    @State private var showEssentialsManage = false
    @State private var contentDownloadsTargetRelativePath: String?
    @State private var contentCatalog: ArkFileContentCatalog?
    @State private var libraryScrollRequestID = 0
    @State private var didApplyInitialSection = false

    private static let libraryContentSectionID = "arkfile-library-content"
    private static let savedContentSectionID = "arkfile-saved-content"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesSingleColumnLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var columns: [GridItem] {
        ArkFileAdaptiveCardGrid.columns(
            isAccessibilitySize: usesSingleColumnLayout,
            standardMinimum: 300,
            spacing: 12
        )
    }

    private var toolColumns: [GridItem] {
        ArkFileAdaptiveCardGrid.columns(
            isAccessibilitySize: usesSingleColumnLayout,
            standardMinimum: 150,
            spacing: 10
        )
    }

    var body: some View {
        Group {
            if initialSection == .top {
                ArkFileContentBrowserView(openItem: open, dismissOnOpen: false)
                    .accessibilityIdentifier("arkfile_library_root")
            } else {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if FeatureFlags.savedWeather {
                        ArkFileSavedWeatherHomeCard {
                            presentSceneRoute(
                                .savedWeather,
                                fallback: .savedWeather
                            )
                        }
                    }
                    essentialsInstallSection
                    libraryContentSection
                    baseAppTools(scrollProxy: scrollProxy)
                    offlineReadinessSection
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 18)
                .padding(.top, 20)
                .padding(.bottom, 42)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .accessibilityIdentifier("arkfile_library_root")
            }
            .background(Color.arkAppBackground.ignoresSafeArea())
            .navigationTitle("ArkFile")
            .navigationBarTitleDisplayMode(.large)
            .tint(Color.arkPrimary)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    if showOpenFile {
                        OpenFileButton(context: .welcomeScreen) {
                            Label(LocalString.welcome_actions_open_file, systemImage: "folder")
                        }
                    }
                }
            }
            .onChange(of: libraryScrollRequestID) { _, _ in
                scrollToLibrary(using: scrollProxy)
            }
            .onChange(of: isRefreshing) { _, newValue in
                guard !newValue else { return }
                scrollToInitialSectionIfNeeded(using: scrollProxy)
            }
        }
            }
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
            case .library:
                toolSheet {
                    ArkFileHomeLibrarySheet()
                }
            case .localSharing:
                toolSheet {
                    HotspotZimFilesSelection()
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
            primaryAction: { item, tier in
                handleLockedPreviewAction(for: item, resolvedTier: tier)
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
            cancel: { pendingPackComparisonTierAfterRestore = nil }
        )
        .sheet(isPresented: $showEssentialsSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .lite,
                    confirmTitle: "Start Download",
                    managementMode: liteInstaller.hasSavedLiteAccess,
                    purpose: liteInstaller.hasSavedLiteAccess ? .downloadOwnedPack : .purchase,
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .lite),
                    onConfirm: { result in
                        showEssentialsSelectionReview = false
        liteInstaller.includeItemsAndDownload(
            keys: result.selectedMissingItemKeys.sorted(),
            tier: .lite
        )
                    },
                    onCancel: {
                        showEssentialsSelectionReview = false
                    }
                )
            }
        }
        .sheet(isPresented: $showPackComparison) {
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
                    chooseEssentials: {
                        handlePackComparisonAction(tier: .lite)
                    },
                    chooseComplete: { currentEssentialsProof in
                        handlePackComparisonAction(
                            tier: .complete,
                            currentEssentialsProof: currentEssentialsProof
                        )
                    },
                    manageDownloads: {
                        showPackComparison = false
                        DispatchQueue.main.async {
                            presentContentDownloads()
                        }
                    },
                    restorePurchases: {
                        showPackComparison = false
                        pendingPackComparisonTierAfterRestore = nil
                        DispatchQueue.main.async {
                            beginRestore()
                        }
                    }
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
        .sheet(isPresented: $showCompleteSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .complete,
                    confirmTitle: "Download Selected",
                    managementMode: liteInstaller.hasSavedCompleteAccess,
                    purpose: liteInstaller.hasSavedCompleteAccess
                        ? .downloadOwnedPack
                        : (hasEssentialsAccess ? .upgradeFromEssentials : .purchase),
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .complete),
                    onConfirm: { result in
                        showCompleteSelectionReview = false
        liteInstaller.includeItemsAndDownload(
            keys: result.selectedMissingItemKeys.sorted(),
            tier: .complete
        )
                    },
                    onCancel: {
                        showCompleteSelectionReview = false
                    }
                )
            }
        }
        .sheet(isPresented: $showEssentialsManage) {
            NavigationStack {
                ArkFileContentBrowserView(
                    openItem: open,
                    initialTargetRelativePath: contentDownloadsTargetRelativePath
                )
                .id(contentDownloadsTargetRelativePath ?? "all")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showEssentialsManage = false
                                contentDownloadsTargetRelativePath = nil
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
        }
        .alert(
            "Purchase Status",
            isPresented: ArkFileInstallerAlertPresentation.binding(
                message: { liteInstaller.purchaseHelpMessage },
                isOwner: {
                    initialSection != .top
                        && canPresentInstallerAlerts()
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
                    initialSection != .top
                        && canPresentInstallerAlerts()
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
                    await refresh()
                }
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("The unfinished download will be removed. Installed titles stay available, and you can download this title again later.")
        }
        .alert(
            "Could not open content",
            isPresented: openErrorPresentation
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
        .task {
            await refresh()
            updateDownloadRuntimeGuard()
            await readinessChecker.refreshCachedState()
            if FeatureFlags.arkFileUnifiedAccountUI {
                await accountSession.refreshIfSignedIn()
            }
            presentReadinessRequestIfNeeded()
        }
        .onChange(of: scenePhase) { _, _ in
            updateDownloadRuntimeGuard()
        }
        .onChange(of: liteInstaller.state.phase) { _, _ in
            updateDownloadRuntimeGuard()
            Task {
                await readinessChecker.refreshCachedState()
            }
        }
        .onChange(of: readinessCoordinator.presentationRequest?.id) { _, _ in
            presentReadinessRequestIfNeeded()
        }
        .onChange(of: contentLibrary.libraryCategories) { _, _ in
            pruneSelections()
        }
        .onDisappear {
            ArkFileDownloadRuntimeGuard.keepScreenAwake(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileGoHome)) { _ in
            sheet = nil
            activeReaderDestination = nil
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenMapLocation)) { _ in
            guard ArkFileAdaptiveNotificationRoutePolicy
                .embeddedViewHandles(
                    .arkFileOpenMapLocation,
                    device: Device.current
                ) else {
                return
            }
            activeReaderDestination = nil
            presentSceneRoute(.map, fallback: .map)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileImportMapGPX)) { _ in
            guard ArkFileAdaptiveNotificationRoutePolicy
                .embeddedViewHandles(
                    .arkFileImportMapGPX,
                    device: Device.current
                ) else {
                return
            }
            activeReaderDestination = nil
            presentSceneRoute(.map, fallback: .map)
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
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenPackComparison)) { _ in
            showPackComparison = true
        }
    }

    private var openErrorPresentation: Binding<Bool> {
        Binding(
            get: { openError != nil },
            set: { isPresented in
                if !isPresented {
                    openError = nil
                }
            }
        )
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

    private var header: some View {
        let logo = Image(Brand.loadingLogoImage)
            .resizable()
            .scaledToFit()
            .frame(width: usesSingleColumnLayout ? 56 : 62, height: usesSingleColumnLayout ? 56 : 62)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.arkAccent.opacity(0.75), lineWidth: 1)
            }

        let copy = VStack(alignment: .leading, spacing: 7) {
            Text("CURRENT CONTENT PACK")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkTextMuted)
            Text("Local ArkFile Content")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Color.arkTextPrimary)
            Text(headerSummary)
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }

        return Group {
            if usesSingleColumnLayout {
                VStack(alignment: .leading, spacing: 12) {
                    logo
                    copy
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    logo
                    copy
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private var headerSummary: String {
        let accessTotals = contentAccessTotals
        let installedCount = accessTotals.installed
        let notDownloadedCount = accessTotals.notDownloaded
        let lockedCount = accessTotals.locked
        if installedCount == 0 && notDownloadedCount == 0 && lockedCount == 0 {
            return "Buy or restore ArkFile Essentials, or open local content, to browse ArkFile categories."
        }
        if essentialsInstallNeedsRepair {
            return installedCount > 0
                ? "\(installedCount) Essentials title\(installedCount == 1 ? "" : "s") already available. Continue Download to finish the rest."
                : incompleteEssentialsCopy
        }
        if installedCount == 0 {
            if lockedCount > 0 && notDownloadedCount > 0 {
                return "\(lockedCount) title\(lockedCount == 1 ? "" : "s") still locked. \(notDownloadedCount) more \(notDownloadedCount == 1 ? "is" : "are") available to download."
            }
            if notDownloadedCount > 0 {
                return "\(notDownloadedCount) title\(notDownloadedCount == 1 ? "" : "s") ready to download. Manage Downloads lets you add them to this device."
            }
            return "\(lockedCount) locked title\(lockedCount == 1 ? "" : "s") listed before you unlock and download an offline pack."
        }
        if lockedCount > 0 && notDownloadedCount > 0 {
            return "\(installedCount) installed, \(notDownloadedCount) more available to download, and \(lockedCount) title\(lockedCount == 1 ? "" : "s") still locked."
        }
        if notDownloadedCount > 0 {
            return "\(installedCount) installed · \(notDownloadedCount) more available to download."
        }
        if lockedCount > 0 {
            return "\(installedCount) installed and \(lockedCount) title\(lockedCount == 1 ? "" : "s") still locked. Buy or restore the required pack to add the rest."
        }
        let rootLabel = contentLibrary.contentRoot?.lastPathComponent ?? "local content"
        return "\(installedCount) items available from \(rootLabel), organized by ArkFile category folders."
    }

    private func baseAppTools(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Included Tools")
            LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 10) {
                ArkFileHomeToolButton(
                    title: "Library",
                    copy: "Browse Essentials content and local files.",
                    systemImage: "books.vertical",
                    tint: Color.arkPrimary
                ) {
                    if let navigateScene {
                        navigateScene(.library)
                    } else {
                        activeReaderDestination = nil
                        Task { await refresh() }
                        withAnimation(.easeInOut) {
                            scrollProxy.scrollTo(
                                Self.libraryContentSectionID,
                                anchor: .top
                            )
                        }
                    }
                }
                ArkFileHomeToolButton(
                    title: "Map",
                    copy: "Open the offline vector map and installed Essentials map detail.",
                    systemImage: "map",
                    tint: Color.arkPrimaryHover
                ) {
                    presentSceneRoute(.map, fallback: .map)
                }
                if FeatureFlags.savedWeather {
                    ArkFileHomeToolButton(
                        title: "Weather",
                        copy: "Keep the last NOAA forecast and alert check available offline.",
                        systemImage: "sun.max",
                        tint: Color.arkAccent
                    ) {
                        presentSceneRoute(
                            .savedWeather,
                            fallback: .savedWeather
                        )
                    }
                }
                ArkFileHomeToolButton(
                    title: "Preparedness",
                    copy: "Open checklists and planning tools.",
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
                    copy: "Search and explore emergency field guidance.",
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
                    copy: "Share included ArkFile content with nearby devices.",
                    systemImage: "wifi",
                    tint: Color.arkPrimaryHover
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

    @ViewBuilder
    private var essentialsInstallSection: some View {
        if shouldShowPackInstallSection {
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
                comparePacksButton
                if shouldShowCompletePackCard {
                    completePackCard
                } else {
                    essentialsPackCard
                }
            }
        }
    }

    private var comparePacksButton: some View {
        Button {
            showPackComparison = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.2.swap")
                    .foregroundStyle(Color.arkAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Essentials and Complete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                    Text("Compare one-time prices, catalog scope, and download choices.")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.arkAccent.opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("arkfile_library_compare_packs_action")
    }

    private var shouldShowPackInstallSection: Bool {
        contentLibrary.lockedLibraryItemCount > 0
            || liteInstaller.state.phase.isBusy
            || liteInstaller.state.phase == .failed
            || liteInstaller.hasInstalledOrPartialContent
            || liteInstaller.installedTier != .complete
    }

    private var shouldShowCompletePackCard: Bool {
        liteInstaller.hasSavedCompleteAccess
            || liteInstaller.installedTier == .complete
            || liteInstaller.state.tier == .complete
            || completeInstallNeedsRepair
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

    private var essentialsPackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(essentialsInstallTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(essentialsInstallCopy)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                    || (
                        liteInstaller.state.phase == .installed
                            && !essentialsInstallNeedsRepair
                    )
            )

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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(liteInstaller.isBusy)
            }

            if shouldShowLiteStatusText,
               liteInstaller.state.tier != .complete,
               let statusText = liteInstaller.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if liteInstaller.state.tier != .complete,
               let progress = liteInstaller.state.progressFraction,
               liteInstaller.shouldShowProgressBar {
                ProgressView(value: progress)
            }
            if liteInstaller.state.tier != .complete {
                downloadInterruptionControls
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
    }

    private var completePackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.title3)
                    .foregroundStyle(Color.arkLockedForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkAccentSecondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(completeInstallTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(completeInstallCopy)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAccentSecondary.opacity(0.28), lineWidth: 1)
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

    private var litePrimaryButtonTitle: String {
        if essentialsInstallNeedsRepair {
            return "Continue Download"
        }
        if liteInstaller.state.phase == .installed {
            return LocalString.arkfile_lite_button_installed
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

    private var essentialsInstallCopy: String {
        if essentialsInstallNeedsRepair {
            return incompleteEssentialsCopy
        }
        if shouldUseRestoreForEssentialsAction {
            return "App Store purchase confirmed. Restore Purchases re-checks access without downloading; you choose Essentials downloads afterward."
        }
        if liteInstaller.state.phase == .installed {
            return packMetrics.essentialsReadyLine
        }
        if let resumableInstallCopy = liteInstaller.resumableInstallCopy(for: .lite) {
            return resumableInstallCopy
        }
        if liteInstaller.state.phase.isBusy {
            return "Essentials is downloading. ArkFile will keep the files already downloaded if this is interrupted."
        }
        if hasEssentialsAccess {
            return "Essentials is unlocked. Choose the titles you want on this device and add more whenever you need them."
        }
        if blocksForAppleAccountCheck, !hasEssentialsAccess {
            return "ArkFile is checking this Apple Account before showing purchase or download choices."
        }
        if contentLibrary.sampleLibraryItemCount > 0 {
            return "Sample content is included with the app. Buy Essentials once with your Apple Account to unlock the full ArkFile pack."
        }
        return "Unlock Essentials with one purchase. Download only what you need, when you need it."
    }

    private var incompleteEssentialsCopy: String {
        "Essentials download did not finish. Continue Download to pick up where it left off."
    }

    private var essentialsInstallTitle: String {
        if essentialsInstallNeedsRepair {
            return "Continue Download"
        }
        if liteInstaller.state.phase == .installed {
            return "\(installedEssentialsTitleCount) Essentials title\(installedEssentialsTitleCount == 1 ? "" : "s") available offline"
        }
        if blocksForAppleAccountCheck, !hasEssentialsAccess {
            return "Checking Apple purchases…"
        }
        let lockedCount = contentLibrary.lockedLibraryItemCount
        if lockedCount > 0 {
            return "\(lockedCount) Essentials title\(lockedCount == 1 ? "" : "s") available in the ArkFile pack"
        }
        if liteInstaller.hasInstalledOrPartialContent {
            return "Essentials is on this device"
        }
        return "ArkFile Essentials"
    }

    private var completeInstallTitle: String {
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
        if blocksForAppleAccountCheck, !hasEssentialsAccess {
            return "Checking Apple purchases…"
        }
        return "Buy ArkFile Complete"
    }

    private var completeInstallCopy: String {
        if liteInstaller.hasSavedCompleteAccess {
            let summary = completeOwnershipMetrics.purchasedSummary
            return completeInstallNeedsRepair
                ? "\(summary) A download needs attention; everything already here is unchanged."
                : summary
        }
        if completeInstallNeedsRepair {
            return "Complete download did not finish. Continue Download to pick up where it left off."
        }
        if liteInstaller.state.tier == .complete, let resumableInstallCopy = liteInstaller.resumableInstallCopy {
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

    private var litePrimaryButtonSystemImage: String {
        if essentialsInstallNeedsRepair {
            return "arrow.clockwise.circle"
        }
        if liteInstaller.state.phase == .installed {
            return "checkmark.circle"
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
        if liteInstaller.hasResumableDownload(for: .lite) {
            return "arrow.clockwise.circle"
        }
        if hasEssentialsAccess || liteInstaller.state.phase.isBusy {
            return "arrow.down.circle"
        }
        return "lock.open"
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

    private var canStartEssentialsInstall: Bool {
        true
    }

    private var shouldUseRestoreForEssentialsAction: Bool {
        liteInstaller.hasPendingStoreKitPurchase || liteInstaller.hasTransientPurchaseStatus
    }

    private var hasEssentialsAccess: Bool {
        liteInstaller.hasSavedLiteAccess || Brand.hasDeveloperContentAuthToken
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
            || liteInstaller.state.phase.isBusy
            || liteInstaller.state.phase == .readyToDownload
            || liteInstaller.state.phase == .failed
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
        if sheet != nil {
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

    private var libraryContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .overlay(Color.arkAppBorder)
                .padding(.top, 2)
            sectionTitle("Library")

            if isRefreshing {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 36)
            } else if contentLibrary.hasLibraryContent {
                savedContentSection
                contentCategoryCards
            } else {
                emptyState
            }
        }
        .id(Self.libraryContentSectionID)
    }

    private var savedContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            favoritesSection
            bookmarksSection
        }
        .id(Self.savedContentSectionID)
        .accessibilityIdentifier("arkfile_saved_section")
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Favorites")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ArkFileContentSelectorCard(
                    title: "Favorites",
                    description: "Favorited archives and files",
                    systemImage: "star",
                    accent: Color.arkAccent,
                    items: favorites.favoriteItems(in: contentLibrary.categories).map {
                        ArkFileLibraryContentItem(installed: $0)
                    },
                    selectedItem: selectedItems["favorites"],
                    emptyMessage: "No favorites yet. Open content and mark it as a favorite.",
                    isOpening: openingItemID == selectedItems["favorites"]?.id,
                    resolutionInput: lockedResolutionInput,
                    lockedNoticeTitle: lockedSelectorNoticeTitle,
                    lockedSelectedMessage: { lockedSelectorSelectedMessage(for: $0) },
                    lockedButtonTitle: { lockedSelectorButtonTitle(for: $0) },
                    lockedButtonSystemImage: { lockedSelectorButtonSystemImage(for: $0) },
                    onSelect: { selectedItems["favorites"] = $0 },
                    onOpen: open
                )
            }
        }
        .accessibilityIdentifier("arkfile_favorites_section")
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Bookmarks")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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

    private var contentCategoryCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Categories")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(contentDisplaySections) { section in
                    ArkFileContentSelectorCard(
                        title: section.group.displayName,
                        description: description(for: section.group),
                        systemImage: section.group.systemImage,
                        accent: accent(for: section.group),
                        items: section.items,
                        selectedItem: selectedItems[section.group.id],
                        emptyMessage: "This library does not include \(section.group.displayName.lowercased()) content yet.",
                        isOpening: openingItemID == selectedItems[section.group.id]?.id,
                        resolutionInput: lockedResolutionInput,
                        lockedNoticeTitle: lockedSelectorNoticeTitle,
                        lockedSelectedMessage: { lockedSelectorSelectedMessage(for: $0) },
                        lockedButtonTitle: { lockedSelectorButtonTitle(for: $0) },
                        lockedButtonSystemImage: { lockedSelectorButtonSystemImage(for: $0) },
                        onSelect: { selectedItems[section.group.id] = $0 },
                        onOpen: open
                    )
                }
            }
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

    private var contentAccessTotals: (installed: Int, notDownloaded: Int, locked: Int) {
        contentDisplaySections.reduce(into: (installed: 0, notDownloaded: 0, locked: 0)) { totals, section in
            totals.installed += section.summary.installedCount
            totals.notDownloaded += section.summary.notDownloadedCount
            totals.locked += section.summary.lockedCount
        }
    }

    private var contentDisplayItems: [ArkFileLibraryContentItem] {
        contentDisplaySections.flatMap(\.items)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No local library installed",
            systemImage: "books.vertical",
            description: Text("Buy or restore Essentials, download the pack, or open a local file to start reading.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.arkTextPrimary)
    }

    private func refresh() async {
        isRefreshing = true
        contentCatalog = await Task.detached(priority: .utility) {
            try? ArkFileContentCatalog.loadBundled()
        }.value
        await contentLibrary.refresh()
        pruneSelections()
        isRefreshing = false
    }

    private func pruneSelections() {
        let itemsByID = Dictionary(
            contentDisplayItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        selectedItems = selectedItems.compactMapValues { itemsByID[$0.id] }
    }

    private func open(_ item: ArkFileLibraryContentItem) {
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
            lockedPreviewItem = item
            return
        }
        open(localItem)
    }

    private func open(_ item: ArkFileLocalContentItem) {
        openingItemID = nil
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
            await openZim(item, continuing: readerOpenIntent)
        }
    }

    private func openBookmark(_ bookmark: ArkFileContentBookmark) {
        openingItemID = nil
        guard let item = contentLibrary.allItems.first(where: { $0.relativePath == bookmark.relativePath }) else {
            openError = "ArkFile could not find \(bookmark.fileName) in the local library."
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
            openingItemID = item.id
            defer {
                if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                    openingItemID = nil
                }
            }
            switch await ArkFileSavedZIMResolver.resolve(bookmark: bookmark, item: item) {
            case .success(let destination):
                guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                    return
                }
                if let load {
                    openingItemID = nil
                    load(destination.url)
                } else {
                    NotificationCenter.openURL(destination.url, continuing: readerOpenIntent)
                    dismiss()
                }
            case .failure(let failure):
                guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                    return
                }
                openError = failure.message(itemName: item.displayName)
            }
        }
    }

    private func openContentItemFromViewer(
        _ item: ArkFileLocalContentItem,
        bookmark: ArkFileContentBookmark?
    ) {
        openingItemID = nil
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
            Task { await openZim(item, continuing: readerOpenIntent) }
        }
    }

    private func openZim(
        _ item: ArkFileLocalContentItem,
        continuing readerOpenIntent: ArkFileReaderOpenIntent
    ) async {
        openingItemID = item.id
        defer {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                openingItemID = nil
            }
        }
        guard let fileID = await LibraryOperations.openFileID(url: item.url) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                openError = "ArkFile could not register \(item.displayName) as readable content."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard await ZimFileService.shared.openArchive(zimFileID: fileID) != nil else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                openError = "ArkFile could not open the current local copy of \(item.displayName)."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard let mainPageURL = await ZimFileService.shared.getMainPageURL(zimFileID: fileID) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                openError = "ArkFile opened \(item.displayName), but could not find its main page."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        if let load {
            openingItemID = nil
            load(mainPageURL)
        } else {
            NotificationCenter.openURL(mainPageURL, continuing: readerOpenIntent)
            dismiss()
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

    private func handleLockedPreviewAction(for item: ArkFileLibraryContentItem) {
        let tier = downloadTier(for: item)
        if tier == .complete {
            handleCompleteInstallAction()
        } else {
            handleEssentialsInstallAction()
        }
    }

    private func handleLockedPreviewAction(
        for item: ArkFileLibraryContentItem,
        resolvedTier: ArkFileContentTier
    ) {
        if resolvedTier == .complete {
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

    private func canDownloadItemIndividually(_ item: ArkFileLibraryContentItem) -> Bool {
        let tier = downloadTier(for: item)
        return !item.isInstalled
            && !item.isSampleContent
            && hasSavedAccess(for: tier)
            && !liteInstaller.isBusy
            && !installNeedsRepair(for: tier)
    }

    private func handleEssentialsInstallAction() {
        if liteInstaller.state.phase == .installed && !essentialsInstallNeedsRepair {
            presentContentDownloads()
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
            : "Choose Downloads"
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

    private func requestLibraryScroll() {
        libraryScrollRequestID += 1
    }

    private func scrollToLibrary(using scrollProxy: ScrollViewProxy) {
        withAnimation(.easeInOut) {
            scrollProxy.scrollTo(Self.libraryContentSectionID, anchor: .top)
        }
    }

    private func scrollToInitialSectionIfNeeded(
        using scrollProxy: ScrollViewProxy
    ) {
        guard !didApplyInitialSection else { return }
        didApplyInitialSection = true
        guard initialSection == .saved else { return }
        withAnimation(.easeInOut) {
            scrollProxy.scrollTo(Self.savedContentSectionID, anchor: .top)
        }
    }

    private func presentContentDownloads(targetRelativePath: String? = nil) {
        if let navigateScene {
            navigateScene(
                .downloads(relativePath: targetRelativePath)
            )
            return
        }
        contentDownloadsTargetRelativePath = targetRelativePath
        showEssentialsManage = true
    }

    private func presentSceneRoute(
        _ route: ArkFileSceneRoute,
        fallback: ArkFileHomeSheet
    ) {
        if let navigateScene {
            navigateScene(route)
        } else {
            sheet = fallback
        }
    }

    private func description(for group: ArkFileContentDisplayGroup) -> String {
        switch group {
        case .general:
            "Wikipedia and general reference"
        case .medical:
            "Medical references and first aid guides"
        case .foodPreparation:
            "Cooking, canning, and food preservation"
        case .travel:
            "Travel guides, destination info, and offline maps"
        case .streetMaps:
            "Downloadable regional street-level map packs"
        case .booksDocuments:
            "Core books, documents, field manuals, and classics"
        case .educationalTextbooks:
            "Open textbooks for structured offline study"
        }
    }

    private func accent(for group: ArkFileContentDisplayGroup) -> Color {
        switch group {
        case .general:
            Color.arkPrimary
        case .medical:
            Color.arkPrimaryHover
        case .foodPreparation:
            Color.arkAccentSecondary
        case .travel:
            Color.arkPrimary
        case .streetMaps:
            Color.arkPrimaryHover
        case .booksDocuments:
            Color.arkAccent
        case .educationalTextbooks:
            Color.arkPrimaryHover
        }
    }
}

private struct ArkFileHomeBookmarkCard: View {
    let bookmark: ArkFileContentBookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: bookmark.contentType.systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 32, height: 32)
                    .background(Color.arkPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.articleTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.arkTextPrimary)
                        .lineLimit(2)
                    Text(bookmark.displaySource)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .lineLimit(1)
                }
            }
            if !bookmark.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(bookmark.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.arkAccent.opacity(0.18))
                            .foregroundStyle(Color.arkTextPrimary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bookmark")
                    .font(.headline)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 34, height: 34)
                    .background(Color.arkPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
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

            if bookmarks.isEmpty {
                Text("No bookmarks yet. Open content and add bookmarks with tags or notes.")
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
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

struct ArkFileContentSelectorCard: View {
    let title: String
    let description: String
    let systemImage: String
    let accent: Color
    let items: [ArkFileLibraryContentItem]
    let selectedItem: ArkFileLibraryContentItem?
    let emptyMessage: String
    let isOpening: Bool
    var resolutionInput: ArkFileLockedContentResolutionInput?
    let lockedNoticeTitle: String
    let lockedSelectedMessage: (ArkFileLibraryContentItem) -> String
    let lockedButtonTitle: (ArkFileLibraryContentItem) -> String
    let lockedButtonSystemImage: (ArkFileLibraryContentItem) -> String
    let onSelect: (ArkFileLibraryContentItem) -> Void
    let onOpen: (ArkFileLibraryContentItem) -> Void
    var onBrowse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                Label(countSummary, systemImage: countSummaryIcon)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkTextMuted)

                if !featuredItems.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(featuredItems) { item in
                            Button {
                                onSelect(item)
                                onOpen(item)
                            } label: {
                                itemPreviewRow(item)
                            }
                            .buttonStyle(.plain)

                            if item.id != featuredItems.last?.id {
                                Divider()
                                    .overlay(Color.arkAppBorder)
                                    .padding(.leading, 42)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if hasLockedItems && onBrowse == nil {
                    Label(lockedNoticeTitle, systemImage: "lock.fill")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.arkLockedForeground)
                }

                if let onBrowse {
                    Button(action: onBrowse) {
                        HStack {
                            Text("Browse \(title)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .accessibilityLabel("Browse \(title)")
                } else {
                Menu {
                    ForEach(offlineGroupedItems, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    menuLabel(for: item)
                                }
                            }
                        }
                    }
                    if !readyToDownloadItems.isEmpty {
                        Section("Ready to Download") {
                            ForEach(readyToDownloadItems) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    menuLabel(for: item)
                                }
                            }
                        }
                    }
                    if hasLockedItems {
                        Section("Locked") {
                            ForEach(lockedItems) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    menuLabel(for: item)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(selectedItem?.displayName ?? "Browse all \(title.lowercased())")
                            .font(.subheadline)
                            .foregroundStyle(selectedItemColor)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
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

                }

                if onBrowse == nil, let selectedItem {
                    let selectedAccessState = accessState(for: selectedItem)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: iconName(for: selectedItem))
                                .foregroundStyle(accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selectedItem.displayName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(itemTitleColor(for: selectedItem))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(selectedItemStatusLine)
                                    .font(.caption2)
                                    .foregroundStyle(Color.arkTextMuted)
                            }
                            Spacer(minLength: 0)
                        }

                        if selectedAccessState == .downloadable || selectedAccessState == .locked {
                            Text(lockedSelectedMessage(selectedItem))
                                .font(.caption)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            onOpen(selectedItem)
                        } label: {
                            HStack {
                                if isOpening && selectedAccessState == .installed {
                                    ProgressView()
                                } else {
                                    Image(systemName: buttonSystemImage(for: selectedItem, accessState: selectedAccessState))
                                }
                                Text(buttonTitle(for: selectedItem))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.arkPrimary)
                        .disabled(isOpening && selectedAccessState == .installed)
                    }
                    .padding(10)
                    .background(accent.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectedItem == nil ? Color.arkAppBorder : accent, lineWidth: selectedItem == nil ? 1 : 2)
        }
    }

    private var countSummary: String {
        let installedCount = items.filter { accessState(for: $0) == .installed }.count
        let sampleCount = items.filter { accessState(for: $0) == .sample }.count
        let notDownloadedCount = items.filter { accessState(for: $0) == .downloadable }.count
        let lockedCount = items.filter { accessState(for: $0) == .locked }.count
        let missingParts = missingSummaryParts(
            lockedCount: lockedCount,
            notDownloadedCount: notDownloadedCount
        )
        if sampleCount > 0 && installedCount == 0 && !missingParts.isEmpty {
            return "\(sampleCount) sample\(sampleCount == 1 ? "" : "s") included - \(missingParts.joined(separator: " - "))"
        }
        if installedCount > 0 && !missingParts.isEmpty {
            return "\(installedCount) available - \(missingParts.joined(separator: " - "))"
        }
        if sampleCount > 0 {
            return "\(sampleCount) sample content item\(sampleCount == 1 ? "" : "s")"
        }
        if !missingParts.isEmpty {
            return missingParts.joined(separator: " - ")
        }
        return "\(installedCount) item\(installedCount == 1 ? "" : "s")"
    }

    private var countSummaryIcon: String {
        if hasLockedItems {
            return "lock"
        }
        if !readyToDownloadItems.isEmpty {
            return "arrow.down.circle"
        }
        if items.contains(where: { accessState(for: $0) == .sample }) {
            return "lock.open"
        }
        return "checkmark.circle"
    }

    private var featuredItems: [ArkFileLibraryContentItem] {
        let downloaded = items.filter { accessState(for: $0) == .installed }
        return Array((downloaded + items.filter(\.isSampleContent)).prefix(2))
    }

    private var selectedItemStatusLine: String {
        guard let selectedItem else { return "" }
        let access: String
        if selectedItem.isSampleContent {
            access = "Sample Content"
        } else {
            switch accessState(for: selectedItem) {
            case .sample:
                access = "Sample Content"
            case .installed:
                access = "Available offline"
            case .downloadable:
                access = "Not downloaded"
            case .locked:
                access = "Locked \(packShortName(for: selectedItem))"
            }
        }
        return "\(selectedItem.type.displayLabel) - \(access)"
    }

    private func itemPreviewRow(_ item: ArkFileLibraryContentItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName(for: item))
                .font(.subheadline)
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(itemTitleColor(for: item))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(itemPreviewSubtitle(for: item))
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: trailingIconName(for: item))
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func itemPreviewSubtitle(for item: ArkFileLibraryContentItem) -> String {
        let subcategory = item.isSampleContent
            ? item.sampleOriginalSubcategory ?? item.type.displayLabel
            : item.subcategory
        let access: String
        if item.isSampleContent {
            access = "Sample Content"
        } else {
            switch accessState(for: item) {
            case .sample:
                access = "Sample Content"
            case .installed:
                access = "Ready offline"
            case .downloadable:
                access = "Not downloaded"
            case .locked:
                access = "Locked \(packShortName(for: item))"
            }
        }
        return "\(subcategory) - \(access)"
    }

    private func buttonTitle(for item: ArkFileLibraryContentItem) -> String {
        let state = accessState(for: item)
        if isOpening && state == .installed {
            return "Opening..."
        }
        if state == .downloadable || state == .locked {
            return lockedButtonTitle(item)
        }
        if item.isSampleContent {
            return "Open sample content"
        }
        return "Open selected content"
    }

    private func packShortName(for item: ArkFileLibraryContentItem) -> String {
        item.requiredPackName.replacingOccurrences(of: "ArkFile ", with: "")
    }

    private func menuTitle(for item: ArkFileLibraryContentItem) -> String {
        if item.isSampleContent {
            return "\(item.displayName) - Sample Content"
        }
        return item.displayName
    }

    private func menuLabel(for item: ArkFileLibraryContentItem) -> some View {
        Label {
            Text(menuTitle(for: item))
                .foregroundStyle(itemTitleColor(for: item))
        } icon: {
            Image(systemName: iconName(for: item))
                .foregroundStyle(itemTitleColor(for: item))
        }
    }

    private func itemTitleColor(for item: ArkFileLibraryContentItem) -> Color {
        accessState(for: item) == .locked ? Color.arkAccentSecondary : Color.arkTextPrimary
    }

    private var selectedItemColor: Color {
        guard let selectedItem else { return Color.arkTextMuted }
        return itemTitleColor(for: selectedItem)
    }

    private func iconName(for item: ArkFileLibraryContentItem) -> String {
        switch accessState(for: item) {
        case .sample, .installed:
            return item.type.systemImage
        case .downloadable:
            return "icloud.and.arrow.down"
        case .locked:
            return "lock"
        }
    }

    private func trailingIconName(for item: ArkFileLibraryContentItem) -> String {
        switch accessState(for: item) {
        case .sample, .installed:
            return "arrow.forward.circle"
        case .downloadable:
            return "arrow.down.circle"
        case .locked:
            return "lock.open"
        }
    }

    private var hasLockedItems: Bool {
        !lockedItems.isEmpty
    }

    private var groupedItems: [(name: String, items: [ArkFileLibraryContentItem])] {
        var groups: [(name: String, items: [ArkFileLibraryContentItem])] = []
        for item in items {
            if let index = groups.firstIndex(where: { $0.name == item.subcategory }) {
                groups[index].items.append(item)
            } else {
                groups.append((name: item.subcategory, items: [item]))
            }
        }
        return ArkFileContentSubcategoryOrder.travelGuidesFirst(groups, name: \.name)
    }

    private var offlineGroupedItems: [(name: String, items: [ArkFileLibraryContentItem])] {
        groupedItems.compactMap { group in
            let offlineItems = group.items.filter {
                let state = accessState(for: $0)
                return state == .sample || state == .installed
            }
            guard !offlineItems.isEmpty else { return nil }
            return (name: group.name, items: offlineItems)
        }
    }

    private var readyToDownloadItems: [ArkFileLibraryContentItem] {
        items.filter { accessState(for: $0) == .downloadable }
    }

    private var lockedItems: [ArkFileLibraryContentItem] {
        items.filter { accessState(for: $0) == .locked }
    }

    private func accessState(for item: ArkFileLibraryContentItem) -> ArkFileLockedContentAccessState {
        if let resolutionInput {
            return ArkFileLockedContentPresentation.resolve(
                item: item,
                input: resolutionInput
            ).accessState
        }
        if item.isSampleContent {
            return .sample
        }
        return item.isInstalled ? .installed : .locked
    }

    private func missingSummaryParts(
        lockedCount: Int,
        notDownloadedCount: Int
    ) -> [String] {
        var parts: [String] = []
        if lockedCount > 0 {
            parts.append("\(lockedCount) locked")
        }
        if notDownloadedCount > 0 {
            parts.append("\(notDownloadedCount) not downloaded")
        }
        return parts
    }

    private func buttonSystemImage(
        for item: ArkFileLibraryContentItem,
        accessState: ArkFileLockedContentAccessState
    ) -> String {
        switch accessState {
        case .sample, .installed:
            return "play.fill"
        case .downloadable:
            return "arrow.down.circle"
        case .locked:
            return lockedButtonSystemImage(item)
        }
    }
}
#endif
