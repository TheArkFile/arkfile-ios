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
import UIKit
import WebKit

enum ArkFileHTMLNavigationPolicy {
    /// A `data:` or `blob:` document does not carry the CSP from ArkFile's
    /// custom-scheme response, even in a child frame. Block those document
    /// navigations entirely; data images and styles load as subresources and
    /// do not pass through this policy. WebKit may use an initial top-level
    /// about:blank before a document commits, and a child about:blank inherits
    /// its creator's policy. A missing target is treated as a new top-level
    /// context.
    static func allowsInWebView(
        _ url: URL,
        isMainFrame: Bool?,
        hasCommittedDocument: Bool
    ) -> Bool {
        switch url.scheme?.lowercased() {
        case ArkFileReaderSchemeHandler.scheme:
            return true
        case "about":
            guard url.absoluteString.lowercased() == "about:blank" else {
                return false
            }
            return isMainFrame == false || (isMainFrame == true && !hasCommittedDocument)
        case "data", "blob":
            return false
        default:
            return false
        }
    }
}

enum ArkFileWebReaderURL {
    static let outsideReadAccessMessage = "That chapter is outside this book's offline files."

    static func staticDocumentReadAccessURL(for sourceURL: URL) -> URL {
        canonicalFileURL(sourceURL).deletingLastPathComponent()
    }

