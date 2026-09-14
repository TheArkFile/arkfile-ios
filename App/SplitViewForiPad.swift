// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import CoreData
import SwiftUI

/// ArkFile's one adaptive iOS shell.
///
/// The route is owned by the scene and survives horizontal size-class changes.
/// Every iPad width keeps one NavigationSplitView and detail tree; SwiftUI
/// collapses that tree in place. iPhone retains its established CompactView.
@MainActor
struct SplitViewForiPad: View { // swiftlint:disable:this type_body_length
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var adaptiveNavigation: ArkFileAdaptiveNavigationState
    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn:
        NavigationSplitViewColumn = .detail
    @State private var activeReaderDestination: ArkFileContentReaderDestination?
    @State private var contentOpenError: String?
    @State private var uiTestShowsDetailOnly = false
    #if DEBUG
    @State private var uiTestSeededReaderIdentifier: String?
    #endif
    @State private var isReplayingOnboarding = false
    @State private var replayOnboardingDestination:
        ArkFileOnboardingDestination?
    @State private var showPackComparison = false
    @State private var mapPurchaseContext: ArkFileMapPurchaseContext?
    @State private var mapRegionID: String?
    @State private var mapShowsDownloads = false
    @State private var contentDownloadGroup: ArkFileContentDisplayGroup?

    private var usesSeparateCompactPresentation: Bool {
        ArkFileAdaptivePresentationPolicy
            .usesSeparateCompactPresentation(
                device: Device.current
            )
    }

    private var adaptivePresentation: some View {
        Group {
            if usesSeparateCompactPresentation {
                compactPresentation
                    .overlay(alignment: .bottomLeading) {
                        ArkFileAccessibilityMarker(
                            identifier: "arkfile_compact_shell"
                        )
                    }
            } else {
                splitPresentation
            }
        }
        .overlay {
            currentReaderObserver
        }
        .overlay(alignment: .topTrailing) {
            adaptiveReaderUITestControls
        }
        .overlay(alignment: .topLeading) {
            ArkFileAccessibilityMarker(
                identifier: "arkfile_adaptive_root"
            )
        }
        .overlay(alignment: .bottomTrailing) {
            presentedReaderAccessibilityMarker
        }
    }

    private var navigationObservedPresentation: some View {
        adaptivePresentation
        .onChange(of: navigation.currentItem) { _, item in
            consumeLegacyNavigationItem(item)
        }
        .onChange(of: adaptiveNavigation.route) { _, _ in
            activeReaderDestination = nil
            showSelectedDetail()
        }
        .onChange(
            of: adaptiveNavigation.readerActivationRevision
        ) { _, _ in
            activeReaderDestination = nil
            showSelectedDetail()
        }
        .onChange(
            of: adaptiveNavigation.routeSelectionRevision
        ) { _, _ in
            activeReaderDestination = nil
            showSelectedDetail()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            // A collapsed split should open on the current semantic detail,
            // not strand the person in an unrelated leading column.
            showSelectedDetail()
        }
    }

