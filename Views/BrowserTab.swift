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
import Defaults
import CoreData

/// This is macOS and iPad only specific, not used on iPhone
struct BrowserTab: View {
    @ObservedObject var browser: BrowserViewModel
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryViewModel
    @StateObject private var search = SearchViewModel.shared
#if os(iOS)
    @StateObject private var arkFileContentLibrary =
        ArkFileLocalContentLibrary.shared
    @StateObject private var arkFileFavorites =
        ArkFileContentFavorites.shared
    @StateObject private var arkFileBookmarks =
        ArkFileContentBookmarks.shared
    @State private var isShowingArkFileBookmarks = false
    @State private var isShowingArkFileBookmarkEditor = false
    @State private var arkFileBookmarkBeingEdited:
        ArkFileContentBookmark?
    @State private var activeSavedZIMBookmarkAlias:
        ArkFileSavedZIMBookmarkAlias?
    @State private var arkFileOpenError: String?
    private let openBookmarkedContent:
        (ArkFileLocalContentItem, ArkFileContentBookmark) -> Void
#endif
    /// used on iPad
    private let didChangeTitle: ((NSManagedObjectID, String) -> Void)?

#if os(iOS)
    init(
        tabID: NSManagedObjectID,
        openBookmarkedContent: @escaping (
            ArkFileLocalContentItem,
            ArkFileContentBookmark
        ) -> Void,
        didChangeTitle: ((NSManagedObjectID, String) -> Void)? = nil
    ) {
        self.openBookmarkedContent = openBookmarkedContent
        self.didChangeTitle = didChangeTitle
        self.browser = BrowserViewModel.getCached(tabID: tabID)
    }
#else
    init(tabID: NSManagedObjectID, didChangeTitle: ((NSManagedObjectID, String) -> Void)? = nil) {
        self.didChangeTitle = didChangeTitle
        self.browser = BrowserViewModel.getCached(tabID: tabID)
    }
#endif

