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

import Combine
import CoreData
import CoreLocation
import WebKit
import Defaults
import os
import CoreKiwix

enum ArkFileBrowserLoadPolicy {
    static func shouldNavigate(
        presentedURL: URL?,
        webViewURL: URL?,
        requestedURL: URL,
        isLoading: Bool,
        hasProvisionalNavigation: Bool,
        hasSuccessfulDocument: Bool
    ) -> Bool {
        guard presentedURL == requestedURL else {
            return true
        }
        if isLoading || hasProvisionalNavigation {
            return false
        }
        return !(hasSuccessfulDocument && webViewURL == requestedURL)
    }
}

enum ArkFileBrowserRestorationPolicy {
    /// Native Home suppresses automatic reader restoration only for ArkFile's
    /// intentionally single-reader iPhone experience. iPad keeps its tabbed
    /// reader history so reopening or resizing a scene never discards context.
    static func restoresPersistedInteractionState(
        opensNativeHomeOnLaunch: Bool,
        usesSingleReader: Bool
    ) -> Bool {
        !opensNativeHomeOnLaunch || !usesSingleReader
    }
}

enum ArkFileZIMHistorySnapshotPolicy {
    static func canAdoptObservedURL(
        lastSuccessfulURL: URL,
        observedURL: URL,
        currentWebViewURL: URL?,
        webViewIsLoading: Bool,
        hasProvisionalNavigation: Bool,
        hasSuccessfulDocumentBase: Bool
    ) -> Bool {
        guard !webViewIsLoading,
              !hasProvisionalNavigation,
              hasSuccessfulDocumentBase,
              currentWebViewURL == observedURL,
              observedURL.isZIMURL,
              lastSuccessfulURL.zimFileID == observedURL.zimFileID else {
            return false
        }
        return true
    }
}

enum ArkFileZIMReaderPresentationPolicy {
    static func stableURL(
        presentedURL: URL?,
        webViewURL: URL?,
        isLoading: Bool?,
        lastSuccessfulURL: URL?
    ) -> URL? {
        guard isLoading != true,
              let presentedURL,
              let webViewURL,
              let lastSuccessfulURL,
              presentedURL == webViewURL,
              presentedURL == lastSuccessfulURL,
              webViewURL.isZIMURL else {
            return nil
        }
        return webViewURL
    }
}

enum ArkFileBrowserObservationPolicy {
    static func shouldApply(
        capturedGeneration: Int,
        currentGeneration: Int,
        presentedURL: URL?,
        observedURL: URL,
        webViewURL: URL?
    ) -> Bool {
        capturedGeneration == currentGeneration
            && presentedURL == observedURL
            && webViewURL == observedURL
    }
}

enum ArkFileBrowserMediaGoal: Equatable {
    case home
    case reader
}

struct ArkFileBrowserMediaRequest: Equatable {
    let revision: Int
    let goal: ArkFileBrowserMediaGoal
}

enum ArkFileBrowserMediaOperation: Equatable {
    case setSuspended(Bool, request: ArkFileBrowserMediaRequest)
    case closePresentations(request: ArkFileBrowserMediaRequest)
}

struct ArkFileBrowserMediaState: Equatable {
    var desiredRequest: ArkFileBrowserMediaRequest?
    private(set) var isSuspended = false
    private(set) var closedHomeRevision: Int?

    func nextOperation() -> ArkFileBrowserMediaOperation? {
        guard let desiredRequest else { return nil }
        switch desiredRequest.goal {
        case .reader:
            return isSuspended
                ? .setSuspended(false, request: desiredRequest)
                : nil
        case .home:
            if !isSuspended {
                return .setSuspended(true, request: desiredRequest)
            }
            return closedHomeRevision == desiredRequest.revision
                ? nil
                : .closePresentations(request: desiredRequest)
        }
    }

    mutating func complete(_ operation: ArkFileBrowserMediaOperation) {
        switch operation {
        case .setSuspended(let suspended, _):
            isSuspended = suspended
        case .closePresentations(let request):
            closedHomeRevision = request.revision
        }
    }
}

enum ArkFileBrowserNavigationFailureDisposition: Equatable {
    case ignoreStale
    case clearCancelled
    case handleFailure
}

enum ArkFileBrowserNavigationFailurePolicy {
    static func disposition(
        errorCode: Int,
        failedNavigationIsCurrent: Bool
    ) -> ArkFileBrowserNavigationFailureDisposition {
        guard failedNavigationIsCurrent else {
            return .ignoreStale
        }
        if errorCode == NSURLErrorCancelled {
            return .clearCancelled
        }
        return .handleFailure
    }
}

