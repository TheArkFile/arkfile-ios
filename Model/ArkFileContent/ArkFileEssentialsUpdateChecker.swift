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

#if os(iOS)
import BackgroundTasks
import CryptoKit
import Foundation
import Network

private final class ArkFileUpdateNetworkProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ resume: () -> Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        resume()
    }
}

private enum ArkFileUpdateNetworkProbe {
    /// This is only a cheap preflight to avoid a doomed content request. A
    /// satisfied path is never treated as authoritative StoreKit evidence.
    static func isNetworkAvailable() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let state = ArkFileUpdateNetworkProbeState()
            monitor.pathUpdateHandler = { path in
                state.resumeOnce {
                    monitor.cancel()
                    continuation.resume(returning: path.status == .satisfied)
                }
            }
            monitor.start(queue: DispatchQueue(label: "app.arkfile.content-update-network-probe"))
        }
    }
}

/// Detects pack content that exists on the server but not on this device —
/// the discovery path for content added to the pack after purchase. Uses the
/// existing entitled download endpoints; no dedicated server API is needed.
@MainActor
final class ArkFileEssentialsUpdateChecker: ObservableObject {
    static let shared = ArkFileEssentialsUpdateChecker()
    nonisolated static let backgroundTaskIdentifier = "app.arkfile.essentials.content-refresh"
    nonisolated static let minimumCheckInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let failedCheckRetryInterval: TimeInterval = 15 * 60

    struct ExpectedFile: Codable, Equatable, Sendable {
        let relativePath: String
        let sizeBytes: Int64
        let sha256: String
    }

    struct NewContentSummary: Codable, Equatable, Sendable {
        let missingPaths: [String]
        let totalBytes: Int64
        let signature: String
        let detectedAt: Date
        var tier: ArkFileContentTier? = nil
        var expectedFiles: [ExpectedFile]? = nil

        var itemCount: Int { missingPaths.count }
    }

    @Published private(set) var availableNewContent: NewContentSummary?

    private static let lastSuccessfulCheckAtKey = "arkfile.essentials.update-check.success-at.v2"
    private static let lastFailedCheckAtKey = "arkfile.essentials.update-check.failure-at.v2"
    private static let notifiedSignatureKey = "arkfile.essentials.update-check.notified-signature.v1"
    private static let summaryKey = "arkfile.essentials.update-check.summary.v1"

    private var isChecking = false

    private init() {
        // V1 service manifests are immutable. Retire old cached notifications;
        // signed v2 discovery is an explicit Content Updates action.
        availableNewContent = nil
        UserDefaults.standard.removeObject(forKey: Self.summaryKey)
    }

    /// Cheap, offline-safe pass: discard summaries from older app builds if
    /// they mention retired paths, then drop entries whose files have since
    /// arrived on disk (e.g. after the user downloaded the new content).
    func revalidateLocally() {
        guard let summary = availableNewContent else { return }
        guard let activeRoot = ArkFileContentPackInstaller.installedContentRootIfAvailable() else {
            return
        }
        let catalog = try? ArkFileContentCatalog.loadBundled()
        let revalidated = Self.revalidatedSummary(
            summary,
            activeRoot: activeRoot,
            catalog: catalog
        )
        guard revalidated != summary else { return }
        setSummary(revalidated)
    }

