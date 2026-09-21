// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import CryptoKit
import Foundation

/// Immutable result of matching a backend-selected manifest to this build's
/// release projection. Activation receives this value instead of trusting a
/// server-supplied identifier or a generic JSON re-encoding.
struct ArkFileTrustedPackageManifest: Sendable {
    struct Identity: Codable, Hashable, Sendable {
        let manifestID: String
        let semanticFingerprint: String
    }

    let projectionHash: String
    let identity: Identity
    private let recognizedIdentities: Set<Identity>

    fileprivate init(
        projectionHash: String,
        identity: Identity,
        recognizedIdentities: Set<Identity>
    ) {
        self.projectionHash = projectionHash
        self.identity = identity
        self.recognizedIdentities = recognizedIdentities
    }

    /// Only a signature-verified, selection-validated v2 release can create this
    /// provenance. The immutable payload digest is the semantic identity.
    init(verifiedRelease: ArkFileVerifiedContentRelease,
         request: ArkFileContentReleaseRequest,
         previousVerifiedReleases: [ArkFileVerifiedContentRelease] = []) throws {
        _ = try verifiedRelease.selectedFiles(for: request)
        let identity = Identity(manifestID: "v2-" + verifiedRelease.binding.releaseID,
                                semanticFingerprint: verifiedRelease.binding.releaseSHA256)
        var recognized: Set<Identity> = [identity]
        for previous in previousVerifiedReleases {
            recognized.insert(Identity(manifestID: "v2-" + previous.binding.releaseID,
                                       semanticFingerprint: previous.binding.releaseSHA256))
        }
        if let legacy = try? ArkFileLocalSharingDispositionIndex.loadBundled() {
            recognized.formUnion(legacy.source.manifests.map {
                Identity(manifestID: $0.id, semanticFingerprint: $0.semanticFingerprint)
            })
        }
        self.init(projectionHash: verifiedRelease.binding.releaseSHA256,
                  identity: identity, recognizedIdentities: recognized)
    }

    func includingVerifiedReleases(_ releases: [ArkFileVerifiedContentRelease]) -> Self {
        let additional = Set(releases.map { Identity(manifestID: "v2-" + $0.binding.releaseID,
                                                      semanticFingerprint: $0.binding.releaseSHA256) })
        return Self(projectionHash: projectionHash, identity: identity,
                    recognizedIdentities: recognizedIdentities.union(additional))
    }

    func recognizes(
        _ provenance: ArkFileInstalledContentAccess.ManifestProvenance
    ) -> Bool {
        recognizedIdentities.contains(
            Identity(
                manifestID: provenance.manifestID,
                semanticFingerprint: provenance.semanticFingerprint.lowercased()
            )
        )
    }
}