    var body: some View {
        let model = if FeatureFlags.hasLibrary {
            CatalogLaunchViewModel(library: library, browser: browser)
        } else {
            NoCatalogLaunchViewModel(browser: browser)
        }
        Content(browser: browser, model: model).toolbar {
#if os(macOS)
            ToolbarItemGroup(placement: .navigation) {
                NavigationButtons(
                    goBack: { [weak browser] in
                        browser?.webView.goBack()
                    },
                    goForward: { [weak browser] in
                        browser?.webView.goForward()
                    })
            }
#elseif os(iOS)
            ToolbarItemGroup(placement: .navigationBarLeading) {
                NavigationButtons(
                    goBack: { [weak browser] in
                        browser?.webView.goBack()
                    },
                    goForward: { [weak browser] in
                        browser?.webView.goForward()
                    })
            }
#endif
            ToolbarItemGroup(placement: .primaryAction) {
                if !Brand.hideTOCButton {
                    OutlineButton(browser: browser)
                }
#if os(iOS)
                if !Brand.hideShareButton {
                    ExportButton(
                        articleTitle: browser.articleTitle,
                        webViewURL: browser.webView.url,
                        pageDataWithExtension: { [weak browser] in await browser?.pageDataWithExtension() },
                        isButtonDisabled: browser.zimFileName.isEmpty
                    )
                }
#else
                if !Brand.hideShareButton {
                    Menu {
                        ExportButton(
                            relativeToView: browser.webView,
                            articleTitle: browser.articleTitle,
                            webViewURL: browser.webView.url,
                            pageDataWithExtension: { [weak browser] in await browser?.pageDataWithExtension() },
                            isButtonDisabled: browser.zimFileName.isEmpty,
                            buttonLabel: LocalString.common_button_share_as_pdf
                        )
                        if let url = browser.webView.url {
                            Button(LocalString.common_button_copy) {
                                CopyPaste.copyToPasteBoard(url: url)
                            }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                        }
                    } label: {
                        Label(LocalString.common_button_share, systemImage: "square.and.arrow.up")
                    }.disabled(browser.webView.url == nil)
                }
                if !Brand.hidePrintButton {
                    PrintButton(articleTitle: { [weak browser] in
                        browser?.articleTitle
                    }, browserDataAsPDF: { [weak browser] in
                        try await browser?.webView.pdf()
                    })
                }
#endif
#if os(iOS)
                if let currentArkFileZimItem {
                    Button {
                        arkFileFavorites.toggle(currentArkFileZimItem)
                    } label: {
                        Image(
                            systemName: arkFileFavorites.isFavorite(
                                currentArkFileZimItem
                            ) ? "star.fill" : "star"
                        )
                    }
                    .accessibilityLabel(
                        arkFileFavorites.isFavorite(currentArkFileZimItem)
                            ? "Remove from Favorites"
                            : "Add to Favorites"
                    )
                    .accessibilityIdentifier("ArkFileZimFavorite")

                    Button {
                        isShowingArkFileBookmarks = true
                    } label: {
                        Image(
                            systemName:
                                currentArkFileZimBookmark == nil
                                    ? "bookmark"
                                    : "bookmark.fill"
                        )
                    }
                    .accessibilityLabel("Bookmarks")
                    .accessibilityIdentifier("ArkFileZimBookmarks")
                } else {
                    BookmarkButton(
                        articleBookmarked: browser.articleBookmarked,
                        isButtonDisabled: browser.zimFileName.isEmpty,
                        createBookmark: {
                            [weak browser] in browser?.createBookmark()
                        },
                        deleteBookmark: {
                            [weak browser] in browser?.deleteBookmark()
                        }
                    )
                }
                if !Brand.hideFindInPage {
                    ContentSearchButton(browser: browser)
                }
#else
                BookmarkButton(
                    articleBookmarked: browser.articleBookmarked,
                    isButtonDisabled: browser.zimFileName.isEmpty,
                    createBookmark: {
                        [weak browser] in browser?.createBookmark()
                    },
                    deleteBookmark: {
                        [weak browser] in browser?.deleteBookmark()
                    }
                )
#endif
                ArticleShortcutButtons(
                    loadMainArticle: { [weak browser] zimFileID in
                        browser?.loadMainArticle(zimFileID: zimFileID)
                    },
                    loadRandomArticle: { [weak browser] zimFileID in
                        browser?.loadRandomArticle(zimFileID: zimFileID)
                    })
            }
        }
        .environmentObject(search)
#if os(iOS)
        .sheet(isPresented: $isShowingArkFileBookmarks) {
            if let currentArkFileZimItem {
                ArkFileBookmarkPanel(
                    currentItem: currentArkFileZimItem,
                    favorites: arkFileFavorites,
                    bookmarks: arkFileBookmarks,
                    addCurrentBookmark: {
                        arkFileBookmarkBeingEdited =
                            currentArkFileZimBookmark
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
                existingTags:
                    arkFileBookmarkBeingEdited?.tags ?? [],
                existingNotes:
                    arkFileBookmarkBeingEdited?.notes ?? ""
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
#endif
        .focusedSceneValue(\.isBrowserURLSet, browser.url != nil)
#if os(macOS)
        .focusedSceneValue(\.browserURL, browser.url)
#endif
        .focusedSceneValue(\.canGoBack, browser.canGoBack)
        .focusedSceneValue(\.canGoForward, browser.canGoForward)
        .modifier(ExternalLinkHandler(externalURL: $browser.externalURL))
        .searchable(
            text: $search.searchText,
            placement: .toolbarPrincipal,
            prompt: LocalString.common_search
        )
        .onChange(of: scenePhase) { [weak browser] _, newValue in
            if case .active = newValue {
                browser?.refreshVideoState()
            } else if case .inactive = newValue {
                // A reader can remain mounted while iPadOS backgrounds and
                // later terminates the scene. Capture WebKit history before
                // the app-level Core Data save so relaunch restores the page
                // and back-forward list the person actually left.
                browser?.flushArkFileReadingHistory()
                Task { @MainActor [weak browser] in
                    await browser?.persistState()
                }
            }
        }
        .modify { [weak browser] view in
#if os(macOS)
            if let browser {
                view.navigationTitle(browser.articleTitle.isEmpty ? Brand.appName : browser.articleTitle)
                    .navigationSubtitle(browser.zimFileName)
            } else {
                view
            }
#elseif os(iOS)
            view
#endif
        }
        .task { [weak browser] in
#if os(iOS)
            await arkFileContentLibrary.refresh()
#endif
            await browser?.updateLastOpened()
        }
        .onChange(of: browser.articleTitle) { [weak browser] oldTitle, newTitle in
            guard let browser, newTitle != oldTitle else { return }
            didChangeTitle?(browser.tabID, newTitle)
        }
        .onDisappear { [weak browser] in
            browser?.pauseVideoWhenNotInPIP()
            Task { [weak browser] in
                await browser?.persistState()
            }
        }
    }

#if os(iOS)
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
        return try? Database.shared.viewContext.fetch(
            ZimFile.fetchRequest(fileID: zimFileID)
        ).first
    }

    private var currentArkFileZimBookmark:
        ArkFileContentBookmark? {
        guard let locationKey = currentArkFileZimLocationKey else {
            return nil
        }
        if let exact = arkFileBookmarks.bookmark(
            matching: locationKey
        ) {
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
        if let title =
            arkFileBookmarkBeingEdited?.articleTitle,
           !title.isEmpty {
            return title
        }
        let title = browser.articleTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !title.isEmpty {
            return title
        }
        return currentArkFileZimItem?.displayName ?? "Bookmark"
    }

    private func saveCurrentArkFileBookmark(
        tags: [String],
        notes: String
    ) {
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
        let existing =
            arkFileBookmarkBeingEdited
            ?? arkFileBookmarks.bookmark(matching: locationKey)
        if var existing {
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
            schemaVersion:
                ArkFileContentBookmark.currentSchemaVersion,
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

    private func openArkFileBookmark(
        _ bookmark: ArkFileContentBookmark
    ) {
        let readerOpenIntent =
            ArkFileReaderOpenIntentCoordinator.shared
                .beginForCurrentReader()
        guard let item = arkFileContentLibrary.allItems.first(
            where: {
                $0.relativePath == bookmark.relativePath
            }
        ) else {
            arkFileOpenError =
                "ArkFile could not find \(bookmark.fileName) in the local library. The Saved entry was kept."
            return
        }
        isShowingArkFileBookmarks = false

        guard item.type == .zim else {
            // Bookmarks spans the whole library. Let the scene present a
            // static reader with its saved page or chapter intact.
            openBookmarkedContent(item, bookmark)
            return
        }

        Task {
            switch await ArkFileSavedZIMResolver.resolve(
                bookmark: bookmark,
                item: item
            ) {
            case .success(let destination):
                guard ArkFileReaderOpenIntentCoordinator.shared
                    .isCurrent(readerOpenIntent) else {
                    return
                }
                let resolvedLocationKey =
                    ArkFileContentBookmark.locationKey(
                        item: item,
                        articleUrl:
                            destination.url.absoluteString,
                        pageNumber: nil,
                        chapterIndex: nil,
                        anchorId: "",
                        scrollTop: 0
                    )
                activeSavedZIMBookmarkAlias =
                    ArkFileSavedZIMBookmarkAlias(
                        bookmarkID: bookmark.id,
                        resolvedLocationKey:
                            resolvedLocationKey
                    )
                browser.load(
                    url: destination.url,
                    continuing: readerOpenIntent
                )
            case .failure(let failure):
                guard ArkFileReaderOpenIntentCoordinator.shared
                    .isCurrent(readerOpenIntent) else {
                    return
                }
                arkFileOpenError = failure.message(
                    itemName: item.displayName
                )
            }
        }
    }
#endif

    private struct Content<LaunchModel>: View where LaunchModel: LaunchProtocol {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        let browser: BrowserViewModel
        @EnvironmentObject private var library: LibraryViewModel
        @EnvironmentObject private var navigation: NavigationViewModel
        @StateObject private var arkFileContentLibrary = ArkFileLocalContentLibrary.shared
        @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \ZimFile.size, ascending: false)],
            predicate: ZimFile.openedPredicate()
        ) private var zimFiles: FetchedResults<ZimFile>
        /// this is still hacky a bit, as the change from here re-validates the view
        /// which triggers the model to be revalidated
        @Default(.hasSeenCategories) private var hasSeenCategories
        @ObservedObject var model: LaunchModel
        @StateObject private var search = SearchViewModel.shared

        private var hasOpenedNonSampleZimFiles: Bool {
            arkFileContentLibrary.hasNonSampleOpenedZimFiles(in: zimFiles)
        }

        var body: some View {
            // swiftlint:disable:next redundant_discardable_let
            let _ = model.updateWith(hasZimFiles: hasOpenedNonSampleZimFiles || arkFileContentLibrary.hasNonSampleContent,
                                     hasSeenCategories: hasSeenCategories,
                                     hasBrowserURL: browser.hasURL)
            GeometryReader { proxy in
                Group {
                    if !search.searchText.isEmpty {
                        SearchResults()
                            .environment(\.horizontalSizeClass, proxy.size.width > 650 ? .regular : .compact)
                    } else {
                        switch model.state {
                        case .loadingData, .webPage:
                            ZStack {
                                LoadingDataView()
                                    .opacity(model.state == .loadingData ? 1.0 : 0.0)
                                WebView(browser: browser)
                                    .opacity(model.state == .loadingData ? 0.0 : 1.0)
                                    .ignoresSafeArea()
                                    .overlay {
                                        if case .webPage(let isLoading) = model.state, isLoading {
                                            LoadingProgressView()
                                                .background(Color.background)
                                        }
                                    }
#if os(macOS)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !Brand.hideFindInPage {
                                            ContentSearchBar(
                                                model: ContentSearchViewModel(
                                                    findInWebPage: browser.webView.find(_:configuration:)
                                                )
                                            )
                                        }
                                    }
#endif
                            }
                        case .catalog(.fetching):
                            FetchingCatalogView()
                        case .catalog(.list):
                            LocalLibraryList(browser: browser)
                        case .catalog(.welcome(let welcomeViewState)):
                            WelcomeCatalog(viewState: welcomeViewState)
                        }
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
        }

        private func showTheLibrary() {
            guard model.state.shouldShowCatalog else { return }
            navigation.currentItem = .categories
        }
    }
}
