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

#if os(iOS)
import Combine
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import ZIPFoundation

enum ArkFileOfflineReadinessCheckLevel: String, Codable, Sendable {
    case quick
    case full
}

enum ArkFileOfflineReadinessStatus: Equatable, Sendable {
    case noManagedContent
    case checkDue
    case checking
    case ready
    case needsAttention
    case unavailable
    case cancelled
}

struct ArkFileOfflineReadinessIssue: Identifiable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable {
        case warning
        case failure
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
}

struct ArkFileOfflineReadinessResult: Equatable, Sendable {
    let status: ArkFileOfflineReadinessStatus
    let level: ArkFileOfflineReadinessCheckLevel?
    let checkedAt: Date?
    let manifestIdentity: String?
    let selectedFileCount: Int
    let checkedBytes: Int64
    let totalBytes: Int64
    let availableStorageBytes: Int64?
    let recommendedHeadroomBytes: Int64?
    let issues: [ArkFileOfflineReadinessIssue]

    static let initial = ArkFileOfflineReadinessResult(
        status: .checkDue,
        level: nil,
        checkedAt: nil,
        manifestIdentity: nil,
        selectedFileCount: 0,
        checkedBytes: 0,
        totalBytes: 0,
        availableStorageBytes: nil,
        recommendedHeadroomBytes: nil,
        issues: []
    )
}

struct ArkFileOfflineReadinessContext: Sendable {
    let state: ArkFileContentInstallState
    let needsRepair: Bool
    let root: URL?
    let hasDurableLocalAccess: Bool

    init(
        state: ArkFileContentInstallState,
        needsRepair: Bool,
        root: URL?,
        hasDurableLocalAccess: Bool = true
    ) {
        self.state = state
        self.needsRepair = needsRepair
        self.root = root
        self.hasDurableLocalAccess = hasDurableLocalAccess
    }

    var fingerprint: String {
        [
            state.phase.rawValue,
            state.tier?.rawValue ?? "none",
            state.activePath,
            state.installedAt?.ISO8601Format() ?? "none",
            state.normalizedExcludedItemPaths.sorted().joined(separator: "|"),
            hasDurableLocalAccess ? "local-commit-valid" : "local-commit-invalid"
        ].joined(separator: "::")
    }
}

private final class ArkFileReadinessProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Int64
    private var lastReportedBytes: Int64 = 0

    init(interval: Int64) {
        self.interval = interval
    }

    func shouldReport(_ bytes: Int64, total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes == total || bytes - lastReportedBytes >= interval else { return false }
        lastReportedBytes = bytes
        return true
    }
}

@MainActor
final class ArkFileOfflineReadinessChecker: ObservableObject {
    static let shared = ArkFileOfflineReadinessChecker()

    nonisolated static let freshnessInterval: TimeInterval = TimeInterval(21 * 24 * 60 * 60)

    @Published private(set) var result = ArkFileOfflineReadinessResult.initial
    @Published private(set) var isRunning = false
    @Published private(set) var runningLevel: ArkFileOfflineReadinessCheckLevel?
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var currentFile = ""
    @Published private(set) var lastQuickPassAt: Date?
    @Published private(set) var lastFullPassAt: Date?

    private struct PassRecord: Codable, Equatable {
        var manifestIdentity: String
        var tier: ArkFileContentTier?
        var lastQuickPassAt: Date?
        var lastFullPassAt: Date?
    }

    private struct PreparedCheck: Sendable {
        let contextFingerprint: String
        let root: URL
        let manifest: ArkFilePackageManifest
        let manifestIdentity: String
        let totalBytes: Int64
        let representativeZim: URL?
        let issues: [ArkFileOfflineReadinessIssue]
        let advisoryIssues: [ArkFileOfflineReadinessIssue]
    }

    private enum DeepEvent: Sendable {
        case progress(completedBytes: Int64, currentFile: String)
        case failure(ArkFileOfflineReadinessIssue)
    }

    private let userDefaults: UserDefaults
    private let contextProvider: @MainActor () -> ArkFileOfflineReadinessContext
    private let catalogProvider: @Sendable () -> ArkFileContentCatalog?
    private let zimProbe: @MainActor (URL) async -> Bool
    private let storageProvider: @MainActor () -> Int64?
    private let now: @MainActor () -> Date
    private var activeTask: Task<Void, Never>?
    private var cachedStateRefreshGeneration = 0

    private enum DefaultsKey {
        static let passRecord = "arkfile.offlineReadiness.passRecord.v1"
    }

