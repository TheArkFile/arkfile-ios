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

import CoreLocation
import Foundation

/// Older ArkFile builds require every stored date key. Keep their JSON reader
/// working without making an unknown date appear known in current models/UI.
/// The exact sentinel remains recognizable if an older build drops new flags.
enum ArkFileMapStoredDate {
    static let missingPlaceholder = Date.distantPast

    static func restore(_ date: Date?, isMissing: Bool = false) -> Date? {
        guard !isMissing, date != missingPlaceholder else { return nil }
        return date
    }
}

/// Value-type coordinate so map, parser, and tests can share the same
/// validation and focusing paths without depending on the SwiftUI map view.
struct ArkFileMapCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum ArkFileMapWaypointKind: String, Codable, CaseIterable, Equatable, Sendable {
    case meeting
    case water
    case shelter
    case medical
    case fuel
    case food
    case hazard
    case cache
    case other

    var displayName: String {
        switch self {
        case .meeting:
            return "Meeting"
        case .water:
            return "Water"
        case .shelter:
            return "Shelter"
        case .medical:
            return "Medical"
        case .fuel:
            return "Fuel"
        case .food:
            return "Food"
        case .hazard:
            return "Hazard"
        case .cache:
            return "Cache"
        case .other:
            return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .meeting:
            return "person.2.fill"
        case .water:
            return "drop.fill"
        case .shelter:
            return "house.fill"
        case .medical:
            return "cross.case.fill"
        case .fuel:
            return "fuelpump.fill"
        case .food:
            return "cart.fill"
        case .hazard:
            return "exclamationmark.triangle.fill"
        case .cache:
            return "shippingbox.fill"
        case .other:
            return "mappin.circle.fill"
        }
    }

    var colorComponents: (red: Double, green: Double, blue: Double) {
        switch self {
        case .meeting:
            return (0.08, 0.45, 0.58)
        case .water:
            return (0.05, 0.39, 0.78)
        case .shelter:
            return (0.24, 0.42, 0.25)
        case .medical:
            return (0.78, 0.13, 0.16)
        case .fuel:
            return (0.72, 0.42, 0.08)
        case .food:
            return (0.28, 0.47, 0.18)
        case .hazard:
            return (0.72, 0.22, 0.09)
        case .cache:
            return (0.42, 0.31, 0.18)
        case .other:
            return (0.28, 0.34, 0.38)
        }
    }
}

/// A user-dropped pin on the offline map: meeting point, water source,
/// shelter. Stored locally so it works with zero connectivity — the whole
/// point of an emergency waypoint.
struct ArkFileMapWaypoint: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    let latitude: Double
    let longitude: Double
    let createdAt: Date?
    var kind: ArkFileMapWaypointKind?

    var coordinateText: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    var coordinate: ArkFileMapCoordinate {
        ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
    }

    init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        createdAt: Date?,
        kind: ArkFileMapWaypointKind? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, createdAt, kind, createdAtIsMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude),
            createdAt: ArkFileMapStoredDate.restore(
                try container.decodeIfPresent(Date.self, forKey: .createdAt),
                isMissing: try container.decodeIfPresent(Bool.self, forKey: .createdAtIsMissing) ?? false
            ),
            kind: try container.decodeIfPresent(ArkFileMapWaypointKind.self, forKey: .kind)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(createdAt ?? ArkFileMapStoredDate.missingPlaceholder, forKey: .createdAt)
        if createdAt == nil { try container.encode(true, forKey: .createdAtIsMissing) }
        try container.encodeIfPresent(kind, forKey: .kind)
    }
}

/// Geodesic math for the offline map's measure tool. Pure functions so the
/// distance and bearing shown in an emergency can be unit-tested.
enum ArkFileMapMeasurement {
    static func distanceMeters(
        fromLatitude latA: Double, longitude lonA: Double,
        toLatitude latB: Double, longitude lonB: Double
    ) -> Double {
        // Haversine great-circle distance.
        let earthRadius = 6_371_000.0
        let phi1 = latA * .pi / 180
        let phi2 = latB * .pi / 180
        let dPhi = (latB - latA) * .pi / 180
        let dLambda = (lonB - lonA) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func bearingDegrees(
        fromLatitude latA: Double, longitude lonA: Double,
        toLatitude latB: Double, longitude lonB: Double
    ) -> Double {
        let phi1 = latA * .pi / 180
        let phi2 = latB * .pi / 180
        let dLambda = (lonB - lonA) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compassPoint(forBearing bearing: Double) -> String {
        let points = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
        ]
        let normalized = (bearing + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalized / 22.5).rounded()) % points.count
        return points[index]
    }