    private var notificationObservedPresentation: some View {
        navigationObservedPresentation
        .onReceive(
            NotificationCenter.default.publisher(
                for: .arkFileOpenLibraryItem
            )
        ) { notification in
            handleOpenLibraryItem(notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .arkFileReplayOnboarding
            )
        ) { _ in
            guard Device.current == .iPad else { return }
            replayOnboardingDestination = nil
            isReplayingOnboarding = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .arkFileOpenPackComparison
            )
        ) { notification in
            guard Device.current == .iPad else { return }
            mapPurchaseContext = (notification.userInfo?["returnToMaps"] as? Bool == true
                || notification.userInfo?["relativePath"] != nil)
                ? ArkFileMapPurchaseContext(
                    relativePath: notification.userInfo?["relativePath"] as? String,
                    showDownloadsOnReturn: notification.userInfo?["returnToMapDownloads"] as? Bool ?? true
                )
                : nil
            showHome()
            showPackComparison = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenContentDownloads)) { notification in
            guard Device.current == .iPad else { return }
            let groupID = notification.userInfo?["group"] as? String
            contentDownloadGroup = ArkFileContentDisplayGroup.allCases.first { $0.id == groupID }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenMapLocation)) { _ in
            mapRegionID = nil
            mapShowsDownloads = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileImportMapGPX)) { _ in
            mapRegionID = nil
            mapShowsDownloads = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenMapRegion)) { notification in
            guard Device.current == .iPad else { return }
            let path = notification.userInfo?["relativePath"] as? String
            mapRegionID = path.flatMap { ArkFileMapRegionIndex.regionID(relativePath: $0) }
            mapShowsDownloads = notification.userInfo?["showDownloads"] as? Bool ?? true
            activeReaderDestination = nil
            adaptiveNavigation.select(.map)
            showSelectedDetail()
        }
    }

    var body: some View {
        notificationObservedPresentation
        .task {
            await contentLibrary.refresh()
            consumeLegacyNavigationItem(navigation.currentItem)
            seedAdaptiveReaderForUITestingIfNeeded()
        }
        .alert(
            "Couldn’t Open Library Item",
            isPresented: Binding(
                get: { contentOpenError != nil },
                set: { if !$0 { contentOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                contentOpenError = nil
            }
        } message: {
            Text(contentOpenError ?? "")
        }
        .sheet(
            isPresented: $isReplayingOnboarding,
            onDismiss: finishReplayedOnboarding
        ) {
            ArkFileOnboardingView { destination in
                replayOnboardingDestination = destination
                isReplayingOnboarding = false
            }
        }
    }

    private var splitPresentation: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebar
                .navigationTitle(Brand.appName)
        } detail: {
            detailStack
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .bottomLeading) {
            ArkFileAccessibilityMarker(
                identifier: "arkfile_split_shell"
            )
        }
        .overlay(alignment: .bottom) {
            if showsAdaptiveReaderUITestHarness
                && uiTestShowsDetailOnly {
                ArkFileAccessibilityMarker(
                    identifier: "arkfile_detail_only_split"
                )
            }
        }
    }

    @ViewBuilder
    private var compactPresentation: some View {
        if activeReaderDestination != nil {
            // Static content remains in the scene-owned detail stack when an
            // iPhone typed destination presents it.
            detailStack
        } else {
            switch adaptiveNavigation.route {
            case .home, .reader:
                CompactView()
            default:
                detailStack
            }
        }
    }

    private var sidebar: some View {
        List {
            Section {
                sidebarRow(.home)
                sidebarRow(.library)
                sidebarRow(.saved)
            }

            Section("Offline Tools") {
                sidebarRow(.map)
                if FeatureFlags.savedWeather {
                    sidebarRow(.savedWeather)
                }
                sidebarRow(.preparedness)
                sidebarRow(.localSharing)
            }

            Section {
                sidebarRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("arkfile_ipad_sidebar")
    }

    private var selectedSidebarDestination: ArkFileAdaptiveDestination {
        let destination = adaptiveNavigation.route.destination
        return destination == .downloads ? .library : destination
    }

    private func sidebarRow(
        _ destination: ArkFileAdaptiveDestination
    ) -> some View {
        Button {
            selectDestination(destination)
        } label: {
            HStack {
                Label(
                    destination.title,
                    systemImage: destination.systemImage
                )
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedSidebarDestination == destination
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier(destination.accessibilityIdentifier)
        .accessibilityAddTraits(
            selectedSidebarDestination == destination
                ? .isSelected
                : []
        )
    }

    private var detailStack: some View {
        NavigationStack {
            detail
                .navigationDestination(item: $activeReaderDestination) { destination in
                    staticContentViewer(destination)
                        .id(destination.id)
                }
                .toolbar {
                    if showsCompactDetailHomeButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                selectDestination(.home)
                            } label: {
                                Label("Home", systemImage: "house")
                            }
                            .accessibilityIdentifier(
                                ArkFileAdaptiveDestination.home
                                    .accessibilityIdentifier
                            )
                        }
                    } else if showsSceneToolbarSidebarToggle {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: toggleSidebar) {
                                Label(
                                    "Show or Hide Sidebar",
                                    systemImage: "sidebar.left"
                                )
                            }
                            .accessibilityLabel("Show or Hide Sidebar")
                            .accessibilityIdentifier(
                                "arkfile_ipad_sidebar_toggle"
                            )
                        }
                    }
                }
        }
        .overlay {
            ArkFileAccessibilityMarker(
                identifier:
                    "arkfile_ipad_detail_"
                    + adaptiveNavigation.route.destination.rawValue
            )
        }
    }

    private var showsSceneToolbarSidebarToggle: Bool {
        Device.current == .iPad
            && activeReaderDestination == nil
            && adaptiveNavigation.route.destination != .home
    }

    private var showsCompactDetailHomeButton: Bool {
        usesSeparateCompactPresentation
            && activeReaderDestination == nil
            && adaptiveNavigation.route.destination != .home
            && adaptiveNavigation.route.destination != .reader
    }

    @ViewBuilder
    private func staticContentViewer(
        _ destination: ArkFileContentReaderDestination
    ) -> some View {
        if usesSeparateCompactPresentation {
            ArkFileContentViewer(
                item: destination.item,
                initialBookmark: destination.bookmark,
                openContentItem: openContentItem
            )
        } else {
            ArkFileContentViewer(
                item: destination.item,
                initialBookmark: destination.bookmark,
                openContentItem: openContentItem,
                toggleSidebar: toggleSidebar
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch adaptiveNavigation.route {
        case .home:
            WelcomeCatalog(
                viewState: .complete,
                showSettings: {
                    adaptiveNavigation.select(
                        .settings(scrollToHotspot: false)
                    )
                },
                usesParentSettingsToolbar: true,
                navigateScene: navigateScene,
                openSceneContent: openContentItem,
                toggleSidebar: toggleSidebar,
                packComparisonPresentation: $showPackComparison,
                mapPurchaseContext: $mapPurchaseContext
            )
        case .library:
            ArkFileLibraryDashboard(
                load: nil,
                navigateScene: navigateScene,
                openSceneContent: openContentItem
            )
        case .importedFile(let fileID):
            ArkFileImportedZIMDetail(
                fileID: fileID,
                openMainPage: openImportedZIMMainPage
            )
                .id(fileID)
        case .downloads(let relativePath):
            ArkFileContentBrowserView(
                openItem: openContentItem,
                initialTargetRelativePath: relativePath,
                initialGroup: contentDownloadGroup
            )
            .id((relativePath ?? "all") + (contentDownloadGroup?.id ?? ""))
        case .saved:
            ArkFileLibraryDashboard(
                load: nil,
                initialSection: .saved,
                navigateScene: navigateScene,
                openSceneContent: openContentItem
            )
        case .map:
            ArkFileOfflineMapView(
                contentRoot: contentLibrary.contentRoot,
                initialMapRegionID: mapRegionID,
                showsMapDownloadsInitially: mapShowsDownloads
            )
            .id("map-\(mapRegionID ?? "world")-\(mapShowsDownloads)")
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        case .savedWeather:
            ArkFileSavedWeatherView(
                contentRoot: contentLibrary.contentRoot
            )
        case .preparedness(let route):
            preparednessDetail(route)
                .id(route)
        case .localSharing:
            HotspotZimFilesSelection()
                .navigationTitle("Local Sharing")
                .navigationBarTitleDisplayMode(.inline)
        case .settings(let scrollToHotspot):
            Settings(scrollToHotspot: scrollToHotspot)
                .id(scrollToHotspot)
        case .reader(let identity):
            readerDetail(identity)
        }
    }

    @ViewBuilder
    private func preparednessDetail(
        _ route: ArkFileAdaptivePreparednessRoute
    ) -> some View {
        switch route {
        case .toolkit(let selectedView):
            ArkFilePreparednessToolkitView()
                .task(id: selectedView) {
                    if let selectedView {
                        UserDefaults.standard.set(
                            selectedView,
                            forKey: "arkfile.toolkit.selected-view.v1"
                        )
                    }
                }
        case .survivalGuide(let sectionID, let blockID):
            ArkFileSurvivalGuideView(
                initialSectionID: sectionID,
                initialBlockID: blockID
            )
        }
    }

    private func navigateScene(_ route: ArkFileSceneRoute) {
        switch route {
        case .library:
            adaptiveNavigation.select(.library)
        case .saved:
            adaptiveNavigation.select(.saved)
        case .map:
            mapRegionID = nil
            mapShowsDownloads = false
            adaptiveNavigation.select(.map)
        case .savedWeather:
            adaptiveNavigation.select(.savedWeather)
        case .preparedness(let selectedView):
            adaptiveNavigation.select(
                .preparedness(
                    .toolkit(selectedView: selectedView)
                )
            )
        case .survivalGuide(let sectionID, let blockID):
            adaptiveNavigation.select(
                .preparedness(
                    .survivalGuide(
                        sectionID: sectionID,
                        blockID: blockID
                    )
                )
            )
        case .localSharing:
            adaptiveNavigation.select(.localSharing)
        case .downloads(let relativePath):
            contentDownloadGroup = nil
            adaptiveNavigation.select(
                .downloads(relativePath: relativePath)
            )
        }
    }

    @ViewBuilder
    private func readerDetail(
        _ identity: ArkFileReaderTabIdentity
    ) -> some View {
        if let objectID = managedObjectID(for: identity) {
            BrowserTab(
                tabID: objectID,
                openBookmarkedContent: { item, bookmark in
                    openContentItem(item, bookmark: bookmark)
                }
            )
            .id(identity)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ArkFileHomeLogoButton(action: showHome)
                }
            }
        } else {
            ContentUnavailableView(
                "Reader No Longer Available",
                systemImage: "book.closed",
                description: Text(
                    "The saved reader tab could not be restored."
                )
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Go Home") {
                        selectDestination(.home)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var currentReaderObserver: some View {
        if case .tab(let objectID) = navigation.currentItem {
            ArkFileAdaptiveReaderObserver(
                tabID: objectID,
                navigationState: adaptiveNavigation,
                activationRevision:
                    adaptiveNavigation.readerActivationRevision
            )
        }
    }

    private var currentReaderObjectID: NSManagedObjectID? {
        guard case .tab(let objectID) = navigation.currentItem else {
            return nil
        }
        return objectID
    }

    private var showsAdaptiveReaderUITestHarness: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("testing")
            && ProcessInfo.processInfo.arguments.contains(
                "arkfile-ui-test-adaptive-reader"
            )
        #else
        false
        #endif
    }

    @ViewBuilder
    private var adaptiveReaderUITestControls: some View {
        #if DEBUG
        if showsAdaptiveReaderUITestHarness {
            VStack(alignment: .trailing, spacing: 0) {
                if let uiTestSeededReaderIdentifier {
                    Text("Seeded reader")
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Seeded Reader Identifier"
                        )
                        .accessibilityValue(
                            uiTestSeededReaderIdentifier
                        )
                        .accessibilityIdentifier(
                            "arkfile_seeded_reader_probe"
                        )
                }

                Button {
                    toggleSidebar()
                } label: {
                    Image(
                        systemName:
                            uiTestShowsDetailOnly
                                ? "rectangle.split.2x1"
                                : "rectangle.compress.vertical"
                    )
                    .padding(10)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Toggle iPad Test Columns")
                .accessibilityIdentifier(
                    "arkfile_ui_toggle_columns"
                )
            }
            .padding(.top, 56)
            .padding(.trailing, 14)
            .zIndex(100)
        }
        #endif
    }

    private func seedAdaptiveReaderForUITestingIfNeeded() {
        #if DEBUG
        guard showsAdaptiveReaderUITestHarness else {
            return
        }
        let objectID =
            currentReaderObjectID ?? navigation.createTab()
        uiTestSeededReaderIdentifier =
            "arkfile_ipad_reader_tab_\(objectID.uriRepresentation().absoluteString)"
        adaptiveNavigation.expectReader()
        BrowserViewModel.getCached(tabID: objectID)
            .seedReaderForAdaptiveUITest()
        #endif
    }

    private func finishReplayedOnboarding() {
        guard let destination = replayOnboardingDestination else {
            return
        }
        replayOnboardingDestination = nil
        switch destination {
        case .home:
            showHome()
        case .includedSamples:
            adaptiveNavigation.select(.library)
        case .packs:
            mapPurchaseContext = nil
            showHome()
            showPackComparison = true
        }
    }

    private func selectDestination(
        _ destination: ArkFileAdaptiveDestination
    ) {
        switch destination {
        case .home:
            showHome()
        case .library:
            adaptiveNavigation.select(.library)
        case .downloads:
            contentDownloadGroup = nil
            adaptiveNavigation.select(.downloads(relativePath: nil))
        case .saved:
            adaptiveNavigation.select(.saved)
        case .map:
            mapRegionID = nil
            mapShowsDownloads = false
            adaptiveNavigation.select(.map)
        case .savedWeather:
            adaptiveNavigation.select(.savedWeather)
        case .preparedness:
            adaptiveNavigation.select(
                .preparedness(.toolkit(selectedView: nil))
            )
        case .localSharing:
            adaptiveNavigation.select(.localSharing)
        case .settings:
            adaptiveNavigation.select(
                .settings(scrollToHotspot: false)
            )
        case .reader:
            if let currentReader = adaptiveNavigation.currentReader {
                adaptiveNavigation.activateReader(currentReader)
            }
        }
    }

    private func showHome() {
        if ArkFileAdaptiveHomeTransitionPolicy.clearsCurrentReader(
            usesSingleReader:
                NavigationViewModel.usesArkFileSingleReaderRouting
        ) {
            let objectID: NSManagedObjectID
            if let currentReaderObjectID {
                objectID = currentReaderObjectID
            } else {
                objectID = navigation.createTab()
            }
            BrowserViewModel.getCached(tabID: objectID).clearForHome()
        }
        adaptiveNavigation.select(.home)
    }

    private func consumeLegacyNavigationItem(
        _ item: NavigationItem?
    ) {
        switch item {
        case .loading, .none:
            break
        case .tab:
            // The reader observer waits for BrowserViewModel to publish whether
            // the tab contains a document before changing the typed route.
            break
        case .bookmarks:
            adaptiveNavigation.select(.saved)
        case .map:
            mapRegionID = nil
            mapShowsDownloads = false
            adaptiveNavigation.select(.map)
        case .opened, .categories, .new:
            adaptiveNavigation.select(.library)
        case .downloads:
            contentDownloadGroup = nil
            adaptiveNavigation.select(.downloads(relativePath: nil))
        case .hotspot:
            adaptiveNavigation.select(.localSharing)
        case .settings(let scrollToHotspot):
            adaptiveNavigation.select(
                .settings(scrollToHotspot: scrollToHotspot)
            )
        }
    }

    private func managedObjectID(
        for identity: ArkFileReaderTabIdentity
    ) -> NSManagedObjectID? {
        let context = Database.shared.viewContext
        guard let objectID = context.persistentStoreCoordinator?
            .managedObjectID(forURIRepresentation: identity.objectURI),
              (try? context.existingObject(with: objectID)) is Tab else {
            return nil
        }
        return objectID
    }

    private func openContentItem(_ item: ArkFileLocalContentItem) {
        openContentItem(item, bookmark: nil)
    }

    private func openContentItem(
        _ item: ArkFileLocalContentItem,
        bookmark: ArkFileContentBookmark?
    ) {
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        let sceneContentOpenIntent =
            adaptiveNavigation.beginContentOpen()
        activeReaderDestination = nil

        guard item.type == .zim else {
            adaptiveNavigation.presentStaticContent()
            activeReaderDestination = ArkFileContentReaderDestination(item: item, bookmark: bookmark)
            return
        }

        Task {
            if let bookmark {
                switch await ArkFileSavedZIMResolver.resolve(
                    bookmark: bookmark,
                    item: item
                ) {
                case .success(let destination):
                    guard isCurrentContentOpen(
                        readerOpenIntent,
                        sceneContentOpenIntent
                    ) else {
                        return
                    }
                    NotificationCenter.openURL(
                        destination.url,
                        continuing: readerOpenIntent
                    )
                case .failure(let failure):
                    guard isCurrentContentOpen(
                        readerOpenIntent,
                        sceneContentOpenIntent
                    ) else {
                        return
                    }
                    contentOpenError = failure.message(
                        itemName: item.displayName
                    )
                }
                return
            }

            await openZIMMainPage(
                item,
                continuing: readerOpenIntent,
                sceneIntent: sceneContentOpenIntent
            )
        }
    }

    private func handleOpenLibraryItem(_ notification: Notification) {
        // CompactViewController owns this event while the compact reader is
        // mounted. Handling it here as well would open the same item twice.
        guard Device.current == .iPad,
              let relativePath =
                notification.userInfo?["relativePath"] as? String,
              let item = contentLibrary.allItems.first(
                where: { $0.relativePath == relativePath }
              ) else {
            return
        }
        openContentItem(item)
    }

    private func openImportedZIMMainPage(_ zimFile: ZimFile) async {
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        let sceneContentOpenIntent =
            adaptiveNavigation.beginContentOpen()

        guard let mainPageURL =
            await ZimFileService.shared.getMainPageURL(
                zimFileID: zimFile.fileID
            ) else {
            if isCurrentContentOpen(
                readerOpenIntent,
                sceneContentOpenIntent
            ) {
                contentOpenError =
                    "ArkFile could not find the main page for \(zimFile.name)."
            }
            return
        }
        guard isCurrentContentOpen(
            readerOpenIntent,
            sceneContentOpenIntent
        ) else {
            return
        }
        NotificationCenter.openURL(
            mainPageURL,
            inNewTab: true,
            continuing: readerOpenIntent
        )
    }

    private func openZIMMainPage(
        _ item: ArkFileLocalContentItem,
        continuing readerOpenIntent: ArkFileReaderOpenIntent,
        sceneIntent: ArkFileAdaptiveSceneContentOpenIntent
    ) async {
        guard let fileID = await LibraryOperations.openFileID(
            url: item.url
        ) else {
            if isCurrentContentOpen(
                readerOpenIntent,
                sceneIntent
            ) {
                contentOpenError =
                    "ArkFile could not register \(item.displayName) as readable content."
            }
            return
        }
        guard isCurrentContentOpen(
            readerOpenIntent,
            sceneIntent
        ) else {
            return
        }
        guard await ZimFileService.shared.openArchive(
            zimFileID: fileID
        ) != nil else {
            if isCurrentContentOpen(
                readerOpenIntent,
                sceneIntent
            ) {
                contentOpenError =
                    "ArkFile could not open the current local copy of \(item.displayName)."
            }
            return
        }
        guard isCurrentContentOpen(
            readerOpenIntent,
            sceneIntent
        ) else {
            return
        }
        guard let mainPageURL =
            await ZimFileService.shared.getMainPageURL(
                zimFileID: fileID
            ) else {
            if isCurrentContentOpen(
                readerOpenIntent,
                sceneIntent
            ) {
                contentOpenError =
                    "ArkFile opened \(item.displayName), but could not find its main page."
            }
            return
        }
        guard isCurrentContentOpen(
            readerOpenIntent,
            sceneIntent
        ) else {
            return
        }
        NotificationCenter.openURL(
            mainPageURL,
            continuing: readerOpenIntent
        )
    }

    private func isCurrentContentOpen(
        _ readerIntent: ArkFileReaderOpenIntent,
        _ sceneIntent: ArkFileAdaptiveSceneContentOpenIntent
    ) -> Bool {
        ArkFileReaderOpenIntentCoordinator.shared
            .isCurrent(readerIntent)
            && adaptiveNavigation.isCurrentContentOpen(sceneIntent)
    }

    private func toggleSidebar() {
        let plan = ArkFileAdaptiveSidebarTogglePolicy.plan(
            isCompactWidth: horizontalSizeClass == .compact,
            regularShowsDetailOnly: columnVisibility == .detailOnly,
            compactShowsSidebar:
                preferredCompactColumn == .sidebar
        )
        columnVisibility =
            plan.showsAllRegularColumns ? .all : .detailOnly
        preferredCompactColumn =
            plan.preferredCompactColumn == .sidebar
                ? .sidebar
                : .detail
        uiTestShowsDetailOnly = columnVisibility == .detailOnly
    }

    private func showSelectedDetail() {
        preferredCompactColumn = .detail
        if horizontalSizeClass == .compact {
            columnVisibility = .all
        }
        uiTestShowsDetailOnly = false
    }

    @ViewBuilder
    private var presentedReaderAccessibilityMarker: some View {
        if showsAdaptiveReaderUITestHarness,
           case .reader(let identity) = adaptiveNavigation.route,
           let objectID = managedObjectID(for: identity) {
            ArkFilePresentedReaderAccessibilityMarker(
                route: adaptiveNavigation.route,
                tabID: objectID
            )
            .id(adaptiveNavigation.readerActivationRevision)
        }
    }

}

private struct ArkFileAccessibilityMarker: View {
    let identifier: String

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("testing") {
            Text(identifier)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(identifier)
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
        }
        #endif
    }
}

