// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Darwin
import Foundation

/// Moves the authority for a historical Files-visible installation into
/// ArkFile's private Application Support root without downloading or copying
/// payload blocks.
///
/// `clonefile` creates an APFS copy-on-write snapshot for every exact managed
/// file. The private snapshots are activated together by one directory rename,
/// but only after every staged directory, snapshot, and authority file has
/// explicitly received and verified ArkFile's durable data-protection policy.
/// Activation begins under deliberately hashless authority. Local Sharing
/// therefore remains closed until `ArkFileLegacyIntegrityPreparationService`
/// hashes the private snapshots and commits their projected identities.
/// Files-visible source paths are always preserved as unmanaged copies:
/// deleting a pathname after any separate identity check would race an external
/// Files writer.
enum ArkFileLegacyContentProtectionMigration {
    struct Result: Equatable, Sendable {
        let protectedRoot: URL
        let migratedEntryCount: Int
        let preservedLegacySourcePaths: [String]
    }

    enum MigrationError: LocalizedError, Equatable, Sendable {
        case invalidSourceAuthority
        case unsafeSourcePath(String)
        case sourceFileUnavailable(String)
        case protectedFileUnavailable(String)
        case targetOccupied
        case copyOnWriteUnavailable(Int32)
        case dataProtectionUnavailable
        case contentWriterUnavailable
        case sourceAuthorityChanged
        case pendingContentRecovery
        case activationFailed

