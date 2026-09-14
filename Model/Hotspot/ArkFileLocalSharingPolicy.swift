// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileLocalSharingZIMIdentity: Sendable {
    let registrationID: UUID
    let contentID: String
}

struct ArkFileLocalSharingServeDescriptor: Sendable {
    let canonicalPathKey: String
    let item: ArkFileLocalContentItem
    /// The open-session file identity is the serving invariant. It protects
    /// against replacement and truncation while a session is active without
    /// deciding whether an installed item is allowed to be shared.
    let sourceFileIdentity: ArkFileOpenFileIdentity?
    /// Optional install metadata is useful for a stable checksum/notice when it
    /// exists, but Build 328-compatible Local Sharing never requires it.
    let sourceIdentity: ArkFileInstalledContentAccess.CommittedSourceIdentity?
    let disposition: ArkFileLocalSharingDispositionIndex.Entry?
    let contentLicense: ArkFileContentLicenseEntry?
    let zimIdentity: ArkFileLocalSharingZIMIdentity?

    init(
        canonicalPathKey: String,
        item: ArkFileLocalContentItem,
        sourceFileIdentity: ArkFileOpenFileIdentity? = nil,
        sourceIdentity: ArkFileInstalledContentAccess.CommittedSourceIdentity?,
        disposition: ArkFileLocalSharingDispositionIndex.Entry?,
        contentLicense: ArkFileContentLicenseEntry?,
        zimIdentity: ArkFileLocalSharingZIMIdentity?
    ) {
        self.canonicalPathKey = canonicalPathKey
        self.item = item
        self.sourceFileIdentity = sourceFileIdentity
        self.sourceIdentity = sourceIdentity
        self.disposition = disposition
        self.contentLicense = contentLicense
        self.zimIdentity = zimIdentity
    }
}

/// The immutable content boundary for one user-started Local Sharing session.
/// Both the portal and the raw Kiwix server consume this snapshot so an item
/// cannot be hidden in the portal while remaining directly reachable by UUID.
struct ArkFileLocalSharingContentSnapshot: Sendable {
    let categories: [ArkFileLocalContentCategory]
    let libraryCategories: [ArkFileLibraryContentCategory]
    let favoriteItems: [ArkFileLocalContentItem]
    let zimFileIDs: Set<UUID>
    let shareableItemCount: Int
    let identity: String
    let descriptorsByCanonicalPath: [String: ArkFileLocalSharingServeDescriptor]
    let orderedDescriptorKeys: [String]
    let categoryDescriptorKeys: [ArkFileLocalContentCategoryKey: [String]]
    let favoriteDescriptorKeys: [String]
    let projectionHash: String?
    let ledgerVersion: String?

    init(
        categories: [ArkFileLocalContentCategory],
        libraryCategories: [ArkFileLibraryContentCategory],
        favoriteItems: [ArkFileLocalContentItem],
        zimFileIDs: Set<UUID>,
        shareableItemCount: Int,
        identity: String,
        descriptorsByCanonicalPath: [
            String: ArkFileLocalSharingServeDescriptor
        ] = [:],
        orderedDescriptorKeys: [String] = [],
        categoryDescriptorKeys: [
            ArkFileLocalContentCategoryKey: [String]
        ] = [:],
        favoriteDescriptorKeys: [String] = [],
        projectionHash: String? = nil,
        ledgerVersion: String? = nil
    ) {
        self.categories = categories
        self.libraryCategories = libraryCategories
        self.favoriteItems = favoriteItems
        self.zimFileIDs = zimFileIDs
        self.shareableItemCount = shareableItemCount
        self.identity = identity
        self.descriptorsByCanonicalPath = descriptorsByCanonicalPath
        self.orderedDescriptorKeys = orderedDescriptorKeys
        self.categoryDescriptorKeys = categoryDescriptorKeys
        self.favoriteDescriptorKeys = favoriteDescriptorKeys
        self.projectionHash = projectionHash
        self.ledgerVersion = ledgerVersion
    }