    static func canonicalFileURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        let canonicalFile = URL(fileURLWithPath: url.fileSystemPath)
        guard let originalComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var canonicalComponents = URLComponents(url: canonicalFile, resolvingAgainstBaseURL: false) else {
            return canonicalFile
        }
        canonicalComponents.percentEncodedQuery = originalComponents.percentEncodedQuery
        canonicalComponents.percentEncodedFragment = originalComponents.percentEncodedFragment
        return canonicalComponents.url ?? canonicalFile
    }

    static func readerRequest(for fileURL: URL, readAccessURL: URL) -> URLRequest? {
        guard let readerURL = ArkFileReaderSchemeHandler.readerURL(
            forFileURL: fileURL,
            rootURL: readAccessURL
        ) else {
            return nil
        }
        return URLRequest(url: readerURL, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    static func fileURL(fromWebURL webURL: URL, readAccessURL: URL) -> URL? {
        if webURL.scheme == ArkFileReaderSchemeHandler.scheme {
            return ArkFileReaderSchemeHandler.fileURL(
                fromReaderURL: webURL,
                rootURL: readAccessURL
            )
        }
        return webURL.isFileURL ? canonicalFileURL(webURL) : webURL
    }
}

struct ArkFileWebNavigationState: Equatable {
    private(set) var committedURL: URL?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    mutating func requestStarted() {
        isLoading = true
        errorMessage = nil
    }

    mutating func requestSucceeded(at url: URL?) {
        if let url {
            committedURL = url
        }
        isLoading = false
        errorMessage = nil
    }

    mutating func requestFailed(message: String) {
        isLoading = false
        errorMessage = message
    }
}

@MainActor
final class ArkFileWebReaderController: NSObject, ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var isNavigating = false
    @Published private(set) var navigationErrorMessage: String?
    @Published private(set) var currentAnchorIDSnapshot = ""
    /// Persistence notifications do not invalidate the SwiftUI reader tree.
    let readingProgress = PassthroughSubject<Void, Never>()
    let readingHistoryCheckpoints = PassthroughSubject<Void, Never>()
    private var readingProgressSubscription: AnyCancellable?

    private weak var webView: WKWebView?
    private var readAccessURL: URL?
    private var pendingURL: URL?
    private var canLoadPendingURL = false
    private var zoomPercent = 100
    private var lastKnownScrollTop: Double = 0
    private var lastKnownAnchorLabel = ""
    private var readingPositionRevision: UInt = 0
    private var readingHistoryRestoreID: String?
    private var readingHistoryRequiresProgress = false
    private var navigationState = ArkFileWebNavigationState()
    private var lastRequestedURL: URL?
    private var sameDocumentLoadTask: Task<Void, Never>?
    private var sameDocumentLoadGeneration = 0

    override init() {
        super.init()
        // Keep the throttle alive across SwiftUI body updates and temporary
        // downstream resubscriptions without retaining the controller.
        let checkpoints = readingHistoryCheckpoints
        readingProgressSubscription = readingProgress
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { checkpoints.send() }
    }

    var canRetryLastLoad: Bool {
        lastRequestedURL != nil
    }

    var currentScrollTopSnapshot: Double {
        lastKnownScrollTop
    }

    var cachedReadingHistoryLocation: ArkFileWebLocationSnapshot? {
        guard !isNavigating,
              navigationErrorMessage == nil,
              readingHistoryRestoreID == nil,
              !readingHistoryRequiresProgress,
              let currentURL else { return nil }
        var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
        if currentAnchorIDSnapshot.isEmpty {
            // Scrolling away from an anchor must not restore its old fragment.
            components?.fragment = nil
        }
        return ArkFileWebLocationSnapshot(
            url: components?.url ?? currentURL,
            scrollTop: lastKnownScrollTop,
            anchorID: currentAnchorIDSnapshot,
            anchorLabel: lastKnownAnchorLabel
        )
    }

    func beginReadingHistoryRestoration(id: String) {
        guard readingHistoryRestoreID != id else { return }
        readingHistoryRestoreID = id
        readingHistoryRequiresProgress = false
        readingPositionRevision &+= 1
    }

    func finishReadingHistoryRestoration(id: String) {
        guard readingHistoryRestoreID == id else { return }
        readingHistoryRestoreID = nil
        readingHistoryRequiresProgress = false
        readingProgress.send()
    }

    func failReadingHistoryRestoration(id: String) {
        guard readingHistoryRestoreID == id else { return }
        readingHistoryRestoreID = nil
        // Preserve the durable saved location after failed JavaScript. A real
        // movement, user scroll, or new navigation can resume checkpoints.
        readingHistoryRequiresProgress = true
        readingPositionRevision &+= 1
    }

    func cancelReadingHistoryRestorationForNavigation() {
        // Releasing an old target must not publish the old document position
        // between the user's new navigation intent and its committed location.
        guard isNavigating else { return }
        readingHistoryRestoreID = nil
        readingHistoryRequiresProgress = false
        readingPositionRevision &+= 1
    }

    func resumeReadingHistoryAfterUserScroll() {
        readingHistoryRestoreID = nil
        readingHistoryRequiresProgress = false
        readingPositionRevision &+= 1
        readingProgress.send()
    }

    func isPerformingProgrammaticSameDocumentLoad(to webURL: URL) -> Bool {
        guard sameDocumentLoadTask != nil,
              let lastRequestedURL,
              let readAccessURL,
              let expectedWebURL = ArkFileWebReaderURL.readerRequest(
                for: lastRequestedURL,
                readAccessURL: readAccessURL
              )?.url else {
            return false
        }
        return expectedWebURL == webURL
    }

    func attach(_ webView: WKWebView, readAccessURL: URL) {
        if self.webView !== webView {
            canLoadPendingURL = false
        }
        self.webView = webView
        self.readAccessURL = readAccessURL
        refreshNavigationMetadata()
    }

    private func refreshNavigationMetadata() {
        let nextCanGoBack = webView?.canGoBack ?? false
        let nextCanGoForward = webView?.canGoForward ?? false
        let nextTitle = webView?.title ?? ""

        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
        if title != nextTitle { title = nextTitle }
    }

    func markReadyForProgrammaticLoad() {
        canLoadPendingURL = true
        loadPendingURLIfPossible()
    }

    func load(_ url: URL) {
        lastRequestedURL = url
        cancelSameDocumentLoad()
        navigationState.requestStarted()
        publishNavigationState()
        guard let webView,
              canLoadPendingURL,
              webView.window != nil,
              !webView.bounds.isEmpty else {
            pendingURL = url
            return
        }
        pendingURL = nil
        if loadSameDocument(url, in: webView) {
            return
        }
        load(url, in: webView)
    }

    func goBack() {
        guard webView?.canGoBack == true else { return }
        cancelSameDocumentLoad()
        navigationState.requestStarted()
        publishNavigationState()
        webView?.goBack()
    }

    func goForward() {
        guard webView?.canGoForward == true else { return }
        cancelSameDocumentLoad()
        navigationState.requestStarted()
        publishNavigationState()
        webView?.goForward()
    }

    func retryLastLoad() {
        guard let lastRequestedURL else { return }
        load(lastRequestedURL)
    }

    func scrollToTop() {
        scrollTo(0)
    }

    func scrollTo(_ scrollTop: Double) {
        let resolvedScrollTop = max(0, scrollTop)
        updateScrollTop(resolvedScrollTop)
        webView?.evaluateJavaScript("window.scrollTo(0, \(Int(resolvedScrollTop.rounded())));")
    }

    func updateScrollTop(_ scrollTop: Double) {
        let resolvedScrollTop = max(0, scrollTop)
        guard resolvedScrollTop != lastKnownScrollTop else { return }
        readingPositionRevision &+= 1
        readingHistoryRequiresProgress = false
        if abs(resolvedScrollTop - lastKnownScrollTop) > 2,
           !currentAnchorIDSnapshot.isEmpty {
            currentAnchorIDSnapshot = ""
            lastKnownAnchorLabel = ""
        }
        lastKnownScrollTop = resolvedScrollTop
        readingProgress.send()
    }

    func updateLocation(scrollTop: Double, anchorID: String) {
        readingPositionRevision &+= 1
        readingHistoryRequiresProgress = false
        lastKnownScrollTop = max(0, scrollTop)
        let resolvedAnchorID = anchorID.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentAnchorIDSnapshot != resolvedAnchorID {
            currentAnchorIDSnapshot = resolvedAnchorID
            lastKnownAnchorLabel = ""
        }
        readingProgress.send()
    }

    func zoomOut() {
        zoomPercent = max(70, zoomPercent - 10)
        applyZoom()
    }

    func zoomIn() {
        zoomPercent = min(170, zoomPercent + 10)
        applyZoom()
    }

    func currentScrollTop() async -> Double {
        if let snapshot = await currentLocationSnapshot() {
            return snapshot.scrollTop
        }
        return lastKnownScrollTop
    }

    /// Captures one coherent committed-document location for bookmark writes.
    /// A failed JavaScript read is deliberately distinguishable from a valid
    /// page-top position so a transient WebKit failure cannot silently create
    /// a bookmark at offset zero.
    func currentLocationSnapshot() async -> ArkFileWebLocationSnapshot? {
        guard let webView,
              !isNavigating,
              !webView.isLoading,
              let committedURL = currentURL,
              let committedWebURL = webView.url,
              let readAccessURL,
              let visibleFileURL = ArkFileWebReaderURL.fileURL(
                fromWebURL: committedWebURL,
                readAccessURL: readAccessURL
              ),
              ArkFileWebReaderURL.canonicalFileURL(visibleFileURL)
                == ArkFileWebReaderURL.canonicalFileURL(committedURL) else {
            return nil
        }
        let capturedRevision = readingPositionRevision
        let script = """
        (() => {
          const scrollingElement = document.scrollingElement || document.documentElement || document.body;
          const scrollTop = Math.max(0, Math.round(
            (scrollingElement && scrollingElement.scrollTop) ||
            window.scrollY ||
            (document.documentElement && document.documentElement.scrollTop) ||
            (document.body && document.body.scrollTop) ||
            0
          ));
          const headingSelector = 'h1,h2,h3,h4,h5,h6';
          const selectors = [
            'h1[id]', 'h2[id]', 'h3[id]', 'h4[id]', 'h5[id]', 'h6[id]',
            'section[id]', 'article[id]', '[role="doc-chapter"][id]',
            'div.chapter[id]', 'a[name]', 'a[id]'
          ].join(',');
          let nearest = null;
          let nearestTop = -Infinity;
          for (const element of document.querySelectorAll(selectors)) {
            const id = (element.id || element.getAttribute('name') || '').trim();
            if (!id) continue;
            const top = element.getBoundingClientRect().top + scrollTop;
            if (top > scrollTop + 32 || top < nearestTop) continue;
            const heading = element.matches(headingSelector)
              ? element
              : element.closest(headingSelector) ||
                element.querySelector(headingSelector) ||
                (element.nextElementSibling && element.nextElementSibling.matches(headingSelector)
                  ? element.nextElementSibling
                  : null);
            const rawLabel = ((heading && heading.innerText) || element.getAttribute('aria-label') || '')
              .replace(/\\s+/g, ' ')
              .trim();
            nearest = { id, label: rawLabel.slice(0, 180) };
            nearestTop = top;
          }
          return {
            scrollTop,
            anchorID: nearest ? nearest.id : '',
            anchorLabel: nearest ? nearest.label : ''
          };
        })()
        """
        guard let result = try? await webView.evaluateJavaScript(script),
              readingPositionRevision == capturedRevision,
              !isNavigating,
              !webView.isLoading,
              webView.url == committedWebURL,
              currentURL == committedURL,
              let values = result as? [String: Any],
              let number = values["scrollTop"] as? NSNumber else {
            return nil
        }
        let resolvedScrollTop = max(0, number.doubleValue)
        let resolvedAnchorID = values["anchorID"] as? String ?? ""
        updateLocation(scrollTop: resolvedScrollTop, anchorID: resolvedAnchorID)
        lastKnownAnchorLabel = values["anchorLabel"] as? String ?? ""
        return ArkFileWebLocationSnapshot(
            url: committedURL,
            scrollTop: resolvedScrollTop,
            anchorID: resolvedAnchorID,
            anchorLabel: lastKnownAnchorLabel
        )
    }

    private func applyZoom() {
        webView?.evaluateJavaScript(
            "document.documentElement.style.webkitTextSizeAdjust='\(zoomPercent)%'; document.body.style.webkitTextSizeAdjust='\(zoomPercent)%';"
        )
    }

    private func loadPendingURLIfPossible() {
        guard let pendingURL,
              let webView,
              canLoadPendingURL,
              webView.window != nil,
              !webView.bounds.isEmpty else {
            return
        }
        self.pendingURL = nil
        load(pendingURL, in: webView)
    }

    private func load(_ url: URL, in webView: WKWebView) {
        let readAccessURL = readAccessURL ?? url.deletingLastPathComponent()
        guard let request = ArkFileWebReaderURL.readerRequest(
            for: url,
            readAccessURL: readAccessURL
        ) else {
            navigationState.requestFailed(message: ArkFileWebReaderURL.outsideReadAccessMessage)
            publishNavigationState()
            return
        }
        webView.load(request)
    }

    private func loadSameDocument(_ url: URL, in webView: WKWebView) -> Bool {
        guard let currentURL,
              currentURL != url,
              Self.isSameDocumentNavigation(from: currentURL, to: url),
              let readAccessURL,
              let readerURL = ArkFileWebReaderURL.readerRequest(
                for: url,
                readAccessURL: readAccessURL
              )?.url else {
            return false
        }
        if !currentAnchorIDSnapshot.isEmpty {
            currentAnchorIDSnapshot = ""
        }
        let rawFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment ?? ""
        let anchorID = rawFragment.removingPercentEncoding ?? rawFragment
        let readerLiteral = Self.javaScriptLiteral(readerURL.absoluteString)
        let generation = sameDocumentLoadGeneration
        let sourceWebURL = webView.url
        sameDocumentLoadTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                let settledLocation = try await self.settleSameDocumentLocation(
                    anchorID: anchorID,
                    in: webView
                )
                guard !Task.isCancelled,
                      self.sameDocumentLoadGeneration == generation,
                      self.lastRequestedURL == url,
                      webView.url == sourceWebURL else {
                    return
                }

                // Commit history only after the requested document location is
                // coherent. A missing anchor or JavaScript failure therefore
                // leaves both the visible and controller URLs at the prior
                // retryable location.
                _ = try await webView.evaluateJavaScript("""
                (() => {
                  const readerURL = \(readerLiteral);
                  history.pushState(null, '', readerURL);
                  return true;
                })()
                """)
                guard !Task.isCancelled,
                      self.sameDocumentLoadGeneration == generation,
                      self.lastRequestedURL == url,
                      webView.url == readerURL else {
                    return
                }
                self.updateLocation(
                    scrollTop: settledLocation.scrollTop,
                    anchorID: settledLocation.foundAnchor ? anchorID : ""
                )
                self.sameDocumentLoadTask = nil
                _ = self.navigationURLDidChange(in: webView)
            } catch {
                guard !Task.isCancelled,
                      self.sameDocumentLoadGeneration == generation,
                      self.lastRequestedURL == url,
                      webView.url == sourceWebURL else {
                    return
                }
                self.sameDocumentLoadTask = nil
                self.navigationDidFail(in: webView, error: error)
            }
        }
        return true
    }

    func settleSameDocumentLocation(
        anchorID: String,
        in webView: WKWebView
    ) async throws -> (scrollTop: Double, foundAnchor: Bool) {
        var lastObservedLocation: (scrollTop: Double, foundAnchor: Bool)?
        for delay in [
            UInt64(0),
            20_000_000,
            80_000_000,
            180_000_000,
            360_000_000
        ] {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            let result = try await webView.callAsyncJavaScript(
                """
                await new Promise(resolve => requestAnimationFrame(
                  () => requestAnimationFrame(resolve)
                ));
                const scrollingElement =
                  document.scrollingElement || document.documentElement || document.body;
                const currentScrollTop = () => Math.max(0, Math.round(
                  (scrollingElement && scrollingElement.scrollTop) || window.scrollY || 0
                ));
                if (!anchorID) {
                  window.scrollTo(0, 0);
                  await new Promise(resolve => requestAnimationFrame(resolve));
                  const scrollTop = currentScrollTop();
                  return { foundAnchor: false, settled: scrollTop <= 2, scrollTop };
                }
                const anchor = document.getElementById(anchorID) ||
                  Array.from(document.getElementsByName(anchorID))[0];
                if (!anchor) {
                  return {
                    foundAnchor: false,
                    settled: false,
                    scrollTop: currentScrollTop()
                  };
                }
                const beforeScrollTop = Math.max(
                  0,
                  (scrollingElement && scrollingElement.scrollTop) || window.scrollY || 0
                );
                const anchorTop = Math.max(
                  0,
                  Math.round(anchor.getBoundingClientRect().top + beforeScrollTop)
                );
                const scrollHeight = Math.max(
                  scrollingElement ? scrollingElement.scrollHeight || 0 : 0,
                  document.documentElement ? document.documentElement.scrollHeight || 0 : 0,
                  document.body ? document.body.scrollHeight || 0 : 0
                );
                const cssViewportWidth = Math.max(
                  1,
                  (document.documentElement && document.documentElement.clientWidth) ||
                    window.innerWidth ||
                    viewportWidthPoints
                );
                const cssPointsPerViewPoint = cssViewportWidth / viewportWidthPoints;
                const viewportHeight = Math.max(
                  1,
                  viewportHeightPoints * cssPointsPerViewPoint
                );
                const expectedScrollTop = Math.min(
                  anchorTop,
                  Math.max(0, scrollHeight - viewportHeight)
                );
                window.scrollTo(0, expectedScrollTop);
                await new Promise(resolve => requestAnimationFrame(resolve));
                const scrollTop = currentScrollTop();
                return {
                  foundAnchor: true,
                  settled: Math.abs(scrollTop - expectedScrollTop) <= 2,
                  scrollTop
                };
                """,
                arguments: [
                    "anchorID": anchorID,
                    "viewportWidthPoints": Double(max(1, webView.bounds.width)),
                    "viewportHeightPoints": Double(max(1, webView.bounds.height))
                ],
                in: nil,
                contentWorld: .page
            )
            guard let values = result as? [String: Any],
                  let scrollTop = values["scrollTop"] as? NSNumber else {
                continue
            }
            let observedLocation = (
                scrollTop: scrollTop.doubleValue,
                foundAnchor:
                    (values["foundAnchor"] as? NSNumber)?.boolValue == true
            )
            lastObservedLocation = observedLocation
            if (values["settled"] as? NSNumber)?.boolValue == true {
                return observedLocation
            }
        }

        // A real anchor whose final position differs slightly from WebKit's
        // expected clamp is still coherent: publish the actual rendered
        // position. A missing requested anchor is not a successful navigation.
        if let lastObservedLocation,
           anchorID.isEmpty || lastObservedLocation.foundAnchor {
            return lastObservedLocation
        }
        throw NSError(
            domain: "ArkFileWebReader",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ArkFile could not find this location in the offline chapter."
            ]
        )
    }

    func restoreCommittedSameDocumentURL(in webView: WKWebView) async {
        guard let committedURL = currentURL,
              let readAccessURL,
              let readerURL = ArkFileWebReaderURL.readerRequest(
                for: committedURL,
                readAccessURL: readAccessURL
              )?.url else {
            return
        }
        let readerLiteral = Self.javaScriptLiteral(readerURL.absoluteString)
        _ = try? await webView.evaluateJavaScript("""
        (() => {
          history.replaceState(null, '', \(readerLiteral));
          return true;
        })()
        """)
    }

    private func cancelSameDocumentLoad() {
        sameDocumentLoadGeneration &+= 1
        sameDocumentLoadTask?.cancel()
        sameDocumentLoadTask = nil
    }

    func navigationDidStart() {
        readingPositionRevision &+= 1
        lastKnownAnchorLabel = ""
        cancelSameDocumentLoad()
        if !currentAnchorIDSnapshot.isEmpty {
            currentAnchorIDSnapshot = ""
        }
        navigationState.requestStarted()
        readingHistoryRequiresProgress = false
        publishNavigationState()
    }

    func navigationDidFinish(in webView: WKWebView) {
        // Fragment-only history updates can still surface a WebKit delegate
        // finish. URL observation owns those transitions so they cannot be
        // published before the requested anchor has actually settled.
        guard sameDocumentURLChange(in: webView) == nil else {
            return
        }
        let committedURL = webView.url.flatMap { webURL in
            readAccessURL.flatMap {
                ArkFileWebReaderURL.fileURL(fromWebURL: webURL, readAccessURL: $0)
            }
        }
        if webView.url?.scheme == ArkFileReaderSchemeHandler.scheme, committedURL == nil {
            navigationState.requestFailed(message: "Couldn’t resolve this offline chapter.")
            publishNavigationState()
            return
        }
        updateScrollTop(Double(webView.scrollView.contentOffset.y))
        navigationState.requestSucceeded(at: committedURL ?? webView.url)
        lastRequestedURL = nil
        refreshNavigationMetadata()
        publishNavigationState()
    }

    @discardableResult
    func navigationURLChangeDidStart(in webView: WKWebView) -> Bool {
        guard sameDocumentURLChange(in: webView) != nil else {
            return false
        }
        // Once URL observation accepts the fragment transition, the
        // coordinator's bounded anchor retries own completion and failure.
        sameDocumentLoadTask?.cancel()
        sameDocumentLoadTask = nil
        navigationState.requestStarted()
        publishNavigationState()
        return true
    }

    @discardableResult
    func navigationURLDidChange(in webView: WKWebView) -> Bool {
        guard let visibleURL = sameDocumentURLChange(in: webView) else {
            return false
        }
        sameDocumentLoadTask?.cancel()
        sameDocumentLoadTask = nil
        navigationState.requestSucceeded(at: visibleURL)
        lastRequestedURL = nil
        refreshNavigationMetadata()
        publishNavigationState()
        return true
    }

    private func sameDocumentURLChange(in webView: WKWebView) -> URL? {
        guard let committedURL = navigationState.committedURL,
              let webURL = webView.url,
              let readAccessURL,
              let visibleURL = ArkFileWebReaderURL.fileURL(
                fromWebURL: webURL,
                readAccessURL: readAccessURL
              ),
              Self.isSameDocumentNavigation(from: committedURL, to: visibleURL),
              committedURL != visibleURL else {
            return nil
        }
        return visibleURL
    }

    func navigationDidFail(in webView: WKWebView, error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        sameDocumentLoadTask?.cancel()
        sameDocumentLoadTask = nil
        navigationState.requestFailed(message: error.localizedDescription)
        refreshNavigationMetadata()
        publishNavigationState()
    }

    private func publishNavigationState() {
        if currentURL != navigationState.committedURL {
            currentURL = navigationState.committedURL
        }
        if isNavigating != navigationState.isLoading {
            isNavigating = navigationState.isLoading
        }
        if navigationErrorMessage != navigationState.errorMessage {
            navigationErrorMessage = navigationState.errorMessage
        }
        readingProgress.send()
    }

    private static func isSameDocumentNavigation(from source: URL, to destination: URL) -> Bool {
        guard var sourceComponents = URLComponents(
            url: ArkFileWebReaderURL.canonicalFileURL(source),
            resolvingAgainstBaseURL: false
        ), var destinationComponents = URLComponents(
            url: ArkFileWebReaderURL.canonicalFileURL(destination),
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        sourceComponents.fragment = nil
        destinationComponents.fragment = nil
        return sourceComponents.url == destinationComponents.url
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return literal
    }
}

