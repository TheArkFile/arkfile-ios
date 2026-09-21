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

struct ArkFileContentLicenseIndex: Decodable, Sendable {
    let schemaVersion: Int
    let projectionHash: String
    let entries: [ArkFileContentLicenseEntry]

    func entry(forRelativePath relativePath: String) -> ArkFileContentLicenseEntry? {
        let key = Self.canonicalPath(relativePath)
        return entries.first(where: {
            Self.canonicalPath($0.artifact.relativePath) == key
        })
    }

    static func loadBundled() throws -> ArkFileContentLicenseIndex {
        for bundle in candidateBundles() {
            if let url = bundle.url(
                forResource: "content-license-index",
                withExtension: "json",
                subdirectory: "ArkFileContentLicenses"
            ) ?? bundle.url(forResource: "content-license-index", withExtension: "json") {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(ArkFileContentLicenseIndex.self, from: data)
            }
        }
        throw ArkFileContentLicenseIndexError.missingBundledIndex
    }

    static func canonicalPath(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func candidateBundles() -> [Bundle] {
        let bundles = [
            Bundle.main,
            Bundle(for: ArkFileContentLicenseIndexBundleMarker.self)
        ]
        var seenIdentifiers = Set<String>()
        return bundles.filter { bundle in
            let identifier = bundle.bundleIdentifier ?? bundle.bundleURL.fileSystemPath
            return seenIdentifiers.insert(identifier).inserted
        }
    }
}

struct ArkFileContentLicenseEntry: Decodable, Identifiable, Hashable, Sendable {
    var id: String { contentId }

    let contentId: String
    let displayName: String
    let artifact: Artifact
    let source: Source
    let license: License
    let notices: Notices
    let downstreamRights: DownstreamRights

    var allowsLocalSharing: Bool {
        downstreamRights.allowedDistributionModes.contains("local-sharing")
    }

    struct Artifact: Decodable, Hashable, Sendable {
        let relativePath: String
        let type: String
        let sha256: String
        let sizeBytes: Int64
        let editionOrRevision: String
        let includedInTiers: [String]
    }

    struct Source: Decodable, Hashable, Sendable {
        let title: String
        let creators: [String]
        let publisher: String
        let canonicalUrl: String
        let artifactUrl: String?
        let retrievedAt: String
    }

    struct License: Decodable, Hashable, Sendable {
        let id: String
        let name: String
        let url: String
        let commercialUse: String
        let redistribution: String
        let modification: String
        let shareAlike: Bool
        let attributionRequired: Bool
        let noAdditionalRestrictions: Bool
    }

    struct Notices: Decodable, Hashable, Sendable {
        let attributionText: String
        let changesMade: String
        let requiredInternalFiles: [String]
    }

    struct DownstreamRights: Decodable, Hashable, Sendable {
        let summary: String
        let allowedDistributionModes: [String]
    }
}

enum ArkFileContentLicenseIndexError: LocalizedError {
    case missingBundledIndex

    var errorDescription: String? {
        switch self {
        case .missingBundledIndex:
            "ArkFile's title-level content license index is missing from the app bundle."
        }
    }
}

private final class ArkFileContentLicenseIndexBundleMarker: NSObject {}