    static func make(
        categories: [ArkFileLocalContentCategory],
        libraryCategories: [ArkFileLibraryContentCategory],
        favoriteItems: [ArkFileLocalContentItem],
        additionalZimFileIDs: Set<UUID> = []
    ) -> ArkFileLocalSharingContentSnapshot {
        return make(
            categories: categories,
            libraryCategories: libraryCategories,
            favoriteItems: favoriteItems,
            dispositionIndex: try? ArkFileLocalSharingDispositionIndex.loadBundled(),
            licenseIndex: try? ArkFileContentLicenseIndex.loadBundled(),
            committedSourceIdentityProvider:
                ArkFileInstalledContentAccess.committedSourceIdentity,
            sourceFileIdentityProvider: ArkFileOpenFileIdentity.capture,
            additionalZimFileIDs: additionalZimFileIDs,
            allowedZimFileIDs: additionalZimFileIDs,
            additionalZimURLProvider: {
                ZimService.__sharedInstance().__getFileURL($0)
            },
            zimIdentityProvider: { item in
                // Raw Kiwix routes use the archive's embedded content ID, but
                // selecting an archive from CoreKiwix must use ArkFile's
                // stable app/Core Data alias for this registered path.
                guard let registrationID = ZimService.__sharedInstance()
                    .__registeredIdentifier(forFileURL: item.url),
                      let metadata = ZimService.__getMetaData(withFileURL: item.url),
                      !metadata.fileID.uuidString.isEmpty else {
                    return nil
                }
                return ArkFileLocalSharingZIMIdentity(
                    registrationID: registrationID,
                    contentID: metadata.fileID.uuidString.lowercased()
                )
            }
        )
    }

    static func make(
        categories: [ArkFileLocalContentCategory],
        libraryCategories: [ArkFileLibraryContentCategory],
        favoriteItems: [ArkFileLocalContentItem],
        dispositionIndex: ArkFileLocalSharingDispositionIndex?,
        licenseIndex: ArkFileContentLicenseIndex?,
        committedSourceIdentityProvider: (
            URL
        ) -> ArkFileInstalledContentAccess.CommittedSourceIdentity?,
        readAccessProvider: (URL) -> Bool = ArkFileInstalledContentAccess.canRead,
        sourceFileIdentityProvider: (
            URL
        ) -> ArkFileOpenFileIdentity? = ArkFileOpenFileIdentity.capture,
        additionalZimFileIDs: Set<UUID> = [],
        allowedZimFileIDs: Set<UUID>? = nil,
        additionalZimURLProvider: (UUID) -> URL? = { _ in nil },
        zimIdentityProvider: (
            ArkFileLocalContentItem
        ) -> ArkFileLocalSharingZIMIdentity?
    ) -> ArkFileLocalSharingContentSnapshot {
        var candidates: [ArkFileLocalContentItem]
        if libraryCategories.isEmpty {
            candidates = categories.flatMap(\.items)
        } else {
            candidates = libraryCategories.flatMap(\.items).compactMap {
                guard $0.isInstalled else { return nil }
                return $0.localItem
            }
        }

        let representedZimIDs = Set(
            candidates.compactMap { item -> UUID? in
                guard item.type == .zim else { return nil }
                return zimIdentityProvider(item)?.registrationID
            }
        )
        for zimFileID in additionalZimFileIDs.subtracting(representedZimIDs)
            .sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let url = additionalZimURLProvider(zimFileID) else { continue }
            let fileIdentity = sourceFileIdentityProvider(url)
            let fileSize = fileIdentity?.byteCount ?? 0
            let filename = url.lastPathComponent.isEmpty
                ? "\(zimFileID.uuidString).zim"
                : url.lastPathComponent
            candidates.append(
                ArkFileLocalContentItem(
                    name: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    relativePath: "imports/\(zimFileID.uuidString.lowercased())/\(filename)",
                    type: .zim,
                    category: .general,
                    subcategory: "Imported Library",
                    sizeBytes: fileSize,
                    isSampleContent: false,
                    sampleOriginalSubcategory: nil
                )
            )
        }

