// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileSavedZIMBookmarkAlias: Equatable, Sendable {
    let bookmarkID: String
    let resolvedLocationKey: String

    func matches(locationKey: String) -> Bool {
        resolvedLocationKey == locationKey
    }
}

/// Reopens a saved ZIM article against the file ID that currently represents
/// the authoritative local archive. Saved metadata never grants read access.
@MainActor
enum ArkFileSavedZIMResolver {
    struct Destination: Equatable, Sendable {
        let fileID: UUID
        let url: URL
    }

    enum Failure: Error, Equatable, Sendable {
        case malformedRoute
        case wrongContent
        case protectedDataUnavailable
        case activationRecoveryBlocked
        case contentMissing
        case contentTemporarilyUnavailable
        case contentNotAuthoritative
        case registrationFailed
        case archiveOpenFailed
        case articleMissing

        func message(itemName: String) -> String {
            switch self {
            case .protectedDataUnavailable:
                return "Unlock this device, then try opening \(itemName) again."
            case .activationRecoveryBlocked, .contentTemporarilyUnavailable:
                return "\(itemName) is temporarily unavailable while ArkFile protects the last valid local copy. Try again shortly."
            case .contentMissing:
                return "\(itemName) is no longer installed on this device. Its Saved entry has been kept."
            case .contentNotAuthoritative:
                return "\(itemName) does not have a valid completed local installation. Its Saved entry has been kept."
            case .malformedRoute, .wrongContent, .articleMissing:
                return "ArkFile kept this Saved entry, but could not find that article in \(itemName)."
            case .registrationFailed, .archiveOpenFailed:
                return "ArkFile could not open the current local copy of \(itemName). Its Saved entry has been kept."
            }
        }
    }

    static func resolve(
        bookmark: ArkFileContentBookmark,
        item: ArkFileLocalContentItem
    ) async -> Result<Destination, Failure> {
        guard bookmark.contentType == .zim,
              item.type == .zim,
              ArkFileSavedContentIdentity.matches(savedPath: bookmark.relativePath, currentPath: item.relativePath) else {
            return .failure(.wrongContent)
        }
        guard bookmark.hasUsableZIMArticleRoute else {
            return .failure(.malformedRoute)
        }
        guard ArkFileProtectedDataAvailability.isAvailable else {
            return .failure(.protectedDataUnavailable)
        }
        guard let readableURL = ArkFileEssentialsAccessGate.resolvedURLForReading(item.url) else {
            return .failure(.contentNotAuthoritative)
        }
        switch ArkFileLocalPathProbe.availability(of: readableURL, expectedDirectory: false) {
        case .available:
            break
        case .definitivelyMissing:
            return .failure(.contentMissing)
        case .temporarilyUnavailable:
            return .failure(.contentTemporarilyUnavailable)
        }
        guard let fileID = await LibraryOperations.openFileID(url: item.url) else {
            return .failure(.registrationFailed)
        }
        guard await ZimFileService.shared.openArchive(zimFileID: fileID) != nil else {
            return .failure(.archiveOpenFailed)
        }
        let normalized = bookmark.normalizedForCurrentSchema()
        guard let targetURL = normalized.rebasedZIMArticleURL(zimFileID: fileID) else {
            return .failure(.malformedRoute)
        }

        if let redirectedURL = await ZimFileService.shared.getRedirectedURL(url: targetURL) {
            guard await ZimFileService.shared.getContentSize(url: redirectedURL) != nil else {
                return .failure(.articleMissing)
            }
            return .success(Destination(fileID: fileID, url: redirectedURL))
        }

        guard await ZimFileService.shared.getContentSize(url: targetURL) != nil else {
            return .failure(.articleMissing)
        }
        return .success(Destination(fileID: fileID, url: targetURL))
    }
}
