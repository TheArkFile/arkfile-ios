// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileWeatherRadioAreaIdentity: Codable, Equatable, Sendable {
    let sameCode: String
    let countyZoneID: String
    let displayName: String
}

enum ArkFileWeatherRadioUnavailableReason: Equatable, Sendable {
    case lookupMetadataMissing
    case noMatchingArea
    case catalogMissing
    case catalogInvalid
}

enum ArkFileWeatherRadioResolution: Equatable, Sendable {
    /// Every transmitter designated by NOAA for the exact area is preserved.
    /// The order remains the source-catalog order; it is not a signal ranking.
    case designated(
        area: ArkFileWeatherRadioAreaIdentity,
        transmitters: [ArkFileWeatherRadioTransmitter],
        catalogGeneratedAt: Date
    )
    /// NOAA explicitly listed no NWR coverage assignment for this area.
    case noCoverage(
        area: ArkFileWeatherRadioAreaIdentity,
        catalogGeneratedAt: Date
    )
    /// County-zone metadata matched more than one partial-county SAME area.
    /// ArkFile refuses to guess which assignment applies.
    case ambiguous(
        candidates: [ArkFileWeatherRadioAreaIdentity],
        catalogGeneratedAt: Date
    )
    case unavailable(ArkFileWeatherRadioUnavailableReason)
}

/// Resolves NOAA Weather Radio transmitters from exact point metadata.
///
/// This resolver never sorts by proximity, reception quality, transmitter
/// power, or a supposed "best" station. NOAA's county/SAME assignments are the
/// authority, and all designated transmitters are returned.
enum ArkFileWeatherRadioResolver {
    static func resolveBundled(
        sameCode: String?,
        countyZoneID: String?,
        bundle: Bundle = .main
    ) -> ArkFileWeatherRadioResolution {
        do {
            return resolve(
                sameCode: sameCode,
                countyZoneID: countyZoneID,
                catalog: try ArkFileWeatherRadioCatalog.loadBundled(
                    bundle: bundle
                )
            )
        } catch ArkFileWeatherRadioCatalogError.resourceMissing {
            return .unavailable(.catalogMissing)
        } catch {
            return .unavailable(.catalogInvalid)
        }
    }

    static func resolve(
        sameCode: String?,
        countyZoneID: String?,
        catalog: ArkFileWeatherRadioCatalog
    ) -> ArkFileWeatherRadioResolution {
        let normalizedSAME = normalized(sameCode)?.filter(\.isNumber)
        let normalizedZone = normalized(countyZoneID)?.uppercased()

        if let normalizedSAME, !normalizedSAME.isEmpty {
            let matches = catalog.areas.filter {
                $0.sameCode == normalizedSAME
            }
            if matches.count == 1, let area = matches.first {
                return resolution(
                    for: area,
                    catalogGeneratedAt: catalog.generatedAt
                )
            }
            if matches.count > 1 {
                return .ambiguous(
                    candidates: matches.map(areaIdentity),
                    catalogGeneratedAt: catalog.generatedAt
                )
            }
        }

        guard let normalizedZone, !normalizedZone.isEmpty else {
            return .unavailable(.lookupMetadataMissing)
        }
        let zoneMatches = catalog.areas.filter {
            $0.countyZoneID.uppercased() == normalizedZone
        }
        if zoneMatches.count == 1, let area = zoneMatches.first {
            return resolution(
                for: area,
                catalogGeneratedAt: catalog.generatedAt
            )
        }
        if zoneMatches.count > 1 {
            return .ambiguous(
                candidates: zoneMatches.map(areaIdentity),
                catalogGeneratedAt: catalog.generatedAt
            )
        }
        return .unavailable(.noMatchingArea)
    }

    /// Required receiver and staleness disclosure for the NWR section.
    static func receiverAndCatalogDisclosure(
        catalogGeneratedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: catalogGeneratedAt)
        return "\(ArkFileDeviceCopy.thisDeviceCapitalized) cannot receive "
            + "NOAA Weather Radio broadcasts. "
            + "Use an external NOAA Weather Radio receiver. "
            + "Transmitter status is listed as of the NOAA catalog time "
            + "\(timestamp) and may have changed."
    }

    private static func resolution(
        for area: ArkFileWeatherRadioCatalog.Area,
        catalogGeneratedAt: Date
    ) -> ArkFileWeatherRadioResolution {
        let identity = areaIdentity(area)
        guard area.coverage == .designated else {
            return .noCoverage(
                area: identity,
                catalogGeneratedAt: catalogGeneratedAt
            )
        }
        return .designated(
            area: identity,
            transmitters: area.transmitters.map {
                map($0, for: area)
            },
            catalogGeneratedAt: catalogGeneratedAt
        )
    }

    private static func map(
        _ transmitter: ArkFileWeatherRadioCatalog.Transmitter,
        for area: ArkFileWeatherRadioCatalog.Area
    ) -> ArkFileWeatherRadioTransmitter {
        let listedStatus = switch transmitter.listedStatus {
        case .normal:
            "NOAA listed status: normal."
        case .degraded:
            "NOAA listed status: degraded."
        case .outOfService:
            "NOAA listed status: out of service."
        }
        let remarks = transmitter.coverageRemarks.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let coverageNote = remarks.isEmpty
            ? listedStatus
            : "\(remarks) \(listedStatus)"

        let transmitterName = transmitter.transmitterName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let siteLocation = transmitter.siteLocation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let siteName: String
        if transmitterName.isEmpty {
            siteName = "\(siteLocation), \(transmitter.siteState)"
        } else if siteLocation.isEmpty || transmitterName == siteLocation {
            siteName = "\(transmitterName), \(transmitter.siteState)"
        } else {
            siteName = "\(transmitterName) — \(siteLocation), "
                + transmitter.siteState
        }

        return ArkFileWeatherRadioTransmitter(
            id: transmitter.id,
            callSign: transmitter.callSign,
            frequencyMegahertz: transmitter.frequencyMHz,
            channel: channel(for: transmitter.frequencyMHz),
            siteName: siteName,
            coordinate: nil,
            sameCounties: [
                ArkFileWeatherSAMECounty(
                    code: area.sameCode,
                    displayName: areaIdentity(area).displayName
                )
            ],
            coverageNote: coverageNote
        )
    }

    private static func channel(for frequencyMHz: Double) -> String? {
        switch frequencyMHz {
        case 162.550: "WX1"
        case 162.400: "WX2"
        case 162.475: "WX3"
        case 162.425: "WX4"
        case 162.450: "WX5"
        case 162.500: "WX6"
        case 162.525: "WX7"
        default: nil
        }
    }

    private static func areaIdentity(
        _ area: ArkFileWeatherRadioCatalog.Area
    ) -> ArkFileWeatherRadioAreaIdentity {
        ArkFileWeatherRadioAreaIdentity(
            sameCode: area.sameCode,
            countyZoneID: area.countyZoneID,
            displayName: "\(area.areaName), \(area.stateCode)"
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
