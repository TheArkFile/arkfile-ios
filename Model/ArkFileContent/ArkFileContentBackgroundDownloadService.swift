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

import CryptoKit
import Darwin
import Foundation
import Security
import UserNotifications

/// Posts quiet local notifications about pack downloads when the app is not
/// in a position to show progress UI (e.g. after iOS relaunched it in the background).
/// Uses provisional authorization so no permission prompt ever interrupts the user.
enum ArkFileEssentialsDownloadNotifier {
    static let attentionNotificationIdentifier = "arkfile.essentials.download-attention"
    static let newContentNotificationIdentifier = "arkfile.essentials.new-content"

    static func notifyDownloadNeedsAttention(_ body: String, tier: ArkFileContentTier? = nil) {
        deliver(identifier: attentionNotificationIdentifier, body: body, tier: tier)
    }

    static func notifyNewContentAvailable(_ body: String, tier: ArkFileContentTier? = nil) {
        deliver(identifier: newContentNotificationIdentifier, body: body, tier: tier)
    }

    private static func deliver(identifier: String, body: String, tier: ArkFileContentTier?) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .provisional]
                ) { granted, _ in
                    guard granted else { return }
                    addRequest(identifier: identifier, body: body, tier: tier)
                }
            case .authorized, .provisional, .ephemeral:
                addRequest(identifier: identifier, body: body, tier: tier)
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func addRequest(identifier: String, body: String, tier: ArkFileContentTier?) {
        let content = UNMutableNotificationContent()
        content.title = "ArkFile \(ArkFileContentPackDisplayName.name(for: tier))"
        content.body = body
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

enum ArkFileContentFileVerifier {
    enum VerificationOutcome {
        case matches
        case definitiveMismatch
        case unavailable(Error)
    }

    private static let fileIOChunkBytes = 1024 * 1024

    static func fileMatches(_ url: URL, entry: ArkFilePackageManifest.Entry) -> Bool {
        guard FileManager.default.fileExists(atPath: url.fileSystemPath) else {
            return false
        }
        do {
            try verifyFile(at: url, entry: entry)
            return true
        } catch {
            return false
        }
    }

    static func verificationOutcome(
        at url: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> VerificationOutcome {
        do {
            try verifyFile(at: url, entry: entry)
            return .matches
        } catch let error as ArkFileContentError {
            switch error {
            case .fileSizeMismatch, .checksumMismatch:
                return .definitiveMismatch
            default:
                return .unavailable(error)
            }
        } catch {
            return .unavailable(error)
        }
    }

    static func verifyFile(
        at url: URL,
        entry: ArkFilePackageManifest.Entry,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) throws {
        let actualSize = try FileManager.default.attributesOfItem(atPath: url.fileSystemPath)[.size] as? NSNumber
        guard actualSize?.int64Value == entry.sizeBytes else {
            throw ArkFileContentError.fileSizeMismatch(entry.normalizedRelativePath)
        }
        let digest = try sha256HexDigest(of: url, progress: progress)
        guard digest == entry.sha256.lowercased() else {
            throw ArkFileContentError.checksumMismatch(entry.normalizedRelativePath)
        }
    }

    static func sha256HexDigest(
        of url: URL,
        progress: (@Sendable (Int64) -> Void)? = nil,
        continuation: (@Sendable () throws -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var completedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            try continuation?()
            let bytesRead = try autoreleasepool { () throws -> Int in
                guard let data = try handle.read(upToCount: fileIOChunkBytes),
                      !data.isEmpty else {
                    return 0
                }
                hasher.update(data: data)
                return data.count
            }
            guard bytesRead > 0 else { break }
            completedBytes += Int64(bytesRead)
            progress?(completedBytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ArkFileHTTPContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    static func parse(_ value: String?) -> ArkFileHTTPContentRange? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }

        let rangeAndTotal = trimmed.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]) else {
            return nil
        }

        let rangeParts = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              start <= end,
              end < total else {
            return nil
        }

        return ArkFileHTTPContentRange(start: start, end: end, total: total)
    }
}

enum ArkFileBackgroundDownloadDurabilityOperation: Equatable {
    case synchronizeFile(String)
    case synchronizeDirectory(String)
}

private enum ArkFileFinishedDownloadOutcome: Sendable {
    case finished
    case partial(Int64)
}

private final class ArkFileBackgroundDownloadPostprocessingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCount = 0
    private var deferredCompletion: (() -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var rejectsAllNewWork = false
    private var rejectedTaskIdentifiers = Set<Int>()

    func begin(taskIdentifier: Int) -> Bool {
        lock.lock()
        guard !rejectsAllNewWork,
              !rejectedTaskIdentifiers.contains(taskIdentifier) else {
            lock.unlock()
            return false
        }
        pendingCount += 1
        lock.unlock()
        return true
    }

    func beginTerminalWork() {
        lock.lock()
        pendingCount += 1
        lock.unlock()
    }

    func beginRejectingAll(taskIdentifiers: Set<Int>) {
        lock.lock()
        rejectsAllNewWork = true
        rejectedTaskIdentifiers.formUnion(taskIdentifiers)
        lock.unlock()
    }

    func reject(taskIdentifiers: Set<Int>) {
        lock.lock()
        rejectedTaskIdentifiers.formUnion(taskIdentifiers)
        lock.unlock()
    }

    func endRejectingAll() {
        lock.lock()
        rejectsAllNewWork = false
        lock.unlock()
    }

    func end() {
        let completion: (() -> Void)?
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 {
            completion = deferredCompletion
            deferredCompletion = nil
            waiters = idleWaiters
            idleWaiters.removeAll()
        } else {
            completion = nil
            waiters = []
        }
        lock.unlock()
        completion?()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func finishEvents(_ completion: (() -> Void)?) {
        let completionToRun: (() -> Void)?
        lock.lock()
        if pendingCount > 0 {
            if let completion {
                deferredCompletion = completion
            }
            completionToRun = nil
        } else {
            completionToRun = completion
        }
        lock.unlock()
        completionToRun?()
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately: Bool
            lock.lock()
            if pendingCount == 0 {
                shouldResumeImmediately = true
            } else {
                idleWaiters.append(continuation)
                shouldResumeImmediately = false
            }
            lock.unlock()
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }
}

private final class ArkFileBackgroundDownloadProgressCoalescer: @unchecked Sendable {
    private struct Snapshot {
        var completedBytes: Int64
        var updatedAt: Date
    }

    private let minimumBytes: Int64
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]

    init(
        minimumBytes: Int64 = 8 * 1024 * 1024,
        minimumInterval: TimeInterval = 1
    ) {
        self.minimumBytes = minimumBytes
        self.minimumInterval = minimumInterval
    }

    func shouldForward(
        recordID: String,
        completedBytes: Int64,
        expectedBytes: Int64,
        now: Date = Date()
    ) -> Bool {
        if expectedBytes > 0 && completedBytes >= expectedBytes {
            remove(recordID: recordID)
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        guard let previous = snapshots[recordID] else {
            snapshots[recordID] = Snapshot(completedBytes: completedBytes, updatedAt: now)
            return true
        }

        guard completedBytes >= previous.completedBytes else {
            snapshots[recordID] = Snapshot(completedBytes: completedBytes, updatedAt: now)
            return true
        }

        let byteDelta = completedBytes - previous.completedBytes
        let elapsed = now.timeIntervalSince(previous.updatedAt)
        guard byteDelta >= minimumBytes || elapsed >= minimumInterval else {
            return false
        }

        snapshots[recordID] = Snapshot(completedBytes: completedBytes, updatedAt: now)
        return true
    }

    func remove(recordID: String) {
        lock.lock()
        snapshots.removeValue(forKey: recordID)
        lock.unlock()
    }
}

struct ArkFileContentBackgroundDownloadRecord: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case scheduled
        case downloading
        case paused
        case finished
        case failed
        case cancelled
    }

    let id: String
    let manifest: ArkFilePackageManifest
    let entry: ArkFilePackageManifest.Entry
    let sourceURL: URL
    /// Cached sandbox location for compatibility with the shipped v1/v2
    /// journal. It is rebound to the current managed Downloads root before the
    /// background URLSession is created; an iOS container path is not identity.
    var destinationPath: String
    /// Runtime-only request headers. The record store always removes these
    /// before writing JSON so bearer tokens never enter the download journal.
    var authorizationHeaders: [String: String]
    /// Opaque Keychain account used to recover request headers after iOS
    /// relaunches the app to continue a background transfer.
    var authorizationReference: String? = nil
    var allowsCellularDownload: Bool? = nil
    var phase: Phase
    var completedBytes: Int64
    var expectedBytes: Int64
    var resumeData: Data?
    var activeRangeStart: Int64? = nil
    var activeRangeEnd: Int64? = nil
    var sessionTaskIdentifier: Int? = nil
    var errorMessage: String?
    var updatedAt: Date

    var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }

    var activeRange: ClosedRange<Int64>? {
        guard let activeRangeStart,
              let activeRangeEnd,
              activeRangeStart <= activeRangeEnd else {
            return nil
        }
        return activeRangeStart...activeRangeEnd
    }

    var contentTier: ArkFileContentTier {
        ArkFileContentTier.iOSInstallableTier(named: manifest.tier) ?? .lite
    }

    var packName: String {
        ArkFileContentPackDisplayName.name(for: contentTier)
    }

    var request: URLRequest {
        request(range: activeRange)
    }

    func request(
        range explicitRange: ClosedRange<Int64>? = nil,
        authorizationHeaders explicitAuthorizationHeaders: [String: String]? = nil
    ) -> URLRequest {
        var request = URLRequest(url: sourceURL, timeoutInterval: 60)
        let requestedRange = explicitRange ?? activeRange
        let relaxNetworkPolicy = ArkFileContentAPI.usesRelaxedDebugNetworking(host: sourceURL.host ?? "")
        let allowsCellular = allowsCellularDownload == true || relaxNetworkPolicy
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        (explicitAuthorizationHeaders ?? authorizationHeaders).forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let requestedRange {
            request.setValue(
                "bytes=\(requestedRange.lowerBound)-\(requestedRange.upperBound)",
                forHTTPHeaderField: "Range"
            )
        }
        return request
    }

    func refreshedForRetry(
        manifest: ArkFilePackageManifest,
        entry: ArkFilePackageManifest.Entry,
        sourceURL: URL,
        destinationPath: String,
        authorizationHeaders: [String: String],
        allowsCellularDownload: Bool = false,
        updatedAt: Date = Date()
    ) -> ArkFileContentBackgroundDownloadRecord {
        let canResume = self.entry == entry
            && self.sourceURL == sourceURL
            && self.destinationPath == destinationPath
            && self.authorizationHeaders == authorizationHeaders
            && self.phase == .paused
            && self.resumeData != nil
        return ArkFileContentBackgroundDownloadRecord(
            id: id,
            manifest: manifest,
            entry: entry,
            sourceURL: sourceURL,
            destinationPath: destinationPath,
            authorizationHeaders: authorizationHeaders,
            authorizationReference: authorizationReference ?? id,
            allowsCellularDownload: allowsCellularDownload,
            phase: .scheduled,
            completedBytes: canResume ? completedBytes : 0,
            expectedBytes: entry.sizeBytes,
            resumeData: canResume ? resumeData : nil,
            activeRangeStart: nil,
            activeRangeEnd: nil,
            errorMessage: nil,
            updatedAt: updatedAt
        )
    }

    func discardingResumeDataForFreshRetry(updatedAt: Date = Date()) -> ArkFileContentBackgroundDownloadRecord {
        guard resumeData != nil || completedBytes != 0 else { return self }
        var record = self
        record.completedBytes = 0
        record.resumeData = nil
        record.errorMessage = nil
        record.updatedAt = updatedAt
        return record
    }

    static func id(for entry: ArkFilePackageManifest.Entry) -> String {
        // Preserve the shipped record-ID wire format. It is not path identity:
        // selection reconciliation separately rejects any collision it causes.
        // Shipped manifests are lowercase; canonicalizing only hash case keeps
        // those IDs stable while avoiding case-only identity churn.
        "\(entry.sha256.lowercased().prefix(16))-\(legacyRecordPathComponent(for: entry))"
    }

    private static func legacyRecordPathComponent(
        for entry: ArkFilePackageManifest.Entry
    ) -> String {
        ArkFileContentCanonicalPath.key(entry.normalizedRelativePath)
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "-")
    }
}

/// Full selected-entry identity for a path-only partial. The persisted record
/// ID intentionally keeps its shipped truncated-hash wire format, so an ID by
/// itself cannot prove ownership when two full SHA-256 values share a prefix.
struct ArkFileContentBackgroundSelectedOwner: Equatable, Sendable {
    let recordID: String
    let entry: ArkFilePackageManifest.Entry

    static func == (
        lhs: ArkFileContentBackgroundSelectedOwner,
        rhs: ArkFileContentBackgroundSelectedOwner
    ) -> Bool {
        lhs.entry.sizeBytes == rhs.entry.sizeBytes
            && lhs.entry.sha256.lowercased() == rhs.entry.sha256.lowercased()
    }
}

struct ArkFileBackgroundDownloadTaskIdentity: Equatable, Sendable {
    let taskIdentifier: Int
    let recordID: String?
}

enum ArkFileBackgroundTerminalSchedulingCallback: Sendable {
    case didFinish
    case didComplete
}

final class ArkFileContentBackgroundDownloadRecordStore: @unchecked Sendable {
    private static let supportedSchemaVersions = 1...2

    private enum MutationResult {
        case write
        case alreadySatisfied
        case failed
    }

    private struct StoreFile: Codable {
        let schemaVersion: Int
        var records: [ArkFileContentBackgroundDownloadRecord]

        init(records: [ArkFileContentBackgroundDownloadRecord]) {
            self.schemaVersion = 2
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case records
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            records = try container.decode([ArkFileContentBackgroundDownloadRecord].self, forKey: .records)
        }
    }

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL = ArkFileContentBackgroundDownloadRecordStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func record(id: String) -> ArkFileContentBackgroundDownloadRecord? {
        loadRecords().first { $0.id == id }
    }

    @discardableResult
    func save(_ record: ArkFileContentBackgroundDownloadRecord) -> Bool {
        updateRecords { records in
            records.removeAll { $0.id == record.id }
            records.append(record)
            return .write
        }
    }