        var errorDescription: String? {
            switch self {
            case .invalidSourceAuthority:
                "ArkFile could not verify the legacy installed-content record."
            case .unsafeSourcePath(let path):
                "The installed-content record contains an unsafe path: \(path)"
            case .sourceFileUnavailable(let path):
                "ArkFile could not safely preserve the installed file: \(path)"
            case .protectedFileUnavailable(let path):
                "ArkFile could not verify the protected copy of the installed file: \(path)"
            case .targetOccupied:
                "ArkFile's protected content area already contains an unfinished installation."
            case .copyOnWriteUnavailable:
                "\(ArkFileDeviceCopy.thisDeviceCapitalized) could not move the installed library into protected storage without duplicating it."
            case .dataProtectionUnavailable:
                "ArkFile could not verify protected storage for the installed library."
            case .contentWriterUnavailable:
                "ArkFile is already finishing another content change. Try again in a moment."
            case .sourceAuthorityChanged:
                "The installed library changed while ArkFile was protecting it. Try again."
            case .pendingContentRecovery:
                "ArkFile is finishing or recovering another content change."
            case .activationFailed:
                "ArkFile preserved the files but could not activate protected storage."
            }
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

    static func migrateCurrentInstallation(
        from sourceRoot: URL
    ) async throws -> Result {
        let targetRoot = try ArkFileContentPackInstaller
            .protectedActiveContentRoot()
        guard sourceRoot.standardizedFileURL.fileSystemPath
                != targetRoot.standardizedFileURL.fileSystemPath else {
            guard let commit = ArkFileInstalledContentAccess
                .currentCommitRecord(at: targetRoot) else {
                throw MigrationError.invalidSourceAuthority
            }
            return Result(
                protectedRoot: targetRoot,
                migratedEntryCount: commit.payload.entries.count,
                preservedLegacySourcePaths: []
            )
        }
        guard let expectedCommit = ArkFileInstalledContentAccess
            .currentCommitRecord(at: sourceRoot) else {
            throw MigrationError.invalidSourceAuthority
        }
        return try await migrate(
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            expectedCommit: expectedCommit,
            adoptProtectedRoot: { root, commit in
                await MainActor.run {
                    ArkFileContentPackInstaller.shared
                        .adoptProtectedContentRootAfterLegacyMigration(
                            root,
                            commit: commit
                        )
                }
            }
        )
    }

    /// Internal entry point retained for focused filesystem tests. Production
    /// always supplies the canonical Application Support target above.
    static func migrate(
        sourceRoot: URL,
        targetRoot: URL,
        expectedCommit: ArkFileInstalledContentAccess.CommitRecord,
        adoptProtectedRoot: @escaping @Sendable (
            URL,
            ArkFileInstalledContentAccess.CommitRecord
        ) async -> Void,
        beforeActivation: @escaping @Sendable (URL) async throws -> Void = {
            _ in
        },
        stagedTreeProtector: @escaping @Sendable (
            URL
        ) -> ArkFileDataProtection.MigrationResult = { root in
            ArkFileDataProtection.migrateExistingTree(at: root)
        }
    ) async throws -> Result {
        let sourceRoot = sourceRoot.standardizedFileURL
        let targetRoot = targetRoot.standardizedFileURL
        guard !expectedCommit.payload.entries.isEmpty,
              ArkFileInstalledContentAccess.currentAuthorityExactlyMatches(
                expectedCommit,
                at: sourceRoot
              ) else {
            throw MigrationError.invalidSourceAuthority
        }
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(
            at: sourceRoot
        ),
        ArkFileContentActivationCoordinator.isJournalDefinitivelyAbsent(
            at: sourceRoot
        ) else {
            throw MigrationError.pendingContentRecovery
        }
        try rejectOccupiedTarget(targetRoot)

        let parent = targetRoot.deletingLastPathComponent()
        try ArkFileDataProtection.createProtectedDirectory(at: parent)
        let stagingRoot = parent.appendingPathComponent(
            ".legacy-protection-\(UUID().uuidString)",
            isDirectory: true
        )
        var didActivate = false
        defer {
            if !didActivate {
                try? FileManager.default.removeItem(at: stagingRoot)
            }
        }
        try ArkFileDataProtection.createProtectedDirectory(at: stagingRoot)

        let entries = expectedCommit.payload.entries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
        var seenCanonicalPaths = Set<String>()
        var migratedRelativePaths: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            guard let relativePath = safeRelativePath(entry.relativePath) else {
                throw MigrationError.unsafeSourcePath(entry.relativePath)
            }
            let canonical = ArkFileContentCanonicalPath.key(relativePath)
            guard seenCanonicalPaths.insert(canonical).inserted else {
                throw MigrationError.unsafeSourcePath(entry.relativePath)
            }
            let source = sourceRoot.appendingPathComponent(relativePath)
            guard let sourceIdentity = regularFileIdentity(
                at: source,
                under: sourceRoot
            ) else {
                throw MigrationError.sourceFileUnavailable(entry.relativePath)
            }
            guard sourceIdentity.byteCount == entry.byteCount else {
                throw MigrationError.sourceFileUnavailable(entry.relativePath)
            }
            let destination = stagingRoot.appendingPathComponent(relativePath)
            try ArkFileDataProtection.createProtectedDirectory(
                at: destination.deletingLastPathComponent()
            )
            guard Darwin.clonefile(
                source.fileSystemPath,
                destination.fileSystemPath,
                0
            ) == 0 else {
                throw MigrationError.copyOnWriteUnavailable(errno)
            }
            guard let destinationIdentity = regularFileIdentity(
                at: destination,
                under: stagingRoot
            ), destinationIdentity.byteCount == sourceIdentity.byteCount else {
                throw MigrationError.protectedFileUnavailable(entry.relativePath)
            }
            try ArkFileDataProtection.apply(toExistingItem: destination)
            try synchronizeFile(destination)
            migratedRelativePaths.append(relativePath)
        }

        try copyLegacyMetadata(
            from: sourceRoot,
            to: stagingRoot,
            excluding: ArkFileInstalledContentAccess.commitFileName
        )
        let installedTier = ArkFileContentTier.iOSInstallableTier(
            named: expectedCommit.payload.installedTier
        ) ?? .lite
        let hashlessEntries = entries.map {
            ArkFileInstalledContentAccess.CommitEntry(
                relativePath: $0.relativePath,
                tier: $0.tier,
                byteCount: $0.byteCount,
                sha256: nil
            )
        }
        let protectedCommit = try ArkFileInstalledContentAccess
            .makeMergedCommitRecord(
                previous: nil,
                replacingGroupPaths: Set(hashlessEntries.map(\.relativePath)),
                with: hashlessEntries,
                installedTier: installedTier,
                explicitlyRemovingPaths: Set(
                    expectedCommit.payload.explicitlyRemovedPaths ?? []
                )
            )
        try writeProtectedMarker(
            at: stagingRoot,
            installedTier: installedTier
        )
        try ArkFileInstalledContentAccess.writeCommitRecordDurably(
            protectedCommit,
            at: stagingRoot
        )
        try ArkFileDataProtection.apply(
            toExistingItem: stagingRoot.appendingPathComponent(
                ArkFileInstalledContentAccess.commitFileName
            )
        )
        try synchronizeDirectoryTree(stagingRoot)
        try await beforeActivation(stagingRoot)
        try Task.checkCancellation()

        let writer = try await acquireWriter()
        defer { writer.release() }
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(
            at: sourceRoot
        ),
        ArkFileContentActivationCoordinator.isJournalDefinitivelyAbsent(
            at: sourceRoot
        ),
        !ArkFileContentActivationCoordinator.isRecoveryFrozen(at: targetRoot),
        ArkFileContentActivationCoordinator.isJournalDefinitivelyAbsent(
            at: targetRoot
        ) else {
            throw MigrationError.pendingContentRecovery
        }
        let protectionResult = stagedTreeProtector(stagingRoot)
        guard protectionResult.isComplete,
              protectionResult.visitedItemCount > 0,
              protectionResult.protectedItemCount
                == protectionResult.visitedItemCount else {
            throw MigrationError.dataProtectionUnavailable
        }
        guard ArkFileInstalledContentAccess.currentAuthorityExactlyMatches(
            expectedCommit,
            at: sourceRoot
        ) else {
            throw MigrationError.sourceAuthorityChanged
        }
        try rejectOccupiedTarget(targetRoot)
        if directoryExists(targetRoot) {
            guard Darwin.rmdir(targetRoot.fileSystemPath) == 0 else {
                throw MigrationError.targetOccupied
            }
        }
        guard Darwin.rename(
            stagingRoot.fileSystemPath,
            targetRoot.fileSystemPath
        ) == 0 else {
            throw MigrationError.activationFailed
        }
        didActivate = true
        try synchronizeDirectory(parent)
        ArkFileInstalledContentAccess.reloadAfterContentCommit()
        guard ArkFileInstalledContentAccess.currentAuthorityExactlyMatches(
            protectedCommit,
            at: targetRoot
        ) else {
            throw MigrationError.activationFailed
        }
        await adoptProtectedRoot(targetRoot, protectedCommit)

        return Result(
            protectedRoot: targetRoot,
            migratedEntryCount: migratedRelativePaths.count,
            preservedLegacySourcePaths: migratedRelativePaths.sorted()
        )
    }

