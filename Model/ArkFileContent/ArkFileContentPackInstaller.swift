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

import Combine
import Darwin
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

final class ArkFileNetworkPreflightState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var didResolve = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let pendingResult: Result<Void, Error>?
        lock.lock()
        if let storedResult = self.pendingResult {
            pendingResult = storedResult
            self.pendingResult = nil
        } else if !didResolve {
            self.continuation = continuation
            pendingResult = nil
        } else {
            pendingResult = .failure(CancellationError())
        }
        lock.unlock()
        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return
        }
        didResolve = true
        if self.continuation != nil {
            continuation = self.continuation
            self.continuation = nil
        } else if pendingResult == nil {
            pendingResult = result
            continuation = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct ArkFileContentStoragePlan: Equatable, Sendable {
    let remainingGrowthBytes: Int64
    let largestInFlightBytes: Int64
    let safetyBytes: Int64

    var requiredAvailableBytes: Int64 {
        guard remainingGrowthBytes > 0 else { return 0 }
        return ArkFileContentStoragePreflight.addingWithoutOverflow(
            ArkFileContentStoragePreflight.addingWithoutOverflow(
                remainingGrowthBytes,
                max(0, largestInFlightBytes)
            ),
            max(0, safetyBytes)
        )
    }
}

struct ArkFileContentStorageEstimate: Equatable, Sendable {
    let contentBytes: Int64
    let requiredAvailableBytes: Int64
    let availableBytes: Int64?

    var hasEnoughReportedStorage: Bool? {
        guard let availableBytes else { return nil }
        return availableBytes >= requiredAvailableBytes
    }
}

struct ArkFileContentLocalDownloadProgress: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let completedBytes: Int64
        let totalBytes: Int64

        var isComplete: Bool {
            totalBytes > 0 && completedBytes >= totalBytes
        }
    }

    let selectedBytes: Int64
    let selectedFiles: Int
    let locallyVerifiedBytes: Int64
    let completedBytes: Int64
    let totalBytes: Int64
    let completedFiles: Int
    let totalFiles: Int
    let entriesByPath: [String: Entry]
    let locallyVerifiedActivePaths: Set<String>
    let locallyVerifiedPartialPaths: Set<String>

    var hasAccountingSnapshot: Bool {
        totalBytes > 0 || locallyVerifiedBytes > 0
    }

    func entry(for manifestEntry: ArkFilePackageManifest.Entry) -> Entry? {
        entriesByPath[ArkFileContentCanonicalPath.key(manifestEntry.normalizedRelativePath)]
    }
}

enum ArkFileContentCanonicalPath {
    private static let stableLocale = Locale(identifier: "en_US_POSIX")

    static func key(_ rawPath: String) -> String {
        rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: stableLocale)
            .lowercased(with: stableLocale)
    }
}

enum ArkFileContentDownloadPaths {
    /// The strict managed-root guard compares URL identity before the directory
    /// exists, so every producer must preserve the directory URL hint.
    static func managedDownloadRoot(in arkFileRoot: URL) -> URL {
        arkFileRoot.appendingPathComponent("Downloads", isDirectory: true)
    }

    static func partialDownloadURL(
        for entry: ArkFilePackageManifest.Entry,
        in downloadRoot: URL
    ) -> URL {
        let safeName = ArkFileContentCanonicalPath.key(entry.normalizedRelativePath)
            .replacingOccurrences(of: "/", with: "__")
            .appending(".arkdownload")
        return downloadRoot.appendingPathComponent(safeName)
    }

    static func isManagedPartialDownloadURL(_ url: URL, in downloadRoot: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let standardizedRoot = downloadRoot.standardizedFileURL
        let rootPath = standardizedRoot.fileSystemPath
        let filePath = standardizedURL.fileSystemPath
        guard filePath != rootPath else { return false }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix)
    }

    @discardableResult
    static func removeManagedPartialDownload(_ url: URL, in downloadRoot: URL) -> Bool {
        guard isManagedPartialDownloadURL(url, in: downloadRoot) else { return false }
        var info = stat()
        guard Darwin.lstat(url.fileSystemPath, &info) == 0 else {
            return errno == ENOENT
        }
        if Darwin.unlink(url.fileSystemPath) == 0 {
            return true
        }
        return false
    }
}

/// One no-follow authority for path-only managed partials. An incomplete file
/// is appendable/reusable only while it is a unique regular inode. A hard link
/// is accepted only after it is already complete and its full SHA-256 matches;
/// it is never opened for append. Symlinks and special files are never read.
enum ArkFileManagedPartialFile {
    enum Classification: Equatable {
        case missing
        case symbolicLink
        case regular(size: Int64, linkCount: UInt64)
        case other
    }

    static func classify(_ url: URL) throws -> Classification {
        var info = stat()
        guard Darwin.lstat(url.standardizedFileURL.fileSystemPath, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            return .symbolicLink
        case S_IFREG:
            return .regular(
                size: Int64(info.st_size),
                linkCount: UInt64(info.st_nlink)
            )
        default:
            return .other
        }
    }

    static func reusableByteCount(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Int64 {
        guard let classification = try? classify(url) else { return 0 }
        switch classification {
        case .regular(let size, _)
            where size == entry.sizeBytes && size >= 0:
            // Complete hard links are intentional zero-copy reuse only after
            // full content verification; they must never become append targets.
            return ArkFileContentFileVerifier.fileMatches(url, entry: entry)
                ? entry.sizeBytes : 0
        case .regular(let size, let linkCount)
            where linkCount == 1 && size > 0 && size < entry.sizeBytes:
            return size
        default:
            return 0
        }
    }

    static func hasVerifiedCompleteFile(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Bool {
        if case .matches = verificationOutcome(at: url, entry: entry) {
            return true
        }
        return false
    }

    static func verificationOutcome(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> ArkFileContentFileVerifier.VerificationOutcome {
        do {
            guard case .regular(let size, _) = try classify(url),
                  size == entry.sizeBytes else {
                return .definitiveMismatch
            }
            return ArkFileContentFileVerifier.verificationOutcome(
                at: url,
                entry: entry
            )
        } catch {
            return .unavailable(error)
        }
    }
}

enum ArkFileContentStoragePreflight {
    static let defaultSafetyBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let safetyHeadroomDivisor: Int64 = 10

    static func storagePlan(
        for manifest: ArkFilePackageManifest,
        activeRoot: URL,
        downloadRoot: URL,
        maximumTransientBytes: Int64,
        safetyBytes: Int64? = nil,
        startingAtFileIndex: Int = 0
    ) -> ArkFileContentStoragePlan {
        var remainingGrowthBytes: Int64 = 0
        var largestInFlightBytes: Int64 = 0

        for (index, entry) in manifest.files.enumerated() {
            guard index >= startingAtFileIndex else { continue }
            let activeURL = activeRoot.appendingPathComponent(entry.normalizedRelativePath)
            // Completed files only reduce the storage requirement after checksum verification.
            // The install loop verifies again before activation because files can change after this preflight.
            if hasVerifiedCompleteFile(at: activeURL, entry: entry) {
                continue
            }

            let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(for: entry, in: downloadRoot)
            if ArkFileManagedPartialFile.hasVerifiedCompleteFile(
                at: partialURL,
                entry: entry
            ) {
                continue
            }

            let reusablePartialBytes = reusablePartialByteCount(at: partialURL, entry: entry)
            let remainingBytes = max(0, entry.sizeBytes - reusablePartialBytes)
            guard remainingBytes > 0 else {
                continue
            }

            remainingGrowthBytes = addingWithoutOverflow(
                remainingGrowthBytes,
                remainingBytes
            )
            largestInFlightBytes = max(largestInFlightBytes, min(remainingBytes, maximumTransientBytes))
        }

        return ArkFileContentStoragePlan(
            remainingGrowthBytes: remainingGrowthBytes,
            largestInFlightBytes: largestInFlightBytes,
            safetyBytes: safetyBytes ?? Self.safetyBytes(for: remainingGrowthBytes)
        )
    }

    /// Reuses the checksum work from `localDownloadProgress` so storage
    /// preflight does not hash a multi-gigabyte installed library again.
    static func storagePlan(
        for manifest: ArkFilePackageManifest,
        transferProgress: ArkFileContentLocalDownloadProgress,
        maximumTransientBytes: Int64,
        safetyBytes: Int64? = nil,
        startingAtFileIndex: Int = 0
    ) -> ArkFileContentStoragePlan {
        var remainingGrowthBytes: Int64 = 0
        var largestInFlightBytes: Int64 = 0

        for (index, entry) in manifest.files.enumerated() where index >= startingAtFileIndex {
            guard let entryProgress = transferProgress.entry(for: entry) else {
                continue
            }
            let normalizedTotal = max(0, entryProgress.totalBytes)
            let normalizedCompleted = min(
                normalizedTotal,
                max(0, entryProgress.completedBytes)
            )
            let remainingBytes = normalizedTotal - normalizedCompleted
            guard remainingBytes > 0 else { continue }
            remainingGrowthBytes = addingWithoutOverflow(
                remainingGrowthBytes,
                remainingBytes
            )
            largestInFlightBytes = max(
                largestInFlightBytes,
                min(remainingBytes, maximumTransientBytes)
            )
        }

        return ArkFileContentStoragePlan(
            remainingGrowthBytes: remainingGrowthBytes,
            largestInFlightBytes: largestInFlightBytes,
            safetyBytes: safetyBytes ?? Self.safetyBytes(for: remainingGrowthBytes)
        )
    }

    /// Bounds a sequential compatibility-group update without reserving a
    /// second copy of every installed file. Growth that cannot be reclaimed is
    /// accumulated across all queued groups; bytes that replace an existing
    /// group contribute only the largest one-group overlap. Existing verified
    /// partials are already reflected in the volume's current free capacity and
    /// therefore contribute no future growth.
    ///
    /// The safety reserve deliberately remains based on all bytes still to be
    /// transferred, not just the largest group. This preserves the existing
    /// `max(2 GiB, 10%)` policy while reducing only the avoidable whole-pack
    /// replacement overlap.
    static func sequentialUpdateStoragePlan(
        groups: [ArkFileContentCompatibilityGroup],
        transferProgress: ArkFileContentLocalDownloadProgress,
        reclaimableBytesByGroupID: [ArkFileContentCompatibilityGroupID: Int64],
        maximumTransientBytes: Int64,
        safetyBytes: Int64? = nil,
        canonicalActiveRoot: URL? = nil
    ) -> ArkFileContentStoragePlan {
        var totalRemainingTransferBytes: Int64 = 0
        var unavoidableGrowthBytes: Int64 = 0
        var peakReplacementOverlapBytes: Int64 = 0
        var largestInFlightBytes: Int64 = 0

        for group in groups {
            var groupRemainingBytes: Int64 = 0
            for member in group.members {
                var remainingBytes = remainingTransferBytes(
                    for: member.entry,
                    transferProgress: transferProgress
                )
                if remainingBytes > 0,
                   let canonicalActiveRoot,
                   member.canonicalRelativePath.lowercased()
                    != ArkFileContentCanonicalPath.key(member.entry.normalizedRelativePath),
                   hasVerifiedCompleteFile(
                       at: canonicalActiveRoot.appendingPathComponent(
                           member.canonicalRelativePath
                       ),
                       entry: member.entry
                   ) {
                    remainingBytes = 0
                }
                groupRemainingBytes = addingWithoutOverflow(
                    groupRemainingBytes,
                    remainingBytes
                )
                totalRemainingTransferBytes = addingWithoutOverflow(
                    totalRemainingTransferBytes,
                    remainingBytes
                )
                largestInFlightBytes = max(
                    largestInFlightBytes,
                    min(remainingBytes, maximumTransientBytes)
                )
            }

            let reclaimableBytes = max(0, reclaimableBytesByGroupID[group.id] ?? 0)
            unavoidableGrowthBytes = addingWithoutOverflow(
                unavoidableGrowthBytes,
                max(0, groupRemainingBytes - reclaimableBytes)
            )
            peakReplacementOverlapBytes = max(
                peakReplacementOverlapBytes,
                min(groupRemainingBytes, reclaimableBytes)
            )
        }

        return ArkFileContentStoragePlan(
            remainingGrowthBytes: addingWithoutOverflow(
                unavoidableGrowthBytes,
                peakReplacementOverlapBytes
            ),
            largestInFlightBytes: largestInFlightBytes,
            safetyBytes: safetyBytes ?? Self.safetyBytes(for: totalRemainingTransferBytes)
        )
    }

    /// Counts only blocks that can plausibly be reclaimed after a successful
    /// group commit. Logical manifest size alone is not enough: sparse or
    /// compressed files may own fewer blocks, and an existing hard link means
    /// replacing the active pathname will not release those blocks.
    static func reclaimableBytesByGroupID(
        groups: [ArkFileContentCompatibilityGroup],
        commit: ArkFileInstalledContentAccess.CommitRecord,
        activeRoot: URL
    ) -> [ArkFileContentCompatibilityGroupID: Int64] {
        let committedByGroup = Dictionary(grouping: commit.payload.entries) {
            ArkFileContentCompatibilityPlanner.groupID(for: $0.relativePath)
        }
        var result: [ArkFileContentCompatibilityGroupID: Int64] = [:]

        for group in groups {
            let incomingPaths = Set(group.canonicalRelativePaths.map { $0.lowercased() })
            let committedEntries = committedByGroup[group.id] ?? []
            guard !committedEntries.isEmpty,
                  committedEntries.allSatisfy({ incomingPaths.contains($0.relativePath.lowercased()) }) else {
                continue
            }

            var reclaimableBytes: Int64 = 0
            for entry in committedEntries {
                let url = activeRoot.appendingPathComponent(entry.relativePath)
                guard let allocatedBytes = reclaimableAllocatedBytes(
                    at: url,
                    expectedLogicalBytes: entry.byteCount
                ) else {
                    continue
                }
                reclaimableBytes = addingWithoutOverflow(
                    reclaimableBytes,
                    allocatedBytes
                )
            }
            if reclaimableBytes > 0 {
                result[group.id] = reclaimableBytes
            }
        }
        return result
    }

    /// Recomputes storage from the exact group about to transfer. The active
    /// probe uses the planner's canonical destination, so a checksum-matching
    /// legacy/canonical file is reused without reserving download bytes.
    static func storagePlan(
        for group: ArkFileContentCompatibilityGroup,
        activeRoot: URL,
        downloadRoot: URL,
        maximumTransientBytes: Int64,
        safetyBytes: Int64
    ) -> ArkFileContentStoragePlan {
        var remainingGrowthBytes: Int64 = 0
        var largestInFlightBytes: Int64 = 0

        for member in group.members {
            let entry = member.entry
            let activeURL = activeRoot.appendingPathComponent(member.canonicalRelativePath)
            if hasVerifiedCompleteFile(at: activeURL, entry: entry) {
                continue
            }

            let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(
                for: entry,
                in: downloadRoot
            )
            if ArkFileManagedPartialFile.hasVerifiedCompleteFile(
                at: partialURL,
                entry: entry
            ) {
                continue
            }

            let reusableBytes = reusablePartialByteCount(at: partialURL, entry: entry)
            let remainingBytes = max(0, entry.sizeBytes - reusableBytes)
            remainingGrowthBytes = addingWithoutOverflow(
                remainingGrowthBytes,
                remainingBytes
            )
            largestInFlightBytes = max(
                largestInFlightBytes,
                min(remainingBytes, maximumTransientBytes)
            )
        }

        return ArkFileContentStoragePlan(
            remainingGrowthBytes: remainingGrowthBytes,
            largestInFlightBytes: largestInFlightBytes,
            safetyBytes: safetyBytes
        )
    }

    /// Builds user-facing transfer progress without counting files that are
    /// already installed. Incomplete partials remain part of transfer progress
    /// so a resumed file does not jump back to zero. A checksum-complete partial
    /// is considered local unless a persisted background record proves it is a
    /// just-finished transfer waiting for the foreground install loop.
    static func localDownloadProgress(
        for manifest: ArkFilePackageManifest,
        activeRoot: URL,
        downloadRoot: URL,
        trackedDownloadPaths: Set<String> = []
    ) -> ArkFileContentLocalDownloadProgress {
        var locallyVerifiedBytes: Int64 = 0
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var completedFiles = 0
        var entriesByPath: [String: ArkFileContentLocalDownloadProgress.Entry] = [:]
        var locallyVerifiedActivePaths = Set<String>()
        var locallyVerifiedPartialPaths = Set<String>()
        let normalizedTrackedPaths = Set(trackedDownloadPaths.map { $0.lowercased() })

        for entry in manifest.files {
            let normalizedPath = ArkFileContentCanonicalPath.key(entry.normalizedRelativePath)
            let activeURL = activeRoot.appendingPathComponent(entry.normalizedRelativePath)
            if hasVerifiedCompleteFile(at: activeURL, entry: entry) {
                locallyVerifiedBytes = addingWithoutOverflow(
                    locallyVerifiedBytes,
                    max(0, entry.sizeBytes)
                )
                locallyVerifiedActivePaths.insert(normalizedPath)
                continue
            }

            let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(for: entry, in: downloadRoot)
            if ArkFileManagedPartialFile.hasVerifiedCompleteFile(
                at: partialURL,
                entry: entry
            ),
               !normalizedTrackedPaths.contains(normalizedPath) {
                locallyVerifiedBytes = addingWithoutOverflow(
                    locallyVerifiedBytes,
                    max(0, entry.sizeBytes)
                )
                locallyVerifiedPartialPaths.insert(normalizedPath)
                continue
            }

            let reusableBytes = reusableDownloadedByteCount(at: partialURL, entry: entry) ?? 0
            let entryProgress = ArkFileContentLocalDownloadProgress.Entry(
                completedBytes: reusableBytes,
                totalBytes: entry.sizeBytes
            )
            entriesByPath[normalizedPath] = entryProgress
            completedBytes = addingWithoutOverflow(completedBytes, reusableBytes)
            totalBytes = addingWithoutOverflow(totalBytes, max(0, entry.sizeBytes))
            if entryProgress.isComplete {
                completedFiles += 1
            }
        }

        return ArkFileContentLocalDownloadProgress(
            selectedBytes: manifest.bytesIncluded,
            selectedFiles: manifest.files.count,
            locallyVerifiedBytes: locallyVerifiedBytes,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            totalFiles: entriesByPath.count,
            entriesByPath: entriesByPath,
            locallyVerifiedActivePaths: locallyVerifiedActivePaths,
            locallyVerifiedPartialPaths: locallyVerifiedPartialPaths
        )
    }

    /// Removes selected partial files that cannot be reused. Keeping these
    /// files until after storage preflight can make a device appear to have too
    /// little room even though the downloader would discard them immediately.
    /// Incomplete partials are retained because the range downloader can resume
    /// them; checksum-complete partials are retained only when valid.
    static func removeUnusablePartialDownloads(
        for manifest: ArkFilePackageManifest,
        downloadRoot: URL,
        classify: (URL) throws -> ArkFileManagedPartialFile.Classification = {
            try ArkFileManagedPartialFile.classify($0)
        }
    ) {
        for entry in manifest.files {
            let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(for: entry, in: downloadRoot)
            let shouldRetain: Bool
            do {
                switch try classify(partialURL) {
                case .missing:
                    shouldRetain = true
                case .regular(let size, let linkCount):
                    if size == entry.sizeBytes {
                        switch ArkFileManagedPartialFile.verificationOutcome(
                            at: partialURL,
                            entry: entry
                        ) {
                        case .matches, .unavailable:
                            shouldRetain = true
                        case .definitiveMismatch:
                            shouldRetain = false
                        }
                    } else {
                        shouldRetain = linkCount == 1
                            && size > 0
                            && size < entry.sizeBytes
                    }
                default:
                    shouldRetain = false
                }
            } catch {
                // Protected-data and transient metadata errors are not proof
                // that a purchased multi-gigabyte partial is invalid.
                shouldRetain = true
            }
            guard !shouldRetain else {
                continue
            }
            _ = ArkFileContentDownloadPaths.removeManagedPartialDownload(
                partialURL,
                in: downloadRoot
            )
        }
    }

    static func storageEstimate(
        contentBytes: Int64,
        maximumTransientBytes: Int64,
        safetyBytes: Int64? = nil,
        availableBytes: Int64?
    ) -> ArkFileContentStorageEstimate {
        ArkFileContentStorageEstimate(
            contentBytes: contentBytes,
            requiredAvailableBytes: addingWithoutOverflow(
                addingWithoutOverflow(
                    max(0, contentBytes),
                    max(0, maximumTransientBytes)
                ),
                max(0, safetyBytes ?? self.safetyBytes(for: contentBytes))
            ),
            availableBytes: availableBytes
        )
    }

    static func safetyBytes(for contentBytes: Int64) -> Int64 {
        guard contentBytes > 0 else { return defaultSafetyBytes }
        let quotient = contentBytes / safetyHeadroomDivisor
        let roundedTenPercent = quotient
            + (contentBytes % safetyHeadroomDivisor == 0 ? 0 : 1)
        return max(defaultSafetyBytes, roundedTenPercent)
    }

    static func availableCapacityForDownload(
        at root: URL = applicationSupportRootForPreflight()
    ) throws -> Int64? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        )
        // Prefer the "important usage" capacity: it is the number Settings shows
        // as free, because iOS purges caches and offloadable data on demand for
        // user-initiated downloads. The raw available capacity can under-report
        // by tens of gigabytes and contradicts what the user sees in Settings.
        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage,
           importantCapacity > 0 {
            return importantCapacity
        }
        if let availableCapacity = values.volumeAvailableCapacity {
            return Int64(availableCapacity)
        }
        return nil
    }

    static func applicationSupportRootForPreflight() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("ArkFile")
    }

    private static func reusablePartialByteCount(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Int64 {
        let reusableBytes = ArkFileManagedPartialFile.reusableByteCount(
            at: url,
            entry: entry
        )
        return reusableBytes < entry.sizeBytes ? reusableBytes : 0
    }

    private static func reusableDownloadedByteCount(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Int64? {
        let reusableBytes = ArkFileManagedPartialFile.reusableByteCount(
            at: url,
            entry: entry
        )
        return reusableBytes > 0 ? reusableBytes : nil
    }

    private static func hasVerifiedCompleteFile(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Bool {
        ArkFileContentFileVerifier.fileMatches(url, entry: entry)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: url.fileSystemPath
        )[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func remainingTransferBytes(
        for entry: ArkFilePackageManifest.Entry,
        transferProgress: ArkFileContentLocalDownloadProgress
    ) -> Int64 {
        let key = ArkFileContentCanonicalPath.key(entry.normalizedRelativePath)
        if transferProgress.locallyVerifiedActivePaths.contains(key)
            || transferProgress.locallyVerifiedPartialPaths.contains(key) {
            return 0
        }
        guard let progress = transferProgress.entry(for: entry) else {
            // A malformed/incomplete accounting snapshot must never reduce the
            // admission requirement.
            return max(0, entry.sizeBytes)
        }
        return max(0, progress.totalBytes - progress.completedBytes)
    }

    static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private static func reclaimableAllocatedBytes(
        at url: URL,
        expectedLogicalBytes: Int64
    ) -> Int64? {
        var fileInfo = stat()
        guard Darwin.lstat(url.fileSystemPath, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_size == expectedLogicalBytes,
              fileInfo.st_nlink == 1 else {
            return nil
        }
        let allocatedBytes = Int64(fileInfo.st_blocks) * 512
        guard allocatedBytes > 0 || expectedLogicalBytes == 0 else { return nil }
        return min(max(0, expectedLogicalBytes), max(0, allocatedBytes))
    }
}

/// Persists download customization independently for Essentials and Complete.
/// The install state still carries the active selection for resumability, but
/// it is no longer the source of truth for both products.
struct ArkFileContentSelectionStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "arkfile.content.selection.v2"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func excludedItemPaths(for tier: ArkFileContentTier) -> Set<String>? {
        guard defaults.object(forKey: key(for: tier)) != nil else {
            return nil
        }
        return Set((defaults.stringArray(forKey: key(for: tier)) ?? []).map { $0.lowercased() })
    }

    func saveExcludedItemPaths(_ paths: Set<String>, for tier: ArkFileContentTier) {
        defaults.set(paths.map { $0.lowercased() }.sorted(), forKey: key(for: tier))
    }

    func restoreExcludedItemPaths(_ paths: Set<String>?, for tier: ArkFileContentTier) {
        if let paths {
            saveExcludedItemPaths(paths, for: tier)
        } else {
            defaults.removeObject(forKey: key(for: tier))
        }
    }

    func loadDownloadQueue() -> ArkFileContentDownloadQueue {
        guard let data = defaults.data(forKey: "\(keyPrefix).pending-downloads"),
              let queue = try? JSONDecoder().decode(ArkFileContentDownloadQueue.self, from: data),
              queue.requests.allSatisfy({ $0.tier.isIOSInstallable }) else {
            return ArkFileContentDownloadQueue()
        }
        return queue
    }

    func saveDownloadQueue(_ queue: ArkFileContentDownloadQueue) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: "\(keyPrefix).pending-downloads")
    }

    /// Build 332 and earlier stored one shared exclusion set. A Complete state
    /// with no Complete-only exclusions was usually an Essentials selection
    /// carried into an upgrade, which is the unsafe 76+ GB default bug. Keep it
    /// with Essentials and let Complete receive its own conservative defaults.
    func migrateLegacySelectionIfNeeded(
        state: ArkFileContentInstallState,
        catalog: ArkFileContentCatalog?
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }
        guard let legacyPaths = state.excludedItemPaths else { return }
        let normalized = Set(legacyPaths.map { $0.lowercased() })
        let destinationTier: ArkFileContentTier
        if state.tier == .complete {
            let completeOnlyKeys = Set((catalog?.allItems ?? []).compactMap { item in
                item.isAvailableInEssentials ? nil : ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
            })
            destinationTier = normalized.isDisjoint(with: completeOnlyKeys) ? .lite : .complete
        } else {
            destinationTier = .lite
        }
        saveExcludedItemPaths(normalized, for: destinationTier)
    }

    private func key(for tier: ArkFileContentTier) -> String {
        "\(keyPrefix).\(tier.rawValue).excluded"
    }

    private var migrationKey: String {
        "\(keyPrefix).legacy-migrated"
    }
}

@MainActor
final class ArkFileContentPackInstaller: ObservableObject {
    static let shared = ArkFileContentPackInstaller()

