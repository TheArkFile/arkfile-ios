import Foundation

/// Public, signed content metadata. This is deliberately independent of the
/// bundled legacy disposition index and its private publication evidence.
struct ArkFileContentPublicNotice: Codable, Equatable, Sendable {
    let sourceTitle: String
    let creators: [String]
    let publisher: String?
    let canonicalURL: String?
    let attributionText: String
    let changesMade: String
    let rightsSummary: String
    let licenseID: String?
    let licenseName: String?
    let licenseURL: String?
    let internalNoticePaths: [String]?
}

struct ArkFileContentReleaseBinding: Codable, Equatable, Hashable, Sendable {
    let releaseID: String
    let releaseSHA256: String
}

struct ArkFileContentRelease: Codable, Sendable {
    struct Catalog: Codable, Equatable, Sendable {
        let name: String
        let relativePath: String
        let category: String
        let subcategory: String
        let type: String
        let summary: String?
        let variantGroup: String?
        let variantLabel: String?
        let variantDefault: Bool?
    }
    struct Item: Codable, Equatable, Identifiable, Sendable {
        let itemID: String
        let revisionID: String
        let minimumTier: String
        let primaryGroupID: String
        let groupIDs: [String]
        let requiredCapabilities: [String]
        let availability: String
        let catalog: Catalog
        let publicNotice: ArkFileContentPublicNotice
        var id: String { itemID }
    }
    struct Group: Codable, Equatable, Sendable {
        let groupID: String
        let kind: String
        let minimumTier: String
        let fileIDs: [String]
        let requiredCapabilities: [String]
    }
    struct File: Codable, Equatable, Sendable {
        let fileID: String
        let relativePath: String
        let objectKey: String
        let sizeBytes: Int64
        let sha256: String
        let mode: Int?
        var manifestEntry: ArkFilePackageManifest.Entry {
            .init(relativePath: relativePath, objectKey: objectKey,
                  sizeBytes: sizeBytes, sha256: sha256, mode: mode)
        }
    }
    let schemaVersion: Int
    let kind: String
    let product: String
    let releaseID: String
    let createdAt: String
    let items: [Item]
    let groups: [Group]
    let files: [File]

    static let supportedCapabilities: Set<String> = [
        "zim-v1", "pdf-v1", "htmlbook-v1", "image-v1", "html-v1",
        "pmtiles-v3", "map-style-v1", "poi-sqlite-v1"
    ]
    func item(_ id: String) -> Item? { items.first { $0.itemID == id } }
    func group(_ id: String) -> Group? { groups.first { $0.groupID == id } }
    func file(_ id: String) -> File? { files.first { $0.fileID == id } }
    func isSupported(_ item: Item) -> Bool {
        guard ArkFileLocalContentType(rawValue: item.catalog.type) != nil,
              ArkFileLocalContentCategoryKey(rawValue: item.catalog.category) != nil,
              Set(item.requiredCapabilities).isSubset(of: Self.supportedCapabilities) else { return false }
        return item.groupIDs.allSatisfy { id in
            guard let group = group(id) else { return false }
            return ["zim", "document", "map-core", "map-region"].contains(group.kind)
                && Set(group.requiredCapabilities).isSubset(of: Self.supportedCapabilities)
        }
    }
    func files(for groupIDs: Set<String>) -> [File] {
        let ids = Set(groups.filter { groupIDs.contains($0.groupID) }.flatMap(\.fileIDs))
        return files.filter { ids.contains($0.fileID) }
    }
    func itemBytes(_ item: Item) -> Int64 {
        files(for: [item.primaryGroupID]).reduce(0) { $0 + $1.sizeBytes }
    }