@MainActor
private struct ArkFilePresentedReaderAccessibilityMarker: View {
    let route: ArkFileAdaptiveRoute
    @ObservedObject private var browser: BrowserViewModel

    init(
        route: ArkFileAdaptiveRoute,
        tabID: NSManagedObjectID
    ) {
        self.route = route
        _browser = ObservedObject(
            wrappedValue: BrowserViewModel.getCached(tabID: tabID)
        )
    }

    @ViewBuilder
    var body: some View {
        if ArkFileAdaptiveReaderPresentationPolicy.hasPresentedReader(
            route: route,
            observedReader: ArkFileReaderTabIdentity(
                objectID: browser.tabID
            ),
            hasPresentedContent: browser.hasURL
        ) {
            ArkFileDynamicAccessibilityMarker(
                identifier: "arkfile_reader_root"
            )
        }
    }
}

private struct ArkFileDynamicAccessibilityMarker: View {
    let identifier: String

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("testing") {
            Text(identifier)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(identifier)
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
        }
        #endif
    }
}

@MainActor
private struct ArkFileImportedZIMDetail: View {
    @FetchRequest private var zimFiles: FetchedResults<ZimFile>
    let openMainPage: @MainActor (ZimFile) async -> Void

    init(
        fileID: UUID,
        openMainPage: @MainActor @escaping (ZimFile) async -> Void
    ) {
        _zimFiles = FetchRequest(
            fetchRequest: ZimFile.fetchRequest(fileID: fileID),
            animation: .easeInOut
        )
        self.openMainPage = openMainPage
    }