struct ArkFileWebLocationSnapshot: Equatable, Sendable {
    let url: URL
    let scrollTop: Double
    let anchorID: String
    let anchorLabel: String
}

struct ArkFileWebScrollTarget: Equatable {
    let id: String
    let scrollTop: Double?
    let anchorID: String?
    let expectedURL: URL?

    init?(
        id: String?,
        scrollTop: Double?,
        anchorID: String? = nil,
        expectedURL: URL? = nil
    ) {
        let resolvedAnchorID = anchorID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scrollTop != nil || resolvedAnchorID?.isEmpty == false else { return nil }
        let resolvedScrollTop = scrollTop.map { max(0, $0) }
        self.id = id ?? [
            resolvedAnchorID ?? "",
            resolvedScrollTop.map { String(Int($0.rounded())) } ?? "anchor"
        ].joined(separator: "|")
        self.scrollTop = resolvedScrollTop
        self.anchorID = resolvedAnchorID?.isEmpty == false ? resolvedAnchorID : nil
        self.expectedURL = expectedURL
    }

    func matchesCommittedURL(_ committedURL: URL?) -> Bool {
        guard let expectedURL else { return true }
        guard let committedURL else { return false }
        if expectedURL.isFileURL, committedURL.isFileURL {
            return expectedURL.standardizedFileURL.fileSystemPath
                == committedURL.standardizedFileURL.fileSystemPath
        }
        return expectedURL == committedURL
    }

