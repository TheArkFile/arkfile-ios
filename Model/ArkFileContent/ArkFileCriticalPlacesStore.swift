// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import SQLite3

struct ArkFileCriticalPlacesBoundingBox: Equatable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    var isValid: Bool {
        west.isFinite && south.isFinite && east.isFinite && north.isFinite
            && south >= -90 && north <= 90 && south <= north
            && west >= -180 && west <= 180 && east >= -180 && east <= 180
    }

    static func around(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double
    ) -> ArkFileCriticalPlacesBoundingBox {
        let latitudeDelta = radiusMeters / 111_320
        let cosine = max(0.1, cos(latitude * .pi / 180))
        let longitudeDelta = radiusMeters / (111_320 * cosine)
        return ArkFileCriticalPlacesBoundingBox(
            west: max(-180, longitude - longitudeDelta),
            south: max(-90, latitude - latitudeDelta),
            east: min(180, longitude + longitudeDelta),
            north: min(90, latitude + latitudeDelta)
        )
    }
}

enum ArkFileCriticalPlaceKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case hospital
    case clinic
    case pharmacy
    case fuel
    case food
    case water
    case police
    case fire
    case hardware

    var displayName: String {
        switch self {
        case .hospital:
            return "Hospital"
        case .clinic:
            return "Clinic"
        case .pharmacy:
            return "Pharmacy"
        case .fuel:
            return "Fuel"
        case .food:
            return "Food"
        case .water:
            return "Water"
        case .police:
            return "Police"
        case .fire:
            return "Fire"
        case .hardware:
            return "Hardware"
        }
    }

    var pluralDisplayName: String {
        switch self {
        case .hospital:
            return "Hospitals"
        case .clinic:
            return "Clinics"
        case .pharmacy:
            return "Pharmacies"
        case .fuel:
            return "Fuel"
        case .food:
            return "Food"
        case .water:
            return "Water"
        case .police:
            return "Police"
        case .fire:
            return "Fire"
        case .hardware:
            return "Hardware"
        }
    }

    var systemImage: String {
        switch self {
        case .hospital, .clinic:
            return "cross.case.fill"
        case .pharmacy:
            return "pills.fill"
        case .fuel:
            return "fuelpump.fill"
        case .food:
            return "cart.fill"
        case .water:
            return "drop.fill"
        case .police:
            return "shield.fill"
        case .fire:
            return "flame.fill"
        case .hardware:
            return "hammer.fill"
        }
    }

    var waypointKind: ArkFileMapWaypointKind {
        switch self {
        case .hospital, .clinic, .pharmacy:
            return .medical
        case .fuel:
            return .fuel
        case .food:
            return .food
        case .water:
            return .water
        case .police, .fire, .hardware:
            return .other
        }
    }
}

struct ArkFileCriticalPlace: Equatable, Identifiable, Sendable {
    let id: Int64
    let kind: ArkFileCriticalPlaceKind
    let name: String
    let latitude: Double
    let longitude: Double
    let locality: String?

    var coordinate: ArkFileMapCoordinate {
        ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        name.isEmpty ? kind.displayName : name
    }

    var detailText: String {
        if let locality, !locality.isEmpty {
            return "\(kind.displayName) · \(locality)"
        }
        return kind.displayName
    }
}

struct ArkFileCriticalPlaceMatch: Equatable, Identifiable, Sendable {
    let place: ArkFileCriticalPlace
    let distanceMeters: Double
    let bearingDegrees: Double

    var id: Int64 { place.id }

    var summaryText: String {
        ArkFileMapMeasurement.summaryText(
            distanceMeters: distanceMeters,
            bearingDegrees: bearingDegrees
        )
    }
}

/// Decides whether a viewport move actually needs a new database query.
/// Queries run against bounds padded beyond the visible viewport, so small
/// pans and zooms inside the padded area reuse the previous result instead
/// of hitting SQLite again.
struct ArkFileMapViewportQueryPlan: Equatable, Sendable {
    let queriedBounds: ArkFileCriticalPlacesBoundingBox
    let kinds: Set<ArkFileCriticalPlaceKind>

