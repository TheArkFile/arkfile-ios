// This file is part of ArkFile and is licensed under GPL-3.0-or-later.

import Foundation

enum ArkFileLibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case allContent
    case includedSamples

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On this device"
        case .allContent: "All content"
        case .includedSamples: "Samples"
        }
    }
}

enum ArkFileLibraryDiscovery {
    private static let mapRegions = ArkFileMapRegionIndex.loadBundled()

    static func displayName(for item: ArkFileLibraryContentItem) -> String {
        guard item.type == .map else { return item.displayName }
        if let region = mapRegions?.regions.first(where: {
            $0.relativePath.caseInsensitiveCompare(item.relativePath) == .orderedSame
        }) {
            return region.displayName
        }
        return item.displayName
            .replacingOccurrences(of: #"^Street Map(?:\s*-\s*|\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" \(z[0-9]+\)$"#, with: "", options: .regularExpression)
    }

    static func includes(
        _ item: ArkFileLibraryContentItem,
        filter: ArkFileLibraryFilter,
        query: String
    ) -> Bool {
        switch filter {
        case .allContent:
            break
        case .onDevice:
            guard item.isInstalled || item.isSampleContent else { return false }
        case .includedSamples:
            guard item.isSampleContent else { return false }
        }
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let searchableText = [
            displayName(for: item),
            item.category.displayName,
            item.subcategory,
            item.summary ?? "",
            item.variantLabel ?? "",
            item.type == .map ? "Regional street map" : ""
        ].joined(separator: " ")
        return words.allSatisfy { word in
            searchableText.range(
                of: String(word),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    static func matchingItems(
        _ items: [ArkFileLibraryContentItem],
        filter: ArkFileLibraryFilter = .allContent,
        query: String
    ) -> [ArkFileLibraryContentItem] {
        items.filter { includes($0, filter: filter, query: query) }
    }
}