    var body: some View {
        if let zimFile = zimFiles.first {
            ZimFileDetail(
                zimFile: zimFile,
                dismissParent: nil,
                openMainPage: {
                    await openMainPage(zimFile)
                }
            )
        } else {
            ContentUnavailableView(
                "Imported File Unavailable",
                systemImage: "doc.questionmark",
                description: Text(
                    "ArkFile could not find the imported file in this device’s library."
                )
            )
            .navigationTitle("Library")
        }
    }
}

@MainActor
private struct ArkFileAdaptiveReaderObserver: View {
    @ObservedObject private var browser: BrowserViewModel
    @ObservedObject var navigationState: ArkFileAdaptiveNavigationState
    let activationRevision: UInt

    init(
        tabID: NSManagedObjectID,
        navigationState: ArkFileAdaptiveNavigationState,
        activationRevision: UInt
    ) {
        _browser = ObservedObject(
            wrappedValue: BrowserViewModel.getCached(tabID: tabID)
        )
        self.navigationState = navigationState
        self.activationRevision = activationRevision
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: publish)
            .onChange(of: browser.hasURL) { _, _ in
                publish()
            }
            .onChange(of: activationRevision) { _, _ in
                publish()
            }
    }

    private func publish() {
        navigationState.observeReader(
            objectID: browser.tabID,
            hasPresentedContent: browser.hasURL
        )
    }
}
#endif
