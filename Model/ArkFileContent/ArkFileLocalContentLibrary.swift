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
#if os(iOS)
import UIKit
#endif

enum ArkFileLocalPathAvailability: Equatable, Sendable {
    case available
    case definitivelyMissing
    case temporarilyUnavailable
}

enum ArkFileLocalPathProbe {
    nonisolated static func availability(
        of url: URL,
        expectedDirectory: Bool? = nil
    ) -> ArkFileLocalPathAvailability {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if let expectedDirectory {
                let hasExpectedKind = expectedDirectory
                    ? values.isDirectory == true
                    : values.isRegularFile == true
                guard hasExpectedKind else { return .definitivelyMissing }
            }
            return .available
        } catch {
            return availability(for: error)
        }
    }

    nonisolated static func availability(for error: Error) -> ArkFileLocalPathAvailability {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return .definitivelyMissing
        }
        if error.domain == NSCocoaErrorDomain,
           (error.code == NSFileNoSuchFileError
            || error.code == NSFileReadNoSuchFileError) {
            return .definitivelyMissing
        }
        return .temporarilyUnavailable
    }
}

@MainActor
enum ArkFileProtectedDataAvailability {
    static var isAvailable: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}

enum ArkFileLocalContentType: String, Codable, CaseIterable, Hashable, Sendable {
    case zim
    case pdf
    case htmlBook = "htmlbook"
    case image
    case html
    case map

    var displayLabel: String {
        switch self {
        case .zim:
            "Library"
        case .pdf:
            "PDF"
        case .htmlBook:
            "Book"
        case .image:
            "Image"
        case .html:
            "HTML"
        case .map:
            "Map"
        }
    }

    var systemImage: String {
        switch self {
        case .zim:
            "book.closed"
        case .pdf:
            "doc.richtext"
        case .htmlBook:
            "books.vertical"
        case .image:
            "photo"
        case .html:
            "safari"
        case .map:
            "map"
        }
    }
}

enum ArkFileLocalContentCategoryKey: String, CaseIterable, Codable, Hashable, Sendable {
    case general
    case medical
    case foodPreparation = "food-preparation"
    case travel
    case booksDocuments = "books_documents"

    var displayName: String {
        switch self {
        case .general:
            LocalString.arkfile_content_category_general
        case .medical:
            LocalString.arkfile_content_category_medical
        case .foodPreparation:
            LocalString.arkfile_content_category_food_preparation
        case .travel:
            LocalString.arkfile_content_category_travel
        case .booksDocuments:
            LocalString.arkfile_content_category_books_documents
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "archivebox"
        case .medical:
            "cross.case"
        case .foodPreparation:
            "fork.knife"
        case .travel:
            "map"
        case .booksDocuments:
            "books.vertical"
        }
    }

    var folderAliases: [String] {
        switch self {
        case .booksDocuments:
            [
                rawValue,
                "Books_documents",
                "books",
                "Books",
                "documents",
                "Documents",
                "Books & Documents"
            ]
        case .foodPreparation:
            [
                rawValue,
                "Food-preparation",
                "food_preparation",
                "Food Preparation",
                "Food_Preparation"
            ]
        default:
            [rawValue, rawValue.capitalized]
        }
    }
}

struct ArkFileLocalContentItem: Identifiable, Hashable, Sendable {
    var id: String { relativePath }

    let name: String
    let url: URL
    let relativePath: String
    let type: ArkFileLocalContentType
    let category: ArkFileLocalContentCategoryKey
    let subcategory: String
    let sizeBytes: Int64
    let isSampleContent: Bool
    let sampleOriginalSubcategory: String?
    /// Immutable provenance. Unlike `isSampleContent`, this remains true when
    /// the sample is presented inside an installed pack.
    let isBundledSampleAsset: Bool

    init(
        name: String,
        url: URL,
        relativePath: String,
        type: ArkFileLocalContentType,
        category: ArkFileLocalContentCategoryKey,
        subcategory: String,
        sizeBytes: Int64,
        isSampleContent: Bool,
        sampleOriginalSubcategory: String?,
        isBundledSampleAsset: Bool = false
    ) {
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.type = type
        self.category = category
        self.subcategory = subcategory
        self.sizeBytes = sizeBytes
        self.isSampleContent = isSampleContent
        self.sampleOriginalSubcategory = sampleOriginalSubcategory
        self.isBundledSampleAsset = isBundledSampleAsset
    }

    var displayName: String {
        ArkFileContentDisplayName.displayName(for: name, relativePath: relativePath)
    }

    /// Distribution retirement never changes or removes the local file. This
    /// computed flag keeps the device copy readable while allowing the UI and
    /// Local Sharing policy to explain that ArkFile no longer distributes it.
    var isNoLongerDistributedByArkFile: Bool {
        ArkFileContentRetirementPolicy.isRetired(relativePath: relativePath)
    }
}

struct ArkFileLocalContentCategory: Identifiable, Hashable, Sendable {
    var id: ArkFileLocalContentCategoryKey { key }

    let key: ArkFileLocalContentCategoryKey
    let items: [ArkFileLocalContentItem]

    var displayName: String {
        key.displayName
    }
}

struct ArkFileLibraryContentItem: Identifiable, Hashable, Sendable {
    var id: String { relativePath.lowercased() }

    let name: String
    let url: URL?
    let relativePath: String
    let type: ArkFileLocalContentType
    let category: ArkFileLocalContentCategoryKey
    let subcategory: String
    let sizeBytes: Int64
    let isInstalled: Bool
    let requiredTier: ArkFileContentTier
    let requiredPackName: String
    let isSampleContent: Bool
    let sampleOriginalSubcategory: String?
    let isBundledSampleAsset: Bool
    let variantGroup: String?
    let variantLabel: String?
    let variantDefault: Bool
    let summary: String?

    var isLocked: Bool {
        !isInstalled
    }

    var displayName: String {
        ArkFileContentDisplayName.displayName(for: name, relativePath: relativePath)
    }

    var isNoLongerDistributedByArkFile: Bool {
        ArkFileContentRetirementPolicy.isRetired(relativePath: relativePath)
    }

    var localItem: ArkFileLocalContentItem? {
        guard let url else { return nil }
        return ArkFileLocalContentItem(
            name: name,
            url: url,
            relativePath: relativePath,
            type: type,
            category: category,
            subcategory: subcategory,
            sizeBytes: sizeBytes,
            isSampleContent: isSampleContent,
            sampleOriginalSubcategory: sampleOriginalSubcategory,
            isBundledSampleAsset: isBundledSampleAsset
        )
    }

    private init(
        name: String,
        url: URL?,
        relativePath: String,
        type: ArkFileLocalContentType,
        category: ArkFileLocalContentCategoryKey,
        subcategory: String,
        sizeBytes: Int64,
        isInstalled: Bool,
        requiredTier: ArkFileContentTier,
        requiredPackName: String,
        isSampleContent: Bool = false,
        sampleOriginalSubcategory: String? = nil,
        isBundledSampleAsset: Bool = false,
        variantGroup: String? = nil,
        variantLabel: String? = nil,
        variantDefault: Bool = false,
        summary: String? = nil
    ) {
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.type = type
        self.category = category
        self.subcategory = subcategory
        self.sizeBytes = sizeBytes
        self.isInstalled = isInstalled
        self.requiredTier = requiredTier
        self.requiredPackName = requiredPackName
        self.isSampleContent = isSampleContent
        self.sampleOriginalSubcategory = sampleOriginalSubcategory
        self.isBundledSampleAsset = isBundledSampleAsset
        self.variantGroup = variantGroup
        self.variantLabel = variantLabel
        self.variantDefault = variantDefault
        self.summary = summary
    }

    init(
        installed item: ArkFileLocalContentItem,
        requiredPackName: String = "ArkFile Essentials",
        requiredTier: ArkFileContentTier? = nil,
        variantGroup: String? = nil,
        variantLabel: String? = nil,
        variantDefault: Bool = false,
        summary: String? = nil
    ) {
        self.init(
            name: item.name,
            url: item.url,
            relativePath: item.relativePath,
            type: item.type,
            category: item.category,
            subcategory: item.subcategory,
            sizeBytes: item.sizeBytes,
            isInstalled: true,
            requiredTier: requiredTier ?? (requiredPackName == "ArkFile Complete" ? .complete : .lite),
            requiredPackName: requiredPackName,
            isSampleContent: item.isSampleContent,
            sampleOriginalSubcategory: item.sampleOriginalSubcategory,
            isBundledSampleAsset: item.isBundledSampleAsset,
            variantGroup: variantGroup,
            variantLabel: variantLabel,
            variantDefault: variantDefault,
            summary: summary
        )
    }

    init(catalog item: ArkFileContentCatalogItem, installedItem: ArkFileLocalContentItem?) {
        let requiredTier: ArkFileContentTier = item.isAvailableInEssentials ? .lite : .complete
        let requiredPackName = requiredTier == .complete ? "ArkFile Complete" : "ArkFile Essentials"
        if let installedItem {
            self.init(
                name: item.name,
                url: installedItem.url,
                relativePath: item.normalizedRelativePath,
                type: item.type,
                category: item.category,
                subcategory: item.subcategory,
                sizeBytes: installedItem.sizeBytes,
                isInstalled: true,
                requiredTier: requiredTier,
                requiredPackName: requiredPackName,
                isSampleContent: installedItem.isSampleContent,
                sampleOriginalSubcategory: installedItem.sampleOriginalSubcategory,
                isBundledSampleAsset: installedItem.isBundledSampleAsset,
                variantGroup: item.normalizedVariantGroup,
                variantLabel: item.variantLabel,
                variantDefault: item.variantDefault == true,
                summary: item.summary
            )
        } else {
            self.init(
                name: item.name,
                url: nil,
                relativePath: item.normalizedRelativePath,
                type: item.type,
                category: item.category,
                subcategory: item.subcategory,
                sizeBytes: item.sizeBytes,
                isInstalled: false,
                requiredTier: requiredTier,
                requiredPackName: requiredPackName,
                variantGroup: item.normalizedVariantGroup,
                variantLabel: item.variantLabel,
                variantDefault: item.variantDefault == true,
                summary: item.summary
            )
        }
    }
}

enum ArkFileContentDisplayName {
    private static let sampleWikipediaDisplayName = "Wikipedia Top 100 Articles (No Images), April 2026"