enum ArkFileBrowserNavigationActionIntentPolicy {
    static func mayBeginIntent(
        normalizedRequestURL: URL,
        presentedURL: URL?,
        hasProvisionalNavigation: Bool,
        usesSingleReader: Bool
    ) -> Bool {
        guard usesSingleReader else { return true }
        guard let presentedURL else { return false }
        if hasProvisionalNavigation {
            // WKWebView canonicalizes a base-relative zim:// URL before asking
            // for navigation policy. Compare canonical identities so the
            // initial request is not mistaken for a stale replacement.
            return normalizedRequestURL.absoluteURL == presentedURL.absoluteURL
        }
        return true
    }
}

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
@MainActor final class BrowserViewModel: NSObject, ObservableObject,
                              WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate,
                              NSFetchedResultsControllerDelegate {

    private static var cache: OrderedCache<NSManagedObjectID, BrowserViewModel>?

    static func getCached(tabID: NSManagedObjectID) -> BrowserViewModel {
        if let cachedModel = cache?.findBy(key: tabID) {
            return cachedModel
        }
        if cache == nil {
            cache = .init()
        }
        let viewModel = BrowserViewModel(tabID: tabID)
        cache?.removeValue(forKey: tabID)
        cache?.setValue(viewModel, forKey: tabID)
        return viewModel
    }

    static func purgeCache() {
        Task { @MainActor in
            cache?.removeOlderThan(Date.now.advanced(by: -360)) // 6 minutes
        }
    }

    /// Clears any rendered paid ZIM whose underlying managed file is no longer
    /// readable. Unmanaged imports and still-entitled Essentials tabs remain.
    static func clearBrowsersBlockedByPaidContentGate() async {
        guard let cache else { return }
        for browser in cache.values {
            guard let zimFileID = browser.url?.zimFileID else { continue }
            let readableURL = await ZimFileService.shared.getFileURL(zimFileID: zimFileID)
            if readableURL == nil {
                await browser.clear()
            }
        }
    }
    
    nonisolated static func destroyTabById(id: NSManagedObjectID) {
        Task { @MainActor in
            await destroyCachedTabById(id: id)
        }
    }

    @MainActor
    static func destroyCachedTabById(id: NSManagedObjectID) async {
        if let browserViewModel = cache?.findBy(key: id) {
            await browserViewModel.destroy()
            cache?.removeValue(forKey: id)
        }
    }

    nonisolated static func keepOnlyTabsByIds(_ ids: Set<NSManagedObjectID>) {
        Task { @MainActor in
            if let cache {
                for browser in cache.removeNotMatchingWith(keys: ids) {
                    await browser.destroy()
                }
            }
        }
    }
    
    // MARK: - Properties

    @Published private(set) var isLoading: Bool?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var articleTitle: String = ""
    @Published var zimFileName: String = ""
    @Published private(set) var articleBookmarked = false
    @Published private(set) var outlineItems = [OutlineItem]()
    @Published private(set) var outlineItemTree = [OutlineItem]()
    @MainActor @Published private(set) var hasURL: Bool = false
    @MainActor @Published private(set) var lastSuccessfulZIMURL: URL?
    @MainActor @Published private(set) var url: URL? {
        didSet {
            if !FeatureFlags.hasLibrary, url == nil {
                loadMainArticle()
            }
            if url != oldValue {
                bookmarkFetchedResultsController.fetchRequest.predicate = Self.bookmarksPredicateFor(url: url)
                try? bookmarkFetchedResultsController.performFetch()
            }
            hasURL = url != nil
        }
    }
    @MainActor var zimFileId: UUID? { url?.zimFileID }
    @Published var externalURL: URL?
    private var metaData: URLContentMetaData?

#if os(macOS)
    private var windowURLs: [URL] {
        UserDefaults.standard[.windowURLs]
    }
#endif
    let webView: WKWebView
    let tabID: NSManagedObjectID
    private var isLoadingObserver: NSKeyValueObservation?
    private var canGoBackObserver: NSKeyValueObservation?
    private var canGoForwardObserver: NSKeyValueObservation?
    private var titleURLObserver: AnyCancellable?
    private let bookmarkFetchedResultsController: NSFetchedResultsController<Bookmark>
    private var contentPresentationGeneration = 0
    private var mediaState = ArkFileBrowserMediaState()
    private var mediaReconciliationTask: Task<Void, Never>?
    private var hasProvisionalNavigation = false
    private var activeMainFrameNavigation: WKNavigation?
    private var activeMainFrameNavigationGeneration: Int?
    private var canAdoptSameDocumentURL = false
    private var lastSuccessfulZIMNavigation: (url: URL, title: String)?

    private struct ClearContext {
        let historyURL: URL?
        let historyTitle: String
        let historyCapturedAt: Date?
    }

    // MARK: - Lifecycle

    // swiftlint:disable:next function_body_length
    @MainActor private init(tabID: NSManagedObjectID) {
        self.tabID = tabID
        webView = WKWebView(
            frame: .zero,
            configuration: WebViewConfiguration.make(
                ruleList: WebContentBlocker.requiredRuleList()
            )
        )
        if !Bundle.main.isProduction {
                webView.isInspectable = true
        }
        // Bookmark fetching:
        bookmarkFetchedResultsController = NSFetchedResultsController(
            fetchRequest: Bookmark.fetchRequest(), // initially empty
            managedObjectContext: Database.shared.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()

        bookmarkFetchedResultsController.delegate = self

        // configure web view
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.defaultWebpagePreferences.preferredContentMode = .mobile // for font adjustment to work
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "headings")
        webView.configuration.userContentController.add(self, name: "headings")
        webView.navigationDelegate = self
        webView.uiDelegate = self

        #if os(iOS)
        if ArkFileBrowserRestorationPolicy.restoresPersistedInteractionState(
            opensNativeHomeOnLaunch: FeatureFlags.opensNativeHomeOnLaunch,
            usesSingleReader: NavigationViewModel.usesArkFileSingleReaderRouting
        ) {
            restoreBy(tabID: tabID)
        }
        #else
        restoreBy(tabID: tabID)
        #endif

        // get outline items if something is already loaded
        if webView.url != nil {
            webView.evaluateJavaScript("getOutlineItems();")
        }

        // setup web view property observers
        canGoBackObserver = webView.observe(\.canGoBack, options: .initial) { [weak self] webView, _ in
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    self?.canGoBack = webView.canGoBack
                }
            }
        }
        canGoForwardObserver = webView.observe(\.canGoForward, options: .initial) { [weak self] webView, _ in
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    self?.canGoForward = webView.canGoForward
                }
            }
        }
        titleURLObserver = Publishers.CombineLatest(
            webView.publisher(for: \.title, options: .initial),
            webView.publisher(for: \.url, options: .initial)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] title, url in
            guard let title, let url else { return }
            self?.didUpdate(title: title, url: url)
        }

        isLoadingObserver = webView.observe(\.isLoading, options: .new) { [weak self] _, change in
            Task { @MainActor [weak self] in
                if change.newValue != self?.isLoading {
                    self?.isLoading = change.newValue
                }
            }
        }
    }
    
    deinit {
        debugPrint("🧨 BrowserViewModel deinit 🧨")
    }

    @MainActor
    func destroy() async {
        bookmarkFetchedResultsController.delegate = nil
        canGoBackObserver?.invalidate()
        canGoForwardObserver?.invalidate()
        titleURLObserver?.cancel()
        isLoadingObserver?.invalidate()
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "headings")
        contentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        #if os(iOS)
        webView.scrollView.delegate = nil
        #endif
        await clear()
    }

    @MainActor
    func clear() async {
        let context = beginClearPresentation()
        await finishClear(context)
        await mediaReconciliationTask?.value
    }

    /// Publishes native Home during the button action, then lets WebKit media
    /// teardown and reading-history persistence finish without holding the
    /// first Home interaction behind them.
    @MainActor
    func clearForHome() {
        let context = beginClearPresentation()
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.finishClear(context)
        }
    }

    @MainActor
    private func beginClearPresentation() -> ClearContext {
        ArkFileReaderOpenIntentCoordinator.shared.invalidateForCurrentReader()
        let historySnapshot = captureArkFileReadingHistorySnapshot()
        lastSuccessfulZIMNavigation = nil
        lastSuccessfulZIMURL = nil
        canAdoptSameDocumentURL = false
        hasProvisionalNavigation = false
        activeMainFrameNavigation = nil
        activeMainFrameNavigationGeneration = nil
        contentPresentationGeneration &+= 1
        // Hide synchronously so a same-URL open arriving while WebKit is
        // suspending supersedes this clear instead of being mistaken for an
        // already-visible no-op.
        webView.stopLoading()
        url = nil
        articleTitle = ""
        zimFileName = ""
        metaData = nil
        outlineItems = []
        outlineItemTree = []
        isLoading = nil
        requestMediaGoal(.home)
        return ClearContext(
            historyURL: historySnapshot?.url,
            historyTitle: historySnapshot?.title ?? "",
            historyCapturedAt: historySnapshot == nil ? nil : Date()
        )
    }

    @MainActor
    private func finishClear(_ context: ClearContext) async {
        if let historyURL = context.historyURL {
            ArkFileReadingHistory.shared.recordCompletedZIMNavigation(
                url: historyURL,
                title: context.historyTitle,
                occurredAt: context.historyCapturedAt ?? Date()
            )
        }
    }

    /// Get the webpage in a binary format
    /// - Returns: PDF of the current page (if text type) or binary data of the content
    /// and the file extension, if known
    func pageDataWithExtension() async -> (Data, String?)? {
        if metaData?.isTextType == true,
           let pdfData = try? await webView.pdf() {
            return (pdfData, metaData?.exportFileExtension)
        } else if let url = webView.url,
                  let contentData = await ZimFileService.shared.getURLContent(url: url)?.data {
            let pathExtesion = url.pathExtension
            let fileExtension: String?
            if !pathExtesion.isEmpty {
                fileExtension = pathExtesion
            } else {
                fileExtension = metaData?.exportFileExtension
            }
            return (contentData, fileExtension)
        }
        return nil
    }

    func forceLoadingState() {
        isLoading = true
    }

    private func didUpdate(title: String, url: URL) {
        updateLastSuccessfulZIMNavigationIfSameDocument(
            observedURL: url,
            title: title
        )
        let observationGeneration = contentPresentationGeneration
        let zimFile: ZimFile? = {
            guard let zimFileID = url.zimFileID else { return nil }
            return try? Database.shared.viewContext.fetch(ZimFile.fetchRequest(fileID: zimFileID)).first
        }()

        Task { @MainActor in
            let resolvedMetaData = await ZimFileService.shared.getContentMetaData(url: url)
            // KVO may enqueue several metadata lookups. A slower response for
            // an older page must not roll the visible URL or history snapshot
            // back after a newer navigation has completed.
            guard ArkFileBrowserObservationPolicy.shouldApply(
                capturedGeneration: observationGeneration,
                currentGeneration: contentPresentationGeneration,
                presentedURL: self.url,
                observedURL: url,
                webViewURL: webView.url
            ) else {
                return
            }
            metaData = resolvedMetaData
            if title.isEmpty {
                articleTitle = metaData?.zimTitle ?? ""
            } else {
                articleTitle = title
            }
            // update view model
            zimFileName = zimFile?.name ?? ""
            self.url = url

            // update tab data
            let context = Database.shared.viewContext
            if let tab = try? context.existingObject(with: tabID) as? Tab {
                tab.title = articleTitle
                tab.zimFile = zimFile
            }
            if context.hasChanges {
                try? context.save()
            }
            #if os(macOS)
            disableVideoContextMenu()
            #endif
        }
    }

    @MainActor
    func updateLastOpened() async {
        let currentTabID = tabID
        await Database.shared.viewContext.perform {
            let context = Database.shared.viewContext
            guard let tab = try? context.existingObject(with: currentTabID) as? Tab else {
                return
            }
            tab.lastOpened = Date()
            try? context.save()
        }
    }

    @MainActor
    func persistState() async {
        let webData = webView.interactionState as? Data
        let currentTabID = tabID
        await Database.shared.viewContext.perform {
            let context = Database.shared.viewContext
            guard let tab = try? context.existingObject(with: currentTabID) as? Tab else {
                return
            }
            tab.interactionState = webData
            if context.hasChanges {
                try? context.save()
            }
        }
    }

    // MARK: - Content Loading
    @MainActor
    func goBack() {
        navigateHistory(
            to: webView.backForwardList.backItem,
            action: { [webView] in webView.goBack() }
        )
    }

    @MainActor
    func goForward() {
        navigateHistory(
            to: webView.backForwardList.forwardItem,
            action: { [webView] in webView.goForward() }
        )
    }

    @MainActor
    private func navigateHistory(
        to item: WKBackForwardListItem?,
        action: () -> WKNavigation?
    ) {
        guard let targetURL = item?.url.updatedToZIMSheme() else { return }
        ArkFileReaderOpenIntentCoordinator.shared.invalidateForCurrentReader()
        contentPresentationGeneration &+= 1
        hasProvisionalNavigation = true
        canAdoptSameDocumentURL = false
        self.url = targetURL
        requestMediaGoal(.reader)
        activeMainFrameNavigation = action()
        activeMainFrameNavigationGeneration = activeMainFrameNavigation == nil
            ? nil
            : contentPresentationGeneration
    }

    @MainActor
    func load(url: URL) {
        load(
            url: url,
            continuing: ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        )
    }

    #if DEBUG && os(iOS)
    /// Seeds semantic reader state without starting WebKit or network work.
    /// Available only to the explicit adaptive iPad UI-test harness.
    @MainActor
    func seedReaderForAdaptiveUITest() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("testing"),
              arguments.contains(
                "arkfile-ui-test-adaptive-reader"
              ),
              let fixtureURL = URL(
                string:
                    "zim://00000000-0000-0000-0000-000000000001/A/Adaptive-Reader-Fixture"
              ) else {
            return
        }
        contentPresentationGeneration &+= 1
        hasProvisionalNavigation = false
        canAdoptSameDocumentURL = true
        url = fixtureURL
        articleTitle = "Adaptive Reader Fixture"
        zimFileName = "Adaptive Reader Fixture"
        isLoading = false
    }
    #endif

    @MainActor
    func load(url: URL, continuing readerOpenIntent: ArkFileReaderOpenIntent) {
        guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
            return
        }
        let requestedURL = url.absoluteURL
        guard ArkFileBrowserLoadPolicy.shouldNavigate(
            presentedURL: self.url,
            webViewURL: webView.url,
            requestedURL: requestedURL,
            isLoading: webView.isLoading,
            hasProvisionalNavigation: hasProvisionalNavigation,
            hasSuccessfulDocument: canAdoptSameDocumentURL
        ) else {
            return
        }
        contentPresentationGeneration &+= 1
        hasProvisionalNavigation = true
        canAdoptSameDocumentURL = false
        // Publish the canonical presentation before calling into WebKit. Its
        // policy callback may be reentrant and must see this request.
        self.url = requestedURL
        requestMediaGoal(.reader)
        activeMainFrameNavigation = webView.load(URLRequest(url: requestedURL))
        activeMainFrameNavigationGeneration = activeMainFrameNavigation == nil
            ? nil
            : contentPresentationGeneration
    }

    @discardableResult
    private func requestMediaGoal(_ goal: ArkFileBrowserMediaGoal) -> Task<Void, Never>? {
        mediaState.desiredRequest = ArkFileBrowserMediaRequest(
            revision: contentPresentationGeneration,
            goal: goal
        )
        guard mediaReconciliationTask == nil,
              mediaState.nextOperation() != nil else {
            return mediaReconciliationTask
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileMediaState()
        }
        mediaReconciliationTask = task
        return task
    }

    private func reconcileMediaState() async {
        while let operation = mediaState.nextOperation() {
            switch operation {
            case .setSuspended(let suspended, _):
                await webView.setAllMediaPlaybackSuspended(suspended)
            case .closePresentations:
                await webView.closeAllMediaPresentations()
            }
            mediaState.complete(operation)
        }
        mediaReconciliationTask = nil
    }

    @MainActor
    func flushArkFileReadingHistory() {
        guard let snapshot = captureArkFileReadingHistorySnapshot() else {
            return
        }
        ArkFileReadingHistory.shared.recordCompletedZIMNavigation(
            url: snapshot.url,
            title: snapshot.title
        )
    }

    @MainActor
    private func captureArkFileReadingHistorySnapshot() -> (url: URL, title: String)? {
        guard FeatureFlags.opensNativeHomeOnLaunch,
              var snapshot = lastSuccessfulZIMNavigation else {
            return nil
        }
        if let observedURL = webView.url,
           ArkFileZIMHistorySnapshotPolicy.canAdoptObservedURL(
            lastSuccessfulURL: snapshot.url,
            observedURL: observedURL,
            currentWebViewURL: webView.url,
            webViewIsLoading: webView.isLoading,
            hasProvisionalNavigation: hasProvisionalNavigation,
            hasSuccessfulDocumentBase: canAdoptSameDocumentURL
           ) {
            snapshot.url = observedURL
            let observedTitle = (webView.title ?? articleTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !observedTitle.isEmpty {
                snapshot.title = observedTitle
            }
            lastSuccessfulZIMNavigation = snapshot
            lastSuccessfulZIMURL = snapshot.url
            self.url = snapshot.url
        }
        return snapshot
    }

    private func updateLastSuccessfulZIMNavigationIfSameDocument(
        observedURL: URL,
        title: String
    ) {
        guard FeatureFlags.opensNativeHomeOnLaunch,
              let snapshot = lastSuccessfulZIMNavigation,
              ArkFileZIMHistorySnapshotPolicy.canAdoptObservedURL(
                lastSuccessfulURL: snapshot.url,
                observedURL: observedURL,
                currentWebViewURL: webView.url,
                webViewIsLoading: webView.isLoading,
                hasProvisionalNavigation: hasProvisionalNavigation,
                hasSuccessfulDocumentBase: canAdoptSameDocumentURL
              ) else {
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSuccessfulZIMNavigation = (
            observedURL,
            trimmedTitle.isEmpty ? snapshot.title : trimmedTitle
        )
        lastSuccessfulZIMURL = observedURL
        self.url = observedURL
    }

    @MainActor
    func loadRandomArticle(zimFileID: UUID? = nil) {
        let zimFileID = zimFileID ?? webView.url?.zimFileID
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        Task { @ZimActor [weak self] in
            guard let url = ZimFileService.shared.getRandomPageURL(zimFileID: zimFileID) else { return }
            await MainActor.run { [weak self] in
                self?.load(url: url, continuing: readerOpenIntent)
            }
        }
    }

    @MainActor
    func loadMainArticle(zimFileID: UUID? = nil) {
        let zimFileID = zimFileID ?? webView.url?.zimFileID
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()
        Task { @ZimActor [weak self] in
            guard let url = ZimFileService.shared.getMainPageURL(zimFileID: zimFileID) else { return }
            await MainActor.run { [weak self] in
                self?.load(url: url, continuing: readerOpenIntent)
            }
        }
    }

    private func restoreBy(tabID: NSManagedObjectID) {
        if let tab = try? Database.shared.viewContext.existingObject(with: tabID) as? Tab {
            webView.interactionState = tab.interactionState
            if webView.url != nil {
                // make sure category(.list) is not displayed
                // while restoring a tab
                isLoading = true
            }
            Task { [weak self] in
                await MainActor.run { [weak self] in
                    // migrate the tab urls on demand to ZIM scheme
                    self?.url = self?.webView.url?.updatedToZIMSheme()
                    if let webURL = self?.webView.url, webURL.isKiwixURL {
                        self?.load(url: webURL.updatedToZIMSheme())
                    }
                }
            }
        }
    }

    // MARK: - Video fixes
    func pauseVideoWhenNotInPIP() {
        // webView.pauseAllMediaPlayback() is not good enough
        // as that pauses in Picture in Picture mode as well.
        // Detecting PiP on a AVPictureInPictureController created by WKWebView
        // is currently non-trivial from the swift side
        webView.evaluateJavaScript("pauseVideoWhenNotInPIP();")
    }

    @MainActor
    func refreshVideoState() {
        Task { [weak webView] in
            await MainActor.run { [weak webView] in
                webView?.evaluateJavaScript("refreshVideoState();")
            }
        }
    }

    #if os(macOS)
    /// Disable the right-click context menu on video components
    @MainActor
    func disableVideoContextMenu() {
        webView.evaluateJavaScript("disableVideoContextMenu();")
    }
    #endif

    // MARK: - New Tab Creation

#if os(macOS)
    @MainActor
    @discardableResult func createNewWindow(with url: URL) -> Bool {
        guard let currentWindow = NSApp.keyWindow,
              let windowController = currentWindow.windowController else { return false }
        let context = Database.shared.viewContext
        // create a new Tab DB object, and a new BrowserViewModel (which creates a new WKWebView)
        // and pre-load the url into that
        let newTab = NavigationViewModel.makeTab(context: context)
        let newTabID = newTab.objectID
        BrowserViewModel.getCached(tabID: newTabID).load(url: url)

        // store the tabID statically, so that the new window can pick it up
        NavigationViewModel.tabIDToUseOnNewTab = newTabID

        windowController.newWindowForTab(nil)
        guard let newWindow = NSApp.keyWindow, currentWindow != newWindow else {
            // rather impossible case, but rolling back everything from above
            NavigationViewModel.tabIDToUseOnNewTab = nil
            context.delete(newTab)
            if context.hasChanges {
                try? context.save()
            }
            return false
        }
        currentWindow.addTabbedWindow(newWindow, ordered: .above)
        return true
    }
#endif

    // MARK: - WKNavigationDelegate

    @MainActor
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard url != nil else {
            if activeMainFrameNavigation === navigation {
                activeMainFrameNavigation = nil
                activeMainFrameNavigationGeneration = nil
            }
            webView.stopLoading()
            return
        }
        if let activeMainFrameNavigation,
           activeMainFrameNavigation !== navigation {
            return
        }
        if activeMainFrameNavigation == nil {
            contentPresentationGeneration &+= 1
            requestMediaGoal(.reader)
        }
        activeMainFrameNavigation = navigation
        activeMainFrameNavigationGeneration = contentPresentationGeneration
        hasProvisionalNavigation = true
        canAdoptSameDocumentURL = false
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @MainActor func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            // Allow to load iFrame content via src-doc instead of external src
            return .allow
        }
        guard let url = navigationAction.request.url?.updatedToZIMSheme() else {
            return .cancel
        }
        let usesSingleReader: Bool = {
            #if os(iOS)
            NavigationViewModel.usesArkFileSingleReaderRouting
            #else
            false
            #endif
        }()
        guard ArkFileBrowserNavigationActionIntentPolicy.mayBeginIntent(
            normalizedRequestURL: url,
            presentedURL: self.url,
            hasProvisionalNavigation: hasProvisionalNavigation,
            usesSingleReader: usesSingleReader
        ) else {
            return .cancel
        }
        let readerOpenIntent = ArkFileReaderOpenIntentCoordinator.shared.beginForCurrentReader()

#if os(macOS)
        // detect cmd + click event
        if navigationAction.modifierFlags.contains(.command) {
            if createNewWindow(with: url) {
                return .cancel
            }
        }
#endif

        if url.isZIMURL, let redirectedURL = await ZimFileService.shared.getRedirectedURL(url: url) {
            guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                return .cancel
            }
            if webView.url != redirectedURL {
                load(url: redirectedURL, continuing: readerOpenIntent)
            }
            return .cancel
        } else if url.isZIMURL {
            let contentExists = await ZimFileService.shared.getContentSize(url: url) != nil
            guard ArkFileReaderOpenIntentCoordinator.shared.isCurrent(readerOpenIntent) else {
                return .cancel
            }
            guard contentExists else {
                let urlString = url.absoluteString
                let path = url.contentPath
                Log.URLSchemeHandler.error(
                    "Missing content at url: \(urlString, privacy: .public) => \(path, privacy: .public)"
                )
                if navigationAction.request.mainDocumentURL == url {
                    // only show alerts for missing main document
                    NotificationCenter.default.post(
                        name: .alert,
                        object: nil,
                        userInfo: ["alert": ActiveAlert.articleFailedToLoad]
                    )
                }
                return .cancel
            }
            return .allow
        } else if url.isUnsupported {
            externalURL = url
            return .cancel
        } else if url.isGeoURL {
            if FeatureFlags.map {
                let _: CLLocation? = {
                    let parts = url.absoluteString.replacingOccurrences(of: "geo:", with: "").split(separator: ",")
                    guard let latitudeString = parts.first,
                          let longitudeString = parts.last,
                          let latitude = Double(latitudeString),
                          let longitude = Double(longitudeString) else { return nil }
                    return CLLocation(latitude: latitude, longitude: longitude)
                }()
            } else {
                let coordinate = url.absoluteString.replacingOccurrences(of: "geo:", with: "")
                if let url = URL(string: "http://maps.apple.com/?ll=\(coordinate)") {
#if os(macOS)
                    NSWorkspace.shared.open(url)
#elseif os(iOS)
                    await UIApplication.shared.open(url)
#endif
                }
            }
            return .cancel
        } else {
            return .cancel
        }
    }

    private var canShowMimeType = true

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @MainActor @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        canShowMimeType = navigationResponse.canShowMIMEType
        guard canShowMimeType else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard activeMainFrameNavigation === navigation,
              activeMainFrameNavigationGeneration == contentPresentationGeneration,
              url != nil else {
            return
        }
        activeMainFrameNavigation = nil
        activeMainFrameNavigationGeneration = nil
        hasProvisionalNavigation = false
        canAdoptSameDocumentURL = true
        if FeatureFlags.opensNativeHomeOnLaunch {
            let title = webView.title ?? articleTitle
            if let url = webView.url, url.isZIMURL {
                lastSuccessfulZIMNavigation = (url, title)
                lastSuccessfulZIMURL = url
                self.url = url
                didUpdate(title: title, url: url)
            }
            ArkFileReadingHistory.shared.recordCompletedZIMNavigation(
                url: webView.url,
                title: title
            )
        }
        webView.evaluateJavaScript("expandAllDetailTags(); getOutlineItems();")
