// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileMapDiscoveryFilter: String, CaseIterable, Identifiable {
    case all
    case downloaded
    case available

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .downloaded: "Downloaded"
        case .available: "Available"
        }
    }

    func includes(isInstalled: Bool, hasAccess: Bool) -> Bool {
        switch self {
        case .all: true
        case .downloaded: isInstalled
        case .available: hasAccess && !isInstalled
        }
    }
}

extension Notification.Name {
    static let arkFileOpenContentDownloads = Notification.Name("arkFileOpenContentDownloads")
    static let arkFileOpenPackComparison = Notification.Name("arkFileOpenPackComparison")
    static let arkFileOpenMapRegion = Notification.Name("arkFileOpenMapRegion")
}

struct ArkFileMapRegionIndex: Decodable, Equatable, Sendable {
    let regions: [Region]

    struct Region: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let displayName: String
        let states: [String]
        let bounds: [Double]
        let sizeBytes: Int64?
        let maxZoom: Double

        var relativePath: String {
            "maps/regions/\(id)/region.pmtiles"
        }

        var formattedSize: String? {
            guard let sizeBytes, sizeBytes > 0 else { return nil }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: sizeBytes)
        }

        var statesDescription: String {
            states.map { ArkFileMapRegionIndex.stateNames[$0.uppercased()] ?? $0 }
                .joined(separator: ", ")
        }

        var center: ArkFileMapCoordinate? {
            guard bounds.count == 4 else { return nil }
            let longitude = bounds[0] <= bounds[2]
                ? (bounds[0] + bounds[2]) / 2
                : (bounds[0] + bounds[2] + 360) / 2
            return ArkFileMapCoordinate(
                latitude: (bounds[1] + bounds[3]) / 2,
                longitude: longitude > 180 ? longitude - 360 : longitude
            )
        }

        func matches(query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            // A state abbreviation is an exact state query; "OR" must not
            // match every region with "North" in its name.
            if ArkFileMapRegionIndex.stateNames[query.uppercased()] != nil {
                return states.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
            }
            let text = "\(displayName) \(statesDescription) \(states.joined(separator: " "))"
            return text.localizedStandardContains(query)
        }

        func contains(_ coordinate: ArkFileMapCoordinate) -> Bool {
            Self.bounds(bounds, contain: coordinate)
        }

        static func bounds(_ bounds: [Double], contain coordinate: ArkFileMapCoordinate) -> Bool {
            guard bounds.count == 4 else { return false }
            let west = bounds[0]
            let south = bounds[1]
            let east = bounds[2]
            let north = bounds[3]
            guard coordinate.latitude >= south, coordinate.latitude <= north else {
                return false
            }
            if west <= east {
                return coordinate.longitude >= west && coordinate.longitude <= east
            }
            return coordinate.longitude >= west || coordinate.longitude <= east
        }

        init(
            id: String,
            displayName: String,
            states: [String] = [],
            bounds: [Double],
            sizeBytes: Int64? = nil,
            maxZoom: Double
        ) {
            self.id = id
            self.displayName = displayName
            self.states = states
            self.bounds = bounds
            self.sizeBytes = sizeBytes
            self.maxZoom = maxZoom
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                ?? container.decodeIfPresent(String.self, forKey: .name)
                ?? id
            states = try container.decodeIfPresent([String].self, forKey: .states) ?? []
            if let decodedBounds = try container.decodeIfPresent([Double].self, forKey: .bounds) {
                bounds = decodedBounds
            } else {
                bounds = try container.decode([Double].self, forKey: .bbox)
            }
            sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
            maxZoom = try container.decodeIfPresent(Double.self, forKey: .maxZoom) ?? 14
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case name
            case states
            case bounds
            case bbox
            case sizeBytes
            case maxZoom
        }
    }

    static func loadBundled(bundle: Bundle = .main) -> ArkFileMapRegionIndex? {
        let candidates = [
            bundle.url(forResource: "regions-index", withExtension: "json", subdirectory: "OfflineMap"),
            bundle.url(forResource: "regions-index", withExtension: "json")
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(ArkFileMapRegionIndex.self, from: data) else {
                continue
            }
            return index
        }
        return nil
    }

    func region(containing coordinate: ArkFileMapCoordinate) -> Region? {
        regions(containing: coordinate).first
    }

    /// Regional extracts include a small border buffer, so a coordinate near
    /// an edge can legitimately be covered by more than one pack. Callers
    /// that explain coverage to people should show every match instead of
    /// implying the first bounding box is authoritative.
    func regions(containing coordinate: ArkFileMapCoordinate) -> [Region] {
        regions.filter { $0.contains(coordinate) }
    }

    func discoveryRegions(query: String, around center: ArkFileMapCoordinate) -> [Region] {
        regions.filter { $0.matches(query: query) }.sorted { lhs, rhs in
            if lhs.contains(center) != rhs.contains(center) { return lhs.contains(center) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func regionID(relativePath: String?) -> String? {
        guard let relativePath else { return nil }
        let parts = relativePath.replacingOccurrences(of: "\\", with: "/")
            .lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "maps", parts[1] == "regions",
              parts[3] == "region.pmtiles", !parts[2].isEmpty,
              parts[2] != ".", parts[2] != ".." else { return nil }
        return String(parts[2])
    }

    private static let stateNames = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
        "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
        "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii",
        "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
        "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
        "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming"
    ]
}

struct ArkFileMapRegionHint: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case downloadCompleteRegion
        case upgradeToComplete
    }

    let regions: [ArkFileMapRegionIndex.Region]
    let action: Action

    var region: ArkFileMapRegionIndex.Region? { regions.first }

    var text: String {
        guard let region else { return "Choose a regional street map for this area." }
        if regions.count > 1 {
            return "\(regions.count) regional downloads cover this area. Choose the street map you need."
        }
        switch action {
        case .downloadCompleteRegion:
            if let size = region.formattedSize {
                return "Add \(region.displayName) street-level map detail (\(size))."
            }
            return "Add \(region.displayName) street-level map detail."
        case .upgradeToComplete:
            return "Get \(region.displayName) street-level map detail with ArkFile Complete."
        }
    }

    static func resolve(
        center: ArkFileMapCoordinate,
        zoom: Double,
        bestAvailableMaxZoom: Double,
        index: ArkFileMapRegionIndex?,
        installedRegionIDs: Set<String>,
        dismissedRegionIDs: Set<String>,
        hasCompleteAccess: Bool
    ) -> ArkFileMapRegionHint? {
        let coverageMatches = (index?.regions(containing: center) ?? []).filter {
            $0.maxZoom > bestAvailableMaxZoom
                && !installedRegionIDs.contains($0.id)
                && !dismissedRegionIDs.contains($0.id)
        }
        guard zoom > bestAvailableMaxZoom + 0.5, !coverageMatches.isEmpty else {
            return nil
        }
        return ArkFileMapRegionHint(
            regions: coverageMatches,
            action: hasCompleteAccess ? .downloadCompleteRegion : .upgradeToComplete
        )
    }
}
