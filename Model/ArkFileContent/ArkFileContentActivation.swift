// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import SQLite3
import zlib

enum ArkFileContentActivationError: LocalizedError {
    case invalidJournal
    case journalMetadataUnavailable
    case pendingForeignTransaction
    case unsafePath(String)
    case crossVolumeActivation
    case backupSnapshotFailed(String)
    case incompleteCompatibilityGroup(String)
    case missingVerifiedReplacement(String)
    case unreadableReplacement(String)
    case contentCurrentlyInUse(String)
    case ambiguousRecovery(String)
    case durableWriteFailed(String)
    case unrecognizedManifestProvenance

    var errorDescription: String? {
        switch self {
        case .invalidJournal:
            "ArkFile found an invalid content activation journal and left every content file untouched."
        case .journalMetadataUnavailable:
            "ArkFile could not inspect content activation metadata yet and left every content file untouched."
        case .pendingForeignTransaction:
            "ArkFile found a different content activation in progress and left every content file untouched."
        case .unsafePath(let path):
            "ArkFile refused an unsafe content activation path: \(path)"
        case .crossVolumeActivation:
            "ArkFile cannot safely activate this download because its staging and content folders are on different storage volumes."
        case .backupSnapshotFailed(let path):
            "ArkFile could not preserve the installed copy of \(path) before updating it. The installed copy is unchanged."
        case .incompleteCompatibilityGroup(let group):
            "ArkFile refused an incomplete update for the \(group) content group. Installed content is unchanged."
        case .missingVerifiedReplacement(let path):
            "ArkFile could not find a verified replacement for \(path). Installed content is unchanged."
        case .unreadableReplacement(let path):
            "ArkFile verified \(path), but could not open it as offline content. ArkFile did not commit the replacement and preserved the last installed version when one existed."
        case .contentCurrentlyInUse:
            "Your offline content is open on this device or being shared nearby. ArkFile kept the verified download and will install it when that activity is finished."
        case .ambiguousRecovery(let path):
            "ArkFile could not safely determine which copy of \(path) is authoritative, so it preserved every copy for repair."
        case .durableWriteFailed(let path):
            "ArkFile could not durably save activation metadata at \(path). Installed content is unchanged."
        case .unrecognizedManifestProvenance:
            "ArkFile refused to activate content whose release manifest is not recognized by this app build. Installed content is unchanged."
        }
    }
}

struct ArkFileContentActivationCandidate: Sendable {
    let relativePath: String
    let manifestEntry: ArkFilePackageManifest.Entry
    let tier: ArkFileContentTier
    /// Nil means the already-active file was verified against `manifestEntry`.
    let stagedURL: URL?
}

final class ArkFileAuthoritativeReadLease: @unchecked Sendable {
    let url: URL
    private let transactionID: UUID?
    private let releaseLock = NSLock()
    private var didRelease = false

    var keepsSnapshotAlive: Bool { transactionID != nil }

    init(url: URL, transactionID: UUID?) {
        self.url = url
        self.transactionID = transactionID
    }

    func release() {
        releaseLock.lock()
        guard !didRelease else {
            releaseLock.unlock()
            return
        }
        didRelease = true
        releaseLock.unlock()
        if let transactionID {
            ArkFileContentActivationCoordinator.releaseReadLease(
                transactionID: transactionID
            )
        }
    }

    deinit {
        release()
    }
}

struct ArkFileContentActivationJournal: Codable, Equatable, Sendable {
    enum RootRole: String, Codable, Sendable {
        case managedContentActive = "managed-content-active-v1"
        case managedContentDownloads = "managed-content-downloads-v1"
    }

    enum Phase: String, Codable, Sendable {
        /// Active paths have not been changed. Backup links may be incomplete.
        case preparing
        /// Every old member has a verified hard-link snapshot. Reads of the
        /// group must resolve to those snapshots until `newCommit` is current.
        case readyToActivate
    }

    struct Operation: Codable, Equatable, Sendable {
        let relativePath: String
        /// Portable path below `managedContentDownloads`. Absolute sandbox
        /// paths are deliberately excluded from the persisted authority.
        let stagedRelativePath: String?
        let backupRelativePath: String?
        let oldEntry: ArkFileInstalledContentAccess.CommitEntry?
        /// Digest of the exact hard-link snapshot made before activation.
        /// Present for every old member once the journal is ready to activate.
        let oldSnapshotSHA256: String?
        let newEntry: ArkFileInstalledContentAccess.CommitEntry
        let newManifestEntry: ArkFilePackageManifest.Entry
    }

    struct Payload: Codable, Equatable, Sendable {
        let formatVersion: Int
        let transactionID: UUID
        let activeRootRole: RootRole
        let downloadRootRole: RootRole
        let groupID: String
        let phase: Phase
        let oldCommit: ArkFileInstalledContentAccess.CommitRecord?
        let newCommit: ArkFileInstalledContentAccess.CommitRecord
        let operations: [Operation]
    }

    let payload: Payload
    let checksum: String

    func readyToActivate(oldSnapshotDigests: [String: String]) throws -> Self {
        let operations = try payload.operations.map { operation in
            let digest: String?
            if operation.oldEntry != nil {
                guard let verifiedDigest = oldSnapshotDigests[operation.relativePath.lowercased()] else {
                    throw ArkFileContentActivationError.backupSnapshotFailed(operation.relativePath)
                }
                digest = verifiedDigest.lowercased()
            } else {
                digest = nil
            }
            return Operation(
                relativePath: operation.relativePath,
                stagedRelativePath: operation.stagedRelativePath,
                backupRelativePath: operation.backupRelativePath,
                oldEntry: operation.oldEntry,
                oldSnapshotSHA256: digest,
                newEntry: operation.newEntry,
                newManifestEntry: operation.newManifestEntry
            )
        }
        let payload = Payload(
            formatVersion: payload.formatVersion,
            transactionID: payload.transactionID,
            activeRootRole: payload.activeRootRole,
            downloadRootRole: payload.downloadRootRole,
            groupID: payload.groupID,
            phase: .readyToActivate,
            oldCommit: payload.oldCommit,
            newCommit: payload.newCommit,
            operations: operations
        )
        return try Self.make(payload: payload)
    }

    static func make(payload: Payload) throws -> Self {
        Self(payload: payload, checksum: try checksum(for: payload))
    }

    var isValid: Bool {
        payload.formatVersion == 1 && hasValidChecksum
    }

    var hasValidChecksum: Bool {
        (try? Self.checksum(for: payload)) == checksum.lowercased()
    }

