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

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

/// Drives the pack download Live Activity from installer state changes.
/// Starts when a download begins, throttles progress updates, and ends with a
/// success or paused card so the Lock Screen never shows a stale download.
@MainActor
final class ArkFileEssentialsLiveActivityController {
    static let shared = ArkFileEssentialsLiveActivityController()

    private static let minimumUpdateInterval: TimeInterval = 2

    private var activity: Activity<ArkFileEssentialsDownloadActivityAttributes>?
    private var lastUpdatedAt = Date.distantPast

    /// Activity is not Sendable; this box carries it into update/end tasks
    /// without tripping strict-concurrency checks. ActivityKit's async calls
    /// are themselves thread-safe.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<ArkFileEssentialsDownloadActivityAttributes>
    }

    private init() {}

    func update(with state: ArkFileContentInstallState) {
        switch state.phase {
        case .downloading, .verifying, .installing:
            push(contentState(from: state, finished: false, paused: false))
        case .installed:
            end(
                contentState(from: state, finished: true, paused: false),
                dismissalDelay: 5 * 60
            )
        case .failed:
            end(
                contentState(from: state, finished: false, paused: true),
                dismissalDelay: 60 * 60
            )
        case .idle:
            endAll()
        case .purchasing, .readyToDownload, .preparing:
            break
        }
    }

    private func contentState(
        from state: ArkFileContentInstallState,
        finished: Bool,
        paused: Bool
    ) -> ArkFileEssentialsDownloadActivityAttributes.ContentState {
        ArkFileEssentialsDownloadActivityAttributes.ContentState(
            packName: ArkFileContentPackDisplayName.name(for: state.tier),
            completedBytes: state.completedBytes,
            totalBytes: state.totalBytes,
            completedFiles: state.completedFiles ?? 0,
            totalFiles: state.totalFiles ?? 0,
            isFinished: finished,
            isPaused: paused
        )
    }

    private func push(_ content: ArkFileEssentialsDownloadActivityAttributes.ContentState) {
        if let activity {
            let now = Date()
            guard now.timeIntervalSince(lastUpdatedAt) >= Self.minimumUpdateInterval else {
                return
            }
            lastUpdatedAt = now
            let box = ActivityBox(activity: activity)
            Task {
                await box.activity.update(ActivityContent(state: content, staleDate: nil))
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        activity = try? Activity.request(
            attributes: ArkFileEssentialsDownloadActivityAttributes(startedAt: Date()),
            content: ActivityContent(state: content, staleDate: nil)
        )
        lastUpdatedAt = Date()
    }

    private func end(
        _ content: ArkFileEssentialsDownloadActivityAttributes.ContentState,
        dismissalDelay: TimeInterval
    ) {
        guard let activity else {
            endAll()
            return
        }
        self.activity = nil
        let box = ActivityBox(activity: activity)
        Task {
            await box.activity.end(
                ActivityContent(state: content, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(dismissalDelay))
            )
        }
    }

    /// Cleans up any activities left over from a previous process (e.g. the
    /// app was killed mid-download and relaunched with nothing in flight).
    private func endAll() {
        activity = nil
        Task {
            for stale in Activity<ArkFileEssentialsDownloadActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
