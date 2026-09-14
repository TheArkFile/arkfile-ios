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

#if os(iOS)
import CoreLocation
import Foundation

struct ArkFileTrackPoint: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date?

    init(latitude: Double, longitude: Double, timestamp: Date?) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case latitude, longitude, timestamp, timestampIsMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude),
            timestamp: ArkFileMapStoredDate.restore(
                try container.decodeIfPresent(Date.self, forKey: .timestamp),
                isMissing: try container.decodeIfPresent(Bool.self, forKey: .timestampIsMissing) ?? false
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(timestamp ?? ArkFileMapStoredDate.missingPlaceholder, forKey: .timestamp)
        if timestamp == nil { try container.encode(true, forKey: .timestampIsMissing) }
    }
}

enum ArkFileMapTrackKind: String, Codable, Equatable, Sendable {
    case recordedTrail
    case plannedRoute

    var displayName: String {
        switch self {
        case .recordedTrail: return "Recorded trail"
        case .plannedRoute: return "Planned route"
        }
    }
}

/// A recorded breadcrumb trail: GPS points captured while moving, so a route
/// can be retraced with no connectivity at all.
struct ArkFileMapTrack: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    let points: [ArkFileTrackPoint]
    let startedAt: Date?
    let endedAt: Date?
    let kind: ArkFileMapTrackKind
    /// Indices at which independent GPX segments begin. Old saved tracks are
    /// one continuous segment; imported gaps must never become connecting lines.
    let segmentStartIndices: [Int]

    init(
        id: String, name: String, points: [ArkFileTrackPoint],
        startedAt: Date?, endedAt: Date?,
        kind: ArkFileMapTrackKind = .recordedTrail,
        segmentStartIndices: [Int] = [0]
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.segmentStartIndices = Self.validSegmentStarts(segmentStartIndices, pointCount: points.count)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, points, startedAt, endedAt, kind, segmentStartIndices, startedAtIsMissing, endedAtIsMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            points: try container.decode([ArkFileTrackPoint].self, forKey: .points),
            startedAt: ArkFileMapStoredDate.restore(
                try container.decodeIfPresent(Date.self, forKey: .startedAt),
                isMissing: try container.decodeIfPresent(Bool.self, forKey: .startedAtIsMissing) ?? false
            ),
            endedAt: ArkFileMapStoredDate.restore(
                try container.decodeIfPresent(Date.self, forKey: .endedAt),
                isMissing: try container.decodeIfPresent(Bool.self, forKey: .endedAtIsMissing) ?? false
            ),
            kind: try container.decodeIfPresent(ArkFileMapTrackKind.self, forKey: .kind) ?? .recordedTrail,
            segmentStartIndices: try container.decodeIfPresent([Int].self, forKey: .segmentStartIndices) ?? [0]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(points, forKey: .points)
        try container.encode(startedAt ?? ArkFileMapStoredDate.missingPlaceholder, forKey: .startedAt)
        try container.encode(endedAt ?? ArkFileMapStoredDate.missingPlaceholder, forKey: .endedAt)
        if startedAt == nil { try container.encode(true, forKey: .startedAtIsMissing) }
        if endedAt == nil { try container.encode(true, forKey: .endedAtIsMissing) }
        try container.encode(kind, forKey: .kind)
        try container.encode(segmentStartIndices, forKey: .segmentStartIndices)
    }

    var segments: [[ArkFileTrackPoint]] {
        segmentStartIndices.enumerated().map { index, start in
            let end = index + 1 < segmentStartIndices.count ? segmentStartIndices[index + 1] : points.count
            return Array(points[start..<end])
        }
    }

    private static func validSegmentStarts(_ starts: [Int], pointCount: Int) -> [Int] {
        guard pointCount > 0 else { return [] }
        return Set(starts.filter { $0 >= 0 && $0 < pointCount } + [0]).sorted()
    }

    var totalDistanceMeters: Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        let breaks = Set(segmentStartIndices)
        for index in 1..<points.count where !breaks.contains(index) {
            total += ArkFileMapMeasurement.distanceMeters(
                fromLatitude: points[index - 1].latitude, longitude: points[index - 1].longitude,
                toLatitude: points[index].latitude, longitude: points[index].longitude
            )
        }
        return total
    }
}

