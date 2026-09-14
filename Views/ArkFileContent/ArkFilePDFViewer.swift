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
import PDFKit
import SwiftUI

enum ArkFilePDFZoom {
    static let initialScaleFactor: CGFloat = 1
    static let fallbackMinimumScaleFactor: CGFloat = 0.25
    static let maximumFitScaleMultiplier: CGFloat = 16
    static let zoomInMultiplier: CGFloat = 1.6
    static let zoomOutMultiplier: CGFloat = 0.75
    static let pagePadding: CGFloat = 12

    @MainActor
    static func configure(_ view: PDFView) {
        view.autoScales = false
        applyLimits(to: view)
        applyFit(to: view)
    }

    @MainActor
    static func applyLimits(to view: PDFView) {
        let fitScale = fitScale(for: view)
        if fitScale > 0 {
            view.minScaleFactor = fitScale
            view.maxScaleFactor = max(initialScaleFactor, fitScale * maximumFitScaleMultiplier)
        } else {
            view.minScaleFactor = fallbackMinimumScaleFactor
            view.maxScaleFactor = maximumFitScaleMultiplier
        }
    }

    @MainActor
    static func applyFit(to view: PDFView) {
        let fitScale = fitScale(for: view)
        let targetScale = fitScale > 0 ? fitScale : initialScaleFactor
        view.scaleFactor = min(max(targetScale, view.minScaleFactor), view.maxScaleFactor)
    }

    static func fitScale(viewportSize: CGSize, pageSize: CGSize) -> CGFloat {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              pageSize.width > 0,
              pageSize.height > 0 else {
            return 0
        }
        let availableWidth = max(1, viewportSize.width - (pagePadding * 2))
        let availableHeight = max(1, viewportSize.height - (pagePadding * 2))
        return min(
            initialScaleFactor,
            min(availableWidth / pageSize.width, availableHeight / pageSize.height)
        )
    }

    @MainActor
    static func pageSize(for view: PDFView) -> CGSize? {
        guard let page = view.currentPage ?? view.document?.page(at: 0) else {
            return nil
        }
        let pageBounds = page.bounds(for: view.displayBox)
        var size = CGSize(width: abs(pageBounds.width), height: abs(pageBounds.height))
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    @MainActor
    private static func fitScale(for view: PDFView) -> CGFloat {
        guard let pageSize = pageSize(for: view) else {
            return 0
        }
        return fitScale(viewportSize: view.bounds.size, pageSize: pageSize)
    }
}

struct ArkFilePDFRefitState {
    private var lastViewportSize: CGSize = .zero
    private var lastPageSize: CGSize = .zero

    mutating func shouldRefit(
        viewportSize: CGSize,
        pageSize: CGSize,
        force: Bool = false
    ) -> Bool {
        let shouldRefit = force
            || viewportSize != lastViewportSize
            || pageSize != lastPageSize
        lastViewportSize = viewportSize
        lastPageSize = pageSize
        return shouldRefit
    }
}

final class ArkFileFittingPDFView: PDFView {
    var presentationDidChange: ((ArkFileFittingPDFView) -> Void)?
    private(set) var hasCompletedNonemptyLayout = false
    private var lastReportedBoundsSize: CGSize = .zero
    private var lastReportedWindowAttachment = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        hasCompletedNonemptyLayout = false
        if window != nil {
            setNeedsLayout()
        }
        reportPresentationChangeIfNeeded(force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let becameLayoutReady = window != nil
            && !bounds.isEmpty
            && !hasCompletedNonemptyLayout
        if becameLayoutReady {
            hasCompletedNonemptyLayout = true
        }
        reportPresentationChangeIfNeeded(force: becameLayoutReady)
    }

    func invalidateCompletedOnscreenLayout() {
        hasCompletedNonemptyLayout = false
        setNeedsLayout()
        reportPresentationChangeIfNeeded(force: true)
    }

    private func reportPresentationChangeIfNeeded(force: Bool = false) {
        let isAttachedToWindow = window != nil
        guard force
                || bounds.size != lastReportedBoundsSize
                || isAttachedToWindow != lastReportedWindowAttachment else {
            return
        }
        lastReportedBoundsSize = bounds.size
        lastReportedWindowAttachment = isAttachedToWindow
        presentationDidChange?(self)
    }
}

final class ArkFilePDFReaderController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var pageNumber = 1
    @Published private(set) var pageCount = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    let readingHistoryCheckpoints = PassthroughSubject<Void, Never>()

    private var readingProgressSubscription: AnyCancellable?
    private weak var pdfView: PDFView?
    private var pageChangeObserver: NSObjectProtocol?
    private var pendingPageNumber: Int?

    override init() {
        super.init()
        let checkpoints = readingHistoryCheckpoints
        readingProgressSubscription = $pageNumber
            .combineLatest($pageCount)
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { _ in checkpoints.send() }
    }

    @MainActor
    var readingHistoryPageNumber: Int? {
        guard pdfView?.document != nil, pageCount > 0, pendingPageNumber == nil else { return nil }
        return pageNumber
    }

