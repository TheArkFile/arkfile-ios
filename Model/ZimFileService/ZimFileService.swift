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

import Darwin
import Foundation

@globalActor actor ZimActor {
    static let shared = ZimActor()
}

@globalActor actor ParserActor {
    static let shared = ParserActor()
}

/// Cheap identity for the exact authoritative ZIM generation CoreKiwix is
/// bound to. A committed digest distinguishes verified pack revisions without
/// hashing a large archive at open time. Device/inode/timestamps additionally
/// catch atomic same-path/same-size replacement and unmanaged-file changes.
struct ArkFileZimSourceIdentity: Equatable, Sendable {
    let authoritativePath: String
    let committedByteCount: Int64?
    let committedSHA256: String?
    let committedCompatibilityGroupSHA256: String?
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    nonisolated static func capture(
        logicalURL: URL,
        authoritativeURL: URL
    ) -> ArkFileZimSourceIdentity? {
        var fileStatus = Darwin.stat()
        guard Darwin.fstatat(
            AT_FDCWD,
            authoritativeURL.fileSystemPath,
            &fileStatus,
            0
        ) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let committed = ArkFileInstalledContentAccess.committedSourceIdentity(
            for: logicalURL
        )
        return ArkFileZimSourceIdentity(
            authoritativePath: authoritativeURL.standardizedFileURL.fileSystemPath,
            committedByteCount: committed?.artifact?.byteCount,
            committedSHA256: committed?.artifact?.sha256.lowercased(),
            committedCompatibilityGroupSHA256: committed?
                .compatibilityGroupSHA256,
            device: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            byteCount: Int64(fileStatus.st_size),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }

    var signatureComponent: String {
        [
            authoritativePath,
            committedByteCount.map(String.init) ?? "uncommitted",
            committedSHA256 ?? "uncommitted",
            committedCompatibilityGroupSHA256 ?? "uncommitted-group",
            String(device),
            String(inode),
            String(byteCount),
            String(modificationSeconds),
            String(modificationNanoseconds),
            String(statusChangeSeconds),
            String(statusChangeNanoseconds)
        ].joined(separator: ":")
    }
}

enum ArkFileZimRebindDecision: Equatable, Sendable {
    case reuse
    case rebind
    case deferUntilUnpinned

    nonisolated static func make(
        bound: ArkFileZimSourceIdentity?,
        current: ArkFileZimSourceIdentity,
        registeredPath: String?,
        isPinned: Bool
    ) -> ArkFileZimRebindDecision {
        let currentPath = current.authoritativePath
        guard bound != current || registeredPath != currentPath else {
            return .reuse
        }
        return isPinned ? .deferUntilUnpinned : .rebind
    }
}

@ZimActor
struct ZimFileService {
    private struct PendingRegistration {
        let logicalURL: URL
        let readLease: ArkFileAuthoritativeReadLease
        let identity: ArkFileZimSourceIdentity
    }

    static let shared = ZimFileService()
    private static var archivePinCounts: [UUID: Int] = [:]
    private static var archiveReadLeases: [UUID: ArkFileAuthoritativeReadLease] = [:]
    /// Stable logical paths from bookmarks. CoreKiwix may be temporarily
    /// registered to an activation snapshot while the old commit is current.
    private static var logicalFileURLs: [UUID: URL] = [:]
    private static var boundSourceIdentities: [UUID: ArkFileZimSourceIdentity] = [:]
    private static var registrationGenerations: [UUID: UInt64] = [:]
    private static var pendingRegistrations: [UUID: PendingRegistration] = [:]
    private static var pendingClosures: Set<UUID> = []
    private static var spellingSourceIdentities: [UUID: ArkFileZimSourceIdentity] = [:]
    private static var purgeWhenUnpinned = false
    /// Shared ZimFileService instance
    private let instance = ZimService.__sharedInstance()

