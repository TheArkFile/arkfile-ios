import CryptoKit
import Foundation

struct ArkFileVerifiedContentRelease: Sendable {
    let release: ArkFileContentRelease
    let binding: ArkFileContentReleaseBinding
    let envelope: Data
    fileprivate init(release: ArkFileContentRelease, binding: ArkFileContentReleaseBinding, envelope: Data) {
        self.release = release; self.binding = binding; self.envelope = envelope
    }

    func selectedFiles(for request: ArkFileContentReleaseRequest) throws -> [ArkFileContentRelease.File] {
        guard request.binding == binding, request.tier.isIOSInstallable,
              !request.selections.isEmpty,
              Set(request.selections.map(\.itemID)).count == request.selections.count else {
            throw ArkFileContentReleaseError.staleSelection
        }
        var groupIDs = Set<String>()
        var variants = Set<String>()
        for selection in request.selections {
            guard let item = release.item(selection.itemID), item.revisionID == selection.revisionID,
                  item.availability == "available",
                  request.tier == .complete || item.minimumTier == "lite" else {
                throw ArkFileContentReleaseError.staleSelection
            }
            guard release.isSupported(item) else {
                throw ArkFileContentReleaseError.incompatibleItem(item.catalog.name)
            }
            if let variant = item.catalog.variantGroup, !variant.isEmpty,
               !variants.insert(variant).inserted { throw ArkFileContentReleaseError.staleSelection }
            if selection.mode == .deleteFirst,
               release.group(item.primaryGroupID)?.kind != "zim" {
                throw ArkFileContentReleaseError.invalid("Only managed ZIMs support delete-first replacement.")
            }
            groupIDs.formUnion(item.groupIDs)
        }
        return release.files(for: groupIDs)
    }

    /// V2 permits independently selected PDFs/books/maps. The legacy validator's
    /// whole-pack requirement for a ZIM remains unchanged.
    func manifest(for request: ArkFileContentReleaseRequest) throws -> ArkFilePackageManifest {
        let selected = try selectedFiles(for: request)
        for file in selected { try file.manifestEntry.validate() }
        return ArkFilePackageManifest(format: 1, tier: request.tier.rawValue,
            baselineTier: nil, deliveryMode: "release-v2", installedBytes: nil,
            files: selected.map(\.manifestEntry), product: "ArkFile",
            sourceEdition: binding.releaseID, installMode: "manifest-v2",
            filesIncluded: selected.count, declaredBytesIncluded: selected.reduce(0) { $0 + $1.sizeBytes },
            generatedAt: release.createdAt)
    }
}

enum ArkFileContentReleaseVerifier {
    static let maximumPayloadBytes = 16 * 1024 * 1024
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    private struct Envelope: Decodable {
        let formatVersion: Int
        let keyID: String
        let payloadBase64: String
        let signatureBase64: String
    }

    static func verifyRelease(_ envelope: Data, keys: [String: Data],
                              expected: ArkFileContentReleaseBinding? = nil) throws -> ArkFileVerifiedContentRelease {
        let payload = try verifiedPayload(envelope, keys: keys)
        try validatePublicFields(payload)
        let release = try JSONDecoder().decode(ArkFileContentRelease.self, from: payload)
        try validate(release)
        let binding = ArkFileContentReleaseBinding(releaseID: release.releaseID, releaseSHA256: sha256(payload))
        if let expected, expected != binding { throw ArkFileContentReleaseError.untrustedSignature }
        return .init(release: release, binding: binding, envelope: envelope)
    }