/// Records breadcrumb trails and exposes the device's current position for
/// the offline map. Recording keeps running with the app in the background
/// (iOS shows its location indicator) and is battery-conscious: points are
/// only kept every ~15 meters of movement and poor fixes are discarded.
@MainActor
final class ArkFileMapTrackRecorder: NSObject, ObservableObject {
    static let shared = ArkFileMapTrackRecorder()

    static let minimumPointSpacingMeters: CLLocationDistance = 15
    static let maximumHorizontalAccuracyMeters: CLLocationAccuracy = 60
    static let maximumPointsPerTrack = 20_000
    nonisolated static let maximumSavedTracks = 20

    @Published private(set) var isRecording = false
    @Published private(set) var activePoints: [ArkFileTrackPoint] = []
    @Published private(set) var savedTracks: [ArkFileMapTrack] = []
    /// Deliberately NOT `@Published`: the map reads this on demand (locate,
    /// share, find-nearest) and MapLibre draws the user-location dot itself.
    /// Publishing it re-rendered the entire map screen on every GPS fix,
    /// which made panning stutter whenever the user was moving.
    private(set) var currentLocation: ArkFileMapCoordinate?
    @Published private(set) var isAuthorizationDenied = false

    private let manager = CLLocationManager()
    private let persistenceURL: URL?
    private var liveUpdateRequests = 0
    private var recordingStartedAt: Date?
    private var activeDistanceAccumulator = 0.0

    private override init() {
        persistenceURL = Self.tracksFileURL()
        super.init()
        manager.delegate = self
        configurePassiveLocationMode()
        savedTracks = Self.loadPersistedTracks(from: persistenceURL)
    }