    @discardableResult
    func update(
        id: String,
        _ updateRecord: (inout ArkFileContentBackgroundDownloadRecord) -> Void
    ) -> Bool {
        updateRecords { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return .failed
            }
            updateRecord(&records[index])
            records[index].updatedAt = Date()
            return .write
        }
    }

    @discardableResult
    func remove(id: String) -> Bool {
        updateRecords { records in
            guard records.contains(where: { $0.id == id }) else {
                return .alreadySatisfied
            }
            records.removeAll { $0.id == id }
            return .write
        }
    }

    @discardableResult
    func removeAll() -> Bool {
        updateRecords { records in
            guard !records.isEmpty else { return .alreadySatisfied }
            records.removeAll()
            return .write
        }
    }

    func loadRecords() -> [ArkFileContentBackgroundDownloadRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let storeFile = try? JSONDecoder().decode(StoreFile.self, from: data),
              Self.supportedSchemaVersions.contains(storeFile.schemaVersion) else {
            return []
        }
        return storeFile.records
    }

    /// Strict inventory used before destructive cancellation. `nil` means the
    /// journal is unreadable, malformed, or owned by a future app and therefore
    /// cannot safely be treated as empty. A definitively absent journal is an
    /// authoritative empty inventory.
    func loadRecordsForMutation() -> [ArkFileContentBackgroundDownloadRecord]? {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try Data(contentsOf: fileURL)
            let storeFile = try JSONDecoder().decode(StoreFile.self, from: data)
            guard Self.supportedSchemaVersions.contains(storeFile.schemaVersion) else {
                return nil
            }
            return storeFile.records
        } catch {
            return Self.isDefinitiveNoSuchFile(error) ? [] : nil
        }
    }

    /// Moves legacy plaintext journal headers into the device-only credential
    /// store, then rewrites the record through the sanitizing v2 writer. The
    /// payload file and verified byte progress remain untouched.
    func migrateLegacyAuthorization(
        to authorizationStore: ArkFileContentBackgroundAuthorizationStore
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let storeFile = try? JSONDecoder().decode(StoreFile.self, from: data),
              Self.supportedSchemaVersions.contains(storeFile.schemaVersion) else {
            return
        }

        // Resolve the complete credential mapping before the first Keychain
        // write. A legacy collision must not let the last record silently win
        // one shared account and then strip both records' plaintext sources.
        var credentialsByReference = [String: [String: String]]()
        let allReferences = storeFile.records.map {
            $0.authorizationReference ?? $0.id
        }
        guard Set(allReferences).count == allReferences.count else {
            // One record finishing must never delete another record's only
            // cold-resume credential. New records use unique record IDs, so a
            // shared legacy reference is rejected before any Keychain write.
            return
        }
        for record in storeFile.records where !record.authorizationHeaders.isEmpty {
            let reference = record.authorizationReference ?? record.id
            if let existingHeaders = credentialsByReference[reference],
               existingHeaders != record.authorizationHeaders {
                return
            }
            credentialsByReference[reference] = record.authorizationHeaders
        }

        // Stage every distinct legacy credential first. Rewriting one record at
        // a time would run the global sanitizer and could erase a later record's
        // only plaintext credential before it reached Keychain.
        for reference in credentialsByReference.keys.sorted() {
            guard let headers = credentialsByReference[reference],
                  authorizationStore.save(headers, reference: reference) else {
                // Plaintext is undesirable, but losing the only usable
                // credential would strand a purchased partial download. Leave
                // the entire legacy journal byte-for-byte until every Keychain
                // write succeeds.
                return
            }
        }

        var migratedRecords = storeFile.records
        var changed = false
        for index in migratedRecords.indices {
            let reference = migratedRecords[index].authorizationReference
                ?? migratedRecords[index].id
            guard migratedRecords[index].authorizationReference != reference
                    || !migratedRecords[index].authorizationHeaders.isEmpty
                    || migratedRecords[index].resumeData != nil else { continue }
            changed = true
            migratedRecords[index].authorizationReference = reference
            migratedRecords[index].authorizationHeaders = [:]
            migratedRecords[index].resumeData = nil
        }
        guard changed else { return }
        let migratedStoreFile = StoreFile(
            records: migratedRecords.sorted { $0.id < $1.id }
        )
        guard let migratedData = try? JSONEncoder().encode(migratedStoreFile) else {
            return
        }
        do {
            try ArkFileDurableAtomicWriter.write(migratedData, to: fileURL)
        } catch {
            // All staged Keychain entries are harmless duplicates. The journal
            // remains the authoritative plaintext retry source until a later
            // atomic rewrite succeeds.
            return
        }
    }

    /// Rebinds shipped absolute sandbox paths after iOS relocates the app
    /// container. Only the deterministic destination below the current managed
    /// Downloads root is inspected; the old persisted path is never read,
    /// moved, or removed.
    ///
    /// This deliberately performs a strict read before writing. Missing,
    /// unreadable, malformed, and future-version journals remain byte-for-byte
    /// untouched so a protected-data delay or newer app cannot be mistaken for
    /// an empty store.
    @discardableResult
    func rebindSupportedDestinationPaths(
        to downloadRoot: URL,
        updatedAt: Date = Date()
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL),
              var storeFile = try? JSONDecoder().decode(StoreFile.self, from: data),
              Self.supportedSchemaVersions.contains(storeFile.schemaVersion),
              !storeFile.records.contains(where: {
                  !$0.authorizationHeaders.isEmpty
              }) else {
            return 0
        }

        let normalizedRoot = downloadRoot.standardizedFileURL
        var reboundCount = 0
        for index in storeFile.records.indices {
            guard Self.recordIsValidForRebinding(
                storeFile.records[index],
                downloadRoot: normalizedRoot
            ) else {
                // A malformed legacy record has no authority to derive, open,
                // unlink, or truncate a managed path. Leave both journal entry
                // and bytes untouched; later task reconciliation cancels it.
                continue
            }
            let expectedURL = ArkFileContentDownloadPaths.partialDownloadURL(
                for: storeFile.records[index].entry,
                in: normalizedRoot
            ).standardizedFileURL
            guard storeFile.records[index].destinationPath != expectedURL.fileSystemPath else {
                continue
            }

            let durableCompletedBytes = min(
                max(0, storeFile.records[index].completedBytes),
                storeFile.records[index].entry.sizeBytes
            )
            guard let checkpointedReusableBytes = try? Self
                .coldLaunchCheckpointedReusableByteCount(
                    at: expectedURL,
                    entry: storeFile.records[index].entry,
                    durableCompletedBytes: durableCompletedBytes
                ) else {
                // A metadata read failure is not proof that the deterministic
                // partial disappeared. Preserve the old journal byte-for-byte
                // and retry after protected data or the filesystem recovers.
                return 0
            }

            storeFile.records[index].destinationPath = expectedURL.fileSystemPath
            storeFile.records[index].completedBytes = checkpointedReusableBytes
            storeFile.records[index].expectedBytes = storeFile.records[index].entry.sizeBytes
            storeFile.records[index].resumeData = nil
            storeFile.records[index].sessionTaskIdentifier = nil
            if storeFile.records[index].phase == .scheduled
                || storeFile.records[index].phase == .downloading
                || storeFile.records[index].phase == .finished
                || storeFile.records[index].activeRange != nil {
                storeFile.records[index].phase = .paused
            }
            storeFile.records[index].updatedAt = updatedAt
            reboundCount += 1
        }

        guard reboundCount > 0 else { return 0 }
        let sanitizedRecords = storeFile.records.map { record -> ArkFileContentBackgroundDownloadRecord in
            var sanitized = record
            sanitized.authorizationHeaders = [:]
            sanitized.resumeData = nil
            return sanitized
        }
        let reboundStoreFile = StoreFile(records: sanitizedRecords.sorted { $0.id < $1.id })
        guard let reboundData = try? JSONEncoder().encode(reboundStoreFile) else {
            return 0
        }
        do {
            try ArkFileDurableAtomicWriter.write(reboundData, to: fileURL)
            return reboundCount
        } catch {
            return 0
        }
    }

    /// Container rebinding runs synchronously during service initialization.
    /// It may inspect inode metadata but must never hash, truncate, or unlink a
    /// potentially multi-gigabyte partial. The durable journal remains the
    /// upper bound; foreground reconciliation verifies complete bytes and
    /// repairs interrupted appends off the launch path before reuse.
    private static func coldLaunchCheckpointedReusableByteCount(
        at url: URL,
        entry: ArkFilePackageManifest.Entry,
        durableCompletedBytes: Int64
    ) throws -> Int64 {
        switch try ArkFileManagedPartialFile.classify(url) {
        case .missing, .symbolicLink, .other:
            return 0
        case .regular(let size, let linkCount):
            guard size >= 0, size <= entry.sizeBytes else { return 0 }
            if size < entry.sizeBytes, linkCount != 1 {
                // An incomplete hard link is never an append target. Leave its
                // directory entry untouched for foreground reconciliation.
                return 0
            }
            return min(size, durableCompletedBytes)
        }
    }

    private static func recordIsValidForRebinding(
        _ record: ArkFileContentBackgroundDownloadRecord,
        downloadRoot: URL
    ) -> Bool {
        guard let tier = ArkFileContentTier.iOSInstallableTier(
            named: record.manifest.tier
        ),
        (try? record.manifest.validateForInstall(tier: tier)) != nil,
        record.manifest.files.contains(record.entry),
        record.id.lowercased()
            == ArkFileContentBackgroundDownloadRecord.id(for: record.entry).lowercased(),
        ArkFileContentBackgroundDownloadService.selectedRecordOwners(
            for: record.manifest,
            downloadRoot: downloadRoot
        ) != nil else {
            return false
        }
        return true
    }

    @discardableResult
    private func updateRecords(
        _ update: (inout [ArkFileContentBackgroundDownloadRecord]) -> MutationResult
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var records: [ArkFileContentBackgroundDownloadRecord]
        do {
            let data = try Data(contentsOf: fileURL)
            let storeFile = try JSONDecoder().decode(StoreFile.self, from: data)
            // A future app may own this journal. Never downgrade or overwrite
            // an explicitly unsupported version from an older binary.
            guard Self.supportedSchemaVersions.contains(storeFile.schemaVersion) else {
                return false
            }
            records = storeFile.records
        } catch {
            // An absent journal is the only safe empty-store state. Protected
            // data, permissions, I/O faults, and malformed bytes are all
            // non-authoritative; overwriting any of them could discard the
            // only durable record of a purchased pack's partial download.
            guard Self.isDefinitiveNoSuchFile(error) else { return false }
            records = []
        }
        // A global rewrite sanitizes every record. Refuse it while any record
        // still carries an unmigrated plaintext credential; only the all-or-
        // nothing migration above may clear those fields.
        guard !records.contains(where: { !$0.authorizationHeaders.isEmpty }) else {
            return false
        }
        switch update(&records) {
        case .alreadySatisfied:
            return true
        case .failed:
            return false
        case .write:
            break
        }
        let sanitizedRecords = records.map { record -> ArkFileContentBackgroundDownloadRecord in
            var sanitized = record
            sanitized.authorizationHeaders = [:]
            // URLSession resume blobs may embed the original request, including
            // authorization headers. ArkFile deliberately resumes from verified
            // on-disk byte ranges instead, so never persist those opaque blobs.
            sanitized.resumeData = nil
            return sanitized
        }
        let storeFile = StoreFile(records: sanitizedRecords.sorted { $0.id < $1.id })
        guard let data = try? JSONEncoder().encode(storeFile) else { return false }
        do {
            try ArkFileDurableAtomicWriter.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    private static func isDefinitiveNoSuchFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError)
    }

    static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("ArkFile", isDirectory: true)
            .appendingPathComponent("content-pack-background-downloads.json")
    }
}

/// Stores background-transfer authorization separately from the JSON journal.
/// `AfterFirstUnlockThisDeviceOnly` keeps iOS background relaunches working
/// without making the credential migratable to another device.
final class ArkFileContentBackgroundAuthorizationStore: @unchecked Sendable {
    private static let service = "app.arkfile.ios.background-download-authorization.v1"

    private let readData: (String) -> Data?
    private let writeData: (Data, String) -> Bool
    private let deleteData: (String) -> Void

    init(
        readData: ((String) -> Data?)? = nil,
        writeData: ((Data, String) -> Bool)? = nil,
        deleteData: ((String) -> Void)? = nil
    ) {
        self.readData = readData ?? Self.keychainData(account:)
        self.writeData = writeData ?? Self.setKeychainData(data:account:)
        self.deleteData = deleteData ?? Self.deleteKeychainData(account:)
    }

    @discardableResult
    func save(_ headers: [String: String], reference: String) -> Bool {
        guard let data = try? JSONEncoder().encode(headers) else { return false }
        return writeData(data, reference)
    }

