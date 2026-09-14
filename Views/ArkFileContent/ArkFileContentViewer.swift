// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum ArkFileReaderChromeLayoutPolicy {
    static let minimumControlDimension: CGFloat = 44

    static func usesStackedHeader(
        isCompactWidth: Bool,
        isAccessibilitySize: Bool
    ) -> Bool {
        isCompactWidth || isAccessibilitySize
    }
}

/// A reader presentation carries its saved location with its content. Keeping
/// these in separate view state lets navigation build the destination before
/// the bookmark reaches it, opening at the beginning and replacing history.
struct ArkFileContentReaderDestination: Identifiable, Hashable {
    let id = UUID()
    let item: ArkFileLocalContentItem
    let bookmark: ArkFileContentBookmark?

    init(item: ArkFileLocalContentItem, bookmark: ArkFileContentBookmark? = nil) {
        self.item = item
        self.bookmark = bookmark
    }
}

struct ArkFileContentViewer: View {
    let item: ArkFileLocalContentItem
    var initialBookmark: ArkFileContentBookmark?
    var openContentItem: (ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void = { _, _ in }
    var toggleSidebar: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var favorites = ArkFileContentFavorites.shared
    @StateObject private var bookmarks = ArkFileContentBookmarks.shared
    @StateObject private var pdfController = ArkFilePDFReaderController()
    @StateObject private var webController = ArkFileWebReaderController()
    @StateObject private var imageController = ArkFileImageReaderController()
    @StateObject private var contentLibrary = ArkFileLocalContentLibrary.shared

    @State private var isAccessBlocked = false
    @State private var blockedTier: ArkFileContentTier = .lite
    @State private var isShowingBookmarks = false
    @State private var isShowingBookmarkEditor = false
    @State private var reopensBookmarksAfterEditor = false
    @State private var bookmarkBeingEdited: ArkFileContentBookmark?
    @State private var selectedHTMLBookURL: URL?
    @State private var htmlBookEntries: [ArkFileHTMLBookEntry] = []
    @State private var activeBookmark: ArkFileContentBookmark?
    @State private var bookmarkRestoreGeneration = 0
    @State private var pendingWebBookmarkLocation: ArkFileWebLocationSnapshot?
    @State private var bookmarkSaveError: String?
    @State private var contentLicenseIndex: ArkFileContentLicenseIndex?
    @State private var selectedLicenseEntry: ArkFileContentLicenseEntry?
    @State private var savedOpenError: String?
    @State private var isReaderVisible = false

    init(
        item: ArkFileLocalContentItem,
        initialBookmark: ArkFileContentBookmark? = nil,
        openContentItem: @escaping (ArkFileLocalContentItem, ArkFileContentBookmark?) -> Void = { _, _ in },
        toggleSidebar: (() -> Void)? = nil
    ) {
        self.item = item
        self.initialBookmark = initialBookmark
        self.openContentItem = openContentItem
        self.toggleSidebar = toggleSidebar
        // PDF/WebKit must receive the saved target on their first render,
        // before either reader can publish its initial page as new progress.
        _activeBookmark = State(initialValue: initialBookmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            readerTopBar
            Divider()
            if item.isNoLongerDistributedByArkFile {
                noLongerDistributedNotice
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            readerBottomBar
        }
        .background(Color.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .focusedSceneValue(\.historyNavigationActions, focusedHistoryNavigationActions)
        .focusedSceneValue(\.canGoBack, canGoBack)
        .focusedSceneValue(\.canGoForward, canGoForward)
        .sheet(isPresented: $isShowingBookmarks) {
            ArkFileBookmarkPanel(
                currentItem: item,
                favorites: favorites,
                bookmarks: bookmarks,
                addCurrentBookmark: {
                    beginAddingBookmark()
                },
                openBookmark: openBookmark,
                deleteBookmark: bookmarks.delete
            )
        }
        .sheet(isPresented: $isShowingBookmarkEditor, onDismiss: {
            pendingWebBookmarkLocation = nil
            if reopensBookmarksAfterEditor {
                reopensBookmarksAfterEditor = false
                isShowingBookmarks = true
            }
        }) {
            ArkFileBookmarkEditor(
                title: bookmarkEditorTitle,
                existingTags: bookmarkBeingEdited?.tags ?? [],
                existingNotes: bookmarkBeingEdited?.notes ?? ""
            ) { tags, notes in
                let didSave = saveCurrentBookmark(tags: tags, notes: notes)
                if didSave {
                    reopensBookmarksAfterEditor = true
                }
                isShowingBookmarkEditor = false
            }
        }
        .sheet(item: $selectedLicenseEntry) { entry in
            NavigationStack {
                ArkFileContentLicenseDetailView(
                    entry: entry,
                    ledgerVersion: contentLicenseIndex?.ledgerVersion ?? "Unknown"
                )
            }
        }
        .alert(
            "Couldn’t Open Saved Item",
            isPresented: Binding(
                get: { savedOpenError != nil },
                set: { if !$0 { savedOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                savedOpenError = nil
            }
        } message: {
            Text(savedOpenError ?? "")
        }
        .alert(
            "Couldn’t Save Bookmark",
            isPresented: Binding(
                get: { bookmarkSaveError != nil },
                set: { if !$0 { bookmarkSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                bookmarkSaveError = nil
            }
        } message: {
            Text(bookmarkSaveError ?? "")
        }
        .onAppear {
            isReaderVisible = true
            if contentLicenseIndex == nil {
                contentLicenseIndex = try? ArkFileContentLicenseIndex.loadBundled()
            }
            refreshAccessBlock()
            if let initialBookmark {
                activeBookmark = initialBookmark
                applyBookmark(initialBookmark)
            }
            recordReadingHistory(force: true)
        }
        .onDisappear {
            recordReadingHistory(force: true)
            isReaderVisible = false
        }
        .onChange(of: scenePhase) { _, phase in
            if isReaderVisible, phase != .active {
                // No asynchronous WebKit work: iOS can suspend us immediately.
                recordReadingHistory(force: true)
            }
        }
        .onReceive(pdfController.readingHistoryCheckpoints) { _ in
            guard isReaderVisible, scenePhase == .active, item.type == .pdf else { return }
            recordReadingHistory()
        }
        .onReceive(webController.readingHistoryCheckpoints) { _ in
            guard isReaderVisible, scenePhase == .active else { return }
            recordReadingHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileGoHome)) { _ in
            refreshAccessBlock()
        }
    }

    private func refreshAccessBlock() {
        blockedTier = ArkFileEssentialsAccessGate.requiredTierForManagedURL(item.url) ?? .lite
        isAccessBlocked = ArkFileEssentialsAccessGate.resolvedURLForReading(item.url) == nil
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if isAccessBlocked {
                ContentUnavailableView(
                    "\(ArkFileContentPackDisplayName.name(for: blockedTier)) Content Needs Repair",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("This downloaded file is missing, incomplete, or could not be verified locally. Keep the rest of your offline library in place and use Manage Downloads to repair this item when a network is available.")
                )
            } else {
                switch item.type {
            case .pdf:
                ArkFilePDFViewer(
                    url: item.url,
                    controller: pdfController,
                    targetPage: activeBookmark?.pageNumber
                )
                .id(item.id)
            case .html:
                let resolvedURL = bookmarkFileURL(activeBookmark) ?? item.url
                ArkFileHTMLViewer(
                    url: resolvedURL,
                    readAccessURL: ArkFileWebReaderURL.staticDocumentReadAccessURL(for: item.url),
                    accessGuardURL: item.url,
                    controller: webController,
                    targetScrollTop: bookmarkTargetScrollTop(activeBookmark),
                    targetScrollID: bookmarkTargetID(activeBookmark),
                    targetAnchorID: bookmarkTargetAnchorID(activeBookmark)
                )
            case .htmlBook:
                let resolvedInitialURL = selectedHTMLBookURL ?? bookmarkFileURL(activeBookmark)
                ArkFileHTMLBookViewer(
                    item: item,
                    controller: webController,
                    initialURL: resolvedInitialURL,
                    initialChapterPath: activeBookmark?.chapterPath,
                    targetScrollTop: bookmarkTargetScrollTop(activeBookmark),
                    targetScrollID: bookmarkTargetID(activeBookmark),
                    targetAnchorID: bookmarkTargetAnchorID(activeBookmark),
                    waitsForResolvedInitialURL: resolvedInitialURL == nil,
                    onEntriesLoaded: { entries in
                        htmlBookEntries = entries
                    },
                    onInitialURLResolved: { initialURL in
                        if selectedHTMLBookURL == nil {
                            selectedHTMLBookURL = initialURL
                        }
                    }
                )
            case .image:
                if item.url.pathExtension.lowercased() == "svg" {
                    ArkFileHTMLViewer(
                        url: item.url,
                        readAccessURL: ArkFileWebReaderURL.staticDocumentReadAccessURL(for: item.url),
                        accessGuardURL: item.url,
                        controller: webController
                    )
                } else {
                    ArkFileImageViewer(url: item.url, title: item.name, controller: imageController)
                        .id(item.id)
                }
            case .map:
                ArkFileOfflineMapView(contentRoot: contentLibrary.contentRoot ?? item.url.deletingLastPathComponent())
            case .zim:
                Message(text: LocalString.arkfile_content_viewer_zim_message)
                }
            }
        }
    }

    private var readerTopBar: some View {
        Group {
            if usesStackedReaderHeader {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        readerLeadingControls
                        readerTitle(lineLimit: 2)
                    }
                    readerUtilityControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 4) {
                    readerLeadingControls
                    readerTitle(lineLimit: 1)
                    Spacer(minLength: 8)
                    readerUtilityControls
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.arkSurface)
        .tint(Color.arkTeal)
    }

    private var usesStackedReaderHeader: Bool {
        ArkFileReaderChromeLayoutPolicy.usesStackedHeader(
            isCompactWidth: horizontalSizeClass == .compact,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private var readerLeadingControls: some View {
        HStack(spacing: 4) {
            if let toggleSidebar {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .frame(
                            width:
                                ArkFileReaderChromeLayoutPolicy
                                    .minimumControlDimension,
                            height:
                                ArkFileReaderChromeLayoutPolicy
                                    .minimumControlDimension
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Show or Hide Sidebar")
                .accessibilityIdentifier(
                    "arkfile_ipad_sidebar_toggle"
                )
            }
            Button {
                ArkFileReaderOpenIntentCoordinator.shared.invalidateForCurrentReader()
                recordReadingHistory(force: true)
                // Navigation is the user's current intent and must not wait on
                // an asynchronous WebKit position snapshot. Otherwise a late
                // Home notification can override a newer sidebar selection.
                NotificationCenter.default.post(name: .arkFileGoHome, object: nil)
                dismiss()
            } label: {
                Image(Brand.loadingLogoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.arkGold.opacity(0.8), lineWidth: 1)
                    }
                    .frame(
                        width:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension,
                        height:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("ArkFile Home")
        }
    }

    private func readerTitle(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkInk)
                .lineLimit(lineLimit)
            Text(item.type.displayLabel)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(Color.arkTaupe)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var readerUtilityControls: some View {
        HStack(spacing: 4) {
            Button {
                favorites.toggle(item)
            } label: {
                Image(systemName: favorites.isFavorite(item) ? "star.fill" : "star")
                    .foregroundStyle(favorites.isFavorite(item) ? Color.arkGold : Color.arkTeal)
                    .frame(
                        width:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension,
                        height:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(favorites.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites")

            Button {
                isShowingBookmarks = true
            } label: {
                Image(systemName: hasBookmarkForCurrentLocation ? "bookmark.fill" : "bookmark")
                    .frame(
                        width:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension,
                        height:
                            ArkFileReaderChromeLayoutPolicy
                                .minimumControlDimension
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Bookmarks")

            if let entry = contentLicenseEntry {
                Button {
                    selectedLicenseEntry = entry
                } label: {
                    Image(systemName: "info.circle")
                        .frame(
                            width:
                                ArkFileReaderChromeLayoutPolicy
                                    .minimumControlDimension,
                            height:
                                ArkFileReaderChromeLayoutPolicy
                                    .minimumControlDimension
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("License and source for \(item.displayName)")
            }
        }
    }

    private var contentLicenseEntry: ArkFileContentLicenseEntry? {
        contentLicenseIndex?.entry(forRelativePath: item.relativePath)
    }

    private var noLongerDistributedNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(Color.arkGold)
            Text(ArkFileContentRetirementPolicy.retainedDeletionWarning)
                .font(.caption)
                .foregroundStyle(Color.arkInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.arkGold.opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var readerBottomBar: some View {
        if item.type == .htmlBook {
            htmlBookUtilityBar
        } else {
            standardReaderBottomBar
        }
    }

    private var standardReaderBottomBar: some View {
        HStack(spacing: 0) {
            contentControlButton("chevron.left", "Previous") {
                if item.type == .pdf {
                    pdfController.goToPreviousPage()
                } else {
                    webController.goBack()
                }
            }
            .disabled(!canGoBack)

            contentControlButton("chevron.right", "Next") {
                if item.type == .pdf {
                    pdfController.goToNextPage()
                } else {
                    webController.goForward()
                }
            }
            .disabled(!canGoForward)

            contentControlButton("minus.magnifyingglass", "Zoom Out") {
                if item.type == .pdf {
                    pdfController.zoomOut()
                } else if usesImageReader {
                    imageController.zoomOut()
                } else {
                    webController.zoomOut()
                }
            }

            contentControlButton("plus.magnifyingglass", "Zoom In") {
                if item.type == .pdf {
                    pdfController.zoomIn()
                } else if usesImageReader {
                    imageController.zoomIn()
                } else {
                    webController.zoomIn()
                }
            }

            contentControlButton("arrow.up", "Top") {
                if item.type == .pdf {
                    pdfController.scrollToTop()
                } else if usesImageReader {
                    imageController.scrollToTop()
                } else {
                    webController.scrollToTop()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.arkSurface)
        .tint(Color.arkTeal)
    }

    private var htmlBookUtilityBar: some View {
        HStack(spacing: 0) {
            contentControlButton("minus.magnifyingglass", "Zoom Out") {
                webController.zoomOut()
            }

            contentControlButton("plus.magnifyingglass", "Zoom In") {
                webController.zoomIn()
            }

            contentControlButton("arrow.up", "Top") {
                webController.scrollToTop()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.arkSurface)
        .tint(Color.arkTeal)
    }

    private func contentControlButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight:
                        ArkFileReaderChromeLayoutPolicy
                            .minimumControlDimension
                )
                .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }

    private var canGoBack: Bool {
        if usesImageReader { return false }
        return item.type == .pdf ? pdfController.canGoBack : webController.canGoBack
    }

    private var canGoForward: Bool {
        if usesImageReader { return false }
        return item.type == .pdf ? pdfController.canGoForward : webController.canGoForward
    }

    private var focusedHistoryNavigationActions:
        FocusedHistoryNavigationActions {
        if item.type == .pdf {
            return FocusedHistoryNavigationActions(
                targetID: ObjectIdentifier(pdfController),
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                goBack: { [weak pdfController] in pdfController?.goToPreviousPage() },
                goForward: { [weak pdfController] in pdfController?.goToNextPage() }
            )
        }
        return FocusedHistoryNavigationActions(
            targetID: ObjectIdentifier(webController),
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            goBack: { [weak webController] in webController?.goBack() },
            goForward: { [weak webController] in webController?.goForward() }
        )
    }

    private var usesImageReader: Bool {
        item.type == .image && item.url.pathExtension.lowercased() != "svg"
    }

    private var bookmarkEditorTitle: String {
        if let title = bookmarkBeingEdited?.articleTitle {
            return title
        }
        if let anchorLabel = pendingWebBookmarkLocation?.anchorLabel
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !anchorLabel.isEmpty {
            return anchorLabel
        }
        return currentBookmarkTitle()
    }

    private func beginAddingBookmark() {
        bookmarkBeingEdited = nil
        pendingWebBookmarkLocation = nil
        guard item.type == .html || item.type == .htmlBook else {
            isShowingBookmarks = false
            isShowingBookmarkEditor = true
            return
        }
        Task { @MainActor in
            guard let snapshot = await webController.currentLocationSnapshot() else {
                isShowingBookmarks = false
                bookmarkSaveError = "Wait for this book to finish loading, then try adding the bookmark again."
                return
            }
            pendingWebBookmarkLocation = snapshot
            isShowingBookmarks = false
            isShowingBookmarkEditor = true
        }
    }

    private var hasBookmarkForCurrentLocation: Bool {
        guard let locationKey = currentLocationKeyApproximation() else { return false }
        return bookmarks.bookmark(matching: locationKey) != nil
    }

    private func currentLocationKeyApproximation() -> String? {
        switch item.type {
        case .pdf:
            return ArkFileContentBookmark.locationKey(
                item: item,
                articleUrl: "pdf:\(item.relativePath)",
                pageNumber: pdfController.pageNumber,
                chapterIndex: nil,
                anchorId: "",
                scrollTop: 0
            )
        case .html, .htmlBook:
            let articleURL = (webController.currentURL ?? selectedHTMLBookURL ?? item.url).absoluteString
            let chapterPath = bookmarkPathComponent()
            return ArkFileContentBookmark.locationKey(
                item: item,
                articleUrl: articleURL,
                pageNumber: nil,
                chapterIndex: currentHTMLBookChapterIndex(),
                chapterPath: chapterPath,
                anchorId: webController.currentAnchorIDSnapshot,
                scrollTop: webController.currentScrollTopSnapshot
            )
        default:
            return ArkFileContentBookmark.locationKey(
                item: item,
                articleUrl: item.url.absoluteString,
                pageNumber: nil,
                chapterIndex: nil,
                anchorId: "",
                scrollTop: 0
            )
        }
    }

    private func currentBookmarkTitle() -> String {
        switch item.type {
        case .pdf:
            "\(item.name) (Page \(pdfController.pageNumber))"
        case .htmlBook:
            webController.title.isEmpty ? item.name : webController.title
        default:
            item.name
        }
    }

    /// Automatic history uses committed cached positions, so a background
    /// flush never waits on JavaScript or races a newer capture. Loading and
    /// bookmark restoration preserve the previous durable entry until ready.
    private func recordReadingHistory(force: Bool = false) {
        let capturedAt = Date()
        guard !isAccessBlocked, item.type != .map else { return }
        let usesWebReader = item.type == .html || item.type == .htmlBook
        let webLocation = usesWebReader ? webController.cachedReadingHistoryLocation : nil
        if usesWebReader, webLocation == nil { return }
        let pageNumber = item.type == .pdf ? pdfController.readingHistoryPageNumber : nil
        if item.type == .pdf, pageNumber == nil { return }
        let currentWebURL = webLocation?.url
        let articleURL = currentWebURL?.absoluteString
            ?? currentArticleURL()
        let chapterPath = bookmarkPathComponent(for: currentWebURL)
        let chapterIndex = currentHTMLBookChapterIndex(for: currentWebURL)
        let scrollTop = webLocation?.scrollTop ?? 0
        let anchorID = webLocation?.anchorID ?? ""
        let anchorLabel = webLocation?.anchorLabel ?? ""
        let locationKey = ArkFileContentBookmark.locationKey(
            item: item,
            articleUrl: articleURL,
            pageNumber: pageNumber,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorID,
            scrollTop: scrollTop
        )
        let entry = ArkFileContentBookmark(
            id: "reading-history-\(item.relativePath.lowercased())",
            schemaVersion: ArkFileContentBookmark.currentSchemaVersion,
            locationKey: locationKey,
            articleUrl: articleURL,
            articleTitle: anchorLabel.isEmpty
                ? currentBookmarkTitle()
                : anchorLabel,
            contentType: item.type,
            relativePath: item.relativePath,
            fileName: item.name,
            pageNumber: pageNumber,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorID,
            anchorLabel: anchorLabel,
            scrollTop: scrollTop,
            tags: [],
            notes: "",
            createdAt: capturedAt,
            updatedAt: capturedAt,
            status: "valid"
        )
        ArkFileReadingHistory.shared.recordProgress(entry, force: force)
    }

    private func saveCurrentBookmark(tags: [String], notes: String) -> Bool {
        let usesWebReader = item.type == .html || item.type == .htmlBook
        if usesWebReader, pendingWebBookmarkLocation == nil {
            bookmarkSaveError = "ArkFile couldn’t read the current book position. Return to the page and try again."
            return false
        }
        let webLocation = pendingWebBookmarkLocation
        let currentWebURL = webLocation?.url
        let scrollTop = webLocation?.scrollTop ?? 0
        let articleURL = currentWebURL?.absoluteString ?? currentArticleURL()
        let chapterPath = bookmarkPathComponent(for: currentWebURL)
        let chapterIndex = currentHTMLBookChapterIndex(for: currentWebURL)
        let anchorID = webLocation.map(resolvedAnchorID(for:)) ?? ""
        let anchorLabel = webLocation?.anchorLabel ?? ""
        let locationKey = ArkFileContentBookmark.locationKey(
            item: item,
            articleUrl: articleURL,
            pageNumber: item.type == .pdf ? pdfController.pageNumber : nil,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorID,
            scrollTop: scrollTop
        )
        let existing = bookmarkBeingEdited ?? bookmarks.bookmark(matching: locationKey)
        let bookmark = ArkFileContentBookmark(
            id: existing?.id ?? UUID().uuidString,
            schemaVersion: ArkFileContentBookmark.currentSchemaVersion,
            locationKey: locationKey,
            articleUrl: articleURL,
            articleTitle: anchorLabel.isEmpty ? currentBookmarkTitle() : anchorLabel,
            contentType: item.type,
            relativePath: item.relativePath,
            fileName: item.name,
            pageNumber: item.type == .pdf ? pdfController.pageNumber : nil,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorID,
            anchorLabel: anchorLabel,
            scrollTop: scrollTop,
            tags: tags,
            notes: notes,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            status: "valid"
        )
        activeBookmark = bookmarks.upsert(bookmark)
        bookmarkBeingEdited = nil
        pendingWebBookmarkLocation = nil
        return true
    }

    private func currentArticleURL() -> String {
        switch item.type {
        case .pdf:
            "pdf:\(item.relativePath)#page=\(pdfController.pageNumber)"
        case .html, .htmlBook:
            (webController.currentURL ?? selectedHTMLBookURL ?? item.url).absoluteString
        case .image:
            "image:\(item.relativePath)"
        case .map:
            "map:\(item.relativePath)"
        case .zim:
            item.url.absoluteString
        }
    }

    private func bookmarkPathComponent(for currentURL: URL? = nil) -> String {
        guard let currentURL = currentURL ?? webController.currentURL ?? selectedHTMLBookURL else {
            return ""
        }
        if item.type == .htmlBook,
           let root = try? ArkFileHTMLBookExtractor.extractedRootURL(for: item),
           let relativePath = ArkFileHTMLBookExtractor.relativePath(from: root, to: currentURL) {
            return relativePath
        }
        guard let root = ArkFileContentPackInstaller.installedContentRootIfAvailable() else {
            return ""
        }
        return currentURL.fileSystemPath
            .replacingOccurrences(of: root.fileSystemPath, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func openBookmark(_ bookmark: ArkFileContentBookmark) {
        guard let targetItem = contentLibrary.allItems.first(where: { $0.relativePath == bookmark.relativePath }) else {
            savedOpenError = "ArkFile could not find \(bookmark.fileName) in the local library. The Saved entry was kept."
            return
        }
        isShowingBookmarks = false
        if targetItem.id == item.id {
            applyBookmark(bookmark)
        } else {
            openContentItem(targetItem, bookmark)
        }
    }

    private func applyBookmark(_ bookmark: ArkFileContentBookmark) {
        activeBookmark = bookmark
        bookmarkRestoreGeneration &+= 1
        if item.type == .html || item.type == .htmlBook,
           let restoreID = bookmarkTargetID(bookmark) {
            webController.beginReadingHistoryRestoration(id: restoreID)
        }
        switch item.type {
        case .pdf:
            pdfController.goToPage(bookmark.pageNumber ?? 1)
        case .html:
            break
        case .htmlBook:
            if let url = bookmarkFileURL(bookmark) {
                selectedHTMLBookURL = url
            }
        default:
            break
        }
    }

    private func bookmarkFileURL(_ bookmark: ArkFileContentBookmark?) -> URL? {
        guard let bookmark else {
            return nil
        }
        if item.type == .htmlBook,
           let bookmarkedURL = try? ArkFileHTMLBookExtractor.bookmarkedURL(
            for: item,
            chapterPath: bookmark.chapterPath,
            articleURL: URL(string: bookmark.articleUrl)
           ) {
            return bookmarkedURL
        }
        guard let url = URL(string: bookmark.articleUrl),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.fileSystemPath) else {
            return nil
        }
        return url
    }

    private func currentHTMLBookChapterIndex(for currentURL: URL? = nil) -> Int? {
        guard item.type == .htmlBook,
              let currentURL = currentURL ?? webController.currentURL ?? selectedHTMLBookURL,
              !htmlBookEntries.isEmpty else {
            return nil
        }
        return ArkFileHTMLBookNavigation.entryIndex(
            committedURL: currentURL,
            initialURL: currentURL,
            entries: htmlBookEntries
        )
    }

    private func resolvedAnchorID(for location: ArkFileWebLocationSnapshot) -> String {
        let capturedAnchor = location.anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !capturedAnchor.isEmpty {
            return capturedAnchor
        }
        let fragment = URLComponents(url: location.url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        return fragment.removingPercentEncoding ?? fragment
    }

    private func bookmarkTargetAnchorID(_ bookmark: ArkFileContentBookmark?) -> String? {
        guard let bookmark else { return nil }
        let storedAnchor = bookmark.anchorId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedAnchor.isEmpty {
            return storedAnchor
        }
        guard let url = URL(string: bookmark.articleUrl) else { return nil }
        let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        let decodedFragment = fragment.removingPercentEncoding ?? fragment
        return decodedFragment.isEmpty ? nil : decodedFragment
    }

    private func bookmarkTargetScrollTop(_ bookmark: ArkFileContentBookmark?) -> Double? {
        guard let bookmark else { return nil }
        if bookmark.scrollTop <= 0, bookmarkTargetAnchorID(bookmark) != nil {
            return nil
        }
        return bookmark.scrollTop
    }

    private func bookmarkTargetID(_ bookmark: ArkFileContentBookmark?) -> String? {
        guard let bookmark else { return nil }
        return "\(bookmark.id)|\(bookmarkRestoreGeneration)"
    }
}

struct ArkFileBookmarkPanel: View {
    let currentItem: ArkFileLocalContentItem
    @ObservedObject var favorites: ArkFileContentFavorites
    @ObservedObject var bookmarks: ArkFileContentBookmarks
    let addCurrentBookmark: () -> Void
    let openBookmark: (ArkFileContentBookmark) -> Void
    let deleteBookmark: (ArkFileContentBookmark) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTag = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = ArkFileBookmarksDocument()
    @State private var importMessage: String?
    @State private var importFailed = false

    private var filteredBookmarks: [ArkFileContentBookmark] {
        bookmarks.filteredBookmarks(searchText: searchText, tag: selectedTag.isEmpty ? nil : selectedTag)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                favoriteSection
                controls
                List {
                    if filteredBookmarks.isEmpty {
                        ContentUnavailableView(
                            "No bookmarks yet",
                            systemImage: "bookmark",
                            description: Text("Open content and add bookmarks with tags or notes.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredBookmarks) { bookmark in
                            Button {
                                openBookmark(bookmark)
                                dismiss()
                            } label: {
                                ArkFileBookmarkRow(bookmark: bookmark)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    deleteBookmark(bookmark)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .background(Color.arkSand.ignoresSafeArea())
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                        addCurrentBookmark()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .tint(Color.arkTeal)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "arkfile-bookmarks-\(Self.exportDateFormatter.string(from: Date())).json"
        ) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: url)
                let stats = try bookmarks.importData(data, merge: true)
                importFailed = false
                importMessage = "Imported \(stats.imported), skipped \(stats.skipped)."
            } catch {
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                importFailed = true
                importMessage = error.localizedDescription
            }
        }
        .alert(
            importFailed ? "Couldn’t Import Bookmarks" : "Import Complete",
            isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                addCurrentBookmark()
            } label: {
                Label("Add Bookmark", systemImage: "bookmark.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkTeal)

            Button {
                favorites.toggle(currentItem)
            } label: {
                Label(
                    favorites.isFavorite(currentItem) ? "Remove from Favorites" : "Favorite this Archive",
                    systemImage: favorites.isFavorite(currentItem) ? "star.fill" : "star"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(favorites.isFavorite(currentItem) ? Color.arkGold : Color.arkTeal)
            Text(currentItem.name)
                .font(.caption)
                .foregroundStyle(Color.arkTaupe)
                .lineLimit(1)
        }
        .padding(12)
        .background(Color.arkSurface)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.arkTaupe)
                TextField("Search bookmarks", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color.arkSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Picker("Tag", selection: $selectedTag) {
                    Text("All tags").tag("")
                    ForEach(bookmarks.allTags, id: \.self) { tag in
                        Text(tag).tag(tag)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button {
                    if let data = try? bookmarks.exportData() {
                        exportDocument = ArkFileBookmarksDocument(data: data)
                        isExporting = true
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(Color.arkSand)
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct ArkFileBookmarkRow: View {
    let bookmark: ArkFileContentBookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(bookmark.articleTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: bookmark.contentType.systemImage)
                    .foregroundStyle(Color.arkTeal)
            }
            Text(bookmark.displaySource)
                .font(.caption)
                .foregroundStyle(Color.arkTaupe)
            if !bookmark.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(bookmark.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.arkTeal)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            if !bookmark.notes.isEmpty {
                Text(bookmark.notes)
                    .font(.caption)
                    .foregroundStyle(Color.arkTaupe)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ArkFileBookmarkEditor: View {
    let title: String
    let existingTags: [String]
    let existingNotes: String
    let onSave: ([String], String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tagsText: String
    @State private var notes: String

    init(title: String, existingTags: [String], existingNotes: String, onSave: @escaping ([String], String) -> Void) {
        self.title = title
        self.existingTags = existingTags
        self.existingNotes = existingNotes
        self.onSave = onSave
        _tagsText = State(initialValue: existingTags.joined(separator: ", "))
        _notes = State(initialValue: existingNotes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Article Title") {
                    Text(title)
                        .foregroundStyle(Color.arkInk)
                }
                Section("Tags") {
                    TextField("Medical, First Aid, Important", text: $tagsText)
                        .textInputAutocapitalization(.words)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(existingTags.isEmpty && existingNotes.isEmpty ? "Add Bookmark" : "Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(parsedTags, notes.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.arkTeal)
    }

    private var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct ArkFileBookmarksDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ArkFileContentCell: View {
    let item: ArkFileLocalContentItem
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.type.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.type.displayLabel)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                Text(item.subcategory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.sizeBytes > 0 {
                    Text(Self.sizeFormatter.string(fromByteCount: item.sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundColor(.primary)
        .padding(12)
        .background(CellBackground.colorFor(isHovering: isHovering))
        .clipShape(CellBackground.clipShapeRectangle)
        .onHover { isHovering = $0 }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
#endif
