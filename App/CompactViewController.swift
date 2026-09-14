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

//
//  CompactViewController.swift
//  Kiwix

#if os(iOS)
import Combine
import SwiftUI
import UIKit
import CoreData
import Defaults

// iPhone portrait only
struct CompactTabView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismissSearch) private var dismissSearch
    @State private var presentedSheet: PresentedSheet?
    @ObservedObject private var browser: BrowserViewModel
    @StateObject private var arkFileContentLibrary = ArkFileLocalContentLibrary.shared
    @StateObject private var arkFileFavorites = ArkFileContentFavorites.shared
    @StateObject private var arkFileBookmarks = ArkFileContentBookmarks.shared
    @State private var isShowingArkFileBookmarks = false
    @State private var isShowingArkFileBookmarkEditor = false
    @State private var arkFileBookmarkBeingEdited: ArkFileContentBookmark?
    @State private var activeReaderDestination: ArkFileContentReaderDestination?
    @State private var activeSavedZIMBookmarkAlias: ArkFileSavedZIMBookmarkAlias?
    @State private var arkFileOpenError: String?
    private let navigateToHotspotSettings = NotificationCenter.default.publisher(for: .navigateToHotspotSettings)
    private let hotspotShareURL = NotificationCenter.default.publisher(for: .hotspotShareURL)
    private let openGuideSection = NotificationCenter.default.publisher(for: .arkFileOpenGuideSection)
    private let openToolkitView = NotificationCenter.default.publisher(for: .arkFileOpenToolkitView)
    private let openLibraryItem = NotificationCenter.default.publisher(for: .arkFileOpenLibraryItem)
    private let openMapLocation = NotificationCenter.default.publisher(for: .arkFileOpenMapLocation)
    private let importMapGPX = NotificationCenter.default.publisher(for: .arkFileImportMapGPX)
    @State private var showPackComparison = false
    @State private var mapPurchaseContext: ArkFileMapPurchaseContext?
    @State private var mapRegionID: String?
    @State private var mapShowsDownloads = false
    @State private var contentDownloadGroup: ArkFileContentDisplayGroup?
    private let openMapRegion = NotificationCenter.default.publisher(for: .arkFileOpenMapRegion)
    private let openPackComparison = NotificationCenter.default.publisher(for: .arkFileOpenPackComparison)
    private let openContentDownloads = NotificationCenter.default.publisher(for: .arkFileOpenContentDownloads)
    private let goHomeNotification = NotificationCenter.default.publisher(for: .arkFileGoHome)
    
    enum PresentedSheet: Identifiable {
        case library(downloads: Bool)
        case arkFileContentDownloads(relativePath: String?)
        case customHotspot // for custom iPhone apps only
        case hotspotShare(url: URL)
        case settings(scrollToHotspot: Bool)
        case survivalGuide(sectionID: String?)
        case preparedness
        case map

        var ownsInstallerAlerts: Bool {
            switch self {
            case .settings, .arkFileContentDownloads:
                true
            case .library, .customHotspot, .hotspotShare, .survivalGuide, .preparedness, .map:
                false
            }
        }

        var id: String {
            switch self {
            case .library(true): return "library-downloads"
            case .library(false): return "library"
            case .arkFileContentDownloads(let relativePath):
                return "arkfile-content-downloads-\(relativePath ?? "all")"
            case .hotspotShare: return "hotspot-share"
            case .customHotspot: return "custom-hotspot"
            case .settings: return "settings"
            case .survivalGuide: return "survival-guide"
            case .preparedness: return "preparedness"
            case .map: return "map"
            }
        }
    }
    
    init(tabID: NSManagedObjectID) {
        self.browser = BrowserViewModel.getCached(tabID: tabID)
    }
    
    private func dismiss() {
        presentedSheet = nil
    }

    private func goHome() {
        applyGoHomeState()
        NotificationCenter.default.post(
            name: .arkFileGoHome,
            object: browser
        )
    }

    private func applyGoHomeState() {
        if ArkFileAdaptiveHomeTransitionPolicy.clearsCurrentReader(
            usesSingleReader:
                NavigationViewModel.usesArkFileSingleReaderRouting
        ) {
            browser.clearForHome()
        }
        presentedSheet = nil
        activeSavedZIMBookmarkAlias = nil
        dismissSearch()
    }

    var body: some View {
        let model = if FeatureFlags.hasLibrary {
            CatalogLaunchViewModel(library: library, browser: browser)
        } else {
            NoCatalogLaunchViewModel(browser: browser)
        }
        Content(
            browser: browser,
            tabID: browser.tabID,
            showLibrary: {
                if presentedSheet == nil {
                    presentedSheet = .library(downloads: false)
                } else { // there's a sheet already presented by the user, do nothing
                }
            },
            showSettings: {
                presentedSheet = .settings(scrollToHotspot: false)
            },
            canPresentInstallerAlerts: {
                presentedSheet?.ownsInstallerAlerts != true
            },
            model: model,
            packComparisonPresentation: $showPackComparison,
            mapPurchaseContext: $mapPurchaseContext)
        .id(browser.tabID)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                ArkFileHomeLogoButton(action: goHome)
                SpacerBackCompatible()
                NavigationButtons(
                    goBack: { [weak browser] in
                        browser?.goBack()
                    },
                    goForward: { [weak browser] in
                        browser?.goForward()
                    })
                SpacerBackCompatible()
                if ArkFileReaderRoutingPolicy.showsTabManagement(
                    usesSingleReader: NavigationViewModel.usesArkFileSingleReaderRouting
                ) {
                    TabsManagerButton()
                    SpacerBackCompatible()
                }
                if !Brand.hideTOCButton {
                    OutlineButton(browser: browser)
                    SpacerBackCompatible()
                }
                if let currentArkFileZimItem {
                    Button {
                        arkFileFavorites.toggle(currentArkFileZimItem)
                    } label: {
                        Image(
                            systemName: arkFileFavorites.isFavorite(currentArkFileZimItem)
                                ? "star.fill"
                                : "star"
                        )
                    }
                    .accessibilityLabel(
                        arkFileFavorites.isFavorite(currentArkFileZimItem)
                            ? "Remove from Favorites"
                            : "Add to Favorites"
                    )
                    .accessibilityIdentifier("ArkFileZimFavorite")
                    SpacerBackCompatible()
                    Button {
                        isShowingArkFileBookmarks = true
                    } label: {
                        Image(systemName: currentArkFileZimBookmark == nil ? "bookmark" : "bookmark.fill")
                    }
                    .accessibilityLabel("Bookmarks")
                    .accessibilityIdentifier("ArkFileZimBookmarks")
                    SpacerBackCompatible()
                    MoreTabButton(
                        browser: browser,
                        presentHotspot: {
                            presentedSheet = .customHotspot
                        },
                        showsBookmarkButton: false
                    )
                } else {
                    MoreTabButton(browser: browser,
                                  presentHotspot: {
                        presentedSheet = .customHotspot
                    },
                                  showsBookmarkButton: currentArkFileZimURL != nil
                                    && !browser.zimFileName.isEmpty)
                }
                Spacer()
            }
        }
        .sheet(item: $presentedSheet) { presentedSheet in
            switch presentedSheet {
            case .library(downloads: false):
                Library(dismiss: dismiss)
            case .library(downloads: true):
                Library(dismiss: dismiss, tabItem: .downloads)
            case .arkFileContentDownloads(let relativePath):
                NavigationStack {
                    ArkFileContentBrowserView(
                        openItem: openArkFileContent,
                        initialTargetRelativePath: relativePath,
                        initialGroup: contentDownloadGroup
                    )
                    .id((relativePath ?? "all") + (contentDownloadGroup?.id ?? ""))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalString.common_button_done) {
                                    self.presentedSheet = nil
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
            case .customHotspot:
                SheetContent {
                    HotspotZimFilesSelection()
                }
            case .hotspotShare(let url):
                // comes from HotspotZimFilesSelection
                ActivityViewController(activityItems: [url].compactMap { $0 })
            case .survivalGuide(let sectionID):
                NavigationStack {
                    ArkFileSurvivalGuideView(initialSectionID: sectionID)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalString.common_button_done) {
                                    self.presentedSheet = nil
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
            case .preparedness:
                NavigationStack {
                    ArkFilePreparednessToolkitView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalString.common_button_done) {
                                    self.presentedSheet = nil
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
            case .map:
                NavigationStack {
                    ArkFileOfflineMapView(
                        contentRoot: ArkFileLocalContentLibrary.shared.contentRoot,
                        initialMapRegionID: mapRegionID,
                        showsMapDownloadsInitially: mapShowsDownloads
                    )
                    .id("map-\(mapRegionID ?? "world")-\(mapShowsDownloads)")
                        .navigationTitle("Map")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(LocalString.common_button_done) {
                                    self.presentedSheet = nil
                                }
                                .fontWeight(.semibold)
                            }
                        }
                }
            case .settings(let scrollToHotspot):
                NavigationStack {
                    Settings(scrollToHotspot: scrollToHotspot).toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                self.presentedSheet = nil
                            } label: {
                                Text(LocalString.common_button_done).fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingArkFileBookmarks) {
            if let currentArkFileZimItem {
                ArkFileBookmarkPanel(
                    currentItem: currentArkFileZimItem,
                    favorites: arkFileFavorites,
                    bookmarks: arkFileBookmarks,
                    addCurrentBookmark: {
                        arkFileBookmarkBeingEdited = currentArkFileZimBookmark
                        isShowingArkFileBookmarks = false
                        isShowingArkFileBookmarkEditor = true
                    },
                    openBookmark: openArkFileBookmark,
                    deleteBookmark: arkFileBookmarks.delete
                )
            }
        }
        .sheet(isPresented: $isShowingArkFileBookmarkEditor) {
            ArkFileBookmarkEditor(
                title: arkFileBookmarkEditorTitle,
                existingTags: arkFileBookmarkBeingEdited?.tags ?? [],
                existingNotes: arkFileBookmarkBeingEdited?.notes ?? ""
            ) { tags, notes in
                saveCurrentArkFileBookmark(tags: tags, notes: notes)
                isShowingArkFileBookmarkEditor = false
                isShowingArkFileBookmarks = true
            }
        }
        .alert(
            "Couldn’t Open Saved Article",
            isPresented: Binding(
                get: { arkFileOpenError != nil },
                set: { if !$0 { arkFileOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                arkFileOpenError = nil
            }
        } message: {
            Text(arkFileOpenError ?? "")
        }
        .navigationDestination(item: $activeReaderDestination) { destination in
            ArkFileContentViewer(
                item: destination.item,
                initialBookmark: destination.bookmark,
                openContentItem: { targetItem, bookmark in
                    openArkFileContentFromViewer(targetItem, bookmark: bookmark)
                }
            )
            .id(destination.id)
        }
        .onReceive(navigation.showDownloads) { _ in
            switch presentedSheet {
            case .library:
                // switching to the downloads tab
                // is done within Library
                break
            case .arkFileContentDownloads, .hotspotShare, .customHotspot:
                // doesn't apply
                break
            case .settings, .survivalGuide, .preparedness, .map, nil:
                presentedSheet = .library(downloads: true)
            }
        }
        .onReceive(goHomeNotification) { notification in
            // Static readers and other scene-owned surfaces send this
            // semantic action. CompactTabView must apply its own iPhone state
            // transition; changing the adaptive route alone would leave the
            // previous browser and sheet visible.
            guard (notification.object as? BrowserViewModel) !== browser else {
                return
            }
            applyGoHomeState()
        }
        .onReceive(hotspotShareURL) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            presentedSheet = .hotspotShare(url: url)
        }
        .onReceive(navigateToHotspotSettings) { _ in
            presentedSheet = .settings(scrollToHotspot: true)
        }
        .onReceive(openPackComparison) { notification in
            mapPurchaseContext = (notification.userInfo?["returnToMaps"] as? Bool == true
                || notification.userInfo?["relativePath"] != nil)
                ? ArkFileMapPurchaseContext(
                    relativePath: notification.userInfo?["relativePath"] as? String,
                    showDownloadsOnReturn: notification.userInfo?["returnToMapDownloads"] as? Bool ?? true
                )
                : nil
            applyGoHomeState()
            showPackComparison = true
        }
        .onReceive(openMapRegion) { notification in
            activeReaderDestination = nil
            let path = notification.userInfo?["relativePath"] as? String
            mapRegionID = path.flatMap { ArkFileMapRegionIndex.regionID(relativePath: $0) }
            mapShowsDownloads = notification.userInfo?["showDownloads"] as? Bool ?? true
            presentedSheet = .map
        }
        .onReceive(openMapLocation) { _ in
            mapRegionID = nil
            mapShowsDownloads = false
            activeReaderDestination = nil
            presentedSheet = .map
        }
        .onReceive(importMapGPX) { _ in
            mapRegionID = nil
            mapShowsDownloads = false
            activeReaderDestination = nil
            presentedSheet = .map
        }
        .onReceive(openContentDownloads) { notification in
            let groupID = notification.userInfo?["group"] as? String
            contentDownloadGroup = ArkFileContentDisplayGroup.allCases.first { $0.id == groupID }
            activeReaderDestination = nil
            presentedSheet = .arkFileContentDownloads(
                relativePath: notification.userInfo?["relativePath"] as? String
            )
        }
        .onReceive(openGuideSection) { notification in
            let sectionID = notification.userInfo?["sectionID"] as? String
            presentedSheet = .survivalGuide(sectionID: sectionID)
        }
        .onReceive(openToolkitView) { notification in
            if let view = notification.userInfo?["view"] as? String {
                UserDefaults.standard.set(view, forKey: "arkfile.toolkit.selected-view.v1")
            }
            presentedSheet = .preparedness
        }
        .onReceive(openLibraryItem) { notification in
            guard Device.current == .iPhone else {
                // iPad owns this destination in its scene-scoped adaptive
                // shell so resizing cannot discard the pushed content.
                return
            }
            guard let relativePath = notification.userInfo?["relativePath"] as? String,
                  let item = arkFileContentLibrary.allItems.first(where: { $0.relativePath == relativePath }) else {
                return
            }
            openArkFileContent(item)
        }
    }

    private var currentArkFileZimItem: ArkFileLocalContentItem? {
        arkFileContentLibrary.localItem(matching: currentZimFile)
    }

    private var currentArkFileZimURL: URL? {
        ArkFileZIMReaderPresentationPolicy.stableURL(
            presentedURL: browser.url,
            webViewURL: browser.webView.url,
            isLoading: browser.isLoading,
            lastSuccessfulURL: browser.lastSuccessfulZIMURL
        )
    }

    private var currentZimFile: ZimFile? {
        guard let zimFileID = currentArkFileZimURL?.zimFileID else {
            return nil
        }
        return try? Database.shared.viewContext.fetch(ZimFile.fetchRequest(fileID: zimFileID)).first
    }

    private func openArkFileContent(_ item: ArkFileLocalContentItem) {
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        presentedSheet = nil
        if item.type == .zim {
            activeSavedZIMBookmarkAlias = nil
            Task {
                await openArkFileZim(item, continuing: readerOpenIntent)
            }
        } else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item)
        }
    }

    private func openArkFileContentFromViewer(
        _ item: ArkFileLocalContentItem,
        bookmark: ArkFileContentBookmark?
    ) {
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        activeReaderDestination = nil
        guard item.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item, bookmark: bookmark)
            return
        }
        if let bookmark {
            openArkFileBookmark(bookmark)
        } else {
            activeSavedZIMBookmarkAlias = nil
            Task { await openArkFileZim(item, continuing: readerOpenIntent) }
        }
    }

    private var currentArkFileZimBookmark: ArkFileContentBookmark? {
        guard let locationKey = currentArkFileZimLocationKey else {
            return nil
        }
        if let exact = arkFileBookmarks.bookmark(matching: locationKey) {
            return exact
        }
        guard let alias = activeSavedZIMBookmarkAlias,
              alias.matches(locationKey: locationKey) else {
            return nil
        }
        return arkFileBookmarks.bookmark(id: alias.bookmarkID)
    }

    private var currentArkFileZimLocationKey: String? {
        guard let item = currentArkFileZimItem,
              let url = currentArkFileZimURL else {
            return nil
        }
        return ArkFileContentBookmark.locationKey(
            item: item,
            articleUrl: url.absoluteString,
            pageNumber: nil,
            chapterIndex: nil,
            anchorId: "",
            scrollTop: 0
        )
    }

    private var arkFileBookmarkEditorTitle: String {
        if let title = arkFileBookmarkBeingEdited?.articleTitle,
           !title.isEmpty {
            return title
        }
        let title = browser.articleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return currentArkFileZimItem?.displayName ?? "Bookmark"
    }

    private func saveCurrentArkFileBookmark(tags: [String], notes: String) {
        guard let item = currentArkFileZimItem,
              let url = currentArkFileZimURL else {
            return
        }
        let locationKey = ArkFileContentBookmark.locationKey(
            item: item,
            articleUrl: url.absoluteString,
            pageNumber: nil,
            chapterIndex: nil,
            anchorId: "",
            scrollTop: 0
        )
        let existing = arkFileBookmarkBeingEdited ?? arkFileBookmarks.bookmark(matching: locationKey)
        if var existing {
            // A saved source path may resolve to a different current path. In
            // that alias state, editing metadata must not silently migrate the
            // source route or delete an independently saved destination.
            existing.articleTitle = arkFileBookmarkEditorTitle
            existing.tags = tags
            existing.notes = notes
            existing.updatedAt = Date()
            arkFileBookmarks.upsert(existing)
            arkFileBookmarkBeingEdited = nil
            return
        }
        let bookmark = ArkFileContentBookmark(
            id: UUID().uuidString,
            schemaVersion: ArkFileContentBookmark.currentSchemaVersion,
            locationKey: locationKey,
            articleUrl: url.absoluteString,
            articleTitle: arkFileBookmarkEditorTitle,
            contentType: .zim,
            relativePath: item.relativePath,
            fileName: item.name,
            pageNumber: nil,
            chapterIndex: nil,
            chapterPath: "",
            anchorId: "",
            anchorLabel: "",
            scrollTop: 0,
            tags: tags,
            notes: notes,
            createdAt: Date(),
            updatedAt: Date(),
            status: "valid"
        )
        arkFileBookmarks.upsert(bookmark)
        arkFileBookmarkBeingEdited = nil
    }

    private func openArkFileBookmark(_ bookmark: ArkFileContentBookmark) {
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        guard let item = arkFileContentLibrary.allItems.first(where: { $0.relativePath == bookmark.relativePath }) else {
            arkFileOpenError = "ArkFile could not find \(bookmark.fileName) in the local library. The Saved entry was kept."
            return
        }
        isShowingArkFileBookmarks = false
        guard item.type == .zim else {
            activeReaderDestination = ArkFileContentReaderDestination(item: item, bookmark: bookmark)
            return
        }
        Task {
            switch await ArkFileSavedZIMResolver.resolve(bookmark: bookmark, item: item) {
            case .success(let destination):
                await MainActor.run {
                    guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                        return
                    }
                    let resolvedLocationKey = ArkFileContentBookmark.locationKey(
                        item: item,
                        articleUrl: destination.url.absoluteString,
                        pageNumber: nil,
                        chapterIndex: nil,
                        anchorId: "",
                        scrollTop: 0
                    )
                    activeSavedZIMBookmarkAlias = ArkFileSavedZIMBookmarkAlias(
                        bookmarkID: bookmark.id,
                        resolvedLocationKey: resolvedLocationKey
                    )
                    browser.load(url: destination.url, continuing: readerOpenIntent)
                }
            case .failure(let failure):
                guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                    return
                }
                arkFileOpenError = failure.message(itemName: item.displayName)
            }
        }
    }

    private func openArkFileZim(
        _ item: ArkFileLocalContentItem,
        continuing readerOpenIntent: ArkFileReaderOpenIntent
    ) async {
        activeSavedZIMBookmarkAlias = nil
        guard let fileID = await LibraryOperations.openFileID(url: item.url) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                arkFileOpenError = "ArkFile could not register \(item.displayName) as readable content."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard await ZimFileService.shared.openArchive(zimFileID: fileID) != nil else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                arkFileOpenError = "ArkFile could not open the current local copy of \(item.displayName)."
            }
            return
        }
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else { return }
        guard let url = await ZimFileService.shared.getMainPageURL(zimFileID: fileID) else {
            if ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) {
                arkFileOpenError = "ArkFile opened \(item.displayName), but could not find its main page."
            }
            return
        }
        await MainActor.run {
            browser.load(url: url, continuing: readerOpenIntent)
        }
    }
}

