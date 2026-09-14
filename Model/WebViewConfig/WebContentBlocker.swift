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
import Combine
import WebKit

/// Create a block-list for html resources (js, img, css etc)
/// so only zim:// schema type urls are allowed to be loaded
@MainActor
enum WebContentBlocker {

    private static let policyIdentifier = "arkfile-external-resources-v2"
    private struct CompilationAttempt {
        let id: UUID
        let task: Task<Bool, Never>
    }
    private static var compilationAttempt: CompilationAttempt?
    private(set) static var ruleList: WKContentRuleList?

    static let contentRules =
"""
[
    {
        "action": {
            "type": "block"
        },
        "trigger": {
            "url-filter": ".*"
        }
    },
    {
        "action": {
            "type": "ignore-previous-rules"
        },
        "trigger": {
            "url-filter": "^zim://",
            "url-filter-is-case-sensitive": false
        }
    }
]
"""

    /// Compile the policy once and let every caller await the same unstructured
    /// task. The task intentionally outlives a cancelled SwiftUI `.task`, so a
    /// scene transition cannot cancel the app-wide security bootstrap.
    static func compilePolicy() async -> Bool {
        if ruleList != nil {
            return true
        }
        if let compilationAttempt {
            let didCompile = await compilationAttempt.task.value
            clearIfCurrent(compilationAttempt.id)
            return didCompile
        }

        let attemptID = UUID()
        let task = Task { @MainActor in
            await compileNewPolicy()
        }
        compilationAttempt = CompilationAttempt(id: attemptID, task: task)
        let didCompile = await task.value
        clearIfCurrent(attemptID)
        return didCompile
    }

    private static func clearIfCurrent(_ attemptID: UUID) {
        guard compilationAttempt?.id == attemptID else {
            return
        }
        compilationAttempt = nil
    }

    static func requiredRuleList() -> WKContentRuleList {
        guard let ruleList else {
            preconditionFailure("A ZIM WebView cannot be created before its external-resource policy is ready.")
        }
        return ruleList
    }

    private static func compileNewPolicy() async -> Bool {
        guard let blockListStore = WKContentRuleListStore.default() else {
            Log.URLSchemeHandler.error("blockListStore cannot be initialized")
            return false
        }

        do {
            ruleList = try await blockListStore.compileContentRuleList(
                forIdentifier: policyIdentifier,
                encodedContentRuleList: contentRules
            )
            return true
        } catch {
            Log.URLSchemeHandler.error(
                "blockList failed to compile: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

@MainActor
final class WebContentPolicyGatekeeper: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed
    }

    typealias PolicyCompiler = @MainActor () async -> Bool

    @Published private(set) var state: State = .idle
    private let compilePolicy: PolicyCompiler

    var isReady: Bool {
        state == .ready
    }

    init(
        compilePolicy: @escaping PolicyCompiler = {
            await WebContentBlocker.compilePolicy()
        }
    ) {
        self.compilePolicy = compilePolicy
    }

    func prepare() async {
        guard state != .preparing, state != .ready else {
            return
        }
        state = .preparing
        state = await compilePolicy() ? .ready : .failed
    }
}
