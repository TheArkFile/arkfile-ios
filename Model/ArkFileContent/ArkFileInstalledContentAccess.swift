// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CryptoKit
import Darwin
import Foundation

enum ArkFileManagedContentTierPolicy {
    static func tier(
        for relativePath: String,
        indexedTier: ArkFileContentTier? = nil,
        catalogTier: ArkFileContentTier? = nil,
        installedTier: ArkFileContentTier
    ) -> ArkFileContentTier {
        let key = relativePath.lowercased()
        if isKnownSharedEssentialsPath(key) {
            return .lite
        }
        return indexedTier ?? catalogTier ?? installedTier
    }

    static func isKnownSharedEssentialsPath(_ path: String) -> Bool {
        let key = path.lowercased()
        return key == "maps/poi/us_critical_places.sqlite"
            || key.hasPrefix("maps/detail/")
            || key.hasPrefix("maps/base/")
            || key.hasPrefix("maps/tiles/")
    }
}

/// A reader-priority lease for APIs that may lazily access a file after their
/// initializer returns (PDFKit and UIImage) or reopen it while doing bounded
/// synchronous work (ZIP extraction). The managed-reader token prevents an
/// activation or explicit deletion from replacing the pathname for the lease
/// lifetime; the authoritative lease separately pins an activation snapshot
/// when recovery is already serving the last committed generation from one.
final class ArkFileDirectReadLease: @unchecked Sendable {
    let url: URL
    private let authoritativeLease: ArkFileAuthoritativeReadLease
    private let managedReaderToken: ArkFileManagedContentReaderToken?
    private let releaseLock = NSLock()
    private var didRelease = false

    init(
        authoritativeLease: ArkFileAuthoritativeReadLease,
        managedReaderToken: ArkFileManagedContentReaderToken?
    ) {
        self.url = authoritativeLease.url
        self.authoritativeLease = authoritativeLease
        self.managedReaderToken = managedReaderToken
    }

    func release() {
        releaseLock.lock()
        guard !didRelease else {
            releaseLock.unlock()
            return
        }
        didRelease = true
        releaseLock.unlock()

        // Drop snapshot authority while the reader token still prevents a new
        // path mutation, then let a deferred activation/deletion proceed.
        authoritativeLease.release()
        managedReaderToken?.release()
    }

    deinit {
        release()
    }
}

/// The durable, entirely local authority for reading installed ArkFile content.
///
/// Ordinary StoreKit and acquisition-token state intentionally do not
/// participate here. A successful installer commit remains readable without an
/// account, network, token, keychain entry, trustworthy clock, or current
/// entitlement snapshot. Commerce state controls future acquisition, not reads
/// from an already verified install.
enum ArkFileInstalledContentAccess {
    nonisolated static let commitFileName = ".arkfile-install-commit.json"

    enum Decision: Equatable, Sendable {
        case unmanaged
        case committed(tier: ArkFileContentTier)
        case uncommittedManagedContent
        case missing

        var canRead: Bool {
            switch self {
            case .unmanaged, .committed:
                true
            case .uncommittedManagedContent, .missing:
                false
            }
        }
    }

    /// Exact artifact identity carried by a checksummed install commit.
    ///
    /// Local reading intentionally tolerates legacy entries without a hash,
    /// but peer redistribution needs a stronger boundary: the committed hash
    /// and byte count must match the reviewed license projection exactly.
    struct CommittedArtifactIdentity: Equatable, Sendable {
        let byteCount: Int64
        let sha256: String
    }

    /// Both values come from one immutable cached authority snapshot. ZIM
    /// registration must not pair one commit's anchor identity with another
    /// commit's multipart-group fingerprint if activation reloads the cache
    /// between two otherwise independent queries.
    struct CommittedSourceIdentity: Equatable, Sendable {
        let artifact: CommittedArtifactIdentity?
        let compatibilityGroupSHA256: String?
    }

    private struct CompatibilityGroupFingerprintPayload: Encodable {
        struct Member: Encodable {
            let relativePath: String
            let byteCount: Int64
            let sha256: String?
        }

        let formatVersion: Int
        let groupID: String
        let hashlessCommitID: UUID?
        let members: [Member]
    }

    struct ManifestProvenance: Codable, Equatable, Hashable, Sendable {
        let manifestID: String
        let semanticFingerprint: String
    }

    struct ManifestProjectionBinding: Codable, Equatable, Sendable {
        let projectionHash: String
        let manifests: [ManifestProvenance]
    }

    struct CommitEntry: Codable, Equatable, Hashable, Sendable {
        let relativePath: String
        let tier: String
        let byteCount: Int64
        let sha256: String?
        let manifestProvenance: ManifestProvenance?

        init(
            relativePath: String,
            tier: String,
            byteCount: Int64,
            sha256: String?,
            manifestProvenance: ManifestProvenance? = nil
        ) {
            self.relativePath = relativePath
            self.tier = tier
            self.byteCount = byteCount
            self.sha256 = sha256
            self.manifestProvenance = manifestProvenance
        }

        var contentTier: ArkFileContentTier {
            ArkFileContentTier.iOSInstallableTier(named: tier) ?? .lite
        }
    }

    struct CommitPayload: Codable, Equatable, Sendable {
        let formatVersion: Int
        let product: String
        let commitID: UUID
        let committedAt: String
        let installedTier: String
        /// Present only when an explicit user deletion has durably made this
        /// managed root empty. Keeping that state in the checksummed authority
        /// prevents legacy-recovery heuristics from adopting orphan bytes if
        /// cleanup is interrupted after the authority change.
        let authorityState: String?
        /// Exact managed paths explicitly removed by the user. If physical
        /// cleanup leaves an orphan, a later authorized reinstall may replace
        /// that path without treating it as an ambiguous user import.
        let explicitlyRemovedPaths: [String]?
        /// Audit binding for the per-entry manifest provenance carried by this
        /// exact checksummed generation. The manifest array is derived from
        /// entries; it is never an independent source of authority.
        let manifestProjection: ManifestProjectionBinding?
        let entries: [CommitEntry]

        init(
            formatVersion: Int,
            product: String,
            commitID: UUID,
            committedAt: String,
            installedTier: String,
            authorityState: String? = nil,
            explicitlyRemovedPaths: [String]? = nil,
            manifestProjection: ManifestProjectionBinding? = nil,
            entries: [CommitEntry]
        ) {
            self.formatVersion = formatVersion
            self.product = product
            self.commitID = commitID
            self.committedAt = committedAt
            self.installedTier = installedTier
            self.authorityState = authorityState
            self.explicitlyRemovedPaths = explicitlyRemovedPaths
            self.manifestProjection = manifestProjection
            self.entries = entries
        }
    }

    struct CommitRecord: Codable, Equatable, Sendable {
        let payload: CommitPayload
        let checksum: String
    }

    enum CommitRecordLoadState {
        case absent
        case valid(CommitRecord)
        case invalid
        case unavailable
    }

    struct ManagedRootCandidate: Sendable {
        enum Scope: Equatable, Sendable {
            /// A directory reserved for ArkFile-managed content.
            case dedicated
            /// A historical root that can also contain user-imported files.
            case sharedDocuments
        }