    private static let displayNameOverridesByRelativePath: [String: String] = [
        "general/practical-skills/electonics and electrical engineering - stack exchange.zim": "Electronics and Electrical Engineering - Stack Exchange",
        "general/encyclopedias/wikipedia_en_100_nopic_2026-04.zim": sampleWikipediaDisplayName
    ]

    private static let displayNameOverridesByName: [String: String] = [
        "electonics and electrical engineering - stack exchange.zim": "Electronics and Electrical Engineering - Stack Exchange",
        "wikipedia_en_100_nopic_2026-04.zim": sampleWikipediaDisplayName,
        "wikipedia en 100 nopic 2026 04": sampleWikipediaDisplayName
    ]

    static func displayName(for rawName: String, relativePath: String? = nil) -> String {
        if let relativePath,
           let override = displayNameOverridesByRelativePath[normalizedDisplayKey(relativePath)] {
            return override
        }
        if let override = displayNameOverridesByName[normalizedDisplayKey(rawName)] {
            return override
        }
        let extensionless = (rawName as NSString).deletingPathExtension
        let cleaned = extensionless
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override = displayNameOverridesByName[normalizedDisplayKey(cleaned)] {
            return override
        }
        guard !cleaned.isEmpty else {
            return rawName
        }
        if cleaned == cleaned.uppercased(), cleaned.count > 8 {
            return cleaned.localizedCapitalized
        }
        return cleaned
    }

    private static func normalizedDisplayKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ArkFileLibraryContentCategory: Identifiable, Hashable, Sendable {
    var id: ArkFileLocalContentCategoryKey { key }

    let key: ArkFileLocalContentCategoryKey
    let items: [ArkFileLibraryContentItem]

    var displayName: String {
        key.displayName
    }

    var installedCount: Int {
        items.filter(\.isInstalled).count
    }

    var lockedCount: Int {
        items.filter(\.isLocked).count
    }
}

struct ArkFileContentCatalogCoverage: Equatable, Sendable {
    let installedCount: Int
    let expectedCount: Int

    var hasExpectedCatalog: Bool {
        expectedCount > 0
    }
}

enum ArkFileSampleContentMode: Sendable {
    case none
    case visibleSample
    case foldedIntoPack
}

@MainActor
final class ArkFileLocalContentLibrary: ObservableObject {
    static let shared = ArkFileLocalContentLibrary()

    @Published private(set) var categories: [ArkFileLocalContentCategory] = []
    @Published private(set) var libraryCategories: [ArkFileLibraryContentCategory] = []
    @Published private(set) var contentRoot: URL?
    @Published private(set) var bundledCatalogItemCount = 0
    @Published private(set) var installedCatalogItemCount = 0
    /// Advances only after one coherent library refresh has published its
    /// categories and completed ZIM registration. Local Sharing uses this as
    /// the cache boundary for its comparatively expensive authority snapshot.
    @Published private(set) var localSharingSnapshotRevision: UInt64 = 0
    /// Catalog anchors promised by the durable installed-coverage expectation.
    /// Legacy states without that expectation fall back to the saved selection.
    @Published private(set) var expectedEssentialsItemCount = 0

    private var lastRegisteredZimSignature: String?
    private var requestedRefreshGeneration = 0
    private var appliedRefreshGeneration = 0
    private var activeRefreshTask: Task<Void, Never>?
    private nonisolated static let minimumInstalledCatalogCoverage = 0.95

    private init() {}

    var hasContent: Bool {
        categories.contains { !$0.items.isEmpty }
    }

    var hasNonSampleContent: Bool {
        allItems.contains { !$0.isSampleContent }
    }

    var allItems: [ArkFileLocalContentItem] {
        categories.flatMap(\.items)
    }

    var hasLibraryContent: Bool {
        libraryCategories.contains { !$0.items.isEmpty }
    }

    var allLibraryItems: [ArkFileLibraryContentItem] {
        libraryCategories.flatMap(\.items)
    }

    var installedLibraryItemCount: Int {
        allLibraryItems.filter(\.isInstalled).count
    }

    var lockedLibraryItemCount: Int {
        allLibraryItems.filter(\.isLocked).count
    }

    var sampleLibraryItemCount: Int {
        allLibraryItems.filter(\.isSampleContent).count
    }

    /// Counts immutable bundled-sample provenance even after an installed pack
    /// folds those titles into their normal subject categories.
    var bundledSampleLibraryItemCount: Int {
        allLibraryItems.filter(\.isBundledSampleAsset).count
    }

    nonisolated func hasNonSampleOpenedZimFiles<S: Sequence>(in zimFiles: S) -> Bool where S.Element == ZimFile {
        Self.hasNonSampleOpenedZimFiles(in: zimFiles)
    }

    nonisolated static func hasNonSampleOpenedZimFiles<S: Sequence>(in zimFiles: S) -> Bool where S.Element == ZimFile {
        zimFiles.contains { zimFile in
            !Self.isBaseSampleOpenedZimFile(zimFile)
        }
    }

    func localItem(matching zimFile: ZimFile?) -> ArkFileLocalContentItem? {
        guard let bookmarkData = zimFile?.fileURLBookmark,
              let fileURL = Self.resolveBookmark(bookmarkData) else {
            return nil
        }
        let targetPath = Self.canonicalPath(for: fileURL)
        return allItems.first { item in
            item.type == .zim && Self.canonicalPath(for: item.url) == targetPath
        }
    }

    var nonZimCategories: [ArkFileLocalContentCategory] {
        categories.compactMap { category in
            let items = category.items.filter { $0.type != .zim }
            guard !items.isEmpty else { return nil }
            return ArkFileLocalContentCategory(key: category.key, items: items)
        }
    }

    func refresh() async {
        requestedRefreshGeneration += 1
        let requestedGeneration = requestedRefreshGeneration

        while appliedRefreshGeneration < requestedGeneration {
            if activeRefreshTask == nil {
                activeRefreshTask = Task { @MainActor [weak self] in
                    await self?.runRefreshLoop()
                }
            }
            await activeRefreshTask?.value
        }
    }

    private func runRefreshLoop() async {
        while true {
            let generation = requestedRefreshGeneration
            await performRefreshPass(generation: generation)
            appliedRefreshGeneration = generation
            guard generation != requestedRefreshGeneration else {
                activeRefreshTask = nil
                return
            }
        }
    }

    nonisolated static func shouldPublishRefresh(
        protectedDataAvailable: Bool,
        activationRecoveryBlocked: Bool,
        pathAvailabilities: [ArkFileLocalPathAvailability]
    ) -> Bool {
        protectedDataAvailable
            && !activationRecoveryBlocked
            && !pathAvailabilities.contains(.temporarilyUnavailable)
    }

    private func performRefreshPass(generation: Int) async {
        guard Self.shouldPublishRefresh(
            protectedDataAvailable: ArkFileProtectedDataAvailability.isAvailable,
            activationRecoveryBlocked: ArkFileContentActivationCoordinator.hasRootWideReadBlock,
            pathAvailabilities: []
        ) else {
            return
        }
        let previousInstalledItems = categories
            .flatMap(\.items)
            .filter { !$0.isBundledSampleAsset }
        var rootProbeURLs: [URL] = []
        let persistedActivePath = ArkFileContentPackInstaller.shared.state.activePath
        if !persistedActivePath.isEmpty {
            rootProbeURLs.append(URL(fileURLWithPath: persistedActivePath))
        }
        if !previousInstalledItems.isEmpty, let contentRoot {
            rootProbeURLs.append(contentRoot)
        }
        if let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            rootProbeURLs.append(
                supportRoot
                    .appendingPathComponent("ArkFile", isDirectory: true)
                    .appendingPathComponent("Content", isDirectory: true)
                    .appendingPathComponent("active", isDirectory: true)
            )
        }
        let rootAvailabilities = Self.unique(rootProbeURLs).map {
            ArkFileLocalPathProbe.availability(of: $0, expectedDirectory: true)
        }
        guard Self.shouldPublishRefresh(
            protectedDataAvailable: ArkFileProtectedDataAvailability.isAvailable,
            activationRecoveryBlocked: ArkFileContentActivationCoordinator.hasRootWideReadBlock,
            pathAvailabilities: rootAvailabilities
        ) else {
            return
        }

        let installedRoot = Self.installedContentRoot()
        let sampleRoot = Self.baseSampleContentRoot()
        let installerSaysInstalled = ArkFileContentPackInstaller.shared.state.phase == .installed
        let scannedInstalledCategories = await Task.detached(priority: .utility) {
            Self.scan(rootURL: installedRoot)
        }.value
        let installedItemAvailabilities = (previousInstalledItems + scannedInstalledCategories.flatMap(\.items))
            .map { item in
                ArkFileLocalPathProbe.availability(
                    of: item.url,
                    expectedDirectory: item.type == .map
                )
            }
        guard Self.shouldPublishRefresh(
            protectedDataAvailable: ArkFileProtectedDataAvailability.isAvailable,
            activationRecoveryBlocked: ArkFileContentActivationCoordinator.hasRootWideReadBlock,
            pathAvailabilities: installedItemAvailabilities
        ) else {
            return
        }
        let installedCategories = Self.filteringUnreadableItems(scannedInstalledCategories)
        let hasInstalledManagedPack = !installedCategories.isEmpty
        let nextContentRoot = hasInstalledManagedPack ? installedRoot : sampleRoot

        let sampleContentMode: ArkFileSampleContentMode = hasInstalledManagedPack
            ? .foldedIntoPack
            : .visibleSample
        let sampleCategories = await Task.detached(priority: .utility) {
            Self.scan(
                rootURL: sampleRoot,
                sampleContentMode: sampleContentMode
            )
        }.value
        let localCategories = Self.mergeLocalCategories(sampleCategories + installedCategories)
        let catalog = Self.loadBundledCatalog()
        let installerState = ArkFileContentPackInstaller.shared.state
        let catalogTier = Self.catalogTierForInstalledState(installerState)
        let savedExcludedItemKeys = ArkFileContentPackInstaller.shared
            .excludedItemKeys(for: catalogTier)
        let coverageExcludedItemKeys = catalog.map {
            Self.coverageExcludedItemKeys(
                catalog: $0,
                tier: catalogTier,
                savedExcludedItemKeys: savedExcludedItemKeys,
                installedCoverageItemKeys:
                    installerState.normalizedInstalledCoverageItemPaths
            )
        } ?? savedExcludedItemKeys
        let nextBundledCatalogItemCount = catalog?.itemCount(for: catalogTier) ?? 0
        let nextExpectedEssentialsItemCount = catalog.map {
            Self.selectedCatalogItemCount(
                catalog: $0,
                tier: catalogTier,
                excludedItemKeys: coverageExcludedItemKeys
            )
        } ?? 0
        let nextLibraryCategories = Self.merge(
            installedCategories: localCategories,
            catalog: catalog,
            tier: catalogTier
        )
        let nextInstalledCatalogItemCount = Self.installedCatalogItemCount(
            in: nextLibraryCategories,
            catalog: catalog,
            tier: catalogTier,
            excludedItemKeys: coverageExcludedItemKeys
        )
        // A newer caller arrived while this pass was scanning.
        // Skip publishing a mixed-generation snapshot; the refresh loop will
        // immediately run one latest-wins pass with the new inputs.
        guard generation == requestedRefreshGeneration else { return }