    /// Isolated storage for verification and previews; never starts GPS updates.
    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        super.init()
        manager.delegate = self
        configurePassiveLocationMode()
        savedTracks = Self.loadPersistedTracks(from: persistenceURL)
    }

    var activeDistanceMeters: Double {
        activeDistanceAccumulator
    }

    /// Distance and compass direction straight back to where recording began.
    var backToStartSummary: String? {
        guard let start = activePoints.first,
              let here = currentLocation else { return nil }
        let meters = ArkFileMapMeasurement.distanceMeters(
            fromLatitude: here.latitude, longitude: here.longitude,
            toLatitude: start.latitude, longitude: start.longitude
        )
        guard meters > 30 else { return nil }
        let bearing = ArkFileMapMeasurement.bearingDegrees(
            fromLatitude: here.latitude, longitude: here.longitude,
            toLatitude: start.latitude, longitude: start.longitude
        )
        let miles = meters / 1_609.344
        let distanceText = miles < 0.19
            ? String(format: "%.0f ft", meters * 3.28084)
            : String(format: "%.1f mi", miles)
        return "\(distanceText) \(ArkFileMapMeasurement.compassPoint(forBearing: bearing)) back to start"
    }

    // MARK: - Live position (map visible)

    /// The map calls this while visible so the position readout stays fresh;
    /// balanced by endLiveUpdates. Recording keeps updates running regardless.
    func beginLiveUpdates() {
        liveUpdateRequests += 1
        requestAuthorizationIfNeeded()
        if !isRecording {
            configurePassiveLocationMode()
        }
        startLiveLocationIfAllowed()
    }

    func endLiveUpdates() {
        liveUpdateRequests = max(0, liveUpdateRequests - 1)
        if liveUpdateRequests == 0 && !isRecording {
            manager.stopUpdatingLocation()
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        requestAuthorizationIfNeeded()
        isRecording = true
        recordingStartedAt = Date()
        activePoints = []
        activeDistanceAccumulator = 0
        configureRecordingLocationMode()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        startUpdatesIfAllowed()
    }

    func stopRecordingAndSave(name: String) {
        guard isRecording else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = recordingStartedAt ?? activePoints.first?.timestamp ?? Date()
        if activePoints.count > 1 {
            let track = ArkFileMapTrack(
                id: UUID().uuidString,
                name: trimmed.isEmpty ? Self.defaultTrackName(for: startedAt) : trimmed,
                points: activePoints,
                startedAt: startedAt,
                endedAt: Date()
            )
            savedTracks.insert(track, at: 0)
            if savedTracks.count > Self.maximumSavedTracks {
                savedTracks = Array(savedTracks.prefix(Self.maximumSavedTracks))
            }
            persistTracks()
        }
        finishRecording()
    }

    func discardRecording() {
        guard isRecording else { return }
        finishRecording()
    }

    func removeTrack(id: String) {
        savedTracks.removeAll { $0.id == id }
        persistTracks()
    }

    func removeTracks(atOffsets offsets: IndexSet) {
        savedTracks.remove(atOffsets: offsets)
        persistTracks()
    }

    @discardableResult
    func importTracks(_ tracks: [ArkFileMapTrack]) throws -> Int {
        try importTracksWithSummary(tracks).accepted.count
    }

    @discardableResult
    func importTracksWithSummary(_ tracks: [ArkFileMapTrack]) throws -> ArkFileMapImportPlan<ArkFileMapTrack> {
        try applyPreparedImport(ArkFileMapGPX.prepareTracks(tracks, existing: savedTracks))
    }

    @discardableResult
    func applyPreparedImport(
        _ prepared: ArkFileMapPreparedImport<ArkFileMapTrack>
    ) throws -> ArkFileMapImportPlan<ArkFileMapTrack> {
        guard savedTracks == prepared.existingItems else { throw ArkFileMapImportError.storeChanged }
        guard prepared.plan.hasChanges else { return prepared.plan }
        guard let data = prepared.encodedData else { throw CocoaError(.fileWriteUnknown) }
        // The review must not report success when the atomic disk write fails.
        try persistTracks(data: data)
        savedTracks = prepared.updatedItems
        return prepared.plan
    }

    private func finishRecording() {
        isRecording = false
        recordingStartedAt = nil
        activePoints = []
        activeDistanceAccumulator = 0
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = true
        if liveUpdateRequests == 0 {
            manager.stopUpdatingLocation()
        } else {
            configurePassiveLocationMode()
            startLiveLocationIfAllowed()
        }
    }

    private func requestAuthorizationIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    private func startUpdatesIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isAuthorizationDenied = false
            manager.startUpdatingLocation()
        case .denied, .restricted:
            isAuthorizationDenied = true
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func startLiveLocationIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isAuthorizationDenied = false
            manager.startUpdatingLocation()
        case .denied, .restricted:
            isAuthorizationDenied = true
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func configurePassiveLocationMode() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
    }

    private func configureRecordingLocationMode() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = Self.minimumPointSpacingMeters
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    fileprivate func handleAuthorizationChange() {
        if isRecording {
            startUpdatesIfAllowed()
        } else if liveUpdateRequests > 0 {
            startLiveLocationIfAllowed()
        }
    }

    fileprivate func handleLocations(_ locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        currentLocation = ArkFileMapCoordinate(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude
        )
        guard isRecording else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= Self.maximumHorizontalAccuracyMeters,
                  activePoints.count < Self.maximumPointsPerTrack else {
                continue
            }
            let newPoint = ArkFileTrackPoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp
            )
            if let previous = activePoints.last {
                let segmentDistance = ArkFileMapMeasurement.distanceMeters(
                    fromLatitude: previous.latitude,
                    longitude: previous.longitude,
                    toLatitude: newPoint.latitude,
                    longitude: newPoint.longitude
                )
                guard segmentDistance >= Self.minimumPointSpacingMeters else {
                    continue
                }
                activeDistanceAccumulator += segmentDistance
            }
            activePoints.append(newPoint)
        }
    }

    // MARK: - Persistence

    private static func tracksFileURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = root.appendingPathComponent("ArkFile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("map-tracks.json")
    }

    private func persistTracks() {
        try? persistTracks(savedTracks)
    }

    private func persistTracks(_ tracks: [ArkFileMapTrack]) throws {
        try persistTracks(data: JSONEncoder().encode(tracks))
    }

    private func persistTracks(data: Data) throws {
        guard let persistenceURL else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: .atomic)
    }

    private static func loadPersistedTracks(from url: URL?) -> [ArkFileMapTrack] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let tracks = try? JSONDecoder().decode([ArkFileMapTrack].self, from: data) else {
            return []
        }
        return tracks
    }

    private static func defaultTrackName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Trail \(formatter.string(from: date))"
    }
}

extension ArkFileMapTrackRecorder: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.handleLocations(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are normal (tunnels, airplane mode); recording
        // simply resumes with the next good fix.
    }
}
#endif