        let url: URL
        let scope: Scope
        let canRecoverMarkerlessInstalledState: Bool

        init(
            url: URL,
            scope: Scope,
            canRecoverMarkerlessInstalledState: Bool = false
        ) {
            self.url = url
            self.scope = scope
            self.canRecoverMarkerlessInstalledState = canRecoverMarkerlessInstalledState
        }
    }

    private enum AuthorityProvenance: Equatable, Sendable {
        /// Loaded from a valid checksummed install commit already present on
        /// disk. Only this provenance may bridge transient commit-file I/O.
        case durableCommit
        /// Reconstructed from conservative legacy/installer evidence. The
        /// record is intentionally hashless and is not prior durable authority.
        case synthesizedFallback
        case invalid
    }

    private enum CommitLoadDisposition: Equatable, Sendable {
        case absent
        case valid
        case invalid
        case unavailable
    }

    private struct RootSnapshot: Sendable {
        let lexicalRootPath: String
        let resolvedRootPath: String
        let commitID: UUID?
        let authorityProvenance: AuthorityProvenance
        let commitLoadDisposition: CommitLoadDisposition
        let defaultTier: ArkFileContentTier
        let entriesByPath: [String: CommitEntry]
        let managedPaths: Set<String>
        let managesUnknownPaths: Bool
        let isValid: Bool

        func decision(for url: URL) -> Decision? {
            let lexicalPath = Self.normalizedPath(url, resolvingSymlinks: false)
            guard Self.isDescendant(lexicalPath, of: lexicalRootPath) else {
                return nil
            }
            if lexicalPath == lexicalRootPath {
                return isValid ? .committed(tier: defaultTier) : .uncommittedManagedContent
            }
            if ArkFileContentActivationCoordinator.isPathBeingReplaced(
                url,
                cachedCommitID: commitID
            ) {
                // During a group swap the active path may already contain the
                // new bytes while the old commit is still authoritative. Older
                // Boolean-only callers fail closed; resolver-aware readers are
                // directed to the all-old hard-link snapshot instead.
                return .uncommittedManagedContent
            }
            let relativePath = String(lexicalPath.dropFirst(lexicalRootPath.count + 1)).lowercased()
            let isKnownManagedPath = managesUnknownPaths
                || managedPaths.contains(relativePath)
                || managedPaths.contains(where: { $0.hasPrefix(relativePath + "/") })
            guard isKnownManagedPath else {
                // Historical installs could mark the Documents container. Files
                // outside the exact managed inventory remain user imports.
                return .unmanaged
            }
            guard isValid else {
                return .uncommittedManagedContent
            }

            // A link inside a paid root must not turn an otherwise managed path
            // into an unmanaged file outside that root.
            let resolvedPath = Self.normalizedPath(url, resolvingSymlinks: true)
            guard Self.isDescendant(resolvedPath, of: resolvedRootPath) else {
                return .uncommittedManagedContent
            }

            if let entry = entriesByPath[relativePath] {
                guard Self.regularFileMatchesCommit(url, entry: entry) else {
                    return .missing
                }
                return .committed(tier: entry.contentTier)
            }

            // Directory checks are occasionally made while a reader walks to a
            // committed child. They are safe only when the commit contains that
            // exact subtree.
            if managedPaths.contains(where: { $0.hasPrefix(relativePath + "/") }),
               Self.isDirectory(url) {
                return .committed(tier: defaultTier)
            }
            return .uncommittedManagedContent
        }

        func resolvedURLForReading(_ url: URL) -> URL? {
            if let overlay = ArkFileContentActivationCoordinator.overlayResolution(
                for: url,
                cachedCommitID: commitID
            ) {
                return overlay.url
            }
            return decision(for: url)?.canRead == true ? url : nil
        }

        func committedArtifactIdentity(for url: URL) -> CommittedArtifactIdentity? {
            let lexicalPath = Self.normalizedPath(url, resolvingSymlinks: false)
            guard lexicalPath != lexicalRootPath,
                  Self.isDescendant(lexicalPath, of: lexicalRootPath),
                  isValid,
                  !ArkFileContentActivationCoordinator.isPathBeingReplaced(
                    url,
                    cachedCommitID: commitID
                  ) else {
                return nil
            }
            let relativePath = String(
                lexicalPath.dropFirst(lexicalRootPath.count + 1)
            ).lowercased()
            guard let entry = entriesByPath[relativePath],
                  let sha256 = entry.sha256?.lowercased(),
                  Self.regularFileMatchesCommit(url, entry: entry) else {
                return nil
            }
            let resolvedPath = Self.normalizedPath(url, resolvingSymlinks: true)
            guard Self.isDescendant(resolvedPath, of: resolvedRootPath) else {
                return nil
            }
            return CommittedArtifactIdentity(
                byteCount: entry.byteCount,
                sha256: sha256
            )
        }

        /// Fingerprints every member of the authoritative compatibility group.
        /// CoreKiwix opens split ZIM siblings lazily, so the anchor file alone
        /// cannot identify a generation when a later `.zimab` fragment changes.
        /// Hashless legacy authority includes its commit identity as a safe
        /// fallback; fully hashed groups remain stable across unrelated commits.
        func committedCompatibilityGroupFingerprint(for url: URL) -> String? {
            let lexicalPath = Self.normalizedPath(url, resolvingSymlinks: false)
            guard lexicalPath != lexicalRootPath,
                  Self.isDescendant(lexicalPath, of: lexicalRootPath),
                  isValid else {
                return nil
            }
            let relativePath = String(
                lexicalPath.dropFirst(lexicalRootPath.count + 1)
            ).lowercased()
            let groupID = ArkFileContentCompatibilityPlanner.groupID(
                for: relativePath
            )
            let entries = entriesByPath.values.filter {
                ArkFileContentCompatibilityPlanner.groupID(
                    for: $0.relativePath
                ) == groupID
            }.sorted {
                let lhs = ArkFileContentCompatibilityPlanner.canonicalIdentityPath(
                    $0.relativePath
                )
                let rhs = ArkFileContentCompatibilityPlanner.canonicalIdentityPath(
                    $1.relativePath
                )
                return lhs == rhs ? $0.relativePath < $1.relativePath : lhs < rhs
            }
            guard !entries.isEmpty else { return nil }
            let containsHashlessEntry = entries.contains { $0.sha256 == nil }
            let payload = CompatibilityGroupFingerprintPayload(
                formatVersion: 1,
                groupID: groupID.rawValue,
                hashlessCommitID: containsHashlessEntry ? commitID : nil,
                members: entries.map {
                    CompatibilityGroupFingerprintPayload.Member(
                        relativePath:
                            ArkFileContentCompatibilityPlanner
                                .canonicalIdentityPath($0.relativePath),
                        byteCount: $0.byteCount,
                        sha256: $0.sha256?.lowercased()
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let encoded = try? encoder.encode(payload) else { return nil }
            return SHA256.hash(data: encoded)
                .map { String(format: "%02x", $0) }
                .joined()
        }

        func committedSourceIdentity(for url: URL) -> CommittedSourceIdentity? {
            let lexicalPath = Self.normalizedPath(url, resolvingSymlinks: false)
            guard lexicalPath != lexicalRootPath,
                  Self.isDescendant(lexicalPath, of: lexicalRootPath),
                  isValid else {
                return nil
            }
            return CommittedSourceIdentity(
                artifact: committedArtifactIdentity(for: url),
                compatibilityGroupSHA256: committedCompatibilityGroupFingerprint(
                    for: url
                )
            )
        }

        func readLease(for url: URL) -> ArkFileAuthoritativeReadLease? {
            if let overlayLease = ArkFileContentActivationCoordinator.acquireReadLease(
                for: url,
                cachedCommitID: commitID
            ) {
                return overlayLease
            }
            guard decision(for: url)?.canRead == true else { return nil }
            return ArkFileAuthoritativeReadLease(url: url, transactionID: nil)
        }

        func overlayTier(for url: URL) -> ArkFileContentTier? {
            ArkFileContentActivationCoordinator.overlayResolution(
                for: url,
                cachedCommitID: commitID
            )?.tier
        }

        private static func regularFileMatchesCommit(_ url: URL, entry: CommitEntry) -> Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.fileSystemPath
            ),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                return false
            }
            guard entry.byteCount >= 0 else { return false }
            return size == entry.byteCount
        }

