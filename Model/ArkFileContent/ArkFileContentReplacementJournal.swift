import Darwin
import Foundation

/// Durable, scoped removal intent. This journal never contains payload backups,
/// authorization tokens or inferred paths. A crash cannot re-adopt old bytes.
struct ArkFileContentReplacementJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, quiescing, removing, recoveryPending, removed
        case downloading, verifying, activating, installed, paused, cancelled, failed
    }
    struct OldFile: Codable, Sendable {
        let entry: ArkFileInstalledContentAccess.CommitEntry
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        init(entry: ArkFileInstalledContentAccess.CommitEntry, identity: ArkFileOpenFileIdentity) {
            self.entry = entry; device = identity.device; inode = identity.inode
            modifiedSeconds = identity.modificationSeconds; modifiedNanoseconds = identity.modificationNanoseconds
        }
        func matches(_ identity: ArkFileOpenFileIdentity) -> Bool {
            device == identity.device && inode == identity.inode && entry.byteCount == identity.byteCount
                && modifiedSeconds == identity.modificationSeconds && modifiedNanoseconds == identity.modificationNanoseconds
        }
    }
    let formatVersion: Int
    let request: ArkFileContentReleaseRequest
    var phase: Phase
    var oldFiles: [OldFile]
    var priorCommit: ArkFileInstalledContentAccess.CommitRecord?
    var removedCommit: ArkFileInstalledContentAccess.CommitRecord?
    var cleanupPendingPaths: [String]
    var completedItemIDs: [String]
    var removeOnly: Bool
    var message: String?
    var updatedAt: Date

    init(request: ArkFileContentReleaseRequest, removeOnly: Bool = false) {
        formatVersion = 1; self.request = request; phase = .prepared; oldFiles = []
        priorCommit = nil; removedCommit = nil; cleanupPendingPaths = []; completedItemIDs = []
        self.removeOnly = removeOnly; message = nil; updatedAt = Date()
    }
    var requiresRecoveryBarrier: Bool { phase == .removing || phase == .recoveryPending }
    var isTerminal: Bool { phase == .installed || phase == .cancelled }
}

enum ArkFileContentReplacementStore {
    static let fileName = ".arkfile-content-replacement.json"
    private struct Envelope: Codable {
        let formatVersion: Int
        let payload: Data
        let sha256: String
    }
    private static let lock = NSRecursiveLock()
    private nonisolated(unsafe) static var barriers: [String: Set<String>] = [:]
    private nonisolated(unsafe) static var loadedRoots = Set<String>()