        contentRoot = nextContentRoot
        categories = localCategories
        libraryCategories = nextLibraryCategories
        bundledCatalogItemCount = nextBundledCatalogItemCount
        expectedEssentialsItemCount = nextExpectedEssentialsItemCount
        installedCatalogItemCount = nextInstalledCatalogItemCount
        reconcileInstallerStateIfNeeded(
            installedRoot: installedRoot,
            installerSaysInstalled: installerSaysInstalled
        )

        // Make the library visible before the comparatively expensive first
        // registration of a Complete pack. ZIM taps fall back to registration
        // until this finishes, so early interaction remains correct.
        let searchableRoots = [sampleRoot, installedRoot].compactMap { $0 }
        await registerZimFilesForSearchIfNeeded(roots: searchableRoots)
        localSharingSnapshotRevision &+= 1
    }

    private func reconcileInstallerStateIfNeeded(
        installedRoot: URL?,
        installerSaysInstalled: Bool
    ) {
        guard ArkFileContentPackInstaller.shouldEnforceBundledCatalogCoverage(
            allowsDeveloperFixtureCatalog: Brand.allowsDeveloperFixtureCatalog
        ) else {
            return
        }
        guard bundledCatalogItemCount > 0, expectedEssentialsItemCount > 0 else {
            return
        }
        let hasSufficientCoverage = Self.hasSufficientInstalledCatalogCoverage(
            installedCount: installedCatalogItemCount,
            catalogItemCount: expectedEssentialsItemCount
        )
        if installerSaysInstalled && !hasSufficientCoverage {
            ArkFileContentPackInstaller.shared.markInstalledContentIncomplete(
                installedCount: installedCatalogItemCount,
                expectedCount: expectedEssentialsItemCount
            )
        } else if let installedRoot,
                  ArkFileContentPackInstaller.shared.needsLiteRepair,
                  hasSufficientCoverage {
            ArkFileContentPackInstaller.shared.markInstalledContentRecovered(
                activeRoot: installedRoot,
                installedCount: installedCatalogItemCount,
                expectedCount: expectedEssentialsItemCount
            )
        }
    }

    static func installedCatalogCoverage(
        in rootURL: URL,
        catalog: ArkFileContentCatalog? = nil,
        tier: ArkFileContentTier = .lite,
        excludedItemKeys: Set<String> = [],
        expectedItemKeys: Set<String>? = nil
    ) -> ArkFileContentCatalogCoverage {
        let loadedCatalog = catalog ?? loadBundledCatalog()
        let coverageExclusions = loadedCatalog.map {
            coverageExcludedItemKeys(
                catalog: $0,
                tier: tier,
                savedExcludedItemKeys: excludedItemKeys,
                installedCoverageItemKeys: expectedItemKeys
            )
        } ?? excludedItemKeys
        let categories = scan(rootURL: rootURL)
        let libraryCategories = merge(installedCategories: categories, catalog: loadedCatalog, tier: tier)
        return ArkFileContentCatalogCoverage(
            installedCount: installedCatalogItemCount(
                in: libraryCategories,
                catalog: loadedCatalog,
                tier: tier,
                excludedItemKeys: coverageExclusions
            ),
            expectedCount: loadedCatalog.map {
                selectedCatalogItemCount(
                    catalog: $0,
                    tier: tier,
                    excludedItemKeys: coverageExclusions
                )
            } ?? 0
        )
    }

    /// The saved selection describes future user intent. Once activation has a
    /// durable commit, repair coverage instead follows the exact catalog
    /// anchors that commit promised, so intentionally deferred titles do not
    /// turn a successful one-title install into a repair state.
    nonisolated static func coverageExcludedItemKeys(
        catalog: ArkFileContentCatalog,
        tier: ArkFileContentTier,
        savedExcludedItemKeys: Set<String>,
        installedCoverageItemKeys: Set<String>?
    ) -> Set<String> {
        guard let installedCoverageItemKeys else {
            return Set(
                savedExcludedItemKeys.map(ArkFileContentCanonicalPath.key)
            )
        }
        let expected = Set(
            installedCoverageItemKeys.map(ArkFileContentCanonicalPath.key)
        )
        let allTierKeys = Set(
            catalog.allItems.compactMap { item -> String? in
                guard item.isAvailable(in: tier),
                      let key = canonicalCatalogItemKey(for: item) else {
                    return nil
                }
                return ArkFileContentCanonicalPath.key(key)
            }
        )
        return allTierKeys.subtracting(expected)
    }

    /// Canonical lowercased key used to match a catalog item against stored
    /// download exclusions and installed files.
    nonisolated static func canonicalCatalogItemKey(
        for item: ArkFileContentCatalogItem
    ) -> String? {
        canonicalizeContentRelativePath(
            item.normalizedRelativePath,
            category: item.category
        )?.lowercased()
    }