private struct Content<LaunchModel>: View where LaunchModel: LaunchProtocol {
    @ObservedObject var browser: BrowserViewModel
    let tabID: NSManagedObjectID?
    let showLibrary: () -> Void
    let showSettings: () -> Void
    let canPresentInstallerAlerts: @MainActor @Sendable () -> Bool
    @ObservedObject var model: LaunchModel
    @Binding var packComparisonPresentation: Bool
    @Binding var mapPurchaseContext: ArkFileMapPurchaseContext?
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @StateObject private var arkFileContentLibrary = ArkFileLocalContentLibrary.shared
    @State private var isReplayingArkFileOnboarding = false
    @State private var replayOnboardingDestination: ArkFileOnboardingDestination?
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
        predicate: ZimFile.openedPredicate()
    ) private var zimFiles: FetchedResults<ZimFile>
    
    /// this is still hacky a bit, as the change from here re-validates the view
    /// which triggers the model to be revalidated
    @Default(.hasSeenCategories) private var hasSeenCategories

    private var hasOpenedNonSampleZimFiles: Bool {
        arkFileContentLibrary.hasNonSampleOpenedZimFiles(in: zimFiles)
    }

    var body: some View {
        launchSurface
            .focusedSceneValue(\.isBrowserURLSet, browser.url != nil)
            .focusedSceneValue(\.canGoBack, browser.canGoBack)
            .focusedSceneValue(\.canGoForward, browser.canGoForward)
            .focusedSceneValue(\.hasZIMFiles, hasOpenedNonSampleZimFiles)
            .preference(key: GlobalSearchVisibilityPreferenceKey.self, value: model.state.showsGlobalSearch)
            .modifier(ExternalLinkHandler(externalURL: $browser.externalURL))
            .task { [weak browser] in
                await browser?.updateLastOpened()
            }
            .onDisappear { [weak browser] in
                if tabID != nil {
                    browser?.flushArkFileReadingHistory()
                    browser?.pauseVideoWhenNotInPIP()
                    Task { @MainActor [weak browser] in
                        await browser?.persistState()
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !Brand.hideFindInPage, model.state.isWebPage {
                        ContentSearchButton(browser: browser)
                    }
                    if shouldShowToolbarSettingsButton {
                        Button {
                            showSettings()
                        } label: {
                            Label(LocalString.common_tab_menu_settings, systemImage: "gear")
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                if case .active = newValue {
                    browser.refreshVideoState()
                } else if case .inactive = newValue {
                    browser.flushArkFileReadingHistory()
                    Task { @MainActor [weak browser] in
                        await browser?.persistState()
                    }
                }
            }
            .onChange(of: library.state) { _, state in
                guard state == .complete else { return }
                showTheLibrary()
            }
            .task {
                await arkFileContentLibrary.refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .arkFileReplayOnboarding)
            ) { _ in
                guard Device.current == .iPhone else {
                    // iPad owns replay in its scene-scoped shell so the sheet
                    // survives compact/regular presentation changes.
                    return
                }
                replayOnboardingDestination = nil
                isReplayingArkFileOnboarding = true
            }
            .sheet(
                isPresented: $isReplayingArkFileOnboarding,
                onDismiss: finishReplayedOnboarding
            ) {
                ArkFileOnboardingView { destination in
                    replayOnboardingDestination = destination
                    isReplayingArkFileOnboarding = false
                }
            }
    }

    @ViewBuilder
    private var launchSurface: some View {
        Group {
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.updateWith(hasZimFiles: hasOpenedNonSampleZimFiles || arkFileContentLibrary.hasNonSampleContent,
                                     hasSeenCategories: hasSeenCategories,
                                     hasBrowserURL: browser.hasURL)
            switch model.state {
            case .loadingData, .webPage:
                ZStack {
                    LoadingDataView()
                        .opacity(model.state == .loadingData ? 1.0 : 0.0)
                    WebView(browser: browser)
                        .opacity(model.state == .loadingData ? 0.0 : 1.0)
                        .overlay {
                            if case .webPage(let isLoading) = model.state, isLoading {
                                LoadingProgressView()
                            }
                        }
                }
            case .catalog(let catalogSequence):
                switch catalogSequence {
                case .fetching:
                    FetchingCatalogView()
                case .list:
                    LocalLibraryList(
                        browser: browser,
                        canPresentInstallerAlerts: canPresentInstallerAlerts
                    )
                case .welcome(let welcomeViewState):
                    WelcomeCatalog(
                        viewState: welcomeViewState,
                        showSettings: showSettings,
                        packComparisonPresentation: $packComparisonPresentation,
                        mapPurchaseContext: $mapPurchaseContext,
                        canPresentInstallerAlerts: canPresentInstallerAlerts
                    )
                }
            }
        }
    }

    private var shouldShowToolbarSettingsButton: Bool {
        if case .catalog(.welcome) = model.state {
            return FeatureFlags.hasCatalog
        }
        return true
    }

    private func showTheLibrary() {
        guard model.state.shouldShowCatalog else { return }
        if horizontalSizeClass == .regular {
            navigation.currentItem = .categories
        } else {
            showLibrary()
        }
    }

    private func finishReplayedOnboarding() {
        UserDefaults.standard.set(
            true,
            forKey: ArkFileOnboardingView.completedDefaultsKey
        )
        guard let destination = replayOnboardingDestination else { return }
        replayOnboardingDestination = nil
        guard destination != .home else { return }
        browser.clearForHome()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: .arkFileOnboardingDestination,
                object: destination
            )
        }
    }
}
#endif