    init(
        userDefaults: UserDefaults = .standard,
        contextProvider: @escaping @MainActor () -> ArkFileOfflineReadinessContext = {
            let installer = ArkFileContentPackInstaller.shared
            let root = ArkFileContentPackInstaller.managedContentRootWithAnyReadableContentIfAvailable()
            let hasDurableLocalAccess: Bool
            if let root,
               case .committed = ArkFileInstalledContentAccess.decision(for: root) {
                hasDurableLocalAccess = true
            } else {
                hasDurableLocalAccess = root == nil
            }
            return ArkFileOfflineReadinessContext(
                state: installer.state,
                needsRepair: installer.needsLiteRepair,
                root: root,
                hasDurableLocalAccess: hasDurableLocalAccess
            )
        },
        catalogProvider: @escaping @Sendable () -> ArkFileContentCatalog? = {
            try? ArkFileContentCatalog.loadBundled()
        },
        zimProbe: @escaping @MainActor (URL) async -> Bool = { url in
            ZimFileService.getMetaData(url: url) != nil
        },
        storageProvider: @escaping @MainActor () -> Int64? = {
            try? ArkFileContentStoragePreflight.availableCapacityForDownload()
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.contextProvider = contextProvider
        self.catalogProvider = catalogProvider
        self.zimProbe = zimProbe
        self.storageProvider = storageProvider
        self.now = now
        let record = Self.loadPassRecord(from: userDefaults)
        self.lastQuickPassAt = record?.lastQuickPassAt
        self.lastFullPassAt = record?.lastFullPassAt
    }

    var hasManagedContent: Bool {
        contextProvider().root != nil
    }

    var hasRecentPassingCheck: Bool {
        guard result.status == .ready,
              let checkedAt = result.checkedAt else {
            return false
        }
        return now().timeIntervalSince(checkedAt) <= Self.freshnessInterval
    }

    nonisolated static func shouldPublishCachedState(
        requestGeneration: Int,
        currentGeneration: Int,
        startedContext: ArkFileOfflineReadinessContext,
        currentContext: ArkFileOfflineReadinessContext
    ) -> Bool {
        requestGeneration == currentGeneration
            && hasSameAuthoritativeContext(
                startedContext: startedContext,
                currentContext: currentContext
            )
    }

    nonisolated static func hasSameAuthoritativeContext(
        startedContext: ArkFileOfflineReadinessContext,
        currentContext: ArkFileOfflineReadinessContext
    ) -> Bool {
        currentContext.fingerprint == startedContext.fingerprint
            && currentContext.root?.standardizedFileURL == startedContext.root?.standardizedFileURL
            && !currentContext.needsRepair
            && currentContext.hasDurableLocalAccess
    }

    func refreshCachedState() async {
        cachedStateRefreshGeneration &+= 1
        let refreshGeneration = cachedStateRefreshGeneration
        guard !isRunning else { return }
        let context = contextProvider()
        guard let root = context.root else {
            result = Self.result(status: .noManagedContent)
            lastQuickPassAt = nil
            lastFullPassAt = nil
            return
        }
        guard !context.needsRepair, context.hasDurableLocalAccess else {
            result = Self.result(
                status: .needsAttention,
                issues: [context.hasDurableLocalAccess ? Self.repairIssue : Self.installCommitIssue]
            )
            return
        }
        let catalogProvider = self.catalogProvider
        let selection = await Task.detached(priority: .utility) {
            Self.prepareSelection(
                context: context,
                root: root,
                catalog: catalogProvider()
            )
        }.value
        guard !isRunning,
              refreshGeneration == cachedStateRefreshGeneration else {
            return
        }
        let currentContext = contextProvider()
        guard Self.hasSameAuthoritativeContext(
            startedContext: context,
            currentContext: currentContext
        ) else {
            applyChangedCachedContext(currentContext)
            return
        }
        guard let selection else {
            result = Self.result(
                status: .unavailable,
                issues: [Self.manifestUnavailableIssue]
            )
            return
        }
        let record = Self.loadPassRecord(from: userDefaults)
        guard record?.manifestIdentity == selection.identity,
              record?.tier == context.state.tier else {
            invalidatePassRecord()
            result = Self.result(
                status: .checkDue,
                manifestIdentity: selection.identity
            )
            return
        }
        lastQuickPassAt = record?.lastQuickPassAt
        lastFullPassAt = record?.lastFullPassAt
        guard let lastQuickPassAt,
              now().timeIntervalSince(lastQuickPassAt) <= Self.freshnessInterval else {
            result = Self.result(
                status: .checkDue,
                checkedAt: lastQuickPassAt,
                manifestIdentity: selection.identity
            )
            return
        }
        result = Self.result(
            status: .ready,
            checkedAt: lastQuickPassAt,
            manifestIdentity: selection.identity
        )
    }

    func startQuickCheck() {
        guard !isRunning, activeTask == nil else { return }
        activeTask = Task { [weak self] in
            await self?.runCheck(level: .quick)
        }
    }

    func startFullCheck() {
        guard !isRunning, activeTask == nil else { return }
        activeTask = Task { [weak self] in
            await self?.runCheck(level: .full)
        }
    }

    func cancelCurrentCheck() {
        activeTask?.cancel()
    }

    func runQuickCheck() async {
        await runCheck(level: .quick)
    }

    func runFullCheck() async {
        await runCheck(level: .full)
    }

    private func runCheck(level: ArkFileOfflineReadinessCheckLevel) async {
        guard !isRunning else { return }
        // A real check supersedes every cached-result projection that may
        // still be preparing off the main actor.
        cachedStateRefreshGeneration &+= 1
        let startedContext = contextProvider()
        guard !startedContext.state.phase.isBusy else {
            result = Self.result(
                status: .needsAttention,
                level: level,
                checkedAt: now(),
                issues: [ArkFileOfflineReadinessIssue(
                    id: "install-in-progress",
                    severity: .warning,
                    title: "Content is changing",
                    detail: "Finish the current download or repair before running an offline check."
                )]
            )
            return
        }

        isRunning = true
        runningLevel = level
        progressFraction = 0
        currentFile = "Preparing offline check"
        result = Self.result(status: .checking, level: level)
        defer {
            isRunning = false
            runningLevel = nil
            activeTask = nil
            currentFile = ""
        }

        guard let root = startedContext.root else {
            result = Self.result(
                status: .noManagedContent,
                level: level,
                checkedAt: now()
            )
            return
        }
        guard !startedContext.needsRepair, startedContext.hasDurableLocalAccess else {
            result = Self.result(
                status: .needsAttention,
                level: level,
                checkedAt: now(),
                issues: [startedContext.hasDurableLocalAccess ? Self.repairIssue : Self.installCommitIssue]
            )
            return
        }
        let catalogProvider = self.catalogProvider
        let selection = await Task.detached(priority: .utility) {
            Self.prepareSelection(
                context: startedContext,
                root: root,
                catalog: catalogProvider()
            )
        }.value
        let contextAfterPreparation = contextProvider()
        guard Self.hasSameAuthoritativeContext(
            startedContext: startedContext,
            currentContext: contextAfterPreparation
        ) else {
            applyContentChangedResult(level: level)
            return
        }
        guard let selection else {
            result = Self.result(
                status: .unavailable,
                level: level,
                checkedAt: now(),
                issues: [Self.manifestUnavailableIssue]
            )
            return
        }

        let contextFingerprint = startedContext.fingerprint
        let prepared = await Task.detached(priority: .utility) {
            Self.scanFiles(
                root: root,
                manifest: selection.manifest,
                manifestIdentity: selection.identity,
                contextFingerprint: contextFingerprint
            )
        }.value

        if Task.isCancelled {
            applyCancelledResult(level: level, prepared: prepared)
            return
        }

        var issues = prepared.issues + prepared.advisoryIssues
        if prepared.issues.isEmpty,
           let representativeZim = prepared.representativeZim,
           !(await zimProbe(representativeZim)) {
            issues.append(ArkFileOfflineReadinessIssue(
                id: "zim-unreadable",
                severity: .failure,
                title: "An offline library could not open",
                detail: "ArkFile could not read \(representativeZim.lastPathComponent). Repair the installed content and check again."
            ))
        }

        let availableStorage = storageProvider()
        let headroom = ArkFileContentStoragePreflight.safetyBytes(for: prepared.totalBytes)
        if let availableStorage, availableStorage < headroom {
            issues.append(ArkFileOfflineReadinessIssue(
                id: "low-storage",
                severity: .warning,
                title: "Storage is running low",
                detail: "This device reports less free space than ArkFile's \(Self.formattedBytes(headroom)) readiness guideline. Apple does not publish a guaranteed safe threshold."
            ))
        }

        if level == .full && !issues.contains(where: { $0.severity == .failure }) {
            let deepIssues = await runDeepVerification(prepared: prepared)
            issues.append(contentsOf: deepIssues)
        } else {
            progressFraction = 1
        }

        if Task.isCancelled {
            applyCancelledResult(level: level, prepared: prepared)
            return
        }
        guard Self.hasSameAuthoritativeContext(
            startedContext: startedContext,
            currentContext: contextProvider()
        ) else {
            applyContentChangedResult(
                level: level,
                prepared: prepared,
                availableStorage: availableStorage,
                recommendedHeadroom: headroom
            )
            return
        }

        let hardFailure = issues.contains { $0.severity == .failure }
        let checkedAt = now()
        let status: ArkFileOfflineReadinessStatus = hardFailure ? .needsAttention : .ready
        result = ArkFileOfflineReadinessResult(
            status: status,
            level: level,
            checkedAt: checkedAt,
            manifestIdentity: prepared.manifestIdentity,
            selectedFileCount: prepared.manifest.files.count,
            checkedBytes: level == .full && !hardFailure ? prepared.totalBytes : 0,
            totalBytes: prepared.totalBytes,
            availableStorageBytes: availableStorage,
            recommendedHeadroomBytes: headroom,
            issues: issues
        )
        if !hardFailure {
            recordSuccessfulPass(
                identity: prepared.manifestIdentity,
                tier: startedContext.state.tier,
                level: level,
                checkedAt: checkedAt
            )
        }
    }

    private func runDeepVerification(prepared: PreparedCheck) async -> [ArkFileOfflineReadinessIssue] {
        progressFraction = 0
        let progressReportingInterval: Int64 = 64 * 1_024 * 1_024
        let stream = AsyncStream<DeepEvent> { continuation in
            let task = Task.detached(priority: .utility) {
                var completedBeforeFile: Int64 = 0
                for entry in prepared.manifest.files {
                    if Task.isCancelled {
                        break
                    }
                    let fileURL = prepared.root.appendingPathComponent(entry.normalizedRelativePath)
                    let completedBeforeCurrentFile = completedBeforeFile
                    let progressThrottle = ArkFileReadinessProgressThrottle(
                        interval: progressReportingInterval
                    )
                    do {
                        try ArkFileContentFileVerifier.verifyFile(
                            at: fileURL,
                            entry: entry,
                            progress: { fileBytes in
                                guard progressThrottle.shouldReport(fileBytes, total: entry.sizeBytes) else {
                                    return
                                }
                                continuation.yield(.progress(
                                    completedBytes: completedBeforeCurrentFile + fileBytes,
                                    currentFile: entry.normalizedRelativePath
                                ))
                            }
                        )
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.yield(.failure(ArkFileOfflineReadinessIssue(
                            id: "checksum-\(entry.normalizedRelativePath.lowercased())",
                            severity: .failure,
                            title: "Integrity check failed",
                            detail: "\(entry.normalizedRelativePath) no longer matches the downloaded manifest. Repair this content before relying on it offline."
                        )))
                    }
                    completedBeforeFile += entry.sizeBytes
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        var issues: [ArkFileOfflineReadinessIssue] = []
        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case let .progress(completedBytes, file):
                progressFraction = prepared.totalBytes > 0
                    ? min(1, Double(completedBytes) / Double(prepared.totalBytes))
                    : 1
                currentFile = file
            case .failure(let issue):
                issues.append(issue)
            }
        }
        return issues
    }

    private nonisolated static func prepareSelection(
        context: ArkFileOfflineReadinessContext,
        root: URL,
        catalog: ArkFileContentCatalog?
    ) -> (manifest: ArkFilePackageManifest, identity: String)? {
        let manifestURL = root.appendingPathComponent(ArkFileContentPackInstaller.contentRootManifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ArkFilePackageManifest.self, from: data),
              let selected = try? ArkFileContentCompatibilityPlanner.manifestFilteringExcludedCatalogAnchors(
                manifest,
                catalog: catalog,
                excludedCatalogAnchorKeys: context.state.normalizedExcludedItemPaths
              ),
              let encoded = try? Self.canonicalManifestData(selected) else {
            return nil
        }
        var identityData = encoded
        identityData.append(Data((context.state.tier?.rawValue ?? "none").utf8))
        identityData.append(Data(context.state.activePath.utf8))
        identityData.append(Data((context.state.installedAt?.ISO8601Format() ?? "none").utf8))
        // A cached readiness pass must not survive cheap, observable payload
        // changes. Stat every selected file (no payload hashing) so a missing,
        // resized, or replaced file invalidates the prior pass immediately.
        for entry in selected.files.sorted(by: {
            $0.normalizedRelativePath.lowercased() < $1.normalizedRelativePath.lowercased()
        }) {
            let fileURL = root.appendingPathComponent(entry.normalizedRelativePath)
            identityData.append(Data(entry.normalizedRelativePath.lowercased().utf8))
            if let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]) {
                identityData.append(Data("\(values.isRegularFile == true)".utf8))
                identityData.append(Data("\(values.fileSize ?? -1)".utf8))
                identityData.append(Data(
                    "\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)".utf8
                ))
            } else {
                identityData.append(Data("missing".utf8))
            }
        }
        let digest = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        return (selected, digest)
    }