    static func selectedCatalogItemCount(
        catalog: ArkFileContentCatalog,
        tier: ArkFileContentTier = .lite,
        excludedItemKeys: Set<String>
    ) -> Int {
        guard !excludedItemKeys.isEmpty else {
            return catalog.itemCount(for: tier)
        }
        var count = 0
        for category in ArkFileLocalContentCategoryKey.allCases {
            for item in catalog.items(for: tier, category: category) {
                guard let key = canonicalCatalogItemKey(for: item) else {
                    count += 1
                    continue
                }
                if !excludedItemKeys.contains(key) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func installedCatalogItemCount(
        in libraryCategories: [ArkFileLibraryContentCategory],
        catalog: ArkFileContentCatalog?,
        tier: ArkFileContentTier = .lite,
        excludedItemKeys: Set<String> = []
    ) -> Int {
        guard let catalog else { return 0 }
        let expectedPaths = Set(ArkFileLocalContentCategoryKey.allCases.flatMap { category in
            catalog.items(for: tier, category: category).compactMap { item in
                canonicalCatalogItemKey(for: item)
            }
        }).subtracting(excludedItemKeys)
        guard !expectedPaths.isEmpty else { return 0 }
        return libraryCategories
            .flatMap(\.items)
            .filter { $0.isInstalled && expectedPaths.contains($0.relativePath.lowercased()) }
            .count
    }

    nonisolated static func hasSufficientInstalledCatalogCoverage(
        installedCount: Int,
        catalogItemCount: Int,
        minimumCoverage: Double = minimumInstalledCatalogCoverage
    ) -> Bool {
        guard catalogItemCount > 0 else { return true }
        let minimumInstalledCount = max(
            1,
            min(catalogItemCount, Int((Double(catalogItemCount) * minimumCoverage).rounded(.up)))
        )
        return installedCount >= minimumInstalledCount
    }

    /// Keeps every UI-derived repair decision on the same catalog-coverage
    /// policy as install finalization and launch-time library reconciliation.
    /// The explicit Debug fixture exception never bypasses a durable installer
    /// repair state, and Release builds always enforce bundled coverage.
    nonisolated static func installedCatalogNeedsRepair(
        phase: ArkFileContentInstallPhase,
        installedCount: Int,
        expectedCount: Int,
        allowsDeveloperFixtureCatalog: Bool
    ) -> Bool {
        guard ArkFileContentPackInstaller.shouldEnforceBundledCatalogCoverage(
            allowsDeveloperFixtureCatalog: allowsDeveloperFixtureCatalog
        ),
        phase == .installed,
        expectedCount > 0 else {
            return false
        }
        return !hasSufficientInstalledCatalogCoverage(
            installedCount: installedCount,
            catalogItemCount: expectedCount
        )
    }

    nonisolated static func scan(
        rootURL: URL?,
        sampleContentMode: ArkFileSampleContentMode = .none
    ) -> [ArkFileLocalContentCategory] {
        guard let rootURL,
              FileManager.default.fileExists(atPath: rootURL.fileSystemPath) else {
            return []
        }

        let catalog = sampleContentMode == .none ? loadBundledCatalog() : nil
        let manifestItemsByCategory = sampleContentMode == .none
            ? manifestBackedCatalogItems(rootURL: rootURL, catalog: catalog)
            : [:]
        let directlyInstalledCatalogItemsByCategory = sampleContentMode == .none
            ? directlyInstalledCatalogItems(rootURL: rootURL, catalog: catalog)
            : [:]

        return ArkFileLocalContentCategoryKey.allCases.compactMap { key in
            var items = scanFiles(
                in: key.folderAliases.map { rootURL.appendingPathComponent($0) },
                category: key,
                sampleContentMode: sampleContentMode
            )
            items.append(contentsOf: directlyInstalledCatalogItemsByCategory[key] ?? [])
            items.append(contentsOf: manifestItemsByCategory[key] ?? [])
            if key == .travel, let mapItem = offlineMapItem(rootURL: rootURL) {
                items.append(mapItem)
            }
            items = sortItems(mergeItemsByRelativePath(items), category: key)
            guard !items.isEmpty else { return nil }
            return ArkFileLocalContentCategory(key: key, items: items)
        }
    }

    private static func installedContentRoot() -> URL? {
        // Prefer the canonical Files-hidden root even when a crash occurred
        // after a legacy migration's atomic activation but before the
        // persisted activePath cache was refreshed.
        if let protectedRoot = try? ArkFileContentPackInstaller
            .protectedActiveContentRoot(),
           ArkFileContentPackInstaller
            .managedContentRootWithAnyReadableContentIfAvailable(
                candidateRoots: [protectedRoot]
            ) != nil {
            return protectedRoot
        }
        let activePath = ArkFileContentPackInstaller.shared.state.activePath
        if !activePath.isEmpty {
            let url = URL(fileURLWithPath: activePath)
            if ArkFileContentPackInstaller.managedContentRootWithAnyReadableContentIfAvailable(
                candidateRoots: [url]
            ) != nil || !scan(rootURL: url).isEmpty {
                return url
            }
        }
        return ArkFileContentPackInstaller.recoverableContentRootWithAnyReadableContentIfAvailable()
    }

    nonisolated private static func baseSampleContentRoot(bundle: Bundle = .main) -> URL? {
        guard let resourceRoot = bundle.resourceURL else { return nil }
        return unique([
            resourceRoot.appendingPathComponent("content/base-sample-content", isDirectory: true),
            resourceRoot.appendingPathComponent("base-sample-content", isDirectory: true),
            resourceRoot.appendingPathComponent("ArkFileSampleContent", isDirectory: true)
        ])
        .first(where: isDirectory)
    }

    nonisolated private static func isBaseSampleContentBookmark(_ bookmarkData: Data?) -> Bool {
        guard let bookmarkData,
              let url = resolveBookmark(bookmarkData) else {
            return false
        }
        return isBaseSampleContentURL(url)
    }

    nonisolated private static func isBaseSampleOpenedZimFile(_ zimFile: ZimFile) -> Bool {
        baseSampleContentZimFileIDs.contains(zimFile.fileID)
            || isBaseSampleContentBookmark(zimFile.fileURLBookmark)
    }

    nonisolated private static func resolveBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
    }

    nonisolated private static func isBaseSampleContentURL(_ url: URL) -> Bool {
        guard let sampleRoot = baseSampleContentRoot() else { return false }
        let sampleRootPath = sampleRoot.standardizedFileURL.fileSystemPath
        let urlPath = url.standardizedFileURL.fileSystemPath
        return urlPath == sampleRootPath || urlPath.hasPrefix(sampleRootPath + "/")
    }

    private static func mergeLocalCategories(
        _ categories: [ArkFileLocalContentCategory]
    ) -> [ArkFileLocalContentCategory] {
        ArkFileLocalContentCategoryKey.allCases.compactMap { key in
            var itemsByPath: [String: ArkFileLocalContentItem] = [:]
            for category in categories where category.key == key {
                for item in category.items {
                    itemsByPath[item.relativePath.lowercased()] = item
                }
            }
            let items = sortItems(Array(itemsByPath.values), category: key)
            guard !items.isEmpty else { return nil }
            return ArkFileLocalContentCategory(key: key, items: items)
        }
    }

    nonisolated private static func mergeItemsByRelativePath(
        _ items: [ArkFileLocalContentItem]
    ) -> [ArkFileLocalContentItem] {
        var itemsByPath: [String: ArkFileLocalContentItem] = [:]
        for item in items {
            let key = item.relativePath.lowercased()
            if let existing = itemsByPath[key],
               !existing.isSampleContent,
               item.isSampleContent {
                continue
            }
            itemsByPath[key] = item
        }
        return Array(itemsByPath.values)
    }

    private func registerZimFilesForSearchIfNeeded(roots: [URL]) async {
        let zimURLs = roots
            .flatMap { Self.zimFileURLs(in: $0) }
            .filter { ArkFileEssentialsAccessGate.resolvedURLForReadingSync($0) != nil }
        guard !zimURLs.isEmpty else {
            lastRegisteredZimSignature = nil
            return
        }
        let signature = Self.zimSignature(for: zimURLs)
        guard signature != lastRegisteredZimSignature else { return }

        let openedCount = await LibraryOperations.open(
            urls: zimURLs,
            includeInSearchByDefault: true
        ).count
        lastRegisteredZimSignature = signature
        Log.ContentPack.info(
            "Registered \(openedCount, privacy: .public) of \(zimURLs.count, privacy: .public) ArkFile ZIM files for search"
        )
    }

    nonisolated static func filteringUnreadableItems(
        _ categories: [ArkFileLocalContentCategory],
        canOpen: (@Sendable (URL) -> Bool)? = nil
    ) -> [ArkFileLocalContentCategory] {
        let readabilityCheck: @Sendable (URL) -> Bool = canOpen ?? { url in
            ArkFileEssentialsAccessGate.resolvedURLForReadingSync(url) != nil
        }
        return categories.compactMap { category in
            let readableItems = category.items.filter { readabilityCheck($0.url) }
            guard !readableItems.isEmpty else { return nil }
            return ArkFileLocalContentCategory(key: category.key, items: readableItems)
        }
    }

    private static func zimFileURLs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if isIgnorable(url) {
                if isDirectory(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension.lowercased() == "zim", isRegularFile(url) {
                urls.append(url)
            }
        }
        return urls.sorted {
            $0.fileSystemPath.localizedCaseInsensitiveCompare($1.fileSystemPath) == .orderedAscending
        }
    }

    nonisolated static func zimSignature(for urls: [URL]) -> String {
        urls.map { url in
            guard let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: url),
                  let identity = ArkFileZimSourceIdentity.capture(
                    logicalURL: url,
                    authoritativeURL: readLease.url
                  ) else {
                return "\(canonicalPath(for: url)):unavailable"
            }
            return "\(canonicalPath(for: url)):\(identity.signatureComponent)"
        }
        .joined(separator: "|")
    }

    nonisolated private static func scanFiles(
        in roots: [URL],
        category: ArkFileLocalContentCategoryKey,
        sampleContentMode: ArkFileSampleContentMode
    ) -> [ArkFileLocalContentItem] {
        var itemsByPath: [String: ArkFileLocalContentItem] = [:]
        var scannedDirectories = Set<String>()

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.fileSystemPath) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                if isIgnorable(url) {
                    if isDirectory(url) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard isRegularFile(url),
                      let type = ArkFileLocalContentType(fileURL: url),
                      let relativePath = normalizedRelativePath(
                        for: url,
                        root: root.deletingLastPathComponent(),
                        category: category
                      ) else {
                    continue
                }
                let realPath = canonicalPath(for: url)
                guard scannedDirectories.insert(realPath.lowercased()).inserted else { continue }
                guard itemsByPath[relativePath.lowercased()] == nil else { continue }
                let name = url.lastPathComponent
                let originalSubcategory = subcategory(for: category, filename: name)
                let isBundledSampleAsset = sampleContentMode != .none
                    && baseSampleContentRelativePaths.contains(relativePath.lowercased())
                let isSampleContent = sampleContentMode == .visibleSample
                    && isBundledSampleAsset
                itemsByPath[relativePath.lowercased()] = ArkFileLocalContentItem(
                    name: name,
                    url: url,
                    relativePath: relativePath,
                    type: type,
                    category: category,
                    subcategory: isSampleContent ? "Sample Content" : originalSubcategory,
                    sizeBytes: fileSize(url),
                    isSampleContent: isSampleContent,
                    sampleOriginalSubcategory: isSampleContent ? originalSubcategory : nil,
                    isBundledSampleAsset: isBundledSampleAsset
                )
            }
        }