/// Exact bundled content identities and public receiver notices. Private
/// approval evidence is checked by release tooling and is not shipped.
struct ArkFileLocalSharingDispositionIndex: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        struct Manifest: Decodable, Hashable, Sendable {
            let id: String
            let role: String
            let variant: String
            let tier: String
            let sourceEdition: String
            let generatedAt: String
            let sha256: String
            let semanticFingerprint: String
        }

        let catalogSHA256: String
        let currentManifestSHA256s: [String: String]
        let retainedManifestSHA256s: [String: String]
        let manifests: [Manifest]
    }

    struct Coverage: Decodable, Hashable, Sendable {
        let managedCatalogEntries: Int
        let bundledSampleEntries: Int
        let allowedEntries: Int
    }

    struct Entry: Decodable, Hashable, Identifiable, Sendable {
        struct AcceptedIdentity: Decodable, Hashable, Sendable {
            let sizeBytes: Int64
            let sha256: String
            let manifestIDs: [String]
        }

        struct CompatibilityGroupMember: Decodable, Hashable, Sendable {
            let relativePath: String
            let sizeBytes: Int64
            let sha256: String
            let manifestIDs: [String]
        }

        struct ReceiverNotice: Decodable, Hashable, Sendable {
            let sourceTitle: String
            let creators: [String]
            let publisher: String?
            let canonicalURL: String?
            let attributionText: String
            let changesMade: String
            let rightsSummary: String
        }

        var id: String { contentId }

        let contentId: String
        let displayName: String
        let relativePath: String
        let canonicalPath: String
        let type: String
        let managed: Bool
        let disposition: String
        var blockReason: String? = nil
        let acceptedIdentities: [AcceptedIdentity]
        let compatibilityGroupMembers: [CompatibilityGroupMember]?
        let receiverNotice: ReceiverNotice

        func acceptedIdentity(
            byteCount: Int64,
            sha256: String
        ) -> AcceptedIdentity? {
            acceptedIdentities.first {
                $0.sizeBytes == byteCount
                    && $0.sha256.caseInsensitiveCompare(sha256) == .orderedSame
            }
        }
    }

    let schemaVersion: Int
    let policyVersion: String
    let projectionHash: String
    let source: Source
    let coverage: Coverage
    let entries: [Entry]

    func entry(forRelativePath relativePath: String) -> Entry? {
        let key = Self.canonicalPath(relativePath)
        return entries.first { $0.canonicalPath == key }
    }

    func trustedPackageManifest(
        for manifest: ArkFilePackageManifest,
        expectedTier: ArkFileContentTier
    ) throws -> ArkFileTrustedPackageManifest {
        let semanticFingerprint = manifest.semanticFingerprint()
        let matches = source.manifests.filter {
            $0.role == "current"
                && $0.tier.lowercased() == expectedTier.rawValue
                && $0.semanticFingerprint.caseInsensitiveCompare(
                    semanticFingerprint
                ) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            throw ArkFileLocalSharingDispositionIndexError
                .unrecognizedPackageManifest
        }
        let identities = Set(source.manifests.map {
            ArkFileTrustedPackageManifest.Identity(
                manifestID: $0.id,
                semanticFingerprint: $0.semanticFingerprint.lowercased()
            )
        })
        return ArkFileTrustedPackageManifest(
            projectionHash: projectionHash.lowercased(),
            identity: .init(
                manifestID: match.id,
                semanticFingerprint: match.semanticFingerprint.lowercased()
            ),
            recognizedIdentities: identities
        )
    }

    static func loadBundled() throws -> ArkFileLocalSharingDispositionIndex {
        for bundle in candidateBundles() {
            if let url = bundle.url(
                forResource: "local-sharing-disposition-index",
                withExtension: "json",
                subdirectory: "ArkFileLocalSharing"
            ) ?? bundle.url(
                forResource: "local-sharing-disposition-index",
                withExtension: "json"
            ) {
                let data = try Data(contentsOf: url)
                return try decodeValidated(data)
            }
        }
        throw ArkFileLocalSharingDispositionIndexError.missingBundledIndex
    }

    static func decodeValidated(
        _ data: Data
    ) throws -> ArkFileLocalSharingDispositionIndex {
        let index = try JSONDecoder().decode(Self.self, from: data)
        try index.validateRuntimeShape()
        return index
    }

    static func canonicalPath(_ value: String) -> String {
        ArkFileContentCompatibilityPlanner.canonicalIdentityPath(value)
    }

    private func validateRuntimeShape() throws {
        guard schemaVersion == 2,
              policyVersion == "local-sharing-v1",
              Self.isSHA256(projectionHash),
              Self.isSHA256(source.catalogSHA256),
              !source.manifests.isEmpty,
              coverage.allowedEntries
                == entries.filter({ $0.disposition == "allow" }).count else {
            throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
        }
        guard source.currentManifestSHA256s.values.allSatisfy(Self.isSHA256),
              source.retainedManifestSHA256s.values.allSatisfy(Self.isSHA256)
        else {
            throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
        }
        var manifestIDs = Set<String>()
        var manifestHashes = Set<String>()
        var manifestFingerprints = Set<String>()
        var expectedCurrentHashes = [String: String]()
        var expectedRetainedHashes = [String: String]()
        guard source.manifests.count == Self.expectedManifestSources.count else {
            throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
        }
        for manifest in source.manifests {
            guard let expected = Self.expectedManifestSources[manifest.id] else {
                throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
            }
            let fingerprint = manifest.semanticFingerprint.lowercased()
            guard !manifest.id.isEmpty,
                  manifestIDs.insert(manifest.id).inserted,
                  manifest.role == expected.role,
                  manifest.variant == expected.variant,
                  manifest.tier == expected.tier,
                  manifest.sourceEdition == expected.sourceEdition,
                  !manifest.generatedAt.isEmpty,
                  Self.isSHA256(manifest.sha256),
                  manifestHashes.insert(manifest.sha256.lowercased()).inserted,
                  Self.isSHA256(fingerprint),
                  manifestFingerprints.insert(fingerprint).inserted else {
                throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
            }
            if expected.role == "current" {
                expectedCurrentHashes[expected.hashKey] = manifest.sha256
            } else {
                expectedRetainedHashes[expected.hashKey] = manifest.sha256
            }
        }
        guard source.currentManifestSHA256s == expectedCurrentHashes,
              source.retainedManifestSHA256s == expectedRetainedHashes else {
            throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
        }
        var paths = Set<String>()
        for entry in entries {
            guard !entry.contentId.isEmpty,
                  !entry.displayName.isEmpty,
                  entry.canonicalPath == Self.canonicalPath(entry.relativePath),
                  paths.insert(entry.canonicalPath).inserted,
                  ArkFileLocalContentType(rawValue: entry.type) != nil,
                  entry.disposition == "allow"
                    || (
                        entry.disposition == "block"
                            && entry.blockReason?.isEmpty == false
                    ),
                  entry.disposition != "allow"
                    || entry.blockReason == nil,
                  !entry.acceptedIdentities.isEmpty,
                  entry.acceptedIdentities.allSatisfy({
                      $0.sizeBytes >= 0
                          && Self.isSHA256($0.sha256)
                          && Self.isSortedUnique($0.manifestIDs)
                          && Set($0.manifestIDs).isSubset(of: manifestIDs)
                  }),
                  entry.compatibilityGroupMembers?.allSatisfy({
                      !$0.relativePath.isEmpty
                          && $0.sizeBytes >= 0
                          && Self.isSHA256($0.sha256)
                          && Self.isSortedUnique($0.manifestIDs)
                          && Set($0.manifestIDs).isSubset(of: manifestIDs)
                  }) != false else {
                throw ArkFileLocalSharingDispositionIndexError.invalidBundledIndex
            }
        }
    }

    private static func isSortedUnique(_ values: [String]) -> Bool {
        values == Array(Set(values)).sorted()
    }

    private struct ExpectedManifestSource {
        let role: String
        let variant: String
        let tier: String
        let sourceEdition: String
        let hashKey: String
    }

    private static let expectedManifestSources: [
        String: ExpectedManifestSource
    ] = [
        "current-lite-full": .init(
            role: "current",
            variant: "lite-full",
            tier: "lite",
            sourceEdition: "lite",
            hashKey: "liteFull"
        ),
        "current-complete-20260711": .init(
            role: "current",
            variant: "complete-full",
            tier: "complete",
            sourceEdition: "full",
            hashKey: "completeFull"
        ),
        "current-complete-from-lite-20260711": .init(
            role: "current",
            variant: "complete-from-lite",
            tier: "complete",
            sourceEdition: "full",
            hashKey: "completeFromLite"
        ),
        "retained-complete-20260708": .init(
            role: "retained",
            variant: "complete-full",
            tier: "complete",
            sourceEdition: "full",
            hashKey: "complete20260708"
        ),
        "retained-complete-textbooks-20260704": .init(
            role: "retained",
            variant: "complete-full",
            tier: "complete",
            sourceEdition: "full",
            hashKey: "completeTextbooks20260704"
        ),
    ]

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[A-Fa-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func candidateBundles() -> [Bundle] {
        let bundles = [
            Bundle.main,
            Bundle(for: ArkFileLocalSharingDispositionBundleMarker.self)
        ]
        var seen = Set<String>()
        return bundles.filter {
            seen.insert($0.bundleIdentifier ?? $0.bundleURL.fileSystemPath).inserted
        }
    }
}