        // Resolve duplicate paths and ZIM aliases deterministically. The active
        // protected copy wins when one exists, but protected storage is not an
        // eligibility requirement.
        candidates.sort {
            let lhsProtected = ArkFileContentPackInstaller
                .isProtectedActiveContentURL($0.url)
            let rhsProtected = ArkFileContentPackInstaller
                .isProtectedActiveContentURL($1.url)
            if lhsProtected != rhsProtected {
                return lhsProtected
            }
            let lhsKey = ArkFileLocalSharingDispositionIndex.canonicalPath(
                $0.relativePath
            )
            let rhsKey = ArkFileLocalSharingDispositionIndex.canonicalPath(
                $1.relativePath
            )
            if lhsKey != rhsKey {
                return lhsKey < rhsKey
            }
            return $0.url.standardizedFileURL.fileSystemPath
                < $1.url.standardizedFileURL.fileSystemPath
        }

        var descriptors: [String: ArkFileLocalSharingServeDescriptor] = [:]
        var claimedZimContentIDs = Set<String>()
        var claimedZimRegistrationIDs = Set<UUID>()
        for item in candidates {
            let key = ArkFileLocalSharingDispositionIndex.canonicalPath(
                item.relativePath
            )
            guard descriptors[key] == nil,
                  !ArkFileContentRetirementPolicy.isRetired(
                      relativePath: item.relativePath
                  ),
                  readAccessProvider(item.url),
                  let sourceFileIdentity = sourceFileIdentityProvider(item.url)
            else {
                continue
            }
            let zimIdentity: ArkFileLocalSharingZIMIdentity?
            if item.type == .zim {
                guard let resolved = zimIdentityProvider(item) else { continue }
                let normalizedContentID = resolved.contentID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !normalizedContentID.isEmpty else { continue }
                let normalizedIdentity = ArkFileLocalSharingZIMIdentity(
                    registrationID: resolved.registrationID,
                    contentID: normalizedContentID
                )
                guard allowedZimFileIDs?.contains(
                    normalizedIdentity.registrationID
                ) != false else {
                    continue
                }
                guard claimedZimRegistrationIDs.insert(
                    normalizedIdentity.registrationID
                ).inserted,
                      claimedZimContentIDs.insert(
                          normalizedIdentity.contentID
                      ).inserted else {
                    continue
                }
                zimIdentity = normalizedIdentity
            } else {
                zimIdentity = nil
            }
            descriptors[key] = ArkFileLocalSharingServeDescriptor(
                canonicalPathKey: key,
                item: item,
                sourceFileIdentity: sourceFileIdentity,
                sourceIdentity: committedSourceIdentityProvider(item.url),
                disposition: dispositionIndex?.entry(
                    forRelativePath: item.relativePath
                ),
                contentLicense: licenseIndex?.entry(
                    forRelativePath: item.relativePath
                ),
                zimIdentity: zimIdentity
            )
        }

