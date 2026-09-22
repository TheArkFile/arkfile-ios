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
import Combine
import UIKit

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

/// Kept behind a driver so permission and location failures can be verified without GPS.
@MainActor
protocol ArkFileMapLocationDriving: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var servicesEnabled: Bool { get }
    var authorizationChanged: (() -> Void)? { get set }
    var locationsChanged: (([CLLocation]) -> Void)? { get set }
    var failed: ((Error) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func start(recording: Bool)
    func stop()
}

@MainActor
private final class ArkFileMapCoreLocationDriver: NSObject, ArkFileMapLocationDriving {
    private let manager = CLLocationManager()
    var authorizationChanged: (() -> Void)?
    var locationsChanged: (([CLLocation]) -> Void)?
    var failed: ((Error) -> Void)?
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }
    var servicesEnabled: Bool { CLLocationManager.locationServicesEnabled() }

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }

    func start(recording: Bool) {
        manager.desiredAccuracy = recording ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.distanceFilter = recording ? ArkFileMapTrackRecorder.minimumPointSpacingMeters : 50
        manager.activityType = recording ? .fitness : .other
        manager.pausesLocationUpdatesAutomatically = !recording
        manager.allowsBackgroundLocationUpdates = recording
        manager.showsBackgroundLocationIndicator = recording
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.pausesLocationUpdatesAutomatically = true
    }
}

extension ArkFileMapCoreLocationDriver: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged?() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.locationsChanged?(locations) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.failed?(error) }
    }
}

enum ArkFileMapRecordingState: Equatable {
    case idle, awaitingPermission, locating, recording, blocked, interrupted, stopped

    var isActive: Bool {
        self == .awaitingPermission || self == .locating || self == .recording
    }

    var title: String {
        switch self {
        case .idle: return "Record a trail"
        case .awaitingPermission: return "Waiting for location permission"
        case .locating: return "Waiting for accurate location"
        case .recording: return "Recording trail"
        case .blocked: return "Location unavailable"
        case .interrupted: return "Trail interrupted"
        case .stopped: return "Trail stopped"
        }
    }
}

private struct ArkFileMapRecordingDraft: Codable, Sendable {
    let id: String
    let startedAt: Date
    let stoppedAt: Date?
    let points: [ArkFileTrackPoint]
}

