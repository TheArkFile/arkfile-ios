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

import Foundation

/// Remembers the last few things the user was reading — automatically, without
/// requiring a bookmark — so home can offer "Continue Reading" instead of
/// losing their place. Entries reuse the bookmark model so the existing
/// bookmark-opening paths restore positions.
@MainActor
final class ArkFileReadingHistory: ObservableObject {
    static let shared = ArkFileReadingHistory()

    private static let defaultsKey = "arkfile.reading-history.v1"
    private static let maxEntries = 3

    private let defaults: UserDefaults
    private let persistenceKey: String
    private let entryLimit: Int

    @Published private(set) var entries: [ArkFileContentBookmark] = []

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = ArkFileReadingHistory.defaultsKey,
        entryLimit: Int = ArkFileReadingHistory.maxEntries
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.entryLimit = max(1, entryLimit)
        entries = Self.loadPersisted(defaults: defaults, key: persistenceKey)
            .map { $0.normalizedForCurrentSchema() }
    }

    var mostRecent: ArkFileContentBookmark? {
        entries.first
    }

    func record(_ entry: ArkFileContentBookmark) {
        let entry = entry.normalizedForCurrentSchema()
        if let existing = entries.first(where: { $0.relativePath == entry.relativePath }),
           existing.updatedAt > entry.updatedAt {
            return
        }
        let candidates = ([entry] + entries.filter { $0.relativePath != entry.relativePath })
            .enumerated()
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.element.updatedAt != rhs.element.updatedAt {
                return lhs.element.updatedAt > rhs.element.updatedAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        entries = Array(ordered.prefix(entryLimit))
        persist()
    }

    /// Reader progress arrives at a throttled cadence. Ignore repeated page
    /// observations and tiny scroll changes; lifecycle flushes keep the exact
    /// final offset without rewriting an unchanged location.
    func recordProgress(_ entry: ArkFileContentBookmark, force: Bool = false) {
        if let existing = entries.first(where: { $0.relativePath == entry.relativePath }) {
            guard entry.updatedAt >= existing.updatedAt else { return }
            let sameDocumentPosition = existing.articleUrl == entry.articleUrl
                && existing.contentType == entry.contentType
                && existing.pageNumber == entry.pageNumber
                && existing.chapterPath == entry.chapterPath
                && existing.chapterIndex == entry.chapterIndex
                && existing.anchorId == entry.anchorId
            let scrollDelta = abs(existing.scrollTop - entry.scrollTop)
            if entries.first?.relativePath == entry.relativePath,
               sameDocumentPosition && (force ? scrollDelta < 1 : scrollDelta < 32) {
                return
            }
        }
        record(entry)
    }

    /// Records a completed ZIM navigation only after CoreKiwix has delivered
    /// the main frame. The current local-library item and its committed file
    /// facts remain the authority; the browser URL is only the saved location.
    func recordCompletedZIMNavigation(
        url: URL?,
        title: String,
        occurredAt: Date = Date()
    ) {
        guard let url,
              url.isZIMURL,
              let fileID = url.zimFileID,
              let zimFile = try? Database.shared.viewContext.fetch(
                ZimFile.fetchRequest(fileID: fileID)
              ).first,
              let item = ArkFileLocalContentLibrary.shared.localItem(matching: zimFile),
              Self.isCurrentlyAvailable(item) else {
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record(
            ArkFileContentBookmark(
                id: "reading-history-\(item.relativePath.lowercased())",
                schemaVersion: ArkFileContentBookmark.currentSchemaVersion,
                locationKey: ArkFileContentBookmark.locationKey(
                    item: item,
                    articleUrl: url.absoluteString,
                    pageNumber: nil,
                    chapterIndex: nil,
                    anchorId: "",
                    scrollTop: 0
                ),
                articleUrl: url.absoluteString,
                articleTitle: trimmedTitle.isEmpty ? item.displayName : trimmedTitle,
                contentType: .zim,
                relativePath: item.relativePath,
                fileName: item.name,
                pageNumber: nil,
                chapterIndex: nil,
                chapterPath: "",
                anchorId: "",
                anchorLabel: "",
                scrollTop: 0,
                tags: [],
                notes: "",
                createdAt: occurredAt,
                updatedAt: occurredAt,
                status: "valid"
            )
        )
    }

    /// A read-only projection for Continue Reading. Unavailable records remain
    /// persisted so protected-data or activation recovery cannot erase them.
    func availableEntries(in items: [ArkFileLocalContentItem]) -> [ArkFileContentBookmark] {
        entries.filter { entry in
            guard entry.contentType != .map,
                  entry.contentType != .zim || entry.hasUsableZIMArticleRoute,
                  let item = items.first(where: {
                      $0.relativePath == entry.relativePath && $0.type == entry.contentType
                  }) else {
                return false
            }
            return Self.isCurrentlyAvailable(item)
        }
    }

    func remove(relativePath: String) {
        entries.removeAll { $0.relativePath == relativePath }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private static func loadPersisted(defaults: UserDefaults, key: String) -> [ArkFileContentBookmark] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([ArkFileContentBookmark].self, from: data) else {
            return []
        }
        return entries
    }

    private static func isCurrentlyAvailable(_ item: ArkFileLocalContentItem) -> Bool {
        guard ArkFileProtectedDataAvailability.isAvailable,
              let readableURL = ArkFileEssentialsAccessGate.resolvedURLForReadingSync(item.url) else {
            return false
        }
        return ArkFileLocalPathProbe.availability(
            of: readableURL,
            expectedDirectory: false
        ) == .available
    }
}