    private static func checksum(for payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Crash-consistent, storage-bounded activation of one compatibility group.
///
/// The previous group is preserved with same-volume hard links, so this does
/// not allocate a second copy of its payload. While files are replaced in the
/// active namespace, the access layer resolves reads to the all-old snapshot.
/// The checksummed install commit is the only switch to the all-new group.
enum ArkFileContentActivationCoordinator {
    nonisolated static let journalFileName = ".arkfile-activation-journal.json"
    nonisolated static let transactionsDirectoryName = ".arkfile-transactions"
    /// Full-document parsers are intentionally limited before allocation.
    /// Shipped map JSON currently tops out below 8 KiB, leaving three orders
    /// of magnitude of headroom without allowing a manifest to consume
    /// unbounded memory during rollback-critical activation.
    nonisolated static let maximumStructuredDocumentBytes = 8 * 1_024 * 1_024

    struct OverlayResolution: Sendable {
        let url: URL
        let tier: ArkFileContentTier
    }

    private struct OverlayState: Sendable {
        let journal: ArkFileContentActivationJournal
        let activeRoot: URL
    }

    enum JournalPathProbeState: Equatable, Sendable {
        case absent
        case present
        case unavailable
    }

    private enum RecoveryFreezeOrigin: Equatable, Sendable {
        /// A journal pathname or decoded transaction was actually observed.
        /// Its disappearance cannot prove the transaction safe in-process.
        case observedJournal
        /// The journal pathname itself could not be inspected, as can happen
        /// before protected data is available after a device restart.
        case metadataProbeUnavailable
    }

    private static let overlayLock = NSLock()
    private nonisolated(unsafe) static var activeOverlay: OverlayState?
    private nonisolated(unsafe) static var recoveryBlockedJournal: OverlayState?
    private nonisolated(unsafe) static var recoveryBlockedRootPath: String?
    /// A journal that recovery cannot safely resolve freezes every content
    /// writer and deferred cleanup, even when a valid last commit still makes
    /// exact committed paths safe to read.
    private nonisolated(unsafe) static var recoveryFrozenRootPath: String?
    private nonisolated(unsafe) static var recoveryFreezeOriginState: RecoveryFreezeOrigin?
    private nonisolated(unsafe) static var readLeaseCounts: [UUID: Int] = [:]
    private nonisolated(unsafe) static var pendingCleanup: [UUID: (ArkFileContentActivationJournal, URL)] = [:]

    static func activate(
        groupID: String,
        candidates: [ArkFileContentActivationCandidate],
        activeRoot: URL,
        downloadRoot: URL,
        installedTier: ArkFileContentTier,
        trustedManifest: ArkFileTrustedPackageManifest,
        zimSemanticValidator: (URL) -> Bool = {
            ZimService.__isSemanticallyReadable(withFileURL: $0)
        },
        nonZimSemanticValidator: (
            URL,
            String,
            [String: ArkFilePackageManifest.Entry]
        ) -> Bool = {
            ArkFileContentActivationCoordinator
                .replacementContentIsSemanticallyReadable(
                    at: $0,
                    relativePath: $1,
                    verifiedGroupEntries: $2
                )
        }
    ) throws {
        try activateImpl(
            groupID: groupID,
            candidates: candidates,
            activeRoot: activeRoot,
            downloadRoot: downloadRoot,
            installedTier: installedTier,
            trustedManifest: trustedManifest,
            zimSemanticValidator: zimSemanticValidator,
            nonZimSemanticValidator: nonZimSemanticValidator
        )
    }

    /// Test-only compatibility surface for activation mechanics that predate
    /// release-manifest provenance. Production installation must use
    /// `activate(...trustedManifest:)`.
    static func activateForTesting(
        groupID: String,
        candidates: [ArkFileContentActivationCandidate],
        activeRoot: URL,
        downloadRoot: URL,
        installedTier: ArkFileContentTier,
        zimSemanticValidator: (URL) -> Bool = {
            ZimService.__isSemanticallyReadable(withFileURL: $0)
        },
        nonZimSemanticValidator: (
            URL,
            String,
            [String: ArkFilePackageManifest.Entry]
        ) -> Bool = {
            ArkFileContentActivationCoordinator
                .replacementContentIsSemanticallyReadable(
                    at: $0,
                    relativePath: $1,
                    verifiedGroupEntries: $2
                )
        }
    ) throws {
        try activateImpl(
            groupID: groupID,
            candidates: candidates,
            activeRoot: activeRoot,
            downloadRoot: downloadRoot,
            installedTier: installedTier,
            trustedManifest: nil,
            zimSemanticValidator: zimSemanticValidator,
            nonZimSemanticValidator: nonZimSemanticValidator
        )
    }

    private static func activateImpl(
        groupID: String,
        candidates: [ArkFileContentActivationCandidate],
        activeRoot: URL,
        downloadRoot: URL,
        installedTier: ArkFileContentTier,
        trustedManifest: ArkFileTrustedPackageManifest?,
        zimSemanticValidator: (URL) -> Bool,
        nonZimSemanticValidator: (
            URL,
            String,
            [String: ArkFilePackageManifest.Entry]
        ) -> Bool
    ) throws {
        guard !candidates.isEmpty else {
            throw ArkFileContentActivationError.incompleteCompatibilityGroup(groupID)
        }
        let activeRoot = activeRoot.standardizedFileURL
        let downloadRoot = downloadRoot.standardizedFileURL
        try validateExistingDirectoryChain(
            to: activeRoot,
            under: activeRoot,
            allowsMissing: false
        )
        try validateExistingDirectoryChain(
            to: downloadRoot,
            under: downloadRoot,
            allowsMissing: false
        )
        try validateSameVolume(activeRoot, downloadRoot)
        try validateCandidates(
            candidates,
            groupID: groupID,
            activeRoot: activeRoot,
            downloadRoot: downloadRoot
        )
        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else {
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        defer {
            writerToken.release()
            retryDeferredCleanupIfPossible()
        }
        guard !isRecoveryFrozen(at: activeRoot) else {
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        if isAlreadyCommitted(
            groupID: groupID,
            candidates: candidates,
            activeRoot: activeRoot,
            installedTier: installedTier,
            trustedManifest: trustedManifest
        ) {
            return
        }
        if pathExists(journalURL(activeRoot: activeRoot)) {
            throw ArkFileContentActivationError.pendingForeignTransaction
        }

        let oldCommit: ArkFileInstalledContentAccess.CommitRecord?
        switch ArkFileInstalledContentAccess.commitRecordLoadState(at: activeRoot) {
        case .valid(let record):
            oldCommit = record
        case .absent:
            oldCommit = nil
        case .invalid, .unavailable:
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        let oldGroupEntries = (oldCommit?.payload.entries ?? []).filter {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath).rawValue == groupID
        }
        let newPaths = Set(candidates.map { $0.relativePath.lowercased() })
        let silentlyRemovedPaths = oldGroupEntries.filter {
            !newPaths.contains($0.relativePath.lowercased())
        }
        guard silentlyRemovedPaths.isEmpty else {
            throw ArkFileContentActivationError.incompleteCompatibilityGroup(groupID)
        }

        let oldByPath = Dictionary(
            uniqueKeysWithValues: (oldCommit?.payload.entries ?? []).map {
                ($0.relativePath.lowercased(), $0)
            }
        )
        let transactionID = UUID()
        let transactionRoot = transactionRoot(activeRoot: activeRoot, transactionID: transactionID)
        let operations = try candidates.map { candidate -> ArkFileContentActivationJournal.Operation in
            let relativePath = try normalizedRelativePath(candidate.relativePath)
            let destination = activeRoot.appendingPathComponent(relativePath)
            try validateExistingDirectoryChain(
                to: destination.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: true
            )
            let committedOldEntry = oldByPath[relativePath.lowercased()]
            let destinationExists = pathExists(destination)
            let destinationMatchesCandidate = destinationExists
                ? try cryptographicallyMatches(destination, entry: candidate.manifestEntry)
                : false
            if committedOldEntry == nil,
               destinationExists,
               !destinationMatchesCandidate {
                let explicitlyRemovedPaths = Set(
                    oldCommit?.payload.explicitlyRemovedPaths?.map { $0.lowercased() } ?? []
                )
                let isKnownDeletionOrphan = oldCommit?.payload.authorityState
                        == "explicitly-empty"
                    || explicitlyRemovedPaths.contains(relativePath.lowercased())
                guard isKnownDeletionOrphan else {
                    // A valid commit does not claim these bytes, so without a
                    // checksummed deletion tombstone they may be a user import
                    // or legacy install. Never silently replace that ambiguity.
                    throw ArkFileContentActivationError.ambiguousRecovery(relativePath)
                }
            }
            let oldEntry: ArkFileInstalledContentAccess.CommitEntry?
            if let committedOldEntry {
                if pathExists(destination) {
                    guard regularFileSize(destination) == committedOldEntry.byteCount else {
                        // lstat only treats ENOENT as absence. A protected,
                        // permission-denied, non-regular, or otherwise
                        // unreadable destination must abort before any rename.
                        throw ArkFileContentActivationError.backupSnapshotFailed(relativePath)
                    }
                    oldEntry = committedOldEntry
                } else {
                    // A user may have explicitly removed one committed member.
                    // There are no old bytes to snapshot or restore in that
                    // definitive ENOENT case; a verified replacement can repair it.
                    oldEntry = nil
                }
            } else {
                oldEntry = nil
            }
            if let stagedURL = candidate.stagedURL {
                guard try cryptographicallyMatches(
                    stagedURL.standardizedFileURL,
                    entry: candidate.manifestEntry
                ) else {
                    throw ArkFileContentActivationError.missingVerifiedReplacement(relativePath)
                }
            } else if try !cryptographicallyMatches(destination, entry: candidate.manifestEntry) {
                throw ArkFileContentActivationError.missingVerifiedReplacement(relativePath)
            }
            let newEntry = ArkFileInstalledContentAccess.CommitEntry(
                relativePath: relativePath,
                tier: candidate.tier.rawValue,
                byteCount: candidate.manifestEntry.sizeBytes,
                sha256: candidate.manifestEntry.sha256.lowercased(),
                manifestProvenance: trustedManifest.map {
                    .init(
                        manifestID: $0.identity.manifestID,
                        semanticFingerprint:
                            $0.identity.semanticFingerprint.lowercased()
                    )
                }
            )
            // A matching legacy/deletion-orphan destination is already the
            // exact byte we intend to authorize. Do not rename a staged
            // duplicate over it: without an old authority entry there is no
            // snapshot to restore, so a pre-commit rollback could otherwise
            // move the only active copy back to Downloads. Keep staging for a
            // later explicit cleanup; preserving active offline access wins.
            let adoptsExistingUncommittedDestination = committedOldEntry == nil
                && destinationMatchesCandidate
            return ArkFileContentActivationJournal.Operation(
                relativePath: relativePath,
                stagedRelativePath: adoptsExistingUncommittedDestination
                    ? nil
                    : try candidate.stagedURL.map {
                        try Self.relativePath(of: $0.standardizedFileURL, under: downloadRoot)
                    },
                backupRelativePath: oldEntry == nil ? nil : "old/\(relativePath)",
                oldEntry: oldEntry,
                oldSnapshotSHA256: nil,
                newEntry: newEntry,
                newManifestEntry: canonicalManifestEntry(
                    candidate.manifestEntry,
                    relativePath: relativePath
                )
            )
        }
        let replacementEntries = operations.map(\.newEntry)
        let newCommit = try ArkFileInstalledContentAccess.makeMergedCommitRecord(
            previous: oldCommit,
            replacingGroupPaths: Set(oldGroupEntries.map { $0.relativePath.lowercased() }),
            with: replacementEntries,
            installedTier: installedTier,
            trustedProjectionHash: trustedManifest?.projectionHash
        )
        if let trustedManifest,
           !newCommit.payload.entries.allSatisfy({
               guard let provenance = $0.manifestProvenance else { return true }
               return trustedManifest.recognizes(provenance)
           }) {
            throw ArkFileContentActivationError
                .unrecognizedManifestProvenance
        }
        var journal = try ArkFileContentActivationJournal.make(payload: .init(
            formatVersion: 1,
            transactionID: transactionID,
            activeRootRole: .managedContentActive,
            downloadRootRole: .managedContentDownloads,
            groupID: groupID,
            phase: .preparing,
            oldCommit: oldCommit,
            newCommit: newCommit,
            operations: operations
        ))

        do {
            try validateExistingDirectoryChain(
                to: transactionRoot,
                under: activeRoot,
                allowsMissing: true
            )
            try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            try validateExistingDirectoryChain(
                to: transactionRoot,
                under: activeRoot,
                allowsMissing: false
            )
            try writeJournal(journal, activeRoot: activeRoot)
            let oldSnapshotDigests = try createOldSnapshots(
                journal: journal,
                activeRoot: activeRoot
            )
            journal = try journal.readyToActivate(oldSnapshotDigests: oldSnapshotDigests)
            try writeJournal(journal, activeRoot: activeRoot)
        } catch {
            do {
                try recoverPendingActivation(
                    at: activeRoot,
                    downloadRootOverride: downloadRoot,
                    heldWriterToken: writerToken
                )
            } catch {
                installRecoveryBlock(
                    activeRoot: activeRoot,
                    downloadRootOverride: downloadRoot
                )
            }
            throw error
        }

        let compatibilityGroupID = ArkFileContentCompatibilityGroupID(rawValue: groupID)
        guard let pathMutationToken = ArkFileManagedContentConcurrencyGate.tryBeginMutation(
            affectedGroups: [compatibilityGroupID],
            writerToken: writerToken
        ) else {
            do {
                try abandonReadyTransactionBeforeMutation(
                    journal: journal,
                    activeRoot: activeRoot,
                    downloadRoot: downloadRoot
                )
            } catch {
                installRecoveryBlock(
                    activeRoot: activeRoot,
                    downloadRootOverride: downloadRoot
                )
            }
            throw ArkFileContentActivationError.contentCurrentlyInUse(groupID)
        }
        defer { pathMutationToken.release() }
        do {
            // The global writer reservation should make this invariant stable;
            // retain the CAS anyway so a future caller cannot replace paths
            // from a journal planned against a different install authority.
            guard currentAuthorityExactlyMatches(
                oldCommit,
                at: activeRoot
            ) else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            installOverlay(journal, activeRoot: activeRoot)

            try replaceActiveFiles(
                journal: journal,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot
            )
            try verifyNewGroup(journal: journal, activeRoot: activeRoot)
            try validateNewGroupSemantics(
                journal: journal,
                activeRoot: activeRoot,
                zimSemanticValidator: zimSemanticValidator,
                nonZimSemanticValidator: nonZimSemanticValidator
            )
            try syncActiveFiles(journal.payload.operations, root: activeRoot)
            try syncDirectoryTreeForOperations(
                journal.payload.operations,
                root: activeRoot,
                sourceRoot: downloadRoot
            )
            try ArkFileInstalledContentAccess.writeCommitRecordDurably(newCommit, at: activeRoot)
            ArkFileInstalledContentAccess.reloadAfterContentCommit()
            clearOverlay(transactionID: transactionID)
            try finalizeCommittedJournal(journal, activeRoot: activeRoot)
            clearRecoveryBlock(activeRoot: activeRoot)
        } catch {
            clearOverlay(transactionID: transactionID)
            do {
                try recoverPendingActivation(
                    at: activeRoot,
                    downloadRootOverride: downloadRoot,
                    heldMutationToken: pathMutationToken,
                    heldWriterToken: writerToken
                )
            } catch {
                installRecoveryBlock(
                    activeRoot: activeRoot,
                    downloadRootOverride: downloadRoot
                )
            }
            throw error
        }
    }

    /// A no-op is safe only when an authoritative valid commit already contains
    /// the exact group inventory and every candidate was verified in place.
    /// Legacy/adoptable bytes without that authority intentionally return false.
    static func isAlreadyCommitted(
        groupID: String,
        candidates: [ArkFileContentActivationCandidate],
        activeRoot: URL,
        installedTier: ArkFileContentTier,
        trustedManifest: ArkFileTrustedPackageManifest? = nil
    ) -> Bool {
        guard !candidates.isEmpty,
              candidates.allSatisfy({ $0.stagedURL == nil }),
              let current = ArkFileInstalledContentAccess.currentCommitRecord(at: activeRoot),
              current.payload.installedTier == installedTier.rawValue else {
            return false
        }
        let committedGroup = current.payload.entries.filter {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath).rawValue == groupID
        }
        guard committedGroup.count == candidates.count else { return false }
        let byPath = Dictionary(
            uniqueKeysWithValues: committedGroup.map { ($0.relativePath.lowercased(), $0) }
        )
        return candidates.allSatisfy { candidate in
            let path = candidate.relativePath.lowercased()
            guard let entry = byPath[path] else { return false }
            let hasExpectedProvenance: Bool
            if let trustedManifest {
                hasExpectedProvenance =
                    entry.manifestProvenance?.manifestID
                        == trustedManifest.identity.manifestID
                    && entry.manifestProvenance?
                        .semanticFingerprint.lowercased()
                        == trustedManifest.identity.semanticFingerprint
                            .lowercased()
            } else {
                hasExpectedProvenance = true
            }
            return entry.tier == candidate.tier.rawValue
                && entry.byteCount == candidate.manifestEntry.sizeBytes
                && entry.sha256?.lowercased() == candidate.manifestEntry.sha256.lowercased()
                && hasExpectedProvenance
                && (try? cryptographicallyMatches(
                    activeRoot.appendingPathComponent(candidate.relativePath),
                    entry: candidate.manifestEntry
                )) == true
        }
    }

    /// Must run before installed-content access bootstraps or CoreKiwix opens
    /// bookmarks. It is intentionally synchronous and entirely local.
    @discardableResult
    static func recoverPendingActivationIfNeeded() -> Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let activeRoot = support
            .appendingPathComponent("ArkFile", isDirectory: true)
            .appendingPathComponent("Content", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        return recoverPendingActivationIfNeeded(at: activeRoot)
    }

    @discardableResult
    static func recoverPendingActivationIfNeeded(
        at activeRoot: URL,
        downloadRootOverride: URL? = nil,
        journalProbeOverride: JournalPathProbeState? = nil
    ) -> Bool {
        // Foreground recovery must not install a freeze over a legitimate
        // in-process activation/deletion transaction. Owning the same global
        // writer reservation makes the inspect/recover/block decision atomic.
        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else {
            return false
        }
        defer {
            writerToken.release()
            retryDeferredCleanupIfPossible()
        }
        do {
            try recoverPendingActivation(
                at: activeRoot,
                downloadRootOverride: downloadRootOverride,
                heldWriterToken: writerToken,
                journalProbeOverride: journalProbeOverride
            )
            return true
        } catch {
            let freezeOrigin: RecoveryFreezeOrigin
            if let activationError = error as? ArkFileContentActivationError,
               case .journalMetadataUnavailable = activationError {
                freezeOrigin = .metadataProbeUnavailable
            } else {
                freezeOrigin = .observedJournal
            }
            installRecoveryBlock(
                activeRoot: activeRoot,
                downloadRootOverride: downloadRootOverride,
                freezeOrigin: freezeOrigin
            )
            return false
        }
    }

    static func recoverPendingActivation(
        at activeRoot: URL,
        downloadRootOverride: URL? = nil,
        heldMutationToken: ArkFileManagedContentMutationToken? = nil,
        heldWriterToken: ArkFileManagedContentWriterToken? = nil,
        journalProbeOverride: JournalPathProbeState? = nil
    ) throws {
        var acquiredWriterToken: ArkFileManagedContentWriterToken?
        let writerToken: ArkFileManagedContentWriterToken
        if let heldWriterToken {
            guard ArkFileManagedContentConcurrencyGate.isActiveWriterReservation(
                heldWriterToken
            ) else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            writerToken = heldWriterToken
        } else {
            guard let token = ArkFileManagedContentConcurrencyGate
                .tryBeginWriterReservation() else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            acquiredWriterToken = token
            writerToken = token
        }
        defer {
            acquiredWriterToken?.release()
            if acquiredWriterToken != nil {
                retryDeferredCleanupIfPossible()
            }
        }
        let activeRoot = activeRoot.standardizedFileURL
        let journalURL = journalURL(activeRoot: activeRoot)
        let journalProbe = journalProbeOverride ?? journalPathProbe(journalURL)
        switch journalProbe {
        case .unavailable:
            // This is deliberately weaker than observing an unreadable or
            // invalid journal. Foreground recovery may clear only this
            // provisional freeze after metadata becomes definitively absent.
            throw ArkFileContentActivationError.journalMetadataUnavailable
        case .absent:
            // An unresolved journal disappearing outside the recovery protocol
            // is not proof that its transaction is safe. Keep the in-process
            // freeze only if a journal was actually observed. A provisional
            // pre-unlock metadata-probe freeze can be cleared now that absence
            // is definitive.
            if recoveryFreezeOrigin(at: activeRoot) == .observedJournal {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            clearProbeUnavailableRecoveryBlock(activeRoot: activeRoot)
            return
        case .present:
            break
        }
        guard let journal = loadJournal(at: journalURL), journal.isValid else {
            throw ArkFileContentActivationError.invalidJournal
        }
        let downloadRoot = try resolvedDownloadRoot(
            activeRoot: activeRoot,
            override: downloadRootOverride,
            journal: journal
        )
        try validateJournalPaths(
            journal,
            activeRoot: activeRoot,
            downloadRoot: downloadRoot
        )

        if journal.payload.phase == .preparing {
            // A preparing journal is written before any active path is renamed.
            // Its hidden links may be incomplete and are never restoration
            // authority. Recovery only removes that exact hidden transaction or
            // reconstructs an independently verified old commit record.
            let commitState = ArkFileInstalledContentAccess.commitRecordLoadState(at: activeRoot)
            let current: ArkFileInstalledContentAccess.CommitRecord?
            switch commitState {
            case .valid(let record): current = record
            case .absent, .invalid: current = nil
            case .unavailable:
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            let oldAuthorityIsUnchanged: Bool
            switch commitState {
            case .valid:
                oldAuthorityIsUnchanged = commitIdentity(current)
                    == commitIdentity(journal.payload.oldCommit)
            case .absent:
                oldAuthorityIsUnchanged = journal.payload.oldCommit == nil
            case .invalid, .unavailable:
                oldAuthorityIsUnchanged = false
            }
            if oldAuthorityIsUnchanged {
                clearOverlay(transactionID: journal.payload.transactionID)
                try removeTransactionMetadata(journal: journal, activeRoot: activeRoot)
                clearRecoveryBlock(activeRoot: activeRoot)
                return
            }
            if case .invalid = commitState,
               let oldCommit = journal.payload.oldCommit,
               try committedInventoryMatches(oldCommit, activeRoot: activeRoot) {
                try ArkFileInstalledContentAccess.writeCommitRecordDurably(oldCommit, at: activeRoot)
                ArkFileInstalledContentAccess.reloadAfterContentCommit()
                clearOverlay(transactionID: journal.payload.transactionID)
                try removeTransactionMetadata(journal: journal, activeRoot: activeRoot)
                clearRecoveryBlock(activeRoot: activeRoot)
                return
            }
            throw ArkFileContentActivationError.pendingForeignTransaction
        }

        let affectedGroup = ArkFileContentCompatibilityGroupID(
            rawValue: journal.payload.groupID
        )
        var acquiredMutationToken: ArkFileManagedContentMutationToken?
        if let heldMutationToken {
            guard !heldMutationToken.isReleased,
                  heldMutationToken.affectedGroups.contains(affectedGroup) else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
        } else {
            guard let token = ArkFileManagedContentConcurrencyGate.tryBeginMutation(
                affectedGroups: [affectedGroup],
                writerToken: writerToken
            ) else {
                throw ArkFileContentActivationError.contentCurrentlyInUse(
                    journal.payload.groupID
                )
            }
            acquiredMutationToken = token
        }
        defer { acquiredMutationToken?.release() }

        let commitState = ArkFileInstalledContentAccess.commitRecordLoadState(at: activeRoot)
        let current: ArkFileInstalledContentAccess.CommitRecord?
        switch commitState {
        case .valid(let record):
            current = record
        case .absent, .invalid:
            current = nil
        case .unavailable:
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        if case .invalid = commitState {
            if try newGroupCryptographicallyMatches(journal: journal, activeRoot: activeRoot) {
                try ArkFileInstalledContentAccess.writeCommitRecordDurably(
                    journal.payload.newCommit,
                    at: activeRoot
                )
                ArkFileInstalledContentAccess.reloadAfterContentCommit()
                clearOverlay(transactionID: journal.payload.transactionID)
                try finalizeCommittedJournal(journal, activeRoot: activeRoot)
                clearRecoveryBlock(activeRoot: activeRoot)
                return
            }
            guard journal.payload.oldCommit != nil else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
            try rollbackToOldCommit(
                journal: journal,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                allowsDefinitivelyDamagedNewBytes: true,
                rewriteOldCommit: true
            )
            clearOverlay(transactionID: journal.payload.transactionID)
            clearRecoveryBlock(activeRoot: activeRoot)
            return
        }
        if commitIdentity(current) == commitIdentity(journal.payload.newCommit) {
            if try newGroupCryptographicallyMatches(journal: journal, activeRoot: activeRoot) {
                clearOverlay(transactionID: journal.payload.transactionID)
                try finalizeCommittedJournal(journal, activeRoot: activeRoot)
            } else {
                try rollbackToOldCommit(
                    journal: journal,
                    activeRoot: activeRoot,
                    downloadRoot: downloadRoot,
                    allowsDefinitivelyDamagedNewBytes: true,
                    rewriteOldCommit: true
                )
                clearOverlay(transactionID: journal.payload.transactionID)
            }
            clearRecoveryBlock(activeRoot: activeRoot)
            return
        }
        if current == nil {
            try rollbackToOldCommit(
                journal: journal,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                allowsDefinitivelyDamagedNewBytes: false,
                rewriteOldCommit: true
            )
            clearOverlay(transactionID: journal.payload.transactionID)
            clearRecoveryBlock(activeRoot: activeRoot)
            return
        }
        if commitIdentity(current) == commitIdentity(journal.payload.oldCommit) {
            try rollbackToOldCommit(
                journal: journal,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                allowsDefinitivelyDamagedNewBytes: false,
                rewriteOldCommit: false
            )
            clearOverlay(transactionID: journal.payload.transactionID)
            clearRecoveryBlock(activeRoot: activeRoot)
            return
        }
        throw ArkFileContentActivationError.pendingForeignTransaction
    }

    static func overlayResolution(
        for url: URL,
        cachedCommitID: UUID?
    ) -> OverlayResolution? {
        overlayLock.lock()
        let state = activeOverlay ?? recoveryBlockedJournal
        overlayLock.unlock()
        guard let state else { return nil }
        return try? oldAuthorityResolution(
            for: url,
            cachedCommitID: cachedCommitID,
            journal: state.journal,
            activeRoot: state.activeRoot
        )
    }

    static func acquireReadLease(
        for url: URL,
        cachedCommitID: UUID?
    ) -> ArkFileAuthoritativeReadLease? {
        overlayLock.lock()
        let state = activeOverlay ?? recoveryBlockedJournal
        overlayLock.unlock()
        guard let state,
              let resolution = try? oldAuthorityResolution(
                  for: url,
                  cachedCommitID: cachedCommitID,
                  journal: state.journal,
                  activeRoot: state.activeRoot
              ) else { return nil }
        let transactionID = state.journal.payload.transactionID
        let activeRootPath = normalizedFileSystemPath(state.activeRoot)
        // Digesting a large emergency pack must not hold the global overlay
        // mutex. Recheck the exact transaction before publishing the lease so
        // its snapshot cannot be cleaned between verification and retention.
        overlayLock.lock()
        let currentState = activeOverlay ?? recoveryBlockedJournal
        guard currentState?.journal.payload.transactionID == transactionID,
              currentState.map({ normalizedFileSystemPath($0.activeRoot) }) == activeRootPath else {
            overlayLock.unlock()
            return nil
        }
        readLeaseCounts[transactionID, default: 0] += 1
        overlayLock.unlock()
        return ArkFileAuthoritativeReadLease(
            url: resolution.url,
            transactionID: transactionID
        )
    }

    static func releaseReadLease(transactionID: UUID) {
        var shouldRetryCleanup = false
        overlayLock.lock()
        let remaining = max(0, readLeaseCounts[transactionID, default: 0] - 1)
        if remaining == 0 {
            readLeaseCounts.removeValue(forKey: transactionID)
            shouldRetryCleanup = pendingCleanup[transactionID] != nil
        } else {
            readLeaseCounts[transactionID] = remaining
        }
        overlayLock.unlock()
        if shouldRetryCleanup {
            retryDeferredCleanupIfPossible()
        }
    }

    /// Retries journal/snapshot cleanup only while holding the same global
    /// writer reservation used by activation and explicit deletion. It is safe
    /// to call opportunistically; an active writer simply makes this a no-op.
    static func retryDeferredCleanupIfPossible() {
        overlayLock.lock()
        let isRecoveryFrozen = recoveryFrozenRootPath != nil
        overlayLock.unlock()
        guard !isRecoveryFrozen else { return }

        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else { return }
        defer { writerToken.release() }

        // Recovery can become blocked between the optimistic check above and
        // acquiring the writer reservation. Never clean transaction evidence
        // once that freeze is visible.
        overlayLock.lock()
        let becameRecoveryFrozen = recoveryFrozenRootPath != nil
        overlayLock.unlock()
        guard !becameRecoveryFrozen else { return }

        while true {
            let cleanup: (UUID, ArkFileContentActivationJournal, URL)?
            overlayLock.lock()
            if let transactionID = pendingCleanup.keys.first(where: {
                readLeaseCounts[$0, default: 0] == 0
            }), let value = pendingCleanup.removeValue(forKey: transactionID) {
                cleanup = (transactionID, value.0, value.1)
            } else {
                cleanup = nil
            }
            overlayLock.unlock()
            guard let cleanup else { return }
            do {
                try removeTransactionMetadata(
                    journal: cleanup.1,
                    activeRoot: cleanup.2
                )
            } catch {
                overlayLock.lock()
                pendingCleanup[cleanup.0] = (cleanup.1, cleanup.2)
                overlayLock.unlock()
                return
            }
        }
    }

    /// Resolves an exact physical representation of the last committed file.
    /// A ready transaction uses its immutable hard-link snapshot; a preparing
    /// recovery block may use the active file only after matching the digest in
    /// the old checksummed commit. No file is accepted on byte count alone.
    private static func oldAuthorityResolution(
        for url: URL,
        cachedCommitID: UUID?,
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws -> OverlayResolution? {
        guard cachedCommitID == journal.payload.oldCommit?.payload.commitID else {
            return nil
        }
        let root = activeRoot.standardizedFileURL
        let requested = url.standardizedFileURL
        guard isDescendant(requested, of: root), !sameFileSystemPath(requested, root) else { return nil }
        let oldSnapshotRoot = transactionRoot(
            activeRoot: root,
            transactionID: journal.payload.transactionID
        ).appendingPathComponent("old", isDirectory: true)
        if isDescendant(requested, of: oldSnapshotRoot),
           !sameFileSystemPath(requested, oldSnapshotRoot) {
            let requestedPath = normalizedFileSystemPath(requested)
            let snapshotRootPath = normalizedFileSystemPath(oldSnapshotRoot)
            let snapshotRelativePath = String(
                requestedPath.dropFirst(snapshotRootPath.count + 1)
            ).lowercased()
            if let operation = journal.payload.operations.first(where: {
                $0.relativePath.lowercased() == snapshotRelativePath
            }), let oldEntry = operation.oldEntry,
               try oldSnapshotCryptographicallyMatches(
                   requested,
                   operation: operation,
                   oldEntry: oldEntry
               ) {
                return OverlayResolution(
                    url: requested,
                    tier: oldEntry.contentTier
                )
            }
            return nil
        }
        let requestedPath = normalizedFileSystemPath(requested)
        let rootPath = normalizedFileSystemPath(root)
        let relativePath = String(requestedPath.dropFirst(rootPath.count + 1)).lowercased()
        guard let operation = journal.payload.operations.first(where: {
            $0.relativePath.lowercased() == relativePath
        }), let oldEntry = operation.oldEntry else { return nil }

        if journal.payload.phase == .readyToActivate,
           let backupRelativePath = operation.backupRelativePath {
            let backup = transactionRoot(
                activeRoot: root,
                transactionID: journal.payload.transactionID
            ).appendingPathComponent(backupRelativePath)
            if try oldSnapshotCryptographicallyMatches(
                backup,
                operation: operation,
                oldEntry: oldEntry
            ) {
                return OverlayResolution(url: backup, tier: oldEntry.contentTier)
            }
            return nil
        }

        guard let oldDigest = oldEntry.sha256,
              try cryptographicallyMatches(
                  requested,
                  byteCount: oldEntry.byteCount,
                  sha256: oldDigest
              ) else { return nil }
        return OverlayResolution(url: requested, tier: oldEntry.contentTier)
    }

    private static func oldSnapshotCryptographicallyMatches(
        _ snapshot: URL,
        operation: ArkFileContentActivationJournal.Operation,
        oldEntry: ArkFileInstalledContentAccess.CommitEntry
    ) throws -> Bool {
        guard let snapshotDigest = operation.oldSnapshotSHA256,
              try cryptographicallyMatches(
                  snapshot,
                  byteCount: oldEntry.byteCount,
                  sha256: snapshotDigest
              ) else { return false }
        if let committedDigest = oldEntry.sha256 {
            return snapshotDigest.lowercased() == committedDigest.lowercased()
        }
        return true
    }

    static func isPathBeingReplaced(_ url: URL, cachedCommitID: UUID?) -> Bool {
        overlayLock.lock()
        let activeState = activeOverlay
        let recoveryState = recoveryBlockedJournal
        let state = activeState ?? recoveryState
        let blockedRootPath = recoveryBlockedRootPath
        let isRecoveryBlock = activeState == nil && recoveryState != nil
        overlayLock.unlock()
        let requested = url.standardizedFileURL
        if let blockedRootPath,
           (normalizedFileSystemPath(requested) == blockedRootPath
            || normalizedFileSystemPath(requested).hasPrefix(blockedRootPath + "/")) {
            return true
        }
        guard let state,
              (isRecoveryBlock || state.journal.payload.phase == .readyToActivate) else {
            return false
        }
        let root = state.activeRoot.standardizedFileURL
        guard isDescendant(requested, of: root), !sameFileSystemPath(requested, root) else {
            return false
        }
        let requestedPath = normalizedFileSystemPath(requested)
        let rootPath = normalizedFileSystemPath(root)
        let relativePath = String(requestedPath.dropFirst(rootPath.count + 1)).lowercased()
        guard state.journal.payload.operations.contains(where: {
            $0.relativePath.lowercased() == relativePath
                && (isRecoveryBlock || $0.stagedRelativePath != nil)
        }) else { return false }
        // This query classifies the logical active pathname, not whether an
        // authoritative read can still be satisfied. Once a ready transaction
        // affects the path, its pathname may already contain uncommitted new
        // bytes (including same-length bytes). Keep Boolean/path-identity
        // callers fail-closed. Resolver-aware readers separately obtain the
        // cryptographically verified old snapshot through overlayResolution or
        // acquireReadLease, preserving offline access without blessing the
        // mutable active pathname.
        return true
    }

    static var hasBlockedRecovery: Bool {
        overlayLock.lock()
        defer { overlayLock.unlock() }
        return recoveryBlockedJournal != nil
            || recoveryBlockedRootPath != nil
            || recoveryFrozenRootPath != nil
    }

    /// True only when no valid committed authority exists to constrain reads.
    /// A preserved invalid journal still freezes mutation through
    /// `hasBlockedRecovery`, but does not hide exact last-committed content.
    static var hasRootWideReadBlock: Bool {
        overlayLock.lock()
        defer { overlayLock.unlock() }
        return recoveryBlockedRootPath != nil
    }

    static func isRecoveryFrozen(at activeRoot: URL) -> Bool {
        let path = normalizedFileSystemPath(activeRoot)
        overlayLock.lock()
        defer { overlayLock.unlock() }
        return recoveryFrozenRootPath == path
    }

    /// Authority synthesis may write only when journal metadata proves a
    /// definitive absence. Permission/protection failures are not absence.
    static func isJournalDefinitivelyAbsent(at activeRoot: URL) -> Bool {
        journalPathProbe(journalURL(activeRoot: activeRoot.standardizedFileURL))
            == .absent
    }

    private static func recoveryFreezeOrigin(
        at activeRoot: URL
    ) -> RecoveryFreezeOrigin? {
        let path = normalizedFileSystemPath(activeRoot)
        overlayLock.lock()
        defer { overlayLock.unlock() }
        guard recoveryFrozenRootPath == path else { return nil }
        return recoveryFreezeOriginState
    }

    static func installOverlayForTesting(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) {
        installOverlay(journal, activeRoot: activeRoot)
    }

    static func clearOverlayForTesting(transactionID: UUID) {
        clearOverlay(transactionID: transactionID)
    }

    static func writeJournalForTesting(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        try writeJournal(journal, activeRoot: activeRoot)
    }

    static func transactionRootForTesting(activeRoot: URL, transactionID: UUID) -> URL {
        transactionRoot(activeRoot: activeRoot, transactionID: transactionID)
    }

    static func removeTransactionMetadataForTesting(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        afterJournalRemoval: () throws -> Void
    ) throws {
        try removeTransactionMetadata(
            journal: journal,
            activeRoot: activeRoot,
            afterJournalRemoval: afterJournalRemoval
        )
    }

    static func currentAuthorityExactlyMatchesForTesting(
        _ expected: ArkFileInstalledContentAccess.CommitRecord?,
        at activeRoot: URL
    ) -> Bool {
        currentAuthorityExactlyMatches(expected, at: activeRoot)
    }

    static func installRecoveryBlockForTesting(
        activeRoot: URL,
        downloadRoot: URL? = nil
    ) {
        installRecoveryBlock(
            activeRoot: activeRoot,
            downloadRootOverride: downloadRoot
        )
    }

    static func clearRecoveryBlockForTesting(activeRoot: URL) {
        clearRecoveryBlock(activeRoot: activeRoot)
    }

    private static func createOldSnapshots(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws -> [String: String] {
        let transactionRoot = transactionRoot(
            activeRoot: activeRoot,
            transactionID: journal.payload.transactionID
        )
        var digests = [String: String]()
        for operation in journal.payload.operations {
            guard let oldEntry = operation.oldEntry,
                  let backupRelativePath = operation.backupRelativePath else { continue }
            let source = activeRoot.appendingPathComponent(operation.relativePath)
            let backup = transactionRoot.appendingPathComponent(backupRelativePath)
            try validateExistingDirectoryChain(
                to: source.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: false
            )
            guard regularFileSize(source) == oldEntry.byteCount else {
                throw ArkFileContentActivationError.backupSnapshotFailed(operation.relativePath)
            }
            try validateExistingDirectoryChain(
                to: backup.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: true
            )
            try FileManager.default.createDirectory(
                at: backup.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateExistingDirectoryChain(
                to: backup.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: false
            )
            guard !pathExists(backup) else {
                throw ArkFileContentActivationError.backupSnapshotFailed(operation.relativePath)
            }
            try FileManager.default.linkItem(at: source, to: backup)
            guard sameFileIdentity(source, backup), regularFileSize(backup) == oldEntry.byteCount else {
                throw ArkFileContentActivationError.backupSnapshotFailed(operation.relativePath)
            }
            let digest = try ArkFileContentFileVerifier.sha256HexDigest(of: backup)
            if let expected = oldEntry.sha256?.lowercased(), digest != expected {
                throw ArkFileContentActivationError.backupSnapshotFailed(operation.relativePath)
            }
            digests[operation.relativePath.lowercased()] = digest
        }
        try syncSnapshotDirectoryTree(journal: journal, activeRoot: activeRoot)
        return digests
    }

    /// The compatibility-group mutation gate was not acquired, so active paths
    /// are still exactly as they were before this transaction. Revalidate that
    /// invariant and remove only this transaction's hidden metadata. Verified
    /// staged payloads remain in Downloads for a later foreground retry.
    private static func abandonReadyTransactionBeforeMutation(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        downloadRoot: URL
    ) throws {
        guard journal.payload.phase == .readyToActivate else {
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        let currentState = ArkFileInstalledContentAccess.commitRecordLoadState(at: activeRoot)
        switch currentState {
        case .valid(let record):
            guard commitIdentity(record) == commitIdentity(journal.payload.oldCommit) else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
        case .absent:
            guard journal.payload.oldCommit == nil else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
        case .invalid, .unavailable:
            throw ArkFileContentActivationError.pendingForeignTransaction
        }

        let transactionRoot = transactionRoot(
            activeRoot: activeRoot,
            transactionID: journal.payload.transactionID
        )
        for operation in journal.payload.operations {
            let active = activeRoot.appendingPathComponent(operation.relativePath)
            if operation.stagedRelativePath != nil {
                let staged = try stagedURL(for: operation, downloadRoot: downloadRoot)
                guard try cryptographicallyMatches(
                    staged,
                    entry: operation.newManifestEntry
                ) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
            }
            if let oldEntry = operation.oldEntry,
               let backupRelativePath = operation.backupRelativePath,
               let snapshotDigest = operation.oldSnapshotSHA256 {
                let backup = transactionRoot.appendingPathComponent(backupRelativePath)
                guard try cryptographicallyMatches(
                    backup,
                    byteCount: oldEntry.byteCount,
                    sha256: snapshotDigest
                ), sameFileIdentity(active, backup) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
            } else if operation.stagedRelativePath != nil {
                guard !pathExists(active) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
            } else {
                guard try cryptographicallyMatches(
                    active,
                    entry: operation.newManifestEntry
                ) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
            }
        }
        clearOverlay(transactionID: journal.payload.transactionID)
        try removeTransactionMetadata(journal: journal, activeRoot: activeRoot)
        clearRecoveryBlock(activeRoot: activeRoot)
    }

    private static func replaceActiveFiles(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        downloadRoot: URL
    ) throws {
        for operation in journal.payload.operations {
            guard operation.stagedRelativePath != nil else { continue }
            let staged = try stagedURL(for: operation, downloadRoot: downloadRoot)
            let destination = activeRoot.appendingPathComponent(operation.relativePath)
            try validateExistingDirectoryChain(
                to: staged.deletingLastPathComponent(),
                under: downloadRoot,
                allowsMissing: false
            )
            guard try cryptographicallyMatches(
                staged,
                entry: operation.newManifestEntry
            ) else {
                throw ArkFileContentActivationError.missingVerifiedReplacement(
                    operation.relativePath
                )
            }
            try validateExistingDirectoryChain(
                to: destination.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: true
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateExistingDirectoryChain(
                to: destination.deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: false
            )
            guard Darwin.rename(staged.fileSystemPath, destination.fileSystemPath) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func verifyNewGroup(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        for operation in journal.payload.operations {
            let active = activeRoot.appendingPathComponent(operation.relativePath)
            try ArkFileContentFileVerifier.verifyFile(
                at: active,
                entry: operation.newManifestEntry
            )
        }
    }

    /// Returns the physical member libzim should open after every replacement
    /// member is adjacent in the active namespace. An ordinary `.zim` is the
    /// canonical anchor; fragment-only input falls back specifically to the
    /// first `.zimaa`, never a later fragment that cannot anchor the archive.
    static func zimSemanticValidationAnchorRelativePath(
        groupID: String,
        relativePaths: [String]
    ) throws -> String? {
        guard groupID.hasPrefix("zim:") else { return nil }
        let orderedPaths = relativePaths.sorted {
            let lhs = $0.lowercased()
            let rhs = $1.lowercased()
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        if let canonicalAnchor = orderedPaths.first(where: {
            $0.lowercased().hasSuffix(".zim")
        }) {
            return canonicalAnchor
        }
        if let firstFragment = orderedPaths.first(where: {
            $0.lowercased().hasSuffix(".zimaa")
        }) {
            return firstFragment
        }
        throw ArkFileContentActivationError.incompleteCompatibilityGroup(groupID)
    }

    private static func validateNewGroupSemantics(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        zimSemanticValidator: (URL) -> Bool,
        nonZimSemanticValidator: (
            URL,
            String,
            [String: ArkFilePackageManifest.Entry]
        ) -> Bool
    ) throws {
        if let relativePath = try zimSemanticValidationAnchorRelativePath(
            groupID: journal.payload.groupID,
            relativePaths: journal.payload.operations.map(\.relativePath)
        ) {
            let physicalNewURL = activeRoot.appendingPathComponent(relativePath)
            // Do not use ArkFileInstalledContentAccess here. Until the new
            // commit is durable its activation overlay intentionally resolves
            // readers to the old hard-link snapshot. This raw libzim probe
            // must inspect the newly replaced physical bytes instead.
            guard zimSemanticValidator(physicalNewURL) else {
                throw ArkFileContentActivationError.unreadableReplacement(relativePath)
            }
            return
        }

        let verifiedGroupEntries = Dictionary(
            uniqueKeysWithValues: journal.payload.operations.map {
                ($0.relativePath.lowercased(), $0.newManifestEntry)
            }
        )
        for operation in journal.payload.operations {
            let physicalNewURL = activeRoot.appendingPathComponent(operation.relativePath)
            guard nonZimSemanticValidator(
                physicalNewURL,
                operation.relativePath,
                verifiedGroupEntries
            ) else {
                throw ArkFileContentActivationError.unreadableReplacement(
                    operation.relativePath
                )
            }
        }
    }

    /// Direct physical-file probes for every user-readable format shipped in
    /// ArkFile's current iOS manifests. Hash and byte-count verification runs
    /// first; this second layer prevents a consistently published but malformed
    /// artifact from replacing the last readable emergency copy.
    static func replacementContentIsSemanticallyReadable(
        at url: URL,
        relativePath: String,
        verifiedGroupEntries: [String: ArkFilePackageManifest.Entry] = [:]
    ) -> Bool {
        switch (relativePath as NSString).pathExtension.lowercased() {
        case "pdf":
            return pdfIsSemanticallyReadable(at: url)
        case "zip":
            return ArkFileHTMLBookExtractor.isSemanticallyReadableArchive(at: url)
        case "jpg", "jpeg", "png", "gif", "webp", "bmp":
            return rasterImageIsSemanticallyReadable(at: url)
        case "svg":
            return svgIsSemanticallyReadable(at: url)
        case "html", "htm", "xhtml", "xht":
            return textDocumentIsSemanticallyReadable(at: url)
        case "json":
            return jsonIsSemanticallyReadable(
                at: url,
                relativePath: relativePath,
                verifiedGroupEntries: verifiedGroupEntries
            )
        case "sqlite", "sqlite3", "db":
            return sqliteIsSemanticallyReadable(at: url, relativePath: relativePath)
        case "pmtiles":
            return pmTilesV3HeaderIsReadable(at: url)
        default:
            // Opaque map dependencies such as PBF glyphs already passed exact
            // manifest size/hash verification. No production parser exposes a
            // synchronous standalone probe for them, so do not invent one.
            return true
        }
    }

    private static func pdfIsSemanticallyReadable(at url: URL) -> Bool {
        guard let document = PDFDocument(url: url),
              !document.isLocked,
              document.pageCount > 0,
              let page = document.page(at: 0) else {
            return false
        }
        let bounds = page.bounds(for: .mediaBox)
        return bounds.width.isFinite
            && bounds.height.isFinite
            && abs(bounds.width) > 0
            && abs(bounds.height) > 0
    }

    private static func rasterImageIsSemanticallyReadable(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) != nil
    }

    private static func textDocumentIsSemanticallyReadable(at url: URL) -> Bool {
        guard let prefix = try? readPrefix(of: url, maximumCount: 64 * 1_024),
              !prefix.isEmpty else {
            return false
        }
        return textPrefixIsReadable(prefix)
    }

    private static func textPrefixIsReadable(_ prefix: Data) -> Bool {
        if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff]) {
            // WebKit supports BOM-marked UTF-16. Its expected zero bytes must
            // not be mistaken for a binary impostor.
            return String(data: prefix, encoding: .utf16) != nil
        }
        let disallowedControlBytes = prefix.reduce(into: 0) { count, byte in
            if byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d {
                count += 1
            }
        }
        // WebKit intentionally accepts HTML fragments and imperfect legacy
        // markup, so the activation gate checks text readability rather than
        // imposing an XML grammar that would reject valid shipped books.
        return disallowedControlBytes <= max(1, prefix.count / 100)
    }

    private static func svgIsSemanticallyReadable(at url: URL) -> Bool {
        guard let data = readBoundedRegularFile(
            at: url,
            maximumCount: maximumStructuredDocumentBytes
        ),
              !data.isEmpty,
              let prefix = String(data: data.prefix(64 * 1_024), encoding: .utf8),
              prefix.range(of: "<svg", options: .caseInsensitive) != nil else {
            return false
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    private static func jsonIsSemanticallyReadable(
        at url: URL,
        relativePath: String,
        verifiedGroupEntries: [String: ArkFilePackageManifest.Entry]
    ) -> Bool {
        guard let data = readBoundedRegularFile(
            at: url,
            maximumCount: maximumStructuredDocumentBytes
        ),
              !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        let normalizedPath = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard normalizedPath.hasPrefix("maps/") else {
            return JSONSerialization.isValidJSONObject(object)
        }
        let fileName = (normalizedPath as NSString).lastPathComponent
        guard fileName == "manifest.json" || fileName == "regions-index.json" else {
            // Sprite metadata and other JSON map dependencies use their own
            // schemas. JSON parsing is their safe common activation probe.
            return JSONSerialization.isValidJSONObject(object)
        }
        guard let dictionary = object as? [String: Any],
              !dictionary.isEmpty else {
            return false
        }
        if let format = dictionary["format"] {
            guard let number = jsonNumber(format), number.intValue == 1 else {
                return false
            }
        }

        if normalizedPath.hasSuffix("/regions-index.json") {
            guard let index = try? JSONDecoder().decode(
                ArkFileMapRegionIndex.self,
                from: data
            ), !index.regions.isEmpty,
                  let rawRegions = dictionary["regions"] as? [[String: Any]],
                  rawRegions.count == index.regions.count else {
                return false
            }
            var regionIDs = Set<String>()
            return zip(index.regions, rawRegions).allSatisfy { region, rawRegion in
                let rawMaximumZoom = rawRegion["maxZoom"] ?? rawRegion["maxzoom"]
                let maximumZoom: Double
                if let rawMaximumZoom {
                    guard let parsed = jsonNumber(rawMaximumZoom)?.doubleValue else {
                        return false
                    }
                    maximumZoom = parsed
                } else {
                    maximumZoom = region.maxZoom
                }
                let rawMinimumZoom = rawRegion["minZoom"] ?? rawRegion["minzoom"]
                let minimumZoom: Double
                if let rawMinimumZoom {
                    guard let parsed = jsonNumber(rawMinimumZoom)?.doubleValue else {
                        return false
                    }
                    minimumZoom = parsed
                } else {
                    minimumZoom = 0
                }
                let declaredSizeIsReadable: Bool
                if let rawSize = rawRegion["sizeBytes"] {
                    declaredSizeIsReadable = positiveInt64(rawSize) != nil
                } else {
                    declaredSizeIsReadable = true
                }
                let digestIsReadable: Bool
                if let rawDigest = rawRegion["sha256"] {
                    digestIsReadable = sha256String(rawDigest) != nil
                } else {
                    digestIsReadable = true
                }
                let expectedRelativePath = "maps/regions/\(region.id)/region.pmtiles"
                let relativePathIsReadable: Bool
                if let rawRelativePathValue = rawRegion["relativePath"] {
                    guard let rawRelativePath = rawRelativePathValue as? String else {
                        return false
                    }
                    relativePathIsReadable = rawRelativePath
                        .replacingOccurrences(of: "\\", with: "/")
                        .lowercased() == expectedRelativePath.lowercased()
                } else {
                    relativePathIsReadable = true
                }
                return mapRegionIDIsSafe(region.id)
                    && regionIDs.insert(region.id.lowercased()).inserted
                    && region.bounds.count == 4
                    && region.bounds.allSatisfy(\.isFinite)
                    && (-180...180).contains(region.bounds[0])
                    && (-90...90).contains(region.bounds[1])
                    && (-180...180).contains(region.bounds[2])
                    && (-90...90).contains(region.bounds[3])
                    && region.bounds[0] <= region.bounds[2]
                    && region.bounds[1] <= region.bounds[3]
                    && minimumZoom.isFinite
                    && maximumZoom.isFinite
                    && minimumZoom >= 0
                    && minimumZoom <= maximumZoom
                    && maximumZoom <= 31
                    && declaredSizeIsReadable
                    && digestIsReadable
                    && relativePathIsReadable
            }
        }

        let descriptorKeys = ["global", "northAmerica", "region", "criticalPlaces"]
        let presentDescriptorKeys = descriptorKeys.filter { dictionary[$0] != nil }
        if !presentDescriptorKeys.isEmpty {
            return presentDescriptorKeys.allSatisfy { key in
                guard let descriptor = dictionary[key] as? [String: Any] else {
                    return false
                }
                return mapArchiveDescriptorIsReadable(
                    descriptor,
                    descriptorKey: key,
                    manifestURL: url,
                    manifestRelativePath: relativePath,
                    verifiedGroupEntries: verifiedGroupEntries
                )
            }
        }
        // Older map manifests placed archive fields at the top level. Keep
        // those readable while still rejecting an empty or unrelated object.
        return mapArchiveDescriptorIsReadable(
            dictionary,
            descriptorKey: "legacyRegion",
            manifestURL: url,
            manifestRelativePath: relativePath,
            verifiedGroupEntries: verifiedGroupEntries
        )
    }

    private static func mapArchiveDescriptorIsReadable(
        _ descriptor: [String: Any],
        descriptorKey: String,
        manifestURL: URL,
        manifestRelativePath: String,
        verifiedGroupEntries: [String: ArkFilePackageManifest.Entry]
    ) -> Bool {
        guard let file = descriptor["file"] as? String,
              !file.isEmpty,
              !(file as NSString).isAbsolutePath else {
            return false
        }
        let normalizedFile = file.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedFile.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !normalizedFile.contains("\0"),
              !normalizedFile.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let declaredSize = positiveInt64(descriptor["sizeBytes"]),
              let declaredDigest = sha256String(descriptor["sha256"]) else {
            return false
        }
        let fileExtension = (normalizedFile as NSString).pathExtension.lowercased()
        let isCriticalPlaces = descriptorKey == "criticalPlaces"
        if isCriticalPlaces {
            guard ["sqlite", "sqlite3", "db"].contains(fileExtension),
                  descriptor["schemaVersion"].map({
                      jsonNumber($0)?.intValue == 1
                  }) ?? true,
                  descriptor["rowCount"].map({ positiveInt64($0) != nil }) ?? true else {
                return false
            }
        } else {
            guard fileExtension == "pmtiles" else { return false }
        }

        if !isCriticalPlaces {
            guard let rawBounds = descriptor["bounds"] as? [Any],
                  rawBounds.count == 4 else {
                return false
            }
            let numbers = rawBounds.compactMap(jsonNumber)
            guard numbers.count == 4 else { return false }
            let bounds = numbers.map(\.doubleValue)
            guard bounds.allSatisfy(\.isFinite),
                  (-180...180).contains(bounds[0]),
                  (-90...90).contains(bounds[1]),
                  (-180...180).contains(bounds[2]),
                  (-90...90).contains(bounds[3]),
                  bounds[0] <= bounds[2],
                  bounds[1] <= bounds[3] else {
                return false
            }
            guard let minimumZoom = (descriptor["minzoom"] ?? descriptor["minZoom"])
                    .flatMap(jsonNumber)?.doubleValue,
                  let maximumZoom = (descriptor["maxzoom"] ?? descriptor["maxZoom"])
                    .flatMap(jsonNumber)?.doubleValue,
                  minimumZoom.isFinite,
                  maximumZoom.isFinite,
                  minimumZoom >= 0,
                  minimumZoom <= maximumZoom,
                  maximumZoom <= 31 else {
                return false
            }
        }

        let referencedURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(normalizedFile)
        guard regularFileSize(referencedURL) == declaredSize else { return false }
        let manifestDirectory = (manifestRelativePath as NSString)
            .deletingLastPathComponent
        let referencedRelativePath = manifestDirectory.isEmpty
            ? normalizedFile
            : "\(manifestDirectory)/\(normalizedFile)"
        if let verifiedEntry = verifiedGroupEntries[referencedRelativePath.lowercased()] {
            // `verifyNewGroup` already hashed this exact physical operation.
            // Comparing the inner map manifest to that journal entry avoids a
            // third multi-gigabyte read of the same map during activation.
            return verifiedEntry.sizeBytes == declaredSize
                && verifiedEntry.sha256.lowercased() == declaredDigest
        }
        guard let digest = try? ArkFileContentFileVerifier.sha256HexDigest(
            of: referencedURL
        ) else {
            return false
        }
        return digest.lowercased() == declaredDigest
    }

    private static func mapRegionIDIsSafe(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty
            && id.count <= 128
            && trimmed == id
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func positiveInt64(_ value: Any?) -> Int64? {
        guard let value,
              let number = jsonNumber(value) else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue >= 1,
              doubleValue <= Double(Int64.max),
              doubleValue.rounded(.towardZero) == doubleValue else {
            return nil
        }
        let integerValue = number.int64Value
        return integerValue > 0 && Double(integerValue) == doubleValue
            ? integerValue
            : nil
    }

    private static func sha256String(_ value: Any?) -> String? {
        guard let digest = value as? String,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return digest.lowercased()
    }

    private static func jsonNumber(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }

    private static func sqliteIsSemanticallyReadable(
        at url: URL,
        relativePath: String
    ) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.fileSystemPath,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var quickCheck: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA quick_check(1)",
            -1,
            &quickCheck,
            nil
        ) == SQLITE_OK, let quickCheck else {
            if let quickCheck { sqlite3_finalize(quickCheck) }
            return false
        }
        defer { sqlite3_finalize(quickCheck) }
        guard sqlite3_step(quickCheck) == SQLITE_ROW,
              let quickCheckText = sqlite3_column_text(quickCheck, 0),
              String(cString: quickCheckText).lowercased() == "ok" else {
            return false
        }

        let normalizedPath = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard normalizedPath == "maps/poi/us_critical_places.sqlite" else {
            return true
        }
        var representativeQuery: OpaquePointer?
        let sql = """
        SELECT p.id, p.kind, p.name, p.lat, p.lon, p.locality
        FROM places p
        JOIN places_rtree r ON p.id = r.id
        LIMIT 1
        """
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &representativeQuery,
            nil
        ) == SQLITE_OK, let representativeQuery else {
            if let representativeQuery { sqlite3_finalize(representativeQuery) }
            return false
        }
        defer { sqlite3_finalize(representativeQuery) }
        let result = sqlite3_step(representativeQuery)
        return result == SQLITE_ROW
    }

    struct PMTilesV3Probe: Equatable, Sendable {
        let internalCompression: UInt8
        let tileCompression: UInt8
        let tileType: UInt8
        let metadataKeys: [String]
        let representativeTileByteCount: Int
    }

    private struct PMTilesV3Header {
        let rootOffset: UInt64
        let rootLength: UInt64
        let metadataOffset: UInt64
        let metadataLength: UInt64
        let leafOffset: UInt64
        let leafLength: UInt64
        let tileOffset: UInt64
        let tileLength: UInt64
        let internalCompression: UInt8
        let tileCompression: UInt8
        let tileType: UInt8
    }

    private struct PMTilesDirectoryEntry: Hashable {
        let tileID: UInt64
        let offset: UInt64
        let length: UInt64
        let runLength: UInt64
    }

    /// Performs a bounded PMTiles v3 open probe while rollback is still
    /// possible. In addition to the fixed header it decodes metadata, walks a
    /// bounded root/leaf directory path, decompresses one referenced tile, and
    /// validates that tile against the declared type. None/gzip are supported;
    /// Brotli and Zstandard preserve the prior committed archive fail-closed.
    static func pmTilesV3HeaderIsReadable(at url: URL) -> Bool {
        pmTilesV3Probe(at: url) != nil
    }

    static func pmTilesV3Probe(at url: URL) -> PMTilesV3Probe? {
        do {
            guard let fileSize = regularFileSize(url), fileSize >= 127 else {
                return nil
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 127) ?? Data()
            guard header.count == 127,
                  String(data: header.prefix(7), encoding: .utf8) == "PMTiles",
                  header[7] == 3,
                  let rootOffset = littleEndianUInt64(header, at: 8),
                  let rootLength = littleEndianUInt64(header, at: 16),
                  let metadataOffset = littleEndianUInt64(header, at: 24),
                  let metadataLength = littleEndianUInt64(header, at: 32),
                  let leafOffset = littleEndianUInt64(header, at: 40),
                  let leafLength = littleEndianUInt64(header, at: 48),
                  let tileOffset = littleEndianUInt64(header, at: 56),
                  let tileLength = littleEndianUInt64(header, at: 64),
                  littleEndianUInt64(header, at: 72) != nil,
                  littleEndianUInt64(header, at: 80) != nil,
                  littleEndianUInt64(header, at: 88) != nil else {
                return nil
            }
            let unsignedFileSize = UInt64(fileSize)
            guard rootLength > 0,
                  metadataLength > 0,
                  tileLength > 0,
                  sectionIsWithinFile(
                    offset: rootOffset,
                    length: rootLength,
                    fileSize: unsignedFileSize
                  ),
                  sectionIsWithinFile(
                    offset: metadataOffset,
                    length: metadataLength,
                    fileSize: unsignedFileSize
                  ),
                  sectionIsWithinFile(
                    offset: leafOffset,
                    length: leafLength,
                    fileSize: unsignedFileSize
                  ),
                  sectionIsWithinFile(
                    offset: tileOffset,
                    length: tileLength,
                    fileSize: unsignedFileSize
                  ),
                  rootOffset >= 127,
                  rootOffset <= 16_384,
                  rootLength <= 16_384 - rootOffset,
                  pmTilesSectionsDoNotOverlap([
                      (rootOffset, rootLength),
                      (metadataOffset, metadataLength),
                      (leafOffset, leafLength),
                      (tileOffset, tileLength)
                  ]),
                  header[96] <= 1,
                  (1...2).contains(header[97]),
                  (1...2).contains(header[98]),
                  (1...5).contains(header[99]),
                  header[100] <= header[101],
                  header[101] <= 31,
                  header[118] <= 31,
                  let minLongitude = littleEndianInt32(header, at: 102),
                  let minLatitude = littleEndianInt32(header, at: 106),
                  let maxLongitude = littleEndianInt32(header, at: 110),
                  let maxLatitude = littleEndianInt32(header, at: 114),
                  let centerLongitude = littleEndianInt32(header, at: 119),
                  let centerLatitude = littleEndianInt32(header, at: 123),
                  (-1_800_000_000...1_800_000_000).contains(minLongitude),
                  (-1_800_000_000...1_800_000_000).contains(maxLongitude),
                  (-900_000_000...900_000_000).contains(minLatitude),
                  (-900_000_000...900_000_000).contains(maxLatitude),
                  (-1_800_000_000...1_800_000_000).contains(centerLongitude),
                  (-900_000_000...900_000_000).contains(centerLatitude),
                  minLongitude <= maxLongitude,
                  minLatitude <= maxLatitude else {
                return nil
            }
            let parsedHeader = PMTilesV3Header(
                rootOffset: rootOffset,
                rootLength: rootLength,
                metadataOffset: metadataOffset,
                metadataLength: metadataLength,
                leafOffset: leafOffset,
                leafLength: leafLength,
                tileOffset: tileOffset,
                tileLength: tileLength,
                internalCompression: header[97],
                tileCompression: header[98],
                tileType: header[99]
            )

            let maximumStoredRootBytes: UInt64 = 16_257
            let maximumDecodedRootBytes = 16 * 1_024 * 1_024
            guard rootLength <= maximumStoredRootBytes,
                  let storedRoot = try readPMTilesSection(
                      handle,
                      offset: rootOffset,
                      length: rootLength,
                      maximumCount: Int(maximumStoredRootBytes)
                  ),
                  let root = decodePMTilesData(
                      storedRoot,
                      compression: parsedHeader.internalCompression,
                      maximumCount: maximumDecodedRootBytes
                  ),
                  let rootEntries = decodePMTilesDirectory(
                      root,
                      leafDirectoryLength: leafLength,
                      tileDataLength: tileLength
                  ),
                  let storedMetadata = try readPMTilesSection(
                      handle,
                      offset: metadataOffset,
                      length: metadataLength,
                      maximumCount: maximumStructuredDocumentBytes
                  ),
                  let metadata = decodePMTilesData(
                      storedMetadata,
                      compression: parsedHeader.internalCompression,
                      maximumCount: maximumStructuredDocumentBytes
                  ),
                  let metadataObject = pmTilesMetadataObject(
                      metadata,
                      tileType: parsedHeader.tileType
                  ),
                  let tileEntry = try representativePMTilesEntry(
                      rootEntries: rootEntries,
                      header: parsedHeader,
                      handle: handle
                  ),
                  let storedTile = try readPMTilesRelativeSection(
                      handle,
                      baseOffset: tileOffset,
                      sectionLength: tileLength,
                      entry: tileEntry,
                      maximumCount: 16 * 1_024 * 1_024
                  ),
                  let tile = decodePMTilesData(
                      storedTile,
                      compression: parsedHeader.tileCompression,
                      maximumCount: 32 * 1_024 * 1_024
                  ),
                  pmTilesTileIsReadable(tile, declaredType: parsedHeader.tileType) else {
                return nil
            }
            return PMTilesV3Probe(
                internalCompression: parsedHeader.internalCompression,
                tileCompression: parsedHeader.tileCompression,
                tileType: parsedHeader.tileType,
                metadataKeys: metadataObject.keys.sorted(),
                representativeTileByteCount: tile.count
            )
        } catch {
            return nil
        }
    }

    private static func readPrefix(of url: URL, maximumCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumCount) ?? Data()
    }

    /// Reads a complete regular file while enforcing the limit on every read,
    /// not only through a racy metadata preflight. A file that grows during
    /// activation can consume at most `maximumCount + 1` bytes before failing.
    private static func readBoundedRegularFile(
        at url: URL,
        maximumCount: Int
    ) -> Data? {
        guard maximumCount > 0,
              let expectedSize = regularFileSize(url),
              expectedSize >= 0,
              expectedSize <= Int64(maximumCount) else {
            return nil
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var result = Data()
            result.reserveCapacity(Int(expectedSize))
            while result.count <= maximumCount {
                let remaining = maximumCount + 1 - result.count
                let chunk = try handle.read(upToCount: min(64 * 1_024, remaining))
                    ?? Data()
                if chunk.isEmpty { break }
                result.append(chunk)
            }
            guard result.count == Int(expectedSize),
                  result.count <= maximumCount else {
                return nil
            }
            return result
        } catch {
            return nil
        }
    }

    private static func sectionIsWithinFile(
        offset: UInt64,
        length: UInt64,
        fileSize: UInt64
    ) -> Bool {
        offset <= fileSize && length <= fileSize - offset
    }

    private static func pmTilesSectionsDoNotOverlap(
        _ sections: [(offset: UInt64, length: UInt64)]
    ) -> Bool {
        let nonempty = sections.filter { $0.length > 0 }
        guard nonempty.allSatisfy({ $0.offset >= 127 }) else { return false }
        for firstIndex in nonempty.indices {
            let first = nonempty[firstIndex]
            guard first.length <= UInt64.max - first.offset else { return false }
            let firstEnd = first.offset + first.length
            for secondIndex in nonempty.indices where secondIndex > firstIndex {
                let second = nonempty[secondIndex]
                guard second.length <= UInt64.max - second.offset else { return false }
                let secondEnd = second.offset + second.length
                if first.offset < secondEnd && second.offset < firstEnd {
                    return false
                }
            }
        }
        return true
    }

    private static func readPMTilesSection(
        _ handle: FileHandle,
        offset: UInt64,
        length: UInt64,
        maximumCount: Int
    ) throws -> Data? {
        guard length > 0,
              maximumCount > 0,
              length <= UInt64(maximumCount),
              let count = Int(exactly: length) else { return nil }
        try handle.seek(toOffset: offset)
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try handle.read(upToCount: min(64 * 1_024, count - data.count))
                ?? Data()
            guard !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data.count == count ? data : nil
    }

    private static func readPMTilesRelativeSection(
        _ handle: FileHandle,
        baseOffset: UInt64,
        sectionLength: UInt64,
        entry: PMTilesDirectoryEntry,
        maximumCount: Int
    ) throws -> Data? {
        guard entry.length > 0,
              entry.offset <= sectionLength,
              entry.length <= sectionLength - entry.offset,
              entry.offset <= UInt64.max - baseOffset else { return nil }
        return try readPMTilesSection(
            handle,
            offset: baseOffset + entry.offset,
            length: entry.length,
            maximumCount: maximumCount
        )
    }

    private static func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    private static func littleEndianInt32(_ data: Data, at offset: Int) -> Int32? {
        littleEndianUInt32(data, at: offset).map { Int32(bitPattern: $0) }
    }

    private static func decodePMTilesData(
        _ data: Data,
        compression: UInt8,
        maximumCount: Int
    ) -> Data? {
        switch compression {
        case 1:
            return data.count <= maximumCount ? data : nil
        case 2:
            return gunzippedPMTilesData(data, maximumCount: maximumCount)
        case 3, 4:
            return nil
        default:
            return nil
        }
    }

    private static func gunzippedPMTilesData(
        _ data: Data,
        maximumCount: Int
    ) -> Data? {
        guard maximumCount > 0,
              maximumCount <= Int(UInt32.max),
              data.count >= 18,
              data[0] == 0x1f,
              data[1] == 0x8b,
              data[2] == 8,
              data[3] & 0xe0 == 0,
              let uncompressedSize = littleEndianUInt32(
                data,
                at: data.count - 4
              ),
              uncompressedSize > 0,
              uncompressedSize <= UInt32(maximumCount) else {
            return nil
        }
        let expectedCount = Int(uncompressedSize)
        // One spare output byte distinguishes an exact stream end from a gzip
        // member whose forged ISIZE understates its decompressed output.
        let outputCapacity = expectedCount + 1
        var output = Data(count: outputCapacity)
        var stream = z_stream()
        let didDecodeExactly = data.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress,
                      let outputBase = outputBuffer.baseAddress else {
                    return false
                }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating:
                    inputBase.assumingMemoryBound(to: Bytef.self)
                )
                stream.avail_in = uInt(data.count)
                stream.next_out = outputBase.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputCapacity)
                guard inflateInit2_(
                    &stream,
                    15 + 16,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                ) == Z_OK else {
                    return false
                }
                defer { inflateEnd(&stream) }
                return inflate(&stream, Z_FINISH) == Z_STREAM_END
                    && stream.avail_in == 0
                    && stream.total_out == uLong(expectedCount)
            }
        }
        guard didDecodeExactly else { return nil }
        output.removeSubrange(expectedCount..<output.count)
        return output
    }

    private static func decodePMTilesDirectory(
        _ data: Data,
        leafDirectoryLength: UInt64,
        tileDataLength: UInt64
    ) -> [PMTilesDirectoryEntry]? {
        var cursor = 0
        guard let entryCountValue = readVarint(data, cursor: &cursor),
              entryCountValue > 0,
              entryCountValue <= 1_000_000,
              entryCountValue <= UInt64((data.count - cursor) / 4),
              let entryCount = Int(exactly: entryCountValue) else {
            return nil
        }

        var tileIDs: [UInt64] = []
        tileIDs.reserveCapacity(entryCount)
        var previousTileID: UInt64 = 0
        for index in 0..<entryCount {
            guard let delta = readVarint(data, cursor: &cursor),
                  (index == 0 || delta > 0),
                  previousTileID <= UInt64.max - delta else {
                return nil
            }
            previousTileID += delta
            tileIDs.append(previousTileID)
        }
        var runLengths: [UInt64] = []
        var lengths: [UInt64] = []
        runLengths.reserveCapacity(entryCount)
        lengths.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard let value = readVarint(data, cursor: &cursor) else { return nil }
            runLengths.append(value)
        }
        for _ in 0..<entryCount {
            guard let value = readVarint(data, cursor: &cursor), value > 0 else {
                return nil
            }
            lengths.append(value)
        }

        var entries: [PMTilesDirectoryEntry] = []
        entries.reserveCapacity(entryCount)
        var previousOffset: UInt64 = 0
        var previousLength: UInt64 = 0
        for index in 0..<entryCount {
            guard let encodedOffset = readVarint(data, cursor: &cursor) else {
                return nil
            }
            let offset: UInt64
            if encodedOffset == 0 {
                guard index > 0,
                      previousOffset <= UInt64.max - previousLength else {
                    return nil
                }
                offset = previousOffset + previousLength
            } else {
                offset = encodedOffset - 1
            }
            let length = lengths[index]
            let containingLength = runLengths[index] == 0
                ? leafDirectoryLength
                : tileDataLength
            guard offset <= containingLength,
                  length <= containingLength - offset else {
                return nil
            }
            entries.append(PMTilesDirectoryEntry(
                tileID: tileIDs[index],
                offset: offset,
                length: length,
                runLength: runLengths[index]
            ))
            previousOffset = offset
            previousLength = length
        }
        return cursor == data.count ? entries : nil
    }

    private static func representativePMTilesEntry(
        rootEntries: [PMTilesDirectoryEntry],
        header: PMTilesV3Header,
        handle: FileHandle
    ) throws -> PMTilesDirectoryEntry? {
        if let direct = rootEntries.first(where: { $0.runLength > 0 }) {
            return direct
        }
        var queue = rootEntries.filter { $0.runLength == 0 }.map { ($0, 1) }
        var queueIndex = 0
        var visited = Set<PMTilesDirectoryEntry>()
        var storedBytes = 0
        var decodedBytes = 0
        let maximumDirectories = 64
        let maximumDepth = 8
        let maximumDirectoryBytes = 16 * 1_024 * 1_024

        while queueIndex < queue.count, visited.count < maximumDirectories {
            let (pointer, depth) = queue[queueIndex]
            queueIndex += 1
            guard depth <= maximumDepth else { return nil }
            guard visited.insert(pointer).inserted else { continue }
            guard pointer.length <= UInt64(maximumDirectoryBytes - storedBytes),
                  let stored = try readPMTilesRelativeSection(
                      handle,
                      baseOffset: header.leafOffset,
                      sectionLength: header.leafLength,
                      entry: pointer,
                      maximumCount: maximumDirectoryBytes - storedBytes
                  ) else { return nil }
            storedBytes += stored.count
            guard let decoded = decodePMTilesData(
                stored,
                compression: header.internalCompression,
                maximumCount: maximumDirectoryBytes - decodedBytes
            ) else { return nil }
            decodedBytes += decoded.count
            guard let entries = decodePMTilesDirectory(
                decoded,
                leafDirectoryLength: header.leafLength,
                tileDataLength: header.tileLength
            ) else { return nil }
            if let direct = entries.first(where: { $0.runLength > 0 }) {
                return direct
            }
            let leafPointers = entries.filter { $0.runLength == 0 }
            guard leafPointers.count <= 4_096,
                  queue.count <= 4_096 - leafPointers.count else { return nil }
            queue.append(contentsOf: leafPointers.map {
                ($0, depth + 1)
            })
        }
        return nil
    }

    private static func pmTilesMetadataObject(
        _ data: Data,
        tileType: UInt8
    ) -> [String: Any]? {
        guard !data.isEmpty,
              String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        if tileType == 1 {
            guard let layers = dictionary["vector_layers"] as? [[String: Any]],
                  !layers.isEmpty else { return nil }
            var layerIDs = Set<String>()
            for layer in layers {
                guard let id = layer["id"] as? String,
                      let fields = layer["fields"] as? [String: Any],
                      fields.values.allSatisfy({ $0 is String }),
                      !id.isEmpty,
                      id.count <= 1_024,
                      id.trimmingCharacters(in: .whitespacesAndNewlines) == id,
                      !id.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      }),
                      layerIDs.insert(id).inserted else { return nil }
            }
        }
        return dictionary
    }

    private static func pmTilesTileIsReadable(
        _ data: Data,
        declaredType: UInt8
    ) -> Bool {
        guard !data.isEmpty else { return false }
        switch declaredType {
        case 1:
            return mvtTileIsStructurallyReadable(data)
        case 2:
            return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
                && rasterTileIsDecodable(data)
        case 3:
            return data.count >= 3
                && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff
                && rasterTileIsDecodable(data)
        case 4:
            return data.count >= 12
                && String(data: data[0..<4], encoding: .ascii) == "RIFF"
                && String(data: data[8..<12], encoding: .ascii) == "WEBP"
                && rasterTileIsDecodable(data)
        case 5:
            let brandWindow = data.prefix(64)
            return data.count >= 16
                && String(data: data[4..<8], encoding: .ascii) == "ftyp"
                && (brandWindow.range(of: Data("avif".utf8)) != nil
                    || brandWindow.range(of: Data("avis".utf8)) != nil)
                && rasterTileIsDecodable(data)
        default:
            return false
        }
    }

    private static func rasterTileIsDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0,
              width.intValue <= 100_000,
              height.intValue <= 100_000 else { return false }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil
    }

    private static func mvtTileIsStructurallyReadable(_ data: Data) -> Bool {
        var cursor = 0
        var foundLayer = false
        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor),
                  key >> 3 > 0 else { return false }
            let fieldNumber = key >> 3
            let wireType = UInt8(key & 0x07)
            if fieldNumber == 3, wireType == 2 {
                guard let layer = readProtobufLengthDelimited(data, cursor: &cursor),
                      mvtLayerIsStructurallyReadable(layer) else { return false }
                foundLayer = true
            } else if !skipProtobufValue(data, cursor: &cursor, wireType: wireType) {
                return false
            }
        }
        return foundLayer
    }

