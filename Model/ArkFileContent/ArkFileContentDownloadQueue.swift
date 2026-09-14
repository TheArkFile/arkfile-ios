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

/// Upcoming requests are independent of the immutable request currently being
/// verified and installed. Only explicit user selections enter this queue.
struct ArkFilePendingContentDownload: Codable, Equatable, Sendable {
    let tier: ArkFileContentTier
    var itemKeys: Set<String>
    let includesMapFoundation: Bool

    init(tier: ArkFileContentTier, itemKeys: Set<String>, includesMapFoundation: Bool = false) {
        self.tier = tier
        self.itemKeys = Set(itemKeys.map(ArkFileContentCanonicalPath.key)).filter { !$0.isEmpty }
        self.includesMapFoundation = includesMapFoundation
    }

    var isEmpty: Bool { itemKeys.isEmpty && !includesMapFoundation }
}

struct ArkFileContentDownloadQueue: Codable, Equatable, Sendable {
    var requests: [ArkFilePendingContentDownload] = []
    var isPaused = false

    var itemKeys: Set<String> { Set(requests.flatMap(\.itemKeys)) }
    var count: Int {
        requests.reduce(0) { $0 + $1.itemKeys.count + ($1.includesMapFoundation ? 1 : 0) }
    }

    mutating func append(
        _ request: ArkFilePendingContentDownload,
        activeItemKeys: Set<String>,
        activeIncludesMapFoundation: Bool
    ) {
        let keys = request.itemKeys.subtracting(itemKeys).subtracting(activeItemKeys)
        let foundation = request.includesMapFoundation
            && !activeIncludesMapFoundation
            && !requests.contains(where: \.includesMapFoundation)
        let addition = ArkFilePendingContentDownload(
            tier: request.tier, itemKeys: keys, includesMapFoundation: foundation
        )
        if !addition.isEmpty { requests.append(addition) }
    }

    mutating func removeItem(key: String) {
        let normalized = ArkFileContentCanonicalPath.key(key)
        for index in requests.indices { requests[index].itemKeys.remove(normalized) }
        requests.removeAll(where: \.isEmpty)
    }

    /// A disk-full or protected-data failure must leave the upcoming request
    /// queued until its exact active retry scope has been saved successfully.
    mutating func takeNext(
        persistingActiveRequest persist: (ArkFilePendingContentDownload) -> Bool
    ) -> ArkFilePendingContentDownload? {
        guard !isPaused, let request = requests.first else { return nil }
        guard persist(request) else {
            isPaused = true
            return nil
        }
        requests.removeFirst()
        return request
    }
}

enum ArkFileDownloadQueueItemState: Equatable, Sendable {
    case none
    case queued
    case active
    case paused
}

/// A user-requested review of the current validated manifest. The installer
/// repeats authorization and storage admission when the user confirms.
struct ArkFileContentDownloadPreview: Equatable, Sendable {
    let selectedBytes: Int64
    let mapFoundationBytes: Int64
    let downloadBytes: Int64
}