enum ArkFileLocalSharingDispositionIndexError: LocalizedError {
    case missingBundledIndex
    case invalidBundledIndex
    case unrecognizedPackageManifest

    var errorDescription: String? {
        switch self {
        case .missingBundledIndex:
            "ArkFile's Local Sharing disposition index is missing from the app bundle."
        case .invalidBundledIndex:
            "ArkFile's Local Sharing disposition index is invalid."
        case .unrecognizedPackageManifest:
            "This ArkFile build does not recognize the content manifest selected by the service."
        }
    }
}

private final class ArkFileLocalSharingDispositionBundleMarker: NSObject {}

private struct ArkFileManifestSemanticFingerprintEncoder {
    private(set) var data = Data()

    mutating func append(_ name: String, _ value: String?) {
        guard let value else {
            data.append(Data("\(name):-\n".utf8))
            return
        }
        let normalized = value.precomposedStringWithCanonicalMapping
        let valueData = Data(normalized.utf8)
        data.append(Data("\(name):\(valueData.count):".utf8))
        data.append(valueData)
        data.append(0x0a)
    }
}

extension ArkFilePackageManifest {
    /// Domain-specific fingerprint of every field iOS treats as authoritative
    /// while installing. File/object order and JSON wrapper serialization are
    /// intentionally outside the contract.
    func semanticFingerprint() -> String {
        var encoder = ArkFileManifestSemanticFingerprintEncoder()
        encoder.append("contract", "arkfile-install-manifest-semantic-v1")
        encoder.append("format", format.map(String.init))
        encoder.append("product", product)
        encoder.append("variant", variant)
        encoder.append("tier", tier)
        encoder.append("baselineTier", baselineTier)
        encoder.append("deliveryMode", deliveryMode)
        encoder.append("sourceEdition", sourceEdition)
        encoder.append("baselineEdition", baselineEdition)
        encoder.append("installMode", installMode)
        encoder.append("installedBytes", installedBytes.map(String.init))
        encoder.append("filesIncluded", filesIncluded.map(String.init))
        encoder.append(
            "bytesIncluded",
            declaredBytesIncluded.map(String.init)
        )
        encoder.append("generatedAt", generatedAt)
        encoder.append(
            "compat.contentSchema",
            compat?.contentSchema.map(String.init)
        )
        encoder.append(
            "compat.minDesktopVersion",
            compat?.minDesktopVersion
        )
        encoder.append(
            "compat.minIOSBuild",
            compat?.minIOSBuild.map(String.init)
        )

        let deletedPaths = (deletedPaths ?? [])
            .map(Self.semanticManifestPath)
            .sorted(by: Self.semanticStringLessThan)
        encoder.append("deletedPaths.count", String(deletedPaths.count))
        for (index, deletedPath) in deletedPaths.enumerated() {
            encoder.append("deletedPaths.\(index)", deletedPath)
        }

        let files = files.sorted {
            let lhsCanonical = ArkFileContentCompatibilityPlanner
                .canonicalIdentityPath($0.relativePath)
            let rhsCanonical = ArkFileContentCompatibilityPlanner
                .canonicalIdentityPath($1.relativePath)
            if lhsCanonical != rhsCanonical {
                return Self.semanticStringLessThan(lhsCanonical, rhsCanonical)
            }
            let lhsPath = Self.semanticManifestPath($0.relativePath)
            let rhsPath = Self.semanticManifestPath($1.relativePath)
            if lhsPath != rhsPath {
                return Self.semanticStringLessThan(lhsPath, rhsPath)
            }
            return Self.semanticStringLessThan(
                Self.semanticManifestString($0.objectKey),
                Self.semanticManifestString($1.objectKey)
            )
        }
        encoder.append("files.count", String(files.count))
        for (index, file) in files.enumerated() {
            encoder.append(
                "files.\(index).relativePath",
                Self.semanticManifestPath(file.relativePath)
            )
            encoder.append(
                "files.\(index).objectKey",
                Self.semanticManifestString(file.objectKey)
            )
            encoder.append(
                "files.\(index).sizeBytes",
                String(file.sizeBytes)
            )
            encoder.append(
                "files.\(index).sha256",
                file.sha256.lowercased()
            )
            encoder.append(
                "files.\(index).mode",
                file.mode.map(String.init)
            )
            encoder.append(
                "files.\(index).variantGroup",
                file.variantGroup
            )
            encoder.append(
                "files.\(index).variantLabel",
                file.variantLabel
            )
            encoder.append(
                "files.\(index).variantDefault",
                file.variantDefault.map { $0 ? "1" : "0" }
            )
        }
        return SHA256.hash(data: encoder.data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func semanticManifestPath(_ value: String) -> String {
        semanticManifestString(value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func semanticManifestString(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private static func semanticStringLessThan(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }
}