    static func load(at root: URL) throws -> ArkFileContentReplacementJournal? {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let identity = ArkFileOpenFileIdentity.capture(noFollowURL: url), identity.byteCount < 32 * 1024 * 1024 else {
            throw ArkFileContentReleaseError.invalid("replacement journal file")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.formatVersion == 1,
              ArkFileContentReleaseVerifier.sha256(envelope.payload) == envelope.sha256 else {
            throw ArkFileContentReleaseError.invalid("replacement journal checksum")
        }
        let journal = try JSONDecoder().decode(ArkFileContentReplacementJournal.self, from: envelope.payload)
        guard journal.formatVersion == 1,
              journal.oldFiles.allSatisfy({ ArkFileContentReleaseVerifier.validPath($0.entry.relativePath) }),
              Set(journal.oldFiles.map { $0.entry.relativePath }).count == journal.oldFiles.count,
              Set(journal.cleanupPendingPaths).isSubset(of: Set(journal.oldFiles.map { $0.entry.relativePath })) else {
            throw ArkFileContentReleaseError.invalid("replacement journal identity")
        }
        return journal
    }

    static func save(_ journal: ArkFileContentReplacementJournal, at root: URL) throws {
        try ArkFileDataProtection.createProtectedDirectory(at: root)
        let payload = try JSONEncoder().encode(journal)
        let envelope = Envelope(formatVersion: 1, payload: payload, sha256: ArkFileContentReleaseVerifier.sha256(payload))
        try ArkFileDurableAtomicWriter.write(try JSONEncoder().encode(envelope), to: root.appendingPathComponent(fileName))
        installBarrier(journal, at: root)
    }

    /// Called before installed-read bootstrap and again by direct-read paths.
    /// An unreadable journal freezes only this managed root, never user imports.
    static func loadRecoveryBarrier(at root: URL) {
        lock.lock(); defer { lock.unlock() }
        let rootPath = root.standardizedFileURL.path
        guard loadedRoots.insert(rootPath).inserted else { return }
        do { installBarrier(try load(at: root), at: root) }
        catch { barriers[rootPath] = ["*"] }
    }

    static func blocksRead(_ url: URL) -> Bool {
        guard let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot() else { return false }
        return blocksRead(url, at: root)
    }
    static func blocksRead(_ url: URL, at root: URL) -> Bool {
        loadRecoveryBarrier(at: root)
        lock.lock(); defer { lock.unlock() }
        let rootPath = root.standardizedFileURL.path
        guard let paths = barriers[rootPath], !paths.isEmpty else { return false }
        let absolute = url.standardizedFileURL.path
        guard absolute.hasPrefix(rootPath + "/") else { return false }
        let path = String(absolute.dropFirst(rootPath.count + 1)).lowercased()
        return paths.contains("*") || paths.contains(path)
    }

    private static func installBarrier(_ journal: ArkFileContentReplacementJournal?, at root: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = root.standardizedFileURL.path
        loadedRoots.insert(key)
        barriers[key] = journal?.requiresRecoveryBarrier == true
            ? Set(journal!.oldFiles.map { $0.entry.relativePath.lowercased() }) : []
    }

    struct RemovalOperations {
        var afterAuthority: () throws -> Void = {}
        var unlink: (URL) throws -> Void = { url in
            if Darwin.unlink(url.path) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        var synchronizeDirectory: (URL) throws -> Void = { directory in
            let descriptor = Darwin.open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        }
    }

    /// Replays only a journaled authority transition. Never restores a prior
    /// commit after even one unlink; orphan cleanup remains retryable.
    static func finishRemoval(_ journal: inout ArkFileContentReplacementJournal, at root: URL,
                              writer: ArkFileManagedContentWriterToken,
                              operations: RemovalOperations = .init()) throws {
        guard ArkFileManagedContentConcurrencyGate.isActiveWriterReservation(writer),
              journal.requiresRecoveryBarrier,
              let previous = journal.priorCommit, let removed = journal.removedCommit else {
            throw ArkFileContentReleaseError.invalid("removal authority")
        }
        let removedPaths = Set(journal.oldFiles.map { $0.entry.relativePath.lowercased() })
        guard !removedPaths.isEmpty,
              journal.oldFiles.allSatisfy({ previous.payload.entries.contains($0.entry) }),
              removed.payload.entries == previous.payload.entries.filter({ !removedPaths.contains($0.relativePath.lowercased()) }) else {
            throw ArkFileContentReleaseError.invalid("removal journal scope")
        }
        let groups = Set(journal.oldFiles.map { ArkFileContentCompatibilityPlanner.groupID(for: $0.entry.relativePath) })
        guard let mutation = ArkFileManagedContentConcurrencyGate.tryBeginMutation(affectedGroups: groups, writerToken: writer) else {
            throw ArkFileManagedContentDeletionError.contentInUse
        }
        defer { mutation.release() }
        let current = ArkFileInstalledContentAccess.currentCommitRecord(at: root)
        guard current == previous || current == removed else {
            throw ArkFileContentReleaseError.invalid("changed removal authority")
        }
        if current == previous {
            try ArkFileInstalledContentAccess.installCommitRecordDurablyAndReload(removed, at: root)
        }
        try operations.afterAuthority()
        var pending: [String] = []
        for old in journal.oldFiles {
            let url = root.appendingPathComponent(old.entry.relativePath)
            guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
                pending.append(old.entry.relativePath); continue
            }
            if !FileManager.default.fileExists(atPath: url.path) { continue }
            guard let actual = ArkFileOpenFileIdentity.capture(noFollowURL: url), old.matches(actual) else {
                pending.append(old.entry.relativePath); continue
            }
            do { try operations.unlink(url) }
            catch { pending.append(old.entry.relativePath) }
        }
        // Directory fsync makes unlink durability explicit before the journal
        // says removed. Replaying a missing file remains idempotent.
        for directory in Set(journal.oldFiles.map { root.appendingPathComponent($0.entry.relativePath).deletingLastPathComponent() }) {
            try operations.synchronizeDirectory(directory)
        }
        journal.cleanupPendingPaths = pending
        journal.phase = pending.isEmpty ? .removed : .recoveryPending
        journal.updatedAt = Date()
        try save(journal, at: root)
        ArkFileInstalledContentAccess.reloadAfterContentCommit()
        if !pending.isEmpty { throw ArkFileContentReleaseError.invalid("Old file cleanup must finish before downloading.") }
    }
}