    static func revalidatedSummary(
        _ summary: NewContentSummary,
        activeRoot: URL,
        catalog: ArkFileContentCatalog?
    ) -> NewContentSummary? {
        guard !summary.missingPaths.contains(where: {
            ArkFileContentRetirementPolicy.isRetired(relativePath: $0)
        }) else {
            return nil
        }
        let installedEntries = Self.installedManifestEntries(at: activeRoot, catalog: catalog)
        let expectedFiles = Dictionary(
            (summary.expectedFiles ?? []).map { ($0.relativePath.lowercased(), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let stillMissing = summary.missingPaths.filter { path in
            let normalizedPath = path.lowercased()
            let destinationExists = FileManager.default.fileExists(
                atPath: activeRoot.appendingPathComponent(path).fileSystemPath
            )
            guard let expected = expectedFiles[normalizedPath] else {
                // Compatibility with summaries persisted before replacement
                // metadata was recorded.
                return !destinationExists
            }
            guard destinationExists,
                  let installed = installedEntries?[normalizedPath] else {
                return true
            }
            return installed.sizeBytes != expected.sizeBytes
                || installed.sha256.caseInsensitiveCompare(expected.sha256) != .orderedSame
        }
        if stillMissing.isEmpty {
            return nil
        }
        guard stillMissing.count != summary.missingPaths.count else { return summary }
        let remainingPathKeys = Set(stillMissing.map { $0.lowercased() })
        let remainingExpectedFiles = (summary.expectedFiles ?? []).filter {
            remainingPathKeys.contains($0.relativePath.lowercased())
        }
        return NewContentSummary(
            missingPaths: stillMissing,
            totalBytes: remainingExpectedFiles.isEmpty
                ? summary.totalBytes
                : remainingExpectedFiles.reduce(0) { $0 + $1.sizeBytes },
            signature: summary.signature,
            detectedAt: summary.detectedAt,
            tier: summary.tier,
            expectedFiles: remainingExpectedFiles.isEmpty ? nil : remainingExpectedFiles
        )
    }

    func checkOnForegroundIfNeeded() async { revalidateLocally() }
    func checkFromBackgroundRefresh() async { revalidateLocally() }

    /// Compatibility for previously persisted UI state. New downloads require
    /// the exact-edition review in Content Updates and cannot start from a v1
    /// background summary.
    func downloadNewContent() { setSummary(nil) }

    static func newContentSummary(
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?,
        excludedItemKeys: Set<String>,
        activeRoot: URL?,
        tier: ArkFileContentTier? = nil,
        now: Date = Date()
    ) -> NewContentSummary? {
        guard let activeRoot else { return nil }
        guard manifest.deletedPaths?.isEmpty != false,
              !manifest.files.contains(where: {
                  ArkFileContentRetirementPolicy.isRetired(relativePath: $0.normalizedRelativePath)
              }) else {
            return nil
        }
        let installedEntries = installedManifestEntries(at: activeRoot, catalog: catalog)
        var expectedFiles: [ExpectedFile] = []
        for entry in manifest.files {
            let installPath = ArkFileContentPackInstaller.installRelativePath(for: entry, catalog: catalog)
            guard !excludedItemKeys.contains(installPath.lowercased()) else {
                continue
            }
            let destination = activeRoot.appendingPathComponent(installPath)
            if FileManager.default.fileExists(atPath: destination.fileSystemPath) {
                guard let installedEntries else {
                    // Preserve legacy behavior when this installation predates
                    // the on-disk manifest used for release comparison.
                    continue
                }
                if let installed = installedEntries[installPath.lowercased()],
                   installed.sizeBytes == entry.sizeBytes,
                   installed.sha256.caseInsensitiveCompare(entry.sha256) == .orderedSame {
                    continue
                }
            }
            expectedFiles.append(ExpectedFile(
                relativePath: installPath,
                sizeBytes: entry.sizeBytes,
                sha256: entry.sha256.lowercased()
            ))
        }
        guard !expectedFiles.isEmpty else { return nil }
        expectedFiles.sort { $0.relativePath.lowercased() < $1.relativePath.lowercased() }
        var hasher = SHA256()
        hasher.update(data: Data((tier?.rawValue ?? "unknown").utf8))
        for file in expectedFiles {
            hasher.update(data: Data(file.relativePath.lowercased().utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(file.sizeBytes).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.sha256.lowercased().utf8))
            hasher.update(data: Data([0]))
        }
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return NewContentSummary(
            missingPaths: expectedFiles.map(\.relativePath),
            totalBytes: expectedFiles.reduce(0) { $0 + $1.sizeBytes },
            signature: signature,
            detectedAt: now,
            tier: tier,
            expectedFiles: expectedFiles
        )
    }

    nonisolated static func shouldStartCheck(
        now: Date,
        lastSuccessfulCheckAt: Date?,
        lastFailedCheckAt: Date?
    ) -> Bool {
        if let lastSuccessfulCheckAt,
           now.timeIntervalSince(lastSuccessfulCheckAt) < minimumCheckInterval {
            return false
        }
        if let lastFailedCheckAt,
           now.timeIntervalSince(lastFailedCheckAt) < failedCheckRetryInterval {
            return false
        }
        return true
    }

    private nonisolated static func installedManifestEntries(
        at activeRoot: URL,
        catalog: ArkFileContentCatalog?
    ) -> [String: ArkFilePackageManifest.Entry]? {
        let manifestURL = activeRoot.appendingPathComponent(
            ArkFileContentPackInstaller.contentRootManifestFileName
        )
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ArkFilePackageManifest.self, from: data) else {
            return nil
        }
        return Dictionary(
            manifest.files.map { entry in
                let installPath = ArkFileContentPackInstaller.installRelativePath(
                    for: entry,
                    catalog: catalog
                )
                return (installPath.lowercased(), entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    nonisolated static func packName(for tier: ArkFileContentTier?) -> String {
        ArkFileContentPackDisplayName.name(for: tier)
    }

    private static func hasSavedAccess(
        for tier: ArkFileContentTier,
        installer: ArkFileContentPackInstaller
    ) -> Bool {
        switch tier {
        case .complete:
            return installer.hasSavedCompleteAccess
        case .lite:
            return installer.hasSavedLiteAccess
        case .standard:
            return false
        }
    }

    private static func canCheckAccess(for tier: ArkFileContentTier) -> Bool {
        switch tier {
        case .complete:
            return !ArkFileLitePurchaseManager.shared.isLiteAccessRevoked
                && !ArkFileLitePurchaseManager.shared.isCompleteAccessRevoked
        case .lite:
            return !ArkFileLitePurchaseManager.shared.isLiteAccessRevoked
        case .standard:
            return false
        }
    }

    // MARK: - Background refresh

    nonisolated static func registerBackgroundRefreshTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleBackgroundRefreshTask(refreshTask)
        }
    }

    nonisolated static func scheduleBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
    }

    /// BGAppRefreshTask is not Sendable; this box carries it into the
    /// completion task without tripping strict-concurrency checks.
    private final class RefreshTaskBox: @unchecked Sendable {
        let task: BGAppRefreshTask
        init(_ task: BGAppRefreshTask) { self.task = task }
    }

    private nonisolated static func handleBackgroundRefreshTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let box = RefreshTaskBox(task)
        let work = Task { @MainActor in
            await shared.checkFromBackgroundRefresh()
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task {
            _ = await work.value
            box.task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    // MARK: - Persistence

    private func setSummary(_ summary: NewContentSummary?) {
        availableNewContent = summary
        if let summary, let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: Self.summaryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.summaryKey)
        }
    }

    private static func loadPersistedSummary() -> NewContentSummary? {
        guard let data = UserDefaults.standard.data(forKey: summaryKey) else { return nil }
        return try? JSONDecoder().decode(NewContentSummary.self, from: data)
    }

    private static func lastSuccessfulCheckAt(for tier: ArkFileContentTier) -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: key(lastSuccessfulCheckAtKey, tier: tier))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func recordSuccessfulCheck(at date: Date, for tier: ArkFileContentTier) {
        UserDefaults.standard.set(
            date.timeIntervalSince1970,
            forKey: key(lastSuccessfulCheckAtKey, tier: tier)
        )
        UserDefaults.standard.removeObject(forKey: key(lastFailedCheckAtKey, tier: tier))
    }

    private static func lastFailedCheckAt(for tier: ArkFileContentTier) -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: key(lastFailedCheckAtKey, tier: tier))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func recordFailedCheck(at date: Date, for tier: ArkFileContentTier) {
        UserDefaults.standard.set(
            date.timeIntervalSince1970,
            forKey: key(lastFailedCheckAtKey, tier: tier)
        )
    }

    private static func lastNotifiedSignature(for tier: ArkFileContentTier) -> String? {
        UserDefaults.standard.string(forKey: key(notifiedSignatureKey, tier: tier))
    }

    private static func recordNotifiedSignature(_ signature: String, for tier: ArkFileContentTier) {
        UserDefaults.standard.set(signature, forKey: key(notifiedSignatureKey, tier: tier))
    }

    private nonisolated static func key(_ base: String, tier: ArkFileContentTier) -> String {
        "\(base).\(tier.rawValue)"
    }
}
#endif