    /// e.g. "12.4 mi (20.0 km) · bearing 245° WSW · ~4 h 8 min walking"
    static func summaryText(distanceMeters: Double, bearingDegrees: Double) -> String {
        let miles = distanceMeters / 1_609.344
        let kilometers = distanceMeters / 1_000
        let distanceText: String
        if miles < 0.19 {
            let feet = distanceMeters * 3.28084
            distanceText = String(format: "%.0f ft (%.0f m)", feet, distanceMeters)
        } else {
            distanceText = String(format: "%.1f mi (%.1f km)", miles, kilometers)
        }
        let bearing = Int(bearingDegrees.rounded()) % 360
        let compass = compassPoint(forBearing: bearingDegrees)
        var summary = "\(distanceText) · bearing \(bearing)° \(compass)"
        // Straight-line walking estimate at a conservative 3 mph; real routes
        // are longer, which the toolkit's evacuation calculator accounts for.
        let walkingHours = miles / 3
        if walkingHours >= 0.1, walkingHours < 200 {
            let totalMinutes = Int((walkingHours * 60).rounded())
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours > 0 {
                summary += " · ~\(hours) h \(minutes) min walking"
            } else {
                summary += " · ~\(minutes) min walking"
            }
        }
        return summary
    }
}

@MainActor
final class ArkFileMapWaypointStore: ObservableObject {
    static let shared = ArkFileMapWaypointStore()

    private static let defaultsKey = "arkfile.map.waypoints.v1"
    nonisolated static let maxWaypoints = 200

    @Published private(set) var waypoints: [ArkFileMapWaypoint] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        waypoints = Self.loadPersisted(from: defaults)
    }

    @discardableResult
    func add(
        name: String,
        latitude: Double,
        longitude: Double,
        kind: ArkFileMapWaypointKind? = nil
    ) -> ArkFileMapWaypoint? {
        guard waypoints.count < Self.maxWaypoints else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let waypoint = ArkFileMapWaypoint(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "Waypoint \(waypoints.count + 1)" : trimmed,
            latitude: latitude,
            longitude: longitude,
            createdAt: Date(),
            kind: kind
        )
        waypoints.insert(waypoint, at: 0)
        persist()
        return waypoint
    }

    func update(id: String, name: String, kind: ArkFileMapWaypointKind?) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        waypoints[index].name = trimmed.isEmpty ? waypoints[index].name : trimmed
        waypoints[index].kind = kind
        persist()
    }

    func remove(id: String) {
        waypoints.removeAll { $0.id == id }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        persist()
    }

    @discardableResult
    func importWaypoints(_ importedWaypoints: [ArkFileMapWaypoint]) throws -> Int {
        try importWaypointsWithSummary(importedWaypoints).accepted.count
    }

    @discardableResult
    func importWaypointsWithSummary(
        _ importedWaypoints: [ArkFileMapWaypoint]
    ) throws -> ArkFileMapImportPlan<ArkFileMapWaypoint> {
        try applyPreparedImport(ArkFileMapGPX.prepareWaypoints(importedWaypoints, existing: waypoints))
    }

    @discardableResult
    func applyPreparedImport(
        _ prepared: ArkFileMapPreparedImport<ArkFileMapWaypoint>
    ) throws -> ArkFileMapImportPlan<ArkFileMapWaypoint> {
        guard waypoints == prepared.existingItems else { throw ArkFileMapImportError.storeChanged }
        guard prepared.plan.hasChanges else { return prepared.plan }
        guard let data = prepared.encodedData else { throw CocoaError(.fileWriteUnknown) }
        defaults.set(data, forKey: Self.defaultsKey)
        waypoints = prepared.updatedItems
        return prepared.plan
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(waypoints) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadPersisted(from defaults: UserDefaults) -> [ArkFileMapWaypoint] {
        guard let data = defaults.data(forKey: defaultsKey),
              let waypoints = try? JSONDecoder().decode([ArkFileMapWaypoint].self, from: data) else {
            return []
        }
        return waypoints
    }
}