        let orderedKeys = descriptors.keys.sorted()
        let allowedKeys = Set(orderedKeys)
        var filteredCategories = categories.map { category in
            ArkFileLocalContentCategory(
                key: category.key,
                items: category.items.filter {
                    allowedKeys.contains(
                        ArkFileLocalSharingDispositionIndex.canonicalPath(
                            $0.relativePath
                        )
                    )
                }
            )
        }
        let categorizedKeys = Set(
            filteredCategories.flatMap(\.items).map {
                ArkFileLocalSharingDispositionIndex.canonicalPath(
                    $0.relativePath
                )
            }
        )
        let uncategorizedItems: [ArkFileLocalContentItem] =
            orderedKeys.compactMap { key -> ArkFileLocalContentItem? in
            guard !categorizedKeys.contains(key) else { return nil }
            return descriptors[key]?.item
        }
        if !uncategorizedItems.isEmpty,
           let generalIndex = filteredCategories.firstIndex(
               where: { $0.key == .general }
           ) {
            filteredCategories[generalIndex] = .init(
                key: .general,
                items: filteredCategories[generalIndex].items
                    + uncategorizedItems
            )
        } else if !uncategorizedItems.isEmpty {
            filteredCategories.append(
                .init(key: .general, items: uncategorizedItems)
            )
        }
        let filteredLibraryCategories = libraryCategories.map { category in
            ArkFileLibraryContentCategory(
                key: category.key,
                items: category.items.filter {
                    allowedKeys.contains(
                        ArkFileLocalSharingDispositionIndex.canonicalPath(
                            $0.relativePath
                        )
                    )
                }
            )
        }
        let filteredFavorites = favoriteItems.filter {
            allowedKeys.contains(
                ArkFileLocalSharingDispositionIndex.canonicalPath(
                    $0.relativePath
                )
            )
        }
        let categoryKeys = Dictionary(
            uniqueKeysWithValues: ArkFileLocalContentCategoryKey.allCases.map {
                category in
                let keys = orderedKeys.filter {
                    descriptors[$0]?.item.category == category
                }
                return (category, keys)
            }
        )
        let favoriteKeys = filteredFavorites.compactMap {
            item -> String? in
            let key = ArkFileLocalSharingDispositionIndex.canonicalPath(
                item.relativePath
            )
            return allowedKeys.contains(key) ? key : nil
        }
        let zimFileIDs = Set(
            descriptors.values.compactMap {
                $0.zimIdentity?.registrationID
            }
        )
        let identity = (
            orderedKeys.compactMap { key in
                guard let descriptor = descriptors[key],
                      let source = descriptor.sourceFileIdentity else {
                    return nil
                }
                return [
                    key,
                    String(source.device),
                    String(source.inode),
                    String(source.byteCount),
                    String(source.modificationSeconds),
                    String(source.modificationNanoseconds),
                    String(source.statusChangeSeconds),
                    String(source.statusChangeNanoseconds),
                    descriptor.zimIdentity?.registrationID.uuidString ?? "",
                    descriptor.zimIdentity?.contentID ?? ""
                ].joined(separator: "|")
            }
        ).joined(separator: "\n")

        return ArkFileLocalSharingContentSnapshot(
            categories: filteredCategories,
            libraryCategories: filteredLibraryCategories,
            favoriteItems: filteredFavorites,
            zimFileIDs: zimFileIDs,
            shareableItemCount: descriptors.count,
            identity: identity,
            descriptorsByCanonicalPath: descriptors,
            orderedDescriptorKeys: orderedKeys,
            categoryDescriptorKeys: categoryKeys,
            favoriteDescriptorKeys: favoriteKeys,
            projectionHash: dispositionIndex?.projectionHash,
            ledgerVersion: dispositionIndex?.source.ledgerVersion
        )
    }

    /// Dependency-injected form used by focused open-library tests. License
    /// and commit data may enrich notices and ETags, but never gate a readable
    /// installed file.
    static func make(
        categories: [ArkFileLocalContentCategory],
        libraryCategories: [ArkFileLibraryContentCategory],
        favoriteItems: [ArkFileLocalContentItem],
        licenseIndex: ArkFileContentLicenseIndex?,
        committedIdentityProvider: (URL) -> ArkFileInstalledContentAccess.CommittedArtifactIdentity?,
        zimFileIDProvider: (ArkFileLocalContentItem) -> UUID?
    ) -> ArkFileLocalSharingContentSnapshot {
        make(
            categories: categories,
            libraryCategories: libraryCategories,
            favoriteItems: favoriteItems,
            dispositionIndex: nil,
            licenseIndex: licenseIndex,
            committedSourceIdentityProvider: { url in
                .init(
                    artifact: committedIdentityProvider(url),
                    compatibilityGroupSHA256: nil
                )
            },
            sourceFileIdentityProvider: ArkFileOpenFileIdentity.capture,
            zimIdentityProvider: { item in
                guard let id = zimFileIDProvider(item) else { return nil }
                return .init(
                    registrationID: id,
                    contentID: id.uuidString.lowercased()
                )
            }
        )
    }
}