    @Published private(set) var state: ArkFileContentInstallState
    @Published private(set) var purchaseHelpMessage: String?
    @Published private(set) var downloadFailureMessage: String?
    @Published private(set) var removalFailureMessage: String?
    @Published private(set) var downloadRemainingTimeText: String?
    @Published private(set) var deferredDownloadTier: ArkFileContentTier?
    @Published private(set) var restoreOutcome: ArkFileContentRestoreOutcome?
    @Published private(set) var entitlementFailureMessage: String?
    @Published private(set) var entitlementFailureAction: ArkFileContentEntitlementOutcomeAction?
    @Published private(set) var isRestoringPurchases = false
    @Published private(set) var isPurchasingWithoutDownload = false
    @Published private(set) var downloadQueue: ArkFileContentDownloadQueue

    private let purchaseManager: ArkFileLitePurchaseManager
    private let selectionStore: ArkFileContentSelectionStore
    private var installTask: Task<Void, Never>?
    private var purchaseManagerCancellable: AnyCancellable?
    private var ownershipCancellable: AnyCancellable?
    private var currentStoreKitProofCancellable: AnyCancellable?
    private var pendingAccessMintEvent: ArkFileStoreKitAccessMintEvent?
    private var downloadProgressCheckpoint: DownloadProgressCheckpoint?
    private var downloadRateSamples: [(sampledAt: Date, completedBytes: Int64)] = []
    private static var statusCatalog: ArkFileContentCatalog? {
        ArkFileContentReleaseProvider.shared.discoveryCatalog ?? (try? ArkFileContentCatalog.loadBundled())
    }
    private static let progressPersistenceMinimumBytes: Int64 = 128 * 1024 * 1024
    private static let progressPersistenceMinimumInterval: TimeInterval = 30
    // A rejected package-file request gets one re-mint. If StoreKit no longer
    // satisfies the tier (for example after a refund), park the download
    // instead of creating a retry storm.
    private static let authorizationRefreshRetryLimit = 1
    private static let authorizationRefreshRetryDelayNanoseconds: UInt64 = 250_000_000
    private static let deferredDownloadTierDefaultsKey = "arkfile.content.deferred-download-tier.v1"
    nonisolated static let contentRootMarkerFileName = ".arkfile-content-root.json"
    nonisolated static let contentRootManifestFileName = ".arkfile-content-manifest.json"
    nonisolated static let contentRootTierIndexFileName = ".arkfile-content-tier-index.json"
    nonisolated static let contentRootCommitFileName = ArkFileInstalledContentAccess.commitFileName
    private static let minimumInstalledCatalogCoverage = 0.95
    private static let recoverableRootMinimumReadableItems = 2
    private static let readableContentExtensions = Set([
        "zim",
        "zimaa",
        "pdf",
        "zip",
        "jpg",
        "jpeg",
        "png",
        "gif",
        "webp",
        "bmp",
        "svg",
        "html",
        "htm",
        "pmtiles"
    ])
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private struct DownloadProgressCheckpoint {
        let completedBytes: Int64
        let persistedAt: Date
    }

    private init(
        purchaseManager: ArkFileLitePurchaseManager = .shared,
        selectionStore: ArkFileContentSelectionStore = ArkFileContentSelectionStore()
    ) {
        self.purchaseManager = purchaseManager
        self.selectionStore = selectionStore
        self.state = Self.loadPersistedState()
        self.downloadQueue = selectionStore.loadDownloadQueue()
        self.deferredDownloadTier = Self.loadDeferredDownloadTier()
        selectionStore.migrateLegacySelectionIfNeeded(
            state: self.state,
            catalog: try? ArkFileContentCatalog.loadBundled()
        )
        if let tier = self.state.tier,
           let selection = selectionStore.excludedItemPaths(for: tier) {
            self.state.excludedItemPaths = selection.isEmpty ? nil : selection
        }
        var recoveredQueue = ArkFileContentDownloadQueue()
        recoveredQueue.isPaused = self.downloadQueue.isPaused
        let activeKeys = self.state.normalizedAddedItemPaths
        let activeFoundation = Self.includesMapFoundationForActiveRequest(self.state) || activeKeys.contains {
            ArkFileContentCompatibilityPlanner.groupID(for: $0).rawValue.hasPrefix("map-region:")
        }
        for request in self.downloadQueue.requests {
            recoveredQueue.append(
                request, activeItemKeys: activeKeys,
                activeIncludesMapFoundation: activeFoundation
            )
        }
        self.downloadQueue = recoveredQueue
        selectionStore.saveDownloadQueue(recoveredQueue)
        // Persist launch-time migrations (including legacy unsafe-manifest
        // copy sanitization) so an old internal path cannot return next launch.
        Self.persist(state: self.state)
        self.purchaseManagerCancellable = purchaseManager.$lastAccessMintedEvent
            .compactMap { $0 }
            .sink { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleAccessMinted(event)
                }
            }
        self.ownershipCancellable = purchaseManager.$ownershipSnapshot
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
        self.currentStoreKitProofCancellable = Publishers.CombineLatest(
            purchaseManager.$currentStoreKitProofTier,
            purchaseManager.$hasResolvedCurrentStoreKitProof
        )
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
    }

    var isBusy: Bool {
        ArkFileContentUpdateCoordinator.shared.isBusy || isPerformingOtherOperation
    }

    /// Work that conflicts with the separate content-update coordinator. Its
    /// own running update must not disable that update's Pause/Cancel controls.
    var isPerformingOtherOperation: Bool {
        installTask != nil || state.phase.isBusy
            || isRestoringPurchases
            || isPurchasingWithoutDownload
    }

    var canPauseLiteDownload: Bool {
        Self.canPauseLiteDownload(phase: state.phase)
    }

    var canCancelCurrentDownload: Bool {
        Self.canCancelCurrentDownload(state: state)
    }

    var currentDownloadDisplayName: String? {
        guard canCancelCurrentDownload else { return nil }
        let currentKey = state.currentFile.lowercased()
        if ArkFileContentCompatibilityPlanner.groupID(for: currentKey).rawValue == "map-core" {
            return "Map detail & places"
        }
        if let catalog = try? ArkFileContentCatalog.loadBundled() {
            let requestKey = Self.catalogRequestKey(for: currentKey, catalog: catalog)
            if let match = catalog.allItems.first(where: {
                ArkFileContentCanonicalPath.key($0.normalizedRelativePath) == requestKey
            }) {
                return ArkFileContentDisplayName.displayName(
                    for: match.name,
                    relativePath: match.normalizedRelativePath
                )
            }
        }
        return URL(fileURLWithPath: state.currentFile).deletingPathExtension().lastPathComponent
    }

    var canRestoreLite: Bool {
        !isBusy && state.phase != .installed
    }

    var hasPendingStoreKitPurchase: Bool {
        purchaseManager.hasPendingLitePurchaseForCurrentAccount
    }

    var isCheckingApplePurchases: Bool {
        purchaseManager.isCheckingApplePurchases
    }

    var hasCurrentStoreKitProof: Bool {
        purchaseManager.hasCurrentStoreKitProof
    }

    func hasCurrentStoreKitProof(for tier: ArkFileContentTier) -> Bool {
        if Brand.hasDeveloperContentAuthToken {
            return tier.isIOSInstallable
        }
        return switch (purchaseManager.currentStoreKitProofTier, tier) {
        case (.complete, .lite), (.complete, .complete), (.lite, .lite):
            true
        case (_, .standard), (.none, _), (.lite, .complete), (.standard, _):
            false
        }
    }

    var hasResolvedCurrentStoreKitProof: Bool {
        purchaseManager.hasResolvedCurrentStoreKitProof
    }

    var hasAuthoritativeNoPurchase: Bool {
        purchaseManager.hasResolvedCurrentStoreKitProof
            && purchaseManager.ownershipSnapshot == .notOwned
    }

    var hasSavedLiteAccess: Bool {
        Self.hasSavedAccess(
            for: .lite,
            ownership: purchaseManager.ownershipSnapshot,
            hasCachedAccess: purchaseManager.hasCachedLiteContentAccess,
            isLiteRevoked: purchaseManager.isLiteAccessRevoked,
            isCompleteRevoked: purchaseManager.isCompleteAccessRevoked,
            hasDeveloperAuthorization: Brand.hasDeveloperContentAuthToken
        )
    }

    var hasSavedCompleteAccess: Bool {
        Self.hasSavedAccess(
            for: .complete,
            ownership: purchaseManager.ownershipSnapshot,
            hasCachedAccess: purchaseManager.hasCachedCompleteContentAccess,
            isLiteRevoked: purchaseManager.isLiteAccessRevoked,
            isCompleteRevoked: purchaseManager.isCompleteAccessRevoked,
            hasDeveloperAuthorization: false
        )
    }

    nonisolated static func hasSavedAccess(
        for tier: ArkFileContentTier,
        ownership: ArkFileStoreKitOwnershipState,
        hasCachedAccess: Bool,
        isLiteRevoked: Bool,
        isCompleteRevoked: Bool,
        hasDeveloperAuthorization: Bool
    ) -> Bool {
        switch tier {
        case .lite:
            if hasDeveloperAuthorization {
                return true
            }
            guard !isLiteRevoked else {
                return false
            }
            return hasCachedAccess || ownership.owns(.lite)
        case .complete:
            guard !isLiteRevoked, !isCompleteRevoked else {
                return false
            }
            return hasCachedAccess || ownership.owns(.complete)
        case .standard:
            return false
        }
    }

    var installedTier: ArkFileContentTier? {
        state.phase == .installed ? state.tier : nil
    }

    var isLiteAccessRevoked: Bool {
        purchaseManager.isLiteAccessRevoked
    }

    var isCompleteAccessRevoked: Bool {
        purchaseManager.isCompleteAccessRevoked
    }

    var hasTransientPurchaseStatus: Bool {
        state.phase == .failed && Self.isTransientPurchaseMessage(state.errorMessage)
    }

    var shouldOfferCellularDownloadOverride: Bool {
        Self.shouldOfferCellularDownloadOverride(
            state: state,
            deferredTier: deferredDownloadTier,
            failureMessage: downloadFailureMessage
        )
    }

    nonisolated static func shouldOfferCellularDownloadOverride(
        state: ArkFileContentInstallState,
        deferredTier: ArkFileContentTier?,
        failureMessage: String?
    ) -> Bool {
        guard !state.phase.isBusy,
              !state.hasExplicitDownloadRequest || state.hasPendingExplicitDownloadRequest else { return false }
        if let deferredTier {
            return state.effectiveActiveDownloadRequestTier.map { $0 == deferredTier } ?? true
        }
        guard state.phase == .failed || state.phase == .readyToDownload
                || (state.phase == .installed && state.hasPendingExplicitDownloadRequest),
              let message = (failureMessage ?? state.errorMessage)?.lowercased() else {
            return false
        }
        return message.contains("wi-fi")
            || message.contains("wifi")
            || message.contains("low data")
            || message.contains("constrained")
    }

    var cellularDownloadOverrideTier: ArkFileContentTier? {
        guard shouldOfferCellularDownloadOverride else { return nil }
        return state.effectiveActiveDownloadRequestTier ?? deferredDownloadTier ?? state.tier ?? .lite
    }

    /// Recovery belongs to the stopped request, even when the installed pack
    /// shown behind it is a different tier. An explicit-empty request cannot
    /// authorize cellular transfer.
    var stoppedDownloadCellularRequest: ArkFilePendingContentDownload? {
        guard !isBusy, shouldOfferCellularDownloadOverride,
              let request = Self.stoppedDownloadRequest(in: state),
              request.tier == .complete ? hasSavedCompleteAccess : hasSavedLiteAccess else { return nil }
        return request
    }

    nonisolated static func stoppedDownloadRequest(
        in state: ArkFileContentInstallState
    ) -> ArkFilePendingContentDownload? {
        guard !state.phase.isBusy, state.hasPendingExplicitDownloadRequest,
              let tier = state.effectiveActiveDownloadRequestTier,
              tier.isIOSInstallable else { return nil }
        return ArkFilePendingContentDownload(
            tier: tier,
            itemKeys: state.normalizedAddedItemPaths,
            includesMapFoundation: state.includesMapFoundation == true
        )
    }

    var stoppedDownloadStatusText: String? {
        guard !isBusy else { return nil }
        return Self.stoppedDownloadStatusText(
            state: state,
            failureMessage: downloadFailureMessage,
            deferredTier: deferredDownloadTier
        )
    }