    /// Adapter for existing discovery/UI models. New items always start
    /// unselected; private review fields are never synthesized.
    func catalogProjection() throws -> ArkFileContentCatalog {
        var categories: [String: [[String: Any]]] = [:]
        for item in items where isSupported(item) {
            var row: [String: Any] = [
                "id": item.itemID, "name": item.catalog.name,
                "relativePath": item.catalog.relativePath,
                "category": item.catalog.category, "subcategory": item.catalog.subcategory,
                "type": item.catalog.type, "sizeBytes": itemBytes(item),
                "minimumTier": item.minimumTier,
                "availableInTiers": item.minimumTier == "lite" ? ["lite", "complete"] : ["complete"],
                "requiredPack": item.minimumTier == "lite" ? "essentials" : "complete",
                "defaultSelected": false,
                "attributionText": item.publicNotice.attributionText,
                "changesMade": item.publicNotice.changesMade
            ]
            row["summary"] = item.catalog.summary
            row["variantGroup"] = item.catalog.variantGroup
            row["variantLabel"] = item.catalog.variantLabel
            row["variantDefault"] = item.catalog.variantDefault
            row["licenseId"] = item.publicNotice.licenseID
            row["licenseName"] = item.publicNotice.licenseName
            row["licenseUrl"] = item.publicNotice.licenseURL
            row["sourceUrl"] = item.publicNotice.canonicalURL
            categories[item.catalog.category, default: []].append(row)
        }
        let object: [String: Any] = ["schemaVersion": 1, "product": "ArkFile",
            "tiers": ["lite": "ArkFile Essentials", "complete": "ArkFile Complete"],
            "categories": categories]
        return try JSONDecoder().decode(ArkFileContentCatalog.self,
                                       from: JSONSerialization.data(withJSONObject: object))
    }
}

struct ArkFileContentPublication: Codable, Sendable {
    struct Release: Codable, Equatable, Sendable {
        let releaseID: String
        let releaseSHA256: String
        let offered: Bool
        let delivery: String
        let reasonCode: String?
        var binding: ArkFileContentReleaseBinding {
            .init(releaseID: releaseID, releaseSHA256: releaseSHA256)
        }
    }
    let schemaVersion: Int
    let kind: String
    let product: String
    let channel: String
    let publicationSequence: Int64
    let currentReleaseID: String
    let releases: [Release]
    var current: Release? { releases.first { $0.releaseID == currentReleaseID } }
}

struct ArkFileContentRevisionSelection: Codable, Equatable, Sendable {
    let itemID: String
    let revisionID: String
    let mode: Mode
    enum Mode: String, Codable, Sendable { case staged, deleteFirst }
}

/// Persist this request before transfer or deletion. Catalog refresh may never
/// retarget it. A changed target or variant needs a new user confirmation.
struct ArkFileContentReleaseRequest: Codable, Equatable, Sendable {
    let id: UUID
    let binding: ArkFileContentReleaseBinding
    let tier: ArkFileContentTier
    let selections: [ArkFileContentRevisionSelection]
    let confirmedAt: Date
}

enum ArkFileContentReleaseError: LocalizedError {
    case invalid(String)
    case unsupportedSchema
    case untrustedSignature
    case releaseUnavailable
    case incompatibleItem(String)
    case staleSelection
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): "The content release is invalid: \(detail)"
        case .unsupportedSchema: "This content release needs a newer version of ArkFile. Your installed library remains available."
        case .untrustedSignature: "ArkFile could not verify this content release. Your installed library remains available."
        case .releaseUnavailable: "This download edition is unavailable. Your progress has been kept. Check for another edition when online."
        case .incompatibleItem(let title): "\(title) requires a newer version of ArkFile."
        case .staleSelection: "The selected edition changed. Review the download again before continuing."
        }
    }
}

/// Storage accounting includes the URLSession range buffer and a safety margin.
/// Reclaim estimates are used only before consented deletion; the transfer gate
/// always re-measures actual free capacity with reclaimableBytes equal to zero.
enum ArkFileContentReplacementStoragePolicy {
    static let bufferBytes: Int64 = 2 * 1024 * 1024 * 1024
    static func requiredFreeBytes(remainingBytes: Int64, reclaimableBytes: Int64 = 0) -> Int64 {
        let remaining = max(0, remainingBytes - min(max(0, reclaimableBytes), max(0, remainingBytes)))
        let result = remaining.addingReportingOverflow(bufferBytes)
        return result.overflow ? .max : result.partialValue
    }
    static func hasCapacity(_ availableBytes: Int64?, remainingBytes: Int64,
                            reclaimableBytes: Int64 = 0) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes >= requiredFreeBytes(remainingBytes: remainingBytes, reclaimableBytes: reclaimableBytes)
    }
}