#if os(iOS)
        // on iOS 17 on the iPhone, the video starts with a black screen
        // if there's a poster attribute
        if Device.current == .iPhone {
            webView.evaluateJavaScript("fixVideoElements();")
        }
        webView.adjustTextSize()
#else
        Task { await persistState() }
#endif
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let error = error as NSError
        let disposition = ArkFileBrowserNavigationFailurePolicy.disposition(
            errorCode: error.code,
            failedNavigationIsCurrent: activeMainFrameNavigation === navigation
                && activeMainFrameNavigationGeneration == contentPresentationGeneration
                && url != nil
        )
        // A callback from the replaced navigation no longer owns reader state
        // or the shared ZIM scheme tasks, regardless of its error code.
        guard disposition != .ignoreStale else {
            return
        }
        activeMainFrameNavigation = nil
        activeMainFrameNavigationGeneration = nil
        hasProvisionalNavigation = false
        canAdoptSameDocumentURL = false
        guard disposition == .handleFailure else {
            return
        }
        Task { @MainActor in
            webView.stopLoading()
            (webView.configuration
                .urlSchemeHandler(forURLScheme: KiwixURLSchemeHandler.ZIMScheme) as? KiwixURLSchemeHandler)?
                .didFailProvisionalNavigation()
        }
        guard canShowMimeType else {
            guard let kiwixURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else {
                return
            }
            NotificationCenter.saveContent(url: kiwixURL)
            return
        }
        NotificationCenter.default.post(
            name: .alert, object: nil, userInfo: ["alert": ActiveAlert.articleFailedToLoad]
        )
    }

    func webView(
        _: WKWebView,
        didFail navigation: WKNavigation!,
        withError _: Error
    ) {
        guard activeMainFrameNavigation === navigation,
              activeMainFrameNavigationGeneration == contentPresentationGeneration,
              url != nil else {
            return
        }
        activeMainFrameNavigation = nil
        activeMainFrameNavigationGeneration = nil
        hasProvisionalNavigation = false
        canAdoptSameDocumentURL = false
    }

    // MARK: - WKScriptMessageHandler

    @MainActor
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "headings", let headings = message.body as? [[String: String]] {
            self.generateOutlineList(headings: headings)
            self.generateOutlineTree(headings: headings)
        }
    }

    // MARK: - WKUIDelegate