    private static func mvtLayerIsStructurallyReadable(_ data: Data) -> Bool {
        var cursor = 0
        var name: String?
        var version: UInt64?
        var foundExtent = false
        while cursor < data.count {
            guard let key = readVarint(data, cursor: &cursor),
                  key >> 3 > 0 else { return false }
            let fieldNumber = key >> 3
            let wireType = UInt8(key & 0x07)
            switch (fieldNumber, wireType) {
            case (1, 2):
                guard let bytes = readProtobufLengthDelimited(data, cursor: &cursor),
                      let decoded = String(data: bytes, encoding: .utf8),
                      !decoded.isEmpty,
                      decoded.count <= 1_024,
                      !decoded.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      }) else { return false }
                name = decoded
            case (5, 0):
                guard let extent = readVarint(data, cursor: &cursor),
                      extent > 0,
                      extent <= UInt64(UInt32.max) else { return false }
                foundExtent = true
            case (15, 0):
                guard let decodedVersion = readVarint(data, cursor: &cursor),
                      decodedVersion == 1 || decodedVersion == 2 else { return false }
                version = decodedVersion
            default:
                guard skipProtobufValue(data, cursor: &cursor, wireType: wireType) else {
                    return false
                }
            }
        }
        return name != nil && version != nil && foundExtent
    }

    private static func readProtobufLengthDelimited(
        _ data: Data,
        cursor: inout Int
    ) -> Data? {
        guard let lengthValue = readVarint(data, cursor: &cursor),
              let length = Int(exactly: lengthValue),
              length <= data.count - cursor else { return nil }
        let result = data.subdata(in: cursor..<(cursor + length))
        cursor += length
        return result
    }

    private static func skipProtobufValue(
        _ data: Data,
        cursor: inout Int,
        wireType: UInt8
    ) -> Bool {
        switch wireType {
        case 0:
            return readVarint(data, cursor: &cursor) != nil
        case 1:
            guard cursor <= data.count - 8 else { return false }
            cursor += 8
            return true
        case 2:
            return readProtobufLengthDelimited(data, cursor: &cursor) != nil
        case 5:
            guard cursor <= data.count - 4 else { return false }
            cursor += 4
            return true
        default:
            return false
        }
    }

    private static func readVarint(_ data: Data, cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard cursor < data.count else { return nil }
            let byte = data[cursor]
            cursor += 1
            let payload = UInt64(byte & 0x7f)
            guard shift < 64,
                  payload <= (UInt64.max >> shift) else {
                return nil
            }
            value |= payload << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func newGroupCryptographicallyMatches(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws -> Bool {
        for operation in journal.payload.operations {
            let active = activeRoot.appendingPathComponent(operation.relativePath)
            if try !cryptographicallyMatches(active, entry: operation.newManifestEntry) {
                return false
            }
        }
        return true
    }

    private static func rollbackToOldCommit(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        downloadRoot: URL,
        allowsDefinitivelyDamagedNewBytes: Bool,
        rewriteOldCommit: Bool
    ) throws {
        let transactionRoot = transactionRoot(
            activeRoot: activeRoot,
            transactionID: journal.payload.transactionID
        )
        struct RollbackAction {
            let operation: ArkFileContentActivationJournal.Operation
            let moveActiveToStaging: Bool
            let restoreOldLink: Bool
        }

        // Fully validate every backup and every source/destination state before
        // changing a single path. An I/O or data-protection error therefore
        // cannot cause a partial rollback.
        var actions = [RollbackAction]()
        for operation in journal.payload.operations {
            let active = activeRoot.appendingPathComponent(operation.relativePath)
            var backup: URL?
            if let oldEntry = operation.oldEntry,
               let backupRelativePath = operation.backupRelativePath,
               let expectedDigest = operation.oldSnapshotSHA256 {
                let candidate = transactionRoot.appendingPathComponent(backupRelativePath)
                try validateExistingDirectoryChain(
                    to: candidate.deletingLastPathComponent(),
                    under: activeRoot,
                    allowsMissing: false
                )
                guard try cryptographicallyMatches(
                    candidate,
                    byteCount: oldEntry.byteCount,
                    sha256: expectedDigest
                ) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
                backup = candidate
            }

            if operation.stagedRelativePath != nil {
                let staged = try stagedURL(for: operation, downloadRoot: downloadRoot)
                try validateExistingDirectoryChain(
                    to: staged.deletingLastPathComponent(),
                    under: downloadRoot,
                    allowsMissing: true
                )
                let activeIsOld = backup.map { sameFileIdentity(active, $0) } == true
                if activeIsOld {
                    actions.append(.init(
                        operation: operation,
                        moveActiveToStaging: false,
                        restoreOldLink: false
                    ))
                    continue
                }
                let activeExists = pathExists(active)
                let activeIsNew = activeExists
                    ? try cryptographicallyMatches(active, entry: operation.newManifestEntry)
                    : false
                let activeIsDefinitivelyDamagedRegularFile = activeExists
                    && regularFileSize(active) != nil
                    && allowsDefinitivelyDamagedNewBytes
                guard activeIsNew || activeIsDefinitivelyDamagedRegularFile
                        || !activeExists else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
                if activeExists, pathExists(staged) {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
                actions.append(.init(
                    operation: operation,
                    moveActiveToStaging: activeExists,
                    restoreOldLink: backup != nil
                ))
            } else {
                // No rename was part of this operation. Its verified active
                // file existed before the transaction and must remain in place.
                guard try cryptographicallyMatches(
                    active,
                    entry: operation.newManifestEntry
                ) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
                actions.append(.init(
                    operation: operation,
                    moveActiveToStaging: false,
                    restoreOldLink: false
                ))
            }
        }

        for action in actions {
            let operation = action.operation
            let active = activeRoot.appendingPathComponent(operation.relativePath)
            if action.moveActiveToStaging, operation.stagedRelativePath != nil {
                let staged = try stagedURL(for: operation, downloadRoot: downloadRoot)
                try validateExistingDirectoryChain(
                    to: staged.deletingLastPathComponent(),
                    under: downloadRoot,
                    allowsMissing: true
                )
                try FileManager.default.createDirectory(
                    at: staged.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try validateExistingDirectoryChain(
                    to: staged.deletingLastPathComponent(),
                    under: downloadRoot,
                    allowsMissing: false
                )
                guard Darwin.rename(active.fileSystemPath, staged.fileSystemPath) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            if action.restoreOldLink,
               let backupRelativePath = operation.backupRelativePath {
                let backup = transactionRoot.appendingPathComponent(backupRelativePath)
                try validateExistingDirectoryChain(
                    to: active.deletingLastPathComponent(),
                    under: activeRoot,
                    allowsMissing: true
                )
                try FileManager.default.createDirectory(
                    at: active.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try validateExistingDirectoryChain(
                    to: active.deletingLastPathComponent(),
                    under: activeRoot,
                    allowsMissing: false
                )
                try FileManager.default.linkItem(at: backup, to: active)
                guard sameFileIdentity(active, backup) else {
                    throw ArkFileContentActivationError.ambiguousRecovery(operation.relativePath)
                }
            }
        }
        for action in actions {
            let active = activeRoot.appendingPathComponent(action.operation.relativePath)
            if pathExists(active) {
                try syncRegularFile(active)
            }
            if action.operation.stagedRelativePath != nil {
                let staged = try stagedURL(
                    for: action.operation,
                    downloadRoot: downloadRoot
                )
                if pathExists(staged) {
                    try syncRegularFile(staged)
                }
            }
        }
        try syncDirectoryTreeForOperations(
            journal.payload.operations,
            root: activeRoot,
            sourceRoot: downloadRoot
        )
        if rewriteOldCommit {
            if let oldCommit = journal.payload.oldCommit {
                try ArkFileInstalledContentAccess.writeCommitRecordDurably(oldCommit, at: activeRoot)
            } else {
                try ArkFileInstalledContentAccess.removeCommitRecordDurably(at: activeRoot)
            }
            ArkFileInstalledContentAccess.reloadAfterContentCommit()
        }
        try removeOrDeferTransactionMetadata(journal: journal, activeRoot: activeRoot)
    }

    private static func finalizeCommittedJournal(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        guard commitIdentity(ArkFileInstalledContentAccess.currentCommitRecord(at: activeRoot))
                == commitIdentity(journal.payload.newCommit) else {
            throw ArkFileContentActivationError.pendingForeignTransaction
        }
        try removeOrDeferTransactionMetadata(journal: journal, activeRoot: activeRoot)
    }

    private static func currentAuthorityExactlyMatches(
        _ expected: ArkFileInstalledContentAccess.CommitRecord?,
        at activeRoot: URL
    ) -> Bool {
        switch (expected, ArkFileInstalledContentAccess.commitRecordLoadState(at: activeRoot)) {
        case (.none, .absent):
            return true
        case (.some(let expected), .valid(let current)):
            return commitIdentity(expected) == commitIdentity(current)
        case (.none, .valid), (.none, .invalid), (.none, .unavailable),
             (.some, .absent), (.some, .invalid), (.some, .unavailable):
            return false
        }
    }

    private static func removeOrDeferTransactionMetadata(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        overlayLock.lock()
        if readLeaseCounts[journal.payload.transactionID, default: 0] > 0 {
            // Whether commit finalized or rollback restored old authority, a
            // resolver-aware reader can still hold the hidden snapshot URL.
            // Keep both journal and links until that exact lifetime ends.
            pendingCleanup[journal.payload.transactionID] = (journal, activeRoot)
            overlayLock.unlock()
            return
        }
        overlayLock.unlock()
        // Only the hidden links named by this checksummed journal are removed.
        // No active path and no entry in current authority is a cleanup target.
        try removeTransactionMetadata(journal: journal, activeRoot: activeRoot)
    }

    private static func removeTransactionMetadata(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        afterJournalRemoval: () throws -> Void = {}
    ) throws {
        let transactionRoot = transactionRoot(
            activeRoot: activeRoot,
            transactionID: journal.payload.transactionID
        )
        let transactionsRoot = transactionRoot.deletingLastPathComponent()
        try validateExistingDirectoryChain(
            to: activeRoot,
            under: activeRoot,
            allowsMissing: false
        )
        let hasTransactionRoot = pathExists(transactionRoot)
        if hasTransactionRoot {
            try validateExistingDirectoryChain(
                to: transactionRoot,
                under: activeRoot,
                allowsMissing: false
            )
        }
        let journalURL = journalURL(activeRoot: activeRoot)
        let hasJournal = pathExists(journalURL)
        if hasJournal {
            guard regularFileSize(journalURL) != nil else {
                throw ArkFileContentActivationError.unsafePath(journalURL.fileSystemPath)
            }
            guard loadJournal(at: journalURL) == journal else {
                throw ArkFileContentActivationError.pendingForeignTransaction
            }
        }

        // Authority is already durable at every call site. Remove and fsync
        // the journal first so an interruption can leave only unreachable
        // orphan hard links, never a valid recovery journal missing snapshots.
        if hasJournal {
            try FileManager.default.removeItem(at: journalURL)
            try syncDirectory(activeRoot)
            try afterJournalRemoval()
        }
        if hasTransactionRoot {
            try FileManager.default.removeItem(at: transactionRoot)
            try syncDirectory(transactionsRoot)
        }
        try syncDirectory(activeRoot)
    }

    private static func installOverlay(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) {
        overlayLock.lock()
        activeOverlay = OverlayState(
            journal: journal,
            activeRoot: activeRoot.standardizedFileURL
        )
        overlayLock.unlock()
    }

    private static func clearOverlay(transactionID: UUID) {
        overlayLock.lock()
        if activeOverlay?.journal.payload.transactionID == transactionID {
            activeOverlay = nil
        }
        overlayLock.unlock()
    }

    private static func installRecoveryBlock(
        activeRoot: URL,
        downloadRootOverride: URL? = nil,
        freezeOrigin requestedFreezeOrigin: RecoveryFreezeOrigin = .observedJournal
    ) {
        let root = activeRoot.standardizedFileURL
        let rootPath = normalizedFileSystemPath(root)
        overlayLock.lock()
        let preservesObservedBlock = recoveryFrozenRootPath == rootPath
            && recoveryFreezeOriginState == .observedJournal
        overlayLock.unlock()
        // Once a journal was observed, a later failed pass must not weaken its
        // operation/root quarantine merely because the pathname disappeared.
        guard !preservesObservedBlock else { return }

        let journalURL = journalURL(activeRoot: root)
        let journalProbe = journalPathProbe(journalURL)
        let effectiveFreezeOrigin: RecoveryFreezeOrigin = journalProbe == .present
            ? .observedJournal
            : requestedFreezeOrigin
        let journal = journalProbe == .present ? loadJournal(at: journalURL) : nil
        let validatedState: OverlayState?
        if let journal, journal.isValid {
            do {
                // A checksummed journal can still carry unsafe or malformed
                // paths. Use an operation-level block only after the complete
                // recovery validator accepts it; otherwise block the root.
                let downloadRoot = try resolvedDownloadRoot(
                    activeRoot: root,
                    override: downloadRootOverride,
                    journal: journal
                )
                try validateJournalPaths(
                    journal,
                    activeRoot: root,
                    downloadRoot: downloadRoot
                )
                validatedState = OverlayState(journal: journal, activeRoot: root)
            } catch {
                validatedState = nil
            }
        } else {
            validatedState = nil
        }
        let hasValidLastCommit: Bool
        switch ArkFileInstalledContentAccess.commitRecordLoadState(at: root) {
        case .valid:
            hasValidLastCommit = true
        case .unavailable:
            // Protected-data and transient I/O failures must not revoke an
            // authority already validated in this process. The cached reader
            // still checks every exact committed path, file type, containment,
            // and byte count before granting access.
            hasValidLastCommit = ArkFileInstalledContentAccess
                .hasCachedValidAuthority(at: root)
        case .absent, .invalid:
            hasValidLastCommit = false
        }
        overlayLock.lock()
        if let validatedState {
            recoveryBlockedJournal = validatedState
            recoveryBlockedRootPath = nil
        } else {
            recoveryBlockedJournal = nil
            // An untrusted journal cannot identify a safe operation-level
            // quarantine. Preserve and freeze it, then let the checksummed
            // last commit constrain reads by exact path, type, and byte count.
            // Without that authority, retain the conservative root-wide deny.
            recoveryBlockedRootPath = hasValidLastCommit ? nil : rootPath
        }
        recoveryFrozenRootPath = rootPath
        if recoveryFreezeOriginState != .observedJournal
            || effectiveFreezeOrigin == .observedJournal {
            recoveryFreezeOriginState = effectiveFreezeOrigin
        }
        overlayLock.unlock()
    }

    /// A metadata-probe freeze is provisional: it says the journal pathname
    /// could not be inspected, not that a transaction was observed. Clear it
    /// only after the same process later proves definitive absence.
    private static func clearProbeUnavailableRecoveryBlock(activeRoot: URL) {
        let path = normalizedFileSystemPath(activeRoot)
        overlayLock.lock()
        guard recoveryFrozenRootPath == path,
              recoveryFreezeOriginState == .metadataProbeUnavailable else {
            overlayLock.unlock()
            return
        }
        recoveryBlockedJournal = nil
        if recoveryBlockedRootPath == path {
            recoveryBlockedRootPath = nil
        }
        recoveryFrozenRootPath = nil
        recoveryFreezeOriginState = nil
        overlayLock.unlock()
    }

    private static func clearRecoveryBlock(activeRoot: URL) {
        let path = normalizedFileSystemPath(activeRoot)
        overlayLock.lock()
        if recoveryBlockedJournal.map({
            normalizedFileSystemPath($0.activeRoot)
        }) == path {
            recoveryBlockedJournal = nil
        }
        if recoveryBlockedRootPath == path {
            recoveryBlockedRootPath = nil
        }
        if recoveryFrozenRootPath == path {
            recoveryFrozenRootPath = nil
            recoveryFreezeOriginState = nil
        }
        overlayLock.unlock()
    }

    private static func writeJournal(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ArkFileDurableAtomicWriter.write(
            try encoder.encode(journal),
            to: journalURL(activeRoot: activeRoot)
        )
    }

    private static func loadJournal(at url: URL) -> ArkFileContentActivationJournal? {
        guard regularFileSize(url) != nil,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArkFileContentActivationJournal.self, from: data)
    }

    private static func validateJournalPaths(
        _ journal: ArkFileContentActivationJournal,
        activeRoot: URL,
        downloadRoot: URL
    ) throws {
        guard journal.payload.activeRootRole == .managedContentActive,
              journal.payload.downloadRootRole == .managedContentDownloads,
              !journal.payload.operations.isEmpty,
              ArkFileInstalledContentAccess.isValidCommitRecord(journal.payload.newCommit),
              journal.payload.oldCommit.map(ArkFileInstalledContentAccess.isValidCommitRecord)
                ?? true else {
            throw ArkFileContentActivationError.invalidJournal
        }
        try validateExistingDirectoryChain(
            to: activeRoot,
            under: activeRoot,
            allowsMissing: false
        )
        try validateExistingDirectoryChain(
            to: downloadRoot,
            under: downloadRoot,
            allowsMissing: false
        )
        try validateSameVolume(activeRoot, downloadRoot)
        try validateExistingDirectoryChain(
            to: transactionRoot(
                activeRoot: activeRoot,
                transactionID: journal.payload.transactionID
            ),
            under: activeRoot,
            allowsMissing: true
        )

        let oldEntries = try uniqueCommitEntries(
            journal.payload.oldCommit?.payload.entries ?? []
        )
        let newEntries = try uniqueCommitEntries(
            journal.payload.newCommit.payload.entries
        )
        var relativePaths = Set<String>()
        var stagedRelativePaths = Set<String>()
        for operation in journal.payload.operations {
            let relativePath = try normalizedRelativePath(operation.relativePath)
            let pathKey = relativePath.lowercased()
            guard relativePath == operation.relativePath,
                  relativePaths.insert(pathKey).inserted,
                  ArkFileContentCompatibilityPlanner.groupID(for: relativePath).rawValue
                    == journal.payload.groupID,
                  operation.newEntry.relativePath == relativePath,
                  operation.newManifestEntry.normalizedRelativePath == relativePath,
                  operation.newEntry.byteCount == operation.newManifestEntry.sizeBytes,
                  operation.newEntry.sha256?.lowercased()
                    == operation.newManifestEntry.sha256.lowercased(),
                  newEntries[pathKey] == operation.newEntry else {
                throw ArkFileContentActivationError.invalidJournal
            }
            try operation.newManifestEntry.validate()
            try validateExistingDirectoryChain(
                to: activeRoot
                    .appendingPathComponent(relativePath)
                    .deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: true
            )
            if let committedOld = oldEntries[pathKey] {
                guard operation.oldEntry == nil || operation.oldEntry == committedOld else {
                    throw ArkFileContentActivationError.invalidJournal
                }
            } else if operation.oldEntry != nil {
                throw ArkFileContentActivationError.invalidJournal
            }
            if let backupRelativePath = operation.backupRelativePath {
                let normalizedBackupPath = try normalizedRelativePath(backupRelativePath)
                guard backupRelativePath == normalizedBackupPath,
                      normalizedBackupPath == "old/\(relativePath)",
                      operation.oldEntry != nil else {
                    throw ArkFileContentActivationError.invalidJournal
                }
            } else if operation.oldEntry != nil {
                throw ArkFileContentActivationError.invalidJournal
            }
            switch journal.payload.phase {
            case .preparing:
                guard operation.oldSnapshotSHA256 == nil else {
                    throw ArkFileContentActivationError.invalidJournal
                }
            case .readyToActivate:
                if operation.oldEntry != nil {
                    guard operation.oldSnapshotSHA256?.range(
                        of: "^[A-Fa-f0-9]{64}$",
                        options: .regularExpression
                    ) != nil else {
                        throw ArkFileContentActivationError.invalidJournal
                    }
                } else if operation.oldSnapshotSHA256 != nil {
                    throw ArkFileContentActivationError.invalidJournal
                }
            }
            if let stagedRelativePath = operation.stagedRelativePath {
                let normalizedStagedPath = try normalizedRelativePath(stagedRelativePath)
                guard normalizedStagedPath == stagedRelativePath,
                      stagedRelativePaths.insert(normalizedStagedPath.lowercased()).inserted else {
                    throw ArkFileContentActivationError.invalidJournal
                }
                let stagedURL = downloadRoot.appendingPathComponent(normalizedStagedPath)
                guard !sameFileSystemPath(stagedURL, downloadRoot),
                      isDescendant(stagedURL, of: downloadRoot) else {
                    throw ArkFileContentActivationError.unsafePath(stagedRelativePath)
                }
                try validateExistingDirectoryChain(
                    to: stagedURL.deletingLastPathComponent(),
                    under: downloadRoot,
                    allowsMissing: true
                )
            }
        }

        let newGroupEntries = journal.payload.newCommit.payload.entries.filter {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath).rawValue
                == journal.payload.groupID
        }
        guard newGroupEntries.count == journal.payload.operations.count,
              Set(newGroupEntries) == Set(journal.payload.operations.map(\.newEntry)) else {
            throw ArkFileContentActivationError.invalidJournal
        }
        let oldGroupPaths = Set((journal.payload.oldCommit?.payload.entries ?? []).compactMap {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath).rawValue
                == journal.payload.groupID ? $0.relativePath.lowercased() : nil
        })
        guard oldGroupPaths.isSubset(of: relativePaths) else {
            throw ArkFileContentActivationError.invalidJournal
        }
        let oldUnaffected = oldEntries.filter { !relativePaths.contains($0.key) }
        let newUnaffected = newEntries.filter { !relativePaths.contains($0.key) }
        guard oldUnaffected == newUnaffected else {
            throw ArkFileContentActivationError.invalidJournal
        }
    }

    private static func resolvedDownloadRoot(
        activeRoot: URL,
        override: URL?,
        journal: ArkFileContentActivationJournal
    ) throws -> URL {
        guard journal.payload.activeRootRole == .managedContentActive,
              journal.payload.downloadRootRole == .managedContentDownloads else {
            throw ArkFileContentActivationError.invalidJournal
        }
        if let override {
            return override.standardizedFileURL
        }
        let activeRoot = activeRoot.standardizedFileURL
        let contentRoot = activeRoot.deletingLastPathComponent()
        let arkFileRoot = contentRoot.deletingLastPathComponent()
        guard activeRoot.lastPathComponent == "active",
              contentRoot.lastPathComponent == "Content",
              arkFileRoot.lastPathComponent == "ArkFile" else {
            throw ArkFileContentActivationError.unsafePath(activeRoot.fileSystemPath)
        }
        return arkFileRoot.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func uniqueCommitEntries(
        _ entries: [ArkFileInstalledContentAccess.CommitEntry]
    ) throws -> [String: ArkFileInstalledContentAccess.CommitEntry] {
        var result = [String: ArkFileInstalledContentAccess.CommitEntry]()
        for entry in entries {
            let relativePath = try normalizedRelativePath(entry.relativePath)
            let key = relativePath.lowercased()
            guard relativePath == entry.relativePath, result[key] == nil else {
                throw ArkFileContentActivationError.invalidJournal
            }
            result[key] = entry
        }
        return result
    }

    private static func validateCandidates(
        _ candidates: [ArkFileContentActivationCandidate],
        groupID: String,
        activeRoot: URL,
        downloadRoot: URL
    ) throws {
        var destinationPaths = Set<String>()
        var stagedPaths = Set<String>()
        for candidate in candidates {
            let relativePath = try normalizedRelativePath(candidate.relativePath)
            guard relativePath == candidate.relativePath,
                  destinationPaths.insert(relativePath.lowercased()).inserted,
                  ArkFileContentCompatibilityPlanner.groupID(for: relativePath).rawValue
                    == groupID else {
                throw ArkFileContentActivationError.incompleteCompatibilityGroup(groupID)
            }
            try candidate.manifestEntry.validate()
            try validateExistingDirectoryChain(
                to: activeRoot
                    .appendingPathComponent(relativePath)
                    .deletingLastPathComponent(),
                under: activeRoot,
                allowsMissing: true
            )
            if let staged = candidate.stagedURL?.standardizedFileURL {
                let stagedRelativePath = try Self.relativePath(of: staged, under: downloadRoot)
                guard stagedPaths.insert(stagedRelativePath.lowercased()).inserted else {
                    throw ArkFileContentActivationError.incompleteCompatibilityGroup(groupID)
                }
                try validateExistingDirectoryChain(
                    to: staged.deletingLastPathComponent(),
                    under: downloadRoot,
                    allowsMissing: false
                )
                guard regularFileSize(staged) != nil else {
                    throw ArkFileContentActivationError.missingVerifiedReplacement(relativePath)
                }
            }
        }
    }

    private static func canonicalManifestEntry(
        _ entry: ArkFilePackageManifest.Entry,
        relativePath: String
    ) -> ArkFilePackageManifest.Entry {
        ArkFilePackageManifest.Entry(
            relativePath: relativePath,
            objectKey: entry.objectKey,
            sizeBytes: entry.sizeBytes,
            sha256: entry.sha256,
            mode: entry.mode,
            variantGroup: entry.variantGroup,
            variantLabel: entry.variantLabel,
            variantDefault: entry.variantDefault
        )
    }

    private static func relativePath(of child: URL, under root: URL) throws -> String {
        let child = child.standardizedFileURL
        let root = root.standardizedFileURL
        guard !sameFileSystemPath(child, root), isDescendant(child, of: root) else {
            throw ArkFileContentActivationError.unsafePath(child.fileSystemPath)
        }
        let childPath = normalizedFileSystemPath(child)
        let rootPath = normalizedFileSystemPath(root)
        return try normalizedRelativePath(
            String(childPath.dropFirst(rootPath.count + 1))
        )
    }

    private static func stagedURL(
        for operation: ArkFileContentActivationJournal.Operation,
        downloadRoot: URL
    ) throws -> URL {
        guard let persistedPath = operation.stagedRelativePath else {
            throw ArkFileContentActivationError.missingVerifiedReplacement(
                operation.relativePath
            )
        }
        let relativePath = try normalizedRelativePath(persistedPath)
        guard relativePath == persistedPath else {
            throw ArkFileContentActivationError.unsafePath(persistedPath)
        }
        let root = downloadRoot.standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard !sameFileSystemPath(url, root), isDescendant(url, of: root) else {
            throw ArkFileContentActivationError.unsafePath(persistedPath)
        }
        return url
    }

    private static func validateExistingDirectoryChain(
        to directory: URL,
        under root: URL,
        allowsMissing: Bool
    ) throws {
        let directory = directory.standardizedFileURL
        let root = root.standardizedFileURL
        guard isDescendant(directory, of: root) else {
            throw ArkFileContentActivationError.unsafePath(directory.fileSystemPath)
        }

        func requireDirectory(_ url: URL, mayBeMissing: Bool) throws -> Bool {
            var status = stat()
            // A trailing slash makes lstat follow a symlink on Darwin. Strip it
            // before every component check so a directory-shaped URL cannot
            // hide a link that escapes the trusted root.
            if Darwin.lstat(normalizedFileSystemPath(url), &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw ArkFileContentActivationError.unsafePath(url.fileSystemPath)
                }
                return true
            }
            if errno == ENOENT, mayBeMissing { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard try requireDirectory(root, mayBeMissing: allowsMissing) else { return }
        if sameFileSystemPath(directory, root) { return }
        let relative = String(
            normalizedFileSystemPath(directory)
                .dropFirst(normalizedFileSystemPath(root).count + 1)
        )
        var current = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty else {
                throw ArkFileContentActivationError.unsafePath(directory.fileSystemPath)
            }
            current.appendPathComponent(String(component), isDirectory: true)
            guard try requireDirectory(current, mayBeMissing: allowsMissing) else { return }
        }
    }

    private static func validateSameVolume(_ first: URL, _ second: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let firstID = try first.resourceValues(forKeys: keys).volumeIdentifier as? AnyHashable
        let secondID = try second.resourceValues(forKeys: keys).volumeIdentifier as? AnyHashable
        guard firstID != nil, firstID == secondID else {
            throw ArkFileContentActivationError.crossVolumeActivation
        }
    }

    private static func syncDirectoryTreeForOperations(
        _ operations: [ArkFileContentActivationJournal.Operation],
        root: URL,
        sourceRoot: URL? = nil
    ) throws {
        let root = root.standardizedFileURL
        var directories: Set<String> = [root.fileSystemPath]
        for operation in operations {
            try appendDirectoryAncestors(
                from: root
                    .appendingPathComponent(operation.relativePath)
                    .deletingLastPathComponent(),
                through: root,
                to: &directories
            )
            if let sourceRoot, operation.stagedRelativePath != nil {
                let normalizedSourceRoot = sourceRoot.standardizedFileURL
                let staged = try stagedURL(
                    for: operation,
                    downloadRoot: normalizedSourceRoot
                )
                guard staged != normalizedSourceRoot,
                      isDescendant(staged, of: normalizedSourceRoot) else {
                    throw ArkFileContentActivationError.unsafePath(
                        operation.stagedRelativePath ?? operation.relativePath
                    )
                }
                try appendDirectoryAncestors(
                    from: staged.deletingLastPathComponent(),
                    through: normalizedSourceRoot,
                    to: &directories
                )
            }
        }
        for path in directories.sorted(by: {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth > rhsDepth
        }) {
            try syncDirectory(URL(fileURLWithPath: path))
        }
    }

    private static func appendDirectoryAncestors(
        from directory: URL,
        through root: URL,
        to paths: inout Set<String>
    ) throws {
        var current = directory.standardizedFileURL
        let root = root.standardizedFileURL
        guard isDescendant(current, of: root) else {
            throw ArkFileContentActivationError.unsafePath(current.fileSystemPath)
        }
        while isDescendant(current, of: root) {
            paths.insert(current.fileSystemPath)
            // URL equality includes the directory-path hint. Production builds
            // construct `active` without that hint, while walking up from a
            // child naturally produces `active/`; compare canonical filesystem
            // identity so the walk stops at the trusted root, never above it.
            if sameFileSystemPath(current, root) { return }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent != current else {
                throw ArkFileContentActivationError.unsafePath(current.fileSystemPath)
            }
            current = parent
        }
        throw ArkFileContentActivationError.unsafePath(directory.fileSystemPath)
    }

    private static func syncSnapshotDirectoryTree(
        journal: ArkFileContentActivationJournal,
        activeRoot: URL
    ) throws {
        let transactionRoot = transactionRoot(
            activeRoot: activeRoot,
            transactionID: journal.payload.transactionID
        )
        var directories: Set<String> = [
            transactionRoot.fileSystemPath,
            transactionRoot.deletingLastPathComponent().fileSystemPath,
            activeRoot.fileSystemPath
        ]
        for operation in journal.payload.operations {
            guard let backupRelativePath = operation.backupRelativePath else { continue }
            var directory = transactionRoot
                .appendingPathComponent(backupRelativePath)
                .deletingLastPathComponent()
            while isDescendant(directory, of: transactionRoot) {
                directories.insert(directory.fileSystemPath)
                if sameFileSystemPath(directory, transactionRoot) { break }
                directory.deleteLastPathComponent()
            }
        }
        for path in directories.sorted(by: {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }) {
            try syncDirectory(URL(fileURLWithPath: path))
        }
    }

    private static func syncActiveFiles(
        _ operations: [ArkFileContentActivationJournal.Operation],
        root: URL
    ) throws {
        for operation in operations {
            try syncRegularFile(root.appendingPathComponent(operation.relativePath))
        }
    }

    private static func syncRegularFile(_ file: URL) throws {
        let descriptor = Darwin.open(file.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func sameFileIdentity(_ first: URL, _ second: URL) -> Bool {
        var firstStatus = stat()
        var secondStatus = stat()
        guard Darwin.lstat(normalizedFileSystemPath(first), &firstStatus) == 0,
              Darwin.lstat(normalizedFileSystemPath(second), &secondStatus) == 0,
              (firstStatus.st_mode & S_IFMT) == S_IFREG,
              (secondStatus.st_mode & S_IFMT) == S_IFREG else { return false }
        return firstStatus.st_dev == secondStatus.st_dev
            && firstStatus.st_ino == secondStatus.st_ino
    }

    private static func regularFileSize(_ url: URL) -> Int64? {
        var status = stat()
        guard Darwin.lstat(normalizedFileSystemPath(url), &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return status.st_size
    }

    /// Journal recovery must distinguish a definitive absence from metadata
    /// that is temporarily protected. A present non-regular pathname is still
    /// `present`; the journal validator will preserve and reject it.
    private static func journalPathProbe(_ url: URL) -> JournalPathProbeState {
        var status = stat()
        if Darwin.lstat(normalizedFileSystemPath(url), &status) == 0 {
            return .present
        }
        return errno == ENOENT ? .absent : .unavailable
    }

    /// Returns false only for a definitive absence. Permission/protection and
    /// other metadata errors conservatively count as present so callers do not
    /// mutate based on transient unreadability.
    private static func pathExists(_ url: URL) -> Bool {
        var status = stat()
        if Darwin.lstat(normalizedFileSystemPath(url), &status) == 0 { return true }
        return errno != ENOENT
    }

    private static func cryptographicallyMatches(
        _ url: URL,
        entry: ArkFilePackageManifest.Entry
    ) throws -> Bool {
        try cryptographicallyMatches(
            url,
            byteCount: entry.sizeBytes,
            sha256: entry.sha256
        )
    }

    private static func cryptographicallyMatches(
        _ url: URL,
        byteCount: Int64,
        sha256: String
    ) throws -> Bool {
        var status = stat()
        guard Darwin.lstat(normalizedFileSystemPath(url), &status) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size == byteCount else {
            return false
        }
        return try ArkFileContentFileVerifier.sha256HexDigest(of: url) == sha256.lowercased()
    }

    private static func committedInventoryMatches(
        _ record: ArkFileInstalledContentAccess.CommitRecord,
        activeRoot: URL
    ) throws -> Bool {
        for entry in record.payload.entries {
            let url = activeRoot.appendingPathComponent(entry.relativePath)
            if let sha256 = entry.sha256 {
                guard try cryptographicallyMatches(
                    url,
                    byteCount: entry.byteCount,
                    sha256: sha256
                ) else { return false }
                continue
            }
            var status = stat()
            guard Darwin.lstat(normalizedFileSystemPath(url), &status) == 0 else {
                if errno == ENOENT { return false }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size == entry.byteCount else { return false }
        }
        return true
    }

    private static func commitIdentity(
        _ record: ArkFileInstalledContentAccess.CommitRecord?
    ) -> String? {
        record.map { "\($0.payload.commitID.uuidString.lowercased()):\($0.checksum.lowercased())" }
    }

    private static func normalizedRelativePath(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasSuffix("/"),
              !normalized.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArkFileContentActivationError.unsafePath(path)
        }
        return normalized
    }

    private static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let childPath = normalizedFileSystemPath(child)
        let rootPath = normalizedFileSystemPath(root)
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func sameFileSystemPath(_ first: URL, _ second: URL) -> Bool {
        normalizedFileSystemPath(first) == normalizedFileSystemPath(second)
    }

    private static func normalizedFileSystemPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func journalURL(activeRoot: URL) -> URL {
        activeRoot.appendingPathComponent(journalFileName)
    }

    private static func transactionRoot(activeRoot: URL, transactionID: UUID) -> URL {
        activeRoot
            .appendingPathComponent(transactionsDirectoryName, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
    }
}

enum ArkFileDurableAtomicWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = Darwin.open(
            temporary.fileSystemPath,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ArkFileContentActivationError.durableWriteFailed(destination.fileSystemPath)
        }
        var writeError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    writeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if writeError == nil, Darwin.fsync(descriptor) != 0 {
            writeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Darwin.close(descriptor)
        if let writeError {
            try? FileManager.default.removeItem(at: temporary)
            throw writeError
        }
        guard Darwin.rename(temporary.fileSystemPath, destination.fileSystemPath) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ArkFileContentActivationError.durableWriteFailed(destination.fileSystemPath)
        }
        let directoryDescriptor = Darwin.open(parent.fileSystemPath, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw ArkFileContentActivationError.durableWriteFailed(destination.fileSystemPath)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw ArkFileContentActivationError.durableWriteFailed(destination.fileSystemPath)
        }
    }
}