    /// IDs of current local zim files (not necessaraly with opened Archive)
    private var fileIDs: [UUID] { instance.__getReaderIdentifiers().compactMap({ $0 as? UUID }) }

    /// Validates identity and guarantees that the archive already exists in
    /// the C++ map before returning true. With no pins it may call `open` to
    /// insert; with any pin it is strictly read-only.
    private func prepareArchiveForRead(zimFileID: UUID) -> Bool {
        guard !Self.pendingClosures.contains(zimFileID),
              resolvedFileURL(zimFileID: zimFileID) != nil else {
            return false
        }
        if Self.archivePinCounts.isEmpty {
            return instance.__open(zimFileID) != nil
        }
        // SearchOperation owns an off-actor read of the entire C++ map. Even
        // inserting a different archive can rehash it, so pinned periods may
        // read only archives that were opened before the first pin.
        return instance.__isArchiveOpen(zimFileID)
    }

    private func resolvedFileURL(zimFileID: UUID) -> URL? {
        guard !Self.pendingClosures.contains(zimFileID) else { return nil }
        guard let registeredURL = instance.__getFileURL(zimFileID) else { return nil }
        let logicalURL = Self.logicalFileURLs[zimFileID] ?? registeredURL
        Self.logicalFileURLs[zimFileID] = logicalURL
        // A resolved macOS bookmark does not keep its security scope active
        // between revalidation and a later lazy open. Cover the identity stat;
        // CoreKiwix begins its own long-lived balanced scope when `open` runs
        // immediately after this method returns.
        let didStartSecurityScope = logicalURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                logicalURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: logicalURL) else {
            return nil
        }
        let readableURL = readLease.url
        guard let identity = ArkFileZimSourceIdentity.capture(
            logicalURL: logicalURL,
            authoritativeURL: readableURL
        ) else {
            return nil
        }
        let registeredPath = registeredURL.standardizedFileURL.fileSystemPath
        switch ArkFileZimRebindDecision.make(
            bound: Self.boundSourceIdentities[zimFileID],
            current: identity,
            registeredPath: registeredPath,
            isPinned: !Self.archivePinCounts.isEmpty
        ) {
        case .reuse:
            Self.pendingRegistrations.removeValue(forKey: zimFileID)
            instance.__setLogicalFileURL(logicalURL, forIdentifier: zimFileID)
            retain(readLease: readLease, for: zimFileID)
        case .rebind:
            apply(
                registration: PendingRegistration(
                    logicalURL: logicalURL,
                    readLease: readLease,
                    identity: identity
                ),
                to: zimFileID,
                reopen: false
            )
        case .deferUntilUnpinned:
            // Do not mutate the C++ archive map while SearchOperation is using
            // it off-actor. Keep both leases: the bound lease protects the old
            // snapshot for that search, and this pending lease protects the
            // replacement until the final unpin performs close -> store -> open.
            Self.pendingRegistrations[zimFileID] = PendingRegistration(
                logicalURL: logicalURL,
                readLease: readLease,
                identity: identity
            )
            return nil
        }
        return readableURL
    }

    private func retain(
        readLease: ArkFileAuthoritativeReadLease,
        for zimFileID: UUID
    ) {
        if readLease.keepsSnapshotAlive {
            Self.archiveReadLeases[zimFileID] = readLease
        } else {
            Self.archiveReadLeases.removeValue(forKey: zimFileID)
        }
    }

    private func apply(
        registration: PendingRegistration,
        to zimFileID: UUID,
        reopen: Bool
    ) {
        precondition(Self.archivePinCounts.isEmpty)
        // ZimService.store only changes the URL registration. It must never run
        // over a cached zim::Archive, because that object would keep serving the
        // old inode under the new pathname.
        instance.__closeArchive(zimFileID)
        instance.__store(registration.readLease.url, with: zimFileID)
        instance.__setLogicalFileURL(registration.logicalURL, forIdentifier: zimFileID)
        Self.logicalFileURLs[zimFileID] = registration.logicalURL
        Self.boundSourceIdentities[zimFileID] = registration.identity
        Self.registrationGenerations[zimFileID, default: 0] &+= 1
        Self.pendingRegistrations.removeValue(forKey: zimFileID)
        retain(readLease: registration.readLease, for: zimFileID)
        if reopen {
            _ = instance.__open(zimFileID)
        }
    }

