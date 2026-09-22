import Foundation

extension Notification.Name {
    static let arkFileContentReleaseChanged = Notification.Name("ArkFileContentReleaseChanged")
}

/// One synchronous snapshot for readers/discovery and an explicit async refresh
/// for the user. No startup request or mutable process-lifetime catalog cache.
final class ArkFileContentReleaseProvider: @unchecked Sendable {
    static let shared = ArkFileContentReleaseProvider()

    struct InstalledRevision: Codable, Equatable, Sendable {
        let itemID: String
        let revisionID: String
        let binding: ArkFileContentReleaseBinding
        let catalog: ArkFileContentRelease.Catalog
        let publicNotice: ArkFileContentPublicNotice
        let files: [ArkFileContentRelease.File]
        let legacyPaths: [String]
    }
    struct Snapshot: Sendable {
        let generation: UInt64
        let available: ArkFileVerifiedContentRelease?
        let catalog: ArkFileContentCatalog?
        let installed: [String: InstalledRevision]
        let errorMessage: String?
    }
    private struct InstalledStore: Codable {
        let formatVersion: Int
        let revisions: [String: InstalledRevision]
    }
    private struct SigningKeys: Decodable { let formatVersion: Int; let keys: [String: String] }
    private let lock = NSRecursiveLock()
    private let root: URL
    private let keys: [String: Data]
    private var generationValue: UInt64 = 0
    private var current: ArkFileVerifiedContentRelease?
    private var baseline: ArkFileVerifiedContentRelease?
    private var catalogValue: ArkFileContentCatalog?
    private var publication: ArkFileContentPublication?
    private var publicationDigest: String?
    private var installed: [String: InstalledRevision] = [:]
    private var errorMessage: String?
    private var discoveryCache: (provider: UInt64, authority: UInt64, catalog: ArkFileContentCatalog)?

    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArkFile/ContentReleases", isDirectory: true)
        let keyURL = Bundle.main.url(forResource: "content-signing-keys", withExtension: "json",
                                     subdirectory: "ArkFileContentRelease")
            ?? Bundle.main.url(forResource: "content-signing-keys", withExtension: "json")
        let keyFile = keyURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(SigningKeys.self, from: $0) }
        let keys = keyFile?.formatVersion == 1
            ? keyFile!.keys.compactMapValues { Data(base64Encoded: $0) } : [:]
        self.init(root: root, keys: keys, bundledCatalog: try? ArkFileContentCatalog.loadBundled(), awaitingBundledBaseline: true)
        if let url = Bundle.main.url(forResource: "baseline-release", withExtension: "json",
                                      subdirectory: "ArkFileContentRelease")
            ?? Bundle.main.url(forResource: "baseline-release", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                let verified = try ArkFileContentReleaseVerifier.verifyRelease(data, keys: keys)
                baseline = verified
                try persist(verified.envelope, at: releaseURL(verified.binding))
                if current == nil {
                    current = verified
                    catalogValue = try verified.release.catalogProjection()
                }
                if let indexURL = Bundle.main.url(forResource: "baseline-publication", withExtension: "json", subdirectory: "ArkFileContentRelease")
                    ?? Bundle.main.url(forResource: "baseline-publication", withExtension: "json") {
                    let bytes = try Data(contentsOf: indexURL)
                    let index = try ArkFileContentReleaseVerifier.verifyPublication(bytes, keys: keys)
                    guard index.current?.binding == verified.binding else { throw ArkFileContentReleaseError.untrustedSignature }
                    if publication == nil || publication!.publicationSequence <= index.publicationSequence {
                        try accept(publicationBytes: bytes, index: index, release: verified,
                                   catalog: verified.release.catalogProjection())
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        validateInstalledReceipts()
        if let baseline {
            do { try refreshInstalledNotices(from: baseline) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    init(root: URL, keys: [String: Data], bundledCatalog: ArkFileContentCatalog? = nil,
         awaitingBundledBaseline: Bool = false) {
        self.root = root; self.keys = keys; self.catalogValue = bundledCatalog
        // Invalid or temporarily unavailable cache never replaces the bundled
        // baseline or grants authority to an unsigned release.
        do {
            if FileManager.default.fileExists(atPath: publicationURL.path) {
                let bytes = try Data(contentsOf: publicationURL)
                let index = try ArkFileContentReleaseVerifier.verifyPublication(bytes, keys: keys)
                guard let target = index.current else { throw ArkFileContentReleaseError.releaseUnavailable }
                let verified = try readRelease(target.binding)
                current = verified; catalogValue = try verified.release.catalogProjection()
                publication = index
                publicationDigest = try ArkFileContentReleaseVerifier.payloadDigest(bytes, keys: keys)
            }
        } catch { errorMessage = error.localizedDescription }
        do {
            if FileManager.default.fileExists(atPath: installedURL.path) {
                let store = try JSONDecoder().decode(InstalledStore.self, from: Data(contentsOf: installedURL))
                guard store.formatVersion == 1 else { throw ArkFileContentReleaseError.unsupportedSchema }
                installed = store.revisions
            }
        } catch { errorMessage = error.localizedDescription }
        if !awaitingBundledBaseline { validateInstalledReceipts() }
    }

    private func validateInstalledReceipts() {
        let migration = (try? migrationEntries()) ?? []
        installed = installed.filter { id, receipt in
            guard id == receipt.itemID, let verified = try? readRelease(receipt.binding),
                  let item = verified.release.item(id) else { return false }
            if item.revisionID == receipt.revisionID,
               item.publicNotice == receipt.publicNotice, item.catalog == receipt.catalog,
               verified.release.files(for: [item.primaryGroupID]) == receipt.files { return true }
            guard baseline?.binding == receipt.binding else { return false }
            return migration.contains { entry in
                entry.itemID == id && entry.revisionID == receipt.revisionID && entry.files == receipt.files
                    && (entry.publicNotice ?? item.publicNotice) == receipt.publicNotice
                    && item.catalog == receipt.catalog
            }
        }
    }

    /// A new bundled baseline can correct notices for the exact same edition.
    /// Keep this centralized in receipts so discovery, detail and sharing agree.
    /// No new item or changed file can become installed through this operation.
    func refreshInstalledNotices(from baseline: ArkFileVerifiedContentRelease) throws {
        lock.lock(); defer { lock.unlock() }
        let verified = try ArkFileContentReleaseVerifier.verifyRelease(
            baseline.envelope, keys: keys, expected: baseline.binding)
        var next = installed
        for (id, receipt) in installed {
            guard id == receipt.itemID,
                  let previous = try? readRelease(receipt.binding),
                  let oldItem = previous.release.item(id),
                  oldItem.revisionID == receipt.revisionID,
                  oldItem.catalog == receipt.catalog, oldItem.publicNotice == receipt.publicNotice,
                  previous.release.files(for: [oldItem.primaryGroupID]) == receipt.files,
                  let item = verified.release.item(id), item.revisionID == receipt.revisionID,
                  item.catalog == receipt.catalog,
                  verified.release.files(for: [item.primaryGroupID]) == receipt.files,
                  item.minimumTier == oldItem.minimumTier,
                  item.primaryGroupID == oldItem.primaryGroupID, item.groupIDs == oldItem.groupIDs,
                  item.requiredCapabilities == oldItem.requiredCapabilities, item.availability == oldItem.availability,
                  verified.release.files(for: Set(item.groupIDs)) == previous.release.files(for: Set(oldItem.groupIDs)),
                  item.publicNotice != receipt.publicNotice else { continue }
            next[id] = InstalledRevision(itemID: id, revisionID: receipt.revisionID, binding: verified.binding,
                catalog: receipt.catalog, publicNotice: item.publicNotice,
                files: receipt.files, legacyPaths: receipt.legacyPaths)
        }
        guard next != installed else { return }
        // Persist the signed source first and publish the rebound receipts only
        // after their durable write succeeds. A failure retains the old receipt
        // in memory and retries this correction on the next launch.
        try persist(verified.envelope, at: releaseURL(verified.binding))
        try persist(JSONEncoder().encode(InstalledStore(formatVersion: 1, revisions: next)), at: installedURL)
        installed = next; changed()
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(generation: generationValue, available: current, catalog: catalogValue,
                     installed: installed, errorMessage: errorMessage)
    }
    var generation: UInt64 { snapshot.generation }
    var catalog: ArkFileContentCatalog? { snapshot.catalog }

    /// Discovery follows the installed edition while a newer edition waits for
    /// explicit review. Available metadata remains separate for the update UI.
    var discoveryCatalog: ArkFileContentCatalog? {
        let state = snapshot
        guard let availableCatalog = state.catalog else { return nil }
        let authority = ArkFileInstalledContentAccess.localAuthorityGeneration
        if let cached = cachedDiscovery(generation: state.generation, authority: authority) { return cached }
        guard let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else { return availableCatalog }
        let entries = Dictionary(commit.payload.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = Dictionary(availableCatalog.allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for receipt in state.installed.values where receipt.files.allSatisfy({ file in
            entries[file.relativePath]?.byteCount == file.sizeBytes && entries[file.relativePath]?.sha256 == file.sha256
        }) {
            let tier = receipt.files.contains { entries[$0.relativePath]?.tier == "complete" } ? "complete" : "lite"
            let item = ArkFileContentRelease.Item(itemID: receipt.itemID, revisionID: receipt.revisionID,
                minimumTier: tier, primaryGroupID: "installed", groupIDs: ["installed"], requiredCapabilities: [],
                availability: "available", catalog: receipt.catalog, publicNotice: receipt.publicNotice)
            let projection = ArkFileContentRelease(schemaVersion: 2, kind: "content-release", product: "ArkFile",
                releaseID: receipt.binding.releaseID, createdAt: "", items: [item], groups: [
                    .init(groupID: "installed", kind: "document", minimumTier: tier,
                          fileIDs: receipt.files.map(\.fileID), requiredCapabilities: [])], files: receipt.files)
            if let row = try? projection.catalogProjection().allItems.first { rows[receipt.itemID] = row }
        }
        let result = ArkFileContentCatalog(schemaVersion: availableCatalog.schemaVersion, product: availableCatalog.product,
            description: availableCatalog.description, tiers: availableCatalog.tiers, source: availableCatalog.source,
            contentLicenses: availableCatalog.contentLicenses,
            categories: Dictionary(grouping: rows.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                   by: { $0.category.rawValue }))
        lock.lock(); discoveryCache = (state.generation, authority, result); lock.unlock()
        return result
    }
    private func cachedDiscovery(generation: UInt64, authority: UInt64) -> ArkFileContentCatalog? {
        lock.lock(); defer { lock.unlock() }
        guard discoveryCache?.provider == generation, discoveryCache?.authority == authority else { return nil }
        return discoveryCache?.catalog
    }

    func verifiedRelease(_ binding: ArkFileContentReleaseBinding) throws -> ArkFileVerifiedContentRelease {
        lock.lock(); defer { lock.unlock() }
        if current?.binding == binding { return current! }
        return try readRelease(binding)
    }

    /// Called only by a visible, explicit Check for content updates action.
    func refresh(using api: ArkFileContentAPI) async throws {
        let bytes = try await api.contentPublication()
        let previous = publicationState()
        let index = try ArkFileContentReleaseVerifier.verifyPublication(bytes, keys: keys, previous: previous)
        guard let target = index.current, target.offered, target.delivery == "available" else {
            throw ArkFileContentReleaseError.releaseUnavailable
        }
        let envelope = try await api.contentRelease(target.binding)
        let verified = try ArkFileContentReleaseVerifier.verifyRelease(envelope, keys: keys, expected: target.binding)
        let projection = try verified.release.catalogProjection()
        try accept(publicationBytes: bytes, index: index, release: verified, catalog: projection)
    }

    private func publicationState() -> (sequence: Int64, digest: String)? {
        lock.lock(); defer { lock.unlock() }
        return publication.map { ($0.publicationSequence, publicationDigest ?? "") }
    }

    private func accept(publicationBytes: Data, index: ArkFileContentPublication,
                        release: ArkFileVerifiedContentRelease, catalog: ArkFileContentCatalog) throws {
        lock.lock(); defer { lock.unlock() }
        // Repeat monotonic admission after network awaits to defeat an older
        // concurrent refresh completing after a newer publication.
        _ = try ArkFileContentReleaseVerifier.verifyPublication(publicationBytes, keys: keys,
            previous: publication.map { ($0.publicationSequence, publicationDigest ?? "") })
        try persist(release.envelope, at: releaseURL(release.binding))
        try persist(publicationBytes, at: publicationURL)
        current = release; catalogValue = catalog; publication = index
        publicationDigest = try ArkFileContentReleaseVerifier.payloadDigest(publicationBytes, keys: keys)
        errorMessage = nil; changed()
    }

    func recordInstalled(_ item: ArkFileContentRelease.Item,
                         from verified: ArkFileVerifiedContentRelease,
                         legacyPaths: [String] = []) throws {
        let files = verified.release.files(for: [item.primaryGroupID])
        guard !files.isEmpty, verified.release.item(item.itemID) == item else {
            throw ArkFileContentReleaseError.invalid("installed revision")
        }
        let receipt = InstalledRevision(itemID: item.itemID, revisionID: item.revisionID,
            binding: verified.binding, catalog: item.catalog, publicNotice: item.publicNotice,
            files: files, legacyPaths: legacyPaths)
        lock.lock(); defer { lock.unlock() }
        var next = installed; next[item.itemID] = receipt
        try persist(verified.envelope, at: releaseURL(verified.binding))
        try persist(JSONEncoder().encode(InstalledStore(formatVersion: 1, revisions: next)), at: installedURL)
        installed = next; changed()
    }

    func installedRevision(itemID: String) -> InstalledRevision? { snapshot.installed[itemID] }

    /// A receipt is metadata, never permission to read a file. The sharing caller
    /// must also pass the committed artifact identity from its frozen snapshot.
    func installedPublicNotice(relativePath: String, byteCount: Int64, sha256: String) -> ArkFileContentPublicNotice? {
        let path = ArkFileContentReleaseVerifier.canonicalPath(relativePath)
        return snapshot.installed.values.first { receipt in
            receipt.files.contains { file in
                ArkFileContentReleaseVerifier.canonicalPath(file.relativePath) == path
                    && file.sizeBytes == byteCount && file.sha256 == sha256.lowercased()
            }
        }?.publicNotice
    }

    func managedItemID(forLegacyPath path: String) -> String? {
        let key = ArkFileContentReleaseVerifier.canonicalPath(path)
        return snapshot.installed.values.first {
            ArkFileContentReleaseVerifier.canonicalPath($0.catalog.relativePath) == key
                || $0.legacyPaths.contains { ArkFileContentReleaseVerifier.canonicalPath($0) == key }
        }?.itemID
    }

    struct Migration: Decodable {
        struct Entry: Decodable {
            let itemID: String
            let revisionID: String
            let legacyRelativePath: String
            let files: [ArkFileContentRelease.File]
            let publicNotice: ArkFileContentPublicNotice?
        }
        let formatVersion: Int
        let baselineReleaseID: String
        let baselineReleaseSHA256: String
        let entries: [Entry]
    }
    func migrationEntries() throws -> [Migration.Entry] {
        guard let baseline,
              let url = Bundle.main.url(forResource: "baseline-migration", withExtension: "json", subdirectory: "ArkFileContentRelease")
                ?? Bundle.main.url(forResource: "baseline-migration", withExtension: "json") else { return [] }
        let migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: url))
        guard migration.formatVersion == 1, migration.baselineReleaseID == baseline.binding.releaseID,
              migration.baselineReleaseSHA256 == baseline.binding.releaseSHA256 else {
            throw ArkFileContentReleaseError.invalid("bundled migration binding")
        }
        return migration.entries
    }

    /// A bundled explicit mapping can label a known legacy install, but only
    /// after exact committed identities match. Hashless/unknown/imported files
    /// remain local legacy content and are never selected for deletion here.
    func adoptKnownBaselineInstallations() throws {
        guard let baseline,
              let root = try? ArkFileContentPackInstaller.protectedActiveContentRoot(),
              let commit = ArkFileInstalledContentAccess.currentCommitRecord(at: root) else { return }
        let entries = try migrationEntries()
        let byID = Dictionary(grouping: entries, by: \.itemID)
        lock.lock(); defer { lock.unlock() }
        var next = installed
        for (id, candidates) in byID where next[id] == nil {
            guard let item = baseline.release.item(id) else { continue }
            let matches = candidates.filter { candidate in
                !candidate.files.isEmpty && candidate.files.allSatisfy { file in
                    commit.payload.entries.contains { $0.relativePath == file.relativePath
                        && $0.byteCount == file.sizeBytes && $0.sha256?.lowercased() == file.sha256 }
                }
            }
            guard matches.count == 1, let match = matches.first else { continue }
            next[id] = InstalledRevision(itemID: id, revisionID: match.revisionID, binding: baseline.binding,
                catalog: item.catalog, publicNotice: match.publicNotice ?? item.publicNotice,
                files: match.files, legacyPaths: [match.legacyRelativePath])
        }
        guard next != installed else { return }
        try persist(JSONEncoder().encode(InstalledStore(formatVersion: 1, revisions: next)), at: installedURL)
        installed = next; changed()
    }

    private func readRelease(_ binding: ArkFileContentReleaseBinding) throws -> ArkFileVerifiedContentRelease {
        guard ArkFileContentReleaseVerifier.validID(binding.releaseID),
              ArkFileContentReleaseVerifier.validHash(binding.releaseSHA256) else {
            throw ArkFileContentReleaseError.invalid("release binding")
        }
        return try ArkFileContentReleaseVerifier.verifyRelease(Data(contentsOf: releaseURL(binding)),
            keys: keys, expected: binding)
    }
    private var publicationURL: URL { root.appendingPathComponent("publication.json") }
    private var installedURL: URL { root.appendingPathComponent("installed-revisions.json") }
    private func releaseURL(_ binding: ArkFileContentReleaseBinding) -> URL {
        root.appendingPathComponent("release-\(binding.releaseSHA256).json")
    }
    private func persist(_ bytes: Data, at url: URL) throws {
        try ArkFileDataProtection.createProtectedDirectory(at: root)
        try ArkFileDurableAtomicWriter.write(bytes, to: url)
        try ArkFileDataProtection.apply(toExistingItem: url)
    }
    private func changed() {
        generationValue &+= 1
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .arkFileContentReleaseChanged, object: nil)
        }
    }
}
