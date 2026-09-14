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

import Foundation

struct ArkFileContentCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let product: String
    let description: String?
    let tiers: [String: String]
    let source: Source?
    let contentLicenses: ContentLicenses?
    let categories: [String: [ArkFileContentCatalogItem]]

    var liteItemCount: Int {
        itemCount(for: .lite)
    }

    var estimatedLiteBytes: Int64 {
        estimatedBytes(for: .lite)
    }

    func itemCount(for tier: ArkFileContentTier) -> Int {
        ArkFileLocalContentCategoryKey.allCases.reduce(0) { count, category in
            count + items(for: tier, category: category).count
        }
    }

    func estimatedBytes(for tier: ArkFileContentTier) -> Int64 {
        var seenPaths = Set<String>()
        var totalBytes: Int64 = 0
        for category in ArkFileLocalContentCategoryKey.allCases {
            for item in items(for: tier, category: category) {
                let path = item.normalizedRelativePath.lowercased()
                guard seenPaths.insert(path).inserted else { continue }
                totalBytes += item.sizeBytes
            }
        }
        return totalBytes
    }

    func items(for category: ArkFileLocalContentCategoryKey) -> [ArkFileContentCatalogItem] {
        (categories[category.rawValue] ?? []).filter(\.isAvailableInEssentials)
    }

    var allItems: [ArkFileContentCatalogItem] {
        ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            categories[category.rawValue] ?? []
        }
    }

    func items(for tier: ArkFileContentTier, category: ArkFileLocalContentCategoryKey) -> [ArkFileContentCatalogItem] {
        (categories[category.rawValue] ?? []).filter { $0.isAvailable(in: tier) }
    }

    func defaultExcludedItemKeys(for tier: ArkFileContentTier) -> Set<String> {
        var excluded = Set<String>()
        let groups = Dictionary(grouping: allItems.filter { $0.isAvailable(in: tier) }) { item in
            item.normalizedVariantGroup ?? ""
        }
        for (group, items) in groups where !group.isEmpty && items.count > 1 {
            // Exclusive variant groups (the full-Wikipedia variants) start fully
            // deselected: they are tens of gigabytes, so the user explicitly
            // chooses a variant in the review sheet. variantDefault still
            // decides which variant wins when a bulk re-include selects the
            // whole group at once.
            for item in items {
                excluded.insert(item.normalizedRelativePath.lowercased())
            }
        }
        for item in allItems where item.isAvailable(in: tier) && item.defaultSelected == false {
            excluded.insert(item.normalizedRelativePath.lowercased())
        }
        return excluded
    }

    static func loadBundled() throws -> ArkFileContentCatalog {
        let resourceName = "content-catalog"
        let resourceDirectory = "ArkFileContentCatalog"
        let bundles = candidateBundles()
        for bundle in bundles {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: resourceDirectory
            ) ?? bundle.url(forResource: resourceName, withExtension: "json") {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(ArkFileContentCatalog.self, from: data)
            }
        }
        throw ArkFileContentCatalogError.missingBundledCatalog
    }

    private static func candidateBundles() -> [Bundle] {
        let bundles = [
            Bundle.main,
            Bundle(for: ArkFileContentCatalogBundleMarker.self)
        ]
        var seenIdentifiers = Set<String>()
        return bundles.filter { bundle in
            let identifier = bundle.bundleIdentifier ?? bundle.bundleURL.fileSystemPath
            return seenIdentifiers.insert(identifier).inserted
        }
    }

    struct Source: Decodable, Hashable, Sendable {
        let desktopCatalogPath: String?
        let desktopCatalogSHA256: String?
        let desktopCommit: String?
    }

    struct ContentLicenses: Decodable, Hashable, Sendable {
        let ledgerVersion: String
        let projectionHash: String
        let coverageComplete: Bool
    }
}