/// Retained only to audit the historical evidence projection. Local Sharing
/// does not call this Build 349-era policy; the active snapshot above follows
/// the Build 328 installed/readable contract.
enum ArkFileLocalSharingPolicy {
    struct Authorization: Sendable {
        let disposition: ArkFileLocalSharingDispositionIndex.Entry
        let sourceIdentity: ArkFileInstalledContentAccess.CommittedSourceIdentity
    }

    static func authorization(
        for item: ArkFileLocalContentItem,
        dispositionIndex: ArkFileLocalSharingDispositionIndex,
        committedSourceIdentityProvider: (
            URL
        ) -> ArkFileInstalledContentAccess.CommittedSourceIdentity?,
        managedSourceProtectionProvider: (URL) -> Bool = { _ in true },
        bundledSampleDigestProvider: (URL) -> String? = {
            try? ArkFileContentFileVerifier.sha256HexDigest(of: $0)
        }
    ) -> Authorization? {
        guard !ArkFileContentRetirementPolicy.isRetired(
            relativePath: item.relativePath
        ),
              let values = try? item.url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
                  .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              ArkFileInstalledContentAccess.canRead(item.url),
              let disposition = dispositionIndex.entry(
                  forRelativePath: item.relativePath
              ),
              disposition.disposition == "allow",
              disposition.type == item.type.rawValue,
              disposition.evidenceStatus == "green"
                || disposition.evidenceStatus == "yellow",
              item.type != .html else {
            return nil
        }

        if disposition.managed {
            guard !item.isBundledSampleAsset,
                  managedSourceProtectionProvider(item.url),
                  let sourceIdentity = committedSourceIdentityProvider(item.url),
                  let artifact = sourceIdentity.artifact,
                  let accepted = disposition.acceptedIdentity(
                      byteCount: artifact.byteCount,
                      sha256: artifact.sha256
                  ),
                  let expectedGroupFingerprint = expectedGroupFingerprint(
                      for: disposition,
                      acceptedIdentity: accepted
                  ),
                  sourceIdentity.compatibilityGroupSHA256
                    == expectedGroupFingerprint else {
                return nil
            }
            return Authorization(
                disposition: disposition,
                sourceIdentity: sourceIdentity
            )
        }

        guard item.isBundledSampleAsset,
              isImmutableBundledResource(item.url),
              let fileSize = values.fileSize,
              let digest = bundledSampleDigestProvider(item.url),
              let accepted = disposition.acceptedIdentity(
                  byteCount: Int64(fileSize),
                  sha256: digest
              ) else {
            return nil
        }
        return Authorization(
            disposition: disposition,
            sourceIdentity: .init(
                artifact: .init(
                    byteCount: accepted.sizeBytes,
                    sha256: accepted.sha256.lowercased()
                ),
                compatibilityGroupSHA256: nil
            )
        )
    }

    private static func expectedGroupFingerprint(
        for disposition: ArkFileLocalSharingDispositionIndex.Entry,
        acceptedIdentity: ArkFileLocalSharingDispositionIndex.Entry.AcceptedIdentity
    ) -> String? {
        let rawMembers = disposition.compatibilityGroupMembers
            .flatMap { $0.isEmpty ? nil : $0 }
        let members: [
            ArkFileInstalledContentAccess.CommitEntry
        ]
        if let rawMembers {
            members = rawMembers.map {
                ArkFileInstalledContentAccess.CommitEntry(
                    relativePath: $0.relativePath,
                    tier: ArkFileContentTier.lite.rawValue,
                    byteCount: $0.sizeBytes,
                    sha256: $0.sha256.lowercased()
                )
            }
        } else {
            members = [
                ArkFileInstalledContentAccess.CommitEntry(
                    relativePath: disposition.relativePath,
                    tier: ArkFileContentTier.lite.rawValue,
                    byteCount: acceptedIdentity.sizeBytes,
                    sha256: acceptedIdentity.sha256.lowercased()
                )
            ]
        }
        return ArkFileInstalledContentAccess.compatibilityGroupFingerprint(
            anchorRelativePath: disposition.relativePath,
            members: members
        )
    }