    deinit {
        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
        }
    }

    @MainActor
    func attach(_ view: PDFView) {
        guard pdfView !== view else {
            applyPendingPageOrRefresh()
            return
        }
        pdfView = view
        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
        }
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        applyPendingPageOrRefresh()
    }

    @MainActor
    func detach(_ view: PDFView) {
        guard pdfView === view else { return }
        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
            self.pageChangeObserver = nil
        }
        pdfView = nil
    }

    @MainActor
    func goToPreviousPage() {
        pdfView?.goToPreviousPage(nil)
        refresh()
    }

    @MainActor
    func goToNextPage() {
        pdfView?.goToNextPage(nil)
        refresh()
    }

    @MainActor
    @discardableResult
    func goToPage(_ page: Int) -> Bool {
        guard page > 0 else {
            pendingPageNumber = nil
            return false
        }
        pendingPageNumber = page
        return applyPendingPageIfReady()
    }

    @MainActor
    func cancelPendingPageRequest() {
        pendingPageNumber = nil
    }

    @MainActor
    private func applyPendingPageIfReady() -> Bool {
        guard let pendingPageNumber,
              let pdfView,
              pdfView.window != nil,
              !pdfView.bounds.isEmpty,
              let document = pdfView.document else {
            return false
        }
        let resolvedPage = min(pendingPageNumber, document.pageCount)
        guard resolvedPage > 0,
              let targetPage = document.page(at: resolvedPage - 1) else {
            return false
        }
        pdfView.go(to: targetPage)
        guard let currentPage = pdfView.currentPage,
              document.index(for: currentPage) == resolvedPage - 1 else {
            refresh()
            return false
        }
        refresh()
        self.pendingPageNumber = nil
        return true
    }

    @MainActor
    private func applyPendingPageOrRefresh() {
        if pendingPageNumber == nil || !applyPendingPageIfReady() {
            refresh()
        }
    }

    @MainActor
    func zoomOut() {
        guard let pdfView else { return }
        pdfView.scaleFactor = max(pdfView.minScaleFactor, pdfView.scaleFactor * ArkFilePDFZoom.zoomOutMultiplier)
    }

    @MainActor
    func zoomIn() {
        guard let pdfView else { return }
        ArkFilePDFZoom.applyLimits(to: pdfView)
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, pdfView.scaleFactor * ArkFilePDFZoom.zoomInMultiplier)
    }

    @MainActor
    func scrollToTop() {
        goToPage(1)
    }

    @MainActor
    private func refresh() {
        let document = pdfView?.document
        let nextPageCount = document?.pageCount ?? 0
        let nextPageNumber: Int
        if let document, let currentPage = pdfView?.currentPage {
            nextPageNumber = document.index(for: currentPage) + 1
        } else {
            nextPageNumber = nextPageCount == 0 ? 1 : pageNumber
        }
        let nextCanGoBack = nextPageNumber > 1
        let nextCanGoForward = nextPageCount > 0 && nextPageNumber < nextPageCount

        // Reattaching the same PDFView is part of SwiftUI's update pass.
        // Publishing unchanged values here would schedule that pass forever.
        if pageCount != nextPageCount { pageCount = nextPageCount }
        if pageNumber != nextPageNumber { pageNumber = nextPageNumber }
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }
    }
}

struct ArkFilePDFViewer: View {
    let url: URL
    var controller: ArkFilePDFReaderController?
    var targetPage: Int?
    @StateObject private var documentLoader: ArkFilePDFDocumentLoader

    init(url: URL, controller: ArkFilePDFReaderController? = nil, targetPage: Int? = nil) {
        self.url = url
        self.controller = controller
        self.targetPage = targetPage
        _documentLoader = StateObject(wrappedValue: ArkFilePDFDocumentLoader(url: url))
    }

    var body: some View {
        if let document = documentLoader.document {
            ArkFilePDFKitView(document: document, controller: controller, targetPage: targetPage)
                .ignoresSafeArea(edges: .bottom)
        } else if documentLoader.didFinishLoading {
            ContentUnavailableView(
                "Could not open PDF",
                systemImage: "doc.richtext",
                description: Text(url.lastPathComponent)
            )
        } else {
            LoadingDataView()
        }
    }
}

@MainActor
private final class ArkFilePDFDocumentLoader: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var didFinishLoading = false
    private var loadTask: Task<Void, Never>?
    private var readLease: ArkFileDirectReadLease?

    init(url: URL) {
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard let readLease = ArkFileInstalledContentAccess.acquireDirectReadLease(
                    for: url
                ) else {
                    return SendablePDFDocument(value: nil, readLease: nil)
                }
                return SendablePDFDocument(
                    value: PDFDocument(url: readLease.url),
                    readLease: readLease
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.document = result.value
            self?.readLease = result.readLease
            self?.didFinishLoading = true
        }
    }

    deinit {
        loadTask?.cancel()
    }

    private struct SendablePDFDocument: @unchecked Sendable {
        let value: PDFDocument?
        let readLease: ArkFileDirectReadLease?
    }
}