    static func verifyPublication(_ envelope: Data, keys: [String: Data],
                                  previous: (sequence: Int64, digest: String)? = nil) throws -> ArkFileContentPublication {
        let payload = try verifiedPayload(envelope, keys: keys, maximumBytes: 256 * 1024)
        let index = try JSONDecoder().decode(ArkFileContentPublication.self, from: payload)
        guard index.schemaVersion == 2 else { throw ArkFileContentReleaseError.unsupportedSchema }
        guard index.kind == "content-index", index.product == "ArkFile", index.channel == "stable",
              index.publicationSequence > 0, index.publicationSequence <= maximumSafeInteger,
              index.releases.count <= 256, !index.releases.isEmpty,
              Set(index.releases.map(\.releaseID)).count == index.releases.count,
              index.current?.offered == true else { throw invalid("publication") }
        for release in index.releases {
            guard validID(release.releaseID), validHash(release.releaseSHA256),
                  ["available", "blocked"].contains(release.delivery),
                  release.reasonCode.map(validID) != false else { throw invalid("publication release") }
        }
        if let previous {
            guard index.publicationSequence >= previous.sequence,
                  index.publicationSequence != previous.sequence || sha256(payload) == previous.digest else {
                throw invalid("publication replay")
            }
        }
        return index
    }

    static func payloadDigest(_ envelope: Data, keys: [String: Data]) throws -> String {
        sha256(try verifiedPayload(envelope, keys: keys))
    }