    private nonisolated static func scanFiles(
        root: URL,
        manifest: ArkFilePackageManifest,
        manifestIdentity: String,
        contextFingerprint: String
    ) -> PreparedCheck {
        var failures: [ArkFileOfflineReadinessIssue] = []
        var advisories: [ArkFileOfflineReadinessIssue] = []
        var representativeZim: URL?

        for entry in manifest.files {
            let url = root.appendingPathComponent(entry.normalizedRelativePath)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else {
                failures.append(ArkFileOfflineReadinessIssue(
                    id: "missing-\(entry.normalizedRelativePath.lowercased())",
                    severity: .failure,
                    title: "Offline content is missing",
                    detail: "\(entry.normalizedRelativePath) is not available on this device."
                ))
                continue
            }
            guard size == entry.sizeBytes else {
                failures.append(ArkFileOfflineReadinessIssue(
                    id: "size-\(entry.normalizedRelativePath.lowercased())",
                    severity: .failure,
                    title: "Offline content is incomplete",
                    detail: "\(entry.normalizedRelativePath) has an unexpected size and should be repaired."
                ))
                continue
            }
            if entry.isZim, representativeZim == nil {
                representativeZim = url
            } else if let advisory = secondaryFormatAdvisory(for: url) {
                advisories.append(advisory)
            }
        }

        return PreparedCheck(
            contextFingerprint: contextFingerprint,
            root: root,
            manifest: manifest,
            manifestIdentity: manifestIdentity,
            totalBytes: manifest.files.reduce(0) { $0 + $1.sizeBytes },
            representativeZim: representativeZim,
            issues: failures,
            advisoryIssues: advisories
        )
    }