    private func clearRegistrationState(for zimFileID: UUID) {
        Self.archivePinCounts.removeValue(forKey: zimFileID)
        Self.archiveReadLeases.removeValue(forKey: zimFileID)
        Self.logicalFileURLs.removeValue(forKey: zimFileID)
        Self.boundSourceIdentities.removeValue(forKey: zimFileID)
        Self.registrationGenerations.removeValue(forKey: zimFileID)
        Self.pendingRegistrations.removeValue(forKey: zimFileID)
        Self.pendingClosures.remove(zimFileID)
        Self.spellingSourceIdentities.removeValue(forKey: zimFileID)
    }

    private func drainPendingArchiveMutationsIfPossible() {
        guard Self.archivePinCounts.isEmpty else { return }

        let closures = Self.pendingClosures.sorted { $0.uuidString < $1.uuidString }
        Self.pendingClosures.removeAll()
        for zimFileID in closures {
            Self.pendingRegistrations.removeValue(forKey: zimFileID)
            instance.__close(zimFileID)
            clearRegistrationState(for: zimFileID)
        }

        let registrations = Self.pendingRegistrations.sorted {
            $0.key.uuidString < $1.key.uuidString
        }
        for (zimFileID, pending) in registrations
            where !Self.pendingClosures.contains(zimFileID) {
            apply(registration: pending, to: zimFileID, reopen: true)
        }
    }

    // MARK: - Reader Management

