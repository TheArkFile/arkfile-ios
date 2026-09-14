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

/// Stable identity for files that must become readable as one compatible unit.
struct ArkFileContentCompatibilityGroupID: RawRepresentable, Codable, Hashable, Comparable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    /// MapLibre keeps PMTiles and style resources open for a view lifetime.
    /// These groups must acquire the app's exclusive path-reader mutation gate
    /// before activation and hold it through commit and cleanup.
    var requiresExclusivePathReaderGate: Bool {
        rawValue == "map-core" || rawValue.hasPrefix("map-region:")
    }

    static func < (
        lhs: ArkFileContentCompatibilityGroupID,
        rhs: ArkFileContentCompatibilityGroupID
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ArkFileContentCompatibilityGroup: Hashable, Identifiable, Sendable {
    struct Member: Hashable, Sendable {
        let entry: ArkFilePackageManifest.Entry
        let canonicalRelativePath: String
    }

    let id: ArkFileContentCompatibilityGroupID
    let members: [Member]

    /// The catalog path whose exclusion selects or deselects this whole group.
    /// Shared core-map groups intentionally have no catalog anchor.
    let catalogAnchorRelativePath: String?

    var entries: [ArkFilePackageManifest.Entry] {
        members.map(\.entry)
    }

    var canonicalRelativePaths: [String] {
        members.map(\.canonicalRelativePath)
    }
}

/// A selection closes over incoming compatibility groups only. In particular,
/// an installed group absent from `selectedIncomingGroups` and
/// `excludedIncomingGroupIDs` has not been authorized for deletion.
struct ArkFileContentCompatibilitySelection: Hashable, Sendable {
    let selectedIncomingGroups: [ArkFileContentCompatibilityGroup]
    let excludedIncomingGroupIDs: Set<ArkFileContentCompatibilityGroupID>
}

enum ArkFileContentCompatibilityPlanner {
    private static let coreMapGroupID = ArkFileContentCompatibilityGroupID(
        rawValue: "map-core"
    )

    /// Returns a deterministic compatibility identity for a canonical install
    /// path. Path comparisons are intentionally case-insensitive because the
    /// content manifest and selection store use lowercased path keys.
    static func groupID(
        for canonicalRelativePath: String
    ) -> ArkFileContentCompatibilityGroupID {
        let path = canonicalIdentityPath(canonicalRelativePath)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)

        if components.count >= 3,
           components[0] == "maps",
           components[1] == "regions",
           !components[2].isEmpty {
            return ArkFileContentCompatibilityGroupID(
                rawValue: "map-region:\(components[2])"
            )
        }

        if components.count >= 3,
           components[0] == "maps",
           ["base", "detail", "tiles", "poi"].contains(String(components[1])) {
            return coreMapGroupID
        }

        if let zimAnchor = multipartZIMAnchorPath(path) {
            return ArkFileContentCompatibilityGroupID(rawValue: "zim:\(zimAnchor)")
        }

        return ArkFileContentCompatibilityGroupID(rawValue: "file:\(path)")
    }

    /// Cross-source identity for compatibility-group paths. Release manifests,
    /// the catalog, and filesystem enumeration can spell the same filename
    /// with different canonically equivalent Unicode scalar sequences. Group
    /// identity must not depend on that storage detail.
    static func canonicalIdentityPath(_ path: String) -> String {
        normalizedPath(path)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    /// Resolves the same canonical install path the installer uses, with the
    /// additional multipart rule that maps `.zimaa`, `.zimab`, and later
    /// siblings through their catalog's `.zim` anchor.
    static func canonicalInstallPath(
        for entry: ArkFilePackageManifest.Entry,
        catalog: ArkFileContentCatalog?
    ) -> String {
        let path = normalizedPath(entry.normalizedRelativePath)
        guard let catalog else { return path }

        if let fragmentSuffix = multipartZIMFragmentSuffix(path) {
            let unsplitPath = String(path.dropLast(fragmentSuffix.count))
            if let canonicalAnchor = ArkFileLocalContentLibrary.canonicalCatalogRelativePath(
                for: unsplitPath,
                catalog: catalog
            ) {
                return canonicalAnchor + fragmentSuffix
            }
        }

        return ArkFileLocalContentLibrary.canonicalCatalogRelativePath(
            for: path,
            catalog: catalog
        ) ?? path
    }

    static func groups(
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?
    ) -> [ArkFileContentCompatibilityGroup] {
        var membersByGroup: [
            ArkFileContentCompatibilityGroupID: [ArkFileContentCompatibilityGroup.Member]
        ] = [:]

        for entry in manifest.files {
            let canonicalPath = canonicalInstallPath(for: entry, catalog: catalog)
            let id = groupID(for: canonicalPath)
            membersByGroup[id, default: []].append(
                .init(entry: entry, canonicalRelativePath: canonicalPath)
            )
        }

        let catalogAnchorsByGroup = catalogAnchorsByGroupID(catalog)
        return membersByGroup.keys.sorted().map { id in
            let members = (membersByGroup[id] ?? []).sorted(by: memberSort)
            let anchor = catalog == nil
                ? fallbackAnchor(for: id, members: members)
                : catalogAnchorsByGroup[id]
            return ArkFileContentCompatibilityGroup(
                id: id,
                members: members,
                catalogAnchorRelativePath: anchor
            )
        }
    }

    /// Rejects aliasing before any download begins. Catalog remapping can make
    /// distinct manifest paths converge on one active destination, while the
    /// legacy flattened partial-file naming can make distinct source paths
    /// converge in Downloads. Either collision would make transaction intent
    /// ambiguous after a crash.
    static func validateActivationPlan(
        _ groups: [ArkFileContentCompatibilityGroup],
        downloadRoot: URL
    ) throws {
        var canonicalPaths = Set<String>()
        var partialPaths = Set<String>()
        for group in groups {
            for member in group.members {
                let canonicalKey = normalizedPath(member.canonicalRelativePath).lowercased()
                guard !canonicalKey.isEmpty,
                      canonicalPaths.insert(canonicalKey).inserted else {
                    throw ArkFileContentError.duplicateManifestFile(
                        member.canonicalRelativePath
                    )
                }
                let partialKey = ArkFileContentDownloadPaths.partialDownloadURL(
                    for: member.entry,
                    in: downloadRoot
                ).standardizedFileURL.fileSystemPath.lowercased()
                guard partialPaths.insert(partialKey).inserted else {
                    throw ArkFileContentError.duplicateManifestFile(
                        member.entry.normalizedRelativePath
                    )
                }
            }
        }
    }

    /// Applies catalog exclusions to complete incoming compatibility groups.
    /// It never produces removal intent for groups already installed on disk.
    static func selection(
        manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?,
        excludedCatalogAnchorKeys: Set<String>
    ) -> ArkFileContentCompatibilitySelection {
        let normalizedExclusions = Set(
            excludedCatalogAnchorKeys.map { normalizedPath($0).lowercased() }
        )
        var selected: [ArkFileContentCompatibilityGroup] = []
        var excluded = Set<ArkFileContentCompatibilityGroupID>()

        for group in groups(manifest: manifest, catalog: catalog) {
            // Preserve legacy exclusion-based repair semantics. New explicit
            // requests use manifestFilteringDownloadRequest, which includes
            // this atomic group only for deliberately requested map content.
            guard group.id != coreMapGroupID else {
                selected.append(group)
                continue
            }
            if let anchor = group.catalogAnchorRelativePath,
               normalizedExclusions.contains(normalizedPath(anchor).lowercased()) {
                excluded.insert(group.id)
            } else {
                selected.append(group)
            }
        }

        return ArkFileContentCompatibilitySelection(
            selectedIncomingGroups: selected,
            excludedIncomingGroupIDs: excluded
        )
    }

    /// Group-aware replacement for per-entry manifest filtering. Missing or
    /// excluded groups only affect this incoming manifest; `deletedPaths` is
    /// neither synthesized nor expanded from catalog selection state.
    static func manifestFilteringExcludedCatalogAnchors(
        _ manifest: ArkFilePackageManifest,
        catalog: ArkFileContentCatalog?,
        excludedCatalogAnchorKeys: Set<String>
    ) throws -> ArkFilePackageManifest {
        guard !excludedCatalogAnchorKeys.isEmpty else { return manifest }
        let selection = selection(
            manifest: manifest,
            catalog: catalog,
            excludedCatalogAnchorKeys: excludedCatalogAnchorKeys
        )
        let files = selection.selectedIncomingGroups.flatMap(\.entries)
        guard !files.isEmpty else {
            throw ArkFileContentError.emptyContentManifest
        }
        return ArkFilePackageManifest(
            format: manifest.format,
            tier: manifest.tier,
            baselineTier: manifest.baselineTier,
            deliveryMode: manifest.deliveryMode,
            installedBytes: files.reduce(0) { $0 + $1.sizeBytes },
            files: files,
            compat: manifest.compat,
            deletedPaths: manifest.deletedPaths,
            product: manifest.product,
            variant: manifest.variant,
            sourceEdition: manifest.sourceEdition,
            baselineEdition: manifest.baselineEdition,
            installMode: manifest.installMode,
            filesIncluded: files.count,
            declaredBytesIncluded: files.reduce(0) { $0 + $1.sizeBytes },
            generatedAt: manifest.generatedAt
        )
    }

    private static func catalogAnchorsByGroupID(
        _ catalog: ArkFileContentCatalog?
    ) -> [ArkFileContentCompatibilityGroupID: String] {
        guard let catalog else { return [:] }
        var anchors: [ArkFileContentCompatibilityGroupID: String] = [:]
        let paths = Set(catalog.allItems.map(\.normalizedRelativePath)).sorted {
            let lhs = $0.lowercased()
            let rhs = $1.lowercased()
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        for path in paths {
            let id = groupID(for: path)
            guard id != coreMapGroupID, anchors[id] == nil else { continue }
            anchors[id] = path
        }
        return anchors
    }

    private static func fallbackAnchor(
        for id: ArkFileContentCompatibilityGroupID,
        members: [ArkFileContentCompatibilityGroup.Member]
    ) -> String? {
        guard id != coreMapGroupID else { return nil }
        if id.rawValue.hasPrefix("map-region:") {
            return members.first(where: {
                $0.canonicalRelativePath.lowercased().hasSuffix(".pmtiles")
            })?.canonicalRelativePath
        }
        if id.rawValue.hasPrefix("zim:") {
            if let unsplit = members.first(where: {
                $0.canonicalRelativePath.lowercased().hasSuffix(".zim")
            }) {
                return unsplit.canonicalRelativePath
            }
            guard let fragment = members.first,
                  let suffix = multipartZIMFragmentSuffix(fragment.canonicalRelativePath) else {
                return nil
            }
            return String(fragment.canonicalRelativePath.dropLast(suffix.count))
        }
        return members.first?.canonicalRelativePath
    }

    private static func memberSort(
        _ lhs: ArkFileContentCompatibilityGroup.Member,
        _ rhs: ArkFileContentCompatibilityGroup.Member
    ) -> Bool {
        let lhsPath = lhs.canonicalRelativePath.lowercased()
        let rhsPath = rhs.canonicalRelativePath.lowercased()
        if lhsPath != rhsPath { return lhsPath < rhsPath }
        return lhs.entry.relativePath < rhs.entry.relativePath
    }

    private static func multipartZIMAnchorPath(_ path: String) -> String? {
        if path.hasSuffix(".zim") { return path }
        guard let suffix = multipartZIMFragmentSuffix(path) else { return nil }
        return String(path.dropLast(suffix.count))
    }

    /// Returns the two letters following `.zim`, preserving their input case.
    private static func multipartZIMFragmentSuffix(_ path: String) -> String? {
        let lowercased = path.lowercased()
        guard lowercased.count >= 6 else { return nil }
        let suffix = String(lowercased.suffix(6))
        guard suffix.hasPrefix(".zim"), suffix.count == 6 else { return nil }
        let letters = suffix.suffix(2)
        guard letters.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
        return String(path.suffix(2))
    }

    private static func normalizedPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