    static func make(
        visibleBounds: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>,
        paddingFraction: Double = 0.35
    ) -> ArkFileMapViewportQueryPlan {
        let latitudePadding = max(0, visibleBounds.north - visibleBounds.south) * paddingFraction
        let longitudePadding = max(0, visibleBounds.east - visibleBounds.west) * paddingFraction
        return ArkFileMapViewportQueryPlan(
            queriedBounds: ArkFileCriticalPlacesBoundingBox(
                west: max(-180, visibleBounds.west - longitudePadding),
                south: max(-90, visibleBounds.south - latitudePadding),
                east: min(180, visibleBounds.east + longitudePadding),
                north: min(90, visibleBounds.north + latitudePadding)
            ),
            kinds: kinds
        )
    }

    func covers(
        visibleBounds: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>
    ) -> Bool {
        guard self.kinds == kinds, visibleBounds.isValid else { return false }
        return visibleBounds.west >= queriedBounds.west
            && visibleBounds.east <= queriedBounds.east
            && visibleBounds.south >= queriedBounds.south
            && visibleBounds.north <= queriedBounds.north
    }
}

/// Read-only access to the Critical Places SQLite pack.
///
/// The connection is opened once and reused: opening the file per query made
/// every map pan pay for an open/close plus access-gate file checks, which is
/// exactly the kind of main-thread work that made the map feel laggy. All
/// database access is serialized on `queue`; the synchronous API (used by
/// tests and the ring search) hops onto that queue, and the `async` variants
/// let the map keep gestures responsive.
final class ArkFileCriticalPlacesStore: @unchecked Sendable {
    static let relativePath = "maps/poi/us_critical_places.sqlite"
    static let minimumViewportZoom = 9.0

    let databaseURL: URL?
    let canOpenFile: (URL) -> Bool
    private let readLease: ArkFileAuthoritativeReadLease?

    /// Probed once at creation: the map recreates the store whenever the
    /// content resources change, so this cannot go stale in practice, and it
    /// keeps file stats out of every SwiftUI body evaluation.
    let isAvailable: Bool

    private let queue = DispatchQueue(label: "app.arkfile.critical-places", qos: .userInitiated)
    private var connection: OpaquePointer?
    private var didAttemptOpen = false

