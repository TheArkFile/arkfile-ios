// This file is part of Kiwix for iOS & macOS.
// Distributed under the GNU General Public License, version 3 or later.

import Foundation

/// Maps a preserved Saved path only through an installed revision of the same
/// managed item. Availability, file integrity and article existence are still
/// checked by the reader; this mapping never grants read access.
enum ArkFileSavedContentIdentity {
    static func currentPath(
        for savedPath: String,
        installed: [String: ArkFileContentReleaseProvider.InstalledRevision] = ArkFileContentReleaseProvider.shared.snapshot.installed
    ) -> String {
        let key = ArkFileContentReleaseVerifier.canonicalPath(savedPath)
        let matches = installed.values.filter { receipt in
            ArkFileContentReleaseVerifier.canonicalPath(receipt.catalog.relativePath) == key
                || receipt.legacyPaths.contains { ArkFileContentReleaseVerifier.canonicalPath($0) == key }
        }
        // Ambiguous historical aliases fail closed instead of guessing which
        // title a user's note was about.
        guard matches.count == 1, let receipt = matches.first else { return savedPath }
        return receipt.catalog.relativePath
    }

    static func matches(savedPath: String, currentPath: String) -> Bool {
        savedPath == currentPath || Self.currentPath(for: savedPath) == currentPath
    }

    static func item(
        for bookmark: ArkFileContentBookmark,
        in items: [ArkFileLocalContentItem]
    ) -> ArkFileLocalContentItem? {
        if let exact = items.first(where: { $0.relativePath == bookmark.relativePath && $0.type == bookmark.contentType }) {
            return exact
        }
        let path = currentPath(for: bookmark.relativePath)
        return items.first { $0.relativePath == path && $0.type == bookmark.contentType }
    }
}
