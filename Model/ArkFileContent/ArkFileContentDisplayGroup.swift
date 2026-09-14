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

enum ArkFileContentDisplayGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case medical
    case foodPreparation
    case travel
    case streetMaps
    case booksDocuments
    case educationalTextbooks

    static let educationalTextbookSubcategory = "Open Textbooks"
    static let streetMapSubcategory = "Street-Level Maps (Complete)"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:
            ArkFileLocalContentCategoryKey.general.displayName
        case .medical:
            ArkFileLocalContentCategoryKey.medical.displayName
        case .foodPreparation:
            ArkFileLocalContentCategoryKey.foodPreparation.displayName
        case .travel:
            ArkFileLocalContentCategoryKey.travel.displayName
        case .streetMaps:
            "Regional Street Maps"
        case .booksDocuments:
            ArkFileLocalContentCategoryKey.booksDocuments.displayName
        case .educationalTextbooks:
            "Educational Textbooks"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            ArkFileLocalContentCategoryKey.general.systemImage
        case .medical:
            ArkFileLocalContentCategoryKey.medical.systemImage
        case .foodPreparation:
            ArkFileLocalContentCategoryKey.foodPreparation.systemImage
        case .travel:
            ArkFileLocalContentCategoryKey.travel.systemImage
        case .streetMaps:
            "map.fill"
        case .booksDocuments:
            ArkFileLocalContentCategoryKey.booksDocuments.systemImage
        case .educationalTextbooks:
            "graduationcap"
        }
    }

    static func group(for category: ArkFileLocalContentCategoryKey) -> ArkFileContentDisplayGroup {
        switch category {
        case .general:
            .general
        case .medical:
            .medical
        case .foodPreparation:
            .foodPreparation
        case .travel:
            .travel
        case .booksDocuments:
            .booksDocuments
        }
    }

    static func group(
        for item: ArkFileLibraryContentItem,
        educationalTextbookKeys: Set<String>
    ) -> ArkFileContentDisplayGroup {
        if item.type == .map,
           item.subcategory == streetMapSubcategory {
            return .streetMaps
        }
        if item.category == .booksDocuments,
           educationalTextbookKeys.contains(item.id) {
            return .educationalTextbooks
        }
        return group(for: item.category)
    }

    static func group(for item: ArkFileContentCatalogItem) -> ArkFileContentDisplayGroup {
        if item.type == .map,
           item.subcategory == streetMapSubcategory {
            return .streetMaps
        }
        if item.category == .booksDocuments,
           item.subcategory == educationalTextbookSubcategory {
            return .educationalTextbooks
        }
        return group(for: item.category)
    }

    @MainActor
    static func educationalTextbookKeys(in catalog: ArkFileContentCatalog) -> Set<String> {
        Set(catalog.allItems.compactMap { item in
            guard group(for: item) == .educationalTextbooks else { return nil }
            return ArkFileLocalContentLibrary.canonicalCatalogItemKey(for: item)
        })
    }
}

struct ArkFileContentDisplaySectionSummary: Hashable, Sendable {
    let totalCount: Int
    let installedCount: Int
    let notDownloadedCount: Int
    let lockedCount: Int
    let totalBytes: Int64
    let installedBytes: Int64
    let selectedCount: Int
    let selectedBytes: Int64

    var missingAccessSummaryParts: [String] {
        var parts: [String] = []
        if lockedCount > 0 {
            parts.append("\(lockedCount) locked")
        }
        if notDownloadedCount > 0 {
            parts.append("\(notDownloadedCount) not downloaded")
        }
        return parts
    }

    static let empty = ArkFileContentDisplaySectionSummary(
        totalCount: 0,
        installedCount: 0,
        notDownloadedCount: 0,
        lockedCount: 0,
        totalBytes: 0,
        installedBytes: 0,
        selectedCount: 0,
        selectedBytes: 0
    )