    private nonisolated static func secondaryFormatAdvisory(for url: URL) -> ArkFileOfflineReadinessIssue? {
        let ext = url.pathExtension.lowercased()
        let readable: Bool
        switch ext {
        case "pdf":
            readable = PDFDocument(url: url) != nil
        case "jpg", "jpeg", "png", "gif", "webp", "bmp":
            readable = CGImageSourceCreateWithURL(url as CFURL, nil) != nil
        case "zip":
            readable = (try? Archive(url: url, accessMode: .read, pathEncoding: nil)) != nil
        case "html", "htm":
            readable = (try? readPrefix(of: url, count: 4096))?.isEmpty == false
        case "pmtiles":
            guard let data = try? readPrefix(of: url, count: 8), data.count >= 8 else {
                readable = false
                break
            }
            readable = String(data: data.prefix(7), encoding: .utf8) == "PMTiles" && data[7] == 3
        default:
            return nil
        }
        guard !readable else { return nil }
        return ArkFileOfflineReadinessIssue(
            id: "probe-\(url.standardizedFileURL.path.lowercased())",
            severity: .warning,
            title: "A format check was inconclusive",
            detail: "ArkFile found \(url.lastPathComponent), but its quick format probe was inconclusive. Run the full integrity check before relying on it."
        )
    }

