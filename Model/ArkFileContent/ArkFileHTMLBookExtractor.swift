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

import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

struct ArkFileHTMLBookEntry: Identifiable, Hashable, Sendable {
    var id: String { url.absoluteString }

    let title: String
    let url: URL
}

private final class ArkFileHTMLBookExtractionLocks: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for key: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key] {
            return existing
        }
        let lock = NSLock()
        locks[key] = lock
        return lock
    }
}

private final class ArkFileHTMLBookExtractionLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private let maximumConcurrentJobs: Int
    private var activeJobs = 0

    init(maximumConcurrentJobs: Int) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
    }

    func acquire(checkpoint: () throws -> Void, pollInterval: TimeInterval) throws {
        condition.lock()
        while activeJobs >= maximumConcurrentJobs {
            _ = condition.wait(until: Date(timeIntervalSinceNow: pollInterval))
            condition.unlock()
            do {
                try checkpoint()
            } catch {
                throw error
            }
            condition.lock()
        }
        activeJobs += 1
        condition.unlock()
    }

    func release() {
        condition.lock()
        activeJobs = max(0, activeJobs - 1)
        condition.broadcast()
        condition.unlock()
    }
}

enum ArkFileHTMLBookArchiveEntryKind: Sendable {
    case file
    case directory
    case symlink
}

struct ArkFileHTMLBookArchiveEntryMetadata: Sendable {
    let path: String
    let kind: ArkFileHTMLBookArchiveEntryKind
    let uncompressedSize: UInt64
}

struct ArkFileHTMLBookArchiveLimits: Sendable {
    /// The largest known production OpenStax archive expands to about 452 MB
    /// across roughly 4,114 entries. These ceilings leave substantial room for
    /// future books while bounding ZIP bombs and pathological directory trees.
    static let production = ArkFileHTMLBookArchiveLimits(
        maximumEntryCount: 20_000,
        maximumTotalUncompressedBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumEntryUncompressedBytes: 1_024 * 1_024 * 1_024
    )

    let maximumEntryCount: Int
    let maximumTotalUncompressedBytes: UInt64
    let maximumEntryUncompressedBytes: UInt64
}

enum ArkFileHTMLBookArchiveError: LocalizedError, Equatable {
    case invalidPath(String)
    case symbolicLink(String)
    case duplicatePath(String)
    case conflictingPath(String)
    case tooManyEntries(maximum: Int)
    case entryTooLarge(path: String, maximumBytes: UInt64)
    case archiveTooLarge(maximumBytes: UInt64)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case sourceChanged
    case extractedSizeMismatch(String)
    case checksumMismatch(String)
    case readUnavailable
    case dataProtectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            "This book archive contains an unsafe file path."
        case .symbolicLink:
            "This book archive contains a symbolic link, which ArkFile does not extract."
        case .duplicatePath, .conflictingPath:
            "This book archive contains conflicting file paths."
        case let .tooManyEntries(maximum):
            "This book archive contains more than \(maximum.formatted()) files."
        case let .entryTooLarge(_, maximumBytes):
            "A file in this book archive is larger than ArkFile's \(Self.formatted(maximumBytes)) safety limit."
        case let .archiveTooLarge(maximumBytes):
            "This book archive expands beyond ArkFile's \(Self.formatted(maximumBytes)) safety limit."
        case let .insufficientStorage(requiredBytes, availableBytes):
            "This book needs \(Self.formatted(UInt64(requiredBytes))) of free space to open, "
                + "but \(Self.formatted(UInt64(max(0, availableBytes)))) is available."
        case .sourceChanged:
            "The book archive changed while ArkFile was opening it. Try again."
        case .extractedSizeMismatch:
            "A file in this book archive did not match its declared size."
        case .checksumMismatch:
            "A file in this book archive failed its integrity check."
        case .readUnavailable:
            "Access to this book changed while ArkFile was opening it."
        case .dataProtectionFailed:
            "ArkFile could not prepare this book for reliable offline access."
        }
    }

    private static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

struct ArkFileHTMLBookServingSnapshot: Sendable {
    struct Member: Codable, Hashable, Sendable {
        let path: String
        let uncompressedSize: UInt64
        let crc32: UInt32
        let sha256: String
    }

    struct OpenedMember: @unchecked Sendable {
        let url: URL
        let handle: FileHandle
        let byteCount: Int64
        let sha256: String
        let fileIdentity: ArkFileOpenFileIdentity
    }

    let rootURL: URL
    let entryURL: URL
    private let membersByKey: [String: Member]