    func headers(reference: String) -> [String: String]? {
        guard let data = readData(reference) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    func delete(reference: String) {
        deleteData(reference)
    }

    private static func keychainData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func setKeychainData(data: Data, account: String) -> Bool {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else { return false }
        query.merge(attributes) { _, new in new }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychainData(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@MainActor
final class ArkFileContentBackgroundDownloadService {
    static let shared = ArkFileContentBackgroundDownloadService()
    static let sessionIdentifier = "app.arkfile.content-pack.background-downloads"
    nonisolated static let standardRangeDownloadBytes: Int64 = 256 * 1024 * 1024
    nonisolated static let largeFileRangeDownloadThresholdBytes: Int64 = 10 * 1024 * 1024 * 1024
    nonisolated static let largeFileRangeDownloadBytes: Int64 = 1024 * 1024 * 1024
    nonisolated static let maximumTransientDownloadBytes: Int64 = largeFileRangeDownloadBytes
    nonisolated static let maximumStructuredErrorResponseBytes: Int64 = 64 * 1024
    // TestFlight interruptions have produced resume blobs that crash task creation.
    // Keep resume data disabled and resume large files from verified on-disk byte ranges instead.
    private static let reusesStoredResumeData = false

    var backgroundCompletionHandler: (() -> Void)? {
        get { sessionDelegate.backgroundCompletionHandler }
        set { sessionDelegate.backgroundCompletionHandler = newValue }
    }

    private let store: ArkFileContentBackgroundDownloadRecordStore
    private let authorizationStore: ArkFileContentBackgroundAuthorizationStore
    private let sessionDelegate: ArkFileContentBackgroundDownloadSessionDelegate
    private let managedDownloadRoot: URL?
    private let queue = DispatchQueue(label: "app.arkfile.content-pack.background-downloads", qos: .background)
    private var discardedTaskIdentifiers = Set<Int>()
    private var discardedRecordIDs = Set<String>()
    private var pausedRecordIDs = Set<String>()
    private var isPauseAllRequested = false
    private var cancellationGeneration: UInt64 = 0
    private var isDiscardingAllDownloads = false
    private var discardGeneration: UInt64 = 0
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var continuationTaskIdentifiers = [String: Int]()
    private var progressHandlers: [String: @MainActor @Sendable (Int64, Int64) -> Void] = [:]
    private var activeProgressRecords: [String: ActiveDownloadProgress] = [:]
    private var completedTasksAwaitingFinish = Set<String>()
    /// `didFinishDownloadingTo` owns the bounded HTTP response body, while
    /// `didComplete` is the terminal continuation gate. Preserve a validated
    /// structured error across either callback order without persisting it as
    /// authority or allowing a stale task to complete a newer continuation.
    private var pendingResponseErrorsByTaskIdentifier = [Int: Error]()
    /// The selected manifest owns each path-only partial by its hash-qualified
    /// record ID. This closes the gap between manifest selection and the first
    /// foreground `download` call, including background auto-scheduling.
    private var selectedOwnersByDestination = [
        String: ArkFileContentBackgroundSelectedOwner
    ]()
    private var isReconcilingSelectedManifest = false
    private var manifestReconciliationWaiters = [CheckedContinuation<Void, Never>]()

    private struct ActiveDownloadProgress {
        let activeRangeStart: Int64
        let expectedBytes: Int64
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Keep the session permissive so nsurlsessiond does not reject local/test
        // network paths; each URLRequest carries ArkFile's actual Wi-Fi policy.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: operationQueue)
    }()

    init(
        store: ArkFileContentBackgroundDownloadRecordStore = ArkFileContentBackgroundDownloadRecordStore(),
        authorizationStore: ArkFileContentBackgroundAuthorizationStore = ArkFileContentBackgroundAuthorizationStore(),
        managedDownloadRoot: URL? = ArkFileContentBackgroundDownloadService.currentManagedDownloadRoot()
    ) {
        self.store = store
        self.authorizationStore = authorizationStore
        self.managedDownloadRoot = managedDownloadRoot?.standardizedFileURL
        self.sessionDelegate = ArkFileContentBackgroundDownloadSessionDelegate()
        self.sessionDelegate.service = self
        store.migrateLegacyAuthorization(to: authorizationStore)
        if let downloadRoot = self.managedDownloadRoot {
            store.rebindSupportedDestinationPaths(to: downloadRoot)
            if let records = store.loadRecordsForMutation(),
               let restoredOwners = Self.selectedRecordOwnersForActiveRecords(
                   records,
                   downloadRoot: downloadRoot
               ) {
                // Background URLSession callbacks may arrive before foreground
                // manifest selection. Restore ownership only from one coherent,
                // fully validated embedded manifest; ambiguity leaves this map
                // empty so callbacks and auto-scheduling fail closed.
                selectedOwnersByDestination = restoredOwners
                enforceColdStartupPersistedTaskInvariant(
                    records: records,
                    selectedOwners: restoredOwners
                )
            } else if let records = store.loadRecordsForMutation() {
                // Invalid or ambiguous journals cannot authorize any restored
                // task. Tombstone known task IDs before session instantiation;
                // the live inventory below cancels the daemon tasks without
                // deriving or touching an untrusted destination path.
                let taskIdentifiers = Set(records.compactMap(\.sessionTaskIdentifier))
                discardedTaskIdentifiers.formUnion(taskIdentifiers)
                sessionDelegate.rejectCallbacks(for: taskIdentifiers)
            }
        }
        do {
            // No callbacks can enter this service until the background session
            // is instantiated below. Remove crash-orphaned handoffs now; the
            // handoff registry also protects any file made concurrently by a
            // different in-process delegate.
            _ = try ArkFileBackgroundDownloadTemporaryFileHandoff
                .scavengeManagedOrphans(namespace: "content-pack")
        } catch {
            Log.ContentPack.error(
                "Could not scavenge managed background handoffs: \(ArkFileBackgroundDownloadDiagnostics.message(for: error), privacy: .public)"
            )
        }
        _ = session
        Task { @MainActor [weak self] in
            await self?.enforceColdStartupLiveTaskInvariant()
        }
    }

    /// Restored records are available before the background session is
    /// instantiated, so serialize them first. This closes the launch window in
    /// which several previously valid tasks could all resume against a storage
    /// plan that reserves only one transient chunk.
    private func enforceColdStartupPersistedTaskInvariant(
        records: [ArkFileContentBackgroundDownloadRecord],
        selectedOwners: [String: ArkFileContentBackgroundSelectedOwner]
    ) {
        let recordGroups = Dictionary(grouping: records, by: \.id)
        let recordsByID = recordGroups.compactMapValues { groupedRecords in
            groupedRecords.count == 1 ? groupedRecords[0] : nil
        }
        let validTaskIdentifiers = Set(records.compactMap { record -> Int? in
            guard let taskIdentifier = record.sessionTaskIdentifier,
                  !Self.taskRequiresQuiescence(
                      record.id,
                      taskIdentifier: taskIdentifier,
                      recordsByID: recordsByID,
                      selectedOwners: selectedOwners
                  ) else {
                return nil
            }
            return taskIdentifier
        })
        let identities = records.compactMap { record -> ArkFileBackgroundDownloadTaskIdentity? in
            guard let taskIdentifier = record.sessionTaskIdentifier else { return nil }
            return ArkFileBackgroundDownloadTaskIdentity(
                taskIdentifier: taskIdentifier,
                recordID: record.id
            )
        }
        let excessTaskIdentifiers = Self.excessSelectedTaskIdentifiers(
            identities,
            validSelectedTaskIdentifiers: validTaskIdentifiers,
            preferredRecordID: nil
        )
        let persistedTaskIdentifiers = Set(identities.map(\.taskIdentifier))
        let taskIdentifiersToReject = excessTaskIdentifiers.union(
            persistedTaskIdentifiers.subtracting(validTaskIdentifiers)
        )
        guard !taskIdentifiersToReject.isEmpty else { return }

        discardedTaskIdentifiers.formUnion(taskIdentifiersToReject)
        sessionDelegate.rejectCallbacks(for: taskIdentifiersToReject)
        for record in records {
            guard let taskIdentifier = record.sessionTaskIdentifier,
                  excessTaskIdentifiers.contains(taskIdentifier) else {
                continue
            }
            pausedRecordIDs.insert(record.id)
            _ = store.update(id: record.id) { paused in
                Self.pauseRecordForColdStartupSerialization(&paused)
            }
        }
    }

    /// Inventories the real daemon tasks after session restoration and cancels
    /// every task that lacks one exact durable owner, plus every valid task
    /// beyond the single deterministic survivor. Persisted excess IDs were
    /// already rejected above, so callbacks cannot win this asynchronous race.
    private func enforceColdStartupLiveTaskInvariant() async {
        let (_, _, downloadTasks) = await session.tasks
        guard !downloadTasks.isEmpty else { return }
        guard let records = store.loadRecordsForMutation(),
              let downloadRoot = managedDownloadRoot,
              let selectedOwners = Self.selectedRecordOwnersForActiveRecords(
                  records,
                  downloadRoot: downloadRoot
              ) else {
            let taskIdentifiers = Set(downloadTasks.map(\.taskIdentifier))
            discardedTaskIdentifiers.formUnion(taskIdentifiers)
            sessionDelegate.rejectCallbacks(for: taskIdentifiers)
            await cancelTasksForDiscard(downloadTasks)
            await waitForDelegateQueueToDrain()
            await sessionDelegate.waitForPostprocessingToFinish()
            return
        }

        let recordGroups = Dictionary(grouping: records, by: \.id)
        let recordsByID = recordGroups.compactMapValues { groupedRecords in
            groupedRecords.count == 1 ? groupedRecords[0] : nil
        }
        let validTaskIdentifiers = Set(downloadTasks.compactMap { task -> Int? in
            Self.taskRequiresQuiescence(
                task.taskDescription,
                taskIdentifier: task.taskIdentifier,
                recordsByID: recordsByID,
                selectedOwners: selectedOwners
            ) ? nil : task.taskIdentifier
        })
        let excessTaskIdentifiers = Self.excessSelectedTaskIdentifiers(
            downloadTasks.map {
                ArkFileBackgroundDownloadTaskIdentity(
                    taskIdentifier: $0.taskIdentifier,
                    recordID: $0.taskDescription
                )
            },
            validSelectedTaskIdentifiers: validTaskIdentifiers,
            preferredRecordID: nil
        )
        let tasksToCancel = downloadTasks.filter {
            !validTaskIdentifiers.contains($0.taskIdentifier)
                || excessTaskIdentifiers.contains($0.taskIdentifier)
        }
        guard !tasksToCancel.isEmpty else { return }

        let taskIdentifiers = Set(tasksToCancel.map(\.taskIdentifier))
        discardedTaskIdentifiers.formUnion(taskIdentifiers)
        sessionDelegate.rejectCallbacks(for: taskIdentifiers)
        for task in tasksToCancel {
            guard let recordID = task.taskDescription,
                  let record = recordsByID[recordID],
                  record.sessionTaskIdentifier == task.taskIdentifier else {
                continue
            }
            pausedRecordIDs.insert(recordID)
            _ = store.update(id: recordID) { paused in
                Self.pauseRecordForColdStartupSerialization(&paused)
            }
        }
        await cancelTasksForDiscard(tasksToCancel)
        await waitForDelegateQueueToDrain()
        await sessionDelegate.waitForPostprocessingToFinish()
    }

    nonisolated static func pauseRecordForColdStartupSerialization(
        _ record: inout ArkFileContentBackgroundDownloadRecord
    ) {
        record.phase = .paused
        record.resumeData = nil
        record.sessionTaskIdentifier = nil
        // Keep completedBytes and an active range exactly as journaled. The
        // foreground retry reconciles any interrupted append back to that
        // durable checkpoint before reuse; startup must not canonize a suffix.
    }

    /// Never falls back to a temporary directory: rebinding to anything other
    /// than the app's current durable Application Support container would turn
    /// a transient lookup failure into persisted data loss.
    nonisolated static func currentManagedDownloadRoot() -> URL? {
        guard let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return ArkFileContentDownloadPaths.managedDownloadRoot(
            in: supportRoot.appendingPathComponent("ArkFile", isDirectory: true)
        )
    }

    nonisolated static func isExpectedManagedDownloadRoot(
        _ candidate: URL,
        expected: URL
    ) -> Bool {
        let standardizedCandidate = candidate.standardizedFileURL
        let standardizedExpected = expected.standardizedFileURL
        guard standardizedCandidate == standardizedExpected else { return false }

        var expectedPath = standardizedExpected.fileSystemPath
        while expectedPath.count > 1 && expectedPath.hasSuffix("/") {
            expectedPath.removeLast()
        }
        var info = stat()
        if Darwin.lstat(expectedPath, &info) == 0 {
            return (info.st_mode & S_IFMT) == S_IFDIR
        }
        // The installer may validate the deterministic root before creating it.
        // Every other metadata failure is non-authoritative and must fail closed.
        return errno == ENOENT
    }

    /// Establishes one selected-manifest owner for every path-only partial
    /// before storage accounting, hard-link preparation, or a new transfer may
    /// touch those paths. Stale tasks are tombstoned first, then cancelled and
    /// fully drained. Only managed `.arkdownload` bytes are ever reset; active
    /// installed content is outside this boundary.
    func quiesceStaleDownloads(
        for selectedManifest: ArkFilePackageManifest,
        downloadRoot: URL,
        preferredRecordID: String? = nil
    ) async throws {
        guard let managedDownloadRoot,
              Self.isExpectedManagedDownloadRoot(
                downloadRoot,
                expected: managedDownloadRoot
              ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused background download work outside its managed Downloads directory."
            )
        }
        await beginManifestReconciliation()
        defer { endManifestReconciliation() }

        // Keychain can be unavailable during protected-data startup. Retry the
        // all-or-nothing legacy migration on the first foreground reconciliation
        // so the same service instance recovers after device unlock.
        store.migrateLegacyAuthorization(to: authorizationStore)

        guard let selectedOwners = Self.selectedRecordOwners(
            for: selectedManifest,
            downloadRoot: downloadRoot
        ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile found colliding selected download paths and left every partial file untouched."
            )
        }
        // Publish selection ownership before the first suspension point so a
        // stale background callback cannot schedule its next chunk meanwhile.
        selectedOwnersByDestination = selectedOwners

        guard let initialRecords = store.loadRecordsForMutation(),
              !initialRecords.contains(where: {
                  !$0.authorizationHeaders.isEmpty
              }) else {
            throw Self.checkpointPersistenceError()
        }
        let initialStaleRecords = Self.staleRecords(
            in: initialRecords,
            selectedOwners: selectedOwners
        )
        let initialStaleRecordIDs = Set(initialStaleRecords.map(\.id))
        // A duplicate record ID is ambiguous because the shipped safe-path
        // transform is not injective. Exclude ambiguous IDs so every task that
        // names one is cancelled fail-closed instead of choosing a record by
        // array order.
        let initialRecordGroups = Dictionary(grouping: initialRecords, by: \.id)
        let ambiguousRecordIDs = Set(initialRecordGroups.compactMap { id, records in
            records.count == 1 ? nil : id
        })
        let initialRecordsByID = initialRecordGroups.compactMapValues { records in
                records.count == 1 ? records[0] : nil
            }
        let (_, _, downloadTasks) = await session.tasks
        let staleTasks = downloadTasks.filter {
            Self.taskRequiresQuiescence(
                $0.taskDescription,
                taskIdentifier: $0.taskIdentifier,
                recordsByID: initialRecordsByID,
                selectedOwners: selectedOwners
            )
        }
        let validSelectedTaskIDs = Set(
            downloadTasks
                .filter { task in
                    !Self.taskRequiresQuiescence(
                        task.taskDescription,
                        taskIdentifier: task.taskIdentifier,
                        recordsByID: initialRecordsByID,
                        selectedOwners: selectedOwners
                    )
                }
                .map(\.taskIdentifier)
        )
        let excessSelectedTaskIDs = Self.excessSelectedTaskIdentifiers(
            downloadTasks.map {
                ArkFileBackgroundDownloadTaskIdentity(
                    taskIdentifier: $0.taskIdentifier,
                    recordID: $0.taskDescription
                )
            },
            validSelectedTaskIdentifiers: validSelectedTaskIDs,
            preferredRecordID: preferredRecordID
        )
        let hasUnmappedTask = staleTasks.contains { task in
            guard let recordID = task.taskDescription else { return true }
            return initialRecordsByID[recordID] == nil
        }
        // An unmapped task cannot prove which managed partial its callbacks
        // might target. Quiesce the entire content session before inspecting or
        // resetting any selected path; otherwise a legitimate selected task
        // could append concurrently after the reset decision.
        let tasksToQuiesce: [URLSessionDownloadTask]
        if hasUnmappedTask {
            tasksToQuiesce = downloadTasks
        } else {
            let taskIDs = Set(staleTasks.map(\.taskIdentifier))
                .union(excessSelectedTaskIDs)
            tasksToQuiesce = downloadTasks.filter {
                taskIDs.contains($0.taskIdentifier)
            }
        }
        let selectedRecordsPausedForSerialization = Set(
            tasksToQuiesce.compactMap { task -> String? in
                guard validSelectedTaskIDs.contains(task.taskIdentifier) else {
                    return nil
                }
                return task.taskDescription
            }
        )
        let staleTaskIDs = Set(tasksToQuiesce.map(\.taskIdentifier))

        // Tombstones and the delegate gate are synchronous. A callback already
        // postprocessing may finish, but the drain below waits for it before a
        // selected partial is verified, retained, or reset.
        discardedRecordIDs.formUnion(initialStaleRecordIDs)
        discardedRecordIDs.formUnion(ambiguousRecordIDs)
        discardedTaskIdentifiers.formUnion(staleTaskIDs)
        sessionDelegate.rejectCallbacks(for: staleTaskIDs)
        await cancelTasksForDiscard(tasksToQuiesce)
        await waitForDelegateQueueToDrain()
        await sessionDelegate.waitForPostprocessingToFinish()

        guard selectedOwnersByDestination == selectedOwners,
              let latestRecords = store.loadRecordsForMutation() else {
            throw Self.checkpointPersistenceError()
        }
        for recordID in selectedRecordsPausedForSerialization {
            guard var paused = latestRecords.first(where: { $0.id == recordID }) else {
                continue
            }
            if paused.activeRange != nil {
                let interruptedRecord = paused
                paused = try await Task.detached(priority: .utility) {
                    try Self.reconcileInterruptedAppend(record: interruptedRecord)
                }.value
            }
            if paused.phase != .finished {
                paused.phase = .paused
            }
            paused.sessionTaskIdentifier = nil
            paused.resumeData = nil
            guard store.save(paused) else {
                throw Self.checkpointPersistenceError()
            }
        }
        let latestStaleRecords = Self.staleRecords(
            in: latestRecords,
            selectedOwners: selectedOwners
        )
        let collidingStaleRecords = latestStaleRecords.filter {
            selectedOwners[Self.destinationPath(for: $0)] != nil
        }
        let staleDestinationPaths = Set<String>(
            initialStaleRecords.compactMap { record -> String? in
                let path = Self.destinationPath(for: record)
                guard let owner = selectedOwners[path],
                      Self.staleRecordRequiresPartialReset(
                        record,
                        selectedOwner: owner
                      ) else {
                    return nil
                }
                return path
            } + collidingStaleRecords.compactMap { record -> String? in
                let path = Self.destinationPath(for: record)
                guard let owner = selectedOwners[path],
                      Self.staleRecordRequiresPartialReset(
                        record,
                        selectedOwner: owner
                      ) else {
                    return nil
                }
                return path
            }
        )
        for destinationPath in staleDestinationPaths {
            guard let selectedEntry = selectedOwners[destinationPath]?.entry else { continue }
            _ = try await Task.detached(priority: .utility) {
                try Self.resetStalePartialIfNeeded(
                    selectedEntry: selectedEntry,
                    downloadRoot: downloadRoot
                )
            }.value
        }
        // An unknown URLSession task owns only its daemon temporary response;
        // ArkFile is the sole appender of deterministic partials. After every
        // task/callback is cancelled and drained, preserve safe unique regular
        // prefixes while unlinking symlinks, special files, incomplete hard
        // links, and invalid full-size bytes.
        for owner in selectedOwners.values {
            _ = try await Task.detached(priority: .utility) {
                try Self.sanitizeSelectedPartialIfNeeded(
                    selectedEntry: owner.entry,
                    downloadRoot: downloadRoot
                )
            }.value
        }

        let selectedRecordIDs = Set(selectedOwners.values.map(\.recordID))
        for record in latestStaleRecords {
            let collidesWithSelectedPartial = selectedOwners[
                Self.destinationPath(for: record)
            ] != nil
            let collidesWithSelectedRecordID = selectedRecordIDs.contains(record.id)
            if collidesWithSelectedPartial || collidesWithSelectedRecordID {
                guard removeRecord(id: record.id) else {
                    throw Self.checkpointPersistenceError()
                }
            } else {
                guard store.update(id: record.id, { paused in
                    paused.phase = .paused
                    paused.sessionTaskIdentifier = nil
                    paused.activeRangeStart = nil
                    paused.activeRangeEnd = nil
                    paused.resumeData = nil
                    paused.errorMessage = "Paused because a newer content selection owns background downloads."
                }) else {
                    throw Self.checkpointPersistenceError()
                }
            }
            completedTasksAwaitingFinish.remove(record.id)
            complete(recordID: record.id, result: .failure(CancellationError()))
        }
    }

    func download(
        manifest: ArkFilePackageManifest,
        entry: ArkFilePackageManifest.Entry,
        from sourceURL: URL,
        authorization: ArkFileContentAuthorization,
        to destination: URL,
        progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void
    ) async throws {
        let recordID = ArkFileContentBackgroundDownloadRecord.id(for: entry)
        let authorizationReference = recordID
        guard Self.isAuthorizedContentSourceURL(sourceURL) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused an untrusted content download URL."
            )
        }
        guard !isDiscardingAllDownloads else { throw CancellationError() }
        let downloadDiscardGeneration = discardGeneration
        let destinationPath = destination.fileSystemPath
        let downloadRoot = destination.deletingLastPathComponent()
        cancellationGeneration &+= 1
        isPauseAllRequested = false
        try await quiesceStaleDownloads(
            for: manifest,
            downloadRoot: downloadRoot,
            preferredRecordID: recordID
        )
        guard ownsSelectedDestination(
            recordID: recordID,
            entry: entry,
            destination: destination
        ) else {
            throw CancellationError()
        }
        discardedRecordIDs.remove(recordID)
        pausedRecordIDs.remove(recordID)
        if await Self.fileMatchesInBackground(destination, entry: entry) {
            guard ownsSelectedDestination(
                recordID: recordID,
                entry: entry,
                destination: destination
            ) else {
                throw CancellationError()
            }
            progress(entry.sizeBytes, entry.sizeBytes)
            removeRecord(id: recordID)
            return
        }
        if entry.sizeBytes == 0 {
            try Self.createEmptyDownloadFile(at: destination)
            try ArkFileContentFileVerifier.verifyFile(at: destination, entry: entry)
            progress(0, 0)
            removeRecord(id: recordID)
            return
        }
        guard authorizationStore.save(
            authorization.headers,
            reference: authorizationReference
        ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile could not securely save download access. Your existing downloaded and partial content was not changed."
            )
        }

        let activeTaskAtStart = await activeDownloadTask(recordID: recordID)
        guard discardGeneration == downloadDiscardGeneration,
              !isDiscardingAllDownloads,
              ownsSelectedDestination(recordID: recordID, entry: entry, destination: destination),
              !discardedRecordIDs.contains(recordID) else {
            throw CancellationError()
        }
        if activeTaskAtStart == nil,
           let interruptedRecord = store.record(id: recordID),
           interruptedRecord.activeRange != nil {
            let repairedRecord = try await Task.detached(priority: .utility) {
                try Self.reconcileInterruptedAppend(record: interruptedRecord)
            }.value
            guard store.save(repairedRecord) else {
                throw Self.checkpointPersistenceError()
            }
        }
        let record: ArkFileContentBackgroundDownloadRecord
        if activeTaskAtStart != nil,
           let storedRecord = store.record(id: recordID),
           Self.entriesHaveSameImmutableContent(storedRecord.entry, entry),
           storedRecord.destinationPath == destinationPath {
            record = storedRecord
        } else {
            let refreshedRecord = store.record(id: recordID)?.refreshedForRetry(
                manifest: manifest,
                entry: entry,
                sourceURL: sourceURL,
                destinationPath: destinationPath,
                authorizationHeaders: authorization.headers,
                allowsCellularDownload: authorization.allowsCellularDownload
            ) ??
                ArkFileContentBackgroundDownloadRecord(
                    id: recordID,
                    manifest: manifest,
                    entry: entry,
                    sourceURL: sourceURL,
                    destinationPath: destinationPath,
                    authorizationHeaders: authorization.headers,
                    authorizationReference: authorizationReference,
                    allowsCellularDownload: authorization.allowsCellularDownload,
                    phase: .scheduled,
                    completedBytes: 0,
                    expectedBytes: entry.sizeBytes,
                    resumeData: nil,
                    activeRangeStart: activeTaskAtStart.flatMap { Self.requestedRange(from: $0.originalRequest)?.lowerBound },
                    activeRangeEnd: activeTaskAtStart.flatMap { Self.requestedRange(from: $0.originalRequest)?.upperBound },
                    errorMessage: nil,
                    updatedAt: Date()
                )
            record = Self.reusesStoredResumeData
                ? refreshedRecord
                : refreshedRecord.discardingResumeDataForFreshRetry()
        }
        guard store.save(record) else {
            throw Self.checkpointPersistenceError()
        }
        rememberProgress(for: record)