    private static func acquireWriter() async throws ->
        ArkFileManagedContentWriterToken {
        let retryNanoseconds: [UInt64] = [
            0, 50_000_000, 100_000_000, 150_000_000, 200_000_000,
            250_000_000, 250_000_000, 250_000_000
        ]
        for delay in retryNanoseconds {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task<Never, Never>.sleep(nanoseconds: delay)
            }
            if let token = ArkFileManagedContentConcurrencyGate
                .tryBeginWriterReservation() {
                return token
            }
        }
        throw MigrationError.contentWriterUnavailable
    }

    private static func rejectOccupiedTarget(_ target: URL) throws {
        var status = Darwin.stat()
        if Darwin.lstat(target.fileSystemPath, &status) != 0 {
            guard errno == ENOENT else {
                throw MigrationError.targetOccupied
            }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              let contents = try? FileManager.default.contentsOfDirectory(
                atPath: target.fileSystemPath
              ),
              contents.isEmpty else {
            throw MigrationError.targetOccupied
        }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var status = Darwin.stat()
        return Darwin.lstat(url.fileSystemPath, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFDIR
    }

    private static func safeRelativePath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.contains("\\"),
              !rawPath.contains("\0") else {
            return nil
        }
        let components = rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            return nil
        }
        return components.map(String.init).joined(separator: "/")
    }

    private static func regularFileIdentity(
        at url: URL,
        under root: URL
    ) -> FileIdentity? {
        let rootPath = descendantPrefix(
            for: root.standardizedFileURL.fileSystemPath
        )
        let lexicalPath = url.standardizedFileURL.fileSystemPath
        guard lexicalPath.hasPrefix(rootPath) else { return nil }
        let resolvedRootPath = root.resolvingSymlinksInPath()
            .standardizedFileURL.fileSystemPath
        let resolvedPath = url.resolvingSymlinksInPath()
            .standardizedFileURL.fileSystemPath
        guard resolvedPath.hasPrefix(
            descendantPrefix(for: resolvedRootPath)
        ) else { return nil }

        var status = Darwin.stat()
        guard Darwin.lstat(lexicalPath, &status) == 0,
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

    private static func descendantPrefix(for rawPath: String) -> String {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path == "/" ? "/" : path + "/"
    }

    private static func copyLegacyMetadata(
        from sourceRoot: URL,
        to stagingRoot: URL,
        excluding excludedName: String
    ) throws {
        let metadataNames = [
            ArkFileContentPackInstaller.contentRootManifestFileName,
            ArkFileContentPackInstaller.contentRootTierIndexFileName
        ]
        for name in metadataNames where name != excludedName {
            let source = sourceRoot.appendingPathComponent(name)
            guard regularFileIdentity(at: source, under: sourceRoot) != nil else {
                continue
            }
            let data = try Data(contentsOf: source)
            let destination = stagingRoot.appendingPathComponent(name)
            try ArkFileDurableAtomicWriter.write(
                data,
                to: destination
            )
            try ArkFileDataProtection.apply(toExistingItem: destination)
        }
    }

    private static func writeProtectedMarker(
        at root: URL,
        installedTier: ArkFileContentTier
    ) throws {
        let marker: [String: String] = [
            "format": "1",
            "product": "ArkFile",
            "bundleType": "managed-content-pack",
            "tier": installedTier.rawValue,
            "installCommitFile":
                ArkFileInstalledContentAccess.commitFileName,
            "installCommitRequired": "true",
            "storageScope": "application-support",
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(
            withJSONObject: marker,
            options: [.prettyPrinted, .sortedKeys]
        )
        let markerURL = root.appendingPathComponent(
            ArkFileContentPackInstaller.contentRootMarkerFileName
        )
        try ArkFileDurableAtomicWriter.write(
            data,
            to: markerURL
        )
        try ArkFileDataProtection.apply(toExistingItem: markerURL)
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw MigrationError.activationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MigrationError.activationFailed
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw MigrationError.activationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw MigrationError.activationFailed
        }
    }

    private static func synchronizeDirectoryTree(_ root: URL) throws {
        var directories = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                if (try? url.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true {
                    directories.append(url)
                }
            }
        }
        for directory in directories.sorted(by: {
            $0.pathComponents.count > $1.pathComponents.count
        }) {
            try synchronizeDirectory(directory)
        }
    }

}
