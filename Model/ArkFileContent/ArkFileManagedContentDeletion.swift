// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Darwin
import Foundation

enum ArkFileManagedContentDeletionError: LocalizedError {
    case contentInUse
    case contentChangeInProgress
    case invalidManagedPath(String)
    case invalidInstallAuthority
    case pendingActivation

    var errorDescription: String? {
        switch self {
        case .contentInUse:
            "This offline content is open or being shared nearby. Close it or stop Local Sharing, then try again."
        case .contentChangeInProgress:
            "ArkFile is already finishing another content change. Try removing this download again in a moment."
        case .invalidManagedPath(let path):
            "ArkFile refused to remove an unsafe managed-content path: \(path)"
        case .invalidInstallAuthority:
            "ArkFile could not verify the installed-content record, so it left the content in place."
        case .pendingActivation:
            "ArkFile is finishing a content update. Try removing the download again in a moment."
        }
    }
}

/// Explicit user-directed deletion of committed offline content.
///
/// Deletion is intentionally independent of commerce state. StoreKit refund or
/// revocation handling must never call this coordinator. A compatibility group
/// is removed under the same reader-priority mutation gate used by activation,
/// and checksummed authority is replaced before any payload byte is unlinked.
enum ArkFileManagedContentDeletionCoordinator {
    struct Operations: @unchecked Sendable {
        let writeAuthority: (ArkFileInstalledContentAccess.CommitRecord, URL) throws -> Void
        let reloadAuthority: () -> Void
        let unlinkFile: (URL) throws -> Void
        let removeItem: (URL) throws -> Void

        static let live = Operations(
            writeAuthority: { record, root in
                try ArkFileInstalledContentAccess.writeCommitRecordDurably(record, at: root)
            },
            reloadAuthority: {
                ArkFileInstalledContentAccess.reloadAfterContentCommit()
            },
            unlinkFile: { url in
                try unlinkRegularFileIfPresent(url)
            },
            removeItem: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    struct GroupRemovalResult: Equatable, Sendable {
        let removedRelativePaths: Set<String>
        let exclusionKeys: Set<String>
        let remainingEntryCount: Int
        /// Logical deletion is already durable when these paths are reported.
        /// Their bytes may remain as inaccessible orphans until a later retry.
        let cleanupFailurePaths: Set<String>
    }

    struct WholePackRemovalResult: Equatable, Sendable {
        let cleanupFailurePaths: Set<String>
    }

    static func removeInstalledGroup(
        requestedKey: String,
        requestedURL: URL,
        tier: ArkFileContentTier,
        managedContainerRoot: URL,
        activeRoot: URL,
        updateExclusionsAfterAuthority: (Set<String>, ArkFileContentTier) -> Void,
        operations: Operations = .live
    ) throws -> GroupRemovalResult {
        let container = managedContainerRoot.standardizedFileURL
        let root = activeRoot.standardizedFileURL
        try requireExpectedActiveRoot(root, managedContainerRoot: container)
        try validateDirectoryChain(to: root, under: container, allowsMissing: false)
        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else {
            throw ArkFileManagedContentDeletionError.contentChangeInProgress
        }
        defer {
            writerToken.release()
            ArkFileContentActivationCoordinator.retryDeferredCleanupIfPossible()
        }
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(at: root) else {
            throw ArkFileManagedContentDeletionError.pendingActivation
        }
        guard !pathExists(root.appendingPathComponent(
            ArkFileContentActivationCoordinator.journalFileName
        )) else {
            throw ArkFileManagedContentDeletionError.pendingActivation
        }

        let requestedRelativePath = try relativePath(of: requestedURL, under: root)
        guard let initialCommit = ArkFileInstalledContentAccess.currentCommitRecord(at: root),
              let requestedEntry = initialCommit.payload.entries.first(where: {
                  $0.relativePath.lowercased() == requestedRelativePath.lowercased()
              }),
              normalizedPath(root.appendingPathComponent(requestedEntry.relativePath))
                == normalizedPath(requestedURL) else {
            throw ArkFileManagedContentDeletionError.invalidInstallAuthority
        }
        let groupID = ArkFileContentCompatibilityPlanner.groupID(
            for: requestedEntry.relativePath
        )
        guard let mutationToken = ArkFileManagedContentConcurrencyGate.tryBeginMutation(
            affectedGroups: [groupID],
            writerToken: writerToken
        ) else {
            throw ArkFileManagedContentDeletionError.contentInUse
        }
        defer { mutationToken.release() }

        // Planning happened before the token so an existing emergency reader
        // wins immediately. Re-read authority after acquisition before touching
        // any path, in case another mutation completed in between.
        guard let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root),
              commit == initialCommit else {
            throw ArkFileManagedContentDeletionError.invalidInstallAuthority
        }
        let groupEntries = commit.payload.entries.filter {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath) == groupID
        }
        guard !groupEntries.isEmpty,
              groupEntries.contains(where: {
                  $0.relativePath.lowercased() == requestedEntry.relativePath.lowercased()
              }) else {
            throw ArkFileManagedContentDeletionError.invalidInstallAuthority
        }

