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

import CoreData
import SwiftUI
import WebKit
import Defaults

#if os(macOS)
struct WebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserViewModel
    
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        let webView = browser.webView
        enableAutoLayout(nsView: nsView, webView: webView)
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(view: self,
                    onChangingFullscreen: { (enters: Bool, webView: WKWebView) in
            guard let nsView = webView.superview else { return }
            if enters {
                // auto-layout is not working
                // when the video is paused in full screen
                disableAutoLayout(nsView: nsView, webView: webView)
            } else {
                enableAutoLayout(nsView: nsView, webView: webView)
            }
        })
    }
    
    @MainActor
    private func enableAutoLayout(nsView: NSView, webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        nsView.addSubview(webView)
        
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: nsView.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    
    @MainActor
    private func disableAutoLayout(nsView: NSView, webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        nsView.addSubview(webView)
    }

    final class Coordinator {
        private let pageZoomObserver: Defaults.Observation
        private let fullScreenObserver: NSKeyValueObservation

        @MainActor
        init(
            view: WebView,
            onChangingFullscreen: @escaping @Sendable @MainActor (_ enters: Bool, _ webView: WKWebView) -> Void
        ) {
            let browser = view.browser
            pageZoomObserver = Defaults.observe(.webViewPageZoom) { [weak browser] change in
                browser?.webView.pageZoom = change.newValue
            }
            fullScreenObserver = view.browser.webView.observe(\.fullscreenState, options: [.new]) { webView, _ in
                Task { @MainActor in
                    switch webView.fullscreenState {
                    case .enteringFullscreen:
                        onChangingFullscreen(true, webView)
                    case .inFullscreen:
                        break
                    case .exitingFullscreen:
                        onChangingFullscreen(false, webView)
                    case .notInFullscreen:
                        break
                    @unknown default:
                        break
                    }
                }
            }
        }
        
        deinit {
            pageZoomObserver.invalidate()
            fullScreenObserver.invalidate()
        }
    }
}

#elseif os(iOS)
struct WebView: UIViewControllerRepresentable {
    @ObservedObject var browser: BrowserViewModel

    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController(webView: browser.webView)
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) { }
}

final class WebViewController: UIViewController {
    private let webView: WKWebView
    private let pageZoomObserver: Defaults.Observation
    private weak var readerNavigationController: UINavigationController?
    
    init(webView: WKWebView) {
        self.webView = webView
        pageZoomObserver = Defaults.observe(.webViewPageZoom) { change in
            webView.adjustTextSize(pageZoom: change.newValue)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        webView.scrollView.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        webView.scrollView.contentInset = UIEdgeInsets(
            top: view.safeAreaInsets.top,
            left: webView.scrollView.contentInset.left,
            bottom: view.safeAreaInsets.bottom,
            right: webView.scrollView.contentInset.right
        )
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if let controller = parent?.navigationController ?? navigationController {
            // ArkFile currently disables immersive reading. Apply the false
            // value explicitly so state inherited from another controller
            // cannot hide reader chrome.
            let enablesImmersiveReading = !Brand.disableImmersiveReading
            controller.hidesBarsOnSwipe = enablesImmersiveReading
            // Only take ownership of bar restoration when this reader was
            // actually allowed to hide them.
            readerNavigationController = enablesImmersiveReading ? controller : nil
        }
    }

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil, let readerNavigationController {
            readerNavigationController.isNavigationBarHidden = false
            readerNavigationController.isToolbarHidden = false
            readerNavigationController.hidesBarsOnSwipe = false
            self.readerNavigationController = nil
        }
        super.willMove(toParent: parent)
    }
}

extension WKWebView {
    func adjustTextSize(pageZoom: Double? = nil) {
        let pageZoom = pageZoom ?? Defaults[.webViewPageZoom]
        let template = "document.getElementsByTagName('body')[0].style.webkitTextSizeAdjust='%.0f%%'"
        let javascript = String(format: template, pageZoom * 100)
        evaluateJavaScript(javascript, completionHandler: nil)
    }
}
#endif