    /// First-install failures may only have a persisted error after partial
    /// content was committed. Keep that explanation visible after dismissing
    /// transient alerts or relaunching, without treating installed titles as
    /// failed downloads.
    nonisolated static func stoppedDownloadStatusText(
        state: ArkFileContentInstallState,
        failureMessage: String?,
        deferredTier: ArkFileContentTier?
    ) -> String? {
        guard let request = stoppedDownloadRequest(in: state) else { return nil }
        for message in [failureMessage, state.errorMessage] {
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return displayMessage(message, for: request.tier)
            }
        }
        if deferredTier == request.tier {
            return "This download is waiting for Wi-Fi. You can use cellular, hotspot, or Low Data Mode after reviewing the data-use warning."
        }
        return nil
    }

    var hasInstalledOrPartialContent: Bool {
        state.phase == .installed
            || state.completedBytes > 0
            || !state.activePath.isEmpty
    }

    var hasResumableLiteDownload: Bool {
        state.hasResumableDownloadProgress
    }

    var hasInterruptedLiteInstall: Bool {
        state.phase == .failed && Self.isInterruptedInstallMessage(state.errorMessage)
    }

    var needsLiteRepair: Bool {
        state.phase == .failed && Self.isIncompleteInstallMessage(state.errorMessage)
    }

    func hasResumableDownload(for tier: ArkFileContentTier) -> Bool {
        Self.isActiveDownloadTier(tier, activeTier: state.tier)
            && hasResumableLiteDownload
    }

    func hasInterruptedInstall(for tier: ArkFileContentTier) -> Bool {
        Self.isActiveDownloadTier(tier, activeTier: state.tier)
            && hasInterruptedLiteInstall
    }

    func needsRepair(for tier: ArkFileContentTier) -> Bool {
        Self.isActiveDownloadTier(tier, activeTier: state.tier)
            && needsLiteRepair
    }

    var liteButtonTitle: String {
        buttonTitle(for: .lite)
    }

    func buttonTitle(for tier: ArkFileContentTier) -> String {
        Self.buttonTitle(
            for: tier,
            activeTier: state.tier,
            phase: state.phase,
            needsRepair: needsLiteRepair,
            hasPendingStoreKitPurchase: hasPendingStoreKitPurchase,
            hasTransientPurchaseStatus: hasTransientPurchaseStatus,
            hasInterruptedInstall: hasInterruptedLiteInstall,
            hasResumableDownload: hasResumableLiteDownload,
            hasSavedAccess: tier == .complete ? hasSavedCompleteAccess : hasSavedLiteAccess
        )
    }

    nonisolated static func buttonTitle(
        for tier: ArkFileContentTier,
        activeTier: ArkFileContentTier? = nil,
        phase: ArkFileContentInstallPhase,
        needsRepair: Bool,
        hasPendingStoreKitPurchase: Bool,
        hasTransientPurchaseStatus: Bool,
        hasInterruptedInstall: Bool,
        hasResumableDownload: Bool,
        hasSavedAccess: Bool
    ) -> String {
        let appliesToRequestedTier = isActiveDownloadTier(tier, activeTier: activeTier)
        if (hasPendingStoreKitPurchase || hasTransientPurchaseStatus) && !phase.isBusy && phase != .installed {
            return "Restore Purchases"
        }
        if appliesToRequestedTier && needsRepair {
            return "Continue Download"
        }
        switch phase {
        case .purchasing:
            return LocalString.arkfile_lite_button_purchasing
        case .readyToDownload:
            return tier == .complete ? "Download Selected" : "Download Essentials"
        case .preparing:
            return LocalString.arkfile_lite_button_preparing
        case .downloading:
            return LocalString.arkfile_lite_button_downloading
        case .verifying:
            return LocalString.arkfile_lite_button_verifying
        case .installing:
            return LocalString.arkfile_lite_button_installing
        case .installed:
            return LocalString.arkfile_lite_button_installed
        case .idle, .failed:
            if appliesToRequestedTier && hasInterruptedInstall {
                return "Continue Download"
            }
            if appliesToRequestedTier && hasResumableDownload {
                return "Resume Download"
            }
            if shouldRetryFailedDownload(
                phase: phase,
                hasSavedAccess: appliesToRequestedTier && hasSavedAccess,
                hasPendingStoreKitPurchase: hasPendingStoreKitPurchase,
                hasTransientPurchaseStatus: hasTransientPurchaseStatus
            ) {
                return "Continue Download"
            }
            if hasSavedAccess {
                return tier == .complete ? "Download Selected" : "Download Essentials"
            }
            return LocalString.arkfile_lite_button_install
        }
    }

    nonisolated static func isActiveDownloadTier(
        _ tier: ArkFileContentTier,
        activeTier: ArkFileContentTier?
    ) -> Bool {
        // Legacy state without a recorded tier was Essentials-only. Treating a
        // nil tier as both packs can route an Essentials action into a failed
        // or resumable Complete transaction (and vice versa).
        (activeTier ?? .lite) == tier
    }

    func shouldRetryFailedDownload(for tier: ArkFileContentTier) -> Bool {
        guard Self.isActiveDownloadTier(tier, activeTier: state.tier) else { return false }
        return Self.shouldRetryFailedDownload(
            phase: state.phase,
            hasSavedAccess: tier == .complete ? hasSavedCompleteAccess : hasSavedLiteAccess,
            hasPendingStoreKitPurchase: hasPendingStoreKitPurchase,
            hasTransientPurchaseStatus: hasTransientPurchaseStatus
        )
    }

    nonisolated static func shouldRetryFailedDownload(
        phase: ArkFileContentInstallPhase,
        hasSavedAccess: Bool,
        hasPendingStoreKitPurchase: Bool,
        hasTransientPurchaseStatus: Bool
    ) -> Bool {
        // An already-owned pack retries through current-entitlement repair;
        // purchase-pending states retain the explicit Restore Purchases path.
        phase == .failed
            && hasSavedAccess
            && !hasPendingStoreKitPurchase
            && !hasTransientPurchaseStatus
    }

    var statusText: String? {
        statusText(for: state.tier ?? .lite)
    }

    func statusText(for tier: ArkFileContentTier) -> String? {
        if deferredDownloadTier == tier, !state.phase.isBusy {
            let packName = Self.packName(for: tier)
            return "\(packName) is unlocked and waiting to download. Use Wi-Fi by default, or choose cellular only if you are sure about the data use."
        }
        return Self.statusText(
            for: state,
            displayTier: tier,
            downloadProgressText: downloadingProgressText,
            resumableProgressText: resumableProgressText,
            failureText: Self.failedStatusText(
                errorMessage: state.errorMessage,
                resumableProgressText: resumableProgressText,
                displayTier: tier
            ),
            catalog: Self.statusCatalog
        )
    }

    /// A real failure must never be hidden by persisted byte counts from an
    /// earlier attempt. The retryable byte count remains available elsewhere,
    /// but the primary status first explains why this attempt stopped.
    nonisolated static func failedStatusText(
        errorMessage: String?,
        resumableProgressText: String?,
        displayTier: ArkFileContentTier
    ) -> String {
        if let errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayMessage(errorMessage, for: displayTier) ?? errorMessage
        }
        return resumableProgressText ?? LocalString.arkfile_lite_status_failed
    }

    nonisolated static func statusText(
        for state: ArkFileContentInstallState,
        displayTier: ArkFileContentTier,
        downloadProgressText: String?,
        resumableProgressText: String?,
        failureText: String?,
        catalog: ArkFileContentCatalog? = nil
    ) -> String? {
        let addLead = addedItemsStatusLead(for: state, catalog: catalog)
        let packName = Self.packName(for: displayTier)
        return switch state.phase {
        case .idle:
            resumableProgressText
        case .purchasing:
            prefixedStatus(LocalString.arkfile_lite_status_purchasing, lead: addLead)
        case .readyToDownload:
            "\(packName) is ready to download. Use Wi-Fi by default, or choose cellular only if you are sure about the data use."
        case .preparing:
            prefixedStatus(LocalString.arkfile_lite_status_preparing, lead: addLead)
        case .downloading:
            if let downloadProgressText, state.totalBytes > 0 {
                prefixedStatus(downloadProgressText, lead: addLead)
            } else if state.currentFile.isEmpty {
                prefixedStatus(LocalString.arkfile_lite_status_downloading, lead: addLead)
            } else {
                prefixedStatus(LocalString.arkfile_lite_status_downloading_file(withArgs: state.currentFile), lead: addLead)
            }
        case .verifying:
            prefixedStatus(checkingInstalledFilesStatusText(for: state), lead: addLead)
        case .installing:
            prefixedStatus(LocalString.arkfile_lite_status_installing, lead: addLead)
        case .installed:
            LocalString.arkfile_lite_status_installed
        case .failed:
            failureText
        }
    }

    private var downloadingProgressText: String {
        var progress = LocalString.arkfile_lite_status_downloading_progress(
            withArgs: Self.byteFormatter.string(fromByteCount: state.completedBytes),
            Self.byteFormatter.string(fromByteCount: state.totalBytes)
        )
        if let totalFiles = state.totalFiles, totalFiles > 0 {
            let completedFiles = min(state.completedFiles ?? 0, totalFiles)
            progress += " \(completedFiles) of \(totalFiles) files done."
        }
        guard let downloadRemainingTimeText else {
            return progress
        }
        return "\(progress) About \(downloadRemainingTimeText) remaining."
    }

    nonisolated static func addedItemsStatusLead(
        for state: ArkFileContentInstallState,
        catalog: ArkFileContentCatalog? = nil
    ) -> String? {
        let count = state.normalizedAddedItemPaths.count
        if count == 0, state.includesMapFoundation == true {
            return "Adding map detail & places"
        }
        guard count > 0 else { return nil }
        if count == 1 {
            let title = state.nonEmptyAddedItemNames.first ?? state.normalizedAddedItemPaths.first ?? "this title"
            let base = "Adding 1 download — \(title)"
            guard let catalog,
                  let selectedPath = state.normalizedAddedItemPaths.first,
                  let selectedItem = catalog.allItems.first(where: {
                      ArkFileContentCanonicalPath.key($0.normalizedRelativePath) == selectedPath
                  }) else {
                return base
            }
            let combinedBytes = state.totalBytes
            let supportingBytes = combinedBytes - selectedItem.sizeBytes
            guard state.phase == .downloading,
                  includesMapFoundationForActiveRequest(state)
                    || ArkFileContentCompatibilityPlanner.groupID(for: selectedPath).rawValue.hasPrefix("map-region:"),
                  supportingBytes >= 250_000_000 else {
                return base
            }
            let titleSize = formattedStatusBytes(selectedItem.sizeBytes)
            let combinedSize = formattedStatusBytes(combinedBytes)
            return "\(base) (\(titleSize)). Map detail & places and supporting files make this \(combinedSize) total"
        }
        return "Adding \(count) downloads"
    }

    nonisolated private static func formattedStatusBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func checkingInstalledFilesStatusText(for state: ArkFileContentInstallState) -> String {
        let checkingTotal = state.totalSelectedFiles ?? state.totalFiles
        let checkedCount = state.checkedFiles ?? state.completedFiles
        if let totalFiles = checkingTotal, totalFiles > 0 {
            let currentFileIndex = min(max((checkedCount ?? 0) + 1, 1), totalFiles)
            return "Checking installed files (\(currentFileIndex) of \(totalFiles)) — nothing is being re-downloaded."
        }
        if !state.currentFile.isEmpty {
            return "\(LocalString.arkfile_lite_status_verifying_file(withArgs: state.currentFile)) Nothing is being re-downloaded."
        }
        return "\(LocalString.arkfile_lite_status_verifying) Nothing is being re-downloaded."
    }

    private nonisolated static func prefixedStatus(_ status: String, lead: String?) -> String {
        guard let lead else { return status }
        return "\(lead). \(status)"
    }

    var resumableProgressText: String? {
        guard state.hasResumableDownloadProgress else {
            return nil
        }
        if state.totalBytes > 0 {
            let progress = "\(Self.byteFormatter.string(fromByteCount: state.completedBytes)) of \(Self.byteFormatter.string(fromByteCount: state.totalBytes)) downloaded."
            if state.completedBytes >= state.totalBytes && !state.phase.isBusy {
                return "\(progress) ArkFile still needs to verify and finish installing these files."
            }
            return state.phase.isBusy ? progress : "\(progress) Continue Download to pick up where it left off."
        }
        let progress = "\(Self.byteFormatter.string(fromByteCount: state.completedBytes)) downloaded."
        return state.phase.isBusy ? progress : "\(progress) Continue Download to pick up where it left off."
    }

    var shouldShowProgressBar: Bool {
        Self.shouldShowProgressBar(for: state)
    }

    nonisolated static func shouldShowProgressBar(for state: ArkFileContentInstallState) -> Bool {
        if state.phase.isBusy {
            return true
        }
        guard state.hasResumableDownloadProgress else {
            return false
        }
        return state.totalBytes <= 0 || state.completedBytes < state.totalBytes
    }

    func warningConfirmationTitle(for tier: ArkFileContentTier) -> String {
        if needsRepair(for: tier) {
            return "Continue Download"
        }
        return hasResumableDownload(for: tier) ? "Resume Download" : "Start Download"
    }

    var resumableInstallCopy: String? {
        guard let resumableProgressText else {
            return nil
        }
        guard !state.phase.isBusy else {
            return nil
        }
        return resumableProgressText
    }

    func resumableInstallCopy(for tier: ArkFileContentTier) -> String? {
        guard hasResumableDownload(for: tier) else { return nil }
        return resumableInstallCopy
    }

    var lockedContentDownloadActionTitle: String {
        if needsRepair(for: .lite) {
            return "Continue Download"
        }
        return hasResumableDownload(for: .lite) ? "Resume Download" : "Download Essentials"
    }

    var lockedContentDownloadMessageVerb: String {
        if needsRepair(for: .lite) {
            return "Continue Download"
        }
        return hasResumableDownload(for: .lite) ? "Resume Download" : "Download Essentials"
    }

    var excludedEssentialsItemKeys: Set<String> {
        excludedItemKeys(for: .lite)
    }

    func savedExcludedItemKeys(for tier: ArkFileContentTier) -> Set<String>? {
        selectionStore.excludedItemPaths(for: tier)
    }

    func excludedItemKeys(for tier: ArkFileContentTier) -> Set<String> {
        savedExcludedItemKeys(for: tier)
            ?? (try? ArkFileContentCatalog.loadBundled().defaultExcludedItemKeys(for: tier))
            ?? []
    }

    func estimatedSelectedContentBytes(for tier: ArkFileContentTier) -> Int64? {
        guard let catalog = try? ArkFileContentCatalog.loadBundled() else {
            return nil
        }
        let exclusions = excludedItemKeys(for: tier)
        var seenPaths = Set<String>()
        return catalog.allItems.reduce(into: Int64(0)) { total, item in
            let path = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
            guard item.isAvailable(in: tier),
                  !path.isEmpty,
                  !exclusions.contains(path),
                  seenPaths.insert(path).inserted else {
                return
            }
            total = ArkFileContentStoragePreflight.addingWithoutOverflow(
                total,
                max(0, item.sizeBytes)
            )
        }
    }

    /// Stores which catalog items the user deselected in the pre-download review.
    /// Empty means the full pack. Ignored while an install is running so the
    /// active download's bookkeeping stays consistent.
    func setExcludedEssentialsItemPaths(_ paths: Set<String>) {
        setExcludedItemPaths(paths, for: .lite)
    }

    func setExcludedItemPaths(_ paths: Set<String>, for tier: ArkFileContentTier) {
        guard !isBusy else { return }
        var newState = state
        // Only the selection is persisted here. The install flow sets state.tier
        // when it actually starts; flipping it now would make an installed
        // Essentials state report the new tier before purchase or download.
        let normalized = Set(paths.map(ArkFileContentCanonicalPath.key))
        selectionStore.saveExcludedItemPaths(normalized, for: tier)
        newState.excludedItemPaths = normalized.isEmpty ? nil : normalized
        newState.addedItemPaths = nil
        newState.addedItemNames = nil
        newState.activeDownloadRequestTier = nil
        newState.includesMapFoundation = nil
        replaceState(newState)
    }

    /// Saves the user's durable selection and snapshots the exact missing
    /// catalog titles authorized for the next transfer. This method does not
    /// start authorization or download work; the pack's normal install action
    /// consumes the request.
    func setDownloadSelection(
        excludedItemPaths: Set<String>,
        selectedItemPaths: Set<String>,
        tier: ArkFileContentTier
    ) {
        guard !isBusy, tier.isIOSInstallable else { return }
        let normalizedExclusions = Set(
            excludedItemPaths.map(ArkFileContentCanonicalPath.key)
        )
        let normalizedRequest = Set(
            selectedItemPaths.map(ArkFileContentCanonicalPath.key)
        ).subtracting(normalizedExclusions)
        let catalog = try? ArkFileContentCatalog.loadBundled()
        selectionStore.saveExcludedItemPaths(normalizedExclusions, for: tier)
        var newState = state
        newState.excludedItemPaths = normalizedExclusions.isEmpty
            ? nil : normalizedExclusions
        // Preserve an explicit empty set as distinct from nil. Nil means the
        // legacy saved-selection scope; an empty set means the review found no
        // missing title and must not silently widen into a full-pack transfer.
        newState.addedItemPaths = normalizedRequest
        newState.addedItemNames = Self.addedItemNames(
            for: normalizedRequest.sorted(),
            catalog: catalog
        )
        newState.activeDownloadRequestTier = tier
        newState.includesMapFoundation = false
        replaceState(newState)
    }

    /// An explicit title request changes neither installed coverage nor the
    /// selection shown next time Add Downloads opens.
    func includeEssentialsItemAndDownload(key: String) {
        includeItemAndDownload(key: key, tier: .lite)
    }

    func includeEssentialsItemsAndDownload(keys: [String]) {
        includeItemsAndDownload(keys: keys, tier: .lite)
    }

    func includeItemAndDownload(key: String, tier: ArkFileContentTier) {
        includeItemsAndDownload(keys: [key], tier: tier)
    }

    func includeItemsAndDownload(keys: [String], tier: ArkFileContentTier) {
        guard !keys.isEmpty else { return }
        enqueueDownload(ArkFilePendingContentDownload(tier: tier, itemKeys: Set(keys)))
    }

    func downloadMapFoundation() {
        enqueueDownload(ArkFilePendingContentDownload(
            tier: .lite, itemKeys: [], includesMapFoundation: true
        ))
    }

    /// Called only after the user asks to review a download. It reads current
    /// signed metadata and local files without starting transfers, changing the
    /// active request, linking partials, or cleaning download storage.
    func downloadPreview(
        keys: [String],
        tier: ArkFileContentTier,
        includesMapFoundation: Bool = false
    ) async throws -> ArkFileContentDownloadPreview {
        guard tier.isIOSInstallable else {
            throw ArkFileContentError.invalidManifestTier(tier.rawValue)
        }
        var authorization = try await purchaseManager.authorization(for: tier, allowPurchase: false)
        var lease = try purchaseManager.makeAcquisitionLease(for: tier)
        try validateAcquisitionLease(lease)
        let api = try ArkFileContentAPI(siteURL: Self.siteURL())
        // A partial library is never proof of a complete baseline. Request the
        // full signed manifest and then scope it to the explicit selection.
        let info = try await requestDownloadInfo(
            api: api, tier: tier, installedTier: nil,
            authorization: &authorization, acquisitionLease: &lease
        )
        guard info.installMode?.lowercased() == "manifest-v1",
              let objectKey = info.manifestObjectKey, !objectKey.isEmpty else {
            throw ArkFileContentError.invalidResponse
        }
        let manifest = try await packageManifest(
            api: api, objectKey: objectKey, tier: tier,
            authorization: &authorization, acquisitionLease: &lease
        )
        try validateAcquisitionLease(lease)
        _ = try ArkFileLocalSharingDispositionIndex.loadBundled()
            .trustedPackageManifest(for: manifest, expectedTier: tier)
        try manifest.validateForInstall(tier: tier)
        let selected = try Self.manifestFilteringDownloadRequest(
            manifest, catalog: try ArkFileContentCatalog.loadBundled(), tier: tier,
            savedExcludedItemKeys: [], explicitRequestedItemKeys: Set(keys),
            includesMapFoundation: includesMapFoundation
        )
        try Self.validateSelectedManifestSubset(selected, of: manifest)
        let activeRoot = try Self.activeContentRoot()
        let downloadRoot = try Self.downloadRoot()
        let trackedPaths = Self.trackedDownloadPaths(for: selected)
        let progress = await Task.detached(priority: .utility) {
            ArkFileContentStoragePreflight.localDownloadProgress(
                for: selected, activeRoot: activeRoot, downloadRoot: downloadRoot,
                trackedDownloadPaths: trackedPaths
            )
        }.value
        try validateAcquisitionLease(lease)
        return Self.downloadPreview(manifest: selected, progress: progress)
    }

    nonisolated static func downloadPreview(
        manifest: ArkFilePackageManifest,
        progress: ArkFileContentLocalDownloadProgress
    ) -> ArkFileContentDownloadPreview {
        let foundationBytes = manifest.files.reduce(into: Int64(0)) { total, entry in
            guard ArkFileContentCompatibilityPlanner.groupID(for: entry.normalizedRelativePath).rawValue == "map-core",
                  let pending = progress.entry(for: entry) else { return }
            total = ArkFileContentStoragePreflight.addingWithoutOverflow(
                total, max(0, pending.totalBytes - pending.completedBytes)
            )
        }
        return ArkFileContentDownloadPreview(
            selectedBytes: progress.selectedBytes,
            mapFoundationBytes: foundationBytes,
            downloadBytes: max(0, progress.totalBytes - progress.completedBytes)
        )
    }

    var queuedItemKeys: Set<String> { downloadQueue.itemKeys }
    var queuedDownloadCount: Int { downloadQueue.count }
    var hasQueuedStandaloneMapFoundation: Bool {
        downloadQueue.requests.contains { $0.includesMapFoundation && $0.itemKeys.isEmpty }
    }

    func isItemQueued(key: String) -> Bool {
        queuedItemKeys.contains(ArkFileContentCanonicalPath.key(key))
    }

    func downloadQueueState(for key: String) -> ArkFileDownloadQueueItemState {
        let normalized = ArkFileContentCanonicalPath.key(key)
        if state.normalizedAddedItemPaths.contains(normalized) {
            return activeDownloadIsRunning ? .active : .paused
        }
        return isItemQueued(key: normalized) ? .queued : .none
    }

    var mapFoundationQueueState: ArkFileDownloadQueueItemState {
        if activeRequestIncludesMapFoundation {
            return activeDownloadIsRunning ? .active : .paused
        }
        return downloadQueue.requests.contains(where: { requestIncludesMapFoundation($0) })
            ? .queued : .none
    }

    func removeQueuedItem(key: String) {
        downloadQueue.removeItem(key: key)
        selectionStore.saveDownloadQueue(downloadQueue)
    }

    func removeQueuedMapFoundation() {
        downloadQueue.requests.removeAll { $0.includesMapFoundation && $0.itemKeys.isEmpty }
        selectionStore.saveDownloadQueue(downloadQueue)
    }

    var canCancelPausedDownloadRequest: Bool {
        !isBusy && state.hasPendingExplicitDownloadRequest
    }

    /// Removes only the stopped batch's transfer intent. Installed content and
    /// reusable partials remain on disk; upcoming requests wait for Resume.
    @discardableResult
    func cancelPausedDownloadRequest() -> Bool {
        guard canCancelPausedDownloadRequest else { return false }
        let cleared = Self.stateAfterRemovingStoppedDownloadRequest(state)
        guard Self.persist(state: cleared) else {
            downloadFailureMessage = "ArkFile could not save this change. The stopped download is unchanged. Free some space or unlock this device, then try again."
            return false
        }
        state = cleared
        downloadProgressCheckpoint = nil
        downloadRateSamples.removeAll()
        downloadRemainingTimeText = nil
        downloadFailureMessage = nil
        setDeferredDownloadTier(nil)
        setDownloadQueuePaused(true)
        #if os(iOS) && canImport(ActivityKit)
        ArkFileEssentialsLiveActivityController.shared.update(with: state)
        #endif
        return true
    }

    nonisolated static func stateAfterRemovingStoppedDownloadRequest(
        _ state: ArkFileContentInstallState
    ) -> ArkFileContentInstallState {
        var cleared = state
        // Keep an explicit-empty marker: retained partials must not resurrect
        // an automatic legacy full-pack request on the next launch or retry.
        cleared.addedItemPaths = []
        cleared.addedItemNames = nil
        cleared.activeDownloadRequestTier = nil
        cleared.includesMapFoundation = false
        cleared.currentFile = ""
        cleared.errorMessage = nil
        if state.phase != .installed {
            cleared.phase = .readyToDownload
            cleared.completedBytes = 0
            cleared.totalBytes = 0
            cleared.selectedBytes = nil
            cleared.locallyVerifiedBytes = nil
            cleared.completedFiles = nil
            cleared.totalFiles = nil
            cleared.checkedFiles = nil
            cleared.totalSelectedFiles = nil
        }
        return cleared
    }

    /// Resuming is deliberate. Purchase, restore, and entitlement observation
    /// never call this method or consume queued requests.
    func resumeQueuedDownloads() {
        guard !isBusy else { return }
        setDownloadQueuePaused(false)
        if state.hasPendingExplicitDownloadRequest {
            resumeQueuedDownloadRequestIfPossible()
        } else {
            startNextQueuedDownload()
        }
    }

    private var activeRequestIncludesMapFoundation: Bool {
        state.hasPendingExplicitDownloadRequest && requestIncludesMapFoundation(
            ArkFilePendingContentDownload(
                tier: state.effectiveActiveDownloadRequestTier ?? .lite,
                itemKeys: state.normalizedAddedItemPaths,
                includesMapFoundation: Self.includesMapFoundationForActiveRequest(state)
            )
        )
    }

    private var activeDownloadIsRunning: Bool {
        installTask != nil && !isRestoringPurchases && !isPurchasingWithoutDownload
            && !downloadQueue.isPaused
    }

    private func requestIncludesMapFoundation(_ request: ArkFilePendingContentDownload) -> Bool {
        request.includesMapFoundation || request.itemKeys.contains {
            ArkFileContentCompatibilityPlanner.groupID(for: $0).rawValue.hasPrefix("map-region:")
        }
    }

    private func enqueueDownload(_ request: ArkFilePendingContentDownload) {
        guard request.tier.isIOSInstallable, !request.isEmpty,
              !isRestoringPurchases, !isPurchasingWithoutDownload else { return }
        // Conflicting editions cannot both become a user's selected Wikipedia.
        // A queued edition can be removed explicitly before choosing another.
        let outstandingKeys = queuedItemKeys.union(state.normalizedAddedItemPaths)
        if let catalog = try? ArkFileContentCatalog.loadBundled() {
            if Self.hasConflictingDownloadVariants(
                requestedKeys: request.itemKeys, outstandingKeys: outstandingKeys, catalog: catalog
            ) {
                downloadFailureMessage = ArkFileContentError.conflictingDownloadVariants.errorDescription
                return
            }
        }
        let hadPausedRequests = downloadQueue.isPaused && !downloadQueue.requests.isEmpty
        downloadQueue.append(
            request,
            activeItemKeys: state.normalizedAddedItemPaths,
            activeIncludesMapFoundation: activeRequestIncludesMapFoundation
        )
        selectionStore.saveDownloadQueue(downloadQueue)
        // A paused active request keeps its partial files and exact scope.
        // Adding another item never overwrites that resumable operation.
        if !isBusy, !state.hasPendingExplicitDownloadRequest, !hadPausedRequests {
            setDownloadQueuePaused(false)
            startNextQueuedDownload()
        }
    }

    private func setDownloadQueuePaused(_ paused: Bool) {
        downloadQueue.isPaused = paused
        selectionStore.saveDownloadQueue(downloadQueue)
    }

    private func startNextQueuedDownload() {
        guard installTask == nil, !state.phase.isBusy,
              !downloadQueue.isPaused, !downloadQueue.requests.isEmpty else { return }
        let request = downloadQueue.requests[0]
        var nextState = state
        nextState.addedItemPaths = request.itemKeys
        nextState.addedItemNames = request.includesMapFoundation
            ? ["Map detail & places"]
            : Self.addedItemNames(for: request.itemKeys.sorted(), catalog: try? ArkFileContentCatalog.loadBundled())
        nextState.activeDownloadRequestTier = request.tier
        nextState.includesMapFoundation = request.includesMapFoundation
        // Write active retry authority before removing its queue copy. A crash
        // between writes can at worst leave a duplicate, never lose the request.
        let activated = downloadQueue.takeNext { _ in Self.persist(state: nextState) }
        selectionStore.saveDownloadQueue(downloadQueue)
        guard activated != nil else {
            downloadFailureMessage = "ArkFile could not save this download request. Your queue and downloaded content are unchanged. Free some space or unlock this device, then resume downloads."
            return
        }
        state = nextState
        downloadProgressCheckpoint = nil
        startInstall(tier: request.tier, mode: .currentEntitlementOnly)
    }

    nonisolated static func excludedItemKeys(
        _ current: Set<String>,
        afterIncluding requestedKeys: [String],
        tier: ArkFileContentTier,
        catalog: ArkFileContentCatalog?
    ) -> Set<String> {
        var exclusions = current
        var requested = Set(requestedKeys.map { $0.lowercased() })
        guard let catalog else {
            for key in requested {
                exclusions.remove(key)
            }
            return exclusions
        }

        let items = ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            catalog.items(for: tier, category: category)
        }
        let keyedItems = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, ArkFileContentCatalogItem)? in
                let key = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
                return key.isEmpty ? nil : (key, item)
            }
        )
        let variantGroups = Dictionary(grouping: keyedItems) { _, item in
            item.normalizedVariantGroup ?? ""
        }

        for (group, keyedGroupItems) in variantGroups where !group.isEmpty {
            let groupKeys = Set(keyedGroupItems.map(\.key))
            let selectedGroupKeys = requested.intersection(groupKeys)
            guard !selectedGroupKeys.isEmpty else { continue }
            let selectedItems = keyedGroupItems
                .filter { selectedGroupKeys.contains($0.key) }
                .sorted { lhs, rhs in
                    if (lhs.value.variantDefault == true) != (rhs.value.variantDefault == true) {
                        return lhs.value.variantDefault == true
                    }
                    return lhs.key < rhs.key
                }
            guard let keyToKeep = selectedItems.first?.key else { continue }
            for key in groupKeys where key != keyToKeep {
                exclusions.insert(key)
            }
            requested.subtract(groupKeys)
            requested.insert(keyToKeep)
        }

        for key in requested {
            exclusions.remove(key)
        }
        return exclusions
    }

    nonisolated static func addedItemNames(
        for requestedKeys: [String],
        catalog: ArkFileContentCatalog?
    ) -> [String] {
        guard let catalog else { return [] }
        // The same relativePath can legitimately appear in more than one
        // catalog category (estimatedBytes dedupes for the same reason), so
        // this must not trap on duplicate keys.
        let keyedItems = Dictionary(
            catalog.allItems.compactMap { item -> (String, ArkFileContentCatalogItem)? in
                let key = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
                return key.isEmpty ? nil : (key, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var names: [String] = []
        var seen = Set<String>()
        for key in requestedKeys.map({ $0.lowercased() }) {
            guard seen.insert(key).inserted,
                  let item = keyedItems[key] else {
                continue
            }
            names.append(ArkFileContentDisplayName.displayName(
                for: item.name,
                relativePath: item.normalizedRelativePath
            ))
        }
        return names
    }

    /// Deletes one installed item's file to reclaim storage and records it as
    /// deselected, so coverage checks do not flag the pack for repair.
    /// Returns false when the file could not be removed.
    @discardableResult
    func removeInstalledEssentialsItem(key: String, fileURL: URL) -> Bool {
        removeInstalledItem(key: key, fileURL: fileURL, tier: .lite)
    }

    @discardableResult
    func removeInstalledItem(key: String, fileURL: URL, tier: ArkFileContentTier) -> Bool {
        // Only managed ArkFile pack content may be deleted; bundled samples and
        // anything outside the active content root are off limits.
        guard Self.canRemoveInstalledItem(
            isBusy: isBusy,
            tier: tier,
            isManagedURL: ArkFileEssentialsAccessGate.isManagedEssentialsURL(fileURL)
        ) else {
            removalFailureMessage = "ArkFile could not verify that this is removable managed content."
            return false
        }
        let originalState = state
        var mutatedSelectionTier: ArkFileContentTier?
        var originalExclusions: Set<String>?
        do {
            let managedRoot = try Self.applicationSupportRoot()
            let activeRoot = try Self.activeContentRoot()
            let result = try ArkFileManagedContentDeletionCoordinator.removeInstalledGroup(
                requestedKey: key,
                requestedURL: fileURL,
                tier: tier,
                managedContainerRoot: managedRoot,
                activeRoot: activeRoot,
                updateExclusionsAfterAuthority: { [self] addedKeys, installedTier in
                    mutatedSelectionTier = installedTier
                    originalExclusions = selectionStore.excludedItemPaths(for: installedTier)
                    var exclusions = originalExclusions
                        ?? (state.tier == installedTier
                            ? state.normalizedExcludedItemPaths
                            : (try? ArkFileContentCatalog.loadBundled()
                                .defaultExcludedItemKeys(for: installedTier)) ?? [])
                    exclusions.formUnion(addedKeys)
                    selectionStore.saveExcludedItemPaths(exclusions, for: installedTier)
                    if state.tier == installedTier {
                        var newState = state
                        newState.excludedItemPaths = exclusions
                        replaceState(newState)
                    }
                }
            )
            let committedTier = ArkFileInstalledContentAccess
                .currentCommitRecord(at: activeRoot)
                .flatMap {
                    ArkFileContentTier.iOSInstallableTier(
                        named: $0.payload.installedTier
                    )
                } ?? tier
            if let coverage = Self.installedCoverageItemKeys(
                at: activeRoot,
                catalog: try? ArkFileContentCatalog.loadBundled(),
                tier: committedTier
            ) {
                var updatedState = state
                updatedState.installedCoverageItemPaths = coverage
                replaceState(updatedState)
            }
            if result.cleanupFailurePaths.isEmpty {
                removalFailureMessage = nil
            } else {
                removalFailureMessage = "The title was removed from ArkFile, but some inaccessible file data could not be reclaimed yet. Restart the app and try Manage Downloads again."
            }
            Task {
                await LibraryOperations.reValidate()
                await ArkFileLocalContentLibrary.shared.refresh()
            }
            return true
        } catch {
            if let mutatedSelectionTier {
                selectionStore.restoreExcludedItemPaths(
                    originalExclusions,
                    for: mutatedSelectionTier
                )
            }
            replaceState(originalState)
            removalFailureMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Log.ContentPack.error(
                "Could not remove ArkFile \(tier.rawValue, privacy: .public) item: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    nonisolated static func canRemoveInstalledItem(
        isBusy: Bool,
        tier: ArkFileContentTier,
        isManagedURL: Bool
    ) -> Bool {
        !isBusy && tier.isIOSInstallable && isManagedURL
    }

    func installLite() {
        startInstall(
            mode: shouldRetryFailedDownload(for: .lite)
                ? .currentEntitlementOnly
                : .purchaseOrCurrentEntitlement
        )
    }

    func installComplete() {
        startInstall(
            tier: .complete,
            mode: shouldRetryFailedDownload(for: .complete)
                ? .currentEntitlementOnly
                : .purchaseOrCurrentEntitlement
        )
    }

    /// Completes StoreKit ownership without touching a paused download request
    /// or the pending queue. Continuing either still requires a download action.
    @discardableResult
    func purchasePackWithoutDownload(tier: ArkFileContentTier) -> Bool {
        guard !isBusy, tier.isIOSInstallable else { return false }
        return startInstall(
            tier: tier,
            mode: .purchaseOrCurrentEntitlementWithoutDownload
        )
    }

    @discardableResult
    func restoreComplete() -> Bool {
        startInstall(
            tier: .complete,
            mode: .restoreEntitlement
        )
    }

    /// Single Restore Purchases entry point (Settings): restores the highest
    /// tier this Apple Account owns, so Complete owners are not silently
    /// downgraded to an Essentials-only token.
    @discardableResult
    func restoreOwnedPacks() -> Bool {
        startInstall(
            mode: .restoreHighestOwnedEntitlement
        )
    }

    func repairComplete() {
        retryRequestedDownload(fallbackTier: .complete)
    }

    func repairLite() {
        retryRequestedDownload(fallbackTier: .lite)
    }

    func restoreLite() {
        startInstall(mode: .restoreEntitlement)
    }

    func installLiteAllowingCellularDownload() {
        retryRequestedDownload(
            fallbackTier: .lite,
            allowsCellularDownload: true
        )
    }

    func installCompleteAllowingCellularDownload() {
        retryRequestedDownload(
            fallbackTier: .complete,
            allowsCellularDownload: true
        )
    }

    /// A repair or cellular approval continues the stopped request, even when
    /// an older installed pack is the state currently displayed by the UI.
    private func retryRequestedDownload(
        fallbackTier: ArkFileContentTier,
        allowsCellularDownload: Bool = false
    ) {
        guard !isBusy,
              let tier = Self.downloadRetryTier(in: state, fallbackTier: fallbackTier) else {
            return
        }
        setDownloadQueuePaused(false)
        startInstall(
            tier: tier,
            mode: .currentEntitlementOnly,
            allowsCellularDownload: allowsCellularDownload
        )
    }

    nonisolated static func downloadRetryTier(
        in state: ArkFileContentInstallState,
        fallbackTier: ArkFileContentTier
    ) -> ArkFileContentTier? {
        if state.hasExplicitDownloadRequest || state.hasPendingExplicitDownloadRequest {
            // An explicit-empty marker records cancelled intent. Never turn
            // that marker into a legacy full-pack repair request.
            guard state.hasPendingExplicitDownloadRequest,
                  let tier = state.effectiveActiveDownloadRequestTier,
                  tier.isIOSInstallable else { return nil }
            return tier
        }
        return fallbackTier.isIOSInstallable ? fallbackTier : nil
    }

    func markInstalledContentIncomplete(installedCount: Int, expectedCount: Int) {
        guard !isBusy, state.phase == .installed else { return }
        var repairState = state
        repairState.phase = .failed
        repairState.currentFile = ""
        if let repairRoot = Self.managedContentRootWithAnyReadableContentIfAvailable(
            candidateRoots: [
                state.activePath.isEmpty ? nil : URL(fileURLWithPath: state.activePath),
                try? Self.activeContentRoot()
            ]
        ) {
            repairState.activePath = repairRoot.fileSystemPath
        }
        repairState.installedAt = nil
        repairState.errorMessage = Self.incompleteInstallMessage(
            installedCount: installedCount,
            expectedCount: expectedCount,
            tier: state.tier ?? .lite
        )
        replaceState(repairState)
    }

    func markInstalledContentRecovered(
        activeRoot: URL,
        installedCount: Int,
        expectedCount: Int
    ) {
        guard !isBusy,
              needsLiteRepair,
              expectedCount > 0,
              ArkFileLocalContentLibrary.hasSufficientInstalledCatalogCoverage(
                installedCount: installedCount,
                catalogItemCount: expectedCount
              ) else {
            return
        }
        var recoveredState = state
        recoveredState.tier = state.tier?.isIOSInstallable == true ? state.tier : .lite
        recoveredState.phase = .installed
        recoveredState.currentFile = ""
        recoveredState.activePath = activeRoot.fileSystemPath
        recoveredState.installedAt = recoveredState.installedAt ?? Date()
        recoveredState.errorMessage = nil
        recoveredState.addedItemPaths = nil
        recoveredState.addedItemNames = nil
        recoveredState.activeDownloadRequestTier = nil
        recoveredState.includesMapFoundation = nil
        let recoveredTier = recoveredState.tier ?? .lite
        recoveredState.installedCoverageItemPaths = Self.installedCoverageItemKeys(
            at: activeRoot,
            catalog: try? ArkFileContentCatalog.loadBundled(),
            tier: recoveredTier
        )
        replaceState(recoveredState)
    }

    func resumeInterruptedInstallIfPossible() {
        resumeInterruptedInstall(initiatedByUser: false)
    }

    func resumeInterruptedInstallByUser() {
        resumeInterruptedInstall(initiatedByUser: true)
    }

    private func resumeInterruptedInstall(initiatedByUser: Bool) {
        guard !isBusy,
              let tier = Self.interruptedDownloadRetryTier(
                in: state,
                queueIsPaused: downloadQueue.isPaused,
                initiatedByUser: initiatedByUser
              ) else { return }
        retryRequestedDownload(fallbackTier: tier)
    }

    nonisolated static func interruptedDownloadRetryTier(
        in state: ArkFileContentInstallState,
        queueIsPaused: Bool,
        initiatedByUser: Bool
    ) -> ArkFileContentTier? {
        guard initiatedByUser || !queueIsPaused,
              state.phase == .failed,
              isInterruptedInstallMessage(state.errorMessage) else { return nil }
        return downloadRetryTier(
            in: state,
            fallbackTier: state.tier?.isIOSInstallable == true ? state.tier ?? .lite : .lite
        )
    }

    /// Retries the exact persisted batch represented by `addedItemPaths`.
    /// This deliberately does not route through `includeItemAndDownload`,
    /// which would replace a multi-title queue with only the tapped row.
    func resumeQueuedDownloadRequestIfPossible() {
        guard installTask == nil,
              !state.phase.isBusy,
              (!state.normalizedAddedItemPaths.isEmpty || state.includesMapFoundation == true),
              let tier = state.effectiveActiveDownloadRequestTier,
              tier.isIOSInstallable else {
            return
        }
        setDownloadQueuePaused(false)
        startInstall(
            tier: tier,
            mode: .currentEntitlementOnly
        )
    }

    func dismissPurchaseHelpMessage() {
        purchaseHelpMessage = nil
    }

    func dismissRestoreOutcome() {
        restoreOutcome = nil
    }

    func dismissEntitlementFailure() {
        entitlementFailureMessage = nil
        entitlementFailureAction = nil
    }

    func dismissDownloadFailureMessage() {
        downloadFailureMessage = nil
    }

    func clearTransientPurchaseStatus() {
        purchaseHelpMessage = nil
        downloadFailureMessage = nil
        guard !isBusy,
              state.phase == .failed,
              Self.isTransientPurchaseMessage(state.errorMessage) else {
            return
        }
        updateState(
            phase: .idle,
            completedBytes: 0,
            totalBytes: 0,
            currentFile: "",
            errorMessage: nil
        )
    }

    func cancelLiteDownload() {
        guard isBusy else { return }
        setDownloadQueuePaused(true)
        installTask?.cancel()
        ArkFileContentBackgroundDownloadService.shared.cancelAll()
        // runInstall owns the terminal transition. In particular, an update
        // cancellation restores its previously installed presentation and
        // reports the paused attempt separately instead of hiding usable
        // emergency content behind a failed pack state.
    }

    /// Stops only the title currently transferring, removes its partial bytes,
    /// and takes it back out of the active selection. Already installed files
    /// are left alone. Remaining batch work stays stopped until the user makes
    /// another explicit download choice.
    @discardableResult
    func cancelCurrentDownloadAndDiscard() async -> Bool {
        guard Self.canCancelCurrentDownload(state: state) else { return false }
        setDownloadQueuePaused(true)
        let currentKey = state.currentFile.lowercased()
        // The install task may restore an older installed tier and selection
        // while cancellation waits. Keep the user's active request separate.
        let requestTier = state.effectiveActiveDownloadRequestTier ?? state.tier ?? .lite
        let requestExclusions = selectionStore.excludedItemPaths(for: requestTier)
            ?? state.normalizedExcludedItemPaths
        let catalog = try? ArkFileContentCatalog.loadBundled()
        let records = ArkFileContentBackgroundDownloadRecordStore().loadRecords()
        let record = records.first { record in
            Self.installRelativePath(for: record.entry, catalog: catalog).lowercased() == currentKey
                || ArkFileContentCanonicalPath.key(record.entry.normalizedRelativePath) == currentKey
        }

        let activeInstallTask = installTask
        activeInstallTask?.cancel()

        let removedPartial: Bool
        if let record, let downloadRoot = try? Self.downloadRoot() {
            removedPartial = await ArkFileContentBackgroundDownloadService.shared.cancelAndDiscard(
                recordID: record.id,
                expectedDownloadRoot: downloadRoot
            )
        } else {
            ArkFileContentBackgroundDownloadService.shared.cancelAll()
            removedPartial = false
        }

        await activeInstallTask?.value
        installTask = nil
        let cancelledState = Self.applyCancelledDownloadSelection(
            to: state,
            itemKey: Self.catalogRequestKey(for: currentKey, catalog: catalog),
            requestTier: requestTier,
            excludedItemPaths: requestExclusions,
            selectionStore: selectionStore
        )
        state = cancelledState
        downloadProgressCheckpoint = nil
        downloadRateSamples.removeAll()
        downloadRemainingTimeText = nil
        if !removedPartial {
            downloadFailureMessage = "The download stopped, but ArkFile could not safely remove its partial file. Your installed titles were not changed."
        }
        #if os(iOS) && canImport(ActivityKit)
        ArkFileEssentialsLiveActivityController.shared.update(with: cancelledState)
        #endif
        Self.persist(state: cancelledState)
        return removedPartial
    }

    func removeLiteContent() async {
        downloadQueue = ArkFileContentDownloadQueue()
        downloadQueue.isPaused = true
        selectionStore.saveDownloadQueue(downloadQueue)
        var previouslyInstalledState = state.phase == .installed ? state : nil
        let activeInstallTask = installTask
        activeInstallTask?.cancel()
        await activeInstallTask?.value
        installTask = nil
        if previouslyInstalledState == nil, state.phase == .installed {
            previouslyInstalledState = state
        }
        setDeferredDownloadTier(nil)
        do {
            let downloadRoot = try Self.downloadRoot()
            guard await ArkFileContentBackgroundDownloadService.shared
                .cancelAllAndDiscard(expectedDownloadRoot: downloadRoot) else {
                let message = "ArkFile could not safely stop and clear every active download. Your installed offline content was left in place. Restart the app and try Remove Download again."
                removalFailureMessage = message
                if let previouslyInstalledState {
                    restoreInstalledStateAfterAbortedInstall(previouslyInstalledState)
                    await ArkFileLocalContentLibrary.shared.refresh()
                } else {
                    updateState(phase: .failed, errorMessage: message)
                }
                return
            }
            let result = try Self.removeInstalledAndPartialContent()
            removalFailureMessage = result.cleanupFailurePaths.isEmpty
                ? nil
                : "ArkFile removed the pack from your library, but some inaccessible file data could not be reclaimed yet. Restart the app and try Remove Download again."
            replaceState(.idle)
            Task {
                await LibraryOperations.reValidate()
                await ArkFileLocalContentLibrary.shared.refresh()
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            removalFailureMessage = message
            if let preservedInstalledState = previouslyInstalledState.flatMap({
                Self.installedStateIfDurableAuthorityRemainsReadable($0)
            }) {
                restoreInstalledStateAfterAbortedInstall(preservedInstalledState)
                await ArkFileLocalContentLibrary.shared.refresh()
            } else {
                updateState(
                    phase: .failed,
                    errorMessage: "ArkFile could not remove the downloaded packs from this device. \(message)"
                )
            }
        }
    }

    func cancelActiveLiteDownloadAfterRevocation() {
        cancelActiveDownloadAfterRevocation(of: .lite)
    }

    func cancelActiveDownloadAfterRevocation(
        of tier: ArkFileContentTier,
        cancelCurrentInstallTask: Bool = true
    ) {
        // Commerce loss can stop an in-flight network transfer, but it must
        // never invoke explicit local-content deletion. Previously downloaded
        // emergency content remains governed only by its durable local commit.
        if tier == .lite || deferredDownloadTier == tier {
            setDeferredDownloadTier(nil)
        }
        guard Self.shouldCancelActiveDownload(state: state, revokedTier: tier) else { return }
        let packName = Self.packName(for: tier)
        downloadFailureMessage = "ArkFile could not confirm active \(packName) access for this Apple Account. Restore Purchases to continue this download."
        if cancelCurrentInstallTask {
            installTask?.cancel()
        }
        ArkFileContentBackgroundDownloadService.shared.cancelAll()
        // runInstall restores any prior installed state. A fresh install has
        // no local authority to preserve and will still transition to failed.
    }

    nonisolated static func shouldCancelActiveDownload(
        state: ArkFileContentInstallState,
        revokedTier: ArkFileContentTier
    ) -> Bool {
        guard state.phase.isBusy else { return false }
        switch revokedTier {
        case .lite:
            return true
        case .complete:
            return state.tier == .complete
        case .standard:
            return false
        }
    }

    @discardableResult
    private func startInstall(
        tier: ArkFileContentTier = .lite,
        mode: ArkFileContentAuthorizationMode,
        allowsCellularDownload: Bool = false,
        forceFullDownload: Bool = false
    ) -> Bool {
        guard installTask == nil else { return false }
        restoreOutcome = nil
        entitlementFailureMessage = nil
        entitlementFailureAction = nil
        purchaseHelpMessage = nil
        downloadFailureMessage = nil
        isRestoringPurchases = mode.isRestore
        isPurchasingWithoutDownload = mode == .purchaseOrCurrentEntitlementWithoutDownload
        installTask = Task { [weak self] in
            guard let self else { return }
            let didInstall = await self.runInstall(
                tier: tier,
                mode: mode,
                allowsCellularDownload: allowsCellularDownload,
                forceFullDownload: forceFullDownload
            )
            self.isRestoringPurchases = false
            self.isPurchasingWithoutDownload = false
            self.installTask = nil
            if mode.startsDownloadAfterAuthorization {
                if didInstall {
                    self.startNextQueuedDownload()
                } else {
                    self.setDownloadQueuePaused(true)
                }
            }
            self.processPendingAccessMintEventIfNeeded()
        }
        return true
    }

    private func runInstall(
        tier requestedTier: ArkFileContentTier,
        mode: ArkFileContentAuthorizationMode,
        allowsCellularDownload: Bool = false,
        forceFullDownload: Bool = false
    ) async -> Bool {
        guard !ArkFileContentUpdateCoordinator.shared.isBusy,
              !ArkFileContentUpdateCoordinator.shared.canResume else {
            downloadFailureMessage = "Resume or cancel the selected content update before starting another download."
            return false
        }
        // A pre-download failure (declined purchase, server rejection, storage
        // check) must not clobber a pack that is already installed: nothing on
        // disk has changed yet, so the installed state stays authoritative.
        var restorableInstalledState: ArkFileContentInstallState?
        var hasStartedContentMutation = false
        var tier = requestedTier
        let originallyRequestedTier = requestedTier
        var restoredAuthorization: ArkFileContentAuthorization?
        let preAuthorizationContentState = Self.contentStatePreservedDuringAuthorization(
            state,
            mode: mode
        )
        do {
            guard tier.isIOSInstallable else {
                throw ArkFileContentError.invalidManifestTier(tier.rawValue)
            }
            // A repair/full verification may replace bytes, but group commits
            // never invalidate untouched readable authority. Keep the prior
            // installed presentation available for every aborted update.
            restorableInstalledState = state.phase == .installed ? state : nil
            if case .restoreHighestOwnedEntitlement = mode {
                let restored = try await purchaseManager.restoreHighestOwnedAuthorization()
                tier = restored.tier
                restoredAuthorization = restored.authorization
            }
            if mode.appliesStoredDownloadSelection {
                applyStoredSelection(
                    for: tier,
                    catalog: try? ArkFileContentCatalog.loadBundled()
                )
            }
            let previousInstalledTier = restorableInstalledState?.tier
            if mode.startsDownloadAfterAuthorization {
                let previousCompletedBytes = state.completedBytes
                let previousTotalBytes = state.totalBytes
                updateState(
                    phase: .purchasing,
                    tier: tier,
                    completedBytes: state.hasResumableDownloadProgress ? previousCompletedBytes : 0,
                    totalBytes: state.hasResumableDownloadProgress ? previousTotalBytes : 0,
                    currentFile: "",
                    errorMessage: nil
                )
            }
            var authorization: ArkFileContentAuthorization
            switch mode {
            case .purchaseOrCurrentEntitlement,
                 .purchaseOrCurrentEntitlementWithoutDownload:
                authorization = try await purchaseManager.authorization(for: tier, allowPurchase: true)
            case .restoreEntitlement:
                authorization = try await purchaseManager.restoreAuthorization(for: tier)
            case .restoreHighestOwnedEntitlement:
                guard let restoredAuthorization else {
                    throw ArkFileContentError.invalidResponse
                }
                authorization = restoredAuthorization
            case .currentEntitlementOnly:
                authorization = try await purchaseManager.authorization(for: tier, allowPurchase: false)
            }
            authorization = authorization.allowingCellularDownload(allowsCellularDownload)
            guard mode.startsDownloadAfterAuthorization else {
                if let preAuthorizationContentState {
                    replaceState(preAuthorizationContentState)
                }
                restoreOutcome = ArkFileContentRestoreOutcome(
                    tier: tier,
                    requestedTier: mode == .restoreHighestOwnedEntitlement
                        ? tier
                        : originallyRequestedTier,
                    action: mode.isRestore ? .restored : .accessConfirmed
                )
                return false
            }
            var acquisitionLease = try purchaseManager.makeAcquisitionLease(
                for: tier
            )
            try validateAcquisitionLease(acquisitionLease)
            updateState(phase: .preparing)
            let siteURL = try Self.siteURL()
            let api = try ArkFileContentAPI(siteURL: siteURL)
            let downloadInfo = try await requestDownloadInfo(
                api: api,
                tier: tier,
                installedTier: state.hasExplicitDownloadRequest ? nil : previousInstalledTier,
                authorization: &authorization,
                acquisitionLease: &acquisitionLease
            )
            try validateAcquisitionLease(acquisitionLease)
            let installMode = downloadInfo.installMode?.lowercased() ?? "archive-v1"
            guard installMode == "manifest-v1" else {
                throw ArkFileContentError.unsupportedInstallMode(installMode)
            }
            guard let manifestObjectKey = downloadInfo.manifestObjectKey,
                  !manifestObjectKey.isEmpty else {
                throw ArkFileContentError.invalidResponse
            }
            let manifest = try await packageManifest(
                api: api,
                objectKey: manifestObjectKey,
                tier: tier,
                authorization: &authorization,
                acquisitionLease: &acquisitionLease
            )
            try validateAcquisitionLease(acquisitionLease)
            let installedCommit = ArkFileInstalledContentAccess.currentCommitRecord(at: try Self.activeContentRoot())
            let trustedManifest: ArkFileTrustedPackageManifest
            do {
                trustedManifest = try ArkFileLocalSharingDispositionIndex
                    .loadBundled()
                    .trustedPackageManifest(
                        for: manifest,
                        expectedTier: tier
                    ).includingVerifiedReleases(Self.verifiedReleasesForInstalledContent(commit: installedCommit))
            } catch {
                throw ArkFileContentError.appUpdateRequired(
                    "This app build does not recognize the content manifest selected by the service. Update ArkFile before retrying this download."
                )
            }
            try manifest.validateForInstall(tier: tier)
            let catalog = try? ArkFileContentCatalog.loadBundled()
            let explicitRequest = try Self.explicitRequestedItemKeys(
                in: state,
                for: tier
            )
            let requestedManifest = try Self.manifestFilteringDownloadRequest(
                manifest,
                catalog: catalog,
                tier: tier,
                savedExcludedItemKeys: state.normalizedExcludedItemPaths,
                explicitRequestedItemKeys: explicitRequest,
                includesMapFoundation: Self.includesMapFoundationForActiveRequest(state)
            )
            let selectedManifest = try Self.manifestPreservingSignedInstalledGroups(
                requestedManifest, commit: installedCommit)
            try Self.validateSelectedManifestSubset(
                selectedManifest,
                of: manifest
            )
            let downloadRoot = try Self.downloadRoot()
            // Compatibility aliases flatten into shared activation paths. Prove
            // the selected manifest has one admissible activation plan before
            // quiescence can cancel or reset any prior selected partial.
            let compatibilityGroups = ArkFileContentCompatibilityPlanner.groups(
                manifest: selectedManifest,
                catalog: catalog
            )
            try ArkFileContentCompatibilityPlanner.validateActivationPlan(
                compatibilityGroups,
                downloadRoot: downloadRoot
            )
            try await ArkFileContentBackgroundDownloadService.shared.quiesceStaleDownloads(
                for: selectedManifest,
                downloadRoot: downloadRoot
            )
            try validateAcquisitionLease(acquisitionLease)
            let transferProgress = try await preparedTransferProgress(for: selectedManifest)
            try validateAcquisitionLease(acquisitionLease)
            let storagePlan = try await ensureEnoughStorage(
                for: selectedManifest,
                transferProgress: transferProgress
            )
            try validateAcquisitionLease(acquisitionLease)
            try await ensureLargeDownloadNetworkIsReady(allowsCellularDownload: allowsCellularDownload)
            try validateAcquisitionLease(acquisitionLease)
            setDeferredDownloadTier(nil)
            hasStartedContentMutation = true
            try await install(
                manifest: selectedManifest,
                trustedManifest: trustedManifest,
                initialTransferProgress: transferProgress,
                api: api,
                authorization: authorization,
                storageSafetyBytes: storagePlan.safetyBytes,
                acquisitionLease: acquisitionLease
            )
            return !Task.isCancelled
        } catch is CancellationError {
            if let preAuthorizationContentState {
                replaceState(preAuthorizationContentState)
                return false
            }
            if let restorableInstalledState {
                downloadFailureMessage = downloadFailureMessage
                    ?? LocalString.arkfile_lite_status_paused
                restoreInstalledStateAfterAbortedInstall(restorableInstalledState)
                await ArkFileLocalContentLibrary.shared.refresh()
            } else if state.phase.isBusy {
                updateState(
                    phase: .failed,
                    errorMessage: downloadFailureMessage
                        ?? LocalString.arkfile_lite_status_paused
                )
            }
        } catch {
            if let preAuthorizationContentState {
                let underlyingError = (error as? ArkFileVerifiedRestoreAuthorizationError)?
                    .underlyingError ?? error
                if case ArkFileContentError.purchaseCancelled = underlyingError {
                    purchaseHelpMessage = "Purchase cancelled. You were not charged."
                    replaceState(preAuthorizationContentState)
                    return false
                }
                let message = (underlyingError as? LocalizedError)?.errorDescription
                    ?? underlyingError.localizedDescription
                if let confirmedOwnership = Self.entitlementOutcomeAfterAuthorizationFailure(
                    ownership: purchaseManager.ownershipSnapshot,
                    mode: mode,
                    requestedTier: tier,
                    error: error
                ) {
                    // Restore evidence came from this operation's verified
                    // proofs, not remembered access from an earlier account.
                    // The separate content authorization is still unavailable.
                    restoreOutcome = confirmedOwnership
                    entitlementFailureMessage = Self.statusMessage(
                        for: underlyingError,
                        fallback: message,
                        tier: confirmedOwnership.tier
                    )
                    entitlementFailureAction = confirmedOwnership.action
                } else if let purchaseHelpMessage = Self.purchaseHelpMessage(
                    for: underlyingError,
                    tier: tier,
                    authorizationMode: mode
                ) {
                    self.purchaseHelpMessage = purchaseHelpMessage
                } else {
                    entitlementFailureMessage = Self.statusMessage(
                        for: underlyingError,
                        fallback: message,
                        tier: tier
                    )
                    entitlementFailureAction = Self.entitlementFailureAction(
                        for: underlyingError,
                        mode: mode
                    )
                }
                replaceState(preAuthorizationContentState)
                return false
            }
            if case ArkFileContentError.purchaseCancelled = error {
                purchaseHelpMessage = "Purchase cancelled. You were not charged."
                if let restorableInstalledState {
                    restoreInstalledStateAfterAbortedInstall(restorableInstalledState)
                    await ArkFileLocalContentLibrary.shared.refresh()
                    return false
                }
                updateState(
                    phase: .idle,
                    tier: tier,
                    completedBytes: 0,
                    totalBytes: 0,
                    currentFile: "",
                    errorMessage: nil
                )
                return false
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let safeStatusMessage = Self.statusMessage(for: error, fallback: message, tier: tier)
            if let purchaseHelpMessage = Self.purchaseHelpMessage(
                for: error,
                tier: tier,
                authorizationMode: mode
            ) {
                self.purchaseHelpMessage = purchaseHelpMessage
            }
            // Record the network deferral before restoring an installed
            // snapshot. Its installed phase must not swallow the stopped
            // request's durable cellular recovery action.
            if !hasStartedContentMutation,
               Self.isDownloadNetworkDeferral(error) {
                setDeferredDownloadTier(tier)
                downloadFailureMessage = safeStatusMessage
                if let restorableInstalledState {
                    restoreInstalledStateAfterAbortedInstall(restorableInstalledState)
                    await ArkFileLocalContentLibrary.shared.refresh()
                } else {
                    updateState(
                        phase: .readyToDownload,
                        tier: tier,
                        currentFile: "",
                        errorMessage: nil
                    )
                }
                Log.ContentPack.info(
                    "ArkFile \(tier.rawValue, privacy: .public) access is ready; waiting for an allowed download network"
                )
                return false
            }
            if let preservedInstalledState = Self.installedStatePreservedAfterStorageFailure(
                error,
                previousInstalledState: restorableInstalledState
            ) {
                // Earlier compatibility groups may already have committed.
                // Their new bytes and every untouched old group remain valid
                // local authority, so low storage pauses the update without
                // presenting the installed emergency library as failed.
                downloadFailureMessage = safeStatusMessage
                restoreInstalledStateAfterAbortedInstall(preservedInstalledState)
                await ArkFileLocalContentLibrary.shared.refresh()
                Log.ContentPack.error(
                    "ArkFile \(tier.rawValue, privacy: .public) update paused for storage; kept installed content available: \(message, privacy: .public)"
                )
                return false
            }
            if let restorableInstalledState {
                if purchaseHelpMessage == nil {
                    downloadFailureMessage = downloadFailureMessage ?? safeStatusMessage
                }
                restoreInstalledStateAfterAbortedInstall(restorableInstalledState)
                await ArkFileLocalContentLibrary.shared.refresh()
                Log.ContentPack.error(
                    "ArkFile \(tier.rawValue, privacy: .public) update stopped; kept installed content available: \(message, privacy: .public)"
                )
                return false
            }
            if !hasStartedContentMutation && purchaseHelpMessage == nil {
                downloadFailureMessage = safeStatusMessage
            }
            updateState(phase: .failed, errorMessage: safeStatusMessage)
            Log.ContentPack.error("ArkFile \(tier.rawValue, privacy: .public) install failed: \(message, privacy: .public)")
        }
        return false
    }

    /// Puts the previously installed pack state back after an install attempt
    /// died before touching disk (declined purchase, entitlement or server
    /// failure, storage preflight). The failure itself is surfaced through the
    /// transient purchase-help alert, not by marking the installed pack broken.
    private func restoreInstalledStateAfterAbortedInstall(_ installedState: ArkFileContentInstallState) {
        replaceState(installedState)
        #if os(iOS) && canImport(ActivityKit)
        ArkFileEssentialsLiveActivityController.shared.update(with: state)
        #endif
    }

    /// A failed explicit removal may restore the installed presentation only
    /// while the exact checksummed local authority still authorizes every
    /// committed file. Once an explicit-empty authority is current, cleanup
    /// errors must not resurrect the removed pack in UI state.
    private static func installedStateIfDurableAuthorityRemainsReadable(
        _ installedState: ArkFileContentInstallState
    ) -> ArkFileContentInstallState? {
        guard installedState.phase == .installed,
              let activeRoot = try? activeContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: activeRoot),
              !commit.payload.entries.isEmpty,
              commit.payload.entries.allSatisfy({ entry in
                  let url = activeRoot.appendingPathComponent(entry.relativePath)
                  if case .committed = ArkFileInstalledContentAccess.decision(for: url) {
                      return true
                  }
                  return false
              }) else {
            return nil
        }
        var preserved = installedState
        preserved.activePath = activeRoot.fileSystemPath
        return preserved
    }

    nonisolated static func isStorageAdmissionFailure(_ error: Error) -> Bool {
        switch error {
        case ArkFileContentError.insufficientStorage(_, _),
             ArkFileContentError.storageAvailabilityUnavailable(_):
            true
        default:
            false
        }
    }

    /// Entitlement-only authorization is layered beside content transfer
    /// state. Every phase—including paused, failed, resumable, and an explicit
    /// queued request—must survive it byte-for-byte.
    nonisolated static func contentStatePreservedDuringAuthorization(
        _ state: ArkFileContentInstallState,
        mode: ArkFileContentAuthorizationMode
    ) -> ArkFileContentInstallState? {
        mode.startsDownloadAfterAuthorization ? nil : state
    }

    nonisolated static func entitlementOutcomeAfterAuthorizationFailure(
        ownership: ArkFileStoreKitOwnershipState,
        mode: ArkFileContentAuthorizationMode,
        requestedTier: ArkFileContentTier,
        error: Error? = nil
    ) -> ArkFileContentRestoreOutcome? {
        if mode.isRestore {
            guard let failure = error as? ArkFileVerifiedRestoreAuthorizationError else {
                return nil
            }
            return ArkFileContentRestoreOutcome(
                tier: failure.verifiedTier,
                requestedTier: mode == .restoreHighestOwnedEntitlement
                    ? failure.verifiedTier
                    : requestedTier,
                action: .restored
            )
        }
        guard mode == .purchaseOrCurrentEntitlementWithoutDownload,
              let ownedTier = ownership.ownedTier,
              let error,
              case ArkFileContentError.purchaseLinkingFailed = error,
              Self.ownedTier(ownedTier, satisfies: requestedTier) else {
            return nil
        }
        return ArkFileContentRestoreOutcome(
            tier: requestedTier,
            requestedTier: requestedTier,
            action: .purchased
        )
    }

    nonisolated static func entitlementFailureAction(
        for error: Error,
        mode: ArkFileContentAuthorizationMode
    ) -> ArkFileContentEntitlementOutcomeAction {
        if case ArkFileContentError.purchasePending = error {
            return .pendingApproval
        }
        return mode.isRestore ? .restored : .accessConfirmed
    }

    private nonisolated static func ownedTier(
        _ ownedTier: ArkFileContentTier,
        satisfies requestedTier: ArkFileContentTier
    ) -> Bool {
        switch (ownedTier, requestedTier) {
        case (.complete, .complete), (.complete, .lite), (.lite, .lite):
            true
        case (_, .standard), (.lite, .complete), (.standard, _):
            false
        }
    }

    nonisolated static func installedStatePreservedAfterStorageFailure(
        _ error: Error,
        previousInstalledState: ArkFileContentInstallState?
    ) -> ArkFileContentInstallState? {
        guard isStorageAdmissionFailure(error) else { return nil }
        return previousInstalledState
    }

    private func applyStoredSelection(
        for tier: ArkFileContentTier,
        catalog: ArkFileContentCatalog?
    ) {
        guard !state.hasExplicitDownloadRequest else { return }
        let exclusions = selectionStore.excludedItemPaths(for: tier)
            ?? catalog?.defaultExcludedItemKeys(for: tier)
            ?? []
        selectionStore.saveExcludedItemPaths(exclusions, for: tier)
        var updatedState = state
        updatedState.excludedItemPaths = exclusions.isEmpty ? nil : exclusions
        replaceState(updatedState)
    }

    nonisolated static func isDownloadNetworkDeferral(_ error: Error) -> Bool {
        switch error {
        case ArkFileContentError.wifiRequired, ArkFileContentError.constrainedNetwork:
            return true
        default:
            return false
        }
    }

    nonisolated static func purchaseHelpMessage(
        for error: Error,
        tier: ArkFileContentTier,
        authorizationMode: ArkFileContentAuthorizationMode
    ) -> String? {
        switch error {
        case ArkFileContentError.noStoreKitPurchaseFound:
            if authorizationMode == .restoreHighestOwnedEntitlement {
                if Bundle.main.usesSandboxAppStoreReceipt {
                    return "No Essentials or Complete purchase was found for the Apple Account currently signed into the App Store sandbox. To test a fresh purchase, use a new Sandbox Apple Account or clear that sandbox tester's purchase history."
                }
                return "No Essentials or Complete purchase was found for this Apple Account. Use the same Apple Account that bought an ArkFile pack, or review pack purchase options in the App Store."
            }
            let packName = ArkFileContentPackDisplayName.name(for: tier)
            if Bundle.main.usesSandboxAppStoreReceipt {
                return "No \(packName) purchase was found for the Apple Account currently signed into the App Store sandbox. To test a fresh purchase, use a new Sandbox Apple Account or clear that sandbox tester's purchase history."
            }
            return "No \(packName) purchase was found for this Apple Account. Use the same Apple Account that bought \(packName), or review \(packName) purchase options in the App Store."
        case ArkFileContentError.ownershipVerificationRequired:
            return "We couldn’t confirm which pack this Apple Account owns. Restore Purchases before buying again."
        default:
            return nil
        }
    }

    private nonisolated static func packName(for tier: ArkFileContentTier?) -> String {
        ArkFileContentPackDisplayName.name(for: tier)
    }

    private nonisolated static func displayMessage(_ message: String?, for tier: ArkFileContentTier) -> String? {
        guard let message else { return nil }
        let sanitizedMessage = sanitizedLegacyManifestFailureMessage(message, tier: tier)
        guard tier == .complete else { return sanitizedMessage }
        return sanitizedMessage.replacingOccurrences(of: "Essentials", with: "Complete")
    }

    nonisolated static func safeManifestRejectionMessage(for tier: ArkFileContentTier) -> String {
        let packName = Self.packName(for: tier)
        return "ArkFile rejected an outdated or unsafe \(packName) content list before downloading anything. Everything already on this device is unchanged. Open Manage Downloads to review the current content."
    }

    /// Builds before the content-replacement hardening persisted the raw
    /// retired relative path. Rewrite only that known legacy failure class;
    /// network, storage, purchase, and repair messages remain actionable.
    nonisolated static func sanitizedLegacyManifestFailureMessage(
        _ message: String,
        tier: ArkFileContentTier
    ) -> String {
        let normalized = message.lowercased()
        guard normalized.contains("content manifest requests a retired arkfile title")
                || normalized.contains("manifest that requests automatic deletion")
                || normalized.contains("automatic deletion of offline library files") else {
            return message
        }
        return safeManifestRejectionMessage(for: tier)
    }

    private nonisolated static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func statusMessage(
        for error: Error,
        fallback: String,
        tier: ArkFileContentTier = .lite
    ) -> String {
        let packName = Self.packName(for: tier)
        return switch error {
        case ArkFileContentError.purchaseOwnedByOtherAccount:
            "This purchase was created by an older ArkFile test build. Restore Purchases checks Apple for ArkFile \(packName) access."
        case ArkFileContentError.noStoreKitPurchaseFound:
            "No \(packName) purchase was found for this Apple Account. Buy \(packName) with the App Store, or restore with the Apple Account that bought it."
        case ArkFileContentError.ownershipVerificationRequired:
            "We couldn’t confirm which pack this Apple Account owns. Restore Purchases before buying again."
        case ArkFileContentError.purchaseCancelled:
            "The App Store purchase was cancelled."
        case ArkFileContentError.purchasePending:
            "The App Store purchase is pending approval."
        case ArkFileContentError.productUnavailable(_), ArkFileContentError.productMisconfigured:
            "ArkFile \(packName) is not available from the App Store right now. Try again in a moment."
        case ArkFileContentError.unverifiedPurchase:
            "The App Store could not verify this purchase. Try again, or contact ArkFile support if this keeps happening."
        case ArkFileContentError.purchaseRequired:
            "ArkFile could not confirm \(packName) access for this Apple Account. Restore Purchases if you already bought it, or buy \(packName) with the App Store."
        case ArkFileStoreKitMintError.supersededByEntitlementChange:
            "App Store access changed while ArkFile was checking this purchase. Restore Purchases to re-check \(packName) access."
        case ArkFileContentError.liteAccessRevoked:
            "ArkFile could not confirm an active Essentials purchase for this Apple Account. Restore Purchases if you already bought it, or remove ArkFile Essentials from this device."
        case ArkFileContentError.confirmedStoreKitRefund:
            "This purchase was refunded. Buy again, or restore if the refund was reversed."
        case ArkFileContentError.purchaseLinkingFailed(_):
            Self.safePurchaseVerificationFailureMessage(for: fallback, tier: tier)
        case ArkFileContentError.httpStatusWithEndpoint(let statusCode, _, _):
            Self.safeServerStatusMessage(statusCode: statusCode, tier: tier)
        case ArkFileContentError.httpStatus(let statusCode):
            Self.safeServerStatusMessage(statusCode: statusCode, tier: tier)
        case ArkFileContentError.insufficientStorage(let requiredBytes, let availableBytes):
            "Free up space to finish ArkFile \(packName). ArkFile needs about \(Self.formattedBytes(requiredBytes)) available, and this device reports \(Self.formattedBytes(availableBytes))."
        case ArkFileContentError.storageAvailabilityUnavailable(let requiredBytes):
            "ArkFile could not confirm enough free space to finish \(packName). Free at least \(Self.formattedBytes(requiredBytes)) and try again."
        case ArkFileContentError.networkUnavailable:
            "Connect to the internet before downloading ArkFile \(packName)."
        case ArkFileContentError.wifiRequired:
            "Connect to Wi-Fi to download ArkFile \(packName), or choose Use Cellular Data if you understand the data use."
        case ArkFileContentError.incompleteInstalledCatalog(let installedCount, let expectedCount):
            Self.incompleteInstallMessage(installedCount: installedCount, expectedCount: expectedCount, tier: tier)
        case ArkFileContentError.appUpdateRequired(let message):
            "This content pack needs a newer ArkFile app. Update ArkFile, then install \(packName) again. \(message)"
        case ArkFileContentError.requestFailed(_, _):
            "ArkFile could not connect to the content server. Check your connection and try again."
        case ArkFileContentError.retiredManifestFile,
             ArkFileContentError.automaticManifestDeletionUnsupported:
            Self.safeManifestRejectionMessage(for: tier)
        case ArkFileContentBackgroundDownloadError.failed(_):
            "Download could not finish. Check your connection and storage, then choose Continue Download."
        default:
            fallback
        }
    }

    nonisolated static func isTransientPurchaseMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("app store purchase")
            || lowercased.contains("storekit")
            || lowercased.contains("purchase is pending")
    }

    nonisolated static func safePurchaseVerificationFailureMessage(
        for message: String,
        usesSandboxReceipt: Bool = Bundle.main.usesSandboxAppStoreReceipt,
        tier: ArkFileContentTier = .lite
    ) -> String {
        let lowercased = message.lowercased()
        if usesSandboxReceipt
            && (
                lowercased.contains("storekit transaction environment is not accepted")
                    || lowercased.contains("testflight")
        ) {
            return "The App Store confirmed the purchase, but this beta build is connected to a purchase server that does not accept TestFlight purchases yet."
        }
        let packName = Self.packName(for: tier)
        return "The App Store confirmed the purchase, but ArkFile could not verify \(packName) access. Restore Purchases to try again, or contact ArkFile support if this keeps happening."
    }

    nonisolated static func safeServerStatusMessage(
        statusCode: Int,
        tier: ArkFileContentTier = .lite
    ) -> String {
        switch statusCode {
        case 401, 403:
            "ArkFile could not confirm \(Self.packName(for: tier)) access for this Apple Account. Restore Purchases if you already bought it."
        case 500..<600:
            "ArkFile content service is temporarily unavailable. Try again in a moment."
        default:
            "ArkFile could not finish the \(Self.packName(for: tier)) request. Check your connection and try again."
        }
    }

    private nonisolated static func isInterruptedInstallMessage(_ message: String?) -> Bool {
        message == LocalString.arkfile_lite_status_interrupted
    }

    nonisolated static func incompleteInstallMessage(
        installedCount: Int,
        expectedCount: Int,
        tier: ArkFileContentTier = .lite
    ) -> String {
        let packName = Self.packName(for: tier)
        if expectedCount > 0, installedCount > 0 {
            return "\(packName) download did not finish. Continue Download to keep the files already here and download what is missing."
        }
        return "\(packName) download did not finish. Continue Download to pick up where it left off."
    }

    private nonisolated static func isIncompleteInstallMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.hasPrefix("Essentials needs repair.")
            || message.hasPrefix("Essentials download did not finish.")
            || message.hasPrefix("Complete needs repair.")
            || message.hasPrefix("Complete download did not finish.")
    }

    nonisolated static func canPauseLiteDownload(phase: ArkFileContentInstallPhase) -> Bool {
        switch phase {
        case .downloading, .verifying, .installing:
            return true
        case .idle, .preparing, .purchasing, .readyToDownload, .installed, .failed:
            return false
        }
    }

    nonisolated static func canCancelCurrentDownload(state: ArkFileContentInstallState) -> Bool {
        state.phase == .downloading
            && !state.currentFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func applyCancelledDownloadSelection(
        to state: ArkFileContentInstallState,
        itemKey: String,
        requestTier: ArkFileContentTier,
        excludedItemPaths: Set<String>,
        selectionStore: ArkFileContentSelectionStore
    ) -> ArkFileContentInstallState {
        var cancelled = stateAfterCancellingCurrentDownload(
            state,
            itemKey: itemKey,
            requestTier: requestTier,
            excludedItemPaths: excludedItemPaths
        )
        if let installedTier = cancelled.tier, installedTier != requestTier {
            // Choosing the request may already have overwritten the installed
            // snapshot's exclusions before runInstall captured it. The tier
            // store preserves its original choice, including an absent choice.
            cancelled.excludedItemPaths = selectionStore.excludedItemPaths(for: installedTier)
        }
        var requestExclusions = excludedItemPaths
        requestExclusions.insert(ArkFileContentCanonicalPath.key(itemKey))
        selectionStore.saveExcludedItemPaths(
            requestExclusions,
            for: requestTier
        )
        return cancelled
    }

    nonisolated static func stateAfterCancellingCurrentDownload(
        _ state: ArkFileContentInstallState,
        itemKey: String,
        requestTier: ArkFileContentTier? = nil,
        excludedItemPaths: Set<String>? = nil
    ) -> ArkFileContentInstallState {
        var cancelled = state
        let normalizedKey = ArkFileContentCanonicalPath.key(itemKey)
        var exclusions = excludedItemPaths ?? cancelled.normalizedExcludedItemPaths
        exclusions.insert(normalizedKey)
        // An installed snapshot restored during cancellation can belong to a
        // different tier. Its persisted exclusions must stay with that tier;
        // applyCancelledDownloadSelection saves the request's choices separately.
        if (requestTier ?? state.tier) == state.tier {
            cancelled.excludedItemPaths = exclusions
        }
        var addedItems = cancelled.normalizedAddedItemPaths
        if addedItems.remove(normalizedKey) != nil {
            cancelled.addedItemPaths = addedItems.isEmpty ? nil : addedItems
            cancelled.addedItemNames = nil
        }
        if addedItems.isEmpty {
            // Cancellation ends exact transfer authority even when other
            // multipart partials remain available for a future deliberate add.
            cancelled.addedItemPaths = state.hasExplicitDownloadRequest ? [] : nil
            cancelled.addedItemNames = nil
            cancelled.activeDownloadRequestTier = nil
            cancelled.includesMapFoundation = state.hasExplicitDownloadRequest ? false : nil
        }
        if state.phase == .installed {
            // runInstall restored the durable installed snapshot while the
            // caller awaited cancellation. Update the request and selection
            // without erasing installed progress, coverage, or presentation.
            return cancelled
        }
        cancelled.phase = .readyToDownload
        cancelled.completedBytes = 0
        cancelled.totalBytes = 0
        cancelled.selectedBytes = nil
        cancelled.locallyVerifiedBytes = nil
        cancelled.currentFile = ""
        cancelled.errorMessage = nil
        cancelled.completedFiles = nil
        cancelled.totalFiles = nil
        cancelled.checkedFiles = nil
        cancelled.totalSelectedFiles = nil
        cancelled.addedItemNames = nil
        return cancelled
    }

    private func validateAcquisitionLease(
        _ lease: ArkFileStoreKitAcquisitionLease
    ) throws {
        try Task.checkCancellation()
        try purchaseManager.validateAcquisitionLease(lease)
    }

    /// Keeps the final lease check and detached activation launch in one
    /// MainActor turn. A verified loss processed before this boundary makes
    /// validation throw, so an obsolete acquisition cannot launch activation.
    static func activateAfterValidatingAcquisitionLease(
        _ validate: () throws -> Void,
        activation: @escaping @Sendable () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try validate()
        try await Task.detached(
            priority: .utility,
            operation: activation
        ).value
    }

    private func requestDownloadInfo(
        api: ArkFileContentAPI,
        tier: ArkFileContentTier,
        installedTier: ArkFileContentTier?,
        authorization: inout ArkFileContentAuthorization,
        acquisitionLease: inout ArkFileStoreKitAcquisitionLease
    ) async throws -> ArkFileDownloadInfo {
        do {
            return try await api.requestDownloadInfo(
                tier: tier,
                installedTier: installedTier,
                authorization: authorization
            )
        } catch ArkFileContentError.confirmedStoreKitRefund(let productIDs) {
            return try await retryAuthorizedRequestAfterConfirmedRefund(
                productIDs: productIDs,
                tier: tier,
                authorization: &authorization,
                acquisitionLease: &acquisitionLease
            ) { recoveredAuthorization in
                try await api.requestDownloadInfo(
                    tier: tier,
                    installedTier: installedTier,
                    authorization: recoveredAuthorization
                )
            }
        } catch let error where Self.isAuthorizationExpiredOrRejected(error) {
            authorization = try await purchaseManager.refreshContentAuthorization(
                for: tier,
                allowingCellularDownload: authorization.allowsCellularDownload
            )
            do {
                return try await api.requestDownloadInfo(
                    tier: tier,
                    installedTier: installedTier,
                    authorization: authorization
                )
            } catch ArkFileContentError.confirmedStoreKitRefund(let productIDs) {
                return try await retryAuthorizedRequestAfterConfirmedRefund(
                    productIDs: productIDs,
                    tier: tier,
                    authorization: &authorization,
                    acquisitionLease: &acquisitionLease
                ) { recoveredAuthorization in
                    try await api.requestDownloadInfo(
                        tier: tier,
                        installedTier: installedTier,
                        authorization: recoveredAuthorization
                    )
                }
            }
        }
    }

    private func packageManifest(
        api: ArkFileContentAPI,
        objectKey: String,
        tier: ArkFileContentTier,
        authorization: inout ArkFileContentAuthorization,
        acquisitionLease: inout ArkFileStoreKitAcquisitionLease
    ) async throws -> ArkFilePackageManifest {
        do {
            return try await api.packageManifest(objectKey: objectKey, authorization: authorization)
        } catch ArkFileContentError.confirmedStoreKitRefund(let productIDs) {
            return try await retryAuthorizedRequestAfterConfirmedRefund(
                productIDs: productIDs,
                tier: tier,
                authorization: &authorization,
                acquisitionLease: &acquisitionLease
            ) { recoveredAuthorization in
                try await api.packageManifest(
                    objectKey: objectKey,
                    authorization: recoveredAuthorization
                )
            }
        } catch let error where Self.isAuthorizationExpiredOrRejected(error) {
            authorization = try await purchaseManager.refreshContentAuthorization(
                for: tier,
                allowingCellularDownload: authorization.allowsCellularDownload
            )
            do {
                return try await api.packageManifest(
                    objectKey: objectKey,
                    authorization: authorization
                )
            } catch ArkFileContentError.confirmedStoreKitRefund(let productIDs) {
                return try await retryAuthorizedRequestAfterConfirmedRefund(
                    productIDs: productIDs,
                    tier: tier,
                    authorization: &authorization,
                    acquisitionLease: &acquisitionLease
                ) { recoveredAuthorization in
                    try await api.packageManifest(
                        objectKey: objectKey,
                        authorization: recoveredAuthorization
                    )
                }
            }
        }
    }

    private func retryAuthorizedRequestAfterConfirmedRefund<Response>(
        productIDs: [String],
        tier: ArkFileContentTier,
        authorization: inout ArkFileContentAuthorization,
        acquisitionLease: inout ArkFileStoreKitAcquisitionLease,
        request: (ArkFileContentAuthorization) async throws -> Response
    ) async throws -> Response {
        guard let recovered = await purchaseManager.applyConfirmedRefund(
            productIDs: productIDs,
            revalidating: tier,
            allowingCellularDownload: authorization.allowsCellularDownload,
            cancelCurrentInstallTask: false
        ) else {
            throw ArkFileContentError.confirmedStoreKitRefund(
                productIDs: productIDs
            )
        }
        authorization = recovered.authorization
        acquisitionLease = recovered.acquisitionLease
        do {
            return try await request(authorization)
        } catch ArkFileContentError.confirmedStoreKitRefund(let repeatedProductIDs) {
            await purchaseManager.applyConfirmedRefund(
                productIDs: repeatedProductIDs,
                cancelCurrentInstallTask: false
            )
            throw ArkFileContentError.confirmedStoreKitRefund(
                productIDs: repeatedProductIDs
            )
        }
    }

    nonisolated static func isAuthorizationExpiredOrRejected(_ error: Error) -> Bool {
        switch error {
        case ArkFileContentError.httpStatus(401):
            return true
        case ArkFileContentError.httpStatusWithEndpoint(401, _, _):
            return true
        case ArkFileContentBackgroundDownloadError.failed(let message):
            return message.contains("HTTP 401")
        default:
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return message.contains("HTTP 401")
        }
    }

    nonisolated static func beginConfirmedRefundRecoveryAttempt(
        _ attempts: inout Int
    ) -> Bool {
        guard attempts == 0 else { return false }
        attempts = 1
        return true
    }

    private func install(
        manifest: ArkFilePackageManifest,
        trustedManifest: ArkFileTrustedPackageManifest,
        initialTransferProgress: ArkFileContentLocalDownloadProgress,
        api: ArkFileContentAPI,
        authorization initialAuthorization: ArkFileContentAuthorization,
        storageSafetyBytes: Int64,
        acquisitionLease initialAcquisitionLease: ArkFileStoreKitAcquisitionLease
    ) async throws {
        var authorization = initialAuthorization
        var acquisitionLease = initialAcquisitionLease
        let authorizationTier = Self.installTier(from: manifest)
        try validateAcquisitionLease(acquisitionLease)
        let activeRoot = try Self.activeContentRoot()
        let downloadRoot = try Self.downloadRoot()
        try ArkFileDataProtection.createProtectedDirectory(at: activeRoot)
        try ArkFileDataProtection.createProtectedDirectory(at: downloadRoot)
        try Self.excludeFromBackup(activeRoot)
        try Self.excludeFromBackup(downloadRoot)
        let bundledCatalog = try? ArkFileContentCatalog.loadBundled()

        var completedBytes = initialTransferProgress.completedBytes
        let totalBytes = initialTransferProgress.totalBytes
        let totalFiles = initialTransferProgress.totalFiles
        var completedFiles = initialTransferProgress.completedFiles
        let totalSelectedFiles = manifest.files.count
        var checkedFiles = 0
        var authorizationRefreshAttempts = 0
        var confirmedRefundRecoveryAttempts = 0

        updateState(
            phase: .verifying,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            selectedBytes: initialTransferProgress.selectedBytes,
            locallyVerifiedBytes: initialTransferProgress.locallyVerifiedBytes,
            currentFile: "",
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            checkedFiles: checkedFiles,
            totalSelectedFiles: totalSelectedFiles
        )

        let compatibilityGroups = ArkFileContentCompatibilityPlanner.groups(
            manifest: manifest,
            catalog: bundledCatalog
        )
        let projectedContentTiers = Self.projectedContentTiers(
            manifest: manifest,
            catalog: bundledCatalog
        )
        try ArkFileContentCompatibilityPlanner.validateActivationPlan(
            compatibilityGroups,
            downloadRoot: downloadRoot
        )
        for group in compatibilityGroups {
            try validateAcquisitionLease(acquisitionLease)
            // Re-measure the actual volume immediately before each sequential
            // group. This is the authority when a pinned reader or filesystem
            // snapshot has delayed reclamation of an earlier generation.
            try await ensureEnoughStorage(
                for: group,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                safetyBytes: storageSafetyBytes
            )
            try validateAcquisitionLease(acquisitionLease)
            var activationCandidates: [ArkFileContentActivationCandidate] = []
            var groupDownloadedBytes = false
            for member in group.members {
                try validateAcquisitionLease(acquisitionLease)
                let entry = member.entry
                let relativePath = member.canonicalRelativePath
                let destination = activeRoot.appendingPathComponent(relativePath)
                let entryTransferProgress = initialTransferProgress.entry(for: entry)
                let normalizedEntryPath = ArkFileContentCanonicalPath.key(entry.normalizedRelativePath)
                let preflightActiveURL = activeRoot.appendingPathComponent(entry.normalizedRelativePath)
                let canReusePreflightVerification = initialTransferProgress.locallyVerifiedActivePaths
                    .contains(normalizedEntryPath)
                    && destination.standardizedFileURL == preflightActiveURL.standardizedFileURL
                updateState(
                    phase: .verifying,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentFile: relativePath,
                    completedFiles: completedFiles,
                    totalFiles: totalFiles,
                    checkedFiles: checkedFiles,
                    totalSelectedFiles: totalSelectedFiles
                )
                let destinationMatches: Bool
                if canReusePreflightVerification {
                    destinationMatches = true
                } else {
                    destinationMatches = await Self.fileMatchesInBackground(destination, entry: entry)
                }
                try validateAcquisitionLease(acquisitionLease)
                if destinationMatches {
                    checkedFiles += 1
                    activationCandidates.append(ArkFileContentActivationCandidate(
                        relativePath: relativePath,
                        manifestEntry: entry,
                        tier: Self.contentTier(
                            for: relativePath,
                            projectedContentTiers: projectedContentTiers,
                            installedTier: authorizationTier
                        ),
                        stagedURL: nil
                    ))
                    continue
                }

                checkedFiles += 1
                let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(for: entry, in: downloadRoot)
                var hasVerifiedPartial = await Self.fileMatchesInBackground(partialURL, entry: entry)
                try validateAcquisitionLease(acquisitionLease)
                if !hasVerifiedPartial,
                   let existingURL = await Self.matchingExistingFileURLInActiveRoot(
                       entry,
                       activeRoot: activeRoot,
                       destination: destination
                   ) {
                    try validateAcquisitionLease(acquisitionLease)
                    hasVerifiedPartial = try await Self.linkExistingFileToPartialInBackground(
                        existingURL: existingURL,
                        partialURL: partialURL,
                        entry: entry,
                        downloadRoot: downloadRoot
                    )
                    try validateAcquisitionLease(acquisitionLease)
                }

                let entryStartingBytes = entryTransferProgress?.completedBytes ?? 0
                let completedBytesBeforeEntry = max(0, completedBytes - entryStartingBytes)
                let completedFilesBeforeEntry = completedFiles
                if !hasVerifiedPartial {
                    if let expiresAt = authorization.expiresAt,
                       expiresAt <= Date().addingTimeInterval(5 * 60) {
                        try validateAcquisitionLease(acquisitionLease)
                        authorization = try await purchaseManager.refreshContentAuthorization(
                            for: authorizationTier,
                            allowingCellularDownload: authorization.allowsCellularDownload
                        )
                        try validateAcquisitionLease(acquisitionLease)
                    }
                    try validateAcquisitionLease(acquisitionLease)
                    let downloadURL = try await api.packageFileURL(objectKey: entry.objectKey)
                    try validateAcquisitionLease(acquisitionLease)
                    updateState(
                        phase: .downloading,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        currentFile: relativePath,
                        checkedFiles: checkedFiles,
                        totalSelectedFiles: totalSelectedFiles
                    )
                    while true {
                        do {
                            try validateAcquisitionLease(acquisitionLease)
                            try await ArkFileContentBackgroundDownloadService.shared.download(
                                manifest: manifest,
                                entry: entry,
                                from: downloadURL,
                                authorization: authorization,
                                to: partialURL,
                                progress: { [weak self] downloadedBytes, _ in
                                    guard entryTransferProgress != nil else { return }
                                    self?.updateDownloadProgress(
                                        completedBytes: min(
                                            totalBytes,
                                            ArkFileContentStoragePreflight.addingWithoutOverflow(
                                                completedBytesBeforeEntry,
                                                max(0, downloadedBytes)
                                            )
                                        ),
                                        totalBytes: totalBytes,
                                        currentFile: relativePath,
                                        completedFiles: completedFilesBeforeEntry,
                                        totalFiles: totalFiles
                                    )
                                }
                            )
                            try validateAcquisitionLease(acquisitionLease)
                            // Each completed file proves the current token works; reset the retry
                            // budget so multi-hour installs can absorb one refresh per expiry.
                            authorizationRefreshAttempts = 0
                            break
                        } catch ArkFileContentError.confirmedStoreKitRefund(let productIDs) {
                            guard Self.beginConfirmedRefundRecoveryAttempt(
                                &confirmedRefundRecoveryAttempts
                            ) else {
                                await purchaseManager.applyConfirmedRefund(
                                    productIDs: productIDs,
                                    cancelCurrentInstallTask: false
                                )
                                throw ArkFileContentError.confirmedStoreKitRefund(
                                    productIDs: productIDs
                                )
                            }
                            guard let recovered = await purchaseManager.applyConfirmedRefund(
                                productIDs: productIDs,
                                revalidating: authorizationTier,
                                allowingCellularDownload: authorization.allowsCellularDownload,
                                cancelCurrentInstallTask: false
                            ) else {
                                throw ArkFileContentError.confirmedStoreKitRefund(
                                    productIDs: productIDs
                                )
                            }
                            authorization = recovered.authorization
                            acquisitionLease = recovered.acquisitionLease
                            try validateAcquisitionLease(acquisitionLease)
                        } catch let error where Self.isAuthorizationExpiredOrRejected(error) {
                            guard authorizationRefreshAttempts < Self.authorizationRefreshRetryLimit else {
                                throw error
                            }
                            authorizationRefreshAttempts += 1
                            try await Task.sleep(nanoseconds: Self.authorizationRefreshRetryDelayNanoseconds)
                            try validateAcquisitionLease(acquisitionLease)
                            authorization = try await purchaseManager.refreshContentAuthorization(
                                for: authorizationTier,
                                allowingCellularDownload: authorization.allowsCellularDownload
                            )
                            try validateAcquisitionLease(acquisitionLease)
                        }
                    }
                    guard await Self.fileMatchesInBackground(partialURL, entry: entry) else {
                        throw ArkFileContentActivationError.missingVerifiedReplacement(relativePath)
                    }
                    try validateAcquisitionLease(acquisitionLease)
                    groupDownloadedBytes = true
                }
                if let entryTransferProgress {
                    completedBytes = ArkFileContentStoragePreflight.addingWithoutOverflow(
                        completedBytesBeforeEntry,
                        max(0, entryTransferProgress.totalBytes)
                    )
                    if !entryTransferProgress.isComplete {
                        completedFiles += 1
                    }
                }
                activationCandidates.append(ArkFileContentActivationCandidate(
                    relativePath: relativePath,
                    manifestEntry: entry,
                    tier: Self.contentTier(
                        for: relativePath,
                        projectedContentTiers: projectedContentTiers,
                        installedTier: authorizationTier
                    ),
                    stagedURL: partialURL
                ))
                updateState(
                    phase: .downloading,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentFile: relativePath,
                    completedFiles: completedFiles,
                    totalFiles: totalFiles,
                    checkedFiles: checkedFiles,
                    totalSelectedFiles: totalSelectedFiles
                )
            }

            updateState(
                phase: .installing,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentFile: group.members.first?.canonicalRelativePath ?? ""
            )
            if ArkFileContentActivationCoordinator.isAlreadyCommitted(
                groupID: group.id.rawValue,
                candidates: activationCandidates,
                activeRoot: activeRoot,
                installedTier: authorizationTier,
                trustedManifest: trustedManifest
            ) {
                continue
            }
            // Raw Kiwix serves physical paths and cannot participate in the
            // temporary read overlay. Stop the foreground-only sharing session
            // before any active path in this group can change.
            await HotspotObservable.shared.stopForAppBackground()
            let candidatesToActivate = activationCandidates
            try await Self.activateAfterValidatingAcquisitionLease(
                {
                    try validateAcquisitionLease(acquisitionLease)
                },
                activation: {
                    try ArkFileContentActivationCoordinator.activate(
                        groupID: group.id.rawValue,
                        candidates: candidatesToActivate,
                        activeRoot: activeRoot,
                        downloadRoot: downloadRoot,
                        installedTier: authorizationTier,
                        trustedManifest: trustedManifest
                    )
                }
            )
#if os(iOS)
            if groupDownloadedBytes {
                ArkFileAdMeasurement.shared.recordFirstContentReady()
            }
#endif
            // Activation has committed the new group before this purge. Close
            // unpinned CoreKiwix archives so replaced inode blocks can be
            // reclaimed; active searches remain pinned and the next live
            // storage gate observes that their bytes are still allocated.
            await ZimFileService.shared.purgeUnpinnedArchives()
        }

        updateState(
            phase: .installing,
            completedBytes: totalBytes,
            totalBytes: totalBytes,
            currentFile: "",
            completedFiles: totalFiles,
            totalFiles: totalFiles,
            checkedFiles: totalSelectedFiles,
            totalSelectedFiles: totalSelectedFiles
        )
        let installedCoverageItemPaths = Self.installedCoverageItemKeys(
            at: activeRoot,
            catalog: bundledCatalog,
            tier: authorizationTier
        )
        try ensureInstalledCatalogCoverage(
            at: activeRoot,
            catalog: bundledCatalog,
            tier: authorizationTier,
            expectedItemKeys: installedCoverageItemPaths,
            allowsVerifiedMapFoundationOnly: Self.isExplicitMapFoundationOnlySelection(
                manifest: manifest,
                requestedItemKeys: state.addedItemPaths,
                includesMapFoundation: state.includesMapFoundation == true
            )
        )
        let selectionIncludesZim = manifest.files.contains(where: \.isZim)
        if selectionIncludesZim {
            guard await containsReadableZim(in: activeRoot) else {
                throw ArkFileContentError.noReadableZims
            }
        }
        // These files are derived discovery/repair metadata. Group commits are
        // already authoritative, so a crash here cannot revoke readable bytes.
        try writeContentTierIndex(at: activeRoot, manifest: manifest, catalog: bundledCatalog)
        try writeContentRootMarker(at: activeRoot, manifest: manifest)
        state.installedCoverageItemPaths = installedCoverageItemPaths
        updateState(
            phase: .installed,
            tier: Self.installTier(from: manifest),
            completedBytes: totalBytes,
            totalBytes: totalBytes,
            currentFile: "",
            activePath: activeRoot.fileSystemPath,
            installedAt: Date(),
            errorMessage: nil,
            completedFiles: totalFiles,
            totalFiles: totalFiles,
            checkedFiles: totalSelectedFiles,
            totalSelectedFiles: totalSelectedFiles
        )
        await ArkFileLocalContentLibrary.shared.refresh()
    }

    private nonisolated static func installTier(
        from manifest: ArkFilePackageManifest
    ) -> ArkFileContentTier {
        ArkFileContentTier.iOSInstallableTier(named: manifest.tier) ?? .lite
    }

    private nonisolated static func trackedDownloadPaths(
        for manifest: ArkFilePackageManifest
    ) -> Set<String> {
        let selectedEntries = Dictionary(
            uniqueKeysWithValues: manifest.files.map {
                (ArkFileContentCanonicalPath.key($0.normalizedRelativePath), $0.sha256.lowercased())
            }
        )
        return Set(
            ArkFileContentBackgroundDownloadRecordStore().loadRecords().compactMap { record in
                let path = ArkFileContentCanonicalPath.key(record.entry.normalizedRelativePath)
                guard selectedEntries[path] == record.entry.sha256.lowercased() else {
                    return nil
                }
                return path
            }
        )
    }

    private func handleAccessMinted(_ event: ArkFileStoreKitAccessMintEvent) {
        if state.phase.isBusy || installTask != nil {
            pendingAccessMintEvent = Self.preferredMintEvent(
                pendingAccessMintEvent,
                event
            )
            return
        }

        if state.phase == .installed {
            guard let installedTier = state.tier,
                  Self.shouldDeferMintedTier(
                    event.tier,
                    overInstalledTier: installedTier
                  ) else {
                return
            }
            // A delayed Complete approval must not overwrite or downgrade the
            // installed Essentials state. Mark the higher tier as unlocked and
            // waiting so Manage Downloads can continue it deliberately.
            setDeferredDownloadTier(event.tier)
            return
        }

        if hasTransientPurchaseStatus || state.phase == .idle {
            updateState(
                phase: .readyToDownload,
                tier: event.tier,
                completedBytes: state.hasResumableDownloadProgress ? state.completedBytes : 0,
                totalBytes: state.hasResumableDownloadProgress ? state.totalBytes : 0,
                currentFile: "",
                errorMessage: nil
            )
        }
    }

    private func processPendingAccessMintEventIfNeeded() {
        guard let event = pendingAccessMintEvent else { return }
        pendingAccessMintEvent = nil
        handleAccessMinted(event)
    }

    nonisolated static func preferredMintEvent(
        _ current: ArkFileStoreKitAccessMintEvent?,
        _ incoming: ArkFileStoreKitAccessMintEvent
    ) -> ArkFileStoreKitAccessMintEvent {
        guard let current else { return incoming }
        let currentRank = tierRank(current.tier)
        let incomingRank = tierRank(incoming.tier)
        if incomingRank != currentRank {
            return incomingRank > currentRank ? incoming : current
        }
        return incoming.mintedAt >= current.mintedAt ? incoming : current
    }

    private nonisolated static func tierRank(_ tier: ArkFileContentTier) -> Int {
        switch tier {
        case .complete:
            2
        case .lite:
            1
        case .standard:
            0
        }
    }

    nonisolated static func shouldDeferMintedTier(
        _ mintedTier: ArkFileContentTier,
        overInstalledTier installedTier: ArkFileContentTier
    ) -> Bool {
        tierRank(mintedTier) > tierRank(installedTier)
    }

    /// Drops manifest entries the user deselected. Entries that do not map to a
    /// catalog item (shared map data, indexes) are always kept — exclusions can
    /// only come from catalog items shown in the review screen.
    nonisolated static func manifestFilteringExcludedItems(
        _ manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?,
        excludedItemKeys: Set<String>
    ) throws -> ArkFilePackageManifest {
        try ArkFileContentCompatibilityPlanner.manifestFilteringExcludedCatalogAnchors(
            manifest,
            catalog: catalog,
            excludedCatalogAnchorKeys: excludedItemKeys
        )
    }

    /// Computes exclusions only for this transfer. An explicit request excludes
    /// every other catalog anchor; map dependencies are resolved separately.
    nonisolated static func runtimeExcludedItemKeys(
        catalog: ArkFileContentCatalog,
        savedExcludedItemKeys: Set<String>,
        explicitRequestedItemKeys: Set<String>?
    ) -> Set<String> {
        guard let explicitRequestedItemKeys else {
            return Set(savedExcludedItemKeys.map(ArkFileContentCanonicalPath.key))
        }
        let requested = Set(
            explicitRequestedItemKeys.map(ArkFileContentCanonicalPath.key)
        )
        let catalogKeys = Set(
            catalog.allItems.compactMap { item -> String? in
                let key = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
                return key.isEmpty ? nil : key
            }
        )
        return catalogKeys.subtracting(requested)
    }

    nonisolated static func explicitRequestedItemKeys(
        in state: ArkFileContentInstallState,
        for tier: ArkFileContentTier
    ) throws -> Set<String>? {
        guard state.hasExplicitDownloadRequest else { return nil }
        guard state.effectiveActiveDownloadRequestTier == tier else {
            throw ArkFileContentError.invalidResponse
        }
        return state.addedItemPaths
    }

    nonisolated static func includesMapFoundationForActiveRequest(
        _ state: ArkFileContentInstallState
    ) -> Bool {
        // A nil flag on an older exact request means map setup was already
        // included in the user's previous transfer. Preserve its resume scope.
        state.includesMapFoundation ?? !state.normalizedAddedItemPaths.isEmpty
    }

    nonisolated static func hasConflictingDownloadVariants(
        requestedKeys: Set<String>,
        outstandingKeys: Set<String> = [],
        catalog: ArkFileContentCatalog
    ) -> Bool {
        let requested = Set(requestedKeys.map(ArkFileContentCanonicalPath.key))
        let combined = requested.union(outstandingKeys.map(ArkFileContentCanonicalPath.key))
        let variants = Dictionary(catalog.allItems.compactMap { item -> (String, String)? in
            guard let group = item.normalizedVariantGroup else { return nil }
            return (ArkFileContentCanonicalPath.key(item.normalizedRelativePath), group)
        }, uniquingKeysWith: { first, _ in first })
        return requested.contains { key in
            guard let group = variants[key] else { return false }
            return combined.contains { $0 != key && variants[$0] == group }
        }
    }

    nonisolated static func catalogRequestKey(
        for currentFile: String,
        catalog: ArkFileContentCatalog?
    ) -> String {
        let key = ArkFileContentCanonicalPath.key(currentFile)
        let group = ArkFileContentCompatibilityPlanner.groupID(for: key)
        return catalog?.allItems.map {
            ArkFileContentCanonicalPath.key($0.normalizedRelativePath)
        }.first {
            ArkFileContentCompatibilityPlanner.groupID(for: $0) == group
        } ?? key
    }

    nonisolated static func installedCoverageItemKeys(
        committedRelativePaths: Set<String>,
        catalog: ArkFileContentCatalog,
        tier: ArkFileContentTier
    ) -> Set<String> {
        let committedGroupIDs = Set(
            committedRelativePaths.map {
                ArkFileContentCompatibilityPlanner.groupID(
                    for: ArkFileContentCanonicalPath.key($0)
                )
            }
        )
        return Set(
            catalog.allItems.compactMap { item -> String? in
                guard item.isAvailable(in: tier) else { return nil }
                let key = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
                guard !key.isEmpty,
                      committedGroupIDs.contains(
                        ArkFileContentCompatibilityPlanner.groupID(for: key)
                      ) else {
                    return nil
                }
                return key
            }
        )
    }

    private nonisolated static func installedCoverageItemKeys(
        at activeRoot: URL,
        catalog: ArkFileContentCatalog?,
        tier: ArkFileContentTier
    ) -> Set<String>? {
        guard let catalog,
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(
                at: activeRoot
              ) else {
            return nil
        }
        return installedCoverageItemKeys(
            committedRelativePaths: Set(
                commit.payload.entries.map(\.relativePath)
            ),
            catalog: catalog,
            tier: tier
        )
    }

    /// Applies either the durable saved selection or a persisted exact-title
    /// request. Explicit scope fails closed when the bundled catalog and
    /// server manifest do not both contain every requested anchor.
    nonisolated static func manifestFilteringDownloadRequest(
        _ manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?,
        tier: ArkFileContentTier,
        savedExcludedItemKeys: Set<String>,
        explicitRequestedItemKeys: Set<String>?,
        includesMapFoundation: Bool = false
    ) throws -> ArkFilePackageManifest {
        guard let explicitRequestedItemKeys else {
            return try manifestFilteringExcludedItems(
                manifest,
                catalog: catalog,
                excludedItemKeys: savedExcludedItemKeys
            )
        }
        let requested = Set(
            explicitRequestedItemKeys.map(ArkFileContentCanonicalPath.key)
        )
        guard !requested.isEmpty || includesMapFoundation else {
            throw ArkFileContentError.emptyContentManifest
        }
        guard let catalog else {
            throw ArkFileContentError.requestedCatalogItemUnavailable(
                requested.sorted().first ?? ""
            )
        }
        guard !hasConflictingDownloadVariants(requestedKeys: requested, catalog: catalog) else {
            throw ArkFileContentError.conflictingDownloadVariants
        }
        let available = Set(
            catalog.allItems.compactMap { item -> String? in
                guard item.isAvailable(in: tier) else { return nil }
                let key = ArkFileContentCanonicalPath.key(item.normalizedRelativePath)
                return key.isEmpty ? nil : key
            }
        )
        if let unavailable = requested.subtracting(available).sorted().first {
            throw ArkFileContentError.requestedCatalogItemUnavailable(unavailable)
        }
        let runtimeExclusions = runtimeExcludedItemKeys(
            catalog: catalog,
            savedExcludedItemKeys: savedExcludedItemKeys,
            explicitRequestedItemKeys: requested
        )
        let needsMapFoundation = includesMapFoundation || requested.contains {
            ArkFileContentCompatibilityPlanner.groupID(for: $0).rawValue.hasPrefix("map-region:")
        }
        var selectedGroups: [ArkFileContentCompatibilityGroup] = []
        var filteredAnchors = Set<String>()
        for group in ArkFileContentCompatibilityPlanner.groups(
            manifest: manifest,
            catalog: catalog
        ) {
            // Map compatibility data belongs only to an explicit map request.
            // Ordinary titles never acquire unrelated map assets.
            if group.id.rawValue == "map-core" {
                if needsMapFoundation { selectedGroups.append(group) }
                continue
            }
            guard let anchor = group.catalogAnchorRelativePath else {
                continue
            }
            let anchorKey = ArkFileContentCanonicalPath.key(anchor)
            guard !runtimeExclusions.contains(anchorKey) else {
                continue
            }
            selectedGroups.append(group)
            filteredAnchors.insert(anchorKey)
        }
        if let unavailable = requested.subtracting(filteredAnchors).sorted().first {
            throw ArkFileContentError.requestedCatalogItemUnavailable(unavailable)
        }
        if needsMapFoundation,
           !selectedGroups.contains(where: { $0.id.rawValue == "map-core" }) {
            throw ArkFileContentError.requestedCatalogItemUnavailable("Map detail & places")
        }
        let files = selectedGroups.flatMap(\.entries)
        guard !files.isEmpty else {
            throw ArkFileContentError.emptyContentManifest
        }
        return ArkFilePackageManifest(
            format: manifest.format,
            tier: manifest.tier,
            baselineTier: manifest.baselineTier,
            deliveryMode: manifest.deliveryMode,
            installedBytes: files.reduce(into: Int64(0)) {
                $0 = ArkFileContentStoragePreflight.addingWithoutOverflow(
                    $0,
                    $1.sizeBytes
                )
            },
            files: files,
            compat: manifest.compat,
            deletedPaths: manifest.deletedPaths,
            product: manifest.product,
            variant: manifest.variant,
            sourceEdition: manifest.sourceEdition,
            baselineEdition: manifest.baselineEdition,
            installMode: manifest.installMode,
            filesIncluded: files.count,
            declaredBytesIncluded: files.reduce(into: Int64(0)) {
                $0 = ArkFileContentStoragePreflight.addingWithoutOverflow(
                    $0,
                    $1.sizeBytes
                )
            },
            generatedAt: manifest.generatedAt
        )
    }

    /// A dependency group may commit before its selected item completes. Its
    /// retained provenance still needs recognition on later unrelated installs.
    /// Only verified envelopes and exact committed file identities contribute;
    /// this neither creates item receipts nor grants download/payload authority.
    nonisolated static func verifiedReleasesForInstalledContent(
        commit: ArkFileInstalledContentAccess.CommitRecord?,
        provider: ArkFileContentReleaseProvider = .shared
    ) -> [ArkFileVerifiedContentRelease] {
        var verified: [ArkFileContentReleaseBinding: ArkFileVerifiedContentRelease] = [:]
        for binding in Set(provider.snapshot.installed.values.map(\.binding)) {
            if let release = try? provider.verifiedRelease(binding) { verified[binding] = release }
        }
        var retained: [ArkFileContentReleaseBinding: [ArkFileInstalledContentAccess.CommitEntry]] = [:]
        for entry in commit?.payload.entries ?? [] {
            guard let provenance = entry.manifestProvenance,
                  let binding = ArkFileTrustedPackageManifest.releaseBinding(from: provenance) else { continue }
            retained[binding, default: []].append(entry)
        }
        for (binding, entries) in retained where verified[binding] == nil {
            guard let release = try? provider.verifiedRelease(binding) else { continue }
            let files = Dictionary(uniqueKeysWithValues: release.release.files.map { ($0.relativePath, $0) })
            guard entries.allSatisfy({ entry in
                guard let file = files[entry.relativePath] else { return false }
                return entry.byteCount == file.sizeBytes && entry.sha256 == file.sha256
            }) else { continue }
            verified[binding] = release
        }
        return verified.values.sorted {
            ($0.binding.releaseID, $0.binding.releaseSHA256) < ($1.binding.releaseID, $1.binding.releaseSHA256)
        }
    }

    /// Frozen v1 repair/install may fill missing legacy content, but cannot
    /// roll a separately installed signed revision back to the bundled edition.
    nonisolated static func manifestPreservingSignedInstalledGroups(
        _ manifest: ArkFilePackageManifest, activeRoot: URL
    ) throws -> ArkFilePackageManifest {
        try manifestPreservingSignedInstalledGroups(manifest,
            commit: ArkFileInstalledContentAccess.currentCommitRecord(at: activeRoot))
    }

    nonisolated static func manifestPreservingSignedInstalledGroups(
        _ manifest: ArkFilePackageManifest, commit: ArkFileInstalledContentAccess.CommitRecord?
    ) throws -> ArkFilePackageManifest {
        guard let commit else { return manifest }
        let protectedGroups = Set(commit.payload.entries.compactMap { entry -> ArkFileContentCompatibilityGroupID? in
            guard entry.manifestProvenance?.manifestID.hasPrefix("v2-") == true else { return nil }
            return ArkFileContentCompatibilityPlanner.groupID(for: entry.relativePath)
        })
        guard !protectedGroups.isEmpty else { return manifest }
        let files = manifest.files.filter { !protectedGroups.contains(ArkFileContentCompatibilityPlanner.groupID(for: $0.normalizedRelativePath)) }
        guard !files.isEmpty else {
            throw ArkFileContentReleaseError.invalid("These titles use signed content editions. Open Content Updates to review or redownload them.")
        }
        return ArkFilePackageManifest(format: manifest.format, tier: manifest.tier, baselineTier: manifest.baselineTier,
            deliveryMode: manifest.deliveryMode, installedBytes: files.reduce(0) { $0 + $1.sizeBytes }, files: files,
            compat: manifest.compat, deletedPaths: manifest.deletedPaths, product: manifest.product, variant: manifest.variant,
            sourceEdition: manifest.sourceEdition, baselineEdition: manifest.baselineEdition, installMode: manifest.installMode,
            filesIncluded: files.count, declaredBytesIncluded: files.reduce(0) { $0 + $1.sizeBytes }, generatedAt: manifest.generatedAt)
    }

    /// A filtered request may only remove exact entries from the already
    /// authenticated full manifest. It must never synthesize or rewrite
    /// download authority after the release projection match.
    nonisolated static func validateSelectedManifestSubset(
        _ selectedManifest: ArkFilePackageManifest,
        of trustedFullManifest: ArkFilePackageManifest
    ) throws {
        let trustedEntries = Set(trustedFullManifest.files)
        guard !selectedManifest.files.isEmpty,
              selectedManifest.files.count <= trustedEntries.count,
              selectedManifest.files.allSatisfy(trustedEntries.contains) else {
            throw ArkFileContentError.invalidResponse
        }
    }

    nonisolated static func installRelativePath(
        for entry: ArkFilePackageManifest.Entry,
        catalog: ArkFileContentCatalog?
    ) -> String {
        guard let catalog,
              let catalogPath = ArkFileLocalContentLibrary.canonicalCatalogRelativePath(
                for: entry.normalizedRelativePath,
                catalog: catalog
              ) else {
            return entry.normalizedRelativePath
        }
        return catalogPath
    }

    private func ensureInstalledCatalogCoverage(
        at activeRoot: URL,
        catalog: ArkFileContentCatalog?,
        tier: ArkFileContentTier,
        expectedItemKeys: Set<String>?,
        allowsVerifiedMapFoundationOnly: Bool = false
    ) throws {
        guard Self.shouldEnforceBundledCatalogCoverage(
            allowsDeveloperFixtureCatalog: Brand.allowsDeveloperFixtureCatalog
        ) else {
            Log.ContentPack.info("Using explicit Debug fixture catalog coverage for local QA")
            return
        }
        if let catalog,
           catalog.itemCount(for: tier) > 0,
           expectedItemKeys?.isEmpty == true,
           !allowsVerifiedMapFoundationOnly {
            throw ArkFileContentError.incompleteInstalledCatalog(
                installedCount: 0,
                expectedCount: 1
            )
        }
        let coverage = ArkFileLocalContentLibrary.installedCatalogCoverage(
            in: activeRoot,
            catalog: catalog,
            tier: tier,
            excludedItemKeys: state.normalizedExcludedItemPaths,
            expectedItemKeys: expectedItemKeys
        )
        guard !coverage.hasExpectedCatalog
                || ArkFileLocalContentLibrary.hasSufficientInstalledCatalogCoverage(
                    installedCount: coverage.installedCount,
                    catalogItemCount: coverage.expectedCount
                ) else {
            throw ArkFileContentError.incompleteInstalledCatalog(
                installedCount: coverage.installedCount,
                expectedCount: coverage.expectedCount
            )
        }
    }

    /// Used only after trusted manifest validation and atomic activation of
    /// every selected group. Map foundation files have no catalog title, so
    /// that one explicit request may correctly finish with zero title coverage.
    nonisolated static func isExplicitMapFoundationOnlySelection(
        manifest: ArkFilePackageManifest,
        requestedItemKeys: Set<String>?,
        includesMapFoundation: Bool
    ) -> Bool {
        includesMapFoundation && requestedItemKeys?.isEmpty == true
            && !manifest.files.isEmpty
            && manifest.files.allSatisfy {
                ArkFileContentCompatibilityPlanner.groupID(for: $0.normalizedRelativePath).rawValue == "map-core"
            }
    }

    nonisolated static func shouldEnforceBundledCatalogCoverage(
        allowsDeveloperFixtureCatalog: Bool
    ) -> Bool {
        #if DEBUG
        !allowsDeveloperFixtureCatalog
        #else
        true
        #endif
    }

    private func preparedTransferProgress(
        for manifest: ArkFilePackageManifest
    ) async throws -> ArkFileContentLocalDownloadProgress {
        let activeRoot = try Self.activeContentRoot()
        let downloadRoot = try Self.downloadRoot()
        let groups = ArkFileContentCompatibilityPlanner.groups(
            manifest: manifest,
            catalog: try? ArkFileContentCatalog.loadBundled()
        )
        try ArkFileContentCompatibilityPlanner.validateActivationPlan(
            groups,
            downloadRoot: downloadRoot
        )
        for group in groups {
            try await Self.prepareReusableFilesForStorageAdmission(
                group: group,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot
            )
        }
        let trackedDownloadPaths = Self.trackedDownloadPaths(for: manifest)
        return await Task.detached(priority: .utility) {
            ArkFileContentStoragePreflight.removeUnusablePartialDownloads(
                for: manifest,
                downloadRoot: downloadRoot
            )
            return ArkFileContentStoragePreflight.localDownloadProgress(
                for: manifest,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                trackedDownloadPaths: trackedDownloadPaths
            )
        }.value
    }

    private func ensureEnoughStorage(
        for manifest: ArkFilePackageManifest,
        transferProgress: ArkFileContentLocalDownloadProgress,
        startingAtFileIndex: Int = 0
    ) async throws -> ArkFileContentStoragePlan {
        let activeRoot = try Self.activeContentRoot()
        let catalog = try? ArkFileContentCatalog.loadBundled()
        let plan = await Task.detached(priority: .utility) {
            let freshInstallPlan = ArkFileContentStoragePreflight.storagePlan(
                for: manifest,
                transferProgress: transferProgress,
                maximumTransientBytes: ArkFileContentBackgroundDownloadService.maximumTransientDownloadBytes,
                startingAtFileIndex: startingAtFileIndex
            )
            guard startingAtFileIndex == 0,
                  case .valid(let commit) = ArkFileInstalledContentAccess
                    .commitRecordLoadState(at: activeRoot),
                  !commit.payload.entries.isEmpty else {
                // A fresh/legacy install intentionally retains the shipped
                // whole-selection formula byte-for-byte.
                return freshInstallPlan
            }
            let groups = ArkFileContentCompatibilityPlanner.groups(
                manifest: manifest,
                catalog: catalog
            )
            let reclaimable = ArkFileContentStoragePreflight
                .reclaimableBytesByGroupID(
                    groups: groups,
                    commit: commit,
                    activeRoot: activeRoot
                )
            return ArkFileContentStoragePreflight.sequentialUpdateStoragePlan(
                groups: groups,
                transferProgress: transferProgress,
                reclaimableBytesByGroupID: reclaimable,
                maximumTransientBytes: ArkFileContentBackgroundDownloadService.maximumTransientDownloadBytes,
                canonicalActiveRoot: activeRoot
            )
        }.value
        guard plan.requiredAvailableBytes > 0 else { return plan }
        let supportRoot = try Self.applicationSupportRoot()
        let available = try await Task.detached(priority: .utility) {
            try ArkFileContentStoragePreflight.availableCapacityForDownload(at: supportRoot)
        }.value
        guard let available else {
            throw ArkFileContentError.storageAvailabilityUnavailable(
                requiredBytes: plan.requiredAvailableBytes
            )
        }
        guard available >= plan.requiredAvailableBytes else {
            throw ArkFileContentError.insufficientStorage(
                requiredBytes: plan.requiredAvailableBytes,
                availableBytes: available
            )
        }
        return plan
    }

    private func ensureEnoughStorage(
        for group: ArkFileContentCompatibilityGroup,
        activeRoot: URL,
        downloadRoot: URL,
        safetyBytes: Int64
    ) async throws {
        let plan = await Task.detached(priority: .utility) {
            ArkFileContentStoragePreflight.storagePlan(
                for: group,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot,
                maximumTransientBytes: ArkFileContentBackgroundDownloadService.maximumTransientDownloadBytes,
                safetyBytes: safetyBytes
            )
        }.value
        guard plan.requiredAvailableBytes > 0 else { return }
        let supportRoot = try Self.applicationSupportRoot()
        let available = try await Task.detached(priority: .utility) {
            try ArkFileContentStoragePreflight.availableCapacityForDownload(at: supportRoot)
        }.value
        guard let available else {
            throw ArkFileContentError.storageAvailabilityUnavailable(
                requiredBytes: plan.requiredAvailableBytes
            )
        }
        guard available >= plan.requiredAvailableBytes else {
            throw ArkFileContentError.insufficientStorage(
                requiredBytes: plan.requiredAvailableBytes,
                availableBytes: available
            )
        }
    }

    func ensureLargeDownloadNetworkIsReady(allowsCellularDownload: Bool) async throws {
        let monitor = NWPathMonitor()
        let state = ArkFileNetworkPreflightState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "app.arkfile.content-pack.network-preflight")

                monitor.pathUpdateHandler = { path in
                    monitor.cancel()
                    if path.status != .satisfied {
                        state.resolve(.failure(ArkFileContentError.networkUnavailable))
                    } else if path.isConstrained && !allowsCellularDownload {
                        state.resolve(.failure(ArkFileContentError.constrainedNetwork))
                    } else if path.isExpensive && !allowsCellularDownload {
                        state.resolve(.failure(ArkFileContentError.wifiRequired))
                    } else {
                        state.resolve(.success(()))
                    }
                }
                state.install(continuation)
                guard !Task.isCancelled else {
                    monitor.cancel()
                    state.resolve(.failure(CancellationError()))
                    return
                }
                monitor.start(queue: queue)
            }
        } onCancel: {
            monitor.cancel()
            state.resolve(.failure(CancellationError()))
        }
    }

    private func writeContentRootMarker(at activeRoot: URL, manifest: ArkFilePackageManifest) throws {
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: activeRoot.appendingPathComponent(Self.contentRootManifestFileName),
            options: .atomic
        )
        let marker = [
            "format": "1",
            "product": "ArkFile",
            "bundleType": "managed-content-pack",
            "tier": manifest.tier ?? ArkFileContentTier.lite.rawValue,
            "baselineTier": manifest.baselineTier ?? "",
            "deliveryMode": manifest.deliveryMode ?? "full",
            "manifestFile": Self.contentRootManifestFileName,
            "installCommitFile": Self.contentRootCommitFileName,
            "installCommitRequired": "true",
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: activeRoot.appendingPathComponent(Self.contentRootMarkerFileName), options: .atomic)
    }

    private func writeContentTierIndex(
        at activeRoot: URL,
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) throws {
        let indexURL = activeRoot.appendingPathComponent(Self.contentRootTierIndexFileName)
        var index = [String: String]()
        if let existingData = try? Data(contentsOf: indexURL),
           let existing = try? JSONDecoder().decode([String: String].self, from: existingData) {
            index = existing
        }
        for (path, tier) in Self.projectedContentTiers(
            manifest: manifest,
            catalog: catalog
        ) {
            index[path] = tier.rawValue
        }
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    /// Projects the catalog anchor's tier onto every physical member of its
    /// compatibility group. Multipart ZIM catalogs describe the canonical
    /// `.zim` title while manifests install `.zimaa`, `.zimab`, and later
    /// fragments; looking up those fragments independently would incorrectly
    /// inherit the enclosing Complete install tier.
    nonisolated static func projectedContentTiers(
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) -> [String: ArkFileContentTier] {
        let installedTier = Self.installTier(from: manifest)
        let catalogTiers = Dictionary(
            (catalog?.allItems ?? []).map {
                (
                    ArkFileContentCanonicalPath.key($0.normalizedRelativePath),
                    $0.isAvailableInEssentials
                        ? ArkFileContentTier.lite
                        : ArkFileContentTier.complete
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        var projected = [String: ArkFileContentTier]()
        for group in ArkFileContentCompatibilityPlanner.groups(
            manifest: manifest,
            catalog: catalog
        ) {
            let catalogTier = group.catalogAnchorRelativePath.flatMap {
                catalogTiers[ArkFileContentCanonicalPath.key($0)]
            }
            for member in group.members {
                let path = ArkFileContentCanonicalPath.key(
                    member.canonicalRelativePath
                )
                projected[path] = ArkFileManagedContentTierPolicy.tier(
                    for: path,
                    catalogTier: catalogTier,
                    installedTier: installedTier
                )
            }
        }
        return projected
    }

    private nonisolated static func contentTier(
        for relativePath: String,
        projectedContentTiers: [String: ArkFileContentTier],
        installedTier: ArkFileContentTier
    ) -> ArkFileContentTier {
        let key = ArkFileContentCanonicalPath.key(relativePath)
        return ArkFileManagedContentTierPolicy.tier(
            for: key,
            catalogTier: projectedContentTiers[key],
            installedTier: installedTier
        )
    }

    nonisolated static func fileMatchesInBackground(
        _ url: URL,
        entry: ArkFilePackageManifest.Entry
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            ArkFileContentFileVerifier.fileMatches(url, entry: entry)
        }.value
    }

    nonisolated static func movePartialToActiveRootInBackground(
        partialURL: URL,
        destination: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // POSIX rename replaces an existing destination atomically. Never
            // introduce a delete-then-move window for managed content.
            guard Darwin.rename(partialURL.fileSystemPath, destination.fileSystemPath) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Self.excludeFromBackup(destination)
        }.value
    }

    private nonisolated static func linkExistingFileToPartialInBackground(
        existingURL: URL,
        partialURL: URL,
        entry: ArkFilePackageManifest.Entry,
        downloadRoot: URL
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            guard ArkFileContentFileVerifier.fileMatches(existingURL, entry: entry) else {
                return false
            }
            if FileManager.default.fileExists(atPath: partialURL.fileSystemPath) {
                guard ArkFileContentDownloadPaths.removeManagedPartialDownload(
                    partialURL,
                    in: downloadRoot
                ) else {
                    return false
                }
            }
            try FileManager.default.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.linkItem(at: existingURL, to: partialURL)
            return ArkFileContentFileVerifier.fileMatches(partialURL, entry: entry)
        }.value
    }

    private nonisolated static func matchingExistingFileURLInActiveRoot(
        _ entry: ArkFilePackageManifest.Entry,
        activeRoot: URL,
        destination: URL
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            let destinationPath = destination.standardizedFileURL.fileSystemPath
            for url in recoverableExistingFileURLs(
                for: entry,
                activeRoot: activeRoot
            ) {
                guard url.standardizedFileURL.fileSystemPath != destinationPath,
                      ArkFileContentFileVerifier.fileMatches(url, entry: entry) else {
                    continue
                }
                return url
            }
            return nil
        }.value
    }

    /// Materializes checksum-matching legacy locations as same-volume hard
    /// links before the live storage gate. This does not allocate payload
    /// blocks, survives interruption as resumable verified staging, and avoids
    /// rejecting an update that needs no network bytes for that member.
    nonisolated static func prepareReusableFilesForStorageAdmission(
        group: ArkFileContentCompatibilityGroup,
        activeRoot: URL,
        downloadRoot: URL
    ) async throws {
        for member in group.members {
            let entry = member.entry
            let destination = activeRoot.appendingPathComponent(member.canonicalRelativePath)
            if await fileMatchesInBackground(destination, entry: entry) {
                continue
            }
            let partialURL = ArkFileContentDownloadPaths.partialDownloadURL(
                for: entry,
                in: downloadRoot
            )
            if await fileMatchesInBackground(partialURL, entry: entry) {
                continue
            }
            guard let existingURL = await matchingExistingFileURLInActiveRoot(
                entry,
                activeRoot: activeRoot,
                destination: destination
            ) else {
                continue
            }
            _ = try await linkExistingFileToPartialInBackground(
                existingURL: existingURL,
                partialURL: partialURL,
                entry: entry,
                downloadRoot: downloadRoot
            )
        }
    }

    private nonisolated static func recoverableExistingFileURLs(
        for entry: ArkFilePackageManifest.Entry,
        activeRoot: URL
    ) -> [URL] {
        let relativePath = entry.normalizedRelativePath
        let prefixes = [
            "",
            "files",
            "lite-full/files",
            "content-pack/files",
            "content-packs/files",
            "content-packs/manifests/lite-full/files"
        ]
        var seenPaths = Set<String>()
        return prefixes.compactMap { prefix in
            let candidate = prefix.isEmpty
                ? activeRoot.appendingPathComponent(relativePath)
                : activeRoot
                    .appendingPathComponent(prefix, isDirectory: true)
                    .appendingPathComponent(relativePath)
            let path = candidate.standardizedFileURL.fileSystemPath
            guard seenPaths.insert(path).inserted else {
                return nil
            }
            return candidate
        }
    }

    private func containsReadableZim(in activeRoot: URL) async -> Bool {
        for url in Self.zimFileURLs(in: activeRoot) {
            if await ZimFileService.getMetaData(url: url) != nil {
                return true
            }
        }
        return false
    }

    private nonisolated static func zimFileURLs(in activeRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: activeRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "zim" {
                urls.append(url)
            }
        }
        return urls
    }

    private nonisolated static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func updateState(
        phase: ArkFileContentInstallPhase,
        tier: ArkFileContentTier? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        selectedBytes: Int64? = nil,
        locallyVerifiedBytes: Int64? = nil,
        currentFile: String? = nil,
        activePath: String? = nil,
        installedAt: Date? = nil,
        errorMessage: String? = nil,
        completedFiles: Int? = nil,
        totalFiles: Int? = nil,
        checkedFiles: Int? = nil,
        totalSelectedFiles: Int? = nil,
        persist: Bool = true,
        persistedAt: Date = Date()
    ) {
        let previousPhase = state.phase
        state.tier = tier ?? state.tier
        state.phase = phase
        state.completedBytes = completedBytes ?? state.completedBytes
        state.totalBytes = totalBytes ?? state.totalBytes
        state.selectedBytes = selectedBytes ?? state.selectedBytes
        state.locallyVerifiedBytes = locallyVerifiedBytes ?? state.locallyVerifiedBytes
        state.transferAccountingVersion = 1
        state.currentFile = currentFile ?? state.currentFile
        state.activePath = activePath ?? state.activePath
        state.installedAt = installedAt ?? state.installedAt
        state.errorMessage = errorMessage
        state.completedFiles = completedFiles ?? state.completedFiles
        state.totalFiles = totalFiles ?? state.totalFiles
        state.checkedFiles = checkedFiles ?? state.checkedFiles
        state.totalSelectedFiles = totalSelectedFiles ?? state.totalSelectedFiles
        // The explicit request is retry authority. Ordinary failures, pauses,
        // and pre-download cancellation must not widen a retry back to the
        // user's full saved selection. Clear it only after install success.
        if Self.shouldClearActiveDownloadRequest(for: phase) {
            state.addedItemPaths = nil
            state.addedItemNames = nil
            state.activeDownloadRequestTier = nil
            state.includesMapFoundation = nil
        }
        if phase != .downloading {
            downloadRateSamples.removeAll()
            downloadRemainingTimeText = nil
        }
        if phase == .installed && previousPhase != .installed {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
        #if os(iOS) && canImport(ActivityKit)
        ArkFileEssentialsLiveActivityController.shared.update(with: state)
        #endif
        guard persist else { return }
        Self.persist(state: state)
        if phase == .downloading {
            downloadProgressCheckpoint = DownloadProgressCheckpoint(
                completedBytes: state.completedBytes,
                persistedAt: persistedAt
            )
        } else {
            downloadProgressCheckpoint = nil
        }
    }

    nonisolated static func shouldClearActiveDownloadRequest(
        for phase: ArkFileContentInstallPhase
    ) -> Bool {
        phase == .installed
    }

    private func updateDownloadProgress(
        completedBytes: Int64,
        totalBytes: Int64,
        currentFile: String,
        completedFiles: Int? = nil,
        totalFiles: Int? = nil
    ) {
        let now = Date()
        updateDownloadRateEstimate(completedBytes: completedBytes, totalBytes: totalBytes, now: now)
        let shouldPersist = Self.shouldPersistProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            lastPersistedBytes: downloadProgressCheckpoint?.completedBytes,
            elapsedSinceLastPersist: downloadProgressCheckpoint.map { now.timeIntervalSince($0.persistedAt) },
            minimumByteInterval: Self.progressPersistenceMinimumBytes,
            minimumTimeInterval: Self.progressPersistenceMinimumInterval
        )
        updateState(
            phase: .downloading,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            currentFile: currentFile,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
            persist: shouldPersist,
            persistedAt: now
        )
    }

    private func updateDownloadRateEstimate(completedBytes: Int64, totalBytes: Int64, now: Date) {
        // Retries can restart a file from an earlier offset; a regression invalidates
        // the sample window, so start a fresh one instead of reporting negative rates.
        if let last = downloadRateSamples.last, completedBytes < last.completedBytes {
            downloadRateSamples.removeAll()
        }
        downloadRateSamples.append((sampledAt: now, completedBytes: completedBytes))
        let windowStart = now.addingTimeInterval(-90)
        downloadRateSamples.removeAll { $0.sampledAt < windowStart }
        downloadRemainingTimeText = Self.remainingTimeText(
            samples: downloadRateSamples,
            totalBytes: totalBytes
        )
    }

    nonisolated static func remainingTimeText(
        samples: [(sampledAt: Date, completedBytes: Int64)],
        totalBytes: Int64
    ) -> String? {
        guard totalBytes > 0,
              let first = samples.first,
              let last = samples.last else {
            return nil
        }
        let elapsed = last.sampledAt.timeIntervalSince(first.sampledAt)
        let transferredBytes = last.completedBytes - first.completedBytes
        guard elapsed >= 5, transferredBytes > 0 else {
            return nil
        }
        let bytesPerSecond = Double(transferredBytes) / elapsed
        let remainingBytes = max(0, totalBytes - last.completedBytes)
        let remainingSeconds = Double(remainingBytes) / bytesPerSecond
        guard remainingSeconds.isFinite else {
            return nil
        }
        if remainingSeconds < 90 {
            return "a minute"
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = remainingSeconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: remainingSeconds)
    }

    nonisolated static func shouldPersistProgress(
        completedBytes: Int64,
        totalBytes: Int64,
        lastPersistedBytes: Int64?,
        elapsedSinceLastPersist: TimeInterval?,
        minimumByteInterval: Int64,
        minimumTimeInterval: TimeInterval
    ) -> Bool {
        guard totalBytes <= 0 || completedBytes < totalBytes else {
            return true
        }
        guard let lastPersistedBytes,
              let elapsedSinceLastPersist else {
            return true
        }
        guard completedBytes >= lastPersistedBytes else {
            return true
        }
        return completedBytes - lastPersistedBytes >= minimumByteInterval
            || elapsedSinceLastPersist >= minimumTimeInterval
    }

    private static func siteURL() throws -> URL {
        guard let url = URL(string: Brand.arkFileSiteURL) else {
            throw ArkFileContentError.invalidSiteURL
        }
        return url
    }

    nonisolated private static func applicationSupportRoot() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ArkFileContentError.invalidResponse
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let arkFileRoot = root.appendingPathComponent("ArkFile")
        try FileManager.default.createDirectory(at: arkFileRoot, withIntermediateDirectories: true)
        return arkFileRoot
    }

    nonisolated private static func activeContentRoot() throws -> URL {
        try applicationSupportRoot()
            .appendingPathComponent("Content")
            .appendingPathComponent("active")
    }

    /// The canonical Files-hidden root for ArkFile-managed payloads.
    ///
    /// Historical builds could use Documents or Documents/LITE. Those roots
    /// remain readable for recovery, but they are not an acceptable immutable
    /// source for peer redistribution because Files can mutate them outside
    /// ArkFile's managed-content reader/writer gate.
    nonisolated static func protectedActiveContentRoot() throws -> URL {
        try activeContentRoot()
    }

    nonisolated static func isProtectedActiveContentURL(_ url: URL) -> Bool {
        guard let root = try? protectedActiveContentRoot() else { return false }
        let lexicalRoot = root.standardizedFileURL.fileSystemPath
        let lexicalPath = url.standardizedFileURL.fileSystemPath
        let resolvedRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL.fileSystemPath
        let resolvedPath = url.resolvingSymlinksInPath()
            .standardizedFileURL.fileSystemPath

        func isDescendant(_ path: String, of root: String) -> Bool {
            path == root || path.hasPrefix(root + "/")
        }
        return isDescendant(lexicalPath, of: lexicalRoot)
            && isDescendant(resolvedPath, of: resolvedRoot)
    }

    /// Publishes the protected-root switch after a crash-safe legacy migration.
    /// The install commit in `root` is already durable before this is called, so
    /// persisted UI state is a discoverability cache rather than authority.
    func adoptProtectedContentRootAfterLegacyMigration(
        _ root: URL,
        commit: ArkFileInstalledContentAccess.CommitRecord
    ) {
        guard Self.isProtectedActiveContentURL(root),
              root.standardizedFileURL.fileSystemPath
                == (try? Self.protectedActiveContentRoot()
                    .standardizedFileURL.fileSystemPath),
              ArkFileInstalledContentAccess.currentAuthorityExactlyMatches(
                commit,
                at: root
              ) else {
            return
        }
        var migrated = state
        migrated.phase = .installed
        migrated.tier = ArkFileContentTier.iOSInstallableTier(
            named: commit.payload.installedTier
        ) ?? migrated.tier ?? .lite
        migrated.activePath = root.fileSystemPath
        migrated.currentFile = ""
        migrated.errorMessage = nil
        migrated.installedAt = migrated.installedAt ?? Date()
        replaceState(migrated)
    }

    static func installedContentRootIfAvailable(requireReadableContent: Bool = false) -> URL? {
        let candidateRoots = [
            try? activeContentRoot(),
            visibleDocumentsLiteRoot(),
            visibleDocumentsRoot()
        ]

        return installedContentRootIfAvailable(
            candidateRoots: candidateRoots,
            requireReadableContent: requireReadableContent
        )
    }

    static func installedContentRootIfAvailable(
        candidateRoots: [URL?],
        requireReadableContent: Bool = false
    ) -> URL? {
        let activeRootPath = (try? activeContentRoot().standardizedFileURL.fileSystemPath) ?? ""
        for url in candidateRoots.compactMap({ $0 }) {
            let standardizedPath = url.standardizedFileURL.fileSystemPath
            let isActiveManagedRoot = !activeRootPath.isEmpty && standardizedPath == activeRootPath
            if isActiveManagedRoot
                && contentRootDirectoryExists(url)
                && (!requireReadableContent || contentRootHasAnyReadableContent(url)) {
                return url
            }
            if contentRootHasInstallMarker(url)
                && (!requireReadableContent || contentRootHasReadableContent(url)) {
                return url
            }
        }
        return nil
    }

    static func managedContentRootWithAnyReadableContentIfAvailable() -> URL? {
        managedContentRootWithAnyReadableContentIfAvailable(
            candidateRoots: [
                try? activeContentRoot(),
                visibleDocumentsLiteRoot(),
                visibleDocumentsRoot()
            ]
        )
    }

    static func managedContentRootWithAnyReadableContentIfAvailable(
        candidateRoots: [URL?]
    ) -> URL? {
        let activeRootPath = (try? activeContentRoot().standardizedFileURL.fileSystemPath) ?? ""
        for url in candidateRoots.compactMap({ $0 }) {
            let standardizedPath = url.standardizedFileURL.fileSystemPath
            let isActiveManagedRoot = !activeRootPath.isEmpty && standardizedPath == activeRootPath
            guard (isActiveManagedRoot || contentRootHasInstallMarker(url)),
                  contentRootHasAnyReadableContent(url) else {
                continue
            }
            return url
        }
        return nil
    }

    static func recoverableContentRootWithAnyReadableContentIfAvailable() -> URL? {
        recoverableContentRootWithAnyReadableContentIfAvailable(
            candidateRoots: [
                try? activeContentRoot(),
                visibleDocumentsLiteRoot(),
                visibleDocumentsRoot()
            ]
        )
    }

    static func recoverableContentRootWithAnyReadableContentIfAvailable(
        candidateRoots: [URL?]
    ) -> URL? {
        if let managedRoot = managedContentRootWithAnyReadableContentIfAvailable(candidateRoots: candidateRoots) {
            return managedRoot
        }
        for url in candidateRoots.compactMap({ $0 }) where contentRootLooksLikeArkFilePack(url) {
            return url
        }
        return nil
    }

    private static func contentRootHasInstallMarker(_ url: URL) -> Bool {
        guard contentRootDirectoryExists(url) else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(Self.contentRootMarkerFileName).fileSystemPath
        )
    }

    private static func contentRootDirectoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.fileSystemPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return true
    }

    private static func contentRootHasReadableContent(_ url: URL) -> Bool {
        guard contentRootHasAnyReadableContent(url) else {
            return false
        }
        guard let catalog = try? ArkFileContentCatalog.loadBundled() else {
            return true
        }
        // Items the user deliberately deselected must not count against coverage,
        // or a partial-by-choice install would look damaged at every launch.
        let excludedItemKeys = persistedExcludedItemPaths()
        let expectedPaths = ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            catalog.items(for: category).compactMap { item -> String? in
                if let key = ArkFileLocalContentLibrary.canonicalCatalogItemKey(for: item),
                   excludedItemKeys.contains(key) {
                    return nil
                }
                return item.normalizedRelativePath
            }
        }
        guard !expectedPaths.isEmpty else {
            return true
        }

        let minimumMatches = max(
            1,
            min(
                expectedPaths.count,
                Int((Double(expectedPaths.count) * Self.minimumInstalledCatalogCoverage).rounded(.up))
            )
        )
        var matchedCount = 0
        for relativePath in expectedPaths {
            let fileURL = url.appendingPathComponent(relativePath)
            guard Self.catalogFileExists(at: fileURL) else {
                continue
            }
            matchedCount += 1
            if matchedCount >= minimumMatches {
                return true
            }
        }
        return false
    }

    private static func contentRootLooksLikeArkFilePack(_ url: URL) -> Bool {
        if contentRootHasInstallMarker(url) {
            return contentRootHasAnyReadableContent(url)
        }
        return arkFileCategoryReadableItemCount(
            in: url,
            limit: recoverableRootMinimumReadableItems
        ) >= recoverableRootMinimumReadableItems
    }

    private static func arkFileCategoryReadableItemCount(in root: URL, limit: Int) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.fileSystemPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return 0
        }

        var count = 0
        var scannedDirectories = Set<String>()
        for category in ArkFileLocalContentCategoryKey.allCases {
            for alias in category.folderAliases {
                let directory = root.appendingPathComponent(alias, isDirectory: true)
                let directoryPath = directory.standardizedFileURL.fileSystemPath
                guard scannedDirectories.insert(directoryPath.lowercased()).inserted else { continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                while let item = enumerator.nextObject() as? URL {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    if values?.isDirectory == true {
                        continue
                    }
                    guard values?.isRegularFile == true,
                          !isContentMetadataFile(item.lastPathComponent),
                          readableContentExtensions.contains(item.pathExtension.lowercased()) else {
                        continue
                    }
                    count += 1
                    if count >= limit {
                        return count
                    }
                }
            }
        }
        return count
    }

    private static func catalogFileExists(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func contentRootHasAnyReadableContent(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let item = enumerator.nextObject() as? URL {
            if isContentMetadataFile(item.lastPathComponent) {
                continue
            }
            if item.lastPathComponent.hasPrefix("._") || item.lastPathComponent == ".DS_Store" {
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }
            guard values?.isRegularFile == true else {
                continue
            }
            if Self.readableContentExtensions.contains(item.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    private static func isContentMetadataFile(_ name: String) -> Bool {
        name == Self.contentRootMarkerFileName
            || name == Self.contentRootManifestFileName
            || name == Self.contentRootTierIndexFileName
            || name == Self.contentRootCommitFileName
    }

    private static func visibleDocumentsRoot() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func visibleDocumentsLiteRoot() -> URL? {
        visibleDocumentsRoot()?.appendingPathComponent("LITE", isDirectory: true)
    }

    private static func downloadRoot() throws -> URL {
        ArkFileContentDownloadPaths.managedDownloadRoot(
            in: try applicationSupportRoot()
        )
    }

    private static func removeInstalledAndPartialContent() throws ->
        ArkFileManagedContentDeletionCoordinator.WholePackRemovalResult {
        let managedRoot = try applicationSupportRoot()
        return try ArkFileManagedContentDeletionCoordinator.removeWholePack(
            managedContainerRoot: managedRoot,
            activeRoot: try activeContentRoot(),
            downloadRoot: try downloadRoot()
        )
    }

    private static func stateURL() throws -> URL {
        try applicationSupportRoot()
            .appendingPathComponent("content-pack-state.json")
    }

    /// Reads only the persisted exclusions, without triggering the launch-time
    /// state reconciliation that itself depends on coverage checks.
    private static func persistedExcludedItemPaths() -> Set<String> {
        guard let url = try? stateURL(),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ArkFileContentInstallState.self, from: data) else {
            return []
        }
        return state.normalizedExcludedItemPaths
    }

    private static func loadPersistedState() -> ArkFileContentInstallState {
        guard let url = try? stateURL(),
              let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(ArkFileContentInstallState.self, from: data) else {
            return reconciledPersistedState(.idle)
        }
        if state.phase.isBusy {
            state.phase = .failed
            state.errorMessage = LocalString.arkfile_lite_status_interrupted
        }
        if state.phase == .failed, let errorMessage = state.errorMessage {
            state.errorMessage = sanitizedLegacyManifestFailureMessage(
                errorMessage,
                tier: state.tier ?? .lite
            )
        }
        state = reconciledInstalledStateForLocalContent(state)
        return reconciledPersistedState(state)
    }

    private static func reconciledInstalledStateForLocalContent(
        _ state: ArkFileContentInstallState
    ) -> ArkFileContentInstallState {
        let activePathRoot = state.activePath.isEmpty ? nil : URL(fileURLWithPath: state.activePath)
        let candidateRoots = [
            try? activeContentRoot(),
            activePathRoot,
            visibleDocumentsLiteRoot(),
            visibleDocumentsRoot()
        ]
        return reconciledInstalledStateForLocalContent(state, candidateRoots: candidateRoots)
    }

    static func reconciledInstalledStateForLocalContent(
        _ state: ArkFileContentInstallState,
        candidateRoots: [URL?]
    ) -> ArkFileContentInstallState {
        guard state.phase == .installed else {
            return state
        }

        if let root = installedContentRootIfAvailable(
            candidateRoots: candidateRoots,
            requireReadableContent: true
        ) {
            var usableState = state
            usableState.activePath = root.fileSystemPath
            return usableState
        }

        var repairState = state
        repairState.phase = .failed
        repairState.currentFile = ""
        repairState.installedAt = nil
        if let repairRoot = recoverableContentRootWithAnyReadableContentIfAvailable(
            candidateRoots: candidateRoots
        ) {
            repairState.activePath = repairRoot.fileSystemPath
            repairState.errorMessage = incompleteInstallMessage(
                installedCount: 0,
                expectedCount: 0,
                tier: state.tier ?? .lite
            )
        } else {
            repairState.activePath = ""
            repairState.errorMessage = LocalString.arkfile_lite_status_interrupted
        }
        return repairState
    }

    private static func reconciledPersistedState(
        _ state: ArkFileContentInstallState
    ) -> ArkFileContentInstallState {
        reconciledStateWithLocalDownloadProgress(
            state,
            records: ArkFileContentBackgroundDownloadRecordStore().loadRecords(),
            activeRoot: try? activeContentRoot(),
            downloadRoot: try? downloadRoot()
        )
    }

    nonisolated static func reconciledStateWithLocalDownloadProgress(
        _ state: ArkFileContentInstallState,
        records: [ArkFileContentBackgroundDownloadRecord],
        activeRoot: URL?,
        downloadRoot: URL?
    ) -> ArkFileContentInstallState {
        guard state.phase != .installed,
              !state.hasExplicitDownloadRequest || state.hasPendingExplicitDownloadRequest,
              let progress = bestLocalDownloadProgress(
                records: records,
                activeRoot: activeRoot,
                downloadRoot: downloadRoot
              ),
              progress.hasAccountingSnapshot else {
            return state
        }

        var reconciled = state
        reconciled.tier = reconciled.tier ?? .lite
        if reconciled.usesNetworkTransferAccounting {
            reconciled.completedBytes = max(reconciled.completedBytes, progress.completedBytes)
            reconciled.totalBytes = max(reconciled.totalBytes, progress.totalBytes)
            reconciled.selectedBytes = max(reconciled.selectedBytes ?? 0, progress.selectedBytes)
            reconciled.locallyVerifiedBytes = max(
                reconciled.locallyVerifiedBytes ?? 0,
                progress.locallyVerifiedBytes
            )
            reconciled.completedFiles = max(reconciled.completedFiles ?? 0, progress.completedFiles)
            reconciled.totalFiles = max(reconciled.totalFiles ?? 0, progress.totalFiles)
        } else {
            // Legacy builds counted every already-installed file as downloaded.
            // Replacing those values from the persisted manifest/partials is the
            // only safe migration; taking max would preserve the inflated total.
            reconciled.transferAccountingVersion = 1
            reconciled.completedBytes = progress.completedBytes
            reconciled.totalBytes = progress.totalBytes
            reconciled.selectedBytes = progress.selectedBytes
            reconciled.locallyVerifiedBytes = progress.locallyVerifiedBytes
            reconciled.completedFiles = progress.completedFiles
            reconciled.totalFiles = progress.totalFiles
            reconciled.checkedFiles = 0
            reconciled.totalSelectedFiles = progress.selectedFiles
        }
        if reconciled.phase == .idle {
            reconciled.phase = .failed
            reconciled.errorMessage = LocalString.arkfile_lite_status_interrupted
        }
        if reconciled.phase == .failed && (reconciled.errorMessage?.isEmpty ?? true) {
            reconciled.errorMessage = LocalString.arkfile_lite_status_interrupted
        }
        return reconciled
    }

    private nonisolated static func bestLocalDownloadProgress(
        records: [ArkFileContentBackgroundDownloadRecord],
        activeRoot: URL?,
        downloadRoot: URL?
    ) -> ArkFileContentLocalDownloadProgress? {
        guard let activeRoot,
              let downloadRoot else {
            return nil
        }
        return records
            .map { record in
                let trackedPaths = Set(records.compactMap { candidate -> String? in
                    let candidatePath = ArkFileContentCanonicalPath.key(candidate.entry.normalizedRelativePath)
                    guard record.manifest.files.contains(where: {
                        ArkFileContentCanonicalPath.key($0.normalizedRelativePath) == candidatePath
                            && $0.sha256.caseInsensitiveCompare(candidate.entry.sha256) == .orderedSame
                    }) else {
                        return nil
                    }
                    return candidatePath
                })
                return ArkFileContentStoragePreflight.localDownloadProgress(
                    for: record.manifest,
                    activeRoot: activeRoot,
                    downloadRoot: downloadRoot,
                    trackedDownloadPaths: trackedPaths
                )
            }
            .filter(\.hasAccountingSnapshot)
            .max { left, right in
                if left.completedBytes == right.completedBytes {
                    return left.totalBytes < right.totalBytes
                }
                return left.completedBytes < right.completedBytes
            }
    }

    @discardableResult
    private static func persist(state: ArkFileContentInstallState) -> Bool {
        do {
            let url = try stateURL()
            let data = try JSONEncoder().encode(state)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func loadDeferredDownloadTier() -> ArkFileContentTier? {
        guard let rawValue = UserDefaults.standard.string(forKey: deferredDownloadTierDefaultsKey),
              let tier = ArkFileContentTier(rawValue: rawValue),
              tier.isIOSInstallable else {
            return nil
        }
        return tier
    }

    private func setDeferredDownloadTier(_ tier: ArkFileContentTier?) {
        deferredDownloadTier = tier
        if let tier {
            UserDefaults.standard.set(tier.rawValue, forKey: Self.deferredDownloadTierDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.deferredDownloadTierDefaultsKey)
        }
    }

    private func replaceState(_ newState: ArkFileContentInstallState) {
        state = newState
        downloadProgressCheckpoint = nil
        Self.persist(state: state)
    }
}