        while true {
            try Task.checkCancellation()
            let reusableBytes = try await Self.prepareDestinationForRangeRetryInBackground(destination, entry: entry)
            guard discardGeneration == downloadDiscardGeneration,
                  !isDiscardingAllDownloads,
                  ownsSelectedDestination(recordID: recordID, entry: entry, destination: destination),
                  !discardedRecordIDs.contains(recordID) else {
                throw CancellationError()
            }
            if reusableBytes == entry.sizeBytes {
                progress(entry.sizeBytes, entry.sizeBytes)
                removeRecord(id: recordID)
                return
            }
            progress(reusableBytes, entry.sizeBytes)

            let task: URLSessionDownloadTask
            if let activeTask = await activeDownloadTask(recordID: recordID) {
                do {
                    try await Self.ensureEnoughStorageForRangeDownloadInBackground(
                        destination: destination,
                        incomingBytes: Self.remainingIncomingBytes(
                            for: activeTask,
                            entry: entry,
                            reusableBytes: reusableBytes
                        )
                    )
                } catch {
                    activeTask.cancel()
                    throw error
                }
                guard discardGeneration == downloadDiscardGeneration,
                      !isDiscardingAllDownloads,
                      ownsSelectedDestination(recordID: recordID, entry: entry, destination: destination),
                      !discardedRecordIDs.contains(recordID) else {
                    discardUncheckpointedTask(activeTask)
                    throw CancellationError()
                }
                task = activeTask
                guard store.update(id: recordID, { updated in
                    updated.sessionTaskIdentifier = activeTask.taskIdentifier
                }) else {
                    discardUncheckpointedTask(activeTask)
                    throw Self.checkpointPersistenceError()
                }
            } else {
                guard let range = Self.nextRange(startingAt: reusableBytes, totalBytes: entry.sizeBytes) else {
                    continue
                }
                try await Self.ensureEnoughStorageForRangeDownloadInBackground(
                    destination: destination,
                    incomingBytes: Self.byteCount(in: range)
                )
                guard discardGeneration == downloadDiscardGeneration,
                      !isDiscardingAllDownloads,
                      ownsSelectedDestination(recordID: recordID, entry: entry, destination: destination),
                      !discardedRecordIDs.contains(recordID) else {
                    throw CancellationError()
                }
                var scheduledRecord = record.refreshedForRetry(
                    manifest: manifest,
                    entry: entry,
                    sourceURL: sourceURL,
                    destinationPath: destinationPath,
                    authorizationHeaders: authorization.headers,
                    allowsCellularDownload: authorization.allowsCellularDownload
                )
                scheduledRecord.phase = .scheduled
                scheduledRecord.completedBytes = reusableBytes
                scheduledRecord.expectedBytes = entry.sizeBytes
                scheduledRecord.resumeData = nil
                scheduledRecord.activeRangeStart = range.lowerBound
                scheduledRecord.activeRangeEnd = range.upperBound
                scheduledRecord.errorMessage = nil

                task = makeDownloadTask(
                    for: scheduledRecord,
                    authorizationHeaders: authorization.headers
                )
                task.taskDescription = recordID
                task.countOfBytesClientExpectsToReceive = Self.byteCount(in: range)
                scheduledRecord.sessionTaskIdentifier = task.taskIdentifier
                guard store.save(scheduledRecord) else {
                    discardUncheckpointedTask(task)
                    throw Self.checkpointPersistenceError()
                }
                rememberProgress(for: scheduledRecord)
            }

            try await awaitDownloadTask(recordID: recordID, task: task, progress: progress)
        }
    }

    func cancelAll() {
        cancellationGeneration &+= 1
        isPauseAllRequested = true
        pendingResponseErrorsByTaskIdentifier.removeAll()
        let capturedCancellationGeneration = cancellationGeneration
        let records = store.loadRecordsForMutation() ?? []
        pausedRecordIDs.formUnion(records.map(\.id))
        let persistedTaskIdentifiers = Set(records.compactMap(\.sessionTaskIdentifier))
        discardedTaskIdentifiers.formUnion(persistedTaskIdentifiers)
        sessionDelegate.rejectCallbacks(for: persistedTaskIdentifiers)
        for record in records {
            _ = store.update(id: record.id) { updated in
                Self.pauseRecordForCancellation(&updated)
            }
        }
        completeAll(with: CancellationError())
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let service = self else { return }
            Task { @MainActor in
                let cancellationStillCurrent = service.cancellationGeneration
                    == capturedCancellationGeneration
                let taskIdentifiers = cancellationStillCurrent
                    ? Set(downloadTasks.map(\.taskIdentifier))
                    : persistedTaskIdentifiers
                service.discardedTaskIdentifiers.formUnion(taskIdentifiers)
                service.sessionDelegate.rejectCallbacks(for: taskIdentifiers)
                for task in downloadTasks where taskIdentifiers.contains(task.taskIdentifier) {
                    task.cancel()
                }
                // Completion is inventory-wide and cannot depend on any one
                // task callback (including tasks with nil descriptions).
                if cancellationStillCurrent {
                    service.completeAll(with: CancellationError())
                }
            }
        }
    }

    func cancel(recordID: String) {
        cancellationGeneration &+= 1
        let capturedCancellationGeneration = cancellationGeneration
        let persistedTaskIdentifier = store.record(id: recordID)?
            .sessionTaskIdentifier
        let capturedTaskIdentifiers = Set(
            [persistedTaskIdentifier, continuationTaskIdentifiers[recordID]]
                .compactMap { $0 }
        )
        pausedRecordIDs.insert(recordID)
        if let persistedTaskIdentifier {
            discardedTaskIdentifiers.insert(persistedTaskIdentifier)
            sessionDelegate.rejectCallbacks(for: [persistedTaskIdentifier])
        }
        _ = store.update(id: recordID) { updated in
            Self.pauseRecordForCancellation(&updated)
        }
        complete(recordID: recordID, result: .failure(CancellationError()))
        session.getTasksWithCompletionHandler { [weak self] _, _, downloadTasks in
            guard let service = self else { return }
            Task { @MainActor in
                let matchingTasks = downloadTasks.filter {
                    capturedTaskIdentifiers.contains($0.taskIdentifier)
                }
                let taskIdentifiers = capturedTaskIdentifiers
                service.discardedTaskIdentifiers.formUnion(taskIdentifiers)
                service.sessionDelegate.rejectCallbacks(for: taskIdentifiers)
                for task in matchingTasks {
                    task.cancel()
                }
                // The exact task may already have disappeared. Always unblock
                // the caller after the durable pause attempt.
                if service.cancellationGeneration == capturedCancellationGeneration,
                   service.pausedRecordIDs.contains(recordID) {
                    service.complete(
                        recordID: recordID,
                        result: .failure(CancellationError())
                    )
                }
            }
        }
    }

    nonisolated static func pauseRecordForCancellation(
        _ record: inout ArkFileContentBackgroundDownloadRecord
    ) {
        let hadActiveRange = record.activeRange != nil
        record.phase = .paused
        if !hadActiveRange {
            record.completedBytes = downloadedByteCount(
                at: record.destinationURL,
                entry: record.entry
            )
        }
        record.resumeData = nil
        record.sessionTaskIdentifier = nil
        if !hadActiveRange {
            record.activeRangeStart = nil
            record.activeRangeEnd = nil
        }
    }

    /// Cancels a single background transfer and discards only its managed
    /// partial file. Task identifiers are tombstoned so late URLSession
    /// delegate callbacks cannot append data after the user cancels.
    func cancelAndDiscard(recordID: String, expectedDownloadRoot: URL) async -> Bool {
        guard let managedDownloadRoot,
              Self.isExpectedManagedDownloadRoot(
                expectedDownloadRoot,
                expected: managedDownloadRoot
              ) else {
            return false
        }
        guard let record = store.record(id: recordID) else { return false }
        discardedRecordIDs.insert(recordID)
        let task = await activeDownloadTask(recordID: recordID)
        if let persistedTaskIdentifier = record.sessionTaskIdentifier {
            discardedTaskIdentifiers.insert(persistedTaskIdentifier)
            sessionDelegate.rejectCallbacks(for: [persistedTaskIdentifier])
        }
        if let task {
            discardedTaskIdentifiers.insert(task.taskIdentifier)
            sessionDelegate.rejectCallbacks(for: [task.taskIdentifier])
            await cancelTaskForDiscard(task)
        }
        await sessionDelegate.waitForPostprocessingToFinish()
        guard removeRecord(id: recordID) else { return false }
        completedTasksAwaitingFinish.remove(recordID)
        complete(recordID: recordID, result: .failure(CancellationError()))

        return await Task.detached(priority: .utility) {
            ArkFileContentDownloadPaths.removeManagedPartialDownload(
                record.destinationURL,
                in: expectedDownloadRoot
            )
        }.value
    }

    /// Quiesces every content-pack URLSession task before deleting any partial
    /// payload. Record and task tombstones are installed before the first
    /// suspension point so queued/late delegate callbacks can only clean their
    /// preserved handoff and can never append or recreate download bytes.
    func cancelAllAndDiscard(expectedDownloadRoot: URL) async -> Bool {
        guard let managedDownloadRoot,
              Self.isExpectedManagedDownloadRoot(
                expectedDownloadRoot,
                expected: managedDownloadRoot
              ) else {
            return false
        }
        guard !isDiscardingAllDownloads,
              let records = store.loadRecordsForMutation() else {
            return false
        }
        isDiscardingAllDownloads = true
        discardGeneration &+= 1
        sessionDelegate.beginRejectingAllCallbacks(
            taskIdentifiers: Set(records.compactMap(\.sessionTaskIdentifier))
        )
        defer {
            sessionDelegate.endRejectingAllCallbacks()
            isDiscardingAllDownloads = false
        }
        discardedRecordIDs.formUnion(records.map(\.id))
        discardedTaskIdentifiers.formUnion(records.compactMap(\.sessionTaskIdentifier))

        let (_, _, downloadTasks) = await session.tasks
        for task in downloadTasks {
            discardedTaskIdentifiers.insert(task.taskIdentifier)
            if let recordID = task.taskDescription {
                discardedRecordIDs.insert(recordID)
            }
        }
        sessionDelegate.rejectCallbacks(
            for: Set(downloadTasks.map(\.taskIdentifier))
        )
        await cancelTasksForDiscard(downloadTasks)

        await waitForDelegateQueueToDrain()
        await sessionDelegate.waitForPostprocessingToFinish()
        guard removeAllRecords(records: records) else {
            completeAll(with: CancellationError())
            return false
        }

        completedTasksAwaitingFinish.removeAll()
        activeProgressRecords.removeAll()
        completeAll(with: CancellationError())
        let removedAllPartials = await Task.detached(priority: .utility) {
            var removedEveryPartial = true
            for record in records {
                if !ArkFileContentDownloadPaths.removeManagedPartialDownload(
                    record.destinationURL,
                    in: expectedDownloadRoot
                ) {
                    removedEveryPartial = false
                }
            }
            return removedEveryPartial
        }.value
        return removedAllPartials
    }

    fileprivate func didWrite(
        taskIdentifier: Int,
        recordID: String,
        completedBytes: Int64,
        expectedBytes: Int64
    ) {
        guard !isPauseAllRequested,
              !pausedRecordIDs.contains(recordID) else { return }
        guard !shouldDiscardCallback(
            taskIdentifier: taskIdentifier,
            recordID: recordID
        ), recordHasExclusiveDestinationOwnership(
            recordID: recordID,
            taskIdentifier: taskIdentifier
        ) else {
            failClosedAfterDestinationOwnershipLoss(
                taskIdentifier: taskIdentifier,
                recordID: recordID
            )
            return
        }
        let progressRecord = activeProgressRecords[recordID]
        let fallbackExpectedBytes = expectedBytes > 0 ? expectedBytes : completedBytes
        let completedForWholeFile = min(
            progressRecord?.expectedBytes ?? fallbackExpectedBytes,
            max(0, (progressRecord?.activeRangeStart ?? 0) + completedBytes)
        )
        let expectedForWholeFile = progressRecord?.expectedBytes ?? fallbackExpectedBytes
        progressHandlers[recordID]?(completedForWholeFile, expectedForWholeFile)
    }

    fileprivate func didFinishDownloading(
        taskIdentifier: Int,
        recordID: String,
        requestedRange: ClosedRange<Int64>?,
        preservedDownloadURL: URL?,
        response: URLResponse?,
        preservationErrorMessage: String?
    ) async {
        defer { sessionDelegate.endPostprocessing() }
        var processedOutcome: ArkFileFinishedDownloadOutcome?
        guard !isPauseAllRequested,
              !pausedRecordIDs.contains(recordID),
              !shouldDiscardCallback(
            taskIdentifier: taskIdentifier,
            recordID: recordID
        ) else {
            Self.cleanupPreservedHandoff(preservedDownloadURL)
            return
        }
        guard recordHasExclusiveDestinationOwnership(
            recordID: recordID,
            taskIdentifier: taskIdentifier
        ) else {
            failClosedAfterDestinationOwnershipLoss(
                taskIdentifier: taskIdentifier,
                recordID: recordID
            )
            Self.cleanupPreservedHandoff(preservedDownloadURL)
            return
        }
        guard let record = store.record(id: recordID) else {
            Self.cleanupPreservedHandoff(preservedDownloadURL)
            return
        }
        do {
            if let preservationErrorMessage {
                throw ArkFileContentBackgroundDownloadError.failed(preservationErrorMessage)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ArkFileContentError.invalidResponse
            }
            guard let preservedDownloadURL else {
                throw ArkFileContentBackgroundDownloadError.failed(
                    "ArkFile could not preserve the completed download before iOS cleaned up its temporary file."
                )
            }
            if let confirmedRefund = Self.confirmedRefundError(
                response: httpResponse,
                responseBodyURL: preservedDownloadURL
            ) {
                throw confirmedRefund
            }

            // The task's request is the final authority for what bytes arrived.
            // A container-rebind may intentionally clear an inconsistent stale
            // journal range while that old nsurlsessiond task is finishing. A
            // restored task can occasionally expose neither request, so a valid
            // HTTP 206 Content-Range is the last safe source of range identity.
            let finishedRange = try Self.finishedResponseRange(
                requestedRange: requestedRange,
                persistedRange: record.activeRange,
                statusCode: httpResponse.statusCode,
                contentRangeHeader: httpResponse.value(forHTTPHeaderField: "Content-Range")
            )
            if let range = finishedRange {
                let outcome = try await Self.processFinishedRangeDownload(
                    record: record,
                    range: range,
                    preservedDownloadURL: preservedDownloadURL,
                    statusCode: httpResponse.statusCode,
                    contentRangeHeader: httpResponse.value(forHTTPHeaderField: "Content-Range")
                )
                try updateFinishedDownload(
                    recordID: recordID,
                    record: record,
                    outcome: outcome
                )
                processedOutcome = outcome
            } else {
                try await Self.processFinishedFullDownload(
                    record: record,
                    preservedDownloadURL: preservedDownloadURL,
                    statusCode: httpResponse.statusCode
                )
                try updateFinishedDownload(
                    recordID: recordID,
                    record: record,
                    outcome: .finished
                )
                processedOutcome = .finished
            }
            guard !shouldDiscardCallback(
                taskIdentifier: taskIdentifier,
                recordID: recordID
            ) else {
                Self.cleanupPreservedHandoff(preservedDownloadURL)
                return
            }
            if completedTasksAwaitingFinish.remove(recordID) != nil {
                if case .partial = processedOutcome,
                   continuations[recordID] == nil,
                   let updatedRecord = store.record(id: recordID),
                   Self.shouldAdmitColdSuccessor(
                        record: updatedRecord,
                        hasForegroundContinuation: false,
                        callback: .didFinish,
                        terminalCompletionAlreadyArrived: true
                   ) {
                    // didComplete arrived first and cannot schedule while the
                    // durable record still owns an active range. This is the
                    // one successor admission for that callback order.
                    scheduleNextChunkWithoutInstallLoop(recordID: recordID)
                }
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .success(())
                )
            }
        } catch {
            guard !shouldDiscardCallback(
                taskIdentifier: taskIdentifier,
                recordID: recordID
            ) else {
                Self.cleanupPreservedHandoff(preservedDownloadURL)
                return
            }
            let message = ArkFileBackgroundDownloadDiagnostics.message(for: error)
            let completionError: Error
            if let contentError = error as? ArkFileContentError,
               case .confirmedStoreKitRefund = contentError {
                pendingResponseErrorsByTaskIdentifier[taskIdentifier] = contentError
                completionError = contentError
            } else {
                completionError = ArkFileContentBackgroundDownloadError.failed(message)
            }
            let requiresReconciliation: Bool
            if case .requiresPartialReconciliation = error as? ArkFileContentBackgroundDownloadError {
                requiresReconciliation = true
            } else {
                requiresReconciliation = false
            }
            let persistedFailure = store.update(id: recordID) { updated in
                updated.phase = .failed
                if requiresReconciliation {
                    // Preserve the prior durable boundary and range marker. A
                    // later no-follow reconciliation will truncate or downgrade
                    // the uncertain suffix; never canonize observed bytes here.
                    updated.completedBytes = min(
                        max(0, updated.completedBytes),
                        updated.activeRange?.lowerBound ?? updated.completedBytes
                    )
                } else {
                    updated.completedBytes = Self.downloadedByteCount(
                        at: updated.destinationURL,
                        entry: updated.entry
                    )
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                }
                updated.errorMessage = message
            }
            if !persistedFailure {
                failClosedAfterCheckpointWriteFailure(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID
                )
            }
            Self.cleanupPreservedHandoff(preservedDownloadURL)
            let failureDisposition = Self.terminalFailureDisposition(
                terminalCompletionAlreadyArrived: completedTasksAwaitingFinish
                    .remove(recordID) != nil,
                hasForegroundContinuation: continuations[recordID] != nil
            )
            if failureDisposition.shouldNotifyNeedsAttention {
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "\(record.packName) download paused. Open ArkFile to continue.",
                    tier: record.contentTier
                )
            }
            if failureDisposition.shouldCompleteNow {
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .failure(completionError)
                )
            }
        }
    }

    nonisolated static func terminalFailureDisposition(
        terminalCompletionAlreadyArrived: Bool,
        hasForegroundContinuation: Bool
    ) -> (shouldCompleteNow: Bool, shouldNotifyNeedsAttention: Bool) {
        (
            shouldCompleteNow: terminalCompletionAlreadyArrived,
            shouldNotifyNeedsAttention: !hasForegroundContinuation
        )
    }

    nonisolated static func clearPendingResponseError(
        for taskIdentifier: Int,
        from errorsByTaskIdentifier: inout [Int: Error]
    ) {
        errorsByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }

    fileprivate func didComplete(taskIdentifier: Int, recordID: String, error: Error?) {
        if isPauseAllRequested || pausedRecordIDs.contains(recordID) {
            pendingResponseErrorsByTaskIdentifier.removeValue(
                forKey: taskIdentifier
            )
            completeCurrentTask(
                taskIdentifier: taskIdentifier,
                recordID: recordID,
                result: .failure(CancellationError())
            )
            return
        }
        if shouldDiscardCallback(taskIdentifier: taskIdentifier, recordID: recordID) {
            pendingResponseErrorsByTaskIdentifier.removeValue(
                forKey: taskIdentifier
            )
            if discardedRecordIDs.contains(recordID) {
                complete(recordID: recordID, result: .failure(CancellationError()))
            } else {
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .failure(CancellationError())
                )
            }
            return
        }
        if let records = store.loadRecordsForMutation(),
           let terminalRecord = records.first(where: { $0.id == recordID }),
           (terminalRecord.phase == .finished
                || terminalRecord.phase == .failed
                || (terminalRecord.phase == .scheduled
                    && terminalRecord.activeRange == nil)),
           Self.recordHasExclusiveTerminalDestinationOwnership(
                recordID: recordID,
                taskIdentifier: taskIdentifier,
                records: records,
                selectedOwners: selectedOwnersByDestination
           ) {
            switch terminalRecord.phase {
            case .finished:
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .success(())
                )
            case .failed:
                let message = terminalRecord.errorMessage
                    ?? "ArkFile \(terminalRecord.packName) background download did not finish cleanly."
                let responseError = pendingResponseErrorsByTaskIdentifier
                    .removeValue(forKey: taskIdentifier)
                    ?? ArkFileContentBackgroundDownloadError.failed(message)
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .failure(responseError)
                )
            case .scheduled:
                if Self.shouldAdmitColdSuccessor(
                    record: terminalRecord,
                    hasForegroundContinuation: continuations[recordID] != nil,
                    callback: .didComplete,
                    terminalCompletionAlreadyArrived: false
                ) {
                    scheduleNextChunkWithoutInstallLoop(recordID: recordID)
                }
                completeCurrentTask(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID,
                    result: .success(())
                )
            default:
                break
            }
            return
        }
        guard recordHasExclusiveDestinationOwnership(
            recordID: recordID,
            taskIdentifier: taskIdentifier
        ) else {
            failClosedAfterDestinationOwnershipLoss(
                taskIdentifier: taskIdentifier,
                recordID: recordID
            )
            return
        }
        if let error = error as NSError? {
            let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let message = ArkFileBackgroundDownloadDiagnostics.message(for: error)
            let isUserPaused = error.code == NSURLErrorCancelled
            let persistedFailure = store.update(id: recordID) { record in
                record.phase = isUserPaused ? .paused : .failed
                record.completedBytes = Self.downloadedByteCount(at: record.destinationURL, entry: record.entry)
                record.resumeData = isUserPaused && Self.reusesStoredResumeData ? resumeData : nil
                record.activeRangeStart = nil
                record.activeRangeEnd = nil
                record.errorMessage = message
            }
            if !persistedFailure {
                failClosedAfterCheckpointWriteFailure(
                    taskIdentifier: taskIdentifier,
                    recordID: recordID
                )
            }
            if continuations[recordID] == nil && !isUserPaused {
                let updatedRecord = store.record(id: recordID)
                let packName = updatedRecord?.packName ?? ArkFileContentPackDisplayName.name(for: nil)
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "\(packName) download paused. Open ArkFile to continue.",
                    tier: updatedRecord?.contentTier
                )
            }
            completeCurrentTask(
                taskIdentifier: taskIdentifier,
                recordID: recordID,
                result: .failure(ArkFileContentBackgroundDownloadError.failed(message))
            )
            return
        }

        guard store.record(id: recordID) != nil else {
            completeCurrentTask(
                taskIdentifier: taskIdentifier,
                recordID: recordID,
                result: .failure(ArkFileContentError.invalidResponse)
            )
            return
        }
        completedTasksAwaitingFinish.insert(recordID)
    }

    fileprivate func finishBackgroundEvents() {
        sessionDelegate.finishBackgroundEvents()
        backgroundCompletionHandler = nil
    }

    nonisolated static func hasPersistedTaskCheckpoint(
        store: ArkFileContentBackgroundDownloadRecordStore,
        recordID: String,
        taskIdentifier: Int
    ) -> Bool {
        guard let record = store.record(id: recordID) else { return false }
        return record.sessionTaskIdentifier == taskIdentifier
            && (record.phase == .scheduled || record.phase == .downloading)
    }

    nonisolated static func shouldDiscardCallback(
        taskIdentifier: Int,
        recordID: String,
        discardedTaskIdentifiers: Set<Int>,
        discardedRecordIDs: Set<String>,
        isDiscardingAllDownloads: Bool
    ) -> Bool {
        isDiscardingAllDownloads
            || discardedTaskIdentifiers.contains(taskIdentifier)
            || discardedRecordIDs.contains(recordID)
    }

    nonisolated static func shouldCancelUnmappedTaskDescription(
        _ taskDescription: String?
    ) -> Bool {
        taskDescription?.isEmpty != false
    }

    nonisolated static func isAuthorizedContentSourceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        #if DEBUG
        if ArkFileContentAPI.usesRelaxedDebugNetworking(host: host) {
            return scheme == "http" || scheme == "https"
        }
        #endif
        return scheme == "https"
            && ArkFileContentAPI.isAllowed(host: host)
            && url.path == "/api/content/v1/package-file"
    }

    nonisolated static func authorizedRedirectRequest(
        from originalURL: URL?,
        to proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let originalURL,
              let proposedURL = proposedRequest.url,
              isAuthorizedContentSourceURL(originalURL),
              isAuthorizedContentSourceURL(proposedURL),
              originalURL.scheme?.lowercased() == proposedURL.scheme?.lowercased(),
              originalURL.host?.lowercased() == proposedURL.host?.lowercased(),
              originalURL.port == proposedURL.port else {
            return nil
        }
        return proposedRequest
    }

    nonisolated static func shouldRetryColdSchedulingAfterTerminalCompletion(
        record: ArkFileContentBackgroundDownloadRecord,
        hasForegroundContinuation: Bool
    ) -> Bool {
        !hasForegroundContinuation
            && record.phase == .scheduled
            && record.activeRange == nil
            && record.completedBytes < record.entry.sizeBytes
    }

    nonisolated static func shouldAdmitColdSuccessor(
        record: ArkFileContentBackgroundDownloadRecord,
        hasForegroundContinuation: Bool,
        callback: ArkFileBackgroundTerminalSchedulingCallback,
        terminalCompletionAlreadyArrived: Bool
    ) -> Bool {
        guard shouldRetryColdSchedulingAfterTerminalCompletion(
            record: record,
            hasForegroundContinuation: hasForegroundContinuation
        ) else {
            return false
        }
        switch callback {
        case .didFinish:
            return terminalCompletionAlreadyArrived
        case .didComplete:
            return !terminalCompletionAlreadyArrived
        }
    }

    nonisolated static func cleanupPreservedHandoff(_ url: URL?) {
        ArkFileBackgroundDownloadTemporaryFileHandoff.cleanup(url)
    }

    private nonisolated static func checkpointPersistenceError() -> Error {
        ArkFileContentBackgroundDownloadError.failed(
            "ArkFile could not durably save the background download checkpoint. Your existing downloaded and partial content was not changed."
        )
    }

    private func discardUncheckpointedTask(_ task: URLSessionDownloadTask) {
        discardedTaskIdentifiers.insert(task.taskIdentifier)
        sessionDelegate.rejectCallbacks(for: [task.taskIdentifier])
        task.cancel()
    }

    private func failClosedAfterCheckpointWriteFailure(
        taskIdentifier: Int,
        recordID: String
    ) {
        discardedTaskIdentifiers.insert(taskIdentifier)
        discardedRecordIDs.insert(recordID)
        sessionDelegate.rejectCallbacks(for: [taskIdentifier])
    }

    private func failClosedAfterDestinationOwnershipLoss(
        taskIdentifier: Int,
        recordID: String
    ) {
        discardedTaskIdentifiers.insert(taskIdentifier)
        sessionDelegate.rejectCallbacks(for: [taskIdentifier])
        let matchesAwaitedTask = continuationTaskIdentifiers[recordID] == taskIdentifier
        let matchesDurableTask = store.record(id: recordID)?.sessionTaskIdentifier
            == taskIdentifier
        if matchesDurableTask {
            discardedRecordIDs.insert(recordID)
            _ = store.update(id: recordID) { record in
                record.phase = .paused
                record.sessionTaskIdentifier = nil
                record.activeRangeStart = nil
                record.activeRangeEnd = nil
                record.resumeData = nil
                record.errorMessage = "Paused because this task no longer owns its managed partial."
            }
        }
        if matchesAwaitedTask || matchesDurableTask {
            complete(recordID: recordID, result: .failure(CancellationError()))
        }
        session.getTasksWithCompletionHandler { _, _, downloadTasks in
            downloadTasks.first(where: {
                $0.taskIdentifier == taskIdentifier
            })?.cancel()
        }
    }

    private func shouldDiscardCallback(taskIdentifier: Int, recordID: String) -> Bool {
        Self.shouldDiscardCallback(
            taskIdentifier: taskIdentifier,
            recordID: recordID,
            discardedTaskIdentifiers: discardedTaskIdentifiers,
            discardedRecordIDs: discardedRecordIDs,
            isDiscardingAllDownloads: isDiscardingAllDownloads
        )
    }

    private func awaitDownloadTask(
        recordID: String,
        task: URLSessionDownloadTask,
        progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void
    ) async throws {
        if let record = store.record(id: recordID),
           record.phase == .finished {
            return
        }
        guard Self.hasPersistedTaskCheckpoint(
            store: store,
            recordID: recordID,
            taskIdentifier: task.taskIdentifier
        ), !shouldDiscardCallback(
            taskIdentifier: task.taskIdentifier,
            recordID: recordID
        ) else {
            discardUncheckpointedTask(task)
            if isDiscardingAllDownloads || discardedRecordIDs.contains(recordID) {
                throw CancellationError()
            }
            throw Self.checkpointPersistenceError()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations[recordID] = continuation
                continuationTaskIdentifiers[recordID] = task.taskIdentifier
                progressHandlers[recordID] = progress
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(recordID: recordID)
            }
        }
    }

    private func updateFinishedDownload(
        recordID: String,
        record: ArkFileContentBackgroundDownloadRecord,
        outcome: ArkFileFinishedDownloadOutcome
    ) throws {
        if isPauseAllRequested || pausedRecordIDs.contains(recordID) {
            guard store.update(id: recordID, { updated in
                switch outcome {
                case .finished:
                    updated.phase = .finished
                    updated.completedBytes = updated.entry.sizeBytes
                case .partial(let completedBytes):
                    updated.phase = .paused
                    updated.completedBytes = completedBytes
                }
                updated.expectedBytes = updated.entry.sizeBytes
                updated.resumeData = nil
                updated.sessionTaskIdentifier = nil
                updated.activeRangeStart = nil
                updated.activeRangeEnd = nil
                updated.errorMessage = nil
            }) else { throw Self.checkpointPersistenceError() }
            return
        }
        switch outcome {
        case .finished:
            activeProgressRecords.removeValue(forKey: recordID)
            guard store.update(id: recordID, { updated in
                updated.phase = .finished
                updated.completedBytes = updated.entry.sizeBytes
                updated.expectedBytes = updated.entry.sizeBytes
                updated.resumeData = nil
                updated.activeRangeStart = nil
                updated.activeRangeEnd = nil
                updated.errorMessage = nil
            }) else { throw Self.checkpointPersistenceError() }
            authorizationStore.delete(reference: record.authorizationReference ?? recordID)
            progressHandlers[recordID]?(record.entry.sizeBytes, record.entry.sizeBytes)
            if continuations[recordID] == nil {
                // The install loop is gone (iOS relaunched us in the background just for
                // session events), so the user must reopen ArkFile to keep installing.
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "A file finished downloading. Open ArkFile to continue installing \(record.packName).",
                    tier: record.contentTier
                )
            }
        case .partial(let completedBytes):
            guard store.update(id: recordID, { updated in
                updated.phase = .scheduled
                updated.completedBytes = completedBytes
                updated.expectedBytes = updated.entry.sizeBytes
                updated.resumeData = nil
                updated.activeRangeStart = nil
                updated.activeRangeEnd = nil
                updated.errorMessage = nil
            }) else { throw Self.checkpointPersistenceError() }
            progressHandlers[recordID]?(completedBytes, record.entry.sizeBytes)
            // didComplete is the single cold-scheduling admission point. It
            // runs after URLSession has retired this task, preventing both a
            // stale-inventory stall and two terminal callbacks racing to create
            // duplicate successor tasks.
        }
    }

    /// Continues a multi-chunk file download when the orchestrating install loop no
    /// longer exists in this process. Without this, iOS terminating the app mid-pack
    /// silently stalls the download until the user happens to reopen ArkFile.
    private func scheduleNextChunkWithoutInstallLoop(recordID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let scheduleDiscardGeneration = self.discardGeneration
            guard !self.isDiscardingAllDownloads,
                  !self.isPauseAllRequested,
                  !self.isReconcilingSelectedManifest,
                  !self.discardedRecordIDs.contains(recordID),
                  !self.pausedRecordIDs.contains(recordID),
                  self.continuations[recordID] == nil,
                  let storedRecord = self.store.record(id: recordID),
                  self.recordHasExclusiveDestinationOwnership(recordID: recordID),
                  storedRecord.phase == .scheduled else {
                return
            }
            guard await self.activeDownloadTask(recordID: recordID) == nil else {
                return
            }
            var record = storedRecord
            if record.activeRange != nil {
                guard let repaired = try? Self.reconcileInterruptedAppend(
                    record: record
                ),
                self.store.save(repaired) else {
                    return
                }
                record = repaired
            }
            guard scheduleDiscardGeneration == self.discardGeneration,
                  !self.isDiscardingAllDownloads,
                  !self.isReconcilingSelectedManifest,
                  self.recordHasExclusiveDestinationOwnership(recordID: recordID),
                  !self.discardedRecordIDs.contains(recordID) else {
                return
            }
            guard let durableCompletedBytes = Self.coldSchedulerPartialByteCount(
                at: record.destinationURL,
                entry: record.entry
            ) else {
                self.store.update(id: recordID) { updated in
                    updated.phase = .failed
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                    updated.errorMessage = "Open ArkFile to verify an inconsistent partial download."
                }
                return
            }
            if durableCompletedBytes == record.entry.sizeBytes {
                guard await Self.fileMatchesInBackground(
                    record.destinationURL,
                    entry: record.entry
                ) else {
                    self.store.update(id: recordID) { updated in
                        updated.phase = .failed
                        updated.completedBytes = 0
                        updated.activeRangeStart = nil
                        updated.activeRangeEnd = nil
                        updated.errorMessage = "Open ArkFile to verify a completed partial download."
                    }
                    return
                }
                guard scheduleDiscardGeneration == self.discardGeneration,
                      !self.isDiscardingAllDownloads,
                      !self.isReconcilingSelectedManifest,
                      self.recordHasExclusiveDestinationOwnership(recordID: recordID),
                      !self.discardedRecordIDs.contains(recordID) else {
                    return
                }
                guard self.store.update(id: recordID, { updated in
                    updated.phase = .finished
                    updated.completedBytes = updated.entry.sizeBytes
                    updated.expectedBytes = updated.entry.sizeBytes
                    updated.sessionTaskIdentifier = nil
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                    updated.errorMessage = nil
                }) else { return }
                self.authorizationStore.delete(
                    reference: record.authorizationReference ?? recordID
                )
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "A file finished downloading. Open ArkFile to continue installing \(record.packName).",
                    tier: record.contentTier
                )
                return
            }
            guard let range = Self.nextRange(
                startingAt: durableCompletedBytes,
                totalBytes: record.entry.sizeBytes
            ) else { return }
            do {
                try await Self.ensureEnoughStorageForRangeDownloadInBackground(
                    destination: record.destinationURL,
                    incomingBytes: Self.byteCount(in: range)
                )
            } catch {
                let message = ArkFileBackgroundDownloadDiagnostics.message(for: error)
                self.store.update(id: recordID) { updated in
                    updated.phase = .failed
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                    updated.errorMessage = message
                }
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "\(record.packName) download paused: not enough free storage. Open ArkFile to review.",
                    tier: record.contentTier
                )
                return
            }
            guard scheduleDiscardGeneration == self.discardGeneration,
                  !self.isDiscardingAllDownloads,
                  !self.isReconcilingSelectedManifest,
                  self.recordHasExclusiveDestinationOwnership(recordID: recordID),
                  !self.discardedRecordIDs.contains(recordID) else {
                return
            }
            guard Self.coldSchedulerPartialByteCount(
                at: record.destinationURL,
                entry: record.entry
            ) == durableCompletedBytes else {
                return
            }
            var next = record
            next.phase = .scheduled
            next.completedBytes = durableCompletedBytes
            next.expectedBytes = record.entry.sizeBytes
            next.resumeData = nil
            next.activeRangeStart = range.lowerBound
            next.activeRangeEnd = range.upperBound
            next.errorMessage = nil
            next.updatedAt = Date()
            guard Self.isAuthorizedContentSourceURL(next.sourceURL) else {
                self.store.update(id: recordID) { updated in
                    updated.phase = .paused
                    updated.sessionTaskIdentifier = nil
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                    updated.errorMessage = "Open ArkFile to renew a trusted content download URL."
                }
                return
            }
            guard let authorizationHeaders = self.authorizationStore.headers(
                reference: next.authorizationReference ?? recordID
            ) else {
                self.store.update(id: recordID) { updated in
                    updated.phase = .paused
                    updated.activeRangeStart = nil
                    updated.activeRangeEnd = nil
                    updated.errorMessage = "Open ArkFile to renew download access."
                }
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "\(record.packName) download paused. Open ArkFile to continue.",
                    tier: record.contentTier
                )
                return
            }
            let task = self.makeDownloadTask(
                for: next,
                authorizationHeaders: authorizationHeaders
            )
            task.taskDescription = recordID
            task.countOfBytesClientExpectsToReceive = Self.byteCount(in: range)
            next.sessionTaskIdentifier = task.taskIdentifier
            guard self.store.save(next),
                  Self.hasPersistedTaskCheckpoint(
                    store: self.store,
                    recordID: recordID,
                    taskIdentifier: task.taskIdentifier
                  ) else {
                self.discardUncheckpointedTask(task)
                ArkFileEssentialsDownloadNotifier.notifyDownloadNeedsAttention(
                    "\(record.packName) download paused because ArkFile could not save its background checkpoint. Open ArkFile to continue.",
                    tier: record.contentTier
                )
                return
            }
            self.rememberProgress(for: next)
            task.resume()
            Log.ContentPack.info(
                "Scheduled next \(record.packName, privacy: .public) chunk from background relaunch: \(recordID, privacy: .public)"
            )
        }
    }

    private func makeDownloadTask(
        for record: ArkFileContentBackgroundDownloadRecord,
        authorizationHeaders: [String: String]
    ) -> URLSessionDownloadTask {
        if Self.reusesStoredResumeData, let resumeData = record.resumeData {
            return session.downloadTask(withResumeData: resumeData)
        }
        return session.downloadTask(
            with: record.request(authorizationHeaders: authorizationHeaders)
        )
    }

    @discardableResult
    private func removeRecord(id: String) -> Bool {
        Self.removeRecordDurably(
            store: store,
            authorizationStore: authorizationStore,
            id: id
        )
    }

    @discardableResult
    private func removeAllRecords(
        records: [ArkFileContentBackgroundDownloadRecord]? = nil
    ) -> Bool {
        Self.removeAllRecordsDurably(
            store: store,
            authorizationStore: authorizationStore,
            knownRecords: records
        )
    }

    nonisolated static func removeRecordDurably(
        store: ArkFileContentBackgroundDownloadRecordStore,
        authorizationStore: ArkFileContentBackgroundAuthorizationStore,
        id: String
    ) -> Bool {
        guard let records = store.loadRecordsForMutation() else { return false }
        let reference = records.first(where: { $0.id == id })?.authorizationReference ?? id
        guard store.remove(id: id) else { return false }
        authorizationStore.delete(reference: reference)
        return true
    }

    nonisolated static func removeAllRecordsDurably(
        store: ArkFileContentBackgroundDownloadRecordStore,
        authorizationStore: ArkFileContentBackgroundAuthorizationStore,
        knownRecords: [ArkFileContentBackgroundDownloadRecord]? = nil
    ) -> Bool {
        guard let currentRecords = store.loadRecordsForMutation() else { return false }
        let records = (knownRecords ?? []) + currentRecords
        let references = Set(records.map { $0.authorizationReference ?? $0.id })
        guard store.removeAll() else { return false }
        for reference in references {
            authorizationStore.delete(reference: reference)
        }
        return true
    }

    private func rememberProgress(for record: ArkFileContentBackgroundDownloadRecord) {
        activeProgressRecords[record.id] = ActiveDownloadProgress(
            activeRangeStart: record.activeRangeStart ?? 0,
            expectedBytes: record.entry.sizeBytes
        )
    }

    private func beginManifestReconciliation() async {
        while isReconcilingSelectedManifest {
            await withCheckedContinuation { continuation in
                manifestReconciliationWaiters.append(continuation)
            }
        }
        isReconcilingSelectedManifest = true
    }

    private func endManifestReconciliation() {
        isReconcilingSelectedManifest = false
        guard !manifestReconciliationWaiters.isEmpty else { return }
        manifestReconciliationWaiters.removeFirst().resume()
    }

    private func ownsSelectedDestination(
        recordID: String,
        entry: ArkFilePackageManifest.Entry,
        destination: URL
    ) -> Bool {
        guard let owner = selectedOwnersByDestination[
            destination.standardizedFileURL.fileSystemPath
        ] else { return false }
        return Self.selectedOwner(
            owner,
            matchesRecordID: recordID,
            entry: entry
        )
    }

    nonisolated static func destinationPath(
        for entry: ArkFilePackageManifest.Entry,
        downloadRoot: URL
    ) -> String {
        ArkFileContentDownloadPaths.partialDownloadURL(
            for: entry,
            in: downloadRoot
        ).standardizedFileURL.fileSystemPath
    }

    nonisolated static func destinationPath(
        for record: ArkFileContentBackgroundDownloadRecord
    ) -> String {
        record.destinationURL.standardizedFileURL.fileSystemPath
    }

    nonisolated static func selectedRecordOwners(
        for manifest: ArkFilePackageManifest,
        downloadRoot: URL
    ) -> [String: ArkFileContentBackgroundSelectedOwner]? {
        var owners = [String: ArkFileContentBackgroundSelectedOwner]()
        var recordIDs = Set<String>()
        for entry in manifest.files {
            let destinationPath = destinationPath(
                for: entry,
                downloadRoot: downloadRoot
            )
            let recordID = ArkFileContentBackgroundDownloadRecord.id(for: entry)
            guard owners[destinationPath] == nil,
                  recordIDs.insert(recordID).inserted else {
                return nil
            }
            owners[destinationPath] = ArkFileContentBackgroundSelectedOwner(
                recordID: recordID,
                entry: entry
            )
        }
        return owners
    }

    /// Recovers selected ownership during an iOS background relaunch, before a
    /// foreground manifest request can run. Only scheduled/downloading records
    /// participate. They must all embed the same validated manifest, match an
    /// exact entry in it, and have unique IDs and canonical destinations after
    /// container rebinding. Any ambiguity returns `nil` and therefore keeps
    /// callbacks and background auto-scheduling fail-closed.
    nonisolated static func selectedRecordOwnersForActiveRecords(
        _ records: [ArkFileContentBackgroundDownloadRecord],
        downloadRoot: URL
    ) -> [String: ArkFileContentBackgroundSelectedOwner]? {
        guard Set(records.map(\.id)).count == records.count else { return nil }
        let activeRecords = records.filter {
            $0.phase == .scheduled || $0.phase == .downloading
        }
        guard let firstRecord = activeRecords.first,
              let tier = ArkFileContentTier.iOSInstallableTier(
                  named: firstRecord.manifest.tier
              ),
              (try? firstRecord.manifest.validateForInstall(tier: tier)) != nil,
              let owners = selectedRecordOwners(
                  for: firstRecord.manifest,
                  downloadRoot: downloadRoot
              ),
              !owners.isEmpty else {
            return nil
        }

        var activeRecordIDs = Set<String>()
        var activeDestinationPaths = Set<String>()
        for record in activeRecords {
            guard selectedRecordOwners(
                for: record.manifest,
                downloadRoot: downloadRoot
            ) == owners,
            record.id == ArkFileContentBackgroundDownloadRecord.id(for: record.entry) else {
                return nil
            }
            let destination = destinationPath(for: record)
            guard activeRecordIDs.insert(record.id).inserted,
                  activeDestinationPaths.insert(destination).inserted,
                  owners[destination].map({
                      selectedOwner(
                          $0,
                          matchesRecordID: record.id,
                          entry: record.entry
                      )
                  }) == true else {
                return nil
            }
        }
        return owners
    }

    nonisolated static func entriesHaveSameImmutableContent(
        _ lhs: ArkFilePackageManifest.Entry,
        _ rhs: ArkFilePackageManifest.Entry
    ) -> Bool {
        lhs.sizeBytes == rhs.sizeBytes
            && lhs.sha256.lowercased() == rhs.sha256.lowercased()
    }

    private nonisolated static func selectedOwner(
        _ owner: ArkFileContentBackgroundSelectedOwner,
        matchesRecordID recordID: String,
        entry: ArkFilePackageManifest.Entry
    ) -> Bool {
        owner.recordID == recordID
            && entriesHaveSameImmutableContent(owner.entry, entry)
    }

    nonisolated static func staleRecords(
        in records: [ArkFileContentBackgroundDownloadRecord],
        selectedOwners: [String: ArkFileContentBackgroundSelectedOwner]
    ) -> [ArkFileContentBackgroundDownloadRecord] {
        records.filter { record in
            guard let owner = selectedOwners[destinationPath(for: record)] else {
                return true
            }
            return !selectedOwner(
                owner,
                matchesRecordID: record.id,
                entry: record.entry
            )
        }
    }

    nonisolated static func staleRecordRequiresPartialReset(
        _ record: ArkFileContentBackgroundDownloadRecord,
        selectedOwner: ArkFileContentBackgroundSelectedOwner
    ) -> Bool {
        !entriesHaveSameImmutableContent(selectedOwner.entry, record.entry)
    }

    /// A task without one exact durable record cannot prove which partial it
    /// owns and is cancelled fail-closed. The selected manifest exclusively
    /// owns managed background activity, so even a known task for an unselected
    /// partial is quiesced and left paused rather than auto-scheduled.
    nonisolated static func taskRequiresQuiescence(
        _ taskDescription: String?,
        taskIdentifier: Int,
        recordsByID: [String: ArkFileContentBackgroundDownloadRecord],
        selectedOwners: [String: ArkFileContentBackgroundSelectedOwner]
    ) -> Bool {
        guard let taskDescription,
              let record = recordsByID[taskDescription],
              record.id == taskDescription,
              record.sessionTaskIdentifier == taskIdentifier,
              (record.phase == .scheduled || record.phase == .downloading) else {
            return true
        }
        guard let owner = selectedOwners[destinationPath(for: record)] else {
            return true
        }
        return !selectedOwner(
            owner,
            matchesRecordID: record.id,
            entry: record.entry
        )
    }

    /// Storage admission reserves one transient range. Keep at most one exact
    /// selected content-pack task alive; pause every other task without deleting
    /// its durable partial. Foreground work may prefer the record it is about to
    /// await, while startup preflight deterministically keeps the lowest task ID.
    nonisolated static func excessSelectedTaskIdentifiers(
        _ tasks: [ArkFileBackgroundDownloadTaskIdentity],
        validSelectedTaskIdentifiers: Set<Int>,
        preferredRecordID: String?
    ) -> Set<Int> {
        let validTasks = tasks
            .filter { validSelectedTaskIdentifiers.contains($0.taskIdentifier) }
            .sorted { lhs, rhs in
                let lhsPreferred = preferredRecordID != nil
                    && lhs.recordID == preferredRecordID
                let rhsPreferred = preferredRecordID != nil
                    && rhs.recordID == preferredRecordID
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                return lhs.taskIdentifier < rhs.taskIdentifier
            }
        return Set(validTasks.dropFirst().map(\.taskIdentifier))
    }

    nonisolated static func recordHasExclusiveDestinationOwnership(
        recordID: String,
        taskIdentifier: Int? = nil,
        records: [ArkFileContentBackgroundDownloadRecord],
        selectedOwners: [String: ArkFileContentBackgroundSelectedOwner]
    ) -> Bool {
        guard Set(records.map(\.id)).count == records.count else { return false }
        let activeRecords = records.filter {
            $0.phase == .scheduled || $0.phase == .downloading
        }
        let matchingRecords = activeRecords.filter { $0.id == recordID }
        guard matchingRecords.count == 1,
              let record = matchingRecords.first else {
            return false
        }
        let path = destinationPath(for: record)
        guard activeRecords.filter({ destinationPath(for: $0) == path }).count == 1 else {
            return false
        }
        guard let owner = selectedOwners[path],
              selectedOwner(
                  owner,
                  matchesRecordID: recordID,
                  entry: record.entry
              ) else {
            return false
        }
        if let taskIdentifier {
            guard record.sessionTaskIdentifier == taskIdentifier,
                  (record.phase == .scheduled || record.phase == .downloading) else {
                return false
            }
        }
        return true
    }

    /// Terminal didFinish state is no longer `downloading`, but the exact
    /// checkpointed task still needs authority to report success/failure (or
    /// retry a cold next range) when didComplete arrives second.
    nonisolated static func recordHasExclusiveTerminalDestinationOwnership(
        recordID: String,
        taskIdentifier: Int,
        records: [ArkFileContentBackgroundDownloadRecord],
        selectedOwners: [String: ArkFileContentBackgroundSelectedOwner]
    ) -> Bool {
        guard Set(records.map(\.id)).count == records.count else { return false }
        let matchingRecords = records.filter { $0.id == recordID }
        guard matchingRecords.count == 1,
              let record = matchingRecords.first,
              record.sessionTaskIdentifier == taskIdentifier else {
            return false
        }
        let path = destinationPath(for: record)
        let competingRecords = records.filter {
            ($0.phase == .scheduled || $0.phase == .downloading || $0.id == recordID)
                && destinationPath(for: $0) == path
        }
        guard competingRecords.count == 1,
              let owner = selectedOwners[path] else {
            return false
        }
        return selectedOwner(owner, matchesRecordID: recordID, entry: record.entry)
    }

    private func recordHasExclusiveDestinationOwnership(
        recordID: String,
        taskIdentifier: Int? = nil
    ) -> Bool {
        guard let records = store.loadRecordsForMutation() else { return false }
        return Self.recordHasExclusiveDestinationOwnership(
            recordID: recordID,
            taskIdentifier: taskIdentifier,
            records: records,
            selectedOwners: selectedOwnersByDestination
        )
    }

    /// Returns true only when an already-complete partial exactly matches the
    /// newly selected entry. An unverifiable prefix from a different manifest
    /// cannot be safely reused and is removed only from the managed Downloads
    /// root. Installed content is never a possible target.
    @discardableResult
    nonisolated static func resetStalePartialIfNeeded(
        selectedEntry: ArkFilePackageManifest.Entry,
        downloadRoot: URL
    ) throws -> Bool {
        let destination = ArkFileContentDownloadPaths.partialDownloadURL(
            for: selectedEntry,
            in: downloadRoot
        )
        guard destination.pathExtension == "arkdownload",
              ArkFileContentDownloadPaths.isManagedPartialDownloadURL(
                destination,
                in: downloadRoot
              ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused an unsafe stale partial-download path."
            )
        }
        if case .missing = try ArkFileManagedPartialFile.classify(destination) {
            return false
        }
        if case .regular(let size, _) = try ArkFileManagedPartialFile.classify(destination),
           size == selectedEntry.sizeBytes {
            switch ArkFileManagedPartialFile.verificationOutcome(
                at: destination,
                entry: selectedEntry
            ) {
            case .matches:
                return true
            case .definitiveMismatch:
                break
            case .unavailable(let error):
                throw error
            }
        }
        guard ArkFileContentDownloadPaths.removeManagedPartialDownload(
            destination,
            in: downloadRoot
        ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile could not safely reset a stale partial download."
            )
        }
        return false
    }

    /// Applies no-follow safety without treating an unknown daemon task as
    /// evidence that a valid multi-gigabyte prefix belongs to different bytes.
    /// Integrity is still protected by exact response ranges and final SHA-256.
    @discardableResult
    nonisolated static func sanitizeSelectedPartialIfNeeded(
        selectedEntry: ArkFilePackageManifest.Entry,
        downloadRoot: URL
    ) throws -> Bool {
        let destination = ArkFileContentDownloadPaths.partialDownloadURL(
            for: selectedEntry,
            in: downloadRoot
        )
        guard destination.pathExtension == "arkdownload",
              ArkFileContentDownloadPaths.isManagedPartialDownloadURL(
                destination,
                in: downloadRoot
              ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused an unsafe selected partial-download path."
            )
        }
        switch try ArkFileManagedPartialFile.classify(destination) {
        case .missing:
            return false
        case .regular(let size, let linkCount)
            where linkCount == 1 && size > 0 && size < selectedEntry.sizeBytes:
            return true
        case .regular(let size, _) where size == selectedEntry.sizeBytes:
            switch ArkFileManagedPartialFile.verificationOutcome(
                at: destination,
                entry: selectedEntry
            ) {
            case .matches:
                return true
            case .definitiveMismatch:
                break
            case .unavailable(let error):
                throw error
            }
        default:
            break
        }
        guard ArkFileContentDownloadPaths.removeManagedPartialDownload(
            destination,
            in: downloadRoot
        ) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile could not safely remove an aliased or invalid partial download."
            )
        }
        return false
    }

    private nonisolated static func isDefinitiveNoSuchFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError)
    }

    private func activeDownloadTask(recordID: String) async -> URLSessionDownloadTask? {
        guard let records = store.loadRecordsForMutation() else { return nil }
        let matchingRecords = records.filter { $0.id == recordID }
        guard matchingRecords.count == 1,
              let record = matchingRecords.first,
              let checkpointedTaskIdentifier = record.sessionTaskIdentifier,
              record.phase == .scheduled || record.phase == .downloading else {
            return nil
        }
        let (_, _, downloadTasks) = await session.tasks
        let checkpointedTasks = downloadTasks.filter {
            $0.taskDescription == recordID
                && $0.taskIdentifier == checkpointedTaskIdentifier
                && !discardedTaskIdentifiers.contains($0.taskIdentifier)
        }
        return checkpointedTasks.count == 1 ? checkpointedTasks[0] : nil
    }

    private func cancelTaskForDiscard(_ task: URLSessionDownloadTask) async {
        await withCheckedContinuation { continuation in
            task.cancel { _ in
                continuation.resume()
            }
        }
    }

    private func cancelTasksForDiscard(_ tasks: [URLSessionDownloadTask]) async {
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        task.cancel { _ in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func waitForDelegateQueueToDrain() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    nonisolated static func nextRange(
        startingAt start: Int64,
        totalBytes: Int64,
        chunkBytes: Int64? = nil
    ) -> ClosedRange<Int64>? {
        guard totalBytes > 0,
              start >= 0,
              start < totalBytes else {
            return nil
        }
        let boundedChunkBytes = max(1, chunkBytes ?? preferredRangeChunkBytes(totalBytes: totalBytes))
        let availableBytes = totalBytes - start
        let selectedBytes = min(availableBytes, boundedChunkBytes)
        let end = start + (selectedBytes - 1)
        return start...end
    }

    nonisolated static func preferredRangeChunkBytes(totalBytes: Int64) -> Int64 {
        totalBytes > largeFileRangeDownloadThresholdBytes
            ? largeFileRangeDownloadBytes
            : standardRangeDownloadBytes
    }

    nonisolated static func byteCount(in range: ClosedRange<Int64>) -> Int64 {
        let (difference, subtractionOverflow) = range.upperBound
            .subtractingReportingOverflow(range.lowerBound)
        guard !subtractionOverflow, difference >= 0 else { return .max }
        let (count, additionOverflow) = difference.addingReportingOverflow(1)
        return additionOverflow ? .max : count
    }

    nonisolated static func remainingIncomingBytes(
        requestedRange: ClosedRange<Int64>?,
        receivedBytes: Int64,
        expectedBytes: Int64,
        fallbackBytes: Int64
    ) -> Int64 {
        let receivedBytes = max(0, receivedBytes)
        if let requestedRange {
            return max(0, byteCount(in: requestedRange) - receivedBytes)
        }
        if expectedBytes > 0 {
            return max(0, expectedBytes - receivedBytes)
        }
        return max(0, fallbackBytes)
    }

    private nonisolated static func remainingIncomingBytes(
        for task: URLSessionTask,
        entry: ArkFilePackageManifest.Entry,
        reusableBytes: Int64
    ) -> Int64 {
        remainingIncomingBytes(
            requestedRange: requestedRange(from: task.originalRequest),
            receivedBytes: task.countOfBytesReceived,
            expectedBytes: task.countOfBytesExpectedToReceive,
            fallbackBytes: entry.sizeBytes - reusableBytes
        )
    }

    nonisolated static func canAcceptFullResponse(
        statusCode: Int,
        range: ClosedRange<Int64>?,
        entrySize: Int64
    ) -> Bool {
        guard statusCode == 200 else { return false }
        guard let range else { return true }
        return range.lowerBound == 0 && byteCount(in: range) == entrySize
    }

    nonisolated static func requestedRange(from request: URLRequest?) -> ClosedRange<Int64>? {
        guard let value = request?.value(forHTTPHeaderField: "Range")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start <= end else {
            return nil
        }
        return start...end
    }

    /// Fail-fast defense for a range response whose status, Content-Range, or
    /// observed byte count cannot describe the requested chunk. URLSession's
    /// delegate callback granularity and byte expectations are advisory, so
    /// this is not a strict transport byte cap: the controlled CDN must still
    /// honor Range and Content-Range. The delegate cancels at its first observed
    /// policy violation to limit, rather than eliminate, unexpected growth.
    nonisolated static func shouldCancelEarlyDownloadWrite(
        requestedRange: ClosedRange<Int64>?,
        responseStatusCode: Int?,
        contentRangeHeader: String?,
        totalBytesWritten: Int64,
        expectedTaskBytes: Int64
    ) -> Bool {
        guard totalBytesWritten >= 0 else { return true }
        let parsedContentRange = ArkFileHTTPContentRange.parse(contentRangeHeader)
        guard let responseStatusCode else { return true }
        switch responseStatusCode {
        case 200:
            // A full response can satisfy only a request beginning at zero;
            // the byte ceiling below still stops an ignored first range.
            guard parsedContentRange == nil else { return true }
            if let requestedRange, requestedRange.lowerBound != 0 {
                return true
            }
        case 206:
            guard let parsedContentRange else { return true }
            if let requestedRange,
               (parsedContentRange.start != requestedRange.lowerBound
                || parsedContentRange.end != requestedRange.upperBound) {
                return true
            }
        case 401:
            // Preserve only a tightly bounded error body so the completion
            // path can authenticate a structured confirmed-refund response.
            // Any other 401 still fails closed after parsing, and an oversized
            // response is cancelled before it can consume transfer-scale disk.
            return totalBytesWritten > maximumStructuredErrorResponseBytes
        default:
            return true
        }

        var byteCeilings = [Int64]()
        if let requestedRange {
            byteCeilings.append(byteCount(in: requestedRange))
        }
        if let parsedContentRange {
            byteCeilings.append(parsedContentRange.end - parsedContentRange.start + 1)
        }
        if expectedTaskBytes > 0 {
            byteCeilings.append(expectedTaskBytes)
        }
        guard let byteCeiling = byteCeilings.min(), byteCeiling > 0 else {
            return true
        }
        return totalBytesWritten > byteCeiling
    }

    /// Resolves the identity of a finished response without ever treating an
    /// unidentifiable partial response as a whole-file replacement. This is
    /// especially important after URLSession restores a background task whose
    /// original/current request is no longer available in memory.
    nonisolated static func finishedResponseRange(
        requestedRange: ClosedRange<Int64>?,
        persistedRange: ClosedRange<Int64>?,
        statusCode: Int,
        contentRangeHeader: String?
    ) throws -> ClosedRange<Int64>? {
        if let requestedRange { return requestedRange }
        if let persistedRange { return persistedRange }
        guard statusCode == 206 else { return nil }
        guard let contentRange = ArkFileHTTPContentRange.parse(contentRangeHeader) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile content server returned an invalid byte-range response."
            )
        }
        return contentRange.start...contentRange.end
    }

    private nonisolated static func fileMatchesInBackground(
        _ url: URL,
        entry: ArkFilePackageManifest.Entry
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            ArkFileContentFileVerifier.fileMatches(url, entry: entry)
        }.value
    }

    private nonisolated static func prepareDestinationForRangeRetryInBackground(
        _ destination: URL,
        entry: ArkFilePackageManifest.Entry
    ) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            try prepareDestinationForRangeRetry(destination, entry: entry)
        }.value
    }

    private nonisolated static func ensureEnoughStorageForRangeDownloadInBackground(
        destination: URL,
        incomingBytes: Int64
    ) async throws {
        try await Task.detached(priority: .utility) {
            let normalizedIncomingBytes = max(0, incomingBytes)
            guard normalizedIncomingBytes > 0 else { return }
            let requiredBytes = ArkFileContentStoragePreflight.addingWithoutOverflow(
                normalizedIncomingBytes,
                ArkFileContentStoragePreflight.safetyBytes(
                    for: normalizedIncomingBytes
                )
            )
            let root = destination.deletingLastPathComponent()
            guard let availableBytes = try ArkFileContentStoragePreflight.availableCapacityForDownload(at: root) else {
                throw ArkFileContentError.storageAvailabilityUnavailable(requiredBytes: requiredBytes)
            }
            guard availableBytes >= requiredBytes else {
                throw ArkFileContentError.insufficientStorage(
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            }
        }.value
    }

    private nonisolated static func processFinishedRangeDownload(
        record: ArkFileContentBackgroundDownloadRecord,
        range: ClosedRange<Int64>,
        preservedDownloadURL: URL,
        statusCode: Int,
        contentRangeHeader: String?
    ) async throws -> ArkFileFinishedDownloadOutcome {
        try await Task.detached(priority: .utility) {
            if canAcceptFullResponse(statusCode: statusCode, range: range, entrySize: record.entry.sizeBytes) {
                try replaceCompletedDownload(preservedDownloadURL, destination: record.destinationURL, entry: record.entry)
                return .finished
            }
            guard statusCode == 206 else {
                throw ArkFileContentError.httpStatus(statusCode)
            }
            guard let contentRange = ArkFileHTTPContentRange.parse(contentRangeHeader),
                  contentRange.start == range.lowerBound,
                  contentRange.end == range.upperBound,
                  contentRange.total == record.entry.sizeBytes else {
                throw ArkFileContentBackgroundDownloadError.failed(
                    "ArkFile content server returned an invalid byte-range response."
                )
            }

            try appendDownloadedChunk(preservedDownloadURL, to: record.destinationURL, range: range)
            let completedBytes = existingFileSize(at: record.destinationURL) ?? 0
            guard completedBytes <= record.entry.sizeBytes else {
                try? FileManager.default.removeItem(at: record.destinationURL)
                throw ArkFileContentBackgroundDownloadError.failed(
                    "ArkFile partial download grew beyond the expected file size."
                )
            }
            if completedBytes == record.entry.sizeBytes {
                switch ArkFileManagedPartialFile.verificationOutcome(
                    at: record.destinationURL,
                    entry: record.entry
                ) {
                case .matches:
                    return .finished
                case .definitiveMismatch:
                    try unlinkPartialEntry(record.destinationURL)
                    throw ArkFileContentError.checksumMismatch(
                        record.entry.normalizedRelativePath
                    )
                case .unavailable(let error):
                    throw ArkFileContentBackgroundDownloadError
                        .requiresPartialReconciliation(
                            "ArkFile downloaded the complete file but could not verify it yet: \(error.localizedDescription)"
                        )
                }
            }
            return .partial(completedBytes)
        }.value
    }

    nonisolated static func confirmedRefundError(
        response: HTTPURLResponse,
        responseBodyURL: URL
    ) -> ArkFileContentError? {
        guard response.statusCode == 401,
              case .regular(let byteCount, _) = try? ArkFileManagedPartialFile
                .classify(responseBodyURL),
              byteCount >= 0,
              byteCount <= maximumStructuredErrorResponseBytes,
              let responseBody = try? Data(contentsOf: responseBodyURL),
              let productIDs = ArkFileContentAPI.confirmedRefundProductIDs(
                statusCode: response.statusCode,
                contentType: response.value(forHTTPHeaderField: "Content-Type"),
                responseBody: responseBody,
                responseURL: response.url
              ) else {
            return nil
        }
        return ArkFileContentError.confirmedStoreKitRefund(
            productIDs: productIDs
        )
    }

    private nonisolated static func processFinishedFullDownload(
        record: ArkFileContentBackgroundDownloadRecord,
        preservedDownloadURL: URL,
        statusCode: Int
    ) async throws {
        try await Task.detached(priority: .utility) {
            guard (200..<300).contains(statusCode) else {
                throw ArkFileContentError.httpStatus(statusCode)
            }
            try replaceCompletedDownload(preservedDownloadURL, destination: record.destinationURL, entry: record.entry)
        }.value
    }

    private nonisolated static func prepareDestinationForRangeRetry(
        _ destination: URL,
        entry: ArkFilePackageManifest.Entry
    ) throws -> Int64 {
        let classification = try ArkFileManagedPartialFile.classify(destination)
        guard case .regular(let size, let linkCount) = classification else {
            if classification != .missing {
                try unlinkPartialEntry(destination)
            }
            return 0
        }
        if size == entry.sizeBytes {
            switch ArkFileManagedPartialFile.verificationOutcome(
                at: destination,
                entry: entry
            ) {
            case .matches:
                return entry.sizeBytes
            case .definitiveMismatch:
                try unlinkPartialEntry(destination)
                return 0
            case .unavailable(let error):
                throw error
            }
        }
        if linkCount == 1, size > 0 && size < entry.sizeBytes {
            return size
        }
        try unlinkPartialEntry(destination)
        return 0
    }

    private nonisolated static func downloadedByteCount(
        at destination: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Int64 {
        ArkFileManagedPartialFile.reusableByteCount(
            at: destination,
            entry: entry
        )
    }

    /// Repairs the only ambiguous crash window in ranged append: payload bytes
    /// may have reached the file before the durable record advanced. Never
    /// extend from the journal. Truncate a unique regular inode back to the
    /// lower durable boundary, downgrade when disk is shorter, and unlink only
    /// the managed directory entry for links/special files.
    nonisolated static func reconcileInterruptedAppend(
        record: ArkFileContentBackgroundDownloadRecord
    ) throws -> ArkFileContentBackgroundDownloadRecord {
        guard let activeRange = record.activeRange else { return record }
        var repaired = record
        let durableBoundary = min(
            max(0, record.completedBytes),
            min(max(0, activeRange.lowerBound), record.entry.sizeBytes)
        )
        switch try ArkFileManagedPartialFile.classify(record.destinationURL) {
        case .missing:
            repaired.completedBytes = 0
        case .symbolicLink, .other:
            try unlinkPartialEntry(record.destinationURL)
            repaired.completedBytes = 0
        case .regular(let size, let linkCount):
            if size == record.entry.sizeBytes {
                switch ArkFileManagedPartialFile.verificationOutcome(
                    at: record.destinationURL,
                    entry: record.entry
                ) {
                case .matches:
                    repaired.phase = .finished
                    repaired.completedBytes = record.entry.sizeBytes
                    repaired.expectedBytes = record.entry.sizeBytes
                    repaired.sessionTaskIdentifier = nil
                    repaired.activeRangeStart = nil
                    repaired.activeRangeEnd = nil
                    repaired.resumeData = nil
                    repaired.errorMessage = nil
                    return repaired
                case .definitiveMismatch:
                    try unlinkPartialEntry(record.destinationURL)
                    repaired.completedBytes = 0
                case .unavailable(let error):
                    throw error
                }
            }
            guard linkCount == 1,
                  size >= 0,
                  size < record.entry.sizeBytes else {
                try unlinkPartialEntry(record.destinationURL)
                repaired.completedBytes = 0
                break
            }
            if size > durableBoundary {
                try truncateUniqueRegularPartial(
                    record.destinationURL,
                    fromSize: size,
                    toSize: durableBoundary
                )
                repaired.completedBytes = durableBoundary
            } else {
                repaired.completedBytes = size
            }
        }
        repaired.phase = .scheduled
        repaired.expectedBytes = record.entry.sizeBytes
        repaired.sessionTaskIdentifier = nil
        repaired.activeRangeStart = nil
        repaired.activeRangeEnd = nil
        repaired.resumeData = nil
        repaired.errorMessage = nil
        return repaired
    }

    nonisolated static func createEmptyDownloadFile(at destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if try ArkFileManagedPartialFile.classify(destination) != .missing {
            try unlinkPartialEntry(destination)
        }
        let descriptor = Darwin.open(
            destination.standardizedFileURL.fileSystemPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size == 0,
              Darwin.fsync(descriptor) == 0 else {
            let capturedErrno = errno
            Darwin.close(descriptor)
            _ = Darwin.unlink(destination.standardizedFileURL.fileSystemPath)
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        Darwin.close(descriptor)
        try ArkFileDataProtection.apply(toExistingItem: destination)
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private nonisolated static func replaceCompletedDownload(
        _ source: URL,
        destination: URL,
        entry: ArkFilePackageManifest.Entry
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.fileSystemPath) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        do {
            try ArkFileDataProtection.apply(toExistingItem: destination)
            try synchronizeCompletedChunkAfterMove(
                source: source,
                destination: destination
            )
            switch ArkFileManagedPartialFile.verificationOutcome(
                at: destination,
                entry: entry
            ) {
            case .matches:
                return
            case .definitiveMismatch:
                try unlinkPartialEntry(destination)
                throw ArkFileContentError.checksumMismatch(
                    entry.normalizedRelativePath
                )
            case .unavailable(let error):
                throw ArkFileContentBackgroundDownloadError
                    .requiresPartialReconciliation(
                        "ArkFile downloaded the complete file but could not verify it yet: \(error.localizedDescription)"
                    )
            }
        } catch let error as ArkFileContentBackgroundDownloadError {
            if case .requiresPartialReconciliation = error {
                throw error
            }
            throw error
        } catch {
            do {
                try unlinkPartialEntry(destination)
                if source.deletingLastPathComponent().standardizedFileURL
                    != destination.deletingLastPathComponent().standardizedFileURL {
                    try synchronizeDirectory(source.deletingLastPathComponent())
                }
            } catch {
                throw ArkFileContentBackgroundDownloadError.requiresPartialReconciliation(
                    "ArkFile could not durably remove an uncheckpointed completed range. Open ArkFile to repair it safely."
                )
            }
            throw error
        }
    }

    nonisolated static func appendDownloadedChunk(
        _ source: URL,
        to destination: URL,
        range: ClosedRange<Int64>,
        failAfterBytesForTesting: Int64? = nil,
        failRollbackForTesting: Bool = false,
        failFirstMoveDurabilityForTesting: Bool = false
    ) throws {
        let chunkBytes = try fileSize(at: source)
        guard chunkBytes == byteCount(in: range) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile content server returned an unexpected byte-range size."
            )
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if case .missing = try ArkFileManagedPartialFile.classify(destination),
           range.lowerBound == 0 {
            try FileManager.default.moveItem(at: source, to: destination)
            do {
                try ArkFileDataProtection.apply(toExistingItem: destination)
                if failFirstMoveDurabilityForTesting {
                    throw POSIXError(.EIO)
                }
                try synchronizeCompletedChunkAfterMove(
                    source: source,
                    destination: destination
                )
            } catch {
                if failRollbackForTesting {
                    throw ArkFileContentBackgroundDownloadError
                        .requiresPartialReconciliation(
                            "ArkFile could not durably restore the empty partial-download checkpoint. Open ArkFile to repair it safely."
                        )
                }
                do {
                    try unlinkPartialEntry(destination)
                    if source.deletingLastPathComponent().standardizedFileURL
                        != destination.deletingLastPathComponent().standardizedFileURL {
                        try synchronizeDirectory(source.deletingLastPathComponent())
                    }
                } catch {
                    throw ArkFileContentBackgroundDownloadError
                        .requiresPartialReconciliation(
                            "ArkFile could not durably restore the empty partial-download checkpoint. Open ArkFile to repair it safely."
                        )
                }
                throw error
            }
            return
        }

        let input = try FileHandle(forReadingFrom: source)
        let outputDescriptor = Darwin.open(
            destination.standardizedFileURL.fileSystemPath,
            O_WRONLY | O_APPEND | O_NOFOLLOW
        )
        guard outputDescriptor >= 0 else {
            try? input.close()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var destinationInfo = stat()
        guard Darwin.fstat(outputDescriptor, &destinationInfo) == 0,
              (destinationInfo.st_mode & S_IFMT) == S_IFREG,
              destinationInfo.st_nlink == 1,
              Int64(destinationInfo.st_size) == range.lowerBound else {
            let capturedErrno = errno
            Darwin.close(outputDescriptor)
            try? input.close()
            throw POSIXError(POSIXErrorCode(rawValue: capturedErrno) ?? .EIO)
        }
        var appendedBytes: Int64 = 0
        do {
            while true {
                let data = try autoreleasepool { () throws -> Data? in
                    guard let data = try input.read(upToCount: 1024 * 1024),
                          !data.isEmpty else {
                        return nil
                    }
                    return data
                }
                guard let data else { break }
                if let failAfterBytesForTesting {
                    let remainingBeforeFailure = max(
                        0,
                        failAfterBytesForTesting - appendedBytes
                    )
                    if remainingBeforeFailure < Int64(data.count) {
                        if remainingBeforeFailure > 0 {
                            try writeAll(
                                data.prefix(Int(remainingBeforeFailure)),
                                to: outputDescriptor
                            )
                            appendedBytes += remainingBeforeFailure
                        }
                        throw ArkFileContentBackgroundDownloadError.failed(
                            "Injected ranged-append failure."
                        )
                    }
                }
                try writeAll(data, to: outputDescriptor)
                appendedBytes += Int64(data.count)
            }
            guard appendedBytes == chunkBytes else {
                throw ArkFileContentBackgroundDownloadError.failed(
                    "ArkFile copied an unexpected byte count into the managed partial."
                )
            }
            // This is the one destination-file flush for the completed chunk.
            // The durable journal cannot advance until it succeeds.
            guard Darwin.fsync(outputDescriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? input.close()
            // The journal still owns range.lowerBound. Restore exactly that
            // durable prefix on every copy/flush failure before surfacing it.
            let didTruncate = !failRollbackForTesting
                && Darwin.ftruncate(outputDescriptor, off_t(range.lowerBound)) == 0
            let didSynchronize = didTruncate
                && Darwin.fsync(outputDescriptor) == 0
            Darwin.close(outputDescriptor)
            let didSynchronizeParent: Bool
            do {
                if failRollbackForTesting {
                    throw POSIXError(.EIO)
                }
                try synchronizeDirectory(destination.deletingLastPathComponent())
                didSynchronizeParent = true
            } catch {
                didSynchronizeParent = false
            }
            guard didTruncate, didSynchronize, didSynchronizeParent else {
                throw ArkFileContentBackgroundDownloadError.requiresPartialReconciliation(
                    "ArkFile could not durably restore the prior partial-download checkpoint. Open ArkFile to repair it safely."
                )
            }
            throw error
        }
        Darwin.close(outputDescriptor)
        try? input.close()
        try FileManager.default.removeItem(at: source)
        try ArkFileDataProtection.apply(toExistingItem: destination)
        try synchronizeCompletedChunkDirectories(
            source: source,
            destination: destination
        )
    }

    nonisolated static func completedChunkDurabilityOperations(
        source: URL,
        destination: URL
    ) -> [ArkFileBackgroundDownloadDurabilityOperation] {
        let destinationPath = destination.standardizedFileURL.fileSystemPath
        let destinationParent = destination.deletingLastPathComponent().standardizedFileURL
        let sourceParent = source.deletingLastPathComponent().standardizedFileURL
        var operations: [ArkFileBackgroundDownloadDurabilityOperation] = [
            .synchronizeFile(destinationPath),
            .synchronizeDirectory(destinationParent.fileSystemPath)
        ]
        if sourceParent != destinationParent {
            operations.append(.synchronizeDirectory(sourceParent.fileSystemPath))
        }
        return operations
    }

    /// Uses only the real managed partial length for cold background resume.
    /// `nil` is an unreadable, negative, or oversized path and fails closed;
    /// definitive absence is the only state that safely means zero bytes.
    nonisolated static func coldSchedulerPartialByteCount(
        at destination: URL,
        entry: ArkFilePackageManifest.Entry
    ) -> Int64? {
        guard entry.sizeBytes >= 0 else { return nil }
        do {
            switch try ArkFileManagedPartialFile.classify(destination) {
            case .missing:
                return 0
            case .regular(let size, _)
                where size == entry.sizeBytes:
                return ArkFileManagedPartialFile.hasVerifiedCompleteFile(
                    at: destination,
                    entry: entry
                ) ? entry.sizeBytes : nil
            case .regular(let size, let linkCount)
                where linkCount == 1 && size >= 0 && size < entry.sizeBytes:
                return size
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// Narrow compatibility overload for tests and accounting call sites that
    /// cannot verify a complete inode. It accepts only a unique incomplete
    /// regular file; complete hard-link reuse requires the entry SHA overload.
    nonisolated static func coldSchedulerPartialByteCount(
        at destination: URL,
        expectedBytes: Int64
    ) -> Int64? {
        guard expectedBytes >= 0 else { return nil }
        do {
            switch try ArkFileManagedPartialFile.classify(destination) {
            case .missing:
                return 0
            case .regular(let size, let linkCount)
                where linkCount == 1 && size >= 0 && size <= expectedBytes:
                return size
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private nonisolated static func synchronizeCompletedChunkAfterMove(
        source: URL,
        destination: URL
    ) throws {
        try synchronizeFile(destination)
        try synchronizeCompletedChunkDirectories(
            source: source,
            destination: destination
        )
    }

    private nonisolated static func synchronizeCompletedChunkDirectories(
        source: URL,
        destination: URL
    ) throws {
        let operations = completedChunkDurabilityOperations(
            source: source,
            destination: destination
        )
        for operation in operations.dropFirst() {
            guard case .synchronizeDirectory(let path) = operation else { continue }
            try synchronizeDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    private nonisolated static func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.standardizedFileURL.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.standardizedFileURL.fileSystemPath, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func unlinkPartialEntry(_ url: URL) throws {
        if Darwin.unlink(url.standardizedFileURL.fileSystemPath) == 0 {
            try synchronizeDirectory(url.deletingLastPathComponent())
            return
        }
        if errno == ENOENT { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private nonisolated static func truncateUniqueRegularPartial(
        _ url: URL,
        fromSize expectedCurrentSize: Int64,
        toSize durableSize: Int64
    ) throws {
        let descriptor = Darwin.open(
            url.standardizedFileURL.fileSystemPath,
            O_WRONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              Int64(info.st_size) == expectedCurrentSize,
              durableSize >= 0,
              durableSize <= expectedCurrentSize else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused to truncate a changed or aliased managed partial."
            )
        }
        guard Darwin.ftruncate(descriptor, off_t(durableSize)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private nonisolated static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, baseAddress, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
    }

    private nonisolated static func fileSize(at url: URL) throws -> Int64 {
        guard case .regular(let size, _) = try ArkFileManagedPartialFile.classify(url),
              size >= 0 else {
            throw ArkFileContentError.invalidResponse
        }
        return size
    }

    private nonisolated static func existingFileSize(at url: URL) -> Int64? {
        guard case .regular(let size, _) = try? ArkFileManagedPartialFile.classify(url),
              size >= 0 else {
            return nil
        }
        return size
    }

    private func complete(recordID: String, result: Result<Void, Error>) {
        completedTasksAwaitingFinish.remove(recordID)
        progressHandlers[recordID] = nil
        activeProgressRecords.removeValue(forKey: recordID)
        if let taskIdentifier = continuationTaskIdentifiers.removeValue(
            forKey: recordID
        ) {
            pendingResponseErrorsByTaskIdentifier.removeValue(
                forKey: taskIdentifier
            )
        }
        guard let continuation = continuations.removeValue(forKey: recordID) else {
            return
        }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    /// A URLSession callback is allowed to finish an install continuation only
    /// when it still names the in-memory awaited task or the exact durable task
    /// checkpoint. A late tombstoned task that reuses the same record ID must
    /// not cancel or complete a newer task's continuation.
    private func completeCurrentTask(
        taskIdentifier: Int,
        recordID: String,
        result: Result<Void, Error>
    ) {
        // A terminal callback owns cleanup for its exact task even when the
        // record or foreground continuation has since moved on. This prevents
        // a typed response error from surviving a cold callback ordering or a
        // late stale callback, without letting that task complete newer work.
        defer {
            Self.clearPendingResponseError(
                for: taskIdentifier,
                from: &pendingResponseErrorsByTaskIdentifier
            )
        }
        let matchesAwaitedTask = continuationTaskIdentifiers[recordID] == taskIdentifier
        let matchesDurableTask = store.record(id: recordID)?.sessionTaskIdentifier
            == taskIdentifier
        guard matchesAwaitedTask || matchesDurableTask else { return }
        complete(recordID: recordID, result: result)
    }

    private func completeAll(with error: Error) {
        let ids = Array(continuations.keys)
        for id in ids {
            complete(recordID: id, result: .failure(error))
        }
    }
}

enum ArkFileContentBackgroundDownloadError: LocalizedError, Equatable {
    case failed(String)
    case requiresPartialReconciliation(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        case .requiresPartialReconciliation(let message):
            message
        }
    }
}

enum ArkFileBackgroundDownloadDiagnostics {
    static func message(for error: Error) -> String {
        message(for: error as NSError)
    }

    static func message(for error: NSError) -> String {
        var parts = [
            "\(error.domain) \(error.code): \(error.localizedDescription)"
        ]
        if let reason = error.localizedFailureReason, !reason.isEmpty {
            parts.append("reason: \(reason)")
        }
        if let suggestion = error.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append("suggestion: \(suggestion)")
        }
        if let failingURL = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           !failingURL.isEmpty {
            parts.append("failingURL: \(failingURL)")
        } else if let failingURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("failingURL: \(failingURL.absoluteString)")
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        let uniqueParts = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return uniqueParts.joined(separator: "; ")
    }
}

enum ArkFileBackgroundDownloadTemporaryFileHandoff {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var livePaths = Set<String>()
    }

    private static let state = State()

    static func preserve(
        _ temporaryURL: URL,
        recordID: String,
        taskIdentifier: Int,
        nonce: UUID = UUID(),
        namespace: String,
        under root: URL = defaultRoot()
    ) throws -> URL {
        state.lock.lock()
        defer { state.lock.unlock() }

        let directory = try managedDirectory(
            namespace: namespace,
            under: root,
            createIfMissing: true
        )

        let preservedURL = directory
            .appendingPathComponent(
                "\(safeFileName(for: recordID))-task-\(taskIdentifier)-\(nonce.uuidString.lowercased())"
            )
            .appendingPathExtension("download")
        try FileManager.default.moveItem(at: temporaryURL, to: preservedURL)
        state.livePaths.insert(preservedURL.standardizedFileURL.fileSystemPath)
        return preservedURL
    }

    static func cleanup(_ url: URL?) {
        guard let url else { return }
        state.lock.lock()
        defer { state.lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        state.livePaths.remove(url.standardizedFileURL.fileSystemPath)
    }

    /// Removes only recognized, regular handoff files from ArkFile's exact
    /// managed namespace. `preserve` and scavenging share one lock and live-file
    /// registry, so startup cleanup cannot race a delegate that has already
    /// taken ownership of its temporary file in this process.
    @discardableResult
    static func scavengeManagedOrphans(
        namespace: String,
        under root: URL = defaultRoot()
    ) throws -> Int {
        state.lock.lock()
        defer { state.lock.unlock() }

        let directoryCandidate = handoffDirectory(namespace: namespace, under: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryCandidate.fileSystemPath,
            isDirectory: &isDirectory
        ) else {
            return 0
        }
        guard isDirectory.boolValue else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused a non-directory background handoff path."
            )
        }
        let directory = try managedDirectory(
            namespace: namespace,
            under: root,
            createIfMissing: false
        )
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsSubdirectoryDescendants]
        )
        var removedCount = 0
        for candidate in candidates {
            let standardizedCandidate = candidate.standardizedFileURL
            guard standardizedCandidate.deletingLastPathComponent() == directory,
                  isRecognizedHandoffFileName(standardizedCandidate.lastPathComponent),
                  !state.livePaths.contains(standardizedCandidate.fileSystemPath) else {
                continue
            }
            let values = try standardizedCandidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try FileManager.default.removeItem(at: standardizedCandidate)
            removedCount += 1
        }
        return removedCount
    }

    private static func defaultRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("ArkFile", isDirectory: true)
    }

    private static func handoffDirectory(namespace: String, under root: URL) -> URL {
        root.standardizedFileURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(".background-handoff", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .standardizedFileURL
    }

    private static func managedDirectory(
        namespace: String,
        under root: URL,
        createIfMissing: Bool
    ) throws -> URL {
        let allowedNamespace = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !namespace.isEmpty,
              namespace.unicodeScalars.allSatisfy({ allowedNamespace.contains($0) }) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused an unsafe background handoff namespace."
            )
        }

        let standardizedRoot = root.standardizedFileURL
        let downloads = standardizedRoot.appendingPathComponent("Downloads", isDirectory: true)
        let handoffRoot = downloads.appendingPathComponent(".background-handoff", isDirectory: true)
        let directory = handoffRoot
            .appendingPathComponent(namespace, isDirectory: true)
            .standardizedFileURL
        guard isStrictDescendant(directory, of: standardizedRoot) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused a background handoff path outside its managed root."
            )
        }
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        // Refuse symlinked managed components even when they happen to resolve
        // back inside the root. This keeps enumeration and deletion lexical and
        // prevents an attacker-controlled link swap from escaping containment.
        for component in [downloads, handoffRoot, directory] {
            let values = try component.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw ArkFileContentBackgroundDownloadError.failed(
                    "ArkFile refused a symlinked background handoff directory."
                )
            }
        }
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        guard isStrictDescendant(resolvedDirectory, of: resolvedRoot) else {
            throw ArkFileContentBackgroundDownloadError.failed(
                "ArkFile refused a background handoff path outside its managed root."
            )
        }
        return directory
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.fileSystemPath
        let candidatePath = candidate.standardizedFileURL.fileSystemPath
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func isRecognizedHandoffFileName(_ fileName: String) -> Bool {
        fileName.count > ".download".count
            && fileName.lowercased().hasSuffix(".download")
    }

    private static func safeFileName(for recordID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var safe = ""
        for scalar in recordID.unicodeScalars {
            if allowed.contains(scalar) {
                safe.unicodeScalars.append(scalar)
            } else {
                safe.append("-")
            }
        }
        return safe.isEmpty ? UUID().uuidString : safe
    }
}

@MainActor
private final class ArkFileContentBackgroundDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var service: ArkFileContentBackgroundDownloadService?
    var backgroundCompletionHandler: (() -> Void)?
    private let postprocessingGate = ArkFileBackgroundDownloadPostprocessingGate()
    private let progressCoalescer = ArkFileBackgroundDownloadProgressCoalescer()

    func endPostprocessing() {
        postprocessingGate.end()
    }

    func beginRejectingAllCallbacks(taskIdentifiers: Set<Int>) {
        postprocessingGate.beginRejectingAll(taskIdentifiers: taskIdentifiers)
    }

    func rejectCallbacks(for taskIdentifiers: Set<Int>) {
        postprocessingGate.reject(taskIdentifiers: taskIdentifiers)
    }

    func endRejectingAllCallbacks() {
        postprocessingGate.endRejectingAll()
    }

    func waitForPostprocessingToFinish() async {
        await postprocessingGate.waitUntilIdle()
    }

    func finishBackgroundEvents() {
        postprocessingGate.finishEvents(backgroundCompletionHandler)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            ArkFileContentBackgroundDownloadService.authorizedRedirectRequest(
                from: task.currentRequest?.url ?? task.originalRequest?.url,
                to: request
            )
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard !ArkFileContentBackgroundDownloadService
            .shouldCancelUnmappedTaskDescription(downloadTask.taskDescription),
              let recordID = downloadTask.taskDescription else {
            postprocessingGate.reject(
                taskIdentifiers: [downloadTask.taskIdentifier]
            )
            downloadTask.cancel()
            return
        }
        let requestedRange = ArkFileContentBackgroundDownloadService.requestedRange(
            from: downloadTask.originalRequest ?? downloadTask.currentRequest
        )
        let httpResponse = downloadTask.response as? HTTPURLResponse
        if ArkFileContentBackgroundDownloadService.shouldCancelEarlyDownloadWrite(
            requestedRange: requestedRange,
            responseStatusCode: httpResponse?.statusCode,
            contentRangeHeader: httpResponse?.value(
                forHTTPHeaderField: "Content-Range"
            ),
            totalBytesWritten: totalBytesWritten,
            expectedTaskBytes: downloadTask.countOfBytesClientExpectsToReceive
        ) {
            postprocessingGate.reject(taskIdentifiers: [downloadTask.taskIdentifier])
            progressCoalescer.remove(recordID: recordID)
            downloadTask.cancel()
            return
        }
        guard progressCoalescer.shouldForward(
            recordID: recordID,
            completedBytes: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite
        ) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.service?.didWrite(
                taskIdentifier: downloadTask.taskIdentifier,
                recordID: recordID,
                completedBytes: totalBytesWritten,
                expectedBytes: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let recordID = downloadTask.taskDescription else { return }
        guard postprocessingGate.begin(taskIdentifier: downloadTask.taskIdentifier) else {
            ArkFileBackgroundDownloadTemporaryFileHandoff.cleanup(location)
            return
        }
        let preservedURL: URL?
        let preservationErrorMessage: String?
        do {
            preservedURL = try ArkFileBackgroundDownloadTemporaryFileHandoff.preserve(
                location,
                recordID: recordID,
                taskIdentifier: downloadTask.taskIdentifier,
                namespace: "content-pack"
            )
            preservationErrorMessage = nil
        } catch {
            preservedURL = nil
            preservationErrorMessage = ArkFileBackgroundDownloadDiagnostics.message(for: error)
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let service = self.service else {
                ArkFileContentBackgroundDownloadService.cleanupPreservedHandoff(preservedURL)
                self?.postprocessingGate.end()
                return
            }
            await service.didFinishDownloading(
                taskIdentifier: downloadTask.taskIdentifier,
                recordID: recordID,
                requestedRange: ArkFileContentBackgroundDownloadService.requestedRange(
                    from: downloadTask.originalRequest ?? downloadTask.currentRequest
                ),
                preservedDownloadURL: preservedURL,
                response: downloadTask.response,
                preservationErrorMessage: preservationErrorMessage
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let recordID = task.taskDescription else { return }
        progressCoalescer.remove(recordID: recordID)
        // didComplete can be the only callback for an early cancellation. Keep
        // iOS background events open until its terminal journal work finishes,
        // even when payload postprocessing for this task was rejected.
        postprocessingGate.beginTerminalWork()
        let terminalGate = postprocessingGate
        Task { @MainActor [weak self] in
            defer { terminalGate.end() }
            guard let service = self?.service else { return }
            service.didComplete(
                taskIdentifier: task.taskIdentifier,
                recordID: recordID,
                error: error
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.service?.finishBackgroundEvents()
        }
    }
}