    func validatedRestoredScrollTop(
        _ actualScrollTop: Double,
        maximumScrollTop: Double,
        anchorWasFound: Bool
    ) -> Double? {
        guard actualScrollTop.isFinite, maximumScrollTop.isFinite,
              actualScrollTop >= 0, maximumScrollTop >= 0 else {
            return nil
        }
        if let scrollTop {
            guard scrollTop.isFinite else { return nil }
            // A not-yet-laid-out document can return zero without throwing.
            // That must not replace a nonzero durable reading position.
            guard scrollTop <= 2 || actualScrollTop > 2,
                  abs(actualScrollTop - min(scrollTop, maximumScrollTop)) <= 2 else {
                return nil
            }
        } else if anchorID == nil || !anchorWasFound {
            return nil
        }
        return actualScrollTop
    }
}

struct ArkFileHTMLViewer: UIViewRepresentable {
    let url: URL
    let readAccessURL: URL
    let accessGuardURL: URL
    var controller: ArkFileWebReaderController?
    var targetScrollTop: Double?
    var targetScrollID: String? = nil
    var targetAnchorID: String? = nil
    var onBlankRenderDetected: (() -> Void)?

    /// EPUB-derived chapters (e.g. the OpenStax textbooks) often ship without
    /// mobile layout metadata and with publisher-specific text scaling. Keep
    /// valid viewport declarations intact while constraining oversized media,
    /// isolating wide tables, and narrowly normalizing known textbook scaling.
    static let responsivePresentationSource = """
        (function () {
          if (!document.querySelector('meta[name="viewport"]')) {
            var meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1';
            (document.head || document.documentElement).appendChild(meta);
          }
          if (!document.getElementById('arkfile-responsive-reader-style')) {
            var style = document.createElement('style');
            style.id = 'arkfile-responsive-reader-style';
            style.textContent = `
              html { max-width: 100%; -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
              body { box-sizing: border-box; max-width: 100%; overflow-wrap: break-word; }
              img, svg, video, canvas, object, embed, iframe { max-width: 100% !important; height: auto !important; }
              pre { box-sizing: border-box; max-width: 100%; overflow-x: auto; }
              .arkfile-wide-content { box-sizing: border-box; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }
            `;
            (document.head || document.documentElement).appendChild(style);
          }
          function isolateWideTables() {
            document.querySelectorAll('table').forEach(function (table) {
              if (table.parentElement && table.parentElement.classList.contains('arkfile-wide-content')) return;
              if (table.scrollWidth <= document.documentElement.clientWidth) return;
              var wrapper = document.createElement('div');
              wrapper.className = 'arkfile-wide-content';
              table.parentNode.insertBefore(wrapper, table);
              wrapper.appendChild(table);
            });
          }
          isolateWideTables();
          requestAnimationFrame(isolateWideTables);
          var root = document.documentElement;
          var body = document.body;
          if (root && body) {
            var sourceScaleText = getComputedStyle(root).getPropertyValue('--content-text-scale').trim();
            var sourceScale = parseFloat(sourceScaleText);
            var bodyFontSize = parseFloat(getComputedStyle(body).fontSize);
            if (Number.isFinite(sourceScale) && sourceScale > 0 && Number.isFinite(bodyFontSize) && bodyFontSize > 20) {
              root.style.setProperty('--content-text-scale', String(sourceScale * (18 / bodyFontSize)));
            }
            root.dataset.arkfileReaderPresentation = 'ready';
          }
        })();
        """

