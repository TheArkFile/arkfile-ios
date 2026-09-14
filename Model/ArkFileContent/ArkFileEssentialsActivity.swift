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

/// Shared between the app and the widget extension: describes the pack
/// download Live Activity shown on the Lock Screen and in the Dynamic Island.
struct ArkFileEssentialsDownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var packName: String = "Essentials"
        var completedBytes: Int64
        var totalBytes: Int64
        var completedFiles: Int
        var totalFiles: Int
        var isFinished: Bool
        var isPaused: Bool

        var progressFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
    }

    var startedAt: Date
}
#endif