    static func library(
        items: [ArkFileLibraryContentItem],
        catalogKeys: Set<String>,
        resolutionInput: ArkFileLockedContentResolutionInput? = nil
    ) -> ArkFileContentDisplaySectionSummary {
        let managedItems = items.filter { item in
            !item.isSampleContent
                && (catalogKeys.isEmpty || catalogKeys.contains(item.id))
        }
        let installed = managedItems.filter(\.isInstalled)
        let missing = managedItems.filter { !$0.isInstalled }
        let notDownloaded: [ArkFileLibraryContentItem]
        let locked: [ArkFileLibraryContentItem]
        if let resolutionInput {
            notDownloaded = missing.filter {
                ArkFileLockedContentPresentation.resolve(
                    item: $0,
                    input: resolutionInput
                ).accessState == .downloadable
            }
            locked = missing.filter {
                ArkFileLockedContentPresentation.resolve(
                    item: $0,
                    input: resolutionInput
                ).accessState == .locked
            }
        } else {
            notDownloaded = []
            locked = missing
        }
        return ArkFileContentDisplaySectionSummary(
            totalCount: managedItems.count,
            installedCount: installed.count,
            notDownloadedCount: notDownloaded.count,
            lockedCount: locked.count,
            totalBytes: managedItems.reduce(0) { $0 + $1.sizeBytes },
            installedBytes: installed.reduce(0) { $0 + $1.sizeBytes },
            selectedCount: managedItems.count,
            selectedBytes: managedItems.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    static func selection<Item>(
        items: [Item],
        excludedKeys: Set<String>,
        key: (Item) -> String,
        sizeBytes: (Item) -> Int64
    ) -> ArkFileContentDisplaySectionSummary {
        let normalizedExclusions = Set(excludedKeys.map { $0.lowercased() })
        let selected = items.filter { !normalizedExclusions.contains(key($0).lowercased()) }
        return ArkFileContentDisplaySectionSummary(
            totalCount: items.count,
            installedCount: 0,
            notDownloadedCount: 0,
            lockedCount: 0,
            totalBytes: items.reduce(0) { $0 + sizeBytes($1) },
            installedBytes: 0,
            selectedCount: selected.count,
            selectedBytes: selected.reduce(0) { $0 + sizeBytes($1) }
        )
    }
}

/// Selection summaries count mutually exclusive variants as one choice. This
/// keeps a category's Select All / Deselect All control truthful when, for
/// example, only one full-Wikipedia variant may be selected at a time.
struct ArkFileSelectableSlotMetrics: Equatable, Sendable {
    let totalSlotCount: Int
    let selectedSlotCount: Int

    var allSlotsSelected: Bool {
        totalSlotCount > 0 && selectedSlotCount == totalSlotCount
    }

    static func make<Item>(
        items: [Item],
        excludedKeys: Set<String>,
        key: (Item) -> String,
        variantGroup: (Item) -> String?
    ) -> ArkFileSelectableSlotMetrics {
        let normalizedExclusions = Set(excludedKeys.map { $0.lowercased() })
        let ordinaryItems = items.filter { normalizedVariantGroup(variantGroup($0)) == nil }
        let groupedItems = Dictionary(
            grouping: items.filter { normalizedVariantGroup(variantGroup($0)) != nil }
        ) { item in
            normalizedVariantGroup(variantGroup(item)) ?? ""
        }
        let selectedOrdinaryCount = ordinaryItems.reduce(into: 0) { count, item in
            if !normalizedExclusions.contains(key(item).lowercased()) {
                count += 1
            }
        }
        let selectedVariantSlotCount = groupedItems.values.reduce(into: 0) { count, members in
            if members.contains(where: {
                !normalizedExclusions.contains(key($0).lowercased())
            }) {
                count += 1
            }
        }
        return ArkFileSelectableSlotMetrics(
            totalSlotCount: ordinaryItems.count + groupedItems.count,
            selectedSlotCount: selectedOrdinaryCount + selectedVariantSlotCount
        )
    }

    static func exclusionsSelectingAll<Item>(
        currentExclusions: Set<String>,
        items: [Item],
        key: (Item) -> String,
        variantGroup: (Item) -> String?,
        variantDefault: (Item) -> Bool
    ) -> Set<String> {
        var exclusions = Set(currentExclusions.map { $0.lowercased() })
        let ordinaryItems = items.filter { normalizedVariantGroup(variantGroup($0)) == nil }
        exclusions.subtract(ordinaryItems.map { key($0).lowercased() })

        let groupedItems = Dictionary(
            grouping: items.filter { normalizedVariantGroup(variantGroup($0)) != nil }
        ) { item in
            normalizedVariantGroup(variantGroup(item)) ?? ""
        }
        for members in groupedItems.values {
            let keys = members.map { key($0).lowercased() }
            exclusions.formUnion(keys)
            if let selected = members.first(where: variantDefault) ?? members.first {
                exclusions.remove(key(selected).lowercased())
            }
        }
        return exclusions
    }

    /// Normalizes mutually exclusive choices after any UI mutation. An
    /// explicitly selected missing alternative wins; otherwise an installed
    /// choice remains selected because the review screen cannot remove it.
    /// When no member is installed, excluding every member is a valid "none"
    /// choice for large optional variants such as full Wikipedia.
    static func exclusionsEnforcingExclusiveVariants<Item>(
        currentExclusions: Set<String>,
        items: [Item],
        key: (Item) -> String,
        variantGroup: (Item) -> String?,
        variantDefault: (Item) -> Bool,
        isInstalled: (Item) -> Bool
    ) -> Set<String> {
        var exclusions = Set(currentExclusions.map { $0.lowercased() })
        let groupedItems = Dictionary(
            grouping: items.filter { normalizedVariantGroup(variantGroup($0)) != nil }
        ) { item in
            normalizedVariantGroup(variantGroup(item)) ?? ""
        }
        for members in groupedItems.values {
            let selectedInstalled = members.first {
                isInstalled($0) && !exclusions.contains(key($0).lowercased())
            }
            let selectedMissing = members.filter {
                !isInstalled($0) && !exclusions.contains(key($0).lowercased())
            }
            // A legacy or malformed saved selection may leave both an installed
            // variant and a missing sibling selected. Preserve the installed
            // choice in that ambiguous state. The row toggle explicitly excludes
            // every sibling before selecting a missing alternative, so a genuine
            // user switch still wins here.
            let itemToKeep = selectedInstalled
                ?? selectedMissing.first(where: variantDefault)
                ?? selectedMissing.first
                ?? members.first(where: isInstalled)
            exclusions.formUnion(members.map { key($0).lowercased() })
            if let itemToKeep {
                exclusions.remove(key(itemToKeep).lowercased())
            }
        }
        return exclusions
    }

    private static func normalizedVariantGroup(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct ArkFileHomePackCardMetrics: Equatable, Sendable {
    let installedEssentialsTitleCount: Int
    let installedCompleteTitleCount: Int
    let installedStreetMapCount: Int
    let availableStreetMapCount: Int

    var completeReadyLine: String {
        var parts = [
            Self.pluralized(installedCompleteTitleCount, singular: "title", plural: "titles") + " offline"
        ]
        if installedStreetMapCount > 0 {
            parts.append(Self.pluralized(installedStreetMapCount, singular: "street map", plural: "street maps") + " offline")
        }
        if availableStreetMapCount > 0 {
            parts.append(Self.pluralized(availableStreetMapCount, singular: "street map", plural: "street maps") + " available")
        }
        return "Complete is ready on this device — \(parts.joined(separator: ", "))."
    }

    var essentialsReadyLine: String {
        "Essentials is ready offline on this device — \(Self.pluralized(installedEssentialsTitleCount, singular: "title", plural: "titles")) offline."
    }

    static func make(items: [ArkFileLibraryContentItem]) -> ArkFileHomePackCardMetrics {
        let managedItems = items.filter {
            !$0.isBundledSampleAsset && $0.requiredTier.isIOSInstallable
        }
        let installedTitles = managedItems.filter { $0.isInstalled && $0.type != .map }
        let streetMaps = managedItems.filter { item in
            item.type == .map
                && item.subcategory == ArkFileContentDisplayGroup.streetMapSubcategory
        }
        return ArkFileHomePackCardMetrics(
            installedEssentialsTitleCount: installedTitles.filter { $0.requiredTier == .lite }.count,
            installedCompleteTitleCount: installedTitles.filter {
                $0.requiredTier == .lite || $0.requiredTier == .complete
            }.count,
            installedStreetMapCount: streetMaps.filter(\.isInstalled).count,
            availableStreetMapCount: streetMaps.filter { !$0.isInstalled }.count
        )
    }

    private static func pluralized(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

/// Counts the library rows shown by Manage Downloads without treating bundled
/// samples folded into pack presentation as downloaded titles.
struct ArkFileDownloadManagerInstalledSummary: Equatable, Sendable {
    let includedSampleCount: Int
    let installedTitleCount: Int
    let installedMapCount: Int
    let installedTitleBytes: Int64

    var countSummary: String {
        var parts: [String] = []
        if includedSampleCount > 0 {
            parts.append("\(includedSampleCount) included sample\(includedSampleCount == 1 ? "" : "s")")
        }
        parts.append("\(installedTitleCount) pack title\(installedTitleCount == 1 ? "" : "s")")
        if installedMapCount > 0 {
            parts.append("\(installedMapCount) offline map\(installedMapCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    static func make(items: [ArkFileLibraryContentItem]) -> Self {
        var seenIDs = Set<String>()
        let installed = items.filter { $0.isInstalled && seenIDs.insert($0.id).inserted }
        let samples = installed.filter(\.isBundledSampleAsset)
        let downloaded = installed.filter { !$0.isBundledSampleAsset }
        let titles = downloaded.filter { $0.type != .map }
        return Self(
            includedSampleCount: samples.count,
            installedTitleCount: titles.count,
            installedMapCount: downloaded.filter { $0.type == .map }.count,
            installedTitleBytes: titles.reduce(0) { $0 + $1.sizeBytes }
        )
    }
}

/// Device coverage for the current Complete catalog. Retained files are not in
/// the denominator, and mutually-exclusive variants (currently full
/// Wikipedia) count as one slot so a user can actually reach 100% coverage.
struct ArkFileCompleteOwnershipMetrics: Equatable, Sendable {
    let installedTitleSlots: Int
    let availableTitleSlots: Int
    let installedMapCount: Int
    let availableMapCount: Int

    static let empty = ArkFileCompleteOwnershipMetrics(
        installedTitleSlots: 0,
        availableTitleSlots: 0,
        installedMapCount: 0,
        availableMapCount: 0
    )

    var purchasedSummary: String {
        guard availableTitleSlots > 0 else {
            return "Purchased. Manage what you want stored on this device."
        }
        let titleVerb = installedTitleSlots == 1 ? "is" : "are"
        var sentences = [
            "Purchased. \(installedTitleSlots) of \(availableTitleSlots) titles \(titleVerb) on this device."
        ]
        if availableMapCount > 0 {
            let mapVerb = installedMapCount == 1 ? "is" : "are"
            sentences.append(
                "\(installedMapCount) of \(availableMapCount) optional regional street maps \(mapVerb) on this device."
            )
        }
        return sentences.joined(separator: " ")
    }

    static func make(
        catalog: ArkFileContentCatalog?,
        libraryItems: [ArkFileLibraryContentItem]
    ) -> ArkFileCompleteOwnershipMetrics {
        guard let catalog else { return .empty }
        let installedKeys = Set(libraryItems.filter(\.isInstalled).map(\.id))
        let completeItems = catalog.allItems.filter { $0.isAvailable(in: .complete) }
        let titleItems = completeItems.filter { $0.type != .map }
        let mapItems = completeItems.filter { $0.type == .map }

        var titleSlots: [String: [ArkFileContentCatalogItem]] = [:]
        for item in titleItems {
            let slot = item.normalizedVariantGroup.map { "variant:\($0)" }
                ?? "title:\(item.normalizedRelativePath.lowercased())"
            titleSlots[slot, default: []].append(item)
        }
        let installedTitleSlots = titleSlots.values.filter { items in
            items.contains { installedKeys.contains($0.normalizedRelativePath.lowercased()) }
        }.count
        let installedMapCount = mapItems.filter {
            installedKeys.contains($0.normalizedRelativePath.lowercased())
        }.count

        return ArkFileCompleteOwnershipMetrics(
            installedTitleSlots: installedTitleSlots,
            availableTitleSlots: titleSlots.count,
            installedMapCount: installedMapCount,
            availableMapCount: mapItems.count
        )
    }
}

/// Keeps device presence, pack availability, and the next download selection
/// separate in Manage Downloads. In particular, "nothing selected" must never
/// imply that an installed title or optional regional map is absent.
struct ArkFileManagedDownloadGroupMetrics: Equatable, Sendable {
    let totalCount: Int
    let installedCount: Int
    let availableToDownloadCount: Int
    let selectedToDownloadCount: Int

    var summaryText: String {
        guard totalCount > 0 else { return "No content" }
        if installedCount == totalCount {
            return "All \(totalCount) on this device"
        }
        let coverage = "\(installedCount) of \(totalCount) on this device"
        if selectedToDownloadCount > 0 {
            return "\(coverage) · \(selectedToDownloadCount) selected"
        }
        return "\(coverage) · \(availableToDownloadCount) available"
    }

    static func make<Item>(
        items: [Item],
        isInstalled: (Item) -> Bool,
        isSelected: (Item) -> Bool
    ) -> ArkFileManagedDownloadGroupMetrics {
        let installedCount = items.filter(isInstalled).count
        let missing = items.filter { !isInstalled($0) }
        return ArkFileManagedDownloadGroupMetrics(
            totalCount: items.count,
            installedCount: installedCount,
            availableToDownloadCount: missing.count,
            selectedToDownloadCount: missing.filter(isSelected).count
        )
    }
}

/// Presentation-only grouping for Manage Downloads. Array filtering preserves
/// catalog order, so changing a row's checkmark never moves that row away from
/// the user's finger. Installed content remains a separate, non-toggleable
/// group.
struct ArkFileManagedDownloadPresentation {
    static let selectionGroupTitle = "Choose Downloads"
    static let installedGroupTitle = "On This Device"

    static func missingItems<Item>(
        from items: [Item],
        isInstalled: (Item) -> Bool
    ) -> [Item] {
        items.filter { !isInstalled($0) }
    }

    static func installedItems<Item>(
        from items: [Item],
        isInstalled: (Item) -> Bool
    ) -> [Item] {
        items.filter(isInstalled)
    }
}

/// Keeps dedicated mutually-exclusive choices out of the ordinary catalog
/// groups while preserving one shared item collection for selection totals and
/// confirmation. This prevents Full Wikipedia from appearing as two separate
/// interactive surfaces.
struct ArkFilePackSelectionPresentation {
    static func catalogGroupItems<Item>(
        from items: [Item],
        variantGroup: (Item) -> String?
    ) -> [Item] {
        items.filter { normalizedVariantGroup(variantGroup($0)) == nil }
    }

    static func dedicatedVariantItems<Item>(
        from items: [Item],
        variantGroup: (Item) -> String?
    ) -> [Item] {
        items.filter { normalizedVariantGroup(variantGroup($0)) != nil }
    }

    static func itemGroupLabel(
        displayGroup: ArkFileContentDisplayGroup,
        catalogSubcategory: String
    ) -> String {
        displayGroup == .streetMaps ? displayGroup.displayName : catalogSubcategory
    }

    private static func normalizedVariantGroup(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Stable initial ordering/expansion for the Complete download manager. The
/// plan is computed once when the catalog loads so toggling a row never makes
/// its category jump around underneath the user's finger.
struct ArkFileDownloadReviewGroupPlan: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        let id: String
        let selectedMissingCount: Int
        let selectedIncludedCount: Int
    }

    let orderedGroupIDs: [String]
    let expandedGroupIDs: Set<String>
    let expandedIncludedGroupIDs: Set<String>

    static func initialExclusions(
        saved: Set<String>?,
        defaults: Set<String>
    ) -> Set<String> {
        saved ?? defaults
    }

    static func make(inputs: [Input]) -> ArkFileDownloadReviewGroupPlan {
        let selected = inputs.filter { $0.selectedMissingCount > 0 }
        let unselected = inputs.filter { $0.selectedMissingCount == 0 }
        return ArkFileDownloadReviewGroupPlan(
            orderedGroupIDs: (selected + unselected).map(\.id),
            expandedGroupIDs: Set(selected.map(\.id)),
            expandedIncludedGroupIDs: Set(
                selected.filter { $0.selectedIncludedCount > 0 }.map(\.id)
            )
        )
    }
}

struct ArkFileContentDisplayLibrarySection: Identifiable, Hashable, Sendable {
    var id: String { group.id }

    let group: ArkFileContentDisplayGroup
    let items: [ArkFileLibraryContentItem]
    let summary: ArkFileContentDisplaySectionSummary

    @MainActor
    static func makeSections(
        from categories: [ArkFileLibraryContentCategory],
        catalog: ArkFileContentCatalog?,
        resolutionInput: ArkFileLockedContentResolutionInput? = nil
    ) -> [ArkFileContentDisplayLibrarySection] {
        let educationalKeys = catalog.map(ArkFileContentDisplayGroup.educationalTextbookKeys(in:)) ?? []
        let catalogKeys = catalog.map(Self.catalogKeys(in:)) ?? []
        var groupedItems: [ArkFileContentDisplayGroup: [ArkFileLibraryContentItem]] = [:]
        for item in categories.flatMap(\.items) {
            let group = ArkFileContentDisplayGroup.group(
                for: item,
                educationalTextbookKeys: educationalKeys
            )
            groupedItems[group, default: []].append(item)
        }
        return ArkFileContentDisplayGroup.allCases.compactMap { group in
            guard let items = groupedItems[group], !items.isEmpty else { return nil }
            let sortedItems = items.sorted {
                if $0.subcategory != $1.subcategory {
                    return $0.subcategory.localizedCaseInsensitiveCompare($1.subcategory) == .orderedAscending
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return ArkFileContentDisplayLibrarySection(
                group: group,
                items: sortedItems,
                summary: .library(
                    items: sortedItems,
                    catalogKeys: catalogKeys,
                    resolutionInput: resolutionInput
                )
            )
        }
    }

    /// Regional map archives are managed from Downloads and from the map's
    /// zoom-aware prompt. They are intentionally omitted from the browseable
    /// home library because a PMTiles archive is not directly readable there.
    static func mainLibrarySections(
        from sections: [ArkFileContentDisplayLibrarySection]
    ) -> [ArkFileContentDisplayLibrarySection] {
        sections.filter { $0.group != .streetMaps }
    }

    @MainActor
    static func completeCatalogBackedCategories(
        installedCategories: [ArkFileLocalContentCategory],
        fallbackCategories: [ArkFileLibraryContentCategory],
        catalog: ArkFileContentCatalog?
    ) -> [ArkFileLibraryContentCategory] {
        guard let catalog else { return fallbackCategories }
        return ArkFileLocalContentLibrary.merge(
            installedCategories: installedCategories,
            catalog: catalog,
            tier: .complete
        )
    }

    @MainActor
    static func catalogKeys(in catalog: ArkFileContentCatalog) -> Set<String> {
        Set(catalog.allItems.compactMap {
            ArkFileLocalContentLibrary.canonicalCatalogItemKey(for: $0)
        })
    }
}