    init(rootURL: URL, entryPath: String, members: [Member]) throws {
        let normalizedEntryPath = try ArkFileHTMLBookExtractor.validatedArchivePath(entryPath)
        let mappedMembers = Dictionary(
            members.map { (ArkFileHTMLBookExtractor.archiveMemberKey($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard mappedMembers.count == members.count,
              let entryMember = mappedMembers[
                ArkFileHTMLBookExtractor.archiveMemberKey(normalizedEntryPath)
              ] else {
            throw ArkFileContentError.invalidResponse
        }
        self.rootURL = rootURL
        self.entryURL = rootURL.appendingPathComponent(entryMember.path).standardizedFileURL
        self.membersByKey = mappedMembers
        guard let openedEntry = openMember(for: entryMember.path) else {
            throw ArkFileContentError.invalidResponse
        }
        try? openedEntry.handle.close()
    }

    func memberURL(for requestedPath: String) -> URL? {
        guard let openedMember = openMember(for: requestedPath) else {
            return nil
        }
        try? openedMember.handle.close()
        return openedMember.url
    }

    func openMember(for requestedPath: String) -> OpenedMember? {
        guard let normalized = try? ArkFileHTMLBookExtractor.validatedArchivePath(requestedPath),
              let member = membersByKey[
                ArkFileHTMLBookExtractor.archiveMemberKey(normalized)
              ],
              member.sha256.count == 64,
              member.sha256.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let candidate = rootURL.appendingPathComponent(member.path).standardizedFileURL
        guard ArkFileHTMLBookExtractor.isContainedForServing(candidate, in: rootURL),
              let opened = ArkFileHTMLBookExtractor.openVerifiedMember(
                  member,
                  rootURL: rootURL,
                  candidateURL: candidate
              ) else {
            return nil
        }
        return opened
    }
}

enum ArkFileHTMLBookExtractor {
    struct DataProtectionOperations: Sendable {
        let protectAndVerifyItem: @Sendable (URL) throws -> Void
        let protectAndVerifyTree: @Sendable (URL) throws -> Void

        static let live = DataProtectionOperations(
            protectAndVerifyItem: {
                try ArkFileHTMLBookExtractor.protectAndVerifyItem(at: $0)
            },
            protectAndVerifyTree: {
                try ArkFileHTMLBookExtractor.protectAndVerifyTree(at: $0)
            }
        )
    }

    private static let maximumTableOfContentsEntries = 300
    private static let extractionLocks = ArkFileHTMLBookExtractionLocks()
    private static let extractionLimiter = ArkFileHTMLBookExtractionLimiter(
        maximumConcurrentJobs: 1
    )
    private static let tableOfContentsCacheVersion = 1
    private static let extractionCacheVersion = 5
    private static let dataProtectionPolicyVersion = 1
    private static let minimumExtractionHeadroomBytes: UInt64 = 64 * 1_024 * 1_024
    private static let extractionBufferSize = 256 * 1_024
    private static let extractionLockPollInterval: TimeInterval = 0.05
    private static let extractionMarkerFileName = ".arkfile-extraction-v5.json"

    private struct ExtractionContinuation {
        let sourceURL: URL
        let accessCheck: @Sendable (URL) -> Bool

        func checkpoint() throws {
            try Task.checkCancellation()
            let hasAccess = accessCheck(sourceURL)
            try Task.checkCancellation()
            guard hasAccess else {
                throw ArkFileHTMLBookArchiveError.readUnavailable
            }
        }
    }

    private struct PlannedEntry {
        let entry: Entry
        let path: String
    }

    private struct ExtractionPlan {
        let entries: [PlannedEntry]
        let totalUncompressedBytes: UInt64
    }

    private struct ExtractionCacheMarker: Codable {
        let version: Int
        let dataProtectionPolicyVersion: Int
        let sourceIdentity: String
        let archiveEntryCount: Int
        let totalUncompressedBytes: UInt64
        let entryPath: String
        let members: [ArkFileHTMLBookServingSnapshot.Member]
    }

    static func servingSnapshot(
        for item: ArkFileLocalContentItem,
        accessCheck: (@Sendable (URL) -> Bool)? = nil,
        readLeaseProvider: (@Sendable (URL) -> ArkFileAuthoritativeReadLease?)? = nil,
        dataProtection: DataProtectionOperations = .live
    ) throws -> ArkFileHTMLBookServingSnapshot {
        let accessCheck = accessCheck ?? {
            ArkFileEssentialsAccessGate.resolvedURLForReadingSync($0) != nil
        }
        let readLeaseProvider = readLeaseProvider
            ?? ArkFileInstalledContentAccess.acquireReadLease
        let managedReaderToken: ArkFileManagedContentReaderToken?
        if ArkFileInstalledContentAccess.isManaged(item.url) {
            guard let token = ArkFileManagedContentConcurrencyGate
                .tryBeginDirectMediaRead() else {
                throw ArkFileHTMLBookArchiveError.readUnavailable
            }
            managedReaderToken = token
        } else {
            managedReaderToken = nil
        }
        guard let sourceLease = readLeaseProvider(item.url) else {
            managedReaderToken?.release()
            throw ArkFileHTMLBookArchiveError.readUnavailable
        }
        // Keep a hard-link snapshot and reader priority through identity
        // calculation, cache locking, and synchronous ZIP extraction. Release
        // snapshot authority first, while the reader token still prevents a
        // new activation/deletion from replacing the source pathname.
        defer {
            sourceLease.release()
            managedReaderToken?.release()
        }
        let readableURL = sourceLease.url
        let readableItem = ArkFileLocalContentItem(
            name: item.name,
            url: readableURL,
            relativePath: item.relativePath,
            type: item.type,
            category: item.category,
            subcategory: item.subcategory,
            sizeBytes: item.sizeBytes,
            isSampleContent: item.isSampleContent,
            sampleOriginalSubcategory: item.sampleOriginalSubcategory,
            isBundledSampleAsset: item.isBundledSampleAsset
        )
        let continuation = ExtractionContinuation(sourceURL: readableURL, accessCheck: { _ in
            accessCheck(item.url)
        })
        try continuation.checkpoint()
        let expectedSourceIdentity = try sourceIdentity(for: readableURL, continuation: continuation)
        let cacheRoot = try cacheDirectory(for: readableItem, sourceIdentity: expectedSourceIdentity)
        try prepareCacheBooksRoot(dataProtection: dataProtection)
        let extractionLock = extractionLocks.lock(for: cacheRoot.fileSystemPath)
        while !extractionLock.lock(before: Date(timeIntervalSinceNow: extractionLockPollInterval)) {
            try continuation.checkpoint()
        }
        defer { extractionLock.unlock() }
        try continuation.checkpoint()
        // The source can be atomically replaced after the first identity scan
        // but before this cache lock is acquired. Never return the old cache in
        // that window; the next open will derive the replacement's cache key.
        guard try sourceIdentity(for: readableURL, continuation: continuation) == expectedSourceIdentity else {
            throw ArkFileHTMLBookArchiveError.sourceChanged
        }
        // A concurrent caller may have completed while this caller waited.
        if let existingSnapshot = completedServingSnapshot(
            in: cacheRoot,
            expectedSourceIdentity: expectedSourceIdentity,
            dataProtection: dataProtection
        ) {
            return existingSnapshot
        }
        try extractionLimiter.acquire(
            checkpoint: { try continuation.checkpoint() },
            pollInterval: extractionLockPollInterval
        )
        defer { extractionLimiter.release() }
        try continuation.checkpoint()
        return try servingSnapshotLocked(
            for: readableItem,
            cacheRoot: cacheRoot,
            expectedSourceIdentity: expectedSourceIdentity,
            continuation: continuation,
            dataProtection: dataProtection
        )
    }

    static func entryURL(
        for item: ArkFileLocalContentItem,
        accessCheck: (@Sendable (URL) -> Bool)? = nil,
        readLeaseProvider: (@Sendable (URL) -> ArkFileAuthoritativeReadLease?)? = nil,
        dataProtection: DataProtectionOperations = .live
    ) throws -> URL {
        try servingSnapshot(
            for: item,
            accessCheck: accessCheck,
            readLeaseProvider: readLeaseProvider,
            dataProtection: dataProtection
        ).entryURL
    }

    /// ZIPFoundation extraction is synchronous. Serializing this small setup
    /// section makes concurrent viewer and Local Sharing requests single-flight:
    /// the first caller installs atomically and followers reuse the finished root.
    private static func servingSnapshotLocked(
        for item: ArkFileLocalContentItem,
        cacheRoot: URL,
        expectedSourceIdentity: String,
        continuation: ExtractionContinuation,
        dataProtection: DataProtectionOperations
    ) throws -> ArkFileHTMLBookServingSnapshot {
        try continuation.checkpoint()
        if FileManager.default.fileExists(atPath: cacheRoot.fileSystemPath) {
            try FileManager.default.removeItem(at: cacheRoot)
        }
        let extractionRoot = cacheRoot
            .deletingLastPathComponent()
            .appendingPathComponent("\(cacheRoot.lastPathComponent)-\(UUID().uuidString).tmp", isDirectory: true)
        if FileManager.default.fileExists(atPath: extractionRoot.fileSystemPath) {
            try FileManager.default.removeItem(at: extractionRoot)
        }
        defer {
            if FileManager.default.fileExists(atPath: extractionRoot.fileSystemPath) {
                try? FileManager.default.removeItem(at: extractionRoot)
            }
        }
        try continuation.checkpoint()
        let archive = try Archive(url: item.url, accessMode: .read)
        let plan = try extractionPlan(for: archive, continuation: continuation)
        try continuation.checkpoint()
        try ensureAvailableDiskSpace(
            for: plan.totalUncompressedBytes,
            at: cacheRoot.deletingLastPathComponent()
        )
        try createProtectedDirectory(
            at: extractionRoot,
            dataProtection: dataProtection
        )
        var protectedDirectoryPaths = Set([
            normalizedFileSystemPath(extractionRoot)
        ])
        var extractedMembers: [ArkFileHTMLBookServingSnapshot.Member] = []
        extractedMembers.reserveCapacity(plan.entries.count)
        for plannedEntry in plan.entries {
            try continuation.checkpoint()
            let entry = plannedEntry.entry
            let normalizedPath = plannedEntry.path
            let destinationURL = extractionRoot
                .appendingPathComponent(normalizedPath)
                .standardizedFileURL
            guard isStrictlyContained(destinationURL, in: extractionRoot) else {
                throw ArkFileHTMLBookArchiveError.invalidPath(entry.path)
            }
            try createProtectedDirectoryHierarchy(
                for: normalizedPath,
                under: extractionRoot,
                includingLastComponent: entry.type == .directory,
                dataProtection: dataProtection,
                protectedDirectoryPaths: &protectedDirectoryPaths
            )
            if entry.type == .directory {
                // The hierarchy helper created and verified this exact
                // directory, including archives that omit parent entries.
            } else {
                do {
                    extractedMembers.append(try extractFile(
                        entry,
                        from: archive,
                        to: destinationURL,
                        normalizedPath: normalizedPath,
                        continuation: continuation,
                        dataProtection: dataProtection
                    ))
                } catch {
                    try? FileManager.default.removeItem(at: destinationURL)
                    Log.ContentPack.error(
                        "Unable to extract HTML book resource \(normalizedPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    throw error
                }
            }
        }
        guard let mainFile = preferredEntryURL(in: extractionRoot),
              let relativeEntryPath = relativePath(from: extractionRoot, to: mainFile) else {
            throw ArkFileContentError.invalidResponse
        }
        try continuation.checkpoint()
        guard try sourceIdentity(for: item.url, continuation: continuation) == expectedSourceIdentity else {
            throw ArkFileHTMLBookArchiveError.sourceChanged
        }
        try persistExtractionMarker(
            ExtractionCacheMarker(
                version: extractionCacheVersion,
                dataProtectionPolicyVersion: dataProtectionPolicyVersion,
                sourceIdentity: expectedSourceIdentity,
                archiveEntryCount: plan.entries.count,
                totalUncompressedBytes: plan.totalUncompressedBytes,
                entryPath: relativeEntryPath,
                members: extractedMembers.sorted {
                    archivePathKey($0.path) < archivePathKey($1.path)
                }
            ),
            in: extractionRoot,
            dataProtection: dataProtection
        )
        try dataProtection.protectAndVerifyTree(extractionRoot)
        try continuation.checkpoint()
        do {
            try FileManager.default.moveItem(at: extractionRoot, to: cacheRoot)
            try dataProtection.protectAndVerifyTree(cacheRoot)
            try continuation.checkpoint()
        } catch {
            if FileManager.default.fileExists(atPath: cacheRoot.fileSystemPath) {
                try? FileManager.default.removeItem(at: cacheRoot)
            }
            throw error
        }
        return try ArkFileHTMLBookServingSnapshot(
            rootURL: cacheRoot,
            entryPath: relativeEntryPath,
            members: extractedMembers
        )
    }

    static func extractedRootURL(for item: ArkFileLocalContentItem) throws -> URL {
        try servingSnapshot(for: item).rootURL
    }

    static func tableOfContents(
        for item: ArkFileLocalContentItem,
        dataProtection: DataProtectionOperations = .live
    ) throws -> [ArkFileHTMLBookEntry] {
        let entryURL = try entryURL(for: item, dataProtection: dataProtection)
        let root = try extractedRootURL(containing: entryURL)
        if let cached = cachedTableOfContents(in: root) {
            return cached
        }
        let entries = tableOfContents(in: root, fallbackTitle: item.name, entryURL: entryURL)
        persistTableOfContents(
            entries,
            in: root,
            dataProtection: dataProtection
        )
        return entries
    }

    /// How many distinct chapter files the entry document must link before
    /// its anchors are trusted as the de-facto table of contents.
    static let minimumEntryDocumentTOCTargets = 3

    static func tableOfContents(
        in root: URL,
        fallbackTitle: String,
        entryURL: URL? = nil
    ) -> [ArkFileHTMLBookEntry] {
        let htmlFiles = htmlFiles(in: root)
        let effectiveEntryURL = entryURL ?? preferredEntryURL(in: root)
        var sortedFiles = htmlFiles.sorted { lhs, rhs in
            lhs.fileSystemPath.localizedStandardCompare(rhs.fileSystemPath) == .orderedAscending
        }
        // Scan the entry document first so its titles win de-duplication:
        // chapter files often sort before index.html, and their inline
        // cross-references ("[link]", "third exam example") must not shadow
        // the real chapter titles.
        if let effectiveEntryURL,
           let index = sortedFiles.firstIndex(where: {
               $0.standardizedFileURL.fileSystemPath == effectiveEntryURL.standardizedFileURL.fileSystemPath
           }) {
            let entryFile = sortedFiles.remove(at: index)
            sortedFiles.insert(entryFile, at: 0)
        }
        let fileEntries = sortedFiles.map { ArkFileHTMLBookEntry(title: displayTitle(for: $0), url: $0) }
        let linkResult = tableOfContentsLinks(in: sortedFiles, root: root)
        if linkResult.usedStructuredContainer, !linkResult.entries.isEmpty {
            return linkResult.entries
        }
        // Real OpenStax exports carry no <nav>/toc markup at all — but their
        // index.html is a plain list of chapter links in reading order. When
        // the entry document links enough distinct files, treat it as the
        // book's table of contents instead of scanning every chapter's
        // inline anchors.
        if let entryDocumentEntries = entryDocumentTableOfContents(
            entryURL: effectiveEntryURL,
            root: root
        ) {
            return entryDocumentEntries
        }
        if !linkResult.entries.isEmpty {
            return linkResult.entries
        }
        let headingEntries = tableOfContentsHeadings(in: sortedFiles)
        if !headingEntries.isEmpty {
            return headingEntries
        }
        if !fileEntries.isEmpty {
            return Array(fileEntries.prefix(maximumTableOfContentsEntries))
        }
        let fallbackURL = entryURL ?? preferredEntryURL(in: root) ?? root
        return [ArkFileHTMLBookEntry(title: fallbackTitle, url: fallbackURL)]
    }

    private static func entryDocumentTableOfContents(
        entryURL: URL?,
        root: URL
    ) -> [ArkFileHTMLBookEntry]? {
        guard let entryURL,
              let html = htmlString(from: entryURL) else {
            return nil
        }
        let entries = tableOfContentsEntries(
            from: htmlAnchorLinks(in: html, sourceURL: entryURL),
            root: root
        )
        let distinctTargets = Set(entries.map { tableOfContentsFileKey(for: $0.url) })
        guard distinctTargets.count >= minimumEntryDocumentTOCTargets else {
            return nil
        }
        return entries
    }

    static func bookmarkedURL(
        for item: ArkFileLocalContentItem,
        chapterPath: String?,
        articleURL: URL?
    ) throws -> URL? {
        let entryURL = try entryURL(for: item)
        let root = try extractedRootURL(containing: entryURL)
        // Prefer the exact saved URL first. It can contain an in-document
        // fragment used as a chapter target; rebuilding from chapterPath alone
        // strips that fragment and silently returns readers to the book start.
        if let articleURL,
           articleURL.isFileURL {
            let candidateFile = fileURLWithoutFragment(articleURL).standardizedFileURL
            if isReadableFile(candidateFile, under: root) {
                return articleURL
            }
        }
        if let chapterPath,
           !chapterPath.isEmpty {
            let candidate = root
                .appendingPathComponent(chapterPath)
                .standardizedFileURL
            if isReadableFile(candidate, under: root) {
                return bookmarkURL(candidate, preservingLocationFrom: articleURL)
            }
        }
        return entryURL
    }

    static func bookmarkURL(_ fileURL: URL, preservingLocationFrom articleURL: URL?) -> URL {
        guard fileURL.isFileURL,
              let articleURL,
              articleURL.isFileURL,
              let sourceComponents = URLComponents(url: articleURL, resolvingAgainstBaseURL: false),
              var destinationComponents = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        destinationComponents.percentEncodedQuery = sourceComponents.percentEncodedQuery
        destinationComponents.percentEncodedFragment = sourceComponents.percentEncodedFragment
        return destinationComponents.url ?? fileURL
    }

    static func relativePath(from root: URL, to fileURL: URL) -> String? {
        let rootPath = normalizedFileSystemPath(root)
        let filePath = normalizedFileSystemPath(fileURL)
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func cacheDirectory(
        for item: ArkFileLocalContentItem,
        sourceIdentity: String
    ) throws -> URL {
        let digestInput = "v\(extractionCacheVersion)|\(item.relativePath)|\(sourceIdentity)"
        let digest = SHA256.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
        return try cacheBooksRoot()
            .appendingPathComponent(digest, isDirectory: true)
    }

    private static func extractionMarkerURL(in root: URL) -> URL {
        root.appendingPathComponent(extractionMarkerFileName)
    }

    private static func completedServingSnapshot(
        in root: URL,
        expectedSourceIdentity: String,
        dataProtection: DataProtectionOperations
    ) -> ArkFileHTMLBookServingSnapshot? {
        let markerURL = extractionMarkerURL(in: root)
        guard FileManager.default.fileExists(atPath: root.fileSystemPath),
              FileManager.default.fileExists(atPath: markerURL.fileSystemPath)
        else {
            return nil
        }
        do {
            // The marker attests that every descendant was protected and
            // verified before atomic promotion. Warm reads only re-verify
            // these two O(1) authority items; an older marker is rebuilt once
            // below instead of rescanning thousands of book members per
            // resource request.
            try dataProtection.protectAndVerifyItem(root)
            try dataProtection.protectAndVerifyItem(markerURL)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(ExtractionCacheMarker.self, from: data),
              marker.version == extractionCacheVersion,
              marker.dataProtectionPolicyVersion == dataProtectionPolicyVersion,
              marker.sourceIdentity == expectedSourceIdentity,
              marker.archiveEntryCount > 0,
              !marker.members.isEmpty else {
            return nil
        }
        return try? ArkFileHTMLBookServingSnapshot(
            rootURL: root,
            entryPath: marker.entryPath,
            members: marker.members
        )
    }

    private static func persistExtractionMarker(
        _ marker: ExtractionCacheMarker,
        in root: URL,
        dataProtection: DataProtectionOperations
    ) throws {
        let data = try JSONEncoder().encode(marker)
        let markerURL = extractionMarkerURL(in: root)
        do {
            try data.write(to: markerURL, options: .atomic)
            try dataProtection.protectAndVerifyItem(markerURL)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
    }

    private static func cacheBooksRoot() throws -> URL {
        guard let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ArkFileContentError.invalidResponse
        }
        return cachesRoot
            .appendingPathComponent("ArkFile", isDirectory: true)
            .appendingPathComponent("HTMLBooks", isDirectory: true)
    }

    private static func prepareCacheBooksRoot(
        dataProtection: DataProtectionOperations
    ) throws {
        let booksRoot = try cacheBooksRoot()
        try createProtectedDirectory(
            at: booksRoot.deletingLastPathComponent(),
            dataProtection: dataProtection
        )
        try createProtectedDirectory(
            at: booksRoot,
            dataProtection: dataProtection
        )
    }

    private static func createProtectedDirectory(
        at url: URL,
        dataProtection: DataProtectionOperations,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory = ObjCBool(false)
        let existed = fileManager.fileExists(
            atPath: url.fileSystemPath,
            isDirectory: &isDirectory
        )
        if existed {
            guard isDirectory.boolValue else {
                throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                    url.lastPathComponent
                )
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false
                )
            } catch {
                // Another extraction can win creation of the shared cache
                // parent. Accept only an actual directory, then apply and
                // verify the policy below.
                isDirectory = ObjCBool(false)
                guard fileManager.fileExists(
                    atPath: url.fileSystemPath,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    throw error
                }
            }
        }

        // Do not remove a shared directory if protection fails. Another book
        // extraction can populate it between creation and verification.
        // Unique temporary extraction roots are cleaned by their enclosing
        // extraction defer.
        try dataProtection.protectAndVerifyItem(url)
    }

    private static func createProtectedDirectoryHierarchy(
        for normalizedPath: String,
        under root: URL,
        includingLastComponent: Bool,
        dataProtection: DataProtectionOperations,
        protectedDirectoryPaths: inout Set<String>
    ) throws {
        let components = normalizedPath.split(separator: "/")
        let directoryComponents = includingLastComponent
            ? components[...]
            : components.dropLast()
        var directoryURL = root
        for component in directoryComponents {
            directoryURL.appendPathComponent(String(component), isDirectory: true)
            guard isStrictlyContained(directoryURL, in: root) else {
                throw ArkFileHTMLBookArchiveError.invalidPath(normalizedPath)
            }
            let directoryPath = normalizedFileSystemPath(directoryURL)
            guard protectedDirectoryPaths.insert(directoryPath).inserted else {
                continue
            }
            do {
                try createProtectedDirectory(
                    at: directoryURL,
                    dataProtection: dataProtection
                )
            } catch {
                protectedDirectoryPaths.remove(directoryPath)
                throw error
            }
        }
    }

    private static func protectAndVerifyItem(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            var status = Darwin.stat()
            guard url.fileSystemPath.withCString({
                Darwin.lstat($0, &status)
            }) == 0,
            (status.st_mode & S_IFMT) != S_IFLNK else {
                throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                    url.lastPathComponent
                )
            }
            try ArkFileDataProtection.apply(
                toExistingItem: url,
                fileManager: fileManager
            )
            guard try hasDurableDataProtection(
                at: url,
                fileManager: fileManager
            ) else {
                throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                    url.lastPathComponent
                )
            }
        } catch let error as ArkFileHTMLBookArchiveError {
            throw error
        } catch {
            throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                url.lastPathComponent
            )
        }
    }

    private static func protectAndVerifyTree(
        at root: URL,
        fileManager: FileManager = .default
    ) throws {
        try protectAndVerifyItem(at: root, fileManager: fileManager)

        var enumerationFailure: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else {
            throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                root.lastPathComponent
            )
        }

        for case let itemURL as URL in enumerator {
            if enumerationFailure != nil {
                break
            }
            let values = try itemURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                    itemURL.lastPathComponent
                )
            }
            try protectAndVerifyItem(at: itemURL, fileManager: fileManager)
        }
        if enumerationFailure != nil {
            throw ArkFileHTMLBookArchiveError.dataProtectionFailed(
                root.lastPathComponent
            )
        }
    }

    static func hasDurableDataProtection(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try ArkFileDataProtection.hasDurableProtection(
            at: url,
            fileManager: fileManager
        )
    }

    private static func extractedRootURL(containing entryURL: URL) throws -> URL {
        let booksRoot = try cacheBooksRoot()
        guard let relativeEntryPath = relativePath(from: booksRoot, to: entryURL),
              let cacheDirectoryName = relativeEntryPath.split(separator: "/").first,
              !cacheDirectoryName.isEmpty else {
            throw ArkFileContentError.invalidResponse
        }
        return booksRoot.appendingPathComponent(String(cacheDirectoryName), isDirectory: true)
    }

    private struct CachedTableOfContents: Codable {
        let version: Int
        let entries: [CachedEntry]
    }

    private struct CachedEntry: Codable {
        let title: String
        let relativePath: String
        let fragment: String?
    }

    private static func tableOfContentsCacheURL(in root: URL) -> URL {
        root.appendingPathComponent(".arkfile-toc-v1.json")
    }

    private static func cachedTableOfContents(in root: URL) -> [ArkFileHTMLBookEntry]? {
        let cacheURL = tableOfContentsCacheURL(in: root)
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CachedTableOfContents.self, from: data),
              cache.version == tableOfContentsCacheVersion,
              !cache.entries.isEmpty else {
            return nil
        }
        let entries = cache.entries.compactMap { cached -> ArkFileHTMLBookEntry? in
            let fileURL = root.appendingPathComponent(cached.relativePath).standardizedFileURL
            guard isReadableFile(fileURL, under: root) else { return nil }
            var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
            components?.fragment = cached.fragment
            return ArkFileHTMLBookEntry(title: cached.title, url: components?.url ?? fileURL)
        }
        return entries.count == cache.entries.count ? entries : nil
    }

    private static func persistTableOfContents(
        _ entries: [ArkFileHTMLBookEntry],
        in root: URL,
        dataProtection: DataProtectionOperations
    ) {
        let cachedEntries = entries.compactMap { entry -> CachedEntry? in
            let fileURL = fileURLWithoutFragment(entry.url)
            guard let relativePath = relativePath(from: root, to: fileURL), !relativePath.isEmpty else {
                return nil
            }
            return CachedEntry(title: entry.title, relativePath: relativePath, fragment: urlFragment(entry.url))
        }
        guard !cachedEntries.isEmpty,
              let data = try? JSONEncoder().encode(CachedTableOfContents(
                version: tableOfContentsCacheVersion,
                entries: cachedEntries
              )) else {
            return
        }
        let cacheURL = tableOfContentsCacheURL(in: root)
        do {
            try data.write(to: cacheURL, options: .atomic)
            try dataProtection.protectAndVerifyItem(cacheURL)
        } catch {
            // A table-of-contents cache is optional. Never retain newly
            // generated metadata when its durable protection cannot be
            // established; the next open can derive it again.
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    private struct ArchiveValidationState {
        var entryCount = 0
        var totalUncompressedBytes: UInt64 = 0
        var seenKeys: Set<String> = []
        var fileKeys: Set<String> = []
        var pathsRequiredAsDirectories: Set<String> = []

        mutating func append(
            _ metadata: ArkFileHTMLBookArchiveEntryMetadata,
            limits: ArkFileHTMLBookArchiveLimits
        ) throws -> String {
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw ArkFileHTMLBookArchiveError.tooManyEntries(maximum: limits.maximumEntryCount)
            }

            let path = try ArkFileHTMLBookExtractor.validatedArchivePath(metadata.path)
            guard metadata.kind != .symlink else {
                throw ArkFileHTMLBookArchiveError.symbolicLink(path)
            }
            guard metadata.uncompressedSize <= limits.maximumEntryUncompressedBytes else {
                throw ArkFileHTMLBookArchiveError.entryTooLarge(
                    path: path,
                    maximumBytes: limits.maximumEntryUncompressedBytes
                )
            }
            let (newTotal, overflow) = totalUncompressedBytes.addingReportingOverflow(metadata.uncompressedSize)
            guard !overflow, newTotal <= limits.maximumTotalUncompressedBytes else {
                throw ArkFileHTMLBookArchiveError.archiveTooLarge(
                    maximumBytes: limits.maximumTotalUncompressedBytes
                )
            }

            let key = ArkFileHTMLBookExtractor.archivePathKey(path)
            guard !seenKeys.contains(key) else {
                throw ArkFileHTMLBookArchiveError.duplicatePath(path)
            }

            let components = key.split(separator: "/", omittingEmptySubsequences: false)
            var ancestor = ""
            for component in components.dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : "\(ancestor)/\(component)"
                guard !fileKeys.contains(ancestor) else {
                    throw ArkFileHTMLBookArchiveError.conflictingPath(path)
                }
                pathsRequiredAsDirectories.insert(ancestor)
            }
            if metadata.kind == .file, pathsRequiredAsDirectories.contains(key) {
                throw ArkFileHTMLBookArchiveError.conflictingPath(path)
            }

            seenKeys.insert(key)
            if metadata.kind == .file {
                fileKeys.insert(key)
            }
            totalUncompressedBytes = newTotal
            return path
        }
    }

    static func validateArchiveEntries(
        _ entries: [ArkFileHTMLBookArchiveEntryMetadata],
        limits: ArkFileHTMLBookArchiveLimits = .production
    ) throws -> (paths: [String], totalUncompressedBytes: UInt64) {
        var state = ArchiveValidationState()
        let paths = try entries.map { try state.append($0, limits: limits) }
        return (paths, state.totalUncompressedBytes)
    }

    /// Performs the same bounded central-directory and path validation used by
    /// extraction, then streams one representative HTML entry through
    /// ZIPFoundation's CRC check. Activation calls this on the newly renamed
    /// physical archive before its install commit becomes authoritative; it
    /// never expands the book or allocates a second payload-sized copy.
    static func isSemanticallyReadableArchive(at url: URL) -> Bool {
        do {
            let archive = try Archive(url: url, accessMode: .read)
            var state = ArchiveValidationState()
            var representativeEntry: Entry?
            var representativeIsPreferred = false

            for entry in archive {
                let path = try state.append(
                    ArkFileHTMLBookArchiveEntryMetadata(
                        path: entry.path,
                        kind: archiveEntryKind(entry.type),
                        uncompressedSize: entry.uncompressedSize
                    ),
                    limits: .production
                )
                guard entry.type == .file,
                      ["html", "htm", "xhtml", "xht"].contains(
                        (path as NSString).pathExtension.lowercased()
                      ) else {
                    continue
                }
                let name = (path as NSString).lastPathComponent.lowercased()
                let isPreferred = [
                    "index.html", "index.htm", "index.xhtml", "default.html", "default.htm"
                ].contains(name)
                if representativeEntry == nil || (isPreferred && !representativeIsPreferred) {
                    representativeEntry = entry
                    representativeIsPreferred = isPreferred
                }
            }

            guard state.entryCount > 0,
                  let representativeEntry,
                  representativeEntry.uncompressedSize > 0 else {
                return false
            }

            let prefixLimit = 64 * 1_024
            var prefix = Data()
            let checksum = try archive.extract(
                representativeEntry,
                bufferSize: extractionBufferSize,
                skipCRC32: false
            ) { chunk in
                guard prefix.count < prefixLimit else { return }
                prefix.append(chunk.prefix(prefixLimit - prefix.count))
            }
            guard checksum == representativeEntry.checksum,
                  !prefix.isEmpty else {
                return false
            }

            // HTML is intentionally error-tolerant in WebKit, so do not invent
            // a stricter grammar here. Reject only a control-heavy binary
            // impostor; allow fragments and older non-UTF-8 HTML exports.
            if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff]) {
                return String(data: prefix, encoding: .utf16) != nil
            }
            let disallowedControlBytes = prefix.reduce(into: 0) { count, byte in
                if byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d {
                    count += 1
                }
            }
            return disallowedControlBytes <= max(1, prefix.count / 100)
        } catch {
            return false
        }
    }

    private static func extractionPlan(
        for archive: Archive,
        continuation: ExtractionContinuation,
        limits: ArkFileHTMLBookArchiveLimits = .production
    ) throws -> ExtractionPlan {
        var state = ArchiveValidationState()
        var entries: [PlannedEntry] = []
        entries.reserveCapacity(min(4_096, limits.maximumEntryCount))
        for entry in archive {
            try continuation.checkpoint()
            let metadata = ArkFileHTMLBookArchiveEntryMetadata(
                path: entry.path,
                kind: archiveEntryKind(entry.type),
                uncompressedSize: entry.uncompressedSize
            )
            let path = try state.append(metadata, limits: limits)
            entries.append(PlannedEntry(entry: entry, path: path))
        }
        return ExtractionPlan(
            entries: entries,
            totalUncompressedBytes: state.totalUncompressedBytes
        )
    }

    private static func extractFile(
        _ entry: Entry,
        from archive: Archive,
        to destinationURL: URL,
        normalizedPath: String,
        continuation: ExtractionContinuation,
        dataProtection: DataProtectionOperations
    ) throws -> ArkFileHTMLBookServingSnapshot.Member {
        try continuation.checkpoint()
        guard FileManager.default.createFile(
            atPath: destinationURL.fileSystemPath,
            contents: nil
        ) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: destinationURL.fileSystemPath]
            )
        }

        do {
            try dataProtection.protectAndVerifyItem(destinationURL)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            let checksum = try archive.extract(
                entry,
                bufferSize: extractionBufferSize,
                skipCRC32: false
            ) { data in
                try continuation.checkpoint()
                hasher.update(data: data)
                try handle.write(contentsOf: data)
            }
            try continuation.checkpoint()
            guard checksum == entry.checksum else {
                throw ArkFileHTMLBookArchiveError.checksumMismatch(normalizedPath)
            }
            guard fileSize(destinationURL) == Int64(clamping: entry.uncompressedSize) else {
                throw ArkFileHTMLBookArchiveError.extractedSizeMismatch(normalizedPath)
            }
            try handle.synchronize()
            try dataProtection.protectAndVerifyItem(destinationURL)
            return ArkFileHTMLBookServingSnapshot.Member(
                path: normalizedPath,
                uncompressedSize: entry.uncompressedSize,
                crc32: entry.checksum,
                sha256: hasher.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func archiveEntryKind(_ type: Entry.EntryType) -> ArkFileHTMLBookArchiveEntryKind {
        switch type {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        }
    }

    static func validatedArchivePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !(path as NSString).isAbsolutePath else {
            throw ArkFileHTMLBookArchiveError.invalidPath(path)
        }

        let slashNormalized = path.replacingOccurrences(of: "\\", with: "/")
        if slashNormalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
            throw ArkFileHTMLBookArchiveError.invalidPath(path)
        }

        var components = slashNormalized.split(separator: "/", omittingEmptySubsequences: false)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
                      && $0.utf8.count <= 255
              }) else {
            throw ArkFileHTMLBookArchiveError.invalidPath(path)
        }
        if let first = components.first,
           first.lowercased().hasPrefix(".arkfile-") {
            throw ArkFileHTMLBookArchiveError.invalidPath(path)
        }
        return components.joined(separator: "/")
    }

    private static func archivePathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func archiveMemberKey(_ path: String) -> String {
        archivePathKey(path)
    }

    static func isContainedForServing(_ url: URL, in root: URL) -> Bool {
        isStrictlyContained(url, in: root)
    }

    static func openVerifiedMember(
        _ member: ArkFileHTMLBookServingSnapshot.Member,
        rootURL: URL,
        candidateURL: URL
    ) -> ArkFileHTMLBookServingSnapshot.OpenedMember? {
        let rootPath = normalizedFileSystemPath(rootURL)
        let candidatePath = normalizedFileSystemPath(candidateURL)
        guard candidatePath.hasPrefix(rootPath + "/") else { return nil }

        let rootDescriptor = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return nil }
        var directoryDescriptor = rootDescriptor
        var ownsDirectoryDescriptor = false
        defer {
            if ownsDirectoryDescriptor {
                Darwin.close(directoryDescriptor)
            }
            Darwin.close(rootDescriptor)
        }

        let components = member.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let lastComponent = components.last, !lastComponent.isEmpty else {
            return nil
        }
        for component in components.dropLast() {
            let nextDescriptor = String(component).withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return nil }
            if ownsDirectoryDescriptor {
                Darwin.close(directoryDescriptor)
            }
            directoryDescriptor = nextDescriptor
            ownsDirectoryDescriptor = true
        }

        let fileDescriptor = String(lastComponent).withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard fileDescriptor >= 0 else { return nil }
        let handle = FileHandle(
            fileDescriptor: fileDescriptor,
            closeOnDealloc: true
        )
        var shouldClose = true
        defer {
            if shouldClose {
                try? handle.close()
            }
        }

        var before = Darwin.stat()
        guard Darwin.fstat(fileDescriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) == member.uncompressedSize else {
            return nil
        }

        do {
            var hasher = SHA256()
            while let data = try handle.read(upToCount: extractionBufferSize),
                  !data.isEmpty {
                hasher.update(data: data)
            }
            let digest = hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
            var after = Darwin.stat()
            guard digest == member.sha256.lowercased(),
                  Darwin.fstat(fileDescriptor, &after) == 0,
                  let beforeIdentity = ArkFileOpenFileIdentity(
                      status: before
                  ),
                  let afterIdentity = ArkFileOpenFileIdentity(
                      status: after
                  ),
                  afterIdentity == beforeIdentity else {
                return nil
            }
            try handle.seek(toOffset: 0)
            shouldClose = false
            return ArkFileHTMLBookServingSnapshot.OpenedMember(
                url: candidateURL,
                handle: handle,
                byteCount: beforeIdentity.byteCount,
                sha256: digest,
                fileIdentity: afterIdentity
            )
        } catch {
            return nil
        }
    }

    static func requiredAvailableBytes(forExtractionBytes bytes: UInt64) -> UInt64 {
        let proportionalHeadroom = bytes / 10 + (bytes % 10 == 0 ? 0 : 1)
        let headroom = max(minimumExtractionHeadroomBytes, proportionalHeadroom)
        let (required, overflow) = bytes.addingReportingOverflow(headroom)
        return overflow ? .max : required
    }

    private static func ensureAvailableDiskSpace(for bytes: UInt64, at directory: URL) throws {
        let values = try directory.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        let availableBytes: Int64?
        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
           importantCapacity > 0 {
            availableBytes = importantCapacity
        } else if let availableCapacity = values.volumeAvailableCapacity,
                  availableCapacity > 0 {
            availableBytes = Int64(availableCapacity)
        } else {
            // The archive expansion itself remains hard-bounded when a volume
            // cannot report capacity (for example, some test filesystems).
            return
        }
        let requiredBytes = requiredAvailableBytes(forExtractionBytes: bytes)
        guard let availableBytes,
              UInt64(availableBytes) >= requiredBytes else {
            throw ArkFileHTMLBookArchiveError.insufficientStorage(
                requiredBytes: Int64(clamping: requiredBytes),
                availableBytes: availableBytes ?? 0
            )
        }
    }

    private static func isStrictlyContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = normalizedFileSystemPath(root)
        let candidatePath = normalizedFileSystemPath(url)
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private struct SourceFileSnapshot: Equatable {
        let size: UInt64
        let modificationDate: Date?
        let creationDate: Date?
        let fileNumber: UInt64?
        let systemNumber: UInt64?
    }

    private static func sourceIdentity(
        for url: URL,
        continuation: ExtractionContinuation
    ) throws -> String {
        try continuation.checkpoint()
        let before = try sourceFileSnapshot(for: url)
        let archive = try Archive(url: url, accessMode: .read)
        try continuation.checkpoint()

        var hasher = SHA256()
        updateIdentityHasher(&hasher, with: [
            "size:\(before.size)",
            "mtime:\(before.modificationDate?.timeIntervalSinceReferenceDate ?? -1)",
            "ctime:\(before.creationDate?.timeIntervalSinceReferenceDate ?? -1)",
            "file:\(before.fileNumber ?? 0)",
            "system:\(before.systemNumber ?? 0)"
        ].joined(separator: "|"))

        var validationState = ArchiveValidationState()
        for entry in archive {
            try continuation.checkpoint()
            let entryKind = archiveEntryKind(entry.type)
            _ = try validationState.append(
                ArkFileHTMLBookArchiveEntryMetadata(
                    path: entry.path,
                    kind: entryKind,
                    uncompressedSize: entry.uncompressedSize
                ),
                limits: .production
            )
            updateIdentityHasher(&hasher, with: entry.path)
            updateIdentityHasher(&hasher, with: String(entry.type.rawValue))
            updateIdentityHasher(&hasher, with: String(entry.checksum))
            updateIdentityHasher(&hasher, with: String(entry.compressedSize))
            updateIdentityHasher(&hasher, with: String(entry.uncompressedSize))
        }
        updateIdentityHasher(&hasher, with: "entries:\(validationState.entryCount)")

        try continuation.checkpoint()
        guard try sourceFileSnapshot(for: url) == before else {
            throw ArkFileHTMLBookArchiveError.sourceChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateIdentityHasher(_ hasher: inout SHA256, with value: String) {
        let data = Data(value.utf8)
        hasher.update(data: Data("\(data.count):".utf8))
        hasher.update(data: data)
    }

    private static func sourceFileSnapshot(for url: URL) throws -> SourceFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.fileSystemPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw ArkFileContentError.invalidResponse
        }
        return SourceFileSnapshot(
            size: size.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            creationDate: attributes[.creationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value
        )
    }

    private static func htmlFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var htmlFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard isHTMLFile(url) else { continue }
            htmlFiles.append(url)
        }
        return htmlFiles.sorted { lhs, rhs in
            let lhsName = lhs.lastPathComponent.lowercased()
            let rhsName = rhs.lastPathComponent.lowercased()
            if lhsName.hasPrefix("index.") != rhsName.hasPrefix("index.") {
                return lhsName.hasPrefix("index.")
            }
            return lhs.fileSystemPath.localizedCaseInsensitiveCompare(rhs.fileSystemPath) == .orderedAscending
        }
    }

    static func preferredEntryURL(in root: URL) -> URL? {
        for fileName in ["index.html", "index.htm", "index.xhtml", "default.html", "default.htm"] {
            let candidate = root.appendingPathComponent(fileName)
            if isReadableFile(candidate, under: root), fileSize(candidate) > 0 {
                return candidate
            }
        }
        return htmlFiles(in: root).first { url in
            isReadableFile(url, under: root)
                && fileSize(url) > 0
        }
    }

    private static func isReadableFile(_ url: URL, under root: URL) -> Bool {
        guard relativePath(from: root, to: url) != nil else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.fileSystemPath)
    }

    private static func displayTitle(for url: URL) -> String {
        if let html = try? String(contentsOf: url, encoding: .utf8),
           let match = html.range(of: #"<title[^>]*>(.*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let rawTitle = String(html[match])
                .replacingOccurrences(of: #"<\/?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty {
                return rawTitle
            }
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.fileSystemPath),
              let value = attributes[.size] as? NSNumber else {
            return 0
        }
        return value.int64Value
    }

    private static func normalizedFileSystemPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func isHTMLFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.fileSystemPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return isHTMLFilePath(url.lastPathComponent)
    }

    private static func isHTMLFilePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm", "xhtml", "xht":
            return true
        default:
            return false
        }
    }

    private static func tableOfContentsLinks(
        in files: [URL],
        root: URL
    ) -> (entries: [ArkFileHTMLBookEntry], usedStructuredContainer: Bool) {
        var foundStructuredContainer = false
        var structuredLinks: [HTMLAnchorLink] = []
        var fallbackLinks: [HTMLAnchorLink] = []
        for file in files {
            guard let html = htmlString(from: file) else { continue }
            let structuredFragments = structuredTableOfContentsFragments(in: html)
            if !structuredFragments.isEmpty {
                foundStructuredContainer = true
                for fragment in structuredFragments {
                    structuredLinks.append(contentsOf: htmlAnchorLinks(in: fragment, sourceURL: file))
                }
            } else {
                fallbackLinks.append(contentsOf: htmlAnchorLinks(in: html, sourceURL: file))
            }
        }
        if foundStructuredContainer {
            return (tableOfContentsEntries(from: structuredLinks, root: root), true)
        }
        return (tableOfContentsEntries(from: fallbackLinks, root: root), false)
    }

    private static func tableOfContentsHeadings(in files: [URL]) -> [ArkFileHTMLBookEntry] {
        let pattern = #"<h([12])\b([^>]*)>(.*?)</h\1>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        var entries: [ArkFileHTMLBookEntry] = []
        for file in files {
            guard let html = htmlString(from: file) else { continue }
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, options: [], range: nsRange) {
                guard let attributeRange = Range(match.range(at: 2), in: html),
                      let titleRange = Range(match.range(at: 3), in: html) else {
                    continue
                }
                let rawTitle = decodeHTMLEntities(stripHTMLTags(String(html[titleRange])))
                let title = readableAnchorTitle(rawTitle)
                guard !title.isEmpty else { continue }
                let attributes = String(html[attributeRange])
                let targetURL = htmlAttributeValue("id", in: attributes).flatMap { fragmentTargetURL($0, in: file) }
                    ?? file
                entries.append(ArkFileHTMLBookEntry(title: title, url: targetURL))
            }
        }
        return deduplicatedTableOfContentsEntries(entries)
    }

    private static func structuredTableOfContentsFragments(in html: String) -> [String] {
        let tocAttributePattern = #"(?:role\s*=\s*["']doc-toc["']|(?:id|class)\s*=\s*["'][^"']*(?:toc|contents|table-of-contents)[^"']*["'])"#
        let patterns = [
            #"<nav\b(?=[^>]*\#(tocAttributePattern))[^>]*>.*?</nav>"#,
            #"<(?:section|div|ol|ul)\b(?=[^>]*\#(tocAttributePattern))[^>]*>.*?</(?:section|div|ol|ul)>"#
        ]
        return patterns.flatMap { pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                return [String]()
            }
            let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
            return regex.matches(in: html, options: [], range: nsRange).compactMap { match in
                guard let range = Range(match.range(at: 0), in: html) else { return nil }
                return String(html[range])
            }
        }
    }

    private struct HTMLAnchorLink {
        let href: String
        let title: String
        let sourceURL: URL
    }

    private static func tableOfContentsEntries(
        from links: [HTMLAnchorLink],
        root: URL
    ) -> [ArkFileHTMLBookEntry] {
        let entries = links.compactMap { link -> ArkFileHTMLBookEntry? in
            guard let targetURL = localHTMLTargetURL(link.href, from: link.sourceURL, root: root) else {
                return nil
            }
            let title = readableAnchorTitle(link.title)
            guard !title.isEmpty else { return nil }
            return ArkFileHTMLBookEntry(title: title, url: targetURL)
        }
        return deduplicatedTableOfContentsEntries(entries)
    }

    private static func deduplicatedTableOfContentsEntries(
        _ entries: [ArkFileHTMLBookEntry]
    ) -> [ArkFileHTMLBookEntry] {
        let fileKeys = entries.map { tableOfContentsFileKey(for: $0.url) }
        let deduplicateByFile = Set(fileKeys).count > 1
        var result: [ArkFileHTMLBookEntry] = []
        var seenKeys: [String: Int] = [:]
        for entry in entries {
            let key = deduplicateByFile ? tableOfContentsFileKey(for: entry.url) : entry.url.absoluteString.lowercased()
            if let existingIndex = seenKeys[key] {
                let existingURL = result[existingIndex].url
                if urlFragment(existingURL) != nil, urlFragment(entry.url) == nil {
                    result[existingIndex] = entry
                }
                continue
            }
            seenKeys[key] = result.count
            result.append(entry)
            if result.count == maximumTableOfContentsEntries {
                break
            }
        }
        return result
    }

    private static func tableOfContentsFileKey(for url: URL) -> String {
        fileURLWithoutFragment(url).standardizedFileURL.fileSystemPath.lowercased()
    }

    private static func htmlString(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .ascii)
    }

    private static func htmlAnchorLinks(in html: String, sourceURL: URL) -> [HTMLAnchorLink] {
        let pattern = #"<a\b[^>]*\bhref\s*=\s*(['"])(.*?)\1[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: nsRange).compactMap { match in
            guard let hrefRange = Range(match.range(at: 2), in: html),
                  let titleRange = Range(match.range(at: 3), in: html) else {
                return nil
            }
            return HTMLAnchorLink(
                href: decodeHTMLEntities(String(html[hrefRange])),
                title: decodeHTMLEntities(stripHTMLTags(String(html[titleRange]))),
                sourceURL: sourceURL
            )
        }
    }

    private static func localHTMLTargetURL(_ href: String, from sourceURL: URL, root: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://"),
              !trimmed.hasPrefix("mailto:") else {
            return nil
        }
        guard let target = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL else {
            return nil
        }
        let fileURL = fileURLWithoutFragment(target)
        guard isHTMLFile(fileURL),
              isReadableFile(fileURL, under: root) else {
            return nil
        }
        return target
    }

    private static func fileURLWithoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    private static func fragmentTargetURL(_ fragment: String, in file: URL) -> URL? {
        guard var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else {
            return file
        }
        components.fragment = fragment
        return components.url
    }

    private static func urlFragment(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
    }

    private static func htmlAttributeValue(_ name: String, in attributes: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*(['"])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, options: [], range: nsRange),
              let range = Range(match.range(at: 3), in: attributes) else {
            return nil
        }
        return decodeHTMLEntities(String(attributes[range]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readableAnchorTitle(_ title: String) -> String {
        let trimmed = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let visibleCharacterCount = trimmed.filter { !$0.isWhitespace }.count
        guard !trimmed.isEmpty,
              visibleCharacterCount >= 2,
              lowercased != "contents",
              lowercased != "table of contents",
              lowercased != "top",
              lowercased != "[link]",
              trimmed.range(of: #"^\[.*\]$"#, options: .regularExpression) == nil,
              trimmed.range(of: #"^\d+[\.)]?$"#, options: .regularExpression) == nil else {
            return ""
        }
        return trimmed
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let numericPattern = #"&#(x?[0-9A-Fa-f]+);"#
        if let regex = try? NSRegularExpression(pattern: numericPattern) {
            let nsRange = NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
            for match in regex.matches(in: decoded, options: [], range: nsRange).reversed() {
                guard let fullRange = Range(match.range(at: 0), in: decoded),
                      let codeRange = Range(match.range(at: 1), in: decoded) else {
                    continue
                }
                let rawCode = String(decoded[codeRange])
                let radix = rawCode.lowercased().hasPrefix("x") ? 16 : 10
                let digits = radix == 16 ? String(rawCode.dropFirst()) : rawCode
                guard let scalarValue = UInt32(digits, radix: radix),
                      let scalar = UnicodeScalar(scalarValue) else {
                    continue
                }
                decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }
        return decoded
    }
}