    static func canShare(
        _ item: ArkFileLocalContentItem,
        licenseIndex: ArkFileContentLicenseIndex?
    ) -> Bool {
        canShare(
            item,
            licenseIndex: licenseIndex,
            committedIdentityProvider: ArkFileInstalledContentAccess.committedArtifactIdentity
        )
    }

    static func canShare(
        _ item: ArkFileLocalContentItem,
        licenseIndex: ArkFileContentLicenseIndex?,
        committedIdentityProvider: (URL) -> ArkFileInstalledContentAccess.CommittedArtifactIdentity?
    ) -> Bool {
        guard !ArkFileContentRetirementPolicy.isRetired(relativePath: item.relativePath),
              (try? item.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              ArkFileInstalledContentAccess.canRead(item.url),
              let entry = licenseIndex?.entry(forRelativePath: item.relativePath),
              entry.decision.status.caseInsensitiveCompare("green") == .orderedSame,
              entry.allowsLocalSharing,
              entry.artifact.type == item.type.rawValue,
              entry.artifact.sizeBytes >= 0,
              entry.artifact.sha256.range(
                of: "^[A-Fa-f0-9]{64}$",
                options: .regularExpression
              ) != nil else {
            return false
        }

        // A single catalog row cannot authorize the map portal's wider set of
        // vector databases, regions, glyphs, sprites, and Critical Places data.
        // Static HTML can similarly reference an unbounded sibling tree. Both
        // stay closed until a whole-bundle projection validates every served
        // resource.
        guard item.type != .map, item.type != .html else {
            return false
        }

        let identity = committedIdentityProvider(item.url)
            ?? bundledSampleIdentity(for: item)
        guard let identity else { return false }
        return identity.byteCount == entry.artifact.sizeBytes
            && identity.sha256.caseInsensitiveCompare(entry.artifact.sha256) == .orderedSame
    }

    static func canShare(
        _ item: ArkFileLibraryContentItem,
        licenseIndex: ArkFileContentLicenseIndex?
    ) -> Bool {
        guard item.isInstalled, let localItem = item.localItem else { return false }
        return canShare(localItem, licenseIndex: licenseIndex)
    }

    private static func bundledSampleIdentity(
        for item: ArkFileLocalContentItem
    ) -> ArkFileInstalledContentAccess.CommittedArtifactIdentity? {
        guard item.isBundledSampleAsset,
              isImmutableBundledResource(item.url),
              let values = try? item.url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              let digest = try? ArkFileContentFileVerifier.sha256HexDigest(of: item.url) else {
            return nil
        }
        return .init(byteCount: Int64(fileSize), sha256: digest)
    }

    private static func isImmutableBundledResource(_ url: URL) -> Bool {
        let candidateRoots = [
            Bundle.main.resourceURL,
            Bundle(for: ArkFileLocalSharingPolicyBundleMarker.self).resourceURL
        ].compactMap { $0 }
        let lexicalPath = normalizedPath(url, resolvingSymlinks: false)
        let resolvedPath = normalizedPath(url, resolvingSymlinks: true)
        return candidateRoots.contains { root in
            let lexicalRoot = normalizedPath(root, resolvingSymlinks: false)
            let resolvedRoot = normalizedPath(root, resolvingSymlinks: true)
            return isDescendant(lexicalPath, of: lexicalRoot)
                && isDescendant(resolvedPath, of: resolvedRoot)
        }
    }

    private static func normalizedPath(_ url: URL, resolvingSymlinks: Bool) -> String {
        let normalized = resolvingSymlinks
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url.standardizedFileURL
        var path = normalized.fileSystemPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

private final class ArkFileLocalSharingPolicyBundleMarker: NSObject {}