        return Array(itemsByPath.values)
    }

    /// Reconciles the catalog against the active content root itself. Category
    /// scanning already finds normal titles, while the persisted manifest
    /// recovers wrapper-prefixed installs. This direct pass is the independent
    /// source of truth for catalog paths outside category folders, especially
    /// optional `maps/regions/<id>/region.pmtiles` archives. A later selective
    /// download may legitimately omit those maps from its filtered manifest
    /// without removing the already-installed files.
    nonisolated private static func directlyInstalledCatalogItems(
        rootURL: URL,
        catalog: ArkFileContentCatalog?
    ) -> [ArkFileLocalContentCategoryKey: [ArkFileLocalContentItem]] {
        guard let catalog else { return [:] }
        var itemsByCategory: [ArkFileLocalContentCategoryKey: [ArkFileLocalContentItem]] = [:]
        var seenPaths = Set<String>()

        for catalogItem in catalog.allItems {
            guard let catalogRelativePath = canonicalizeContentRelativePath(
                catalogItem.normalizedRelativePath,
                category: catalogItem.category
            ) else {
                continue
            }
            let lookupKey = catalogRelativePath.lowercased()
            guard seenPaths.insert(lookupKey).inserted else { continue }
            let url = rootURL.appendingPathComponent(catalogRelativePath)
            guard isRegularFile(url) else { continue }

            itemsByCategory[catalogItem.category, default: []].append(
                ArkFileLocalContentItem(
                    name: url.lastPathComponent,
                    url: url,
                    relativePath: catalogRelativePath,
                    type: catalogItem.type,
                    category: catalogItem.category,
                    subcategory: catalogItem.subcategory,
                    sizeBytes: fileSize(url),
                    isSampleContent: false,
                    sampleOriginalSubcategory: nil
                )
            )
        }
        return itemsByCategory
    }

    nonisolated private static func manifestBackedCatalogItems(
        rootURL: URL,
        catalog: ArkFileContentCatalog?
    ) -> [ArkFileLocalContentCategoryKey: [ArkFileLocalContentItem]] {
        guard let catalog,
              let manifest = installedManifest(at: rootURL) else {
            return [:]
        }
        let catalogTier = ArkFileContentTier.iOSInstallableTier(named: manifest.tier) ?? .lite
        let entries = manifest.files
        guard !entries.isEmpty else { return [:] }

        let entriesByPath = Dictionary(
            entries.map { ($0.normalizedRelativePath.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entriesByFileNameAndType = Dictionary(
            entries.compactMap { entry -> (String, ArkFilePackageManifest.Entry)? in
                guard let type = ArkFileLocalContentType(relativePath: entry.normalizedRelativePath) else {
                    return nil
                }
                return (fileNameTypeKey(path: entry.normalizedRelativePath, type: type), entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let entryFileNameAndTypeCounts = entries.reduce(into: [String: Int]()) { counts, entry in
            guard let type = ArkFileLocalContentType(relativePath: entry.normalizedRelativePath) else {
                return
            }
            counts[fileNameTypeKey(path: entry.normalizedRelativePath, type: type), default: 0] += 1
        }
        let catalogItems = ArkFileLocalContentCategoryKey.allCases.flatMap {
            catalog.items(for: catalogTier, category: $0)
        }
        let catalogFileNameAndTypeCounts = catalogItems.reduce(into: [String: Int]()) { counts, item in
            counts[fileNameTypeKey(path: item.normalizedRelativePath, type: item.type), default: 0] += 1
        }

        var itemsByCategory: [ArkFileLocalContentCategoryKey: [ArkFileLocalContentItem]] = [:]
        for category in ArkFileLocalContentCategoryKey.allCases {
            for catalogItem in catalog.items(for: catalogTier, category: category) {
                guard let catalogRelativePath = canonicalizeContentRelativePath(
                    catalogItem.normalizedRelativePath,
                    category: category
                ) else {
                    continue
                }
                guard let entry = manifestEntry(
                    forCatalogRelativePath: catalogRelativePath,
                    catalogType: catalogItem.type,
                    entries: entries,
                    entriesByPath: entriesByPath,
                    entriesByFileNameAndType: entriesByFileNameAndType,
                    allowFileNameFallback: {
                        let key = fileNameTypeKey(path: catalogRelativePath, type: catalogItem.type)
                        return catalogFileNameAndTypeCounts[key] == 1
                            && entryFileNameAndTypeCounts[key] == 1
                    }()
                ) else {
                    continue
                }
                let url = rootURL.appendingPathComponent(entry.normalizedRelativePath)
                guard isRegularFile(url) else {
                    continue
                }
                itemsByCategory[category, default: []].append(ArkFileLocalContentItem(
                    name: url.lastPathComponent,
                    url: url,
                    relativePath: catalogRelativePath,
                    type: catalogItem.type,
                    category: category,
                    subcategory: catalogItem.subcategory,
                    sizeBytes: fileSize(url),
                    isSampleContent: false,
                    sampleOriginalSubcategory: nil
                ))
            }
        }
        return itemsByCategory
    }

    nonisolated private static func installedManifest(at rootURL: URL) -> ArkFilePackageManifest? {
        let manifestURL = rootURL.appendingPathComponent(
            ArkFileContentPackInstaller.contentRootManifestFileName
        )
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ArkFilePackageManifest.self, from: data)
    }

    nonisolated private static func manifestEntry(
        forCatalogRelativePath catalogRelativePath: String,
        catalogType: ArkFileLocalContentType,
        entries: [ArkFilePackageManifest.Entry],
        entriesByPath: [String: ArkFilePackageManifest.Entry],
        entriesByFileNameAndType: [String: ArkFilePackageManifest.Entry],
        allowFileNameFallback: Bool
    ) -> ArkFilePackageManifest.Entry? {
        let lookupKey = catalogRelativePath.lowercased()
        if let entry = entriesByPath[lookupKey] {
            return entry
        }
        if let entry = entries.first(where: {
            $0.normalizedRelativePath.lowercased().hasSuffix("/\(lookupKey)")
        }) {
            return entry
        }
        guard allowFileNameFallback else { return nil }
        return entriesByFileNameAndType[fileNameTypeKey(path: catalogRelativePath, type: catalogType)]
    }

    nonisolated static func canonicalCatalogRelativePath(
        for relativePath: String,
        catalog: ArkFileContentCatalog
    ) -> String? {
        let normalized = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        let lookupKey = normalized.lowercased()
        let candidates = catalog.allItems.compactMap { item -> (ArkFileContentCatalogItem, String)? in
            guard let catalogRelativePath = canonicalizeContentRelativePath(
                item.normalizedRelativePath,
                category: item.category
            ) else {
                return nil
            }
            return (item, catalogRelativePath)
        }
        for (_, catalogRelativePath) in candidates {
            let catalogLookupKey = catalogRelativePath.lowercased()
            if lookupKey == catalogLookupKey || lookupKey.hasSuffix("/\(catalogLookupKey)") {
                return catalogRelativePath
            }
        }
        guard let type = ArkFileLocalContentType(relativePath: normalized) else { return nil }
        let fileNameKey = fileNameTypeKey(path: normalized, type: type)
        let fileNameMatches = candidates.filter { item, catalogRelativePath in
            fileNameKey == fileNameTypeKey(path: catalogRelativePath, type: item.type)
        }
        return fileNameMatches.count == 1 ? fileNameMatches[0].1 : nil
    }

    nonisolated private static func offlineMapItem(rootURL: URL) -> ArkFileLocalContentItem? {
        let resources = ArkFileOfflineMapResources.locate(contentRoot: rootURL, bundleResourceRoot: nil)
        guard resources.hasVectorMap || resources.hasLegacyTiles else {
            return nil
        }
        let mapsRoot = rootURL.appendingPathComponent("maps", isDirectory: true)
        let relativePath = resources.detail?.relativePath
            ?? resources.base?.relativePath
            ?? "maps/tiles"
        return ArkFileLocalContentItem(
            name: LocalString.arkfile_content_offline_map_title,
            url: mapsRoot,
            relativePath: relativePath,
            type: .map,
            category: .travel,
            subcategory: subcategory(for: .travel, filename: "Offline Vector Map"),
            sizeBytes: resources.detail?.sizeBytes
                ?? resources.base?.sizeBytes
                ?? resources.legacyTilesRoot.map {
                    fileSize(
                        $0
                            .appendingPathComponent("4")
                            .appendingPathComponent("4")
                            .appendingPathComponent("6.png")
                    )
                }
                ?? 0,
            isSampleContent: false,
            sampleOriginalSubcategory: nil
        )
    }

    nonisolated private static func normalizedRelativePath(
        for fileURL: URL,
        root: URL,
        category: ArkFileLocalContentCategoryKey
    ) -> String? {
        var rootPath = root.fileSystemPath
        while rootPath.hasSuffix("/") {
            rootPath.removeLast()
        }
        let filePath = fileURL.fileSystemPath
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let relative = String(filePath.dropFirst(min(filePath.count, rootPath.count + 1)))
        let normalized = relative
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty,
              !normalized.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return canonicalizeContentRelativePath(normalized, category: category)
    }

    nonisolated private static func canonicalizeContentRelativePath(
        _ relativePath: String,
        category: ArkFileLocalContentCategoryKey
    ) -> String? {
        var components = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = components.first,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return nil
        }
        if isFolderAlias(first, for: category) {
            components[0] = category.rawValue
        }
        return components.joined(separator: "/")
    }

    nonisolated private static func isFolderAlias(
        _ segment: String,
        for category: ArkFileLocalContentCategoryKey
    ) -> Bool {
        let normalizedSegment = normalizedCategorySegment(segment)
        let aliases = ([category.rawValue] + category.folderAliases).map(normalizedCategorySegment)
        return aliases.contains(normalizedSegment)
    }

    nonisolated private static func normalizedCategorySegment(_ segment: String) -> String {
        segment
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.fileSystemPath).inserted
        }
    }

    nonisolated private static func isIgnorable(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store"
            || name == ArkFileContentPackInstaller.contentRootMarkerFileName
            || name == ArkFileContentPackInstaller.contentRootManifestFileName
            || name.hasPrefix("._")
    }

    nonisolated private static func canonicalPath(for url: URL) -> String {
        URL(fileURLWithPath: url.fileSystemPath).resolvingSymlinksInPath().fileSystemPath
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    nonisolated private static func loadBundledCatalog() -> ArkFileContentCatalog? {
        if let catalog = ArkFileContentReleaseProvider.shared.discoveryCatalog { return catalog }
        do {
            return try ArkFileContentCatalog.loadBundled()
        } catch {
            Log.ContentPack.error(
                "Unable to load ArkFile content catalog: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func merge(
        installedCategories: [ArkFileLocalContentCategory],
        catalog: ArkFileContentCatalog?,
        tier: ArkFileContentTier = .lite
    ) -> [ArkFileLibraryContentCategory] {
        let installedByCategory = Dictionary(
            uniqueKeysWithValues: installedCategories.map { ($0.key, $0.items) }
        )

        return ArkFileLocalContentCategoryKey.allCases.compactMap { key in
            let installedItems = installedByCategory[key] ?? []
            let catalogItems = catalog?.items(for: tier, category: key) ?? []
            let installedByPath = Dictionary(
                installedItems.map { ($0.relativePath.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let installedByFileNameAndType = Dictionary(
                installedItems.map { (fileNameTypeKey(path: $0.relativePath, type: $0.type), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let installedFileNameAndTypeCounts = installedItems.reduce(into: [String: Int]()) { counts, item in
                counts[fileNameTypeKey(path: item.relativePath, type: item.type), default: 0] += 1
            }
            let catalogFileNameAndTypeCounts = catalogItems.reduce(into: [String: Int]()) { counts, item in
                counts[fileNameTypeKey(path: item.normalizedRelativePath, type: item.type), default: 0] += 1
            }
            var usedInstalledPaths = Set<String>()
            var mergedItems: [ArkFileLibraryContentItem] = []

            for catalogItem in catalogItems {
                guard let relativePath = canonicalizeContentRelativePath(
                    catalogItem.normalizedRelativePath,
                    category: key
                ) else {
                    continue
                }
                let lookupKey = relativePath.lowercased()
                let fileNameKey = fileNameTypeKey(path: relativePath, type: catalogItem.type)
                let installedItem = installedByPath[lookupKey] ?? {
                    guard catalogFileNameAndTypeCounts[fileNameKey] == 1,
                          installedFileNameAndTypeCounts[fileNameKey] == 1 else {
                        return nil
                    }
                    return installedByFileNameAndType[fileNameKey]
                }()
                if let installedItem {
                    usedInstalledPaths.insert(installedItem.relativePath.lowercased())
                }
                mergedItems.append(ArkFileLibraryContentItem(
                    catalog: catalogItem,
                    installedItem: installedItem
                ))
            }

            for installedItem in installedItems where !usedInstalledPaths.contains(installedItem.relativePath.lowercased()) {
                mergedItems.append(ArkFileLibraryContentItem(installed: installedItem))
            }

            mergedItems = sortLibraryItems(mergedItems, category: key)

            guard !mergedItems.isEmpty else { return nil }
            return ArkFileLibraryContentCategory(key: key, items: mergedItems)
        }
    }

    private static func catalogTierForInstalledState(_ state: ArkFileContentInstallState) -> ArkFileContentTier {
        state.tier?.isIOSInstallable == true ? state.tier ?? .lite : .lite
    }

    nonisolated private static func fileNameTypeKey(path: String, type: ArkFileLocalContentType) -> String {
        "\(URL(fileURLWithPath: path).lastPathComponent.lowercased())|\(type.rawValue)"
    }

    nonisolated private static func sortItems(
        _ items: [ArkFileLocalContentItem],
        category: ArkFileLocalContentCategoryKey
    ) -> [ArkFileLocalContentItem] {
        items.sorted { lhs, rhs in
            if lhs.isSampleContent != rhs.isSampleContent {
                return lhs.isSampleContent
            }
            let lhsOrder = subcategoryOrder(for: category, subcategory: lhs.subcategory)
            let rhsOrder = subcategoryOrder(for: category, subcategory: rhs.subcategory)
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.subcategory != rhs.subcategory {
                return lhs.subcategory.localizedCaseInsensitiveCompare(rhs.subcategory) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func sortLibraryItems(
        _ items: [ArkFileLibraryContentItem],
        category: ArkFileLocalContentCategoryKey
    ) -> [ArkFileLibraryContentItem] {
        items.sorted { lhs, rhs in
            if lhs.isSampleContent != rhs.isSampleContent {
                return lhs.isSampleContent
            }
            let lhsOrder = subcategoryOrder(for: category, subcategory: lhs.subcategory)
            let rhsOrder = subcategoryOrder(for: category, subcategory: rhs.subcategory)
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.subcategory != rhs.subcategory {
                return lhs.subcategory.localizedCaseInsensitiveCompare(rhs.subcategory) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func subcategoryOrder(
        for category: ArkFileLocalContentCategoryKey,
        subcategory: String
    ) -> Int {
        let order = subcategories[category]?.map(\.name) ?? []
        return order.firstIndex(of: subcategory) ?? 999
    }

    nonisolated private static func subcategory(
        for category: ArkFileLocalContentCategoryKey,
        filename: String
    ) -> String {
        guard let rules = subcategories[category] else {
            return LocalString.arkfile_content_subcategory_other
        }
        for rule in rules {
            if rule.matches.contains(where: { filename.localizedCaseInsensitiveContains($0) }) {
                return rule.name
            }
        }
        return LocalString.arkfile_content_subcategory_other
    }

    private struct SubcategoryRule: Sendable {
        let name: String
        let matches: [String]
    }

    nonisolated private static let baseSampleContentRelativePaths: Set<String> = [
        "general/encyclopedias/wikipedia_en_100_nopic_2026-04.zim",
        "medical/reference/emergency childbirth by us office of civil defense.zip",
        "food-preparation/water/rainwater harvesting for army installations  (2010).pdf",
        "travel/maps-hawaii/hawaiian islands.jpg",
        "books_documents/meditations by marcus aurelius.zip"
    ]

    nonisolated private static let baseSampleContentZimFileIDs: Set<UUID> = Set([
        UUID(uuidString: "ba431319-866c-37b5-f2bf-c6e5ab537ea5")
    ].compactMap { $0 })

    nonisolated private static let subcategories: [ArkFileLocalContentCategoryKey: [SubcategoryRule]] = [
        .booksDocuments: [
            SubcategoryRule(
                name: "Religious Texts",
                matches: [
                    "King James Bible", "CHILDREN'S BIBLE", "The Koran", "Life of Buddha",
                    "Confessions of St. Augustine", "Pilgrim's Progress", "Book of Mormon"
                ]
            ),
            SubcategoryRule(
                name: "Philosophy",
                matches: [
                    "Apology by Plato", "Beyond Good and Evil", "Meditations by Marcus Aurelius",
                    "Mysticism and Logic", "On Liberty", "Pascal's Pensees", "Pascal's Pensées",
                    "Blaise Pascal", "Politics,A Treatise", "Critique of Pure Reason",
                    "Ethics of Aristotle", "Communist Manifesto", "The Republic by Plato",
                    "As a man thinketh", "The Simple Life"
                ]
            ),
            SubcategoryRule(
                name: "American Founding",
                matches: [
                    "Declaration of Independence", "United States Constitution", "Bill of Rights",
                    "Common Sense by Thomas Paine", "Writings of Thomas Paine", "Thomas Paine",
                    "Federalist Papers", "Lincoln's Gettysburg"
                ]
            ),
            SubcategoryRule(name: "Epic & Classical", matches: ["Aeneid", "Iliad", "Odyssey", "Paradise Lost"]),
            SubcategoryRule(
                name: "American Literature",
                matches: [
                    "Huckleberry Finn", "Great Gatsby", "Moby-Dick", "Edgar Allan Poe", "Walden",
                    "Frederick Douglass", "call of the wild", "White Fang", "The Jungle by Upton"
                ]
            ),
            SubcategoryRule(
                name: "World Literature",
                matches: [
                    "Anna Karenina", "Crime and Punishment", "Count of Monte Cristo",
                    "William Shakespeare", "Aesop's fables", "Aesop", "Ulysses by James Joyce",
                    "Jules Verne", "Mysterious Island"
                ]
            ),
            SubcategoryRule(name: "Biography & History", matches: ["Benjamin Franklin", "Decline and Fall", "Art of War"]),
            SubcategoryRule(
                name: "Practical & Science",
                matches: [
                    "How it Works", "Mechanical Properties of Wood", "Wealth of Nations",
                    "Origin of Species", "Age of Invention"
                ]
            ),
            SubcategoryRule(
                name: "Children's & Youth",
                matches: ["Grimms' Fairy Tales", "Grimm", "Peter Pan", "Anecdotes for boys", "Boy Scouts", "Boy Scout"]
            )
        ],
        .foodPreparation: [
            SubcategoryRule(
                name: "Hunting & Trapping",
                matches: ["Camp Life in the Woods", "Deadfalls and Snares", "Hunter and Trapper", "Hunting with the Bow"]
            ),
            SubcategoryRule(name: "Meat Processing", matches: ["Slaughtering", "butchering", "Meat on the farm"]),
            SubcategoryRule(name: "USDA Guides", matches: ["USDA -"]),
            SubcategoryRule(name: "Cookbooks & Recipes", matches: ["Cookery", "Cookery Book", "Science in the Kitchen"]),
            SubcategoryRule(name: "Foraging", matches: ["Toadstools and Mushrooms", "Edible Plants", "sweet potato flour"]),
            SubcategoryRule(name: "Food Preservation", matches: ["Canning", "Home_Canning", "Freezing, Storing"]),
            SubcategoryRule(
                name: "Water Safety",
                matches: [
                    "DISINFECTION OF DRINKING WATER", "Giardia", "RAINWATER HARVESTING",
                    "Purifying Water", "Safe Water", "Water Treatment"
                ]
            )
        ],
        .general: [
            SubcategoryRule(name: "Encyclopedias", matches: ["Wikipedia", "Simple Wikipedia"]),
            SubcategoryRule(
                name: "Practical Skills",
                matches: [
                    "Stack Exchange", "DIY", "Electronics", "Electrical Engineering", "Gardening",
                    "Great Outdoors", "Ham Radio", "Motor Vehicle"
                ]
            ),
            SubcategoryRule(
                name: "Survival & Emergency",
                matches: [
                    "FM 21-", "FM 3-", "FM 4-", "FM 5-", "FM 34-", "TC 31-", "AF Reg", "FEMA",
                    "SERE", "NatSec", "USMC", "In Time of Emergency", "Survival Training",
                    "Survival Manual", "Survival Course", "Survival Evasion", "Combat Water Survival"
                ]
            )
        ],
        .medical: [
            SubcategoryRule(
                name: "Reference",
                matches: ["WikiMed", "wikem", "Emergency Childbirth", "Nuclear and Radiological Casualties"]
            ),
            SubcategoryRule(
                name: "Field Guides",
                matches: [
                    "Pregnancy", "First_Aid", "Where_There_Is_No_Doctor", "Care_For",
                    "Breastfeeding", "Emergency Healthcare", "Infant Feeding"
                ]
            )
        ],
        .travel: [
            SubcategoryRule(name: "Travel Guides", matches: ["WikiVoyage"]),
            SubcategoryRule(name: "National Maps", matches: ["United States.jpg", "National Atlas 2003", "Offline Vector Map"]),
            SubcategoryRule(name: "East Coast", matches: ["Northeastern States", "Middle Atlantic", "Southeastern States", "Florida"]),
            SubcategoryRule(name: "Midwest", matches: ["Great Lakes", "Mississippi Valley"]),
            SubcategoryRule(name: "Plains", matches: ["Central Plains", "Northern Plains", "Southern Plains"]),
            SubcategoryRule(
                name: "West Coast & Southwest",
                matches: ["Central Pacific", "Northwestern States", "Southern California", "Arizona and New Mexico", "Southern Texas"]
            ),
            SubcategoryRule(name: "Alaska", matches: ["Alaska", "Aleutian"]),
            SubcategoryRule(name: "Hawaii", matches: ["Hawaiian"]),
            SubcategoryRule(name: "Urban Areas", matches: ["Urban Areas"])
        ]
    ]
}

@MainActor
final class ArkFileContentFavorites: ObservableObject {
    static let shared = ArkFileContentFavorites()

    @Published private(set) var relativePaths: Set<String>

    private static let defaultsKey = "arkfile.content.favoriteRelativePaths"

    private init() {
        relativePaths = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isFavorite(_ item: ArkFileLocalContentItem) -> Bool {
        relativePaths.contains { ArkFileSavedContentIdentity.matches(savedPath: $0, currentPath: item.relativePath) }
    }

    func toggle(_ item: ArkFileLocalContentItem) {
        if isFavorite(item) {
            relativePaths = Set(relativePaths.filter {
                !ArkFileSavedContentIdentity.matches(savedPath: $0, currentPath: item.relativePath)
            })
        } else {
            relativePaths.insert(item.relativePath)
        }
        persist()
    }

    func favoriteItems(in categories: [ArkFileLocalContentCategory]) -> [ArkFileLocalContentItem] {
        categories
            .flatMap(\.items)
            .filter { isFavorite($0) }
            .sorted { left, right in
                if left.category != right.category {
                    return left.category.displayName.localizedCaseInsensitiveCompare(right.category.displayName) == .orderedAscending
                }
                if left.subcategory != right.subcategory {
                    return left.subcategory.localizedCaseInsensitiveCompare(right.subcategory) == .orderedAscending
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func persist() {
        UserDefaults.standard.set(Array(relativePaths).sorted(), forKey: Self.defaultsKey)
    }
}

/// A ZIM article location that remains valid when libkiwix assigns a different
/// archive UUID after the same local content is registered again.
///
/// `articleUrl` remains the rollback representation on the bookmark. This
/// additive route stores only the URL components below the volatile authority
/// and deliberately retains their percent encoding and case.
struct ArkFileZIMArticleRoute: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var percentEncodedPath: String
    var percentEncodedQuery: String?
    var percentEncodedFragment: String?

    init(
        version: Int = Self.currentVersion,
        percentEncodedPath: String,
        percentEncodedQuery: String? = nil,
        percentEncodedFragment: String? = nil
    ) {
        self.version = version
        self.percentEncodedPath = percentEncodedPath
        self.percentEncodedQuery = percentEncodedQuery
        self.percentEncodedFragment = percentEncodedFragment
    }

    init?(articleURLString: String) {
        guard let components = URLComponents(string: articleURLString),
              let scheme = components.scheme?.lowercased(),
              scheme == "zim" || scheme == "kiwix",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host,
              UUID(uuidString: host) != nil else {
            return nil
        }
        self.init(
            percentEncodedPath: components.percentEncodedPath,
            percentEncodedQuery: components.percentEncodedQuery,
            percentEncodedFragment: components.percentEncodedFragment
        )
    }

    init?(url: URL) {
        self.init(articleURLString: url.absoluteString)
    }

    /// Rebinds a saved article route to the UUID of the currently registered
    /// local archive. The reparsing check rejects malformed imported fields and
    /// ensures URL construction did not reinterpret any encoded component.
    func url(zimFileID: UUID) -> URL? {
        guard version == Self.currentVersion else {
            return nil
        }
        let query = percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = percentEncodedFragment.map { "#\($0)" } ?? ""
        guard let url = URL(string: "zim://\(zimFileID.uuidString)\(percentEncodedPath)\(query)\(fragment)"),
              let reparsed = Self(articleURLString: url.absoluteString),
              reparsed.percentEncodedPath == percentEncodedPath,
              reparsed.percentEncodedQuery == percentEncodedQuery,
              reparsed.percentEncodedFragment == percentEncodedFragment else {
            return nil
        }
        return url
    }

    fileprivate var stableLocationIdentifier: String {
        guard let canonicalURL = url(zimFileID: UUID()) else {
            return "unsupported"
        }
        let path = canonicalURL.contentPath
        let query = percentEncodedQuery.map(Self.canonicalPercentEncoding)
        let fragment = percentEncodedFragment.map(Self.canonicalPercentEncoding)
        return [
            "identity-v1",
            Self.lengthDelimited("path", value: path),
            Self.lengthDelimited("query", value: query),
            Self.lengthDelimited("fragment", value: fragment)
        ].joined(separator: "|")
    }

    fileprivate var isSupportedAndWellFormed: Bool {
        url(zimFileID: UUID()) != nil
    }

    private static func lengthDelimited(_ name: String, value: String?) -> String {
        guard let value else {
            return "\(name):nil"
        }
        return "\(name):\(value.utf8.count):\(value)"
    }

    /// RFC 3986 normalization for identity only. Replay keeps every original
    /// byte: identity uppercases escapes and decodes ASCII unreserved bytes,
    /// while reserved escapes, ordering, `+`, case, and Unicode remain intact.
    private static func canonicalPercentEncoding(_ value: String) -> String {
        let source = Array(value.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            guard source[index] == 0x25,
                  index + 2 < source.count,
                  let high = hexValue(source[index + 1]),
                  let low = hexValue(source[index + 2]) else {
                result.append(source[index])
                index += 1
                continue
            }
            let decoded = (high << 4) | low
            if isUnreserved(decoded) {
                result.append(decoded)
            } else {
                result.append(0x25)
                result.append(uppercaseHex(high))
                result.append(uppercaseHex(low))
            }
            index += 3
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func uppercaseHex(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x41 + nibble - 10
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }
}

struct ArkFileContentBookmark: Codable, Identifiable, Hashable, Sendable {
    static let currentSchemaVersion = 3

    var id: String
    var schemaVersion: Int
    var locationKey: String
    var articleUrl: String
    var articleTitle: String
    var contentType: ArkFileLocalContentType
    var relativePath: String
    var fileName: String
    var pageNumber: Int?
    var chapterIndex: Int?
    var chapterPath: String
    var anchorId: String
    var anchorLabel: String
    var scrollTop: Double
    var tags: [String]
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var status: String
    /// Additive ZIM-only route. Older clients continue to use `articleUrl` and
    /// older persisted bookmarks derive this value during normalization.
    var zimArticleRoute: ArkFileZIMArticleRoute?

    init(
        id: String,
        schemaVersion: Int,
        locationKey: String,
        articleUrl: String,
        articleTitle: String,
        contentType: ArkFileLocalContentType,
        relativePath: String,
        fileName: String,
        pageNumber: Int?,
        chapterIndex: Int?,
        chapterPath: String,
        anchorId: String,
        anchorLabel: String,
        scrollTop: Double,
        tags: [String],
        notes: String,
        createdAt: Date,
        updatedAt: Date,
        status: String,
        zimArticleRoute: ArkFileZIMArticleRoute? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.locationKey = locationKey
        self.articleUrl = articleUrl
        self.articleTitle = articleTitle
        self.contentType = contentType
        self.relativePath = relativePath
        self.fileName = fileName
        self.pageNumber = pageNumber
        self.chapterIndex = chapterIndex
        self.chapterPath = chapterPath
        self.anchorId = anchorId
        self.anchorLabel = anchorLabel
        self.scrollTop = scrollTop
        self.tags = tags
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.zimArticleRoute = contentType == .zim
            ? zimArticleRoute ?? ArkFileZIMArticleRoute(articleURLString: articleUrl)
            : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        locationKey = try container.decodeIfPresent(String.self, forKey: .locationKey) ?? ""
        articleUrl = try container.decodeIfPresent(String.self, forKey: .articleUrl) ?? ""
        articleTitle = try container.decodeIfPresent(String.self, forKey: .articleTitle) ?? "Bookmark"
        contentType = try container.decodeIfPresent(ArkFileLocalContentType.self, forKey: .contentType) ?? .zim
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        pageNumber = try container.decodeIfPresent(Int.self, forKey: .pageNumber)
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex)
            ?? container.decodeIfPresent(Int.self, forKey: .chapter)
        chapterPath = try container.decodeIfPresent(String.self, forKey: .chapterPath)
            ?? container.decodeIfPresent(String.self, forKey: .chapterFile)
            ?? ""
        anchorId = try container.decodeIfPresent(String.self, forKey: .anchorId) ?? ""
        anchorLabel = try container.decodeIfPresent(String.self, forKey: .anchorLabel) ?? ""
        scrollTop = try container.decodeIfPresent(Double.self, forKey: .scrollTop) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = Self.decodeDate(from: container, forKey: .createdAt) ?? Date()
        updatedAt = Self.decodeDate(from: container, forKey: .updatedAt) ?? createdAt
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "valid"
        let decodedZIMRoute = try? container.decode(ArkFileZIMArticleRoute.self, forKey: .zimArticleRoute)
        zimArticleRoute = contentType == .zim
            ? decodedZIMRoute ?? ArkFileZIMArticleRoute(articleURLString: articleUrl)
            : nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(locationKey, forKey: .locationKey)
        try container.encode(articleUrl, forKey: .articleUrl)
        try container.encode(articleTitle, forKey: .articleTitle)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(pageNumber, forKey: .pageNumber)
        try container.encodeIfPresent(chapterIndex, forKey: .chapterIndex)
        try container.encodeIfPresent(chapterIndex, forKey: .chapter)
        try container.encode(chapterPath, forKey: .chapterPath)
        try container.encode(chapterPath, forKey: .chapterFile)
        try container.encode(anchorId, forKey: .anchorId)
        try container.encode(anchorLabel, forKey: .anchorLabel)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(tags, forKey: .tags)
        try container.encode(notes, forKey: .notes)
        try container.encode(Self.epochMilliseconds(for: createdAt), forKey: .createdAt)
        try container.encode(Self.epochMilliseconds(for: updatedAt), forKey: .updatedAt)
        try container.encode(Self.epochMilliseconds(for: updatedAt), forKey: .lastResolved)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(zimArticleRoute, forKey: .zimArticleRoute)
    }

    var displaySource: String {
        switch contentType {
        case .pdf:
            if let pageNumber {
                return "\(fileName) - Page \(pageNumber)"
            }
            return fileName
        case .htmlBook:
            if let chapterIndex {
                return "\(fileName) - Chapter \(chapterIndex + 1)"
            }
            return fileName
        case .image:
            return "\(fileName) - Image"
        case .html:
            return "\(fileName) - HTML"
        case .map:
            return "\(fileName) - Map"
        case .zim:
            return fileName
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case locationKey
        case articleUrl
        case articleTitle
        case contentType
        case relativePath
        case fileName
        case pageNumber
        case chapter
        case chapterIndex
        case chapterFile
        case chapterPath
        case anchorId
        case anchorLabel
        case scrollTop
        case tags
        case notes
        case createdAt
        case updatedAt
        case lastResolved
        case status
        case zimArticleRoute
    }

    private static func epochMilliseconds(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func decodeDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        if let milliseconds = try? container.decode(Double.self, forKey: key) {
            if milliseconds > 10_000_000_000 {
                return Date(timeIntervalSince1970: milliseconds / 1_000)
            }
            if milliseconds > 100_000_000 {
                return Date(timeIntervalSince1970: milliseconds)
            }
            return Date(timeIntervalSinceReferenceDate: milliseconds)
        }
        if let string = try? container.decode(String.self, forKey: key),
           let date = ISO8601DateFormatter().date(from: string) {
            return date
        }
        return nil
    }

    static func locationKey(
        item: ArkFileLocalContentItem,
        articleUrl: String,
        pageNumber: Int?,
        chapterIndex: Int?,
        chapterPath: String = "",
        anchorId: String,
        scrollTop: Double
    ) -> String {
        locationKey(
            contentType: item.type,
            relativePath: item.relativePath,
            articleUrl: articleUrl,
            pageNumber: pageNumber,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorId,
            scrollTop: scrollTop
        )
    }

    func normalizedForCurrentSchema() -> Self {
        var normalized = self
        normalized.schemaVersion = Self.currentSchemaVersion
        normalized.zimArticleRoute = contentType == .zim
            ? zimArticleRoute ?? ArkFileZIMArticleRoute(articleURLString: articleUrl)
            : nil
        normalized.locationKey = Self.locationKey(
            contentType: contentType,
            relativePath: relativePath,
            articleUrl: articleUrl,
            pageNumber: pageNumber,
            chapterIndex: chapterIndex,
            chapterPath: chapterPath,
            anchorId: anchorId,
            scrollTop: scrollTop,
            zimArticleRoute: Self.effectiveZIMArticleRoute(
                storedRoute: normalized.zimArticleRoute,
                articleUrl: articleUrl
            )
        )
        return normalized
    }

    var hasUsableZIMArticleRoute: Bool {
        contentType == .zim && Self.effectiveZIMArticleRoute(
            storedRoute: zimArticleRoute,
            articleUrl: articleUrl
        ) != nil
    }

    /// Returns the saved ZIM article with the current registration UUID while
    /// retaining `articleUrl` as a fallback for bookmarks written before this
    /// additive route existed (or by a future route version).
    func rebasedZIMArticleURL(zimFileID: UUID) -> URL? {
        guard contentType == .zim else {
            return nil
        }
        return Self.effectiveZIMArticleRoute(
            storedRoute: zimArticleRoute,
            articleUrl: articleUrl
        )?.url(zimFileID: zimFileID)
    }

    private static func locationKey(
        contentType: ArkFileLocalContentType,
        relativePath: String,
        articleUrl: String,
        pageNumber: Int?,
        chapterIndex: Int?,
        chapterPath: String,
        anchorId: String,
        scrollTop: Double,
        zimArticleRoute: ArkFileZIMArticleRoute? = nil
    ) -> String {
        switch contentType {
        case .pdf:
            return ["pdf", relativePath, "page", "\(pageNumber ?? 1)"].joined(separator: "|")
        case .htmlBook:
            let chapterPart = stableChapterIdentifier(
                chapterPath: chapterPath,
                articleUrl: articleUrl,
                chapterIndex: chapterIndex
            )
            return [
                "htmlbook",
                relativePath,
                "chapter",
                chapterPart,
                "position",
                stablePositionIdentifier(anchorId: anchorId, scrollTop: scrollTop)
            ].joined(separator: "|")
        case .html:
            return [
                "html",
                relativePath,
                stableArticleIdentifier(articleUrl),
                "position",
                stablePositionIdentifier(anchorId: anchorId, scrollTop: scrollTop)
            ].joined(separator: "|")
        case .image:
            return ["image", relativePath].joined(separator: "|")
        case .map:
            return ["map", relativePath].joined(separator: "|")
        case .zim:
            let route = effectiveZIMArticleRoute(
                storedRoute: zimArticleRoute,
                articleUrl: articleUrl
            )
            return [
                "zim",
                relativePath,
                route?.stableLocationIdentifier ?? stableZIMFallbackIdentifier(articleUrl)
            ].joined(separator: "|")
        }
    }

    /// A future or malformed additive route remains preserved for round-trip
    /// compatibility, but cannot define deduplication or opening identity.
    /// Both operations fall back to the legacy URL's stable path components.
    private static func effectiveZIMArticleRoute(
        storedRoute: ArkFileZIMArticleRoute?,
        articleUrl: String
    ) -> ArkFileZIMArticleRoute? {
        guard let legacyRoute = ArkFileZIMArticleRoute(articleURLString: articleUrl) else {
            return nil
        }
        if let storedRoute,
           storedRoute.isSupportedAndWellFormed,
           storedRoute.stableLocationIdentifier == legacyRoute.stableLocationIdentifier {
            return storedRoute
        }
        return legacyRoute
    }

    private static func stableZIMFallbackIdentifier(_ articleUrl: String) -> String {
        guard let components = URLComponents(string: articleUrl),
              let scheme = components.scheme?.lowercased(),
              scheme == "zim" || scheme == "kiwix" else {
            return "unresolved:\(articleUrl)"
        }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""
        return "unresolved:\(components.percentEncodedPath)\(query)\(fragment)"
    }

    private static func stableChapterIdentifier(
        chapterPath: String,
        articleUrl: String,
        chapterIndex: Int?
    ) -> String {
        let normalizedPath = chapterPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let fragment = URL(string: articleUrl)
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.fragment }
            .map { ($0.removingPercentEncoding ?? $0).lowercased() }
            ?? ""
        if !normalizedPath.isEmpty {
            return fragment.isEmpty ? normalizedPath : "\(normalizedPath)#\(fragment)"
        }
        let articleIdentifier = stableArticleIdentifier(articleUrl)
        if !articleIdentifier.isEmpty {
            return articleIdentifier
        }
        return "index:\(chapterIndex ?? 0)"
    }

    private static func stableArticleIdentifier(_ articleUrl: String) -> String {
        guard let url = URL(string: articleUrl) else {
            return articleUrl.lowercased()
        }
        if url.isFileURL {
            let path = url.standardizedFileURL.fileSystemPath.lowercased()
            let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
                .map { ($0.removingPercentEncoding ?? $0).lowercased() }
                ?? ""
            return fragment.isEmpty ? path : "\(path)#\(fragment)"
        }
        return url.absoluteString.lowercased()
    }

    private static func stablePositionIdentifier(anchorId: String, scrollTop: Double) -> String {
        if !anchorId.isEmpty {
            let anchor = "anchor:\(anchorId.lowercased())"
            let resolvedScrollTop = Int(max(0, scrollTop).rounded())
            return resolvedScrollTop > 0
                ? "\(anchor)|scroll:\(resolvedScrollTop)"
                : anchor
        }
        return "scroll:\(Int(max(0, scrollTop).rounded()))"
    }
}

@MainActor
final class ArkFileContentBookmarks: ObservableObject {
    static let shared = ArkFileContentBookmarks()

    @Published private(set) var bookmarks: [ArkFileContentBookmark] = []

    private static let defaultsKey = "arkfile.content.bookmarks.v2"
    private static let exportVersion = ArkFileContentBookmark.currentSchemaVersion
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let defaults: UserDefaults
    private let persistenceKey: String

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = ArkFileContentBookmarks.defaultsKey
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        bookmarks = Self.loadBookmarks(
            decoder: decoder,
            defaults: defaults,
            key: persistenceKey
        )
    }

    func bookmark(matching locationKey: String) -> ArkFileContentBookmark? {
        bookmarks.first { $0.locationKey == locationKey }
    }

    func bookmark(id: String) -> ArkFileContentBookmark? {
        bookmarks.first { $0.id == id }
    }

    func bookmarks(for item: ArkFileLocalContentItem) -> [ArkFileContentBookmark] {
        bookmarks.filter {
            $0.contentType == item.type
                && ArkFileSavedContentIdentity.matches(savedPath: $0.relativePath, currentPath: item.relativePath)
        }
    }

    func filteredBookmarks(searchText: String, tag: String?) -> [ArkFileContentBookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return bookmarks.filter { bookmark in
            let matchesTag = tag?.isEmpty != false || bookmark.tags.contains(tag ?? "")
            let matchesSearch = query.isEmpty
                || bookmark.articleTitle.localizedCaseInsensitiveContains(query)
                || bookmark.notes.localizedCaseInsensitiveContains(query)
                || bookmark.fileName.localizedCaseInsensitiveContains(query)
            return matchesTag && matchesSearch
        }
    }

    var allTags: [String] {
        Array(Set(bookmarks.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    @discardableResult
    func upsert(_ bookmark: ArkFileContentBookmark) -> ArkFileContentBookmark {
        var updated = bookmark.normalizedForCurrentSchema()
        updated.updatedAt = Date()
        if let index = bookmarks.firstIndex(where: { $0.locationKey == updated.locationKey }) {
            updated.id = bookmarks[index].id
            updated.createdAt = bookmarks[index].createdAt
            bookmarks[index] = updated
        } else {
            bookmarks.insert(updated, at: 0)
        }
        sortAndPersist()
        return updated
    }

    func delete(_ bookmark: ArkFileContentBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    func exportData() throws -> Data {
        try encoder.encode(ArkFileBookmarkExport(exportVersion: Self.exportVersion, exportedAt: Date(), bookmarks: bookmarks))
    }

    @discardableResult
    func importData(_ data: Data, merge: Bool = true) throws -> (imported: Int, skipped: Int) {
        let importedFile = try decoder.decode(ArkFileBookmarkExport.self, from: data)
        var imported = 0
        var skipped = 0
        var mergedBookmarks = merge ? bookmarks : []
        var existingKeys = Set(mergedBookmarks.map(\.locationKey))

        for bookmark in importedFile.bookmarks {
            let normalizedBookmark = bookmark.normalizedForCurrentSchema()
            guard !normalizedBookmark.locationKey.isEmpty else {
                skipped += 1
                continue
            }
            if existingKeys.contains(normalizedBookmark.locationKey) {
                skipped += 1
                continue
            }
            var copy = normalizedBookmark
            copy.id = UUID().uuidString
            copy.createdAt = Date()
            copy.updatedAt = Date()
            mergedBookmarks.append(copy)
            existingKeys.insert(copy.locationKey)
            imported += 1
        }

        bookmarks = mergedBookmarks
        sortAndPersist()
        return (imported, skipped)
    }

    private func sortAndPersist() {
        bookmarks.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(bookmarks) {
            defaults.set(data, forKey: persistenceKey)
        }
    }

    private static func loadBookmarks(
        decoder: JSONDecoder,
        defaults: UserDefaults,
        key: String
    ) -> [ArkFileContentBookmark] {
        guard let data = defaults.data(forKey: key),
              let bookmarks = try? decoder.decode([ArkFileContentBookmark].self, from: data) else {
            return []
        }
        return bookmarks
            .map { $0.normalizedForCurrentSchema() }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

private struct ArkFileBookmarkExport: Codable {
    let exportVersion: Int
    let exportedAt: Date
    let bookmarks: [ArkFileContentBookmark]
}

private extension ArkFileLocalContentType {
    init?(relativePath: String) {
        self.init(fileURL: URL(fileURLWithPath: relativePath))
    }

    init?(fileURL: URL) {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "zim", "zimaa":
            self = .zim
        case "pdf":
            self = .pdf
        case "zip":
            self = .htmlBook
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg":
            self = .image
        case "html", "htm":
            self = .html
        default:
            return nil
        }
    }
}
