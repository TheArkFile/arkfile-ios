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

import Foundation

/// The content selected by a catalog default. Counts keep title choices and
/// optional maps separate so merchandising never describes a regional map as a
/// book or reference title.
struct ArkFilePackDownloadSelectionMetrics: Equatable, Sendable {
    let titleSlotCount: Int
    let titleOptionCount: Int
    let mapCount: Int
    let bytes: Int64

    static let empty = ArkFilePackDownloadSelectionMetrics(
        titleSlotCount: 0,
        titleOptionCount: 0,
        mapCount: 0,
        bytes: 0
    )
}

/// Catalog scope for one iOS pack tier. `catalogBytesAcrossAllOptions` is not a
/// recommended download size: it deliberately includes every mutually
/// exclusive variant and every optional map. UI should normally present
/// `defaultSelection.bytes` instead.
struct ArkFilePackTierCatalogMetrics: Equatable, Sendable {
    let titleSlotCount: Int
    let titleOptionCount: Int
    let mapCount: Int
    let catalogBytesAcrossAllOptions: Int64
    let defaultSelection: ArkFilePackDownloadSelectionMetrics
}

/// A mutually exclusive catalog choice such as the full-Wikipedia editions.
/// Variant groups count as one title slot even though each downloadable option
/// has its own size.
struct ArkFilePackVariantGroupMetrics: Equatable, Identifiable, Sendable {
    let id: String
    let optionCount: Int
    let defaultSelectedOptionCount: Int
    let smallestOptionBytes: Int64
    let largestOptionBytes: Int64
}

/// Stable, catalog-derived facts used by the Essentials/Complete comparison.
/// Nothing here is a marketing constant, so a regenerated catalog updates the
/// card counts and safe starting-download estimate automatically.
struct ArkFilePackCatalogMetrics: Equatable, Sendable {
    let essentials: ArkFilePackTierCatalogMetrics
    let complete: ArkFilePackTierCatalogMetrics
    let completeAdditionalTitleSlotCount: Int
    let completeOptionalMapCount: Int
    let completeOptionalMapBytes: Int64
    let completeVariantGroups: [ArkFilePackVariantGroupMetrics]

    static func make(catalog: ArkFileContentCatalog) -> ArkFilePackCatalogMetrics {
        let essentialsItems = uniqueItems(in: catalog, tier: .lite)
        let completeItems = uniqueItems(in: catalog, tier: .complete)
        let essentialsDefaults = defaultSelection(
            from: essentialsItems,
            excludedKeys: catalog.defaultExcludedItemKeys(for: .lite)
        )
        let completeDefaultExcludedKeys = catalog.defaultExcludedItemKeys(for: .complete)
        let completeDefaults = defaultSelection(
            from: completeItems,
            excludedKeys: completeDefaultExcludedKeys
        )
        let essentialsTitleSlots = titleSlotKeys(in: essentialsItems)
        let completeTitleSlots = titleSlotKeys(in: completeItems)
        let optionalMaps = completeItems.filter {
            $0.type == .map && completeDefaultExcludedKeys.contains(itemKey($0))
        }

        let groupedVariants = Dictionary(
            grouping: completeItems.compactMap { item -> ArkFileContentCatalogItem? in
                item.normalizedVariantGroup == nil ? nil : item
            },
            by: { $0.normalizedVariantGroup ?? "" }
        )
        let variantGroups = groupedVariants.compactMap { groupID, items -> ArkFilePackVariantGroupMetrics? in
            guard !groupID.isEmpty, !items.isEmpty else { return nil }
            let optionBytes = items.map(\.sizeBytes)
            let defaultSelectedCount = items.filter {
                !completeDefaultExcludedKeys.contains(itemKey($0))
            }.count
            return ArkFilePackVariantGroupMetrics(
                id: groupID,
                optionCount: items.count,
                defaultSelectedOptionCount: defaultSelectedCount,
                smallestOptionBytes: optionBytes.min() ?? 0,
                largestOptionBytes: optionBytes.max() ?? 0
            )
        }
        .sorted { $0.id < $1.id }

        return ArkFilePackCatalogMetrics(
            essentials: tierMetrics(
                items: essentialsItems,
                defaultSelection: essentialsDefaults
            ),
            complete: tierMetrics(
                items: completeItems,
                defaultSelection: completeDefaults
            ),
            completeAdditionalTitleSlotCount: completeTitleSlots
                .subtracting(essentialsTitleSlots)
                .count,
            completeOptionalMapCount: optionalMaps.count,
            completeOptionalMapBytes: optionalMaps.reduce(0) { $0 + $1.sizeBytes },
            completeVariantGroups: variantGroups
        )
    }

    private static func tierMetrics(
        items: [ArkFileContentCatalogItem],
        defaultSelection: ArkFilePackDownloadSelectionMetrics
    ) -> ArkFilePackTierCatalogMetrics {
        let titleItems = items.filter { $0.type != .map }
        return ArkFilePackTierCatalogMetrics(
            titleSlotCount: titleSlotKeys(in: titleItems).count,
            titleOptionCount: titleItems.count,
            mapCount: items.filter { $0.type == .map }.count,
            catalogBytesAcrossAllOptions: items.reduce(0) { $0 + $1.sizeBytes },
            defaultSelection: defaultSelection
        )
    }

    private static func defaultSelection(
        from items: [ArkFileContentCatalogItem],
        excludedKeys: Set<String>
    ) -> ArkFilePackDownloadSelectionMetrics {
        let selectedItems = items.filter { !excludedKeys.contains(itemKey($0)) }
        let selectedTitles = selectedItems.filter { $0.type != .map }
        return ArkFilePackDownloadSelectionMetrics(
            titleSlotCount: titleSlotKeys(in: selectedTitles).count,
            titleOptionCount: selectedTitles.count,
            mapCount: selectedItems.filter { $0.type == .map }.count,
            bytes: selectedItems.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    private static func uniqueItems(
        in catalog: ArkFileContentCatalog,
        tier: ArkFileContentTier
    ) -> [ArkFileContentCatalogItem] {
        var seenKeys = Set<String>()
        return ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            catalog.items(for: tier, category: category)
        }
        .filter { seenKeys.insert(itemKey($0)).inserted }
    }

    private static func titleSlotKeys(
        in items: [ArkFileContentCatalogItem]
    ) -> Set<String> {
        Set(items.compactMap { item in
            guard item.type != .map else { return nil }
            if let variantGroup = item.normalizedVariantGroup {
                return "variant:\(variantGroup)"
            }
            return "title:\(itemKey(item))"
        })
    }

    private static func itemKey(_ item: ArkFileContentCatalogItem) -> String {
        item.normalizedRelativePath.lowercased()
    }
}