        let targets = try groupEntries.map { entry -> URL in
            let target = root.appendingPathComponent(entry.relativePath).standardizedFileURL
            guard try relativePath(of: target, under: root) == entry.relativePath else {
                throw ArkFileManagedContentDeletionError.invalidManagedPath(
                    entry.relativePath
                )
            }
            try validateDirectoryChain(
                to: target.deletingLastPathComponent(),
                under: root,
                allowsMissing: true
            )
            try requireRegularFileOrAbsence(target)
            return target
        }

        let removedPaths = Set(groupEntries.map { $0.relativePath.lowercased() })
        let exclusionKeys = removedPaths.union([requestedKey.lowercased()])
        let remainingEntries = commit.payload.entries.filter {
            !removedPaths.contains($0.relativePath.lowercased())
        }
        let installedTier = ArkFileContentTier.iOSInstallableTier(
            named: commit.payload.installedTier
        ) ?? tier

        // Replace local-read authority while every old byte is still present.
        // Selection follows the durable authority so a crash can never hide a
        // still-authorized emergency title in the UI.
        let nextCommit: ArkFileInstalledContentAccess.CommitRecord
        if remainingEntries.isEmpty {
            // A missing commit is recoverable by design. Use an explicit,
            // checksummed empty authority so interrupted cleanup cannot cause
            // orphan bytes to be adopted as a legacy installation.
            nextCommit = try ArkFileInstalledContentAccess
                .makeExplicitEmptyCommitRecord(
                    installedTier: installedTier,
                    explicitlyRemovedPaths: removedPaths
                )
        } else {
            nextCommit = try ArkFileInstalledContentAccess.makeMergedCommitRecord(
                previous: commit,
                replacingGroupPaths: removedPaths,
                with: [],
                installedTier: installedTier,
                explicitlyRemovingPaths: removedPaths
            )
        }
        try installAuthority(nextCommit, at: root, operations: operations)
        updateExclusionsAfterAuthority(exclusionKeys, installedTier)

        // From here forward failures must never restore the old commit: it may
        // reference a partially unlinked group. Leave failed cleanup as
        // inaccessible orphan bytes and report it for a later retry instead.
        var cleanupFailures = Set<String>()
        for (entry, target) in zip(groupEntries, targets) {
            do {
                try operations.unlinkFile(target)
            } catch {
                cleanupFailures.insert(entry.relativePath.lowercased())
            }
        }
        return GroupRemovalResult(
            removedRelativePaths: removedPaths,
            exclusionKeys: exclusionKeys,
            remainingEntryCount: remainingEntries.count,
            cleanupFailurePaths: cleanupFailures
        )
    }

    static func removeWholePack(
        managedContainerRoot: URL,
        activeRoot: URL,
        downloadRoot: URL,
        operations: Operations = .live
    ) throws -> WholePackRemovalResult {
        guard let writerToken = ArkFileManagedContentConcurrencyGate
            .tryBeginWriterReservation() else {
            throw ArkFileManagedContentDeletionError.contentChangeInProgress
        }
        defer {
            writerToken.release()
            ArkFileContentActivationCoordinator.retryDeferredCleanupIfPossible()
        }
        guard !ArkFileContentActivationCoordinator.isRecoveryFrozen(
            at: activeRoot
        ) else {
            throw ArkFileManagedContentDeletionError.pendingActivation
        }
        guard let mutationToken = ArkFileManagedContentConcurrencyGate
            .tryBeginAllContentMutation(writerToken: writerToken) else {
            throw ArkFileManagedContentDeletionError.contentInUse
        }
        defer { mutationToken.release() }

        let container = managedContainerRoot.standardizedFileURL
        let active = activeRoot.standardizedFileURL
        let downloads = downloadRoot.standardizedFileURL
        try requireExpectedActiveRoot(active, managedContainerRoot: container)
        try requireExpectedDownloadRoot(downloads, managedContainerRoot: container)
        let roots = [active, downloads]
        for root in roots {
            try validateDirectoryChain(to: root, under: container, allowsMissing: true)
        }
        guard !pathExists(active.appendingPathComponent(
            ArkFileContentActivationCoordinator.journalFileName
        )) else {
            throw ArkFileManagedContentDeletionError.pendingActivation
        }

        // Keep the active root and its checksummed empty authority in place.
        // Recursively removing the root would also remove the authority; a
        // crash during cleanup could then let surviving bytes be re-adopted by
        // legacy recovery on the next launch.
        if !pathExists(active) {
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: true
            )
        }
        try validateDirectoryChain(to: active, under: container, allowsMissing: false)
        let installedTier = ArkFileInstalledContentAccess.currentCommitRecord(at: active)
            .flatMap { ArkFileContentTier.iOSInstallableTier(named: $0.payload.installedTier) }
            ?? .lite
        let emptyAuthority = try ArkFileInstalledContentAccess.makeExplicitEmptyCommitRecord(
            installedTier: installedTier,
            explicitlyRemovedPaths: Set(
                ArkFileInstalledContentAccess.currentCommitRecord(at: active)?
                    .payload.entries.map { $0.relativePath.lowercased() } ?? []
            )
        )
        try installAuthority(emptyAuthority, at: active, operations: operations)