        private static func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        private static func isDescendant(_ path: String, of root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }

        private static func normalizedPath(_ url: URL, resolvingSymlinks: Bool) -> String {
            let normalizedURL = resolvingSymlinks
                ? url.resolvingSymlinksInPath().standardizedFileURL
                : url.standardizedFileURL
            var path = normalizedURL.fileSystemPath
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedRoots: [RootSnapshot] = []
    private nonisolated(unsafe) static var didBootstrap = false
    private nonisolated(unsafe) static var authorityGeneration: UInt64 = 0
    static var localAuthorityGeneration: UInt64 {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return authorityGeneration
    }

    /// Loads and caches the local access inventory. This is intentionally
    /// synchronous so startup can establish local-read truth before StoreKit
    /// reconciliation starts.
    static func bootstrap() {
        if let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot() {
            ArkFileContentReplacementStore.loadRecoveryBarrier(at: root)
        }
        installSnapshot(from: defaultCandidates())
    }

    static func reloadAfterContentCommit() {
        installSnapshot(from: defaultCandidates())
    }

    /// Refreshes metadata after protected data becomes available or the app
    /// returns to the foreground. A previously valid in-memory snapshot is
    /// retained when a transient read produces an invalid replacement; each
    /// file is still checked for existence/type/size when it is opened.
    static func reloadForForeground() {
        reloadForForeground(from: defaultCandidates())
    }

    private static func reloadForForeground(from candidates: [ManagedRootCandidate]) {
        // Do not publish a snapshot planned concurrently with activation or
        // deletion. The active writer will reload the exact authority it
        // commits; a later foreground pass can retry normally.
        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else { return }
        defer { writerToken.release() }
        let refreshed = candidates.compactMap {
            loadSnapshot(candidate: $0, heldWriterToken: writerToken)
        }
        cacheLock.lock()
        let previousByRoot = Dictionary(
            cachedRoots.map { ($0.lexicalRootPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var merged = refreshed.map { candidate in
            // Only transient I/O may retain an earlier exact durable commit.
            // Missing or invalid on-disk authority must not fall back to cache,
            // and synthesized legacy recovery is never equivalent provenance.
            if candidate.commitLoadDisposition == .unavailable,
               let previous = previousByRoot[candidate.lexicalRootPath],
               previous.isValid,
               previous.authorityProvenance == .durableCommit {
                return previous
            }
            return candidate
        }
        let refreshedRoots = Set(refreshed.map(\.lexicalRootPath))
        merged.append(contentsOf: cachedRoots.filter {
            $0.isValid && !refreshedRoots.contains($0.lexicalRootPath)
        })
        cachedRoots = merged
        authorityGeneration &+= 1
        didBootstrap = true
        cacheLock.unlock()
    }

    /// Whether this process already established a checksummed local authority
    /// for this exact root. Recovery may consult this only when the commit file
    /// is temporarily unavailable: each subsequent read still has to satisfy
    /// the cached commit's exact path, regular-file, containment, and size
    /// checks. Missing or checksum-invalid authority never falls back here.
    static func hasCachedValidAuthority(at root: URL) -> Bool {
        let rootPath = normalizedPath(root, resolvingSymlinks: false)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedRoots.contains {
            $0.lexicalRootPath == rootPath
                && $0.isValid
                && $0.commitID != nil
                && $0.authorityProvenance == .durableCommit
        }
    }

    static func decision(for url: URL) -> Decision {
        guard !ArkFileContentReplacementStore.blocksRead(url) else { return .uncommittedManagedContent }
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            if let decision = root.decision(for: url) {
                return decision
            }
        }
        return .unmanaged
    }

    static func canRead(_ url: URL) -> Bool {
        decision(for: url).canRead
    }

    /// Returns a manifest-verified identity only for an exact file in the
    /// current checksummed commit. Hashless legacy/adopted entries remain
    /// readable locally but deliberately cannot authorize Local Sharing.
    static func committedArtifactIdentity(for url: URL) -> CommittedArtifactIdentity? {
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.committedArtifactIdentity(for: url)
            }
        }
        return nil
    }

    /// Generation identity for the complete committed compatibility group.
    /// Unlike `committedArtifactIdentity`, this deliberately remains available
    /// while an activation overlay serves the old group snapshot: the cached
    /// root is still the old checksummed authority until the new commit lands.
    static func committedCompatibilityGroupFingerprint(for url: URL) -> String? {
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.committedCompatibilityGroupFingerprint(for: url)
            }
        }
        return nil
    }

    /// Deterministic expected fingerprint for a fully hashed projected group.
    /// The tier is intentionally absent from the fingerprint contract.
    static func compatibilityGroupFingerprint(
        anchorRelativePath: String,
        members: [CommitEntry]
    ) -> String? {
        guard !members.isEmpty,
              members.allSatisfy({ $0.sha256 != nil }),
              members.allSatisfy({
                  ArkFileContentCompatibilityPlanner.groupID(
                      for: $0.relativePath
                  ) == ArkFileContentCompatibilityPlanner.groupID(
                      for: anchorRelativePath
                  )
              }) else {
            return nil
        }
        let groupID = ArkFileContentCompatibilityPlanner.groupID(
            for: anchorRelativePath
        )
        let sorted = members.sorted {
            let lhs = ArkFileContentCompatibilityPlanner.canonicalIdentityPath(
                $0.relativePath
            )
            let rhs = ArkFileContentCompatibilityPlanner.canonicalIdentityPath(
                $1.relativePath
            )
            return lhs == rhs ? $0.relativePath < $1.relativePath : lhs < rhs
        }
        let payload = CompatibilityGroupFingerprintPayload(
            formatVersion: 1,
            groupID: groupID.rawValue,
            hashlessCommitID: nil,
            members: sorted.map {
                CompatibilityGroupFingerprintPayload.Member(
                    relativePath:
                        ArkFileContentCompatibilityPlanner
                            .canonicalIdentityPath($0.relativePath),
                    byteCount: $0.byteCount,
                    sha256: $0.sha256?.lowercased()
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(payload) else { return nil }
        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Atomically projects the anchor and full compatibility-group identity
    /// from one cached commit generation. The physical file stat remains the
    /// caller's responsibility because it must describe the resolved lease URL.
    static func committedSourceIdentity(for url: URL) -> CommittedSourceIdentity? {
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.committedSourceIdentity(for: url)
            }
        }
        return nil
    }

    /// Returns the physical URL that is authoritative for this read. Most of
    /// the time it is the input URL. During the bounded activation of a group,
    /// it points at the preserved all-old snapshot until the new checksummed
    /// commit becomes current.
    static func resolvedURLForReading(_ url: URL) -> URL? {
        guard !ArkFileContentReplacementStore.blocksRead(url) else { return nil }
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.resolvedURLForReading(url)
            }
        }
        return url
    }

