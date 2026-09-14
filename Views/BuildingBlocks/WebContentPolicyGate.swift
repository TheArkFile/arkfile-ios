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

/// Prevents ArkFile's root hierarchy from being constructed until every ZIM
/// WebView can receive its external-resource policy. The native iPhone home is
/// currently coupled to `BrowserViewModel`, so this is intentionally an
/// app-wide startup interlock. Failure never mutates installed content or its
/// authority metadata, and retry remains available.
struct WebContentPolicyGate<Content: View>: View {
    @ObservedObject private var gatekeeper: WebContentPolicyGatekeeper
    private let content: () -> Content

    init(
        gatekeeper: WebContentPolicyGatekeeper,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.gatekeeper = gatekeeper
        self.content = content
    }

    var body: some View {
        Group {
            switch gatekeeper.state {
            case .idle, .preparing:
                ZStack {
                    LogoView()
                    LoadingMessageView(message: LocalString.web_content_policy_preparing)
                    LoadingProgressView()
                }
                .ignoresSafeArea()
            case .ready:
                content()
            case .failed:
                ContentUnavailableView {
                    Label(
                        LocalString.web_content_policy_failure_title,
                        systemImage: "shield.slash"
                    )
                } description: {
                    Text(LocalString.web_content_policy_failure_description)
                } actions: {
                    Button(LocalString.web_content_policy_failure_retry) {
                        Task { @MainActor in
                            await gatekeeper.prepare()
                        }
                    }
                }
            }
        }
        .task {
            await gatekeeper.prepare()
        }
    }
}

struct PendingWebContentOpenURLs {
    private(set) var values: [URL] = []

    mutating func enqueue(_ url: URL) {
        guard !values.contains(url) else {
            return
        }
        values.append(url)
    }

    mutating func drain() -> [URL] {
        defer { values.removeAll() }
        return values
    }
}