struct ArkFilePDFKitView: UIViewRepresentable {
    let document: PDFDocument
    let controller: ArkFilePDFReaderController?
    let targetPage: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    nonisolated static func shouldReplaceDocument(
        current: PDFDocument?,
        requested: PDFDocument
    ) -> Bool {
        current !== requested
    }

    func makeUIView(context: Context) -> ArkFileFittingPDFView {
        let view = ArkFileFittingPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = false
        view.backgroundColor = .systemBackground
        view.document = document
        ArkFilePDFZoom.configure(view)
        context.coordinator.update(
            controller: controller,
            targetPage: targetPage,
            in: view
        )
        return view
    }

    func updateUIView(_ view: ArkFileFittingPDFView, context: Context) {
        if Self.shouldReplaceDocument(current: view.document, requested: document) {
            context.coordinator.prepareForDocumentReplacement(in: view)
            view.invalidateCompletedOnscreenLayout()
            view.document = document
            ArkFilePDFZoom.configure(view)
        }
        context.coordinator.update(
            controller: controller,
            targetPage: targetPage,
            in: view
        )
    }

    static func dismantleUIView(
        _ view: ArkFileFittingPDFView,
        coordinator: Coordinator
    ) {
        coordinator.detach(from: view)
    }

    @MainActor
    final class Coordinator {
        private(set) var appliedTargetPage: Int?
        private weak var attachedView: ArkFileFittingPDFView?
        private weak var controller: ArkFilePDFReaderController?
        private var requestedTargetPage: Int?
        private var refitState = ArkFilePDFRefitState()

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor
        func update(
            controller: ArkFilePDFReaderController?,
            targetPage: Int?,
            in view: ArkFileFittingPDFView
        ) {
            let previousController = self.controller
            self.controller = controller
            let normalizedTargetPage = targetPage.flatMap { $0 > 0 ? $0 : nil }
            let explicitlyInvalidTarget = targetPage.map { $0 <= 0 } ?? false
            if previousController !== controller {
                previousController?.cancelPendingPageRequest()
                if let attachedView {
                    previousController?.detach(attachedView)
                }
                appliedTargetPage = nil
            }
            if requestedTargetPage != normalizedTargetPage || explicitlyInvalidTarget {
                controller?.cancelPendingPageRequest()
                requestedTargetPage = normalizedTargetPage
                appliedTargetPage = nil
            }
            attachPresentationObserver(to: view)
            applyReaderStateIfReady(in: view)
        }

        func prepareForDocumentReplacement(in view: ArkFileFittingPDFView) {
            controller?.detach(view)
            appliedTargetPage = nil
            refitState = ArkFilePDFRefitState()
        }

        func detach(from view: ArkFileFittingPDFView) {
            guard attachedView === view else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: .PDFViewPageChanged,
                object: view
            )
            view.presentationDidChange = nil
            controller?.cancelPendingPageRequest()
            controller?.detach(view)
            attachedView = nil
            controller = nil
            requestedTargetPage = nil
            appliedTargetPage = nil
            refitState = ArkFilePDFRefitState()
        }

        private func attachPresentationObserver(to view: ArkFileFittingPDFView) {
            if attachedView !== view {
                if let attachedView {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: .PDFViewPageChanged,
                        object: attachedView
                    )
                    attachedView.presentationDidChange = nil
                    controller?.detach(attachedView)
                }
                attachedView = view
                refitState = ArkFilePDFRefitState()
                view.presentationDidChange = { [weak self] view in
                    self?.applyReaderStateIfReady(in: view)
                }
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(pageDidChange(_:)),
                    name: .PDFViewPageChanged,
                    object: view,
                )
            }
        }

        @objc private func pageDidChange(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            refitIfNeeded(view)
        }

        private func applyReaderStateIfReady(in view: ArkFileFittingPDFView) {
            guard view.window != nil,
                  !view.bounds.isEmpty,
                  view.hasCompletedNonemptyLayout else {
                return
            }

            // PDFKit resets an early go(to:) when a zero-sized PDFView receives
            // its first real on-screen layout. Fit first, then attach and apply
            // the saved page only after that layout is established.
            refitIfNeeded(view, force: attachedView === view && controller?.pageCount == 0)
            controller?.attach(view)
            applyTargetPageIfNeeded(in: view)
        }

        private func applyTargetPageIfNeeded(in view: PDFView) {
            guard let targetPage = requestedTargetPage,
                  appliedTargetPage != targetPage,
                  let controller,
                  let document = view.document,
                  document.pageCount > 0 else {
                return
            }
            guard controller.goToPage(targetPage) else { return }
            appliedTargetPage = targetPage
        }

        @MainActor
        func refitIfNeeded(_ view: PDFView, force: Bool = false) {
            guard !view.bounds.isEmpty,
                  let pageSize = ArkFilePDFZoom.pageSize(for: view) else {
                return
            }
            guard refitState.shouldRefit(
                viewportSize: view.bounds.size,
                pageSize: pageSize,
                force: force
            ) else { return }
            ArkFilePDFZoom.applyLimits(to: view)
            ArkFilePDFZoom.applyFit(to: view)
        }
    }
}
#endif