#if os(macOS)
    @MainActor
    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard let newUrl = navigationAction.request.url else { return nil }

        // open external link in default browser
        guard newUrl.isUnsupported == false else {
            externalURL = newUrl
            return nil
        }

        createNewWindow(with: newUrl)
        return nil
    }
#else
    @MainActor
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let newURL = navigationAction.request.url else { return nil }
        if let frame = navigationAction.targetFrame, frame.isMainFrame {
            return nil
        }
        guard newURL.isUnsupported == false else {
            externalURL = newURL
            return nil
        }
        NotificationCenter.openURL(
            newURL,
            inNewTab: ArkFileReaderRoutingPolicy.routesAuxiliaryNavigationInNewTab(
                usesSingleReader: NavigationViewModel.usesArkFileSingleReaderRouting
            )
        )
        return nil
    }
#endif

#if os(iOS)
    
    // swiftlint:disable:next function_body_length
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo
    ) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, url.isZIMURL else { return nil }
        let offersOpenInNewTab = ArkFileReaderRoutingPolicy.routesAuxiliaryNavigationInNewTab(
            usesSingleReader: NavigationViewModel.usesArkFileSingleReaderRouting
        )
        let configuration = UIContextMenuConfiguration(
            previewProvider: {
                let webView = WKWebView(
                    frame: .zero,
                    configuration: WebViewConfiguration.make(
                        ruleList: WebContentBlocker.requiredRuleList()
                    )
                )
                if !Bundle.main.isProduction {
                    webView.isInspectable = true
                }
                webView.load(URLRequest(url: url))
                return WebViewController(webView: webView)
            },
            actionProvider: { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                var actions = [UIAction]()
                
                // open url
                actions.append(
                    UIAction(title: LocalString.common_dialog_button_open,
                             image: UIImage(systemName: "doc.text")) { [weak self] _ in
                                 self?.load(url: url)
                             }
                )
                if offersOpenInNewTab {
                    actions.append(
                        UIAction(title: LocalString.common_dialog_button_open_in_new_tab,
                                 image: UIImage(systemName: "doc.badge.plus")) { _ in
                                     Task { @MainActor in
                                         NotificationCenter.openURL(url, inNewTab: true)
                                     }
                                 }
                    )
                }
                
                if !NavigationViewModel.usesArkFileSingleReaderRouting {
                    // Retain the legacy Kiwix bookmark action only in tabbed
                    // presentations. ArkFile iPhone uses its unified Saved
                    // controls and leaves existing legacy rows untouched.
                    let bookmarkAction: UIAction = { [weak self] in
                        let context = Database.shared.viewContext
                        let predicate = NSPredicate(format: "articleURL == %@", url as CVarArg)
                        let request = Bookmark.fetchRequest(predicate: predicate)

                        if let bookmarks = try? context.fetch(request),
                           !bookmarks.isEmpty {
                            return UIAction(title: LocalString.common_dialog_button_remove_bookmark,
                                            image: UIImage(systemName: "star.slash.fill")) { [weak self] _ in
                                self?.deleteBookmark(url: url)
                            }
                        } else {
                            return UIAction(
                                title: LocalString.common_dialog_button_bookmark,
                                image: UIImage(systemName: "star")
                            ) { [weak self] _ in
                                Task { @MainActor [weak self] in self?.createBookmark(url: url) }
                            }
                        }
                    }()
                    actions.append(bookmarkAction)
                }
                
                return UIMenu(children: actions)
            }
        )
        return configuration
    }