    private static func verifiedPayload(_ bytes: Data, keys: [String: Data],
                                        maximumBytes: Int = maximumPayloadBytes) throws -> Data {
        guard bytes.count <= (maximumBytes + 2) / 3 * 4 + 2048 else { throw invalid("envelope too large") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.formatVersion == 1, validID(envelope.keyID),
              let rawKey = keys[envelope.keyID], rawKey.count == 32,
              let signature = Data(base64Encoded: envelope.signatureBase64), signature.count == 64, signature.base64EncodedString() == envelope.signatureBase64,
              envelope.payloadBase64.utf8.count <= (maximumBytes + 2) / 3 * 4,
              let payload = Data(base64Encoded: envelope.payloadBase64), payload.count <= maximumBytes, payload.base64EncodedString() == envelope.payloadBase64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              publicKey.isValidSignature(signature, for: payload) else {
            throw ArkFileContentReleaseError.untrustedSignature
        }
        return payload
    }

    static func validate(_ release: ArkFileContentRelease) throws {
        guard release.schemaVersion == 2 else { throw ArkFileContentReleaseError.unsupportedSchema }
        guard release.kind == "content-release", release.product == "ArkFile", validID(release.releaseID), ISO8601DateFormatter().date(from: release.createdAt) != nil,
              !release.items.isEmpty, release.items.count <= 10_000,
              !release.groups.isEmpty, release.groups.count <= 10_000,
              !release.files.isEmpty, release.files.count <= 20_000,
              Set(release.items.map(\.itemID)).count == release.items.count,
              Set(release.groups.map(\.groupID)).count == release.groups.count,
              Set(release.files.map(\.fileID)).count == release.files.count else { throw invalid("release identities") }
        let fileIDs = Set(release.files.map(\.fileID))
        var paths = Set<String>(), objectKeys = Set<String>(), catalogPaths = Set<String>(), owners = Set<String>(), usedGroups = Set<String>()
        var total: Int64 = 0
        for file in release.files {
            guard validID(file.fileID), validPath(file.relativePath), validPath(file.objectKey), file.objectKey.hasPrefix("content-packs/"),
                  objectKeys.insert(file.objectKey).inserted,
                  paths.insert(canonicalPath(file.relativePath)).inserted,
                  file.sizeBytes > 0, (file.mode.map { (0...0o777).contains($0) } ?? true), file.sizeBytes <= maximumSafeInteger, validHash(file.sha256) else {
                throw invalid("file identity")
            }
            let sum = total.addingReportingOverflow(file.sizeBytes)
            guard !sum.overflow, sum.partialValue <= maximumSafeInteger else { throw invalid("size overflow") }
            total = sum.partialValue
        }
        for group in release.groups {
            guard validID(group.groupID), validTier(group.minimumTier),
                  ["zim", "document", "map-core", "map-region"].contains(group.kind), !group.fileIDs.isEmpty,
                  Set(group.fileIDs).count == group.fileIDs.count,
                  Set(group.fileIDs).isSubset(of: fileIDs), validCapabilities(group.requiredCapabilities) else {
                throw invalid("group")
            }
            for id in group.fileIDs { guard owners.insert(id).inserted else { throw invalid("multiple file owners") } }
        }
        guard owners == fileIDs else { throw invalid("unowned file") }
        for item in release.items {
            guard validID(item.itemID), validID(item.revisionID), validTier(item.minimumTier),
                  !item.groupIDs.isEmpty, Set(item.groupIDs).count == item.groupIDs.count,
                  item.groupIDs.contains(item.primaryGroupID),
                  ["available", "withdrawn"].contains(item.availability),
                  validPath(item.catalog.relativePath), catalogPaths.insert(canonicalPath(item.catalog.relativePath)).inserted,
                  validText(item.catalog.name, maximum: 1024), validText(item.catalog.category, maximum: 1024),
                  validText(item.catalog.type, maximum: 1024), item.catalog.subcategory.utf8.count <= 1024,
                  [item.catalog.summary, item.catalog.variantGroup, item.catalog.variantLabel].allSatisfy({ $0.map { validText($0) } != false }),
                  validCapabilities(item.requiredCapabilities), validNotice(item.publicNotice) else { throw invalid("item") }
            for id in item.groupIDs {
                guard let group = release.group(id),
                      item.minimumTier == "complete" || group.minimumTier == "lite" else { throw invalid("cross-tier group") }
                usedGroups.insert(id)
            }
            // Catalog anchors may denote a multipart .zim or an extracted book,
            // but must resolve to their primary group's actual payload stem.
            guard let primary = release.group(item.primaryGroupID),
                  primary.fileIDs.compactMap(release.file).contains(where: {
                      let path = canonicalPath($0.relativePath), anchor = canonicalPath(item.catalog.relativePath)
                      return path == anchor || path.hasPrefix(anchor + "/")
                          || (anchor.hasSuffix(".zim") && path.hasPrefix(anchor)
                              && String(path.dropFirst(anchor.count)).range(of: "^[a-z]{2}$", options: .regularExpression) != nil)
                  }) else { throw invalid("catalog anchor") }
        }
        guard usedGroups == Set(release.groups.map(\.groupID)) else { throw invalid("unreferenced group") }
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
    static func validHash(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    static func validPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1024, !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.contains("?"), !value.contains("#"), !value.contains(":"), !value.hasPrefix("/"),
              !value.contains("%") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && String($0) == $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    static func canonicalPath(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    static func sha256(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func validTier(_ value: String) -> Bool { ["lite", "complete"].contains(value) }
    private static func validCapabilities(_ values: [String]) -> Bool {
        !values.isEmpty && values.count <= 32 && Set(values).count == values.count && values.allSatisfy(validID)
    }
    private static func validText(_ value: String, maximum: Int = 16384) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }
    private static func validNotice(_ value: ArkFileContentPublicNotice) -> Bool {
        [value.sourceTitle, value.attributionText, value.changesMade, value.rightsSummary].allSatisfy { validText($0) }
            && value.creators.count <= 256 && value.creators.allSatisfy { validText($0, maximum: 1024) }
            && [value.publisher, value.licenseID, value.licenseName].allSatisfy { $0.map { validText($0, maximum: 2048) } != false }
            && [value.canonicalURL, value.licenseURL].allSatisfy { text in
                guard let text else { return true }
                guard text.utf8.count <= 2048, let url = URL(string: text) else { return false }
                return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
            }
            && (value.internalNoticePaths?.count ?? 0) <= 128
            && value.internalNoticePaths?.allSatisfy(validPath) != false
    }
    private static func validatePublicFields(_ payload: Data) throws {
        let allowed: Set<String> = ["sourceTitle", "creators", "publisher", "canonicalURL", "attributionText", "changesMade", "rightsSummary", "licenseID", "licenseName", "licenseURL", "internalNoticePaths"]
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.allSatisfy({ item in
                  guard let notice = item["publicNotice"] as? [String: Any],
                        let catalog = item["catalog"] as? [String: Any] else { return false }
                  return Set(notice.keys).isSubset(of: allowed) && catalog["defaultSelected"] == nil
              }) else { throw invalid("public metadata") }
    }
    private static func invalid(_ reason: String) -> ArkFileContentReleaseError { .invalid(reason) }
}