struct ArkFileContentCatalogItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    let category: ArkFileLocalContentCategoryKey
    let subcategory: String
    let type: ArkFileLocalContentType
    let sizeBytes: Int64
    let availableInTiers: [String]
    let minimumTier: String
    let requiredPack: String
    let variantGroup: String?
    let variantLabel: String?
    let variantDefault: Bool?
    let defaultSelected: Bool?
    let summary: String?
    let licenseId: String?
    let licenseName: String?
    let licenseUrl: String?
    let sourceUrl: String?
    let attributionText: String?
    let changesMade: String?
    let contentLicenseLedgerVersion: String?
    let contentLicenseProjectionHash: String?
    let contentLicenseDecisionStatus: String?

    var isAvailableInEssentials: Bool {
        isAvailable(in: .lite)
    }

    func isAvailable(in tier: ArkFileContentTier) -> Bool {
        switch tier {
        case .lite:
            return minimumTier == ArkFileContentTier.lite.rawValue
                || requiredPack == "essentials"
                || availableInTiers.contains(ArkFileContentTier.lite.rawValue)
        case .complete:
            return minimumTier == ArkFileContentTier.complete.rawValue
                || requiredPack == "complete"
                || availableInTiers.contains(ArkFileContentTier.complete.rawValue)
                || isAvailable(in: .lite)
        case .standard:
            return minimumTier == ArkFileContentTier.standard.rawValue
                || requiredPack == "standard"
                || availableInTiers.contains(ArkFileContentTier.standard.rawValue)
        }
    }

    var normalizedRelativePath: String {
        relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var normalizedVariantGroup: String? {
        let normalized = variantGroup?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRelativePath = try container.decode(String.self, forKey: .relativePath)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !decodedRelativePath.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .relativePath,
                in: container,
                debugDescription: "Catalog item relativePath cannot be empty"
            )
        }

        let rawCategory = try container.decode(String.self, forKey: .category)
        guard let decodedCategory = ArkFileLocalContentCategoryKey(rawValue: rawCategory) else {
            throw DecodingError.dataCorruptedError(
                forKey: .category,
                in: container,
                debugDescription: "Unsupported ArkFile content category: \(rawCategory)"
            )
        }

        let rawType = try container.decode(String.self, forKey: .type)
        guard let decodedType = ArkFileLocalContentType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported ArkFile content type: \(rawType)"
            )
        }

        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? decodedRelativePath.lowercased()
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? URL(fileURLWithPath: decodedRelativePath).lastPathComponent
        relativePath = decodedRelativePath
        category = decodedCategory
        subcategory = try container.decodeIfPresent(String.self, forKey: .subcategory)
            ?? LocalString.arkfile_content_subcategory_other
        type = decodedType
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .size)
            ?? container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            ?? 0
        availableInTiers = try container.decodeIfPresent([String].self, forKey: .availableInTiers)
            ?? []
        minimumTier = try container.decodeIfPresent(String.self, forKey: .minimumTier)
            ?? ""
        requiredPack = try container.decodeIfPresent(String.self, forKey: .requiredPack)
            ?? ""
        variantGroup = try container.decodeIfPresent(String.self, forKey: .variantGroup)
        variantLabel = try container.decodeIfPresent(String.self, forKey: .variantLabel)
        variantDefault = try container.decodeIfPresent(Bool.self, forKey: .variantDefault)
        defaultSelected = try container.decodeIfPresent(Bool.self, forKey: .defaultSelected)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        licenseId = try container.decodeIfPresent(String.self, forKey: .licenseId)
        licenseName = try container.decodeIfPresent(String.self, forKey: .licenseName)
        licenseUrl = try container.decodeIfPresent(String.self, forKey: .licenseUrl)
        sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl)
        attributionText = try container.decodeIfPresent(String.self, forKey: .attributionText)
        changesMade = try container.decodeIfPresent(String.self, forKey: .changesMade)
        contentLicenseLedgerVersion = try container.decodeIfPresent(String.self, forKey: .contentLicenseLedgerVersion)
        contentLicenseProjectionHash = try container.decodeIfPresent(String.self, forKey: .contentLicenseProjectionHash)
        contentLicenseDecisionStatus = try container.decodeIfPresent(String.self, forKey: .contentLicenseDecisionStatus)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case relativePath
        case category
        case subcategory
        case type
        case size
        case sizeBytes
        case availableInTiers
        case minimumTier
        case requiredPack
        case variantGroup
        case variantLabel
        case variantDefault
        case defaultSelected
        case summary
        case licenseId
        case licenseName
        case licenseUrl
        case sourceUrl
        case attributionText
        case changesMade
        case contentLicenseLedgerVersion
        case contentLicenseProjectionHash
        case contentLicenseDecisionStatus
    }
}

enum ArkFileContentCatalogError: LocalizedError {
    case missingBundledCatalog

    var errorDescription: String? {
        switch self {
        case .missingBundledCatalog:
            "ArkFile content catalog is missing from the app bundle."
        }
    }
}

private final class ArkFileContentCatalogBundleMarker: NSObject {}