    private nonisolated static func readPrefix(of url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private func applyCancelledResult(
        level: ArkFileOfflineReadinessCheckLevel,
        prepared: PreparedCheck
    ) {
        result = Self.result(
            status: .cancelled,
            level: level,
            checkedAt: now(),
            manifestIdentity: prepared.manifestIdentity,
            selectedFileCount: prepared.manifest.files.count,
            totalBytes: prepared.totalBytes,
            issues: [ArkFileOfflineReadinessIssue(
                id: "cancelled",
                severity: .warning,
                title: "Check cancelled",
                detail: "No readiness result was changed. Run the check again when convenient."
            )]
        )
    }

    private func applyContentChangedResult(
        level: ArkFileOfflineReadinessCheckLevel,
        prepared: PreparedCheck? = nil,
        availableStorage: Int64? = nil,
        recommendedHeadroom: Int64? = nil
    ) {
        result = Self.result(
            status: .needsAttention,
            level: level,
            checkedAt: now(),
            manifestIdentity: prepared?.manifestIdentity,
            selectedFileCount: prepared?.manifest.files.count ?? 0,
            totalBytes: prepared?.totalBytes ?? 0,
            availableStorageBytes: availableStorage,
            recommendedHeadroomBytes: recommendedHeadroom,
            issues: [ArkFileOfflineReadinessIssue(
                id: "content-changed",
                severity: .warning,
                title: "Content changed during the check",
                detail: "Run the offline check again after downloads or library changes finish."
            )]
        )
    }

    private func applyChangedCachedContext(_ context: ArkFileOfflineReadinessContext) {
        guard context.root != nil else {
            result = Self.result(status: .noManagedContent)
            lastQuickPassAt = nil
            lastFullPassAt = nil
            return
        }
        guard !context.needsRepair, context.hasDurableLocalAccess else {
            result = Self.result(
                status: .needsAttention,
                issues: [context.hasDurableLocalAccess ? Self.repairIssue : Self.installCommitIssue]
            )
            return
        }
        invalidatePassRecord()
        result = Self.result(status: .checkDue)
    }

    private func recordSuccessfulPass(
        identity: String,
        tier: ArkFileContentTier?,
        level: ArkFileOfflineReadinessCheckLevel,
        checkedAt: Date
    ) {
        var record = Self.loadPassRecord(from: userDefaults)
        if record?.manifestIdentity != identity || record?.tier != tier {
            record = PassRecord(manifestIdentity: identity, tier: tier)
        }
        record?.lastQuickPassAt = checkedAt
        if level == .full {
            record?.lastFullPassAt = checkedAt
        }
        if let record, let data = try? JSONEncoder().encode(record) {
            userDefaults.set(data, forKey: DefaultsKey.passRecord)
            lastQuickPassAt = record.lastQuickPassAt
            lastFullPassAt = record.lastFullPassAt
        }
    }

    private func invalidatePassRecord() {
        userDefaults.removeObject(forKey: DefaultsKey.passRecord)
        lastQuickPassAt = nil
        lastFullPassAt = nil
    }

    private nonisolated static func canonicalManifestData(_ manifest: ArkFilePackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func loadPassRecord(from defaults: UserDefaults) -> PassRecord? {
        guard let data = defaults.data(forKey: DefaultsKey.passRecord) else { return nil }
        return try? JSONDecoder().decode(PassRecord.self, from: data)
    }

    private static let repairIssue = ArkFileOfflineReadinessIssue(
        id: "repair-needed",
        severity: .failure,
        title: "Offline content needs repair",
        detail: "Finish or repair the installed content before relying on ArkFile during an outage."
    )

    private static let manifestUnavailableIssue = ArkFileOfflineReadinessIssue(
        id: "manifest-unavailable",
        severity: .warning,
        title: "This installation cannot be verified yet",
        detail: "ArkFile found older or recovered content without its verification manifest. Repair or reinstall the selected content to enable readiness checks."
    )

    private static let installCommitIssue = ArkFileOfflineReadinessIssue(
        id: "install-commit-invalid",
        severity: .failure,
        title: "Offline content needs repair",
        detail: "ArkFile could not verify the local installation record. Repair the downloaded content before relying on it during an outage."
    )

    private static func result(
        status: ArkFileOfflineReadinessStatus,
        level: ArkFileOfflineReadinessCheckLevel? = nil,
        checkedAt: Date? = nil,
        manifestIdentity: String? = nil,
        selectedFileCount: Int = 0,
        checkedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        availableStorageBytes: Int64? = nil,
        recommendedHeadroomBytes: Int64? = nil,
        issues: [ArkFileOfflineReadinessIssue] = []
    ) -> ArkFileOfflineReadinessResult {
        ArkFileOfflineReadinessResult(
            status: status,
            level: level,
            checkedAt: checkedAt,
            manifestIdentity: manifestIdentity,
            selectedFileCount: selectedFileCount,
            checkedBytes: checkedBytes,
            totalBytes: totalBytes,
            availableStorageBytes: availableStorageBytes,
            recommendedHeadroomBytes: recommendedHeadroomBytes,
            issues: issues
        )
    }

    nonisolated static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
#endif
