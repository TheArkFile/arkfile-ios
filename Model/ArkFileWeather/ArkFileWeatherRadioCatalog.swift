// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileWeatherRadioCatalog: Codable, Equatable, Sendable {
    enum Coverage: String, Codable, Equatable, Sendable {
        case designated
        case none
    }

    enum ListedStatus: String, Codable, Equatable, Sendable {
        case normal
        case degraded
        case outOfService
    }

    struct WeatherForecastOffice: Codable, Equatable, Sendable {
        let name: String
        let state: String
    }

    struct Transmitter: Codable, Equatable, Identifiable, Sendable {
        let callSign: String
        let frequencyMHz: Double
        let transmitterName: String
        let siteLocation: String
        let siteState: String
        let powerWatts: Double
        let listedStatus: ListedStatus
        let weatherForecastOffice: WeatherForecastOffice
        let coverageRemarks: String

        var id: String {
            "\(callSign)-\(frequencyMHz)"
        }
    }

    struct Area: Codable, Equatable, Identifiable, Sendable {
        let sameCode: String
        let countyZoneID: String
        let stateCode: String
        let stateName: String
        let areaName: String
        let coverage: Coverage
        let transmitters: [Transmitter]

        var id: String {
            "\(sameCode)-\(stateCode)-\(areaName)"
        }
    }

    struct Source: Codable, Equatable, Sendable {
        let cclURL: String
        let sameCodeURL: String
        let retrievedAt: Date
        let cclLastModified: Date
        let cclSHA256: String
        let sameCodeSHA256: String
        let sourceRowCount: Int
        let sameReferenceMatchCount: Int
        let sameReferenceMissingCount: Int
        let noCoverageAssignmentCount: Int
    }

    let schemaVersion: Int
    let generatedAt: Date
    let source: Source
    let areas: [Area]
    let payloadSHA256: String

    static func loadBundled(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(
            forResource: "noaa-nwr-catalog-v1",
            withExtension: "json"
        ) else {
            throw ArkFileWeatherRadioCatalogError.resourceMissing
        }
        let resourceValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true,
              let fileSize = resourceValues.fileSize,
              (1...8_000_000).contains(fileSize) else {
            throw ArkFileWeatherRadioCatalogError.resourceInvalid
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    /// Returns the exact point-specific SAME assignment. If the point metadata
    /// lacks a usable SAME code, a county-zone match is returned only when it
    /// is unambiguous; ArkFile never guesses among partial-county assignments.
    func area(sameCode: String?, countyZoneID: String?) -> Area? {
        if let sameCode,
           let exact = areas.first(where: { $0.sameCode == sameCode }) {
            return exact
        }
        guard let countyZoneID else { return nil }
        let matches = areas.filter { $0.countyZoneID == countyZoneID }
        return matches.count == 1 ? matches[0] : nil
    }

    func validate() throws {
        guard schemaVersion == 1,
              (3_000...10_000).contains(areas.count),
              source.sourceRowCount > 0,
              source.sameReferenceMatchCount + source.sameReferenceMissingCount
                == source.sourceRowCount,
              Self.isSHA256(payloadSHA256),
              Self.isSHA256(source.cclSHA256),
              Self.isSHA256(source.sameCodeSHA256) else {
            throw ArkFileWeatherRadioCatalogError.resourceInvalid
        }

        var identities = Set<String>()
        var transmitterCount = 0
        var noCoverageCount = 0
        for area in areas {
            guard area.sameCode.range(
                of: #"^\d{6}$"#,
                options: .regularExpression
            ) != nil,
            area.countyZoneID.range(
                of: #"^[A-Z]{2}C\d{3}$"#,
                options: .regularExpression
            ) != nil,
            area.countyZoneID
                == "\(area.stateCode)C\(area.sameCode.suffix(3))",
            identities.insert(area.id).inserted,
            area.transmitters.count <= 50 else {
                throw ArkFileWeatherRadioCatalogError.resourceInvalid
            }

            switch area.coverage {
            case .designated:
                guard !area.transmitters.isEmpty else {
                    throw ArkFileWeatherRadioCatalogError.resourceInvalid
                }
            case .none:
                guard area.transmitters.isEmpty else {
                    throw ArkFileWeatherRadioCatalogError.resourceInvalid
                }
                noCoverageCount += 1
            }

            var transmitterIdentities = Set<String>()
            for transmitter in area.transmitters {
                guard transmitter.callSign.range(
                    of: #"^[A-Z0-9]{3,12}$"#,
                    options: .regularExpression
                ) != nil,
                Self.allowedFrequencies.contains(transmitter.frequencyMHz),
                transmitterIdentities.insert(transmitter.id).inserted else {
                    throw ArkFileWeatherRadioCatalogError.resourceInvalid
                }
                transmitterCount += 1
            }
        }
        guard transmitterCount + noCoverageCount == source.sourceRowCount,
              noCoverageCount == source.noCoverageAssignmentCount else {
            throw ArkFileWeatherRadioCatalogError.resourceInvalid
        }
    }

    private static let allowedFrequencies: Set<Double> = [
        162.400,
        162.425,
        162.450,
        162.475,
        162.500,
        162.525,
        162.550
    ]

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil
    }
}

enum ArkFileWeatherRadioCatalogError: Error, Equatable, Sendable {
    case resourceMissing
    case resourceInvalid
}