    static func acquireReadLease(for url: URL) -> ArkFileAuthoritativeReadLease? {
        guard !ArkFileContentReplacementStore.blocksRead(url) else { return nil }
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.readLease(for: url)
            }
        }
        return ArkFileAuthoritativeReadLease(url: url, transactionID: nil)
    }

    /// Acquires reader priority before resolving the authoritative URL. Managed
    /// content therefore cannot be swapped or explicitly deleted between the
    /// access decision and a lazy reader's first/last physical read. Unmanaged
    /// user imports do not unnecessarily block ArkFile pack activation.
    static func acquireDirectReadLease(for url: URL) -> ArkFileDirectReadLease? {
        guard !ArkFileContentReplacementStore.blocksRead(url) else { return nil }
        let managedReaderToken: ArkFileManagedContentReaderToken?
        if isManaged(url) {
            guard let token = ArkFileManagedContentConcurrencyGate
                .tryBeginDirectMediaRead() else {
                return nil
            }
            managedReaderToken = token
        } else {
            managedReaderToken = nil
        }
        guard let authoritativeLease = acquireReadLease(for: url) else {
            managedReaderToken?.release()
            return nil
        }
        return ArkFileDirectReadLease(
            authoritativeLease: authoritativeLease,
            managedReaderToken: managedReaderToken
        )
    }

    static func isManaged(_ url: URL) -> Bool {
        switch decision(for: url) {
        case .unmanaged:
            false
        case .committed, .uncommittedManagedContent, .missing:
            true
        }
    }

    static func requiredTier(for url: URL) -> ArkFileContentTier? {
        ensureBootstrapped()
        cacheLock.lock()
        let roots = cachedRoots
        cacheLock.unlock()
        for root in roots {
            if let tier = root.overlayTier(for: url) {
                return tier
            }
        }
        switch decision(for: url) {
        case .committed(let tier):
            return tier
        case .unmanaged, .uncommittedManagedContent, .missing:
            return nil
        }
    }

    /// Writes the sole authoritative activation record after the installer has
    /// verified every selected file. File hashes are carried forward from the
    /// verified manifest; the commit itself is checksummed independently.
    static func writeCommit(
        at root: URL,
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) throws {
        let entries = try committedEntries(at: root, manifest: manifest, catalog: catalog)
        guard !entries.isEmpty else {
            throw ArkFileContentError.emptyContentManifest
        }
        let payload = CommitPayload(
            formatVersion: 1,
            product: "ArkFile",
            commitID: UUID(),
            committedAt: ISO8601DateFormatter().string(from: Date()),
            installedTier: (ArkFileContentTier.iOSInstallableTier(named: manifest.tier) ?? .lite).rawValue,
            entries: entries
        )
        let record = CommitRecord(payload: payload, checksum: try checksum(for: payload))
        try writeRecord(record, at: root)
        reloadAfterContentCommit()
    }

    static func currentCommitRecord(at root: URL) -> CommitRecord? {
        guard case .valid(let record) = commitRecordLoadState(at: root) else {
            return nil
        }
        return record
    }

    static func currentAuthorityExactlyMatches(
        _ expected: CommitRecord,
        at root: URL
    ) -> Bool {
        currentCommitRecord(at: root) == expected
    }

    static func commitRecordLoadState(at root: URL) -> CommitRecordLoadState {
        loadCommitRecordState(at: root.appendingPathComponent(commitFileName))
    }

    static func makeMergedCommitRecord(
        previous: CommitRecord?,
        replacingGroupPaths: Set<String>,
        with replacementEntries: [CommitEntry],
        installedTier: ArkFileContentTier,
        trustedProjectionHash: String? = nil,
        explicitlyRemovingPaths: Set<String> = []
    ) throws -> CommitRecord {
        let normalizedReplacing = Set(replacingGroupPaths.map { $0.lowercased() })
        var entriesByPath = Dictionary(
            (previous?.payload.entries ?? []).compactMap { entry -> (String, CommitEntry)? in
                let key = entry.relativePath.lowercased()
                return normalizedReplacing.contains(key) ? nil : (key, entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for entry in replacementEntries {
            guard normalizedRelativePath(entry.relativePath) != nil else {
                throw ArkFileContentActivationError.unsafePath(entry.relativePath)
            }
            entriesByPath[entry.relativePath.lowercased()] = entry
        }
        let replacementKeys = Set(replacementEntries.map { $0.relativePath.lowercased() })
        var removedPaths = Set(previous?.payload.explicitlyRemovedPaths ?? [])
        removedPaths = Set(removedPaths.map { $0.lowercased() })
        removedPaths.subtract(replacementKeys)
        removedPaths.formUnion(explicitlyRemovingPaths.map { $0.lowercased() })
        let entries = entriesByPath.values.sorted {
            $0.relativePath.lowercased() < $1.relativePath.lowercased()
        }
        guard !entries.isEmpty, entriesAreValid(entries) else {
            throw ArkFileContentError.emptyContentManifest
        }
        let manifestProjection = try manifestProjectionBinding(
            for: entries,
            projectionHash: trustedProjectionHash
                ?? previous?.payload.manifestProjection?.projectionHash
        )
        let payload = CommitPayload(
            formatVersion: 1,
            product: "ArkFile",
            commitID: UUID(),
            committedAt: ISO8601DateFormatter().string(from: Date()),
            installedTier: installedTier.rawValue,
            explicitlyRemovedPaths: removedPaths.isEmpty ? nil : removedPaths.sorted(),
            manifestProjection: manifestProjection,
            entries: entries
        )
        return CommitRecord(payload: payload, checksum: try checksum(for: payload))
    }

    /// Creates a valid, checksummed authority that intentionally grants access
    /// to no managed payload. This is distinct from a missing commit: missing
    /// commits can be reconstructed from redundant legacy evidence, while an
    /// explicit-empty commit records durable user deletion intent.
    static func makeExplicitEmptyCommitRecord(
        installedTier: ArkFileContentTier,
        explicitlyRemovedPaths: Set<String> = []
    ) throws -> CommitRecord {
        let payload = CommitPayload(
            formatVersion: 1,
            product: "ArkFile",
            commitID: UUID(),
            committedAt: ISO8601DateFormatter().string(from: Date()),
            installedTier: installedTier.rawValue,
            authorityState: "explicitly-empty",
            explicitlyRemovedPaths: explicitlyRemovedPaths.isEmpty
                ? nil
                : explicitlyRemovedPaths.map { $0.lowercased() }.sorted(),
            entries: []
        )
        return CommitRecord(payload: payload, checksum: try checksum(for: payload))
    }

    static func writeCommitRecordDurably(_ record: CommitRecord, at root: URL) throws {
        guard isValidCommitRecord(record) else {
            throw ArkFileContentActivationError.invalidJournal
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ArkFileDurableAtomicWriter.write(
            try encoder.encode(record),
            to: root.appendingPathComponent(commitFileName)
        )
    }

    /// Installs metadata-only authority and reconciles an atomic-writer error
    /// that may have been reported after the rename became durable.
    static func installCommitRecordDurablyAndReload(
        _ record: CommitRecord,
        at root: URL
    ) throws {
        do {
            try writeCommitRecordDurably(record, at: root)
        } catch {
            guard currentAuthorityExactlyMatches(record, at: root) else {
                throw error
            }
        }
        guard currentAuthorityExactlyMatches(record, at: root) else {
            throw ArkFileContentActivationError.invalidJournal
        }
        reloadAfterContentCommit()
    }

    static func removeCommitRecordDurably(at root: URL) throws {
        let commitURL = root.appendingPathComponent(commitFileName)
        if Darwin.unlink(commitURL.fileSystemPath) != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = Darwin.open(root.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw ArkFileContentActivationError.durableWriteFailed(commitURL.fileSystemPath)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ArkFileContentActivationError.durableWriteFailed(commitURL.fileSystemPath)
        }
    }

    static func decisionForTesting(
        _ url: URL,
        candidates: [ManagedRootCandidate]
    ) -> Decision {
        for root in candidates.compactMap(loadSnapshot) {
            if let decision = root.decision(for: url) {
                return decision
            }
        }
        return .unmanaged
    }

    static func committedArtifactIdentityForTesting(
        _ url: URL,
        candidates: [ManagedRootCandidate]
    ) -> CommittedArtifactIdentity? {
        for root in candidates.compactMap(loadSnapshot) {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.committedArtifactIdentity(for: url)
            }
        }
        return nil
    }

    static func committedCompatibilityGroupFingerprintForTesting(
        _ url: URL,
        candidates: [ManagedRootCandidate]
    ) -> String? {
        for root in candidates.compactMap(loadSnapshot) {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.committedCompatibilityGroupFingerprint(for: url)
            }
        }
        return nil
    }

    static func resolvedURLForReadingForTesting(
        _ url: URL,
        candidates: [ManagedRootCandidate]
    ) -> URL? {
        for root in candidates.compactMap(loadSnapshot) {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.resolvedURLForReading(url)
            }
        }
        return url
    }

    static func readLeaseForTesting(
        _ url: URL,
        candidates: [ManagedRootCandidate]
    ) -> ArkFileAuthoritativeReadLease? {
        for root in candidates.compactMap(loadSnapshot) {
            let lexicalPath = url.standardizedFileURL.fileSystemPath
            if lexicalPath == root.lexicalRootPath
                || lexicalPath.hasPrefix(root.lexicalRootPath + "/") {
                return root.readLease(for: url)
            }
        }
        return ArkFileAuthoritativeReadLease(url: url, transactionID: nil)
    }

    static func installSnapshotsForTesting(_ candidates: [ManagedRootCandidate]) {
        installSnapshot(from: candidates)
    }

    static func reloadForForegroundForTesting(_ candidates: [ManagedRootCandidate]) {
        reloadForForeground(from: candidates)
    }

    static func resetCachedSnapshotsForTesting() {
        cacheLock.lock()
        cachedRoots = []
        authorityGeneration &+= 1
        didBootstrap = false
        cacheLock.unlock()
    }

    static func makeCommitRecordForTesting(
        installedTier: ArkFileContentTier,
        entries: [CommitEntry],
        trustedProjectionHash: String? = nil
    ) throws -> CommitRecord {
        let sortedEntries = entries.sorted {
            $0.relativePath.lowercased() < $1.relativePath.lowercased()
        }
        let payload = CommitPayload(
            formatVersion: 1,
            product: "ArkFile",
            commitID: UUID(),
            committedAt: "2026-07-18T00:00:00Z",
            installedTier: installedTier.rawValue,
            manifestProjection: try manifestProjectionBinding(
                for: sortedEntries,
                projectionHash: trustedProjectionHash
            ),
            entries: sortedEntries
        )
        return CommitRecord(payload: payload, checksum: try checksum(for: payload))
    }

    static func writeCommitRecordForTesting(_ record: CommitRecord, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ArkFileDurableAtomicWriter.write(
            try encoder.encode(record),
            to: root.appendingPathComponent(commitFileName)
        )
    }

    private static func writeRecord(_ record: CommitRecord, at root: URL) throws {
        try writeCommitRecordDurably(record, at: root)
    }

    private static func ensureBootstrapped() {
        cacheLock.lock()
        let needsBootstrap = !didBootstrap
        cacheLock.unlock()
        if needsBootstrap {
            bootstrap()
        }
    }

    private static func installSnapshot(from candidates: [ManagedRootCandidate]) {
        let snapshots = candidates.compactMap(loadSnapshot)
        cacheLock.lock()
        cachedRoots = snapshots
        authorityGeneration &+= 1
        didBootstrap = true
        cacheLock.unlock()
    }

    private static func loadSnapshot(candidate: ManagedRootCandidate) -> RootSnapshot? {
        loadSnapshot(candidate: candidate, heldWriterToken: nil)
    }

    private static func loadSnapshot(
        candidate: ManagedRootCandidate,
        heldWriterToken: ArkFileManagedContentWriterToken?
    ) -> RootSnapshot? {
        let root = candidate.url.standardizedFileURL
        guard isDirectory(root) else {
            // Reserve the canonical active namespace even before its directory
            // is created. Otherwise first-install files could briefly fall
            // through as unmanaged between startup and the final commit reload.
            return candidate.canRecoverMarkerlessInstalledState
                ? invalidSnapshot(
                    root: root,
                    scope: candidate.scope,
                    commitLoadDisposition: .absent
                )
                : nil
        }
        let commitURL = root.appendingPathComponent(commitFileName)
        let commitState = loadCommitRecordState(at: commitURL)
        switch commitState {
        case .valid(let record):
            return snapshot(
                root: root,
                record: record,
                scope: candidate.scope,
                authorityProvenance: .durableCommit,
                commitLoadDisposition: .valid
            )
        case .invalid, .unavailable:
            // The commit is deliberately not a single point of failure for an
            // emergency library. If independent local evidence proves that the
            // installer completed, rebuild the small record without consulting
            // StoreKit or moving, deleting, re-downloading, or re-hashing pack
            // payloads. This snapshot remains explicitly synthesized in this
            // pass even if a later, unfrozen pass persists and reloads it.
            let disposition = commitLoadDisposition(of: commitState)
            if let recovered = recoverCompletedInstallation(candidate: candidate) {
                persistSynthesizedAuthorityIfSafe(
                    recovered,
                    at: root,
                    commitLoadDisposition: disposition,
                    heldWriterToken: heldWriterToken
                )
                return snapshot(
                    root: root,
                    record: recovered,
                    scope: candidate.scope,
                    authorityProvenance: .synthesizedFallback,
                    commitLoadDisposition: disposition
                )
            }
            return invalidSnapshot(
                root: root,
                scope: candidate.scope,
                commitLoadDisposition: disposition
            )
        case .absent:
            break
        }

        guard legacyAdoptionIsAllowed(candidate: candidate)
                || recoveryEvidenceConfirmsCompletedInstallation(candidate: candidate) else {
            // The canonical active root is always managed, even before a first
            // successful commit. Bytes in it must not become user-imported just
            // because the authoritative record is absent.
            let hasManagedMarker = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ArkFileContentPackInstaller.contentRootMarkerFileName
                ).fileSystemPath
            )
            return candidate.canRecoverMarkerlessInstalledState || hasManagedMarker
                ? invalidSnapshot(
                    root: root,
                    scope: candidate.scope,
                    commitLoadDisposition: .absent
                )
                : nil
        }
        guard let adopted = makeLegacyCommit(root: root, scope: candidate.scope) else {
            return invalidSnapshot(
                root: root,
                scope: candidate.scope,
                commitLoadDisposition: .absent
            )
        }

        // Adoption never hashes or relocates the pack. Persist the small record
        // when possible; a storage/protection failure does not strand an older
        // otherwise valid emergency library in this launch.
        persistSynthesizedAuthorityIfSafe(
            adopted,
            at: root,
            commitLoadDisposition: .absent,
            heldWriterToken: heldWriterToken
        )
        return snapshot(
            root: root,
            record: adopted,
            scope: candidate.scope,
            authorityProvenance: .synthesizedFallback,
            commitLoadDisposition: .absent
        )
    }

    private static func persistSynthesizedAuthorityIfSafe(
        _ record: CommitRecord,
        at root: URL,
        commitLoadDisposition expectedDisposition: CommitLoadDisposition,
        heldWriterToken: ArkFileManagedContentWriterToken?
    ) {
        // Unavailable authority cannot safely be replaced, and an unresolved
        // activation journal freezes every authority writer. The pathname
        // check also protects callers that have not installed the in-memory
        // recovery freeze yet.
        guard expectedDisposition == .absent || expectedDisposition == .invalid else {
            return
        }
        var acquiredWriterToken: ArkFileManagedContentWriterToken?
        let writerToken: ArkFileManagedContentWriterToken
        if let heldWriterToken {
            guard ArkFileManagedContentConcurrencyGate.isActiveWriterReservation(
                heldWriterToken
            ) else { return }
            writerToken = heldWriterToken
        } else {
            guard let token = ArkFileManagedContentConcurrencyGate
                .tryBeginWriterReservation() else { return }
            acquiredWriterToken = token
            writerToken = token
        }
        defer { acquiredWriterToken?.release() }
        guard ArkFileManagedContentConcurrencyGate.isActiveWriterReservation(
            writerToken
        ) else { return }
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(at: root),
              ArkFileContentActivationCoordinator.isJournalDefinitivelyAbsent(at: root),
              commitLoadDisposition(of: commitRecordLoadState(at: root))
                == expectedDisposition else { return }
        try? writeRecord(record, at: root)
    }

    private static func commitLoadDisposition(
        of state: CommitRecordLoadState
    ) -> CommitLoadDisposition {
        switch state {
        case .absent: .absent
        case .valid: .valid
        case .invalid: .invalid
        case .unavailable: .unavailable
        }
    }

    private static func recoverCompletedInstallation(
        candidate: ManagedRootCandidate
    ) -> CommitRecord? {
        guard legacyAdoptionIsAllowed(candidate: candidate)
                || recoveryEvidenceConfirmsCompletedInstallation(candidate: candidate) else {
            return nil
        }
        return makeLegacyCommit(root: candidate.url, scope: candidate.scope)
    }

    /// Uses redundant, entirely local installation evidence. A persisted
    /// installed state is enough for a dedicated ArkFile root. Otherwise the
    /// managed marker and complete manifest inventory must agree with every
    /// selected file's path and size. This intentionally prefers availability
    /// over preventing a small amount of stale local access.
    private static func recoveryEvidenceConfirmsCompletedInstallation(
        candidate: ManagedRootCandidate
    ) -> Bool {
        let root = candidate.url
        let stateConfirmsRoot = persistedInstallerStateConfirmsInstalledRoot(root)
        let markerConfirmsRoot = managedMarkerIdentifiesArkFileRoot(root)

        switch candidate.scope {
        case .dedicated:
            if stateConfirmsRoot { return true }
        case .sharedDocuments:
            // The Documents container can contain arbitrary user imports, so a
            // state file alone must never convert that whole container into a
            // managed pack.
            guard markerConfirmsRoot else { return false }
            if stateConfirmsRoot { return true }
        }

        guard markerConfirmsRoot,
              let manifest = loadManifest(root: root),
              !manifest.files.isEmpty else {
            return false
        }
        let catalog = try? ArkFileContentCatalog.loadBundled()
        var seenPaths = Set<String>()
        for entry in manifest.files {
            let relativePath = ArkFileContentPackInstaller.installRelativePath(
                for: entry,
                catalog: catalog
            )
            guard let normalized = normalizedRelativePath(relativePath),
                  seenPaths.insert(normalized.lowercased()).inserted,
                  regularFile(root.appendingPathComponent(normalized)) == entry.sizeBytes else {
                return false
            }
        }
        return true
    }

    private static func managedMarkerIdentifiesArkFileRoot(_ root: URL) -> Bool {
        let markerURL = root.appendingPathComponent(
            ArkFileContentPackInstaller.contentRootMarkerFileName
        )
        guard let data = try? Data(contentsOf: markerURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["product"] as? String) == "ArkFile"
            && (object["bundleType"] as? String) == "managed-content-pack"
    }

    private static func defaultCandidates() -> [ManagedRootCandidate] {
        var candidates: [ManagedRootCandidate] = []
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            candidates.append(ManagedRootCandidate(
                url: support
                    .appendingPathComponent("ArkFile", isDirectory: true)
                    .appendingPathComponent("Content", isDirectory: true)
                    .appendingPathComponent("active", isDirectory: true),
                scope: .dedicated,
                canRecoverMarkerlessInstalledState: true
            ))
        }
        if let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            candidates.append(ManagedRootCandidate(
                url: documents.appendingPathComponent("LITE", isDirectory: true),
                scope: .dedicated
            ))
            candidates.append(ManagedRootCandidate(
                url: documents,
                scope: .sharedDocuments
            ))
        }
        return candidates
    }

    private static func legacyAdoptionIsAllowed(candidate: ManagedRootCandidate) -> Bool {
        let root = candidate.url
        let markerURL = root.appendingPathComponent(ArkFileContentPackInstaller.contentRootMarkerFileName)
        if FileManager.default.fileExists(atPath: markerURL.fileSystemPath) {
            return validLegacyMarkerAllowsAdoption(markerURL)
        }
        if candidate.canRecoverMarkerlessInstalledState,
           persistedInstallerStateConfirmsInstalledRoot(root) {
            return true
        }
        if case .dedicated = candidate.scope,
           root.lastPathComponent.caseInsensitiveCompare("LITE") == .orderedSame {
            return recognizableArkFileFileCount(in: root, limit: 2) >= 2
        }
        return false
    }

    private static func validLegacyMarkerAllowsAdoption(_ markerURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard (object["product"] as? String) == "ArkFile",
              (object["bundleType"] as? String) == "managed-content-pack" else {
            return false
        }
        if let value = object["installCommitRequired"] as? Bool {
            return !value
        }
        if let value = object["installCommitRequired"] as? String {
            return value.caseInsensitiveCompare("true") != .orderedSame
        }
        return true
    }

    private static func persistedInstallerStateConfirmsInstalledRoot(_ root: URL) -> Bool {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }
        let stateURL = support
            .appendingPathComponent("ArkFile", isDirectory: true)
            .appendingPathComponent("content-pack-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["phase"] as? String) == "installed",
              let activePath = object["activePath"] as? String else {
            return false
        }
        return normalizedPath(URL(fileURLWithPath: activePath), resolvingSymlinks: false)
            == normalizedPath(root, resolvingSymlinks: false)
    }

    private static func makeLegacyCommit(
        root: URL,
        scope: ManagedRootCandidate.Scope
    ) -> CommitRecord? {
        let manifest = loadManifest(root: root)
        let catalog = try? ArkFileContentCatalog.loadBundled()
        let tierIndex = loadTierIndex(root: root)
        let installedTier = ArkFileContentTier.iOSInstallableTier(named: manifest?.tier) ?? .lite
        let manifestEntries = manifest.map {
            manifestEntryMap($0, catalog: catalog)
        } ?? [:]
        let catalogTiers = catalogTierMap(catalog, manifest: manifest)

        let paths: [String]
        switch scope {
        case .dedicated:
            paths = regularRelativePaths(in: root)
        case .sharedDocuments:
            let known = Set(manifestEntries.keys)
                .union(tierIndex.keys)
                .union(catalogTiers.keys)
            paths = known.filter { regularFile(root.appendingPathComponent($0)) != nil }.sorted()
        }
        let entries = paths.compactMap { relativePath -> CommitEntry? in
            guard let actualSize = regularFile(root.appendingPathComponent(relativePath)) else {
                return nil
            }
            let key = relativePath.lowercased()
            let tier = ArkFileManagedContentTierPolicy.tier(
                for: key,
                indexedTier: tierIndex[key].flatMap(
                    ArkFileContentTier.iOSInstallableTier(named:)
                ),
                catalogTier: catalogTiers[key],
                installedTier: installedTier
            )
            return CommitEntry(
                relativePath: relativePath,
                tier: tier.rawValue,
                byteCount: actualSize,
                // Legacy adoption and commit recovery intentionally avoid
                // re-hashing a potentially very large pack at launch. A
                // manifest hash is expected identity, not proof that these
                // current bytes were verified. Keep the entry readable but
                // hashless so it cannot authorize peer redistribution.
                sha256: nil
            )
        }
        guard !entries.isEmpty else { return nil }
        return try? makeCommitRecordForTesting(installedTier: installedTier, entries: entries)
    }

    private static func committedEntries(
        at root: URL,
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) throws -> [CommitEntry] {
        let manifestEntries = manifestEntryMap(manifest, catalog: catalog)
        let tierIndex = loadTierIndex(root: root)
        let catalogTiers = catalogTierMap(catalog, manifest: manifest)
        let installedTier = ArkFileContentTier.iOSInstallableTier(named: manifest.tier) ?? .lite

        return regularRelativePaths(in: root).compactMap { relativePath in
            let key = relativePath.lowercased()
            guard let size = regularFile(root.appendingPathComponent(relativePath)) else { return nil }
            let manifestEntry = manifestEntries[key]
            let tier = ArkFileManagedContentTierPolicy.tier(
                for: key,
                indexedTier: tierIndex[key].flatMap(
                    ArkFileContentTier.iOSInstallableTier(named:)
                ),
                catalogTier: catalogTiers[key],
                installedTier: installedTier
            )
            return CommitEntry(
                relativePath: relativePath,
                tier: tier.rawValue,
                byteCount: size,
                sha256: manifestEntry?.sizeBytes == size ? manifestEntry?.sha256.lowercased() : nil
            )
        }
        .sorted { $0.relativePath.lowercased() < $1.relativePath.lowercased() }
    }

    private static func manifestEntryMap(
        _ manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) -> [String: ArkFilePackageManifest.Entry] {
        Dictionary(
            manifest.files.map { entry in
                (
                    ArkFileContentPackInstaller.installRelativePath(
                        for: entry,
                        catalog: catalog
                    ).lowercased(),
                    entry
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func catalogTierMap(
        _ catalog: ArkFileContentCatalog?,
        manifest: ArkFilePackageManifest?
    ) -> [String: ArkFileContentTier] {
        var tiers: [String: ArkFileContentTier] = Dictionary(
            (catalog?.allItems ?? []).map {
                (
                    ArkFileContentCanonicalPath.key($0.normalizedRelativePath),
                    $0.isAvailableInEssentials ? .lite : .complete
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        if let manifest {
            tiers.merge(
                ArkFileContentPackInstaller.projectedContentTiers(
                    manifest: manifest,
                    catalog: catalog
                ),
                uniquingKeysWith: { _, projected in projected }
            )
        }
        return tiers
    }

    private static func loadManifest(root: URL) -> ArkFilePackageManifest? {
        let url = root.appendingPathComponent(ArkFileContentPackInstaller.contentRootManifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArkFilePackageManifest.self, from: data)
    }

    private static func loadTierIndex(root: URL) -> [String: String] {
        let url = root.appendingPathComponent(ArkFileContentPackInstaller.contentRootTierIndexFileName)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return Dictionary(
            index.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func loadValidCommit(at url: URL) -> CommitRecord? {
        guard case .valid(let record) = loadCommitRecordState(at: url) else { return nil }
        return record
    }

    private static func loadCommitRecordState(at url: URL) -> CommitRecordLoadState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain
                    && (error.code == CocoaError.fileNoSuchFile.rawValue
                        || error.code == CocoaError.fileReadNoSuchFile.rawValue))
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                return .absent
            }
            return .unavailable
        }
        guard let record = try? JSONDecoder().decode(CommitRecord.self, from: data),
              isValidCommitRecord(record) else {
            return .invalid
        }
        return .valid(record)
    }

    static func isValidCommitRecord(_ record: CommitRecord) -> Bool {
        let entryPaths = Set(record.payload.entries.map { $0.relativePath.lowercased() })
        let removedPaths = record.payload.explicitlyRemovedPaths ?? []
        let normalizedRemovedPaths = removedPaths.compactMap(normalizedRelativePath)
        let hasValidRemovalInventory = normalizedRemovedPaths.count == removedPaths.count
            && Set(normalizedRemovedPaths.map { $0.lowercased() }).count == removedPaths.count
            && Set(normalizedRemovedPaths.map { $0.lowercased() }).isDisjoint(with: entryPaths)
        let hasValidAuthorityInventory: Bool
        if record.payload.entries.isEmpty {
            hasValidAuthorityInventory = record.payload.authorityState == "explicitly-empty"
        } else {
            hasValidAuthorityInventory = record.payload.authorityState == nil
                && entriesAreValid(record.payload.entries)
        }
        let derivedManifestProjection = try? manifestProjectionBinding(
            for: record.payload.entries,
            projectionHash: record.payload.manifestProjection?.projectionHash
        )
        return record.payload.formatVersion == 1
            && record.payload.product == "ArkFile"
            && ArkFileContentTier.iOSInstallableTier(named: record.payload.installedTier) != nil
            && hasValidRemovalInventory
            && hasValidAuthorityInventory
            && derivedManifestProjection == record.payload.manifestProjection
            && (try? checksum(for: record.payload)) == record.checksum.lowercased()
    }

    private static func manifestProjectionBinding(
        for entries: [CommitEntry],
        projectionHash: String?
    ) throws -> ManifestProjectionBinding? {
        let manifests = Array(
            Set(entries.compactMap(\.manifestProvenance))
        ).sorted {
            if $0.manifestID != $1.manifestID {
                return $0.manifestID < $1.manifestID
            }
            return $0.semanticFingerprint < $1.semanticFingerprint
        }
        guard !manifests.isEmpty else {
            return nil
        }
        guard let projectionHash,
              isSHA256(projectionHash) else {
            throw ArkFileContentActivationError.invalidJournal
        }
        return ManifestProjectionBinding(
            projectionHash: projectionHash.lowercased(),
            manifests: manifests
        )
    }

    private static func entriesAreValid(_ entries: [CommitEntry]) -> Bool {
        var paths = Set<String>()
        for entry in entries {
            let normalized = normalizedRelativePath(entry.relativePath)
            guard normalized != nil,
                  entry.byteCount >= 0,
                  ArkFileContentTier.iOSInstallableTier(named: entry.tier) != nil,
                  paths.insert(normalized!.lowercased()).inserted else {
                return false
            }
            if let sha256 = entry.sha256,
               sha256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) == nil {
                return false
            }
            if let provenance = entry.manifestProvenance,
               provenance.manifestID.isEmpty
                || !isSHA256(provenance.semanticFingerprint)
                || entry.sha256 == nil {
                return false
            }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[A-Fa-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func snapshot(
        root: URL,
        record: CommitRecord,
        scope: ManagedRootCandidate.Scope,
        authorityProvenance: AuthorityProvenance,
        commitLoadDisposition: CommitLoadDisposition
    ) -> RootSnapshot {
        let entries = Dictionary(
            record.payload.entries.compactMap { entry -> (String, CommitEntry)? in
                guard let path = normalizedRelativePath(entry.relativePath) else { return nil }
                return (path.lowercased(), entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return RootSnapshot(
            lexicalRootPath: normalizedPath(root, resolvingSymlinks: false),
            resolvedRootPath: normalizedPath(root, resolvingSymlinks: true),
            commitID: record.payload.commitID,
            authorityProvenance: authorityProvenance,
            commitLoadDisposition: commitLoadDisposition,
            defaultTier: ArkFileContentTier.iOSInstallableTier(named: record.payload.installedTier) ?? .lite,
            entriesByPath: entries,
            managedPaths: Set(entries.keys).union(knownManagedPaths(root: root)),
            managesUnknownPaths: scope == .dedicated,
            isValid: true
        )
    }

    private static func invalidSnapshot(
        root: URL,
        scope: ManagedRootCandidate.Scope,
        commitLoadDisposition: CommitLoadDisposition
    ) -> RootSnapshot {
        let knownPaths = scope == .sharedDocuments ? knownManagedPaths(root: root) : []
        return RootSnapshot(
            lexicalRootPath: normalizedPath(root, resolvingSymlinks: false),
            resolvedRootPath: normalizedPath(root, resolvingSymlinks: true),
            commitID: nil,
            authorityProvenance: .invalid,
            commitLoadDisposition: commitLoadDisposition,
            defaultTier: .lite,
            entriesByPath: [:],
            managedPaths: knownPaths,
            managesUnknownPaths: scope == .dedicated,
            isValid: false
        )
    }

    private static func knownManagedPaths(root: URL) -> Set<String> {
        let manifest = loadManifest(root: root)
        let catalog = try? ArkFileContentCatalog.loadBundled()
        let manifestPaths = manifest.map {
            Set(manifestEntryMap($0, catalog: catalog).keys)
        } ?? []
        return manifestPaths
            .union(loadTierIndex(root: root).keys)
            .union(catalogTierMap(catalog, manifest: manifest).keys)
    }

    private static func checksum(for payload: CommitPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedRelativePath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasSuffix("/"),
              !normalized.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        return normalized
    }

    private static func regularRelativePaths(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let rootPath = normalizedPath(root, resolvingSymlinks: false)
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let name = url.lastPathComponent
            guard !name.hasPrefix("._"),
                  name != ".DS_Store",
                  !name.hasSuffix(".arkdownload"),
                  !name.hasSuffix(".partial"),
                  !isMetadataFile(name) else {
                continue
            }
            let path = normalizedPath(url, resolvingSymlinks: false)
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if normalizedRelativePath(relative) != nil {
                paths.append(relative)
            }
        }
        return paths.sorted { $0.lowercased() < $1.lowercased() }
    }

    private static func recognizableArkFileFileCount(in root: URL, limit: Int) -> Int {
        let aliases = ArkFileLocalContentCategoryKey.allCases.flatMap(\.folderAliases)
        var count = 0
        var scanned = Set<String>()
        for alias in aliases {
            let directory = root.appendingPathComponent(alias, isDirectory: true)
            let key = normalizedPath(directory, resolvingSymlinks: false).lowercased()
            guard scanned.insert(key).inserted else { continue }
            count += regularRelativePaths(in: directory).count
            if count >= limit { return count }
        }
        return count
    }

    private static func regularFile(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isMetadataFile(_ name: String) -> Bool {
        name == commitFileName
            || name == ArkFileContentActivationCoordinator.journalFileName
            || name == ArkFileContentPackInstaller.contentRootMarkerFileName
            || name == ArkFileContentPackInstaller.contentRootManifestFileName
            || name == ArkFileContentPackInstaller.contentRootTierIndexFileName
    }

    private static func normalizedPath(_ url: URL, resolvingSymlinks: Bool) -> String {
        let normalizedURL = resolvingSymlinks
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url.standardizedFileURL
        var path = normalizedURL.fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