#endif

    // MARK: - Bookmark

    nonisolated func controller(_: NSFetchedResultsController<NSFetchRequestResult>,
                                didChangeContentWith snapshot: NSDiffableDataSourceSnapshotReference) {
        let isEmpty: Bool = snapshot.itemIdentifiers.isEmpty
        Task { @MainActor in
            articleBookmarked = !isEmpty
        }
    }

    @MainActor 
    func createBookmark(url: URL? = nil) {
        guard let url = url ?? webView.url,
              let zimFileID = url.zimFileID else { return }
        let title = webView.title
        Task {
            guard let metaData = await ZimFileService.shared.getContentMetaData(url: url) else { return }
            await Database.shared.viewContext.perform {
                let context = Database.shared.viewContext
                let bookmark = Bookmark(context: context)
                bookmark.articleURL = url
                bookmark.created = Date()
                guard let zimFile = try? context.fetch(ZimFile.fetchRequest(fileID: zimFileID)).first else { return }

                bookmark.zimFile = zimFile
                bookmark.title = title ?? metaData.zimTitle
                try? context.save()
            }
        }
    }

    func deleteBookmark(url: URL? = nil) {
        guard let url = url ?? webView.url else { return }
        Task {
            await Database.shared.viewContext.perform {
                let context = Database.shared.viewContext
                let request = Bookmark.fetchRequest(predicate: NSPredicate(format: "articleURL == %@", url as CVarArg))
                guard let bookmark = try? context.fetch(request).first else { return }
                context.delete(bookmark)
                try? context.save()
            }
        }
    }

    // MARK: - Outline

    /// Scroll to an outline item
    /// - Parameter outlineItemID: ID of the outline item to scroll to
    func scrollTo(outlineItemID: String) {
        webView.evaluateJavaScript("scrollToHeading('\(outlineItemID)')")
    }

    /// Convert flattened heading element data to a list of OutlineItems.
    /// - Parameter headings: list of heading element data retrieved from webview
    @MainActor private func generateOutlineList(headings: [[String: String]]) {
        let allLevels = headings.compactMap { Int($0["tag"]?.suffix(1) ?? "") }
        let offset = allLevels.filter { $0 == 1 }.count == 1 ? 2 : allLevels.min() ?? 0
        let outlineItems: [OutlineItem] = headings.enumerated().compactMap { index, heading in
            guard let id = heading["id"],
                  let text = heading["text"],
                  let tag = heading["tag"],
                  let level = Int(tag.suffix(1)) else { return nil }
            return OutlineItem(id: id, index: index, text: text, level: max(level - offset, 0))
        }
        self.outlineItems = outlineItems
    }

    /// Convert flattened heading element data to a tree of OutlineItems.
    /// - Parameter headings: list of heading element data retrieved from webview
    @MainActor private func generateOutlineTree(headings: [[String: String]]) {
        let root = OutlineItem(index: -1, text: "", level: 0)
        var stack: [OutlineItem] = [root]

        headings.enumerated().forEach { index, heading in
            guard let id = heading["id"],
                  let text = heading["text"],
                  let tag = heading["tag"], let level = Int(tag.suffix(1)) else { return }
            let item = OutlineItem(id: id, index: index, text: text, level: level)

            // get last item in stack
            // if last item is child of item's sibling, unwind stack until a sibling is found
            guard var lastItem = stack.last else { return }
            while lastItem.level > item.level {
                stack.removeLast()
                lastItem = stack[stack.count - 1]
            }

            // if item is last item's sibling, add item to parent and replace last item with itself in stack
            // if item is last item's child, add item to parent and add item to stack
            if lastItem.level == item.level {
                stack[stack.count - 2].addChild(item)
                stack[stack.count - 1] = item
            } else if lastItem.level < item.level {
                stack[stack.count - 1].addChild(item)
                stack.append(item)
            }
        }

        // if there is only one item at top level, with the same text as the article title
        // do not display it only it's children
        if let rootChildren = root.children, rootChildren.count == 1,
            let rootFirstChild = rootChildren.first,
           rootFirstChild.text.lowercased() == articleTitle.lowercased() {
            self.outlineItemTree = rootFirstChild.children ?? []
        } else {
            self.outlineItemTree = root.children ?? []
        }
    }

    private static func bookmarksPredicateFor(url: URL?) -> NSPredicate? {
        guard let url else { return nil }
        return NSPredicate(format: "articleURL == %@", url as CVarArg)
    }
}