    private static let responsivePresentationScript = WKUserScript(
        source: responsivePresentationSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    func makeUIView(context: Context) -> WebViewContainer {
        let readerSchemeHandler = ArkFileReaderSchemeHandler(
            rootURL: readAccessURL,
            accessGuardURL: accessGuardURL
        )
        let configuration = Self.webViewConfiguration(readerSchemeHandler: readerSchemeHandler)
        context.coordinator.configure(readerSchemeHandler: readerSchemeHandler)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.backgroundColor = .systemBackground
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        controller?.attach(webView, readAccessURL: readAccessURL)
        let container = WebViewContainer(webView: webView)
        container.onReady = { [weak coordinator = context.coordinator, weak webView] in
            guard let webView else { return }
            coordinator?.webViewBecameReady(webView)
        }
        context.coordinator.requestLoad(
            url,
            readAccessURL: readAccessURL,
            accessGuardURL: accessGuardURL,
            in: webView
        )
        return container
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        let webView = container.webView
        controller?.attach(webView, readAccessURL: readAccessURL)
        context.coordinator.update(
            targetScroll: ArkFileWebScrollTarget(
                id: targetScrollID,
                scrollTop: targetScrollTop,
                anchorID: targetAnchorID,
                expectedURL: url
            ),
            onBlankRenderDetected: onBlankRenderDetected,
            in: webView
        )
        context.coordinator.requestLoad(
            url,
            readAccessURL: readAccessURL,
            accessGuardURL: accessGuardURL,
            in: webView
        )
    }

    static func webViewConfiguration(
        readerSchemeHandler: ArkFileReaderSchemeHandler
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.addUserScript(responsivePresentationScript)
        configuration.setURLSchemeHandler(
            readerSchemeHandler,
            forURLScheme: ArkFileReaderSchemeHandler.scheme
        )
        return configuration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            targetScroll: ArkFileWebScrollTarget(
                id: targetScrollID,
                scrollTop: targetScrollTop,
                anchorID: targetAnchorID,
                expectedURL: url
            ),
            onBlankRenderDetected: onBlankRenderDetected
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        private weak var controller: ArkFileWebReaderController?
        private var targetScroll: ArkFileWebScrollTarget?
        private var onBlankRenderDetected: (() -> Void)?
        private var didApplyTargetScroll = false
        private var requestedLoad: LoadRequest?
        private var scheduledLoad: LoadRequest?
        private var startedLoad: LoadRequest?
        private var reportedBlankLoad: LoadRequest?
        private var isWebViewReady = false
        private var loadTask: Task<Void, Never>?
        private var verificationTask: Task<Void, Never>?
        private var targetScrollTask: Task<Void, Never>?
        private var sameDocumentNavigationTask: Task<Void, Never>?
        private var webViewURLObservation: NSKeyValueObservation?
        private var readerSchemeHandler: ArkFileReaderSchemeHandler?
        private static let targetScrollRetryDelays: [UInt64] = [
            0,
            80_000_000,
            160_000_000,
            360_000_000,
            600_000_000
        ]

        @MainActor
        init(
            controller: ArkFileWebReaderController?,
            targetScroll: ArkFileWebScrollTarget?,
            onBlankRenderDetected: (() -> Void)?
        ) {
            self.controller = controller
            self.targetScroll = targetScroll
            self.onBlankRenderDetected = onBlankRenderDetected
            if let targetScroll {
                controller?.beginReadingHistoryRestoration(id: targetScroll.id)
            }
        }

        deinit {
            loadTask?.cancel()
            verificationTask?.cancel()
            targetScrollTask?.cancel()
            sameDocumentNavigationTask?.cancel()
            webViewURLObservation?.invalidate()
        }

        @MainActor
        func update(
            targetScroll: ArkFileWebScrollTarget?,
            onBlankRenderDetected: (() -> Void)?,
            in webView: WKWebView
        ) {
            let previousTarget = self.targetScroll
            let targetChanged = previousTarget != targetScroll
            self.targetScroll = targetScroll
            self.onBlankRenderDetected = onBlankRenderDetected
            if targetChanged {
                targetScrollTask?.cancel()
                if let targetScroll {
                    controller?.beginReadingHistoryRestoration(id: targetScroll.id)
                } else if let previousTarget {
                    controller?.finishReadingHistoryRestoration(id: previousTarget.id)
                }
                didApplyTargetScroll = false
                applyTargetScrollIfNeeded(in: webView)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let scrollTop = max(0, Double(scrollView.contentOffset.y))
            MainActor.assumeIsolated {
                controller?.updateScrollTop(scrollTop)
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            MainActor.assumeIsolated {
                targetScrollTask?.cancel()
                targetScrollTask = nil
                controller?.resumeReadingHistoryAfterUserScroll()
            }
        }

        @MainActor
        func configure(readerSchemeHandler: ArkFileReaderSchemeHandler) {
            self.readerSchemeHandler = readerSchemeHandler
        }

        @MainActor
        func requestLoad(
            _ url: URL,
            readAccessURL: URL,
            accessGuardURL: URL,
            in webView: WKWebView
        ) {
            guard readerSchemeHandler?.matches(
                rootURL: readAccessURL,
                accessGuardURL: accessGuardURL
            ) == true else {
                controller?.navigationDidFail(
                    in: webView,
                    error: NSError(
                        domain: "ArkFileWebReader",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The offline book changed while it was open."]
                    )
                )
                return
            }
            let request = LoadRequest(
                url: url,
                readAccessURL: readAccessURL,
                accessGuardURL: accessGuardURL
            )
            requestedLoad = request
            scheduleLoadIfReady(in: webView)
        }

        @MainActor
        func webViewBecameReady(_ webView: WKWebView) {
            isWebViewReady = true
            observeURLChanges(in: webView)
            controller?.markReadyForProgrammaticLoad()
            scheduleLoadIfReady(in: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                sameDocumentNavigationTask?.cancel()
                sameDocumentNavigationTask = nil
                targetScrollTask?.cancel()
                targetScrollTask = nil
                controller?.navigationDidStart()
                if didApplyTargetScroll {
                    controller?.cancelReadingHistoryRestorationForNavigation()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                controller?.navigationDidFinish(in: webView)
                if let targetScroll,
                   !targetScroll.matchesCommittedURL(controller?.currentURL) {
                    controller?.finishReadingHistoryRestoration(id: targetScroll.id)
                }
                applyTargetScrollIfNeeded(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                controller?.navigationDidFail(in: webView, error: error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                readerSchemeHandler?.didFailProvisionalNavigation()
                controller?.navigationDidFail(in: webView, error: error)
            }
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                if navigationAction.navigationType == .linkActivated {
                    await UIApplication.shared.open(url)
                }
                return .cancel
            }
            return ArkFileHTMLNavigationPolicy.allowsInWebView(
                url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame,
                hasCommittedDocument: webView.url != nil
            ) ? .allow : .cancel
        }

        @MainActor
        private func scheduleLoadIfReady(in webView: WKWebView) {
            guard isWebViewReady,
                  let request = requestedLoad,
                  startedLoad != request,
                  scheduledLoad != request else {
                return
            }
            scheduledLoad = request
            loadTask?.cancel()
            loadTask = Task { @MainActor [weak self, weak webView] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      let webView,
                      self.requestedLoad == request else {
                    return
                }
                self.scheduledLoad = nil
                self.startedLoad = request
                self.reportedBlankLoad = nil
                self.didApplyTargetScroll = false
                self.targetScrollTask?.cancel()
                self.targetScrollTask = nil
                self.verificationTask?.cancel()
                guard let readerRequest = ArkFileWebReaderURL.readerRequest(
                    for: request.url,
                    readAccessURL: request.readAccessURL
                ) else {
                    let error = NSError(
                        domain: "ArkFileWebReader",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: ArkFileWebReaderURL.outsideReadAccessMessage]
                    )
                    self.controller?.navigationDidFail(in: webView, error: error)
                    return
                }
                webView.load(readerRequest)
                self.scheduleBlankLoadRetry(for: request, in: webView)
            }
        }

        @MainActor
        private func observeURLChanges(in webView: WKWebView) {
            webViewURLObservation?.invalidate()
            webViewURLObservation = webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let self,
                          let webView,
                          let expectedWebURL = webView.url else {
                        return
                    }
                    // Every observed document-location change supersedes any
                    // delayed bookmark-layout retries for the prior location.
                    self.targetScrollTask?.cancel()
                    self.targetScrollTask = nil
                    if self.controller?
                        .isPerformingProgrammaticSameDocumentLoad(
                            to: expectedWebURL
                        ) == true {
                        // The controller owns completion for this exact URL.
                        if self.didApplyTargetScroll {
                            self.controller?.cancelReadingHistoryRestorationForNavigation()
                        }
                        return
                    }
                    guard self.controller?
                    .navigationURLChangeDidStart(in: webView) == true else {
                        return
                    }
                    if self.didApplyTargetScroll {
                        self.controller?.cancelReadingHistoryRestorationForNavigation()
                    }
                    let rawFragment = URLComponents(
                        url: expectedWebURL,
                        resolvingAgainstBaseURL: false
                    )?
                        .fragment
                        ?? ""
                    let anchorID = rawFragment.removingPercentEncoding ?? rawFragment
                    self.sameDocumentNavigationTask?.cancel()
                    self.sameDocumentNavigationTask = Task { @MainActor [weak self, weak webView] in
                        guard let self,
                              let webView,
                              let controller = self.controller else {
                            return
                        }
                        do {
                            let settledLocation =
                                try await controller.settleSameDocumentLocation(
                                    anchorID: anchorID,
                                    in: webView
                                )
                            guard !Task.isCancelled,
                                  webView.url == expectedWebURL else {
                                return
                            }
                            controller.updateLocation(
                                scrollTop: settledLocation.scrollTop,
                                anchorID:
                                    settledLocation.foundAnchor
                                        ? anchorID
                                        : ""
                            )
                            guard controller.navigationURLDidChange(
                                in: webView
                            ) else {
                                return
                            }
                            self.applyTargetScrollIfNeeded(in: webView)
                        } catch is CancellationError {
                            return
                        } catch {
                            guard !Task.isCancelled else {
                                return
                            }
                            guard webView.url == expectedWebURL else {
                                return
                            }
                            await controller
                                .restoreCommittedSameDocumentURL(in: webView)
                            guard !Task.isCancelled else {
                                return
                            }
                            controller.navigationDidFail(
                                in: webView,
                                error: error
                            )
                        }
                    }
                }
            }
        }

        @MainActor
        private static func applySameDocumentFragment(
            _ anchorID: String,
            in webView: WKWebView
        ) async -> Double? {
            let script = """
            const anchorID = requestedAnchorID;
            const scrollingElement =
              document.scrollingElement ||
              document.documentElement ||
              document.body;
            let targetAnchor = null;
            if (!anchorID) {
              window.scrollTo(0, 0);
            } else {
              targetAnchor =
                document.getElementById(anchorID) ||
                Array.from(document.getElementsByName(anchorID))[0];
              if (!targetAnchor) return null;
              targetAnchor.scrollIntoView({
                block: 'start',
                inline: 'nearest'
              });
            }
            await new Promise((resolve) => {
              let completed = false;
              const finish = () => {
                if (completed) return;
                completed = true;
                resolve();
              };
              requestAnimationFrame(() => requestAnimationFrame(finish));
              setTimeout(finish, 100);
            });
            const scrollTop = Math.max(0, Math.round(
              (scrollingElement && scrollingElement.scrollTop) ||
              window.scrollY ||
              (document.documentElement &&
                document.documentElement.scrollTop) ||
              (document.body && document.body.scrollTop) ||
              0
            ));
            if (!anchorID) {
              return scrollTop <= 1 ? scrollTop : null;
            }
            const rect = targetAnchor.getBoundingClientRect();
            const viewportHeight = Math.max(
              1,
              window.innerHeight ||
                (document.documentElement &&
                  document.documentElement.clientHeight) ||
                0
            );
            const documentHeight = Math.max(
              scrollingElement ? scrollingElement.scrollHeight : 0,
              document.documentElement
                ? document.documentElement.scrollHeight
                : 0,
              document.body ? document.body.scrollHeight : 0
            );
            const maximumScrollTop = Math.max(
              0,
              documentHeight - viewportHeight
            );
            const settledNearTop = Math.abs(rect.top) <= 32;
            const settledAtDocumentBottom =
              Math.abs(scrollTop - Math.round(maximumScrollTop)) <= 2 &&
              rect.top >= -1 &&
              rect.top < viewportHeight;
            return settledNearTop || settledAtDocumentBottom
              ? scrollTop
              : null;
            """
            guard let result = try? await webView.callAsyncJavaScript(
                script,
                arguments: ["requestedAnchorID": anchorID],
                in: nil,
                contentWorld: .page
            ) else {
                return nil
            }
            if let number = result as? NSNumber {
                return number.doubleValue
            }
            return result as? Double
        }

        @MainActor
        private func applyTargetScrollIfNeeded(in webView: WKWebView) {
            guard !didApplyTargetScroll,
                  let targetScroll,
                  targetScroll.matchesCommittedURL(controller?.currentURL),
                  !webView.isLoading,
                  webView.url != nil else {
                return
            }
            didApplyTargetScroll = true
            targetScrollTask?.cancel()
            targetScrollTask = Task { @MainActor [weak self, weak webView] in
                guard let self else { return }
                defer {
                    // A cancelled or replaced target has its own cleanup.
                    // Other early exits must release this attempt's ID while
                    // preserving the durable location until actual progress.
                    if !Task.isCancelled, self.targetScroll == targetScroll {
                        self.controller?.failReadingHistoryRestoration(id: targetScroll.id)
                    }
                }
                guard let webView else { return }
                var restored = false
                for delay in Self.targetScrollRetryDelays {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    guard !Task.isCancelled,
                          self.targetScroll == targetScroll,
                          targetScroll.matchesCommittedURL(self.controller?.currentURL),
                          !webView.isLoading,
                          webView.url != nil else {
                        return
                    }
                    guard let actualScrollTop = await Self.apply(
                        targetScroll,
                        in: webView
                    ) else {
                        restored = false
                        continue
                    }
                    guard !Task.isCancelled, self.targetScroll == targetScroll else { return }
                    self.controller?.updateLocation(
                        scrollTop: actualScrollTop,
                        anchorID: targetScroll.anchorID ?? ""
                    )
                    restored = true
                }
                if restored, !Task.isCancelled, self.targetScroll == targetScroll {
                    // Success releases the ID, so the deferred failure cleanup
                    // becomes a no-op.
                    self.controller?.finishReadingHistoryRestoration(id: targetScroll.id)
                }
            }
        }

        @MainActor
        private static func apply(
            _ target: ArkFileWebScrollTarget,
            in webView: WKWebView
        ) async -> Double? {
            let anchorLiteral = javaScriptLiteral(target.anchorID)
            let scrollLiteral = target.scrollTop.map { String($0) } ?? "null"
            let script = """
            (() => {
              const anchorID = \(anchorLiteral);
              const targetScroll = \(scrollLiteral);
              let anchorWasFound = false;
              if (anchorID) {
                const anchor = document.getElementById(anchorID) ||
                  Array.from(document.getElementsByName(anchorID))[0];
                if (anchor) {
                  anchorWasFound = true;
                  anchor.scrollIntoView({ block: 'start', inline: 'nearest' });
                }
              }
              if (targetScroll !== null && Number.isFinite(targetScroll)) {
                window.scrollTo(0, Math.max(0, targetScroll));
              }
              const scrollingElement = document.scrollingElement || document.documentElement || document.body;
              const scrollTop = Math.max(0, Math.round(
                (scrollingElement && scrollingElement.scrollTop) ||
                window.scrollY ||
                (document.documentElement && document.documentElement.scrollTop) ||
                (document.body && document.body.scrollTop) ||
                0
              ));
              const scrollHeight = Math.max(
                scrollingElement ? scrollingElement.scrollHeight || 0 : 0,
                document.documentElement ? document.documentElement.scrollHeight || 0 : 0,
                document.body ? document.body.scrollHeight || 0 : 0
              );
              const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
              return { scrollTop, maximumScrollTop: Math.max(0, scrollHeight - viewportHeight), anchorWasFound };
            })()
            """
            guard let result = try? await webView.evaluateJavaScript(script),
                  let values = result as? [String: Any],
                  let scrollTop = values["scrollTop"] as? NSNumber,
                  let maximumScrollTop = values["maximumScrollTop"] as? NSNumber,
                  let anchorWasFound = values["anchorWasFound"] as? Bool else {
                return nil
            }
            return target.validatedRestoredScrollTop(
                scrollTop.doubleValue,
                maximumScrollTop: maximumScrollTop.doubleValue,
                anchorWasFound: anchorWasFound
            )
        }

        private static func javaScriptLiteral(_ value: String?) -> String {
            guard let value,
                  let data = try? JSONEncoder().encode(value),
                  let literal = String(data: data, encoding: .utf8) else {
                return "null"
            }
            return literal
        }

        @MainActor
        private func scheduleBlankLoadRetry(for request: LoadRequest, in webView: WKWebView) {
            guard reportedBlankLoad != request else { return }
            verificationTask?.cancel()
            verificationTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      let webView else {
                    return
                }
                await self.retryIfWebViewStayedBlank(request, in: webView)
            }
        }

        @MainActor
        private func retryIfWebViewStayedBlank(_ request: LoadRequest, in webView: WKWebView) async {
            guard requestedLoad == request,
                  reportedBlankLoad != request else {
                return
            }
            if webView.isLoading && webView.url != nil {
                return
            }
            if webView.url != nil,
               await documentHasRenderableContent(in: webView) {
                if !(await visibleSnapshotLooksBlank(in: webView)) {
                    return
                }
            }
            reportedBlankLoad = request
            Log.ContentPack.info(
                "HTML book WebView appeared blank after load; remounting \(request.url.lastPathComponent, privacy: .public)"
            )
            onBlankRenderDetected?()
        }

        @MainActor
        private func documentHasRenderableContent(in webView: WKWebView) async -> Bool {
            let script = """
            (() => {
              const body = document.body;
              const root = document.documentElement;
              const text = ((body && (body.innerText || body.textContent)) || (root && root.textContent) || '').trim().length;
              const images = document.images ? document.images.length : 0;
              const svgs = document.getElementsByTagName('svg').length;
              const bodyRect = body ? body.getBoundingClientRect() : { width: 0, height: 0 };
              const rootRect = root ? root.getBoundingClientRect() : { width: 0, height: 0 };
              const width = Math.max(
                bodyRect.width || 0,
                rootRect.width || 0,
                body ? body.scrollWidth || 0 : 0,
                root ? root.scrollWidth || 0 : 0
              );
              const height = Math.max(
                bodyRect.height || 0,
                rootRect.height || 0,
                body ? body.scrollHeight || 0 : 0,
                root ? root.scrollHeight || 0 : 0
              );
              return { text, images, svgs, width, height };
            })()
            """
            guard let result = try? await webView.evaluateJavaScript(script) else {
                return false
            }
            let values: [String: Any]
            if let dictionary = result as? [String: Any] {
                values = dictionary
            } else if let dictionary = result as? NSDictionary {
                values = dictionary as? [String: Any] ?? [:]
            } else {
                return false
            }
            let hasContent = Self.intValue(values["text"]) > 0
                || Self.intValue(values["images"]) > 0
                || Self.intValue(values["svgs"]) > 0
            return hasContent
                && Self.doubleValue(values["width"]) > 0
                && Self.doubleValue(values["height"]) > 0
        }

        @MainActor
        private func visibleSnapshotLooksBlank(in webView: WKWebView) async -> Bool {
            guard webView.window != nil,
                  !webView.bounds.isEmpty else {
                return true
            }
            let image = await withCheckedContinuation { continuation in
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
                webView.takeSnapshot(with: configuration) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            guard let image else {
                return true
            }
            return Self.snapshotLooksBlank(image)
        }

        private static func snapshotLooksBlank(_ image: UIImage) -> Bool {
            guard let cgImage = image.cgImage else {
                return true
            }
            let sampleWidth = 32
            let sampleHeight = 32
            let bytesPerPixel = 4
            let bytesPerRow = sampleWidth * bytesPerPixel
            var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return false
                }
                context.interpolationQuality = .low
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
                return true
            }
            guard didDraw else {
                return true
            }
            var nonBlankPixelCount = 0
            for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                let alpha = Int(pixels[index + 3])
                if alpha > 20 && (red < 245 || green < 245 || blue < 245) {
                    nonBlankPixelCount += 1
                    if nonBlankPixelCount >= 4 {
                        return false
                    }
                }
            }
            return true
        }

        private static func intValue(_ value: Any?) -> Int {
            if let number = value as? NSNumber {
                return number.intValue
            }
            if let int = value as? Int {
                return int
            }
            if let double = value as? Double {
                return Int(double)
            }
            return 0
        }

        private static func doubleValue(_ value: Any?) -> Double {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let double = value as? Double {
                return double
            }
            if let int = value as? Int {
                return Double(int)
            }
            return 0
        }

        private struct LoadRequest: Equatable {
            let url: URL
            let readAccessURL: URL
            let accessGuardURL: URL
        }
    }

    final class WebViewContainer: UIView {
        let webView: WKWebView
        var onReady: (() -> Void)?

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            backgroundColor = .systemBackground
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            notifyReadyIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            notifyReadyIfPossible()
        }

        private func notifyReadyIfPossible() {
            guard window != nil,
                  bounds.width > 0,
                  bounds.height > 0 else {
                return
            }
            onReady?()
        }
    }
}
#endif