    /// Revalidates the zim file url bookmark data (returned)
    /// and stores the zim file url in ZimFileService associated with the zim UUID
    /// - Parameter bookmark: url bookmark data of the zim file to open
    /// - Returns: new url bookmark data if the one used to open the zim file is stale
    @discardableResult
    func revalidate(fileURLBookmark data: Data, for uuid: UUID) throws -> Data? {
        guard !Self.pendingClosures.contains(uuid) else {
            throw ZimFileOpenError.temporarilyInUse
        }
        // resolve url
        var isStale: Bool = false
        #if os(macOS)
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            bookmarkDataIsStale: &isStale
        ) else { throw ZimFileOpenError.missing }
        #else
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else {
            throw ZimFileOpenError.missing
        }
        #endif
        // Resolving a security-scoped bookmark does not itself grant access.
        // Own one balanced window across the authoritative lease lookup,
        // identity stat, CoreKiwix registration, and stale-bookmark refresh.
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: url) else {
            throw ZimFileOpenError.missing
        }
        guard let identity = ArkFileZimSourceIdentity.capture(
            logicalURL: url,
            authoritativeURL: readLease.url
        ) else {
            throw ZimFileOpenError.missing
        }
        let registeredPath = instance.__getFileURL(uuid)?
            .standardizedFileURL.fileSystemPath
        switch ArkFileZimRebindDecision.make(
            bound: Self.boundSourceIdentities[uuid],
            current: identity,
            registeredPath: registeredPath,
            isPinned: !Self.archivePinCounts.isEmpty
        ) {
        case .reuse:
            Self.logicalFileURLs[uuid] = url
            instance.__setLogicalFileURL(url, forIdentifier: uuid)
            retain(readLease: readLease, for: uuid)
        case .rebind:
            apply(
                registration: PendingRegistration(
                    logicalURL: url,
                    readLease: readLease,
                    identity: identity
                ),
                to: uuid,
                reopen: false
            )
        case .deferUntilUnpinned:
            Self.pendingRegistrations[uuid] = PendingRegistration(
                logicalURL: url,
                readLease: readLease,
                identity: identity
            )
            throw ZimFileOpenError.temporarilyInUse
        }
        return isStale ? ZimFileService.getFileURLBookmarkData(for: url) : nil
    }

    func openArchive(zimFileID: UUID) -> UUID? {
        guard prepareArchiveForRead(zimFileID: zimFileID) else { return nil }
        return zimFileID
    }

    @discardableResult
    func pinArchives(zimFileIDs: Set<UUID>) -> Set<UUID> {
        // Resolve/open the whole requested set before publishing the first pin.
        // Once any pin exists no archive-map insertion is permitted, including
        // for a second concurrent search targeting a different archive.
        let pinned = Set(zimFileIDs.filter { prepareArchiveForRead(zimFileID: $0) })
        for fileID in pinned {
            Self.archivePinCounts[fileID, default: 0] += 1
        }
        return pinned
    }

    func unpinArchives(zimFileIDs: Set<UUID>) {
        for fileID in zimFileIDs {
            let remaining = max(0, Self.archivePinCounts[fileID, default: 0] - 1)
            if remaining == 0 {
                Self.archivePinCounts.removeValue(forKey: fileID)
            } else {
                Self.archivePinCounts[fileID] = remaining
            }
        }
        drainPendingArchiveMutationsIfPossible()
        if Self.archivePinCounts.isEmpty, Self.purgeWhenUnpinned {
            Self.purgeWhenUnpinned = false
            purgeUnpinnedArchives()
        }
    }

    /// Releases only CoreKiwix archive objects. URL registrations remain, so
    /// subsequent browser requests reopen lazily. Searches pin their archives
    /// until completion and are never invalidated by a memory warning.
    func purgeUnpinnedArchives() {
        guard Self.archivePinCounts.isEmpty else {
            Self.purgeWhenUnpinned = true
            return
        }
        for fileID in fileIDs where Self.archivePinCounts[fileID] == nil {
            instance.__closeArchive(fileID)
            Self.archiveReadLeases.removeValue(forKey: fileID)
        }
    }
    
    func createSpellingIndex(zimFileID: UUID, cacheDir: URL) {
        guard prepareArchiveForRead(zimFileID: zimFileID) else { return }
        if let identity = Self.boundSourceIdentities[zimFileID],
           Self.spellingSourceIdentities[zimFileID] != identity {
            let baseName = zimFileID.uuidString.lowercased() + ".spellingsdb.v0.1"
            for suffix in ["", ".tmp"] {
                try? FileManager.default.removeItem(
                    at: cacheDir.appendingPathComponent(baseName + suffix)
                )
            }
            Self.spellingSourceIdentities[zimFileID] = identity
        }
        instance.__createSpellingIndex(zimFileID, cachePath: cacheDir.path())
    }

    /// Close a zim file
    /// - Parameter fileID: ID of the zim file to close
    func close(fileID: UUID) {
        guard Self.archivePinCounts.isEmpty else {
            // Closing any key can race SearchOperation's off-actor traversal,
            // even when that search pinned another ID. A close supersedes a
            // queued rebind and drains only after the final global unpin.
            Self.pendingRegistrations.removeValue(forKey: fileID)
            Self.pendingClosures.insert(fileID)
            return
        }
        instance.__close(fileID)
        clearRegistrationState(for: fileID)
    }

    // MARK: - Metadata

    static func getMetaData(url: URL) -> ZimFileMetaStruct? {
        guard let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: url) else {
            return nil
        }
        return metaStruct(from: ZimService.__getMetaData(withFileURL: readLease.url))
    }
    
    nonisolated static func metaStruct(from metadata: ZimFileMetaData?) -> ZimFileMetaStruct? {
        guard let metadata else { return nil }
        return ZimFileMetaStruct(
            fileID: metadata.fileID,
            groupIdentifier: metadata.groupIdentifier,
            title: metadata.title,
            fileDescription: metadata.fileDescription,
            languageCodes: metadata.languageCodes,
            category: metadata.category,
            creationDate: metadata.creationDate,
            size: metadata.size.int64Value,
            articleCount: metadata.articleCount.int64Value,
            mediaCount: metadata.mediaCount.int64Value,
            creator: metadata.creator,
            publisher: metadata.publisher,
            downloadURL: metadata.downloadURL,
            faviconURL: metadata.faviconURL,
            faviconData: metadata.faviconData,
            flavor: metadata.flavor,
            hasDetails: metadata.hasDetails,
            hasPictures: metadata.hasPictures,
            hasVideos: metadata.hasVideos,
            requiresServiceWorkers: metadata.requiresServiceWorkers
        )
    }

    // MARK: - URL System Bookmark

    /// System URL bookmark for the ZIM file itself
    /// "bookmark data that can later be resolved into a URL object for a file
    /// even if the user moves or renames it"
    /// Not to be confused with the article bookmarks
    /// - Parameter url: file system URL
    /// - Returns: data that can later be resolved into a URL object
    static func getFileURLBookmarkData(for url: URL) -> Data? {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        #if os(macOS)
        return try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try? url.bookmarkData(options: .minimalBookmark)
        #endif
    }

    // MARK: - URL Retrieve

    func getFileURL(zimFileID: UUID) -> URL? {
        guard resolvedFileURL(zimFileID: zimFileID) != nil else { return nil }
        return Self.logicalFileURLs[zimFileID] ?? instance.__getFileURL(zimFileID)
    }

    func registeredFileID(for url: URL) -> UUID? {
        guard let fileID = instance.__registeredIdentifier(forFileURL: url),
            prepareArchiveForRead(zimFileID: fileID) else {
            return nil
        }
        return fileID
    }

    func getRedirectedURL(url: URL) -> URL? {
        guard let zimFileID = url.zimFileID,
              prepareArchiveForRead(zimFileID: zimFileID),
              let redirectedPath = instance.__getRedirectedPath(
                zimFileID,
                contentPath: url.contentPath
              ) else {
            return nil
        }
        return Self.redirectedURL(
            sourceURL: url,
            zimFileID: zimFileID,
            redirectedPath: redirectedPath
        )
    }

    nonisolated static func redirectedURL(
        sourceURL: URL,
        zimFileID: UUID,
        redirectedPath: String
    ) -> URL? {
        guard let redirectedURL = URL(
            zimFileID: zimFileID.uuidString,
            contentPath: redirectedPath
        )?.absoluteURL else {
            return nil
        }
        guard let sourceComponents = URLComponents(
                url: sourceURL.absoluteURL,
                resolvingAgainstBaseURL: false
              ),
              var redirectedComponents = URLComponents(
                url: redirectedURL,
                resolvingAgainstBaseURL: false
              ) else {
            return redirectedURL
        }
        redirectedComponents.percentEncodedQuery = sourceComponents.percentEncodedQuery
        redirectedComponents.percentEncodedFragment = sourceComponents.percentEncodedFragment
        return redirectedComponents.url ?? redirectedURL
    }

    func getMainPageURL(zimFileID: UUID? = nil) -> URL? {
        guard let zimFileID = zimFileID ?? fileIDs.randomElement(),
              prepareArchiveForRead(zimFileID: zimFileID),
              let path = instance.__getMainPagePath(zimFileID) else { return nil }
        return URL(zimFileID: zimFileID.uuidString, contentPath: path)
    }

    func getRandomPageURL(zimFileID: UUID? = nil) -> URL? {
        guard let zimFileID = zimFileID ?? fileIDs.randomElement(),
              prepareArchiveForRead(zimFileID: zimFileID),
              let path = instance.__getRandomPagePath(zimFileID) else { return nil }
        return URL(zimFileID: zimFileID.uuidString, contentPath: path)
    }

    // MARK: - URL Response

    func getURLContent(url: URL) -> URLContent? {
        guard let zimFileID = url.zimFileID else { return nil }
        return getURLContent(zimFileID: zimFileID, contentPath: url.contentPath)
    }

    func getURLContent(url: URL, start: UInt, end: UInt) -> URLContent? {
        guard let zimFileID = url.zimFileID else { return nil }
        return getURLContent(zimFileID: zimFileID, contentPath: url.contentPath, start: start, end: end)
    }

    func getContentSize(url: URL) -> NSNumber? {
        guard let zimFileUUID = url.zimFileID,
              prepareArchiveForRead(zimFileID: zimFileUUID) else { return nil }
        return instance.__getContentSize(zimFileUUID, contentPath: url.contentPath)
    }

    func getDirectAccessInfo(url: URL) -> DirectAccessInfo? {
        guard let zimFileUUID = url.zimFileID,
              prepareArchiveForRead(zimFileID: zimFileUUID),
              let directAccess = instance.__getDirectAccess(zimFileUUID, contentPath: url.contentPath),
              let path: String = directAccess["path"] as? String,
              let offset: UInt = directAccess["offset"] as? UInt
        else {
            return nil
        }
        return DirectAccessInfo(
            path: path,
            offset: offset,
            zimFileID: zimFileUUID,
            registrationGeneration: Self.registrationGenerations[zimFileUUID]
        )
    }

    func getContentMetaData(url: URL) -> URLContentMetaData? {
        guard let zimFileUUID = url.zimFileID,
              prepareArchiveForRead(zimFileID: zimFileUUID),
              let content = instance.__getMetaData(zimFileUUID, contentPath: url.contentPath),
              let mime = content["mime"] as? String,
              let size = content["size"] as? UInt,
              let title = content["title"] as? String else { return nil }
        let zimFileModificationDate = content["zimFileDate"] as? Date
        return URLContentMetaData(
            mime: mime,
            size: size,
            zimTitle: title,
            lastModified: zimFileModificationDate,
            zimFileID: zimFileUUID,
            registrationGeneration: Self.registrationGenerations[zimFileUUID]
        )
    }

    func getURLContent(
        zimFileID: UUID,
        contentPath: String,
        start: UInt = 0,
        end: UInt = 0,
        expectedRegistrationGeneration: UInt64? = nil
    ) -> URLContent? {
        guard prepareArchiveForRead(zimFileID: zimFileID),
              expectedRegistrationGeneration == nil
                || expectedRegistrationGeneration == Self.registrationGenerations[zimFileID],
              let content = instance.__getContent(zimFileID, contentPath: contentPath, start: start, end: end),
              let data = content["data"] as? Data,
              let start = content["start"] as? UInt,
              let end = content["end"] as? UInt else { return nil }
        return URLContent(data: data, start: start, end: end)
    }

    func isCurrentRegistration(zimFileID: UUID, generation: UInt64) -> Bool {
        guard prepareArchiveForRead(zimFileID: zimFileID) else { return false }
        return Self.pendingRegistrations[zimFileID] == nil
            && Self.registrationGenerations[zimFileID] == generation
    }

    func registrationGenerationForTesting(zimFileID: UUID) -> UInt64? {
        Self.registrationGenerations[zimFileID]
    }

    func hasPendingRegistrationForTesting(zimFileID: UUID) -> Bool {
        Self.pendingRegistrations[zimFileID] != nil
    }
    
    // MARK: ZIM integrity check
    func checkIntegrity(zimFileID: UUID) -> Bool {
        guard prepareArchiveForRead(zimFileID: zimFileID) else { return false }
        return instance.__checkIntegrity(zimFileID)
    }
}

enum ZimFileOpenError: Error {
    case missing
    case temporarilyInUse
}
