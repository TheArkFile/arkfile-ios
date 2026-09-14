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

import Foundation
import WebKit

enum WebViewConfiguration {
    @MainActor
    static func make(ruleList: WKContentRuleList) -> WKWebViewConfiguration {
        // Return WebKit's concrete configuration. WKWebView copies its input
        // with `init()`, so subclassing it with a policy-requiring initializer
        // would reintroduce an unprotected construction path or trap at runtime.
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            KiwixURLSchemeHandler(),
            forURLScheme: KiwixURLSchemeHandler.ZIMScheme
        )
        #if os(macOS)
        configuration.preferences.isElementFullscreenEnabled = true
        #else
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #endif
        configuration.userContentController = {
            let controller = WKUserContentController()
            controller.add(ruleList)
            if let url = Bundle.main.url(forResource: "injection", withExtension: "js"),
               let javascript = try? String(contentsOf: url) {
                let script = WKUserScript(source: javascript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
                controller.addUserScript(script)
            }
            return controller
        }()
        return configuration
    }
}