/// One queue orders checkpoints, final saves and draft removal. A delayed checkpoint
/// cannot recreate a discarded draft or overwrite a newer stop checkpoint.
private final class ArkFileMapTrailStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.arkfile.trail-storage", qos: .utility)
    let tracksURL: URL?
    let draftURL: URL?

    init(tracksURL: URL?) {
        self.tracksURL = tracksURL
        draftURL = tracksURL?.deletingPathExtension().appendingPathExtension("draft.json")
    }

    func loadDraft() throws -> ArkFileMapRecordingDraft? {
        try queue.sync {
            guard let draftURL, FileManager.default.fileExists(atPath: draftURL.path) else { return nil }
            return try JSONDecoder().decode(ArkFileMapRecordingDraft.self, from: Data(contentsOf: draftURL))
        }
    }

    func checkpoint(_ draft: ArkFileMapRecordingDraft) throws {
        try queue.sync { try writeDraft(draft) }
    }

    func enqueueCheckpoint(_ draft: ArkFileMapRecordingDraft, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                try self.writeDraft(draft)
                completion(true)
            } catch { completion(false) }
        }
    }

    func writeTracks(_ data: Data) throws {
        try queue.sync { try Self.write(data, to: tracksURL) }
    }

    func removeDraft() throws {
        try queue.sync {
            if let draftURL, FileManager.default.fileExists(atPath: draftURL.path) {
                try FileManager.default.removeItem(at: draftURL)
            }
        }
    }

    private func writeDraft(_ draft: ArkFileMapRecordingDraft) throws {
        try Self.write(JSONEncoder().encode(draft), to: draftURL)
    }

    private static func write(_ data: Data, to url: URL?) throws {
        guard let url else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// User-started GPS trails continue in the background until explicitly stopped.
/// Recovered drafts are always stopped; launching the app never restarts recording.
@MainActor
final class ArkFileMapTrackRecorder: ObservableObject {
    static let shared = ArkFileMapTrackRecorder(persistenceURL: tracksFileURL())
    static let minimumPointSpacingMeters: CLLocationDistance = 15
    static let maximumHorizontalAccuracyMeters: CLLocationAccuracy = 60
    static let maximumLiveHorizontalAccuracyMeters: CLLocationAccuracy = 100
    static let maximumPointsPerTrack = 20_000
    nonisolated static let maximumSavedTracks = 20
    static let maximumFixAge: TimeInterval = 30

    @Published private(set) var recordingState: ArkFileMapRecordingState = .idle
    @Published private(set) var activePoints: [ArkFileTrackPoint] = []
    @Published private(set) var savedTracks: [ArkFileMapTrack] = []
    @Published private(set) var isAuthorizationDenied = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var persistenceError: String?
    private var latestLocation: CLLocation?
    private let driver: any ArkFileMapLocationDriving
    private let storage: ArkFileMapTrailStorage
    private let now: () -> Date
    private var liveUpdateRequests = 0
    private var draftID: String?
    private var hasUnreadableDraft = false
    private var checkpointGeneration = 0
    private var recordingStartedAt: Date?
    private var recordingStoppedAt: Date?
    private var activeDistanceAccumulator = 0.0
    private var checkpointTask: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?

    init(persistenceURL: URL?, locationDriver: (any ArkFileMapLocationDriving)? = nil, now: @escaping () -> Date = Date.init) {
        driver = locationDriver ?? ArkFileMapCoreLocationDriver()
        storage = ArkFileMapTrailStorage(tracksURL: persistenceURL)
        self.now = now
        savedTracks = Self.loadPersistedTracks(from: persistenceURL)
        driver.authorizationChanged = { [weak self] in self?.handleAuthorizationChange() }
        driver.locationsChanged = { [weak self] locations in self?.handleLocations(locations) }
        driver.failed = { [weak self] error in self?.handleLocationError(error) }
        restoreDraft()
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkpointNow() }
            }
    }

    var isRecording: Bool { recordingState == .recording }
    var isSessionActive: Bool { recordingState.isActive }
    var hasDraft: Bool { draftID != nil || hasUnreadableDraft }
    var showsRecordingStatus: Bool { hasDraft || statusMessage != nil || persistenceError != nil }
    var canSaveDraft: Bool { hasDraft && activePoints.count >= 2 }
    var activeDistanceMeters: Double { activeDistanceAccumulator }
    var isSavedTrackCapacityReached: Bool { savedTracks.count >= Self.maximumSavedTracks }

    /// A cached coordinate is usable only while its fix and current permission
    /// remain suitable. Stopping a trail must not make an old fix timeless.
    var currentLocation: ArkFileMapCoordinate? {
        let currentTime = now()
        guard driver.servicesEnabled,
              driver.authorizationStatus == .authorizedAlways || driver.authorizationStatus == .authorizedWhenInUse,
              driver.accuracyAuthorization == .fullAccuracy,
              let location = latestLocation,
              location.horizontalAccuracy <= Self.maximumLiveHorizontalAccuracyMeters,
              location.timestamp >= currentTime.addingTimeInterval(-Self.maximumFixAge),
              location.timestamp <= currentTime.addingTimeInterval(5) else { return nil }
        return ArkFileMapCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    var locationUnavailableMessage: String? {
        if !driver.servicesEnabled { return "Turn on Location Services in Settings to use your current position." }
        if driver.authorizationStatus == .denied || driver.authorizationStatus == .restricted {
            return "Location access is off. Allow it in Settings to use your current position."
        }
        if driver.authorizationStatus == .notDetermined {
            return "Allow location access when prompted, then try again."
        }
        if driver.accuracyAuthorization == .reducedAccuracy {
            return "Enable Precise Location in Settings to use an accurate current position."
        }
        return nil
    }

    var backToStartSummary: String? {
        guard let start = activePoints.first, let here = currentLocation else { return nil }
        let meters = ArkFileMapMeasurement.distanceMeters(
            fromLatitude: here.latitude, longitude: here.longitude,
            toLatitude: start.latitude, longitude: start.longitude
        )
        guard meters > 30 else { return nil }
        let bearing = ArkFileMapMeasurement.bearingDegrees(
            fromLatitude: here.latitude, longitude: here.longitude,
            toLatitude: start.latitude, longitude: start.longitude
        )
        let distanceText = meters < 305 ? String(format: "%.0f ft", meters * 3.28084) : String(format: "%.1f mi", meters / 1_609.344)
        return "\(distanceText) \(ArkFileMapMeasurement.compassPoint(forBearing: bearing)) back to start"
    }

    func beginLiveUpdates() {
        liveUpdateRequests += 1
        if isSessionActive { return }
        if driver.authorizationStatus == .notDetermined { driver.requestWhenInUseAuthorization() }
        startPassiveUpdatesIfAllowed()
    }

    func endLiveUpdates() {
        liveUpdateRequests = max(0, liveUpdateRequests - 1)
        if liveUpdateRequests == 0 && !isSessionActive { driver.stop() }
    }

    func startRecording() {
        guard !hasDraft else { return }
        persistenceError = nil
        statusMessage = nil
        guard driver.servicesEnabled else {
            blockWithoutDraft("Turn on Location Services in Settings to record a trail.")
            return
        }
        guard driver.authorizationStatus != .denied, driver.authorizationStatus != .restricted else {
            blockWithoutDraft("Allow location access in Settings to record a trail. Choose While Using the App and enable Precise Location.")
            return
        }
        draftID = UUID().uuidString
        recordingStartedAt = now()
        recordingStoppedAt = nil
        activePoints = []
        activeDistanceAccumulator = 0
        // Confirm that a recoverable draft can be stored before starting GPS.
        guard checkpointNow() else {
            recordingState = .stopped
            return
        }
        if driver.authorizationStatus == .notDetermined {
            recordingState = .awaitingPermission
            statusMessage = "Choose While Using the App to start this trail. You can stop it at any time."
            driver.requestWhenInUseAuthorization()
        } else {
            beginAuthorizedRecording()
        }
    }

    /// Stops trail/background recording immediately. A visible map may continue
    /// foreground updates without adding to the retained, stopped draft.
    func stopRecording() {
        guard hasDraft, isSessionActive else { return }
        driver.stop()
        recordingStoppedAt = now()
        recordingState = .stopped
        statusMessage = activePoints.count < 2
            ? "Not enough location points to save a trail. Your draft is stopped; discard it when ready."
            : "Location recording has stopped. Save or discard this trail."
        checkpointNow()
        startPassiveUpdatesIfAllowed()
    }

    /// Content mutation and authorization loss must not implicitly save or discard.
    func interruptRecording(message: String) {
        guard hasDraft, isSessionActive else { return }
        driver.stop()
        recordingStoppedAt = now()
        recordingState = .interrupted
        statusMessage = message
        checkpointNow()
    }

    @discardableResult
    func stopRecordingAndSave(name: String) -> Bool {
        stopRecording()
        guard let draftID, let startedAt = recordingStartedAt, activePoints.count > 1 else {
            statusMessage = "A trail needs at least two accurate location points. The draft has not been discarded."
            return false
        }
        guard !isSavedTrackCapacityReached else {
            statusMessage = "You can keep up to \(Self.maximumSavedTracks) trails. Delete a saved trail in Waypoints & Trails, then save this draft."
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = ArkFileMapTrack(
            id: draftID, name: trimmed.isEmpty ? Self.defaultTrackName(for: startedAt) : trimmed,
            points: activePoints, startedAt: startedAt, endedAt: recordingStoppedAt ?? now()
        )
        var updated = savedTracks
        updated.insert(track, at: 0)
        do {
            try storage.writeTracks(JSONEncoder().encode(updated))
            // Publish only after the atomic saved-track write succeeds.
            savedTracks = updated
            try? storage.removeDraft()
            clearDraft()
            return true
        } catch {
            persistenceError = "The trail could not be saved. Its stopped draft is still here. Free some device storage, then try Save Trail again."
            return false
        }
    }

    func discardRecording() {
        stopRecording()
        checkpointTask?.cancel()
        checkpointTask = nil
        do {
            try storage.removeDraft()
            clearDraft()
        } catch {
            persistenceError = "The draft could not be removed from this device. Try Discard again."
        }
    }

    func dismissStatus() {
        guard !hasDraft else { return }
        recordingState = .idle
        statusMessage = nil
        persistenceError = nil
    }

    func removeTrack(id: String) { removeSavedTracks { $0.id == id } }
    func removeTracks(atOffsets offsets: IndexSet) {
        let ids = Set(offsets.compactMap { savedTracks.indices.contains($0) ? savedTracks[$0].id : nil })
        removeSavedTracks { ids.contains($0.id) }
    }

    private func removeSavedTracks(where shouldRemove: (ArkFileMapTrack) -> Bool) {
        let updated = savedTracks.filter { !shouldRemove($0) }
        do {
            try storage.writeTracks(JSONEncoder().encode(updated))
            savedTracks = updated
            persistenceError = nil
        } catch { persistenceError = "The saved trail could not be deleted. Please try again." }
    }

    @discardableResult
    func importTracks(_ tracks: [ArkFileMapTrack]) throws -> Int { try importTracksWithSummary(tracks).accepted.count }

    @discardableResult
    func importTracksWithSummary(_ tracks: [ArkFileMapTrack]) throws -> ArkFileMapImportPlan<ArkFileMapTrack> {
        try applyPreparedImport(ArkFileMapGPX.prepareTracks(tracks, existing: savedTracks))
    }

    @discardableResult
    func applyPreparedImport(_ prepared: ArkFileMapPreparedImport<ArkFileMapTrack>) throws -> ArkFileMapImportPlan<ArkFileMapTrack> {
        guard savedTracks == prepared.existingItems else { throw ArkFileMapImportError.storeChanged }
        guard prepared.plan.hasChanges else { return prepared.plan }
        guard let data = prepared.encodedData else { throw CocoaError(.fileWriteUnknown) }
        try storage.writeTracks(data)
        savedTracks = prepared.updatedItems
        return prepared.plan
    }

    private func blockWithoutDraft(_ message: String) {
        driver.stop()
        isAuthorizationDenied = true
        recordingState = .blocked
        statusMessage = message
    }

    private func beginAuthorizedRecording() {
        guard hasDraft, driver.servicesEnabled else { return }
        switch driver.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            isAuthorizationDenied = false
            recordingState = .locating
            statusMessage = driver.accuracyAuthorization == .reducedAccuracy
                ? "Enable Precise Location in Settings for a usable trail. Recording needs accurate fixes as you move."
                : "Move outdoors for an accurate fix. This trail continues while the screen is locked until you stop it."
            driver.start(recording: true)
        default: break
        }
    }

    private func startPassiveUpdatesIfAllowed() {
        guard liveUpdateRequests > 0, !isSessionActive, driver.servicesEnabled else { return }
        switch driver.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            isAuthorizationDenied = false
            driver.start(recording: false)
        case .denied, .restricted: isAuthorizationDenied = true
        default: break
        }
    }

    private func handleAuthorizationChange() {
        isAuthorizationDenied = !driver.servicesEnabled || driver.authorizationStatus == .denied || driver.authorizationStatus == .restricted
        if isAuthorizationDenied || driver.authorizationStatus == .notDetermined || driver.accuracyAuthorization == .reducedAccuracy {
            latestLocation = nil
        }
        if isSessionActive {
            if isAuthorizationDenied || driver.authorizationStatus == .notDetermined {
                interruptRecording(message: "Location permission is unavailable. The trail is stopped and its draft is kept. Allow location in Settings before starting another trail.")
            } else if recordingState == .awaitingPermission {
                beginAuthorizedRecording()
            } else if driver.accuracyAuthorization == .reducedAccuracy {
                recordingState = .locating
                statusMessage = "Enable Precise Location in Settings to capture accurate trail points."
            }
        } else {
            if isAuthorizationDenied || driver.authorizationStatus == .notDetermined {
                driver.stop()
            } else {
                startPassiveUpdatesIfAllowed()
            }
        }
    }

    private func handleLocationError(_ error: Error) {
        latestLocation = nil
        guard isSessionActive else { return }
        if let locationError = error as? CLError, locationError.code == .locationUnknown {
            recordingState = .locating
            statusMessage = "Waiting for an accurate location fix. Keep the device outdoors; recording will continue when a usable fix returns."
        } else {
            if let locationError = error as? CLError, locationError.code == .denied { isAuthorizationDenied = true }
            interruptRecording(message: "Location updates stopped. Your trail draft is kept. Check Location Services before starting another trail.")
        }
    }

    private func handleLocations(_ locations: [CLLocation]) {
        let currentTime = now()
        let valid = locations.filter {
            CLLocationCoordinate2DIsValid($0.coordinate)
                && $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite
                && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy.isFinite
                && $0.timestamp >= currentTime.addingTimeInterval(-Self.maximumFixAge)
                && $0.timestamp <= currentTime.addingTimeInterval(5)
        }
        if let latest = valid.max(by: { $0.timestamp < $1.timestamp }),
           latest.timestamp >= (latestLocation?.timestamp ?? .distantPast) {
            latestLocation = latest
        }
        guard isSessionActive, recordingState != .awaitingPermission else { return }
        if !valid.isEmpty, valid.allSatisfy({ $0.horizontalAccuracy > Self.maximumHorizontalAccuracyMeters }) {
            recordingState = .locating
            statusMessage = "Waiting for an accurate location fix. Enable Precise Location and move outdoors if possible."
        }
        var changed = false
        for location in valid {
            guard location.horizontalAccuracy <= Self.maximumHorizontalAccuracyMeters,
                  location.timestamp >= (recordingStartedAt ?? currentTime),
                  activePoints.count < Self.maximumPointsPerTrack else { continue }
            if let timestamp = activePoints.last?.timestamp, location.timestamp <= timestamp { continue }
            // A valid fix establishes live recording even while the user stands still.
            recordingState = .recording
            statusMessage = "Continues while the screen is locked until you stop it. Points are added as you move."
            let point = ArkFileTrackPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp)
            if let previous = activePoints.last {
                let meters = ArkFileMapMeasurement.distanceMeters(
                    fromLatitude: previous.latitude, longitude: previous.longitude,
                    toLatitude: point.latitude, longitude: point.longitude
                )
                guard meters >= Self.minimumPointSpacingMeters else { continue }
                activeDistanceAccumulator += meters
            }
            activePoints.append(point)
            changed = true
        }
        if activePoints.count >= Self.maximumPointsPerTrack {
            interruptRecording(message: "This trail reached its \(Self.maximumPointsPerTrack)-point limit and has stopped. Save it before starting another trail.")
        } else if changed { scheduleCheckpoint() }
    }

    private var draft: ArkFileMapRecordingDraft? {
        guard let draftID, let recordingStartedAt else { return nil }
        return ArkFileMapRecordingDraft(id: draftID, startedAt: recordingStartedAt, stoppedAt: recordingStoppedAt, points: activePoints)
    }

    private func scheduleCheckpoint() {
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self else { return }
            self.checkpointTask = nil
            guard let snapshot = self.draft else { return }
            self.checkpointGeneration += 1
            let generation = self.checkpointGeneration
            self.storage.enqueueCheckpoint(snapshot) { [weak self] succeeded in
                Task { @MainActor [weak self] in
                    guard let self, self.draftID == snapshot.id, self.checkpointGeneration == generation, !succeeded else { return }
                    self.interruptRecording(message: "Trail recording stopped because its recovery copy could not be saved. Your points are still available here.")
                    self.persistenceError = "Free some device storage, then save this stopped trail."
                }
            }
        }
    }

    @discardableResult
    func checkpointNow() -> Bool {
        checkpointGeneration += 1
        checkpointTask?.cancel()
        checkpointTask = nil
        guard let draft else { return true }
        do {
            try storage.checkpoint(draft)
            persistenceError = nil
            return true
        } catch {
            if isSessionActive {
                driver.stop()
                recordingStoppedAt = now()
                recordingState = .interrupted
                statusMessage = "Trail recording stopped because its recovery copy could not be saved. Your points are still available here."
            }
            persistenceError = "The trail recovery copy could not be saved. Keep ArkFile open and free some storage before saving this draft."
            return false
        }
    }

    private func restoreDraft() {
        do {
            guard let restored = try storage.loadDraft() else { return }
            // A crash between committed save and draft deletion must not duplicate it.
            if savedTracks.contains(where: { $0.id == restored.id }) {
                try? storage.removeDraft()
                return
            }
            guard !restored.id.isEmpty, restored.points.count <= Self.maximumPointsPerTrack,
                  restored.points.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            draftID = restored.id
            recordingStartedAt = restored.startedAt
            recordingStoppedAt = restored.stoppedAt ?? restored.points.last?.timestamp ?? restored.startedAt
            activePoints = restored.points
            activeDistanceAccumulator = ArkFileMapTrack(id: restored.id, name: "", points: restored.points, startedAt: restored.startedAt, endedAt: recordingStoppedAt).totalDistanceMeters
            recordingState = .interrupted
            statusMessage = "Recovered an interrupted trail. Location recording is stopped. Save or discard this draft before starting another trail."
        } catch {
            hasUnreadableDraft = true
            recordingState = .interrupted
            persistenceError = "A previous trail draft could not be read. Its file has been kept on this device. Discard it explicitly before recording another trail."
        }
    }

    private func clearDraft() {
        checkpointTask?.cancel()
        checkpointTask = nil
        draftID = nil
        hasUnreadableDraft = false
        checkpointGeneration += 1
        recordingStartedAt = nil
        recordingStoppedAt = nil
        activePoints = []
        activeDistanceAccumulator = 0
        recordingState = .idle
        statusMessage = nil
        persistenceError = nil
        driver.stop()
        startPassiveUpdatesIfAllowed()
    }

    private static func tracksFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArkFile", isDirectory: true).appendingPathComponent("map-tracks.json")
    }

    private static func loadPersistedTracks(from url: URL?) -> [ArkFileMapTrack] {
        guard let url, let data = try? Data(contentsOf: url),
              let tracks = try? JSONDecoder().decode([ArkFileMapTrack].self, from: data) else { return [] }
        return tracks
    }

    private static func defaultTrackName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Trail \(formatter.string(from: date))"
    }
}
#endif
