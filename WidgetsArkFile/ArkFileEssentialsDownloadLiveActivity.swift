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

import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen / Dynamic Island progress for a pack download, so the
/// multi-gigabyte install stays visible without keeping the app open.
struct ArkFileEssentialsDownloadLiveActivity: Widget {
    private static let brandTeal = Color(red: 0.07, green: 0.25, blue: 0.24)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ArkFileEssentialsDownloadActivityAttributes.self) { context in
            lockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color(red: 0.96, green: 0.95, blue: 0.87))
                .activitySystemActionForegroundColor(Self.brandTeal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusIcon(state: context.state)
                        .font(.title2)
                        .foregroundStyle(Self.brandTeal)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percentText(state: context.state))
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(titleText(state: context.state))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        ProgressView(value: context.state.progressFraction)
                            .tint(Self.brandTeal)
                        Text(detailText(state: context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                statusIcon(state: context.state)
                    .foregroundStyle(Self.brandTeal)
            } compactTrailing: {
                Text(percentText(state: context.state))
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                ProgressView(value: context.state.progressFraction)
                    .progressViewStyle(.circular)
                    .tint(Self.brandTeal)
            }
        }
    }

    private func lockScreenView(
        state: ArkFileEssentialsDownloadActivityAttributes.ContentState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon(state: state)
                    .foregroundStyle(Self.brandTeal)
                Text(titleText(state: state))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(percentText(state: state))
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            ProgressView(value: state.progressFraction)
                .tint(Self.brandTeal)
            Text(detailText(state: state))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusIcon(
        state: ArkFileEssentialsDownloadActivityAttributes.ContentState
    ) -> Image {
        if state.isFinished {
            Image(systemName: "checkmark.circle.fill")
        } else if state.isPaused {
            Image(systemName: "pause.circle.fill")
        } else {
            Image(systemName: "arrow.down.circle.fill")
        }
    }

    private func titleText(
        state: ArkFileEssentialsDownloadActivityAttributes.ContentState
    ) -> String {
        if state.isFinished {
            return "\(state.packName) Installed"
        }
        if state.isPaused {
            return "\(state.packName) Download Paused"
        }
        return "Downloading \(state.packName)"
    }

    private func percentText(
        state: ArkFileEssentialsDownloadActivityAttributes.ContentState
    ) -> String {
        "\(Int((state.progressFraction * 100).rounded()))%"
    }

    private func detailText(
        state: ArkFileEssentialsDownloadActivityAttributes.ContentState
    ) -> String {
        if state.isFinished {
            return "Your offline library is ready."
        }
        let completed = ByteCountFormatter.string(fromByteCount: state.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file)
        let bytes = state.totalBytes > 0 ? "\(completed) of \(total)" : completed
        if state.isPaused {
            return "\(bytes) downloaded. Open ArkFile to continue."
        }
        if state.totalFiles > 0 {
            return "\(bytes) · \(min(state.completedFiles, state.totalFiles)) of \(state.totalFiles) files"
        }
        return bytes
    }
}