    init(
        databaseURL: URL?,
        canOpenFile: ((URL) -> Bool)? = nil
    ) {
        if let canOpenFile {
            self.databaseURL = databaseURL
            self.canOpenFile = canOpenFile
            self.readLease = nil
        } else if let databaseURL,
                  let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: databaseURL) {
            self.databaseURL = readLease.url
            self.canOpenFile = { _ in true }
            self.readLease = readLease
        } else {
            self.databaseURL = databaseURL
            self.canOpenFile = { _ in false }
            self.readLease = nil
        }
        if let databaseURL = self.databaseURL {
            isAvailable = Self.regularFileExists(databaseURL) && self.canOpenFile(databaseURL)
        } else {
            isAvailable = false
        }
    }

    deinit {
        if let connection {
            sqlite3_close(connection)
        }
    }

    func places(
        in boundingBox: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int
    ) -> [ArkFileCriticalPlace] {
        queue.sync {
            placesOnQueue(in: boundingBox, kinds: kinds, limit: limit)
        }
    }

    /// Runs the viewport query off the calling thread and delivers on main.
    func placesAsync(
        in boundingBox: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int,
        completion: @escaping @MainActor ([ArkFileCriticalPlace]) -> Void
    ) {
        queue.async { [self] in
            let places = placesOnQueue(in: boundingBox, kinds: kinds, limit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(places)
                }
            }
        }
    }

    func nearest(
        to coordinate: ArkFileMapCoordinate,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int = 5
    ) -> [ArkFileCriticalPlaceMatch] {
        queue.sync {
            nearestOnQueue(to: coordinate, kinds: kinds, limit: limit)
        }
    }

    /// Runs the expanding ring search for every group in one queue hop and
    /// delivers on main — the Find Nearest sheet opens instantly while this
    /// works in the background.
    func nearestAsync(
        to coordinate: ArkFileMapCoordinate,
        kindGroups: [Set<ArkFileCriticalPlaceKind>],
        limit: Int = 5,
        completion: @escaping @MainActor ([[ArkFileCriticalPlaceMatch]]) -> Void
    ) {
        queue.async { [self] in
            let results = kindGroups.map {
                nearestOnQueue(to: coordinate, kinds: $0, limit: limit)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(results)
                }
            }
        }
    }

    private func placesOnQueue(
        in boundingBox: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int
    ) -> [ArkFileCriticalPlace] {
        guard boundingBox.isValid, !kinds.isEmpty, limit > 0,
              let database = openedConnection() else {
            return []
        }
        return queryPlaces(
            database: database,
            boundingBox: boundingBox,
            kinds: kinds,
            limit: limit
        )
    }

    private func nearestOnQueue(
        to coordinate: ArkFileMapCoordinate,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int
    ) -> [ArkFileCriticalPlaceMatch] {
        guard !kinds.isEmpty, limit > 0 else { return [] }
        var radius = 5_000.0
        while radius <= 500_000 {
            let boundingBox = ArkFileCriticalPlacesBoundingBox.around(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radiusMeters: radius
            )
            let candidates = placesOnQueue(
                in: boundingBox,
                kinds: kinds,
                limit: 2_000
            )
            let matches = candidates
                .map { place -> ArkFileCriticalPlaceMatch in
                    let distance = ArkFileMapMeasurement.distanceMeters(
                        fromLatitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        toLatitude: place.latitude,
                        longitude: place.longitude
                    )
                    let bearing = ArkFileMapMeasurement.bearingDegrees(
                        fromLatitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        toLatitude: place.latitude,
                        longitude: place.longitude
                    )
                    return ArkFileCriticalPlaceMatch(
                        place: place,
                        distanceMeters: distance,
                        bearingDegrees: bearing
                    )
                }
                .filter { $0.distanceMeters <= radius }
                .sorted { lhs, rhs in
                    if lhs.distanceMeters == rhs.distanceMeters {
                        return lhs.place.displayName < rhs.place.displayName
                    }
                    return lhs.distanceMeters < rhs.distanceMeters
                }
            if !matches.isEmpty {
                return Array(matches.prefix(limit))
            }
            radius *= 2
        }
        return []
    }

    /// Must be called on `queue`. Opens the connection once; the per-query
    /// access-gate check keeps committed-content authority fail-closed without
    /// paying a file open per query.
    private func openedConnection() -> OpaquePointer? {
        guard isAvailable, let databaseURL, canOpenFile(databaseURL) else { return nil }
        if let connection {
            return connection
        }
        guard !didAttemptOpen else { return nil }
        didAttemptOpen = true
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.fileSystemPath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        sqlite3_busy_timeout(database, 250)
        connection = database
        return database
    }

    private func queryPlaces(
        database: OpaquePointer,
        boundingBox: ArkFileCriticalPlacesBoundingBox,
        kinds: Set<ArkFileCriticalPlaceKind>,
        limit: Int
    ) -> [ArkFileCriticalPlace] {
        let orderedKinds = kinds.sorted { $0.rawValue < $1.rawValue }
        let placeholders = Array(repeating: "?", count: orderedKinds.count).joined(separator: ",")
        let sql = """
        SELECT p.id, p.kind, p.name, p.lat, p.lon, p.locality
        FROM places p
        JOIN places_rtree r ON p.id = r.id
        WHERE r.min_lat <= ?
          AND r.max_lat >= ?
          AND r.min_lon <= ?
          AND r.max_lon >= ?
          AND p.kind IN (\(placeholders))
        ORDER BY p.name COLLATE NOCASE ASC, p.id ASC
        LIMIT ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_double(statement, 1, boundingBox.north)
        sqlite3_bind_double(statement, 2, boundingBox.south)
        sqlite3_bind_double(statement, 3, boundingBox.east)
        sqlite3_bind_double(statement, 4, boundingBox.west)
        var bindIndex: Int32 = 5
        for kind in orderedKinds {
            sqlite3_bind_text(statement, bindIndex, kind.rawValue, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var places: [ArkFileCriticalPlace] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let place = Self.place(from: statement) else { continue }
            places.append(place)
        }
        return places
    }

    private static func place(from statement: OpaquePointer) -> ArkFileCriticalPlace? {
        let id = sqlite3_column_int64(statement, 0)
        guard let kindText = stringColumn(statement, 1),
              let kind = ArkFileCriticalPlaceKind(rawValue: kindText) else {
            return nil
        }
        let name = stringColumn(statement, 2) ?? kind.displayName
        let latitude = sqlite3_column_double(statement, 3)
        let longitude = sqlite3_column_double(statement, 4)
        guard ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        return ArkFileCriticalPlace(
            id: id,
            kind: kind,
            name: name,
            latitude: latitude,
            longitude: longitude,
            locality: stringColumn(statement, 5)
        )
    }

    private static func stringColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func regularFileExists(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