        var cleanupFailures = Set<String>()
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: active,
                includingPropertiesForKeys: nil,
                options: []
            ).filter { $0.lastPathComponent != ArkFileInstalledContentAccess.commitFileName }
            for child in children {
                do {
                    try validateDirectoryChain(
                        to: child.deletingLastPathComponent(),
                        under: active,
                        allowsMissing: false
                    )
                    try operations.removeItem(child)
                } catch {
                    cleanupFailures.insert(child.lastPathComponent)
                }
            }
        } catch {
            cleanupFailures.insert("Content/active")
        }

        if pathExists(downloads) {
            // Downloads contain no committed read authority and can be removed
            // as a tree once the wildcard reader gate is held.
            do {
                try validateDirectoryChain(to: downloads, under: container, allowsMissing: false)
                try operations.removeItem(downloads)
            } catch {
                cleanupFailures.insert("Downloads")
            }
        }
        operations.reloadAuthority()
        return WholePackRemovalResult(cleanupFailurePaths: cleanupFailures)
    }

    /// A durable atomic writer can report a directory-fsync failure after its
    /// rename has already installed the new record. Re-read exact authority so
    /// callers do not roll selection state back or leave the in-memory access
    /// cache stale when that happened.
    private static func installAuthority(
        _ authority: ArkFileInstalledContentAccess.CommitRecord,
        at activeRoot: URL,
        operations: Operations
    ) throws {
        do {
            try operations.writeAuthority(authority, activeRoot)
        } catch {
            guard ArkFileInstalledContentAccess.currentCommitRecord(at: activeRoot)
                    == authority else {
                throw error
            }
        }
        operations.reloadAuthority()
    }

    private static func requireExpectedActiveRoot(
        _ activeRoot: URL,
        managedContainerRoot: URL
    ) throws {
        let expected = managedContainerRoot
            .appendingPathComponent("Content", isDirectory: true)
            .appendingPathComponent("active", isDirectory: true)
        guard normalizedPath(activeRoot) == normalizedPath(expected) else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(
                normalizedPath(activeRoot)
            )
        }
    }

    private static func requireExpectedDownloadRoot(
        _ downloadRoot: URL,
        managedContainerRoot: URL
    ) throws {
        let expected = managedContainerRoot.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        guard normalizedPath(downloadRoot) == normalizedPath(expected) else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(
                normalizedPath(downloadRoot)
            )
        }
    }

    private static func requireRegularFileOrAbsence(_ url: URL) throws {
        var status = stat()
        if Darwin.lstat(normalizedPath(url), &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw ArkFileManagedContentDeletionError.invalidManagedPath(
                    url.fileSystemPath
                )
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func unlinkRegularFileIfPresent(_ url: URL) throws {
        var status = stat()
        let path = normalizedPath(url)
        guard Darwin.lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(path)
        }
        guard Darwin.unlink(path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func relativePath(of child: URL, under root: URL) throws -> String {
        let childPath = normalizedPath(child)
        let rootPath = normalizedPath(root)
        guard childPath != rootPath, childPath.hasPrefix(rootPath + "/") else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(childPath)
        }
        let relative = String(childPath.dropFirst(rootPath.count + 1))
        let normalized = try normalizedRelativePath(relative)
        guard normalized == relative else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(relative)
        }
        return normalized
    }

    private static func normalizedRelativePath(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasSuffix("/"),
              !normalized.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(path)
        }
        return normalized
    }

    private static func validateDirectoryChain(
        to directory: URL,
        under root: URL,
        allowsMissing: Bool
    ) throws {
        let directoryPath = normalizedPath(directory)
        let rootPath = normalizedPath(root)
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            throw ArkFileManagedContentDeletionError.invalidManagedPath(directoryPath)
        }

        func requireDirectory(_ path: String, mayBeMissing: Bool) throws -> Bool {
            var status = stat()
            if Darwin.lstat(path, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    throw ArkFileManagedContentDeletionError.invalidManagedPath(path)
                }
                return true
            }
            if errno == ENOENT, mayBeMissing { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard try requireDirectory(rootPath, mayBeMissing: allowsMissing) else { return }
        if directoryPath == rootPath { return }
        let relative = String(directoryPath.dropFirst(rootPath.count + 1))
        var current = rootPath
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty else {
                throw ArkFileManagedContentDeletionError.invalidManagedPath(directoryPath)
            }
            current += "/" + component
            guard try requireDirectory(current, mayBeMissing: allowsMissing) else { return }
        }
    }

    private static func pathExists(_ url: URL) -> Bool {
        var status = stat()
        if Darwin.lstat(normalizedPath(url), &status) == 0 { return true }
        return errno != ENOENT
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(normalizedPath(directory), O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
