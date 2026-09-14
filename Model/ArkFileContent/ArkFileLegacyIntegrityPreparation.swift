// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Darwin
import Foundation
#if os(iOS)
import UIKit
#endif

private final class ArkFilePreparationProtectedDataMonitor:
    @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool?
    private var notificationTokens: [NSObjectProtocol] = []

    var isKnownUnavailable: Bool {
        lock.withLock { available == false }
    }

    @MainActor
    func refreshAndStartMonitoring() -> Bool {
        let current = ArkFileProtectedDataAvailability.isAvailable
        setAvailable(current)
        #if os(iOS)
        if notificationTokens.isEmpty {
            notificationTokens = [
                NotificationCenter.default.addObserver(
                    forName: UIApplication
                        .protectedDataWillBecomeUnavailableNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setAvailable(false)
                },
                NotificationCenter.default.addObserver(
                    forName: UIApplication
                        .protectedDataDidBecomeAvailableNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setAvailable(true)
                }
            ]
        }
        #endif
        return current
    }

    private func setAvailable(_ value: Bool) {
        lock.withLock {
            available = value
        }
    }
}

/// Upgrades readable legacy install authority from size-only entries to exact
/// projected artifact identities. Files-visible legacy payloads first move to
/// a private APFS copy-on-write snapshot; one complete compatibility group is
/// then hashed, re-statted, and committed as metadata.
///
/// The service is an actor so synchronous file hashing cannot run on the main
/// actor. It deliberately does not reserve the global writer while hashing a
/// potentially multi-gigabyte group.
actor ArkFileLegacyIntegrityPreparationService {
    enum BlockReason: Equatable, Sendable {
        case invalidInstallAuthority
        case duplicateAuthorityPath(String)
        case missingGroupMember(String)
        case unexpectedGroupMember(String)
        case unsafeOrUnavailableFile(String)
        case unexpectedFileSize(String)
        case committedIdentityNotAccepted(String)
        case pendingContentRecovery

        var description: String {
            switch self {
            case .invalidInstallAuthority:
                "ArkFile could not verify the installed-content record."
            case .duplicateAuthorityPath(let path):
                "The installed-content record contains the same path more than once: \(path)"
            case .missingGroupMember(let path):
                "A required compatibility file is not installed: \(path)"
            case .unexpectedGroupMember(let path):
                "The installed compatibility group contains an unprojected file: \(path)"
            case .unsafeOrUnavailableFile(let path):
                "ArkFile could not safely read the installed file: \(path)"
            case .unexpectedFileSize(let path):
                "The installed file does not match a release-approved size: \(path)"
            case .committedIdentityNotAccepted(let path):
                "The installed file has an identity that is not approved by this release: \(path)"
            case .pendingContentRecovery:
                "ArkFile is finishing or recovering another content change."
            }
        }
    }

    enum GroupState: Equatable, Sendable {
        case ready
        case needsPreparation
        case blocked(reason: BlockReason)
    }

    struct GroupAssessment: Equatable, Sendable, Identifiable {
        let id: String
        let displayName: String
        let relativePaths: [String]
        let byteCount: Int64
        let state: GroupState
    }

    struct Assessment: Equatable, Sendable {
        let activeRoot: URL
        let commitID: UUID?
        let groups: [GroupAssessment]
        let globalBlockReason: BlockReason?

        var groupsNeedingPreparation: Int {
            groups.reduce(0) {
                $0 + ($1.state == .needsPreparation ? 1 : 0)
            }
        }

        var bytesNeedingPreparation: Int64 {
            groups.reduce(0) {
                $0 + ($1.state == .needsPreparation ? $1.byteCount : 0)
            }
        }

        var hasBlockedGroups: Bool {
            globalBlockReason != nil || groups.contains {
                if case .blocked = $0.state { return true }
                return false
            }
        }

        var isReady: Bool {
            globalBlockReason == nil
                && !groups.isEmpty
                && groups.allSatisfy { $0.state == .ready }
        }
    }

    enum ProgressPhase: Equatable, Sendable {
        case stoppingSharing
        case protectingStorage
        case hashing
        case waitingForWriter
        case committing
        case purging
        case completed
    }

    struct Progress: Equatable, Sendable {
        let phase: ProgressPhase
        let groupID: String?
        let groupDisplayName: String?
        let relativePath: String?
        let completedBytes: Int64
        let totalBytes: Int64
        let completedGroups: Int
        let totalGroups: Int
    }

    struct PreparationResult: Equatable, Sendable {
        let completedGroupIDs: [String]
        let committedBytes: Int64
        let finalAssessment: Assessment
    }

    enum ResourceConstraint: Equatable, Sendable {
        case protectedDataUnavailable
        case lowPowerMode
        case seriousThermalState
        case criticalThermalState

        var description: String {
            switch self {
            case .protectedDataUnavailable:
                "Unlock \(ArkFileDeviceCopy.thisDevice) before preparing Local Sharing."
            case .lowPowerMode:
                "Turn off Low Power Mode before preparing Local Sharing."
            case .seriousThermalState:
                "\(ArkFileDeviceCopy.thisDeviceCapitalized) is too warm to prepare Local Sharing. Let it cool, then try again."
            case .criticalThermalState:
                "\(ArkFileDeviceCopy.thisDeviceCapitalized) is too hot to prepare Local Sharing. Let it cool, then try again."
            }
        }
    }

    enum PreparationError: LocalizedError, Equatable, Sendable {
        case noManagedContent
        case dispositionUnavailable
        case invalidInstallAuthority
        case resourceConstrained(
            reason: ResourceConstraint,
            completedGroupIDs: [String]
        )
        case groupBecameBlocked(
            groupID: String,
            reason: BlockReason,
            completedGroupIDs: [String]
        )
        case contentChanged(completedGroupIDs: [String])
        case contentWriterUnavailable(completedGroupIDs: [String])
        case protectionMigrationFailed
        case commitFailed(completedGroupIDs: [String])
        case cancelled(completedGroupIDs: [String])

        var errorDescription: String? {
            switch self {
            case .noManagedContent:
                "There is no ArkFile-managed offline library to prepare."
            case .dispositionUnavailable:
                "This build's Local Sharing disposition is unavailable."
            case .invalidInstallAuthority:
                "ArkFile could not verify the installed-content record."
            case .resourceConstrained(let reason, _):
                reason.description
            case .groupBecameBlocked(_, let reason, _):
                reason.description
            case .contentChanged:
                "The installed library changed while ArkFile was verifying it. Try again."
            case .contentWriterUnavailable:
                "ArkFile is already finishing another content change. Try again in a moment."
            case .protectionMigrationFailed:
                "ArkFile could not move the legacy library into protected storage."
            case .commitFailed:
                "ArkFile verified the files but could not safely save their integrity record."
            case .cancelled:
                "Integrity preparation was cancelled."
            }
        }

        func checkpointing(_ completedGroupIDs: [String]) -> Self {
            switch self {
            case .resourceConstrained(let reason, _):
                .resourceConstrained(
                    reason: reason,
                    completedGroupIDs: completedGroupIDs
                )
            case .contentChanged:
                .contentChanged(completedGroupIDs: completedGroupIDs)
            case .contentWriterUnavailable:
                .contentWriterUnavailable(
                    completedGroupIDs: completedGroupIDs
                )
            case .protectionMigrationFailed:
                .protectionMigrationFailed
            case .commitFailed:
                .commitFailed(completedGroupIDs: completedGroupIDs)
            case .cancelled:
                .cancelled(completedGroupIDs: completedGroupIDs)
            case .groupBecameBlocked(let groupID, let reason, _):
                .groupBecameBlocked(
                    groupID: groupID,
                    reason: reason,
                    completedGroupIDs: completedGroupIDs
                )
            case .noManagedContent,
                 .dispositionUnavailable,
                 .invalidInstallAuthority:
                self
            }
        }
    }

    /// A test seam around the short writer/commit window. Production still
    /// calls the same concurrency, recovery, commit, and ZIM-cache primitives
    /// used by the installer.
    struct Operations: @unchecked Sendable {
        private static let liveProtectedDataMonitor =
            ArkFilePreparationProtectedDataMonitor()

        final class WriterReservation: @unchecked Sendable {
            private let lock = NSLock()
            private var released = false
            private let active: @Sendable () -> Bool
            private let releaseAction: @Sendable () -> Void

            init(
                active: @escaping @Sendable () -> Bool,
                release: @escaping @Sendable () -> Void
            ) {
                self.active = active
                self.releaseAction = release
            }

            var isActive: Bool {
                lock.lock()
                let isReleased = released
                lock.unlock()
                return !isReleased && active()
            }

            func release() {
                lock.lock()
                guard !released else {
                    lock.unlock()
                    return
                }
                released = true
                lock.unlock()
                releaseAction()
            }

            deinit {
                release()
            }
        }

        let currentCommit: @Sendable (
            URL
        ) -> ArkFileInstalledContentAccess.CommitRecord?
        let protectedDataIsAvailable: @Sendable () async -> Bool
        let resourceConstraint: @Sendable () -> ResourceConstraint?
        let beginWriter: @Sendable () -> WriterReservation?
        let recoveryIsFrozen: @Sendable (URL) -> Bool
        let journalIsDefinitivelyAbsent: @Sendable (URL) -> Bool
        let installCommit: @Sendable (
            ArkFileInstalledContentAccess.CommitRecord,
            URL
        ) throws -> Void
        let hashFile: @Sendable (
            URL,
            @escaping @Sendable (Int64) -> Void,
            @escaping @Sendable () throws -> Void
        ) throws -> String
        let purgeUnpinnedZIMArchives: @Sendable () async -> Void

        static let live = Operations(
            currentCommit: {
                ArkFileInstalledContentAccess.currentCommitRecord(at: $0)
            },
            protectedDataIsAvailable: {
                await liveProtectedDataMonitor
                    .refreshAndStartMonitoring()
            },
            resourceConstraint: {
                if liveProtectedDataMonitor.isKnownUnavailable {
                    return .protectedDataUnavailable
                }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    return .lowPowerMode
                }
                switch ProcessInfo.processInfo.thermalState {
                case .serious:
                    return .seriousThermalState
                case .critical:
                    return .criticalThermalState
                case .nominal, .fair:
                    return nil
                @unknown default:
                    return .seriousThermalState
                }
            },
            beginWriter: {
                guard let token = ArkFileManagedContentConcurrencyGate
                    .tryBeginWriterReservation() else {
                    return nil
                }
                return WriterReservation(
                    active: {
                        ArkFileManagedContentConcurrencyGate
                            .isActiveWriterReservation(token)
                    },
                    release: {
                        token.release()
                        ArkFileContentActivationCoordinator
                            .retryDeferredCleanupIfPossible()
                    }
                )
            },
            recoveryIsFrozen: {
                ArkFileContentActivationCoordinator.isRecoveryFrozen(at: $0)
            },
            journalIsDefinitivelyAbsent: {
                ArkFileContentActivationCoordinator
                    .isJournalDefinitivelyAbsent(at: $0)
            },
            installCommit: { record, root in
                try ArkFileInstalledContentAccess
                    .installCommitRecordDurablyAndReload(record, at: root)
            },
            hashFile: { url, progress, continuation in
                try ArkFileContentFileVerifier.sha256HexDigest(
                    of: url,
                    progress: progress,
                    continuation: continuation
                )
            },
            purgeUnpinnedZIMArchives: {
                await ZimFileService.shared.purgeUnpinnedArchives()
            }
        )
    }

    private struct AcceptedIdentity: Hashable, Sendable {
        let byteCount: Int64
        let sha256: String
    }

    private struct ProjectedMember: Sendable {
        let canonicalPath: String
        let relativePath: String
        let acceptedIdentities: Set<AcceptedIdentity>
    }

    private struct ProjectedGroup: Sendable {
        let id: String
        let displayName: String
        let anchorCanonicalPath: String
        let members: [ProjectedMember]

        func assessment(
            byteCount: Int64,
            state: GroupState
        ) -> GroupAssessment {
            GroupAssessment(
                id: id,
                displayName: displayName,
                relativePaths: members.map(\.relativePath),
                byteCount: byteCount,
                state: state
            )
        }
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private struct PreparedMember: Sendable {
        let existingEntry: ArkFileInstalledContentAccess.CommitEntry
        let url: URL
        let identity: FileIdentity
        let digest: String
    }

    private struct PreparedGroup: Sendable {
        let projection: ProjectedGroup
        let members: [PreparedMember]
        let byteCount: Int64
    }

    private let activeRoot: URL
    private let projectedGroups: [ProjectedGroup]
    private let operations: Operations
    private let requiresProtectionMigration: Bool

    @MainActor
    static func current() throws -> ArkFileLegacyIntegrityPreparationService {
        guard ArkFileProtectedDataAvailability.isAvailable else {
            throw PreparationError.resourceConstrained(
                reason: .protectedDataUnavailable,
                completedGroupIDs: []
            )
        }
        guard let activeRoot = ArkFileContentPackInstaller
            .installedContentRootIfAvailable(requireReadableContent: true) else {
            throw PreparationError.noManagedContent
        }
        guard let disposition = try? ArkFileLocalSharingDispositionIndex
            .loadBundled() else {
            throw PreparationError.dispositionUnavailable
        }
        return ArkFileLegacyIntegrityPreparationService(
            activeRoot: activeRoot,
            disposition: disposition,
            requiresProtectionMigration:
                !ArkFileContentPackInstaller.isProtectedActiveContentURL(
                    activeRoot
                )
        )
    }

    init(
        activeRoot: URL,
        disposition: ArkFileLocalSharingDispositionIndex,
        operations: Operations = .live,
        requiresProtectionMigration: Bool = false
    ) {
        self.activeRoot = activeRoot.standardizedFileURL
        self.projectedGroups = Self.makeProjectedGroups(from: disposition)
        self.operations = operations
        self.requiresProtectionMigration = requiresProtectionMigration
    }

    private init(
        activeRoot: URL,
        projectedGroups: [ProjectedGroup],
        operations: Operations,
        requiresProtectionMigration: Bool
    ) {
        self.activeRoot = activeRoot.standardizedFileURL
        self.projectedGroups = projectedGroups
        self.operations = operations
        self.requiresProtectionMigration = requiresProtectionMigration
    }

    func assess() -> Assessment {
        guard let commit = operations.currentCommit(activeRoot) else {
            return Assessment(
                activeRoot: activeRoot,
                commitID: nil,
                groups: [],
                globalBlockReason: .invalidInstallAuthority
            )
        }
        guard !operations.recoveryIsFrozen(activeRoot),
              operations.journalIsDefinitivelyAbsent(activeRoot) else {
            return Assessment(
                activeRoot: activeRoot,
                commitID: commit.payload.commitID,
                groups: [],
                globalBlockReason: .pendingContentRecovery
            )
        }
        return assessment(for: commit)
    }

    func prepare(
        stopSharing: @escaping @Sendable () async -> Void,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> PreparationResult {
        try await requireAvailableResources(completedGroupIDs: [])
        if requiresProtectionMigration {
            progress(Progress(
                phase: .stoppingSharing,
                groupID: nil,
                groupDisplayName: nil,
                relativePath: nil,
                completedBytes: 0,
                totalBytes: 0,
                completedGroups: 0,
                totalGroups: projectedGroups.count
            ))
            await stopSharing()
            try Task.checkCancellation()
            progress(Progress(
                phase: .protectingStorage,
                groupID: nil,
                groupDisplayName: nil,
                relativePath: nil,
                completedBytes: 0,
                totalBytes: 0,
                completedGroups: 0,
                totalGroups: projectedGroups.count
            ))
            let migratedRoot: URL
            do {
                migratedRoot = try await ArkFileLegacyContentProtectionMigration
                    .migrateCurrentInstallation(from: activeRoot)
                    .protectedRoot
            } catch is CancellationError {
                throw PreparationError.cancelled(completedGroupIDs: [])
            } catch let error as ArkFileLegacyContentProtectionMigration
                    .MigrationError {
                switch error {
                case .contentWriterUnavailable:
                    throw PreparationError.contentWriterUnavailable(
                        completedGroupIDs: []
                    )
                case .sourceAuthorityChanged:
                    throw PreparationError.contentChanged(
                        completedGroupIDs: []
                    )
                case .pendingContentRecovery:
                    throw PreparationError.groupBecameBlocked(
                        groupID: "",
                        reason: .pendingContentRecovery,
                        completedGroupIDs: []
                    )
                default:
                    throw PreparationError.protectionMigrationFailed
                }
            }
            let migratedService = ArkFileLegacyIntegrityPreparationService(
                activeRoot: migratedRoot,
                projectedGroups: projectedGroups,
                operations: operations,
                requiresProtectionMigration: false
            )
            return try await migratedService.prepare(
                stopSharing: stopSharing,
                progress: progress
            )
        }

        var completedGroupIDs: [String] = []
        var committedBytes: Int64 = 0
        guard var expectedCommit = operations.currentCommit(activeRoot) else {
            throw PreparationError.invalidInstallAuthority
        }
        guard !operations.recoveryIsFrozen(activeRoot),
              operations.journalIsDefinitivelyAbsent(activeRoot) else {
            throw PreparationError.groupBecameBlocked(
                groupID: "",
                reason: .pendingContentRecovery,
                completedGroupIDs: []
            )
        }

        let initialAssessment = assessment(for: expectedCommit)
        let groupsToPrepare = initialAssessment.groups.filter {
            $0.state == .needsPreparation
        }
        let groupByID = Dictionary(
            uniqueKeysWithValues: projectedGroups.map { ($0.id, $0) }
        )
        let totalBytes = groupsToPrepare.reduce(0) { $0 + $1.byteCount }
        let totalGroups = groupsToPrepare.count

        guard !groupsToPrepare.isEmpty else {
            progress(Progress(
                phase: .completed,
                groupID: nil,
                groupDisplayName: nil,
                relativePath: nil,
                completedBytes: 0,
                totalBytes: 0,
                completedGroups: 0,
                totalGroups: 0
            ))
            return PreparationResult(
                completedGroupIDs: [],
                committedBytes: 0,
                finalAssessment: initialAssessment
            )
        }

        do {
            var completedBytes: Int64 = 0
            for groupAssessment in groupsToPrepare {
                try await requireAvailableResources(
                    completedGroupIDs: completedGroupIDs
                )
                guard let projectedGroup = groupByID[groupAssessment.id] else {
                    throw PreparationError.contentChanged(
                        completedGroupIDs: completedGroupIDs
                    )
                }
                let prepared: PreparedGroup
                do {
                    prepared = try prepareBytes(
                        for: projectedGroup,
                        expectedCommit: expectedCommit,
                        completedBytesBeforeGroup: completedBytes,
                        totalBytes: totalBytes,
                        completedGroups: completedGroupIDs.count,
                        totalGroups: totalGroups,
                        progress: progress
                    )
                } catch let reason as GroupPreparationBlock {
                    throw PreparationError.groupBecameBlocked(
                        groupID: projectedGroup.id,
                        reason: reason.reason,
                        completedGroupIDs: completedGroupIDs
                    )
                } catch let error as PreparationError {
                    throw error.checkpointing(completedGroupIDs)
                }
                try await requireAvailableResources(
                    completedGroupIDs: completedGroupIDs
                )

                progress(Progress(
                    phase: .stoppingSharing,
                    groupID: projectedGroup.id,
                    groupDisplayName: projectedGroup.displayName,
                    relativePath: nil,
                    completedBytes: completedBytes + prepared.byteCount,
                    totalBytes: totalBytes,
                    completedGroups: completedGroupIDs.count,
                    totalGroups: totalGroups
                ))
                await stopSharing()
                try Task.checkCancellation()

                let writer = try await acquireWriter(
                    group: projectedGroup,
                    completedBytes: completedBytes + prepared.byteCount,
                    totalBytes: totalBytes,
                    completedGroups: completedGroupIDs.count,
                    totalGroups: totalGroups,
                    completedGroupIDs: completedGroupIDs,
                    progress: progress
                )
                do {
                    try commit(
                        prepared,
                        expectedCommit: expectedCommit,
                        writer: writer,
                        completedBytes: completedBytes + prepared.byteCount,
                        totalBytes: totalBytes,
                        completedGroups: completedGroupIDs.count,
                        totalGroups: totalGroups,
                        progress: progress
                    )
                } catch let error as PreparationError {
                    writer.release()
                    throw error.checkpointing(completedGroupIDs)
                } catch {
                    writer.release()
                    throw PreparationError.commitFailed(
                        completedGroupIDs: completedGroupIDs
                    )
                }
                writer.release()

                guard let committed = operations.currentCommit(activeRoot),
                      committed != expectedCommit else {
                    throw PreparationError.commitFailed(
                        completedGroupIDs: completedGroupIDs
                    )
                }
                expectedCommit = committed
                completedGroupIDs.append(projectedGroup.id)
                completedBytes += prepared.byteCount
                committedBytes += prepared.byteCount

                progress(Progress(
                    phase: .purging,
                    groupID: projectedGroup.id,
                    groupDisplayName: projectedGroup.displayName,
                    relativePath: nil,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    completedGroups: completedGroupIDs.count,
                    totalGroups: totalGroups
                ))
                await operations.purgeUnpinnedZIMArchives()
            }
        } catch is CancellationError {
            throw PreparationError.cancelled(
                completedGroupIDs: completedGroupIDs
            )
        }

        let finalAssessment = assessment(for: expectedCommit)
        progress(Progress(
            phase: .completed,
            groupID: nil,
            groupDisplayName: nil,
            relativePath: nil,
            completedBytes: committedBytes,
            totalBytes: committedBytes,
            completedGroups: completedGroupIDs.count,
            totalGroups: completedGroupIDs.count
        ))
        return PreparationResult(
            completedGroupIDs: completedGroupIDs,
            committedBytes: committedBytes,
            finalAssessment: finalAssessment
        )
    }

    private func assessment(
        for commit: ArkFileInstalledContentAccess.CommitRecord
    ) -> Assessment {
        var entriesByPath: [
            String: ArkFileInstalledContentAccess.CommitEntry
        ] = [:]
        var duplicatePaths = Set<String>()
        for entry in commit.payload.entries {
            let key = ArkFileLocalSharingDispositionIndex.canonicalPath(
                entry.relativePath
            )
            if entriesByPath.updateValue(entry, forKey: key) != nil {
                duplicatePaths.insert(key)
            }
        }

        let groups = projectedGroups.compactMap { group -> GroupAssessment? in
            let projectedMemberKeys = Set(
                group.members.map(\.canonicalPath)
            )
            let authorityGroupMembers = commit.payload.entries.filter {
                ArkFileContentCompatibilityPlanner.groupID(
                    for: $0.relativePath
                ).rawValue == group.id
            }
            let installedMemberKeys = group.members.filter {
                entriesByPath[$0.canonicalPath] != nil
            }.map(\.canonicalPath)
            guard !installedMemberKeys.isEmpty
                    || !authorityGroupMembers.isEmpty else {
                return nil
            }
            if let unexpected = authorityGroupMembers.first(where: {
                !projectedMemberKeys.contains(
                    ArkFileLocalSharingDispositionIndex.canonicalPath(
                        $0.relativePath
                    )
                )
            }) {
                return group.assessment(
                    byteCount: 0,
                    state: .blocked(
                        reason: .unexpectedGroupMember(
                            unexpected.relativePath
                        )
                    )
                )
            }
            if let duplicate = group.members.first(where: {
                duplicatePaths.contains($0.canonicalPath)
            }) {
                return group.assessment(
                    byteCount: 0,
                    state: .blocked(
                        reason: .duplicateAuthorityPath(duplicate.relativePath)
                    )
                )
            }
            guard entriesByPath[group.anchorCanonicalPath] != nil else {
                return group.assessment(
                    byteCount: 0,
                    state: .blocked(
                        reason: .missingGroupMember(group.anchorCanonicalPath)
                    )
                )
            }

            var byteCount: Int64 = 0
            var needsPreparation = requiresProtectionMigration
            for member in group.members {
                guard let entry = entriesByPath[member.canonicalPath] else {
                    return group.assessment(
                        byteCount: byteCount,
                        state: .blocked(
                            reason: .missingGroupMember(member.relativePath)
                        )
                    )
                }
                guard member.acceptedIdentities.contains(where: {
                    $0.byteCount == entry.byteCount
                }) else {
                    return group.assessment(
                        byteCount: byteCount,
                        state: .blocked(
                            reason: .unexpectedFileSize(member.relativePath)
                        )
                    )
                }
                let url = activeRoot.appendingPathComponent(entry.relativePath)
                guard let fileIdentity = Self.regularFileIdentity(
                    at: url,
                    under: activeRoot
                ) else {
                    return group.assessment(
                        byteCount: byteCount,
                        state: .blocked(
                            reason: .unsafeOrUnavailableFile(
                                member.relativePath
                            )
                        )
                    )
                }
                guard fileIdentity.byteCount == entry.byteCount else {
                    return group.assessment(
                        byteCount: byteCount,
                        state: .blocked(
                            reason: .unexpectedFileSize(member.relativePath)
                        )
                    )
                }
                byteCount += entry.byteCount
                if let committedDigest = entry.sha256 {
                    guard member.acceptedIdentities.contains(where: {
                        $0.byteCount == entry.byteCount
                            && $0.sha256.caseInsensitiveCompare(
                                committedDigest
                            ) == .orderedSame
                    }) else {
                        return group.assessment(
                            byteCount: byteCount,
                            state: .blocked(
                                reason: .committedIdentityNotAccepted(
                                    member.relativePath
                                )
                            )
                        )
                    }
                } else {
                    needsPreparation = true
                }
            }
            return group.assessment(
                byteCount: byteCount,
                state: needsPreparation ? .needsPreparation : .ready
            )
        }
        return Assessment(
            activeRoot: activeRoot,
            commitID: commit.payload.commitID,
            groups: groups,
            globalBlockReason: nil
        )
    }

    private func prepareBytes(
        for group: ProjectedGroup,
        expectedCommit: ArkFileInstalledContentAccess.CommitRecord,
        completedBytesBeforeGroup: Int64,
        totalBytes: Int64,
        completedGroups: Int,
        totalGroups: Int,
        progress: @escaping @Sendable (Progress) -> Void
    ) throws -> PreparedGroup {
        let entriesByPath = Dictionary(
            expectedCommit.payload.entries.map {
                (
                    ArkFileLocalSharingDispositionIndex.canonicalPath(
                        $0.relativePath
                    ),
                    $0
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        var preparedMembers: [PreparedMember] = []
        var completedMemberBytes: Int64 = 0

        for member in group.members {
            if Task.isCancelled { throw CancellationError() }
            guard let entry = entriesByPath[member.canonicalPath] else {
                throw GroupPreparationBlock(
                    reason: .missingGroupMember(member.relativePath)
                )
            }
            let url = activeRoot.appendingPathComponent(entry.relativePath)
            guard let before = Self.regularFileIdentity(
                at: url,
                under: activeRoot
            ) else {
                throw GroupPreparationBlock(
                    reason: .unsafeOrUnavailableFile(member.relativePath)
                )
            }
            guard before.byteCount == entry.byteCount,
                  member.acceptedIdentities.contains(where: {
                      $0.byteCount == before.byteCount
                  }) else {
                throw GroupPreparationBlock(
                    reason: .unexpectedFileSize(member.relativePath)
                )
            }
            let base = completedBytesBeforeGroup + completedMemberBytes
            let resourceConstraint = operations.resourceConstraint
            let digest = try operations.hashFile(
                url,
                { memberBytes in
                    progress(Progress(
                        phase: .hashing,
                        groupID: group.id,
                        groupDisplayName: group.displayName,
                        relativePath: member.relativePath,
                        completedBytes: base + memberBytes,
                        totalBytes: totalBytes,
                        completedGroups: completedGroups,
                        totalGroups: totalGroups
                    ))
                },
                {
                    try Task.checkCancellation()
                    if let reason = resourceConstraint() {
                        throw PreparationError.resourceConstrained(
                            reason: reason,
                            completedGroupIDs: []
                        )
                    }
                }
            ).lowercased()
            guard let after = Self.regularFileIdentity(
                at: url,
                under: activeRoot
            ), after == before else {
                throw PreparationError.contentChanged(
                    completedGroupIDs: []
                )
            }
            guard member.acceptedIdentities.contains(
                AcceptedIdentity(
                    byteCount: after.byteCount,
                    sha256: digest
                )
            ) else {
                throw GroupPreparationBlock(
                    reason: .committedIdentityNotAccepted(member.relativePath)
                )
            }
            preparedMembers.append(PreparedMember(
                existingEntry: entry,
                url: url,
                identity: after,
                digest: digest
            ))
            completedMemberBytes += after.byteCount
        }
        return PreparedGroup(
            projection: group,
            members: preparedMembers,
            byteCount: completedMemberBytes
        )
    }

    private func requireAvailableResources(
        completedGroupIDs: [String]
    ) async throws {
        try Task.checkCancellation()
        guard await operations.protectedDataIsAvailable() else {
            throw PreparationError.resourceConstrained(
                reason: .protectedDataUnavailable,
                completedGroupIDs: completedGroupIDs
            )
        }
        if let reason = operations.resourceConstraint() {
            throw PreparationError.resourceConstrained(
                reason: reason,
                completedGroupIDs: completedGroupIDs
            )
        }
        try Task.checkCancellation()
    }

    private func acquireWriter(
        group: ProjectedGroup,
        completedBytes: Int64,
        totalBytes: Int64,
        completedGroups: Int,
        totalGroups: Int,
        completedGroupIDs: [String],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Operations.WriterReservation {
        let retryNanoseconds: [UInt64] = [
            0, 50_000_000, 100_000_000, 150_000_000, 200_000_000,
            250_000_000, 250_000_000, 250_000_000, 250_000_000,
            250_000_000
        ]
        for delay in retryNanoseconds {
            try Task.checkCancellation()
            if delay > 0 {
                progress(Progress(
                    phase: .waitingForWriter,
                    groupID: group.id,
                    groupDisplayName: group.displayName,
                    relativePath: nil,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    completedGroups: completedGroups,
                    totalGroups: totalGroups
                ))
                try await Task<Never, Never>.sleep(nanoseconds: delay)
            }
            if let writer = operations.beginWriter() {
                return writer
            }
        }
        throw PreparationError.contentWriterUnavailable(
            completedGroupIDs: completedGroupIDs
        )
    }

    private func commit(
        _ prepared: PreparedGroup,
        expectedCommit: ArkFileInstalledContentAccess.CommitRecord,
        writer: Operations.WriterReservation,
        completedBytes: Int64,
        totalBytes: Int64,
        completedGroups: Int,
        totalGroups: Int,
        progress: @escaping @Sendable (Progress) -> Void
    ) throws {
        guard writer.isActive,
              !operations.recoveryIsFrozen(activeRoot),
              operations.journalIsDefinitivelyAbsent(activeRoot) else {
            throw PreparationError.contentChanged(completedGroupIDs: [])
        }
        guard operations.currentCommit(activeRoot) == expectedCommit else {
            throw PreparationError.contentChanged(completedGroupIDs: [])
        }
        for member in prepared.members {
            guard Self.regularFileIdentity(
                at: member.url,
                under: activeRoot
            ) == member.identity else {
                throw PreparationError.contentChanged(completedGroupIDs: [])
            }
        }
        progress(Progress(
            phase: .committing,
            groupID: prepared.projection.id,
            groupDisplayName: prepared.projection.displayName,
            relativePath: nil,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedGroups: completedGroups,
            totalGroups: totalGroups
        ))
        let replacements = prepared.members.map {
            ArkFileInstalledContentAccess.CommitEntry(
                relativePath: $0.existingEntry.relativePath,
                tier: $0.existingEntry.tier,
                byteCount: $0.identity.byteCount,
                sha256: $0.digest,
                manifestProvenance: $0.existingEntry.manifestProvenance
            )
        }
        let installedTier = ArkFileContentTier(
            rawValue: expectedCommit.payload.installedTier.lowercased()
        ) ?? .lite
        let replacementPaths = Set(
            prepared.members.map { $0.existingEntry.relativePath }
        )
        let nextCommit = try ArkFileInstalledContentAccess
            .makeMergedCommitRecord(
                previous: expectedCommit,
                replacingGroupPaths: replacementPaths,
                with: replacements,
                installedTier: installedTier
            )
        guard writer.isActive,
              operations.currentCommit(activeRoot) == expectedCommit else {
            throw PreparationError.contentChanged(completedGroupIDs: [])
        }
        try operations.installCommit(nextCommit, activeRoot)
        guard writer.isActive,
              operations.currentCommit(activeRoot) == nextCommit else {
            throw PreparationError.commitFailed(completedGroupIDs: [])
        }
    }

    private static func makeProjectedGroups(
        from disposition: ArkFileLocalSharingDispositionIndex
    ) -> [ProjectedGroup] {
        struct Accumulator {
            let id: String
            var displayName: String
            var anchorCanonicalPath: String
            var members: [
                String: (relativePath: String, identities: Set<AcceptedIdentity>)
            ]
        }

        var groups: [String: Accumulator] = [:]
        for entry in disposition.entries where entry.managed {
            let groupID = ArkFileContentCompatibilityPlanner.groupID(
                for: entry.relativePath
            ).rawValue
            let anchorKey = ArkFileLocalSharingDispositionIndex.canonicalPath(
                entry.relativePath
            )
            var accumulator = groups[groupID] ?? Accumulator(
                id: groupID,
                displayName: entry.displayName,
                anchorCanonicalPath: anchorKey,
                members: [:]
            )
            let projectedMembers: [
                (relativePath: String, identities: Set<AcceptedIdentity>)
            ]
            if let compatibilityMembers = entry.compatibilityGroupMembers,
               !compatibilityMembers.isEmpty {
                projectedMembers = compatibilityMembers.map {
                    (
                        $0.relativePath,
                        [AcceptedIdentity(
                            byteCount: $0.sizeBytes,
                            sha256: $0.sha256.lowercased()
                        )]
                    )
                }
            } else {
                projectedMembers = [(
                    entry.relativePath,
                    Set(entry.acceptedIdentities.map {
                        AcceptedIdentity(
                            byteCount: $0.sizeBytes,
                            sha256: $0.sha256.lowercased()
                        )
                    })
                )]
            }
            for projectedMember in projectedMembers {
                let key = ArkFileLocalSharingDispositionIndex.canonicalPath(
                    projectedMember.relativePath
                )
                var existing = accumulator.members[key] ?? (
                    projectedMember.relativePath,
                    []
                )
                existing.identities.formUnion(projectedMember.identities)
                accumulator.members[key] = existing
            }
            groups[groupID] = accumulator
        }

        return groups.values.map { group in
            ProjectedGroup(
                id: group.id,
                displayName: group.displayName,
                anchorCanonicalPath: group.anchorCanonicalPath,
                members: group.members.map {
                    ProjectedMember(
                        canonicalPath: $0.key,
                        relativePath: $0.value.relativePath,
                        acceptedIdentities: $0.value.identities
                    )
                }.sorted { $0.canonicalPath < $1.canonicalPath }
            )
        }.sorted { $0.id < $1.id }
    }

    private static func regularFileIdentity(
        at url: URL,
        under root: URL
    ) -> FileIdentity? {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let rootPath = standardizedRoot.fileSystemPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootedPrefix = "/" + rootPath + "/"
        let path = standardizedURL.fileSystemPath
        guard path.hasPrefix(rootedPrefix) else { return nil }
        let resolvedRootPath = standardizedRoot.resolvingSymlinksInPath()
            .fileSystemPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedRootPrefix = "/" + resolvedRootPath + "/"
        let resolvedPath = standardizedURL.resolvingSymlinksInPath()
            .fileSystemPath
        guard resolvedPath.hasPrefix(resolvedRootPrefix) else { return nil }

        var status = Darwin.stat()
        guard Darwin.lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(status.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private struct GroupPreparationBlock: Error {
        let reason: BlockReason
    }
}
