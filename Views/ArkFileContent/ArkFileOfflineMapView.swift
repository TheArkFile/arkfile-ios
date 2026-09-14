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
@preconcurrency import MapLibre
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ArkFileCriticalPlaceSelection {
    static func load(from defaults: UserDefaults, key: String) -> Set<ArkFileCriticalPlaceKind>? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Set((defaults.stringArray(forKey: key) ?? []).compactMap(ArkFileCriticalPlaceKind.init(rawValue:)))
    }

    static func effectiveKinds(_ saved: Set<ArkFileCriticalPlaceKind>?) -> Set<ArkFileCriticalPlaceKind> {
        saved ?? ArkFileCriticalPlaceSearchGroup.allKinds
    }
}

enum ArkFileMapTopOverlayContext: Equatable {
    case none
    case error
    case notice
    case measure
    case recording
    case criticalPlacesHint
    case criticalPlacesChips
}

enum ArkFileMapOverlayBudget {
    static func showsRegionalOffer(
        hasRegionHint: Bool,
        topContext: ArkFileMapTopOverlayContext,
        isCriticalPlacesStoreAvailable: Bool
    ) -> Bool {
        hasRegionHint && !(topContext == .criticalPlacesHint && !isCriticalPlacesStoreAvailable)
    }

    static func topContext(
        hasError: Bool,
        hasNotice: Bool,
        isMeasuring: Bool,
        isRecording: Bool,
        hasCriticalPlacesHint: Bool,
        isCriticalPlacesStoreAvailable: Bool
    ) -> ArkFileMapTopOverlayContext {
        if hasError { return .error }
        if hasNotice { return .notice }
        if isMeasuring { return .measure }
        if isRecording { return .recording }
        if hasCriticalPlacesHint { return .criticalPlacesHint }
        if isCriticalPlacesStoreAvailable { return .criticalPlacesChips }
        return .none
    }
}

enum ArkFileMapLocationAccessAction: Hashable {
    case acquireLiveUpdates
    case releaseLiveUpdates
    case stopAndSaveRecording
}

enum ArkFileMapLocationAccessPolicy {
    static func actions(
        isAccessBlocked: Bool,
        isMapVisible: Bool,
        ownsLiveUpdateRequest: Bool,
        isRecording: Bool
    ) -> Set<ArkFileMapLocationAccessAction> {
        var actions: Set<ArkFileMapLocationAccessAction> = []
        if isAccessBlocked {
            if isRecording {
                actions.insert(.stopAndSaveRecording)
            }
            if ownsLiveUpdateRequest {
                actions.insert(.releaseLiveUpdates)
            }
        } else if isMapVisible, !ownsLiveUpdateRequest {
            actions.insert(.acquireLiveUpdates)
        } else if !isMapVisible, ownsLiveUpdateRequest {
            actions.insert(.releaseLiveUpdates)
        }
        return actions
    }
}

/// Owns the Critical Places store and the viewport-driven place list so that
/// camera movement never does synchronous database work and never re-renders
/// the map body unless the visible place set actually changed.
@MainActor
final class ArkFileMapPlacesController: ObservableObject {
    static let viewportQueryLimit = 900
    static let visiblePlacesCap = 300
    static let refreshDebounceSeconds: TimeInterval = 0.25

    @Published private(set) var visiblePlaces: [ArkFileCriticalPlace] = []
    @Published private(set) var isStoreAvailable = false

    private(set) var store: ArkFileCriticalPlacesStore?
    private(set) var lastCenter: ArkFileMapCoordinate?
    private(set) var lastZoom = 0.0
    private var lastBounds: ArkFileCriticalPlacesBoundingBox?
    private var configuredURL: URL?
    private var hasConfigured = false
    private var activePlan: ArkFileMapViewportQueryPlan?
    private var pendingRefresh: DispatchWorkItem?
    private var refreshGeneration = 0

    /// Creates (or recreates) the store. Reopening only happens when the
    /// database location actually changed — e.g. after a content install.
    func configure(databaseURL: URL?) {
        guard !hasConfigured || configuredURL?.fileSystemPath != databaseURL?.fileSystemPath else {
            return
        }
        hasConfigured = true
        configuredURL = databaseURL
        pendingRefresh?.cancel()
        refreshGeneration += 1
        activePlan = nil
        if databaseURL == nil {
            clearVisiblePlaces()
        }
        let store = ArkFileCriticalPlacesStore(databaseURL: databaseURL)
        self.store = store
        if isStoreAvailable != store.isAvailable {
            isStoreAvailable = store.isAvailable
        }
    }

    func cameraDidChange(
        center: ArkFileMapCoordinate,
        zoom: Double,
        bounds: ArkFileCriticalPlacesBoundingBox?,
        kinds: Set<ArkFileCriticalPlaceKind>
    ) {
        lastCenter = center
        lastZoom = zoom
        lastBounds = bounds
        guard isStoreAvailable, !kinds.isEmpty,
              zoom >= ArkFileCriticalPlacesStore.minimumViewportZoom,
              let bounds, bounds.isValid else {
            clearVisiblePlaces()
            return
        }
        if let activePlan, activePlan.covers(visibleBounds: bounds, kinds: kinds) {
            return
        }
        scheduleRefresh(bounds: bounds, center: center, kinds: kinds)
    }

    func kindsDidChange(_ kinds: Set<ArkFileCriticalPlaceKind>) {
        pendingRefresh?.cancel()
        activePlan = nil
        guard isStoreAvailable, !kinds.isEmpty,
              lastZoom >= ArkFileCriticalPlacesStore.minimumViewportZoom,
              let bounds = lastBounds, bounds.isValid,
              let center = lastCenter else {
            clearVisiblePlaces()
            return
        }
        performRefresh(bounds: bounds, center: center, kinds: kinds)
    }

    /// Keeps a Find Nearest selection on the map even when it sits outside
    /// the current viewport query.
    func ensureVisible(_ place: ArkFileCriticalPlace) {
        guard !visiblePlaces.contains(where: { $0.id == place.id }) else { return }
        visiblePlaces.append(place)
    }

    private func clearVisiblePlaces() {
        pendingRefresh?.cancel()
        activePlan = nil
        if !visiblePlaces.isEmpty {
            visiblePlaces = []
        }
    }

    private func scheduleRefresh(
        bounds: ArkFileCriticalPlacesBoundingBox,
        center: ArkFileMapCoordinate,
        kinds: Set<ArkFileCriticalPlaceKind>
    ) {
        pendingRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.performRefresh(bounds: bounds, center: center, kinds: kinds)
            }
        }
        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.refreshDebounceSeconds,
            execute: workItem
        )
    }

    private func performRefresh(
        bounds: ArkFileCriticalPlacesBoundingBox,
        center: ArkFileMapCoordinate,
        kinds: Set<ArkFileCriticalPlaceKind>
    ) {
        guard let store, store.isAvailable else {
            clearVisiblePlaces()
            return
        }
        let plan = ArkFileMapViewportQueryPlan.make(visibleBounds: bounds, kinds: kinds)
        refreshGeneration += 1
        let generation = refreshGeneration
        store.placesAsync(
            in: plan.queriedBounds,
            kinds: kinds,
            limit: Self.viewportQueryLimit
        ) { [weak self] places in
            guard let self, self.refreshGeneration == generation else { return }
            self.activePlan = plan
            let capped = Self.nearestSubset(of: places, center: center, cap: Self.visiblePlacesCap)
            if self.visiblePlaces != capped {
                self.visiblePlaces = capped
            }
        }
    }

    /// Caps the annotation count, preferring places closest to the camera.
    /// Distances are computed once per place instead of inside the sort
    /// comparator.
    static func nearestSubset(
        of places: [ArkFileCriticalPlace],
        center: ArkFileMapCoordinate,
        cap: Int
    ) -> [ArkFileCriticalPlace] {
        guard places.count > cap else { return places }
        return places
            .map { place in
                (place: place, distance: ArkFileMapMeasurement.distanceMeters(
                    fromLatitude: center.latitude,
                    longitude: center.longitude,
                    toLatitude: place.latitude,
                    longitude: place.longitude
                ))
            }
            .sorted { lhs, rhs in
                if lhs.distance == rhs.distance {
                    return lhs.place.displayName < rhs.place.displayName
                }
                return lhs.distance < rhs.distance
            }
            .prefix(cap)
            .map(\.place)
    }
}

struct ArkFileOfflineMapView: View {
    // Geographic center of the contiguous United States, framed for a phone.
    private static let defaultCenter = CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35)
    private static let defaultZoom = 2.9

    private static let savedCenterLatKey = "arkfile.map.camera.lat.v1"
    private static let savedCenterLonKey = "arkfile.map.camera.lon.v1"
    private static let savedZoomKey = "arkfile.map.camera.zoom.v1"
    private static let dismissedRegionHintsKey = "arkfile.map.dismissed-region-hints.v1"
    private static let dismissedCriticalPlacesUnavailableHintKey = "arkfile.map.dismissed-critical-places-benefits.v1"
    private static let selectedCriticalPlaceKindsKey = "arkfile.map.critical-place-kinds.v1"
    private static let gpxContentType = UTType("com.topografix.gpx") ?? UTType(filenameExtension: "gpx") ?? .xml

    /// First open lands on the USA; afterwards the map reopens wherever the
    /// user last left it.
    private static func initialCamera() -> (center: CLLocationCoordinate2D, zoom: Double) {
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: savedCenterLatKey)
        let lon = defaults.double(forKey: savedCenterLonKey)
        let zoom = defaults.double(forKey: savedZoomKey)
        guard zoom > 0, abs(lat) <= 85, abs(lon) <= 180, (lat != 0 || lon != 0) else {
            return (defaultCenter, defaultZoom)
        }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), zoom)
    }

    static func saveCamera(center: CLLocationCoordinate2D, zoom: Double) {
        let defaults = UserDefaults.standard
        defaults.set(center.latitude, forKey: savedCenterLatKey)
        defaults.set(center.longitude, forKey: savedCenterLonKey)
        defaults.set(zoom, forKey: savedZoomKey)
    }

    let contentRoot: URL?
    private let automaticallyTracksLocation: Bool
    /// When present, the map becomes a one-purpose, offline coordinate picker.
    /// It never starts map-owned live location updates or exposes trail tools.
    let onSelectCoordinate: ((ArkFileMapCoordinate) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var managedContentReadToken: ArkFileManagedContentReaderToken?
    @State private var resources: ArkFileOfflineMapResources
    @State private var regionIndex: ArkFileMapRegionIndex?
    // Camera-derived UI state. The raw camera lives on placesController and
    // deliberately does NOT drive SwiftUI: re-rendering this whole body on
    // every pan was a major source of map lag. Only these two distilled
    // values (which rarely change) invalidate the view.
    @State private var regionHint: ArkFileMapRegionHint?
    @State private var mapCoverageStatus = "World overview"
    @State private var mapZoomOutTarget: Double?
    @State private var isBelowPlacesZoom: Bool
    @StateObject private var placesController = ArkFileMapPlacesController()
    @State private var dismissedRegionHintIDs: Set<String>
    @State private var dismissedCriticalPlacesUnavailableHint: Bool
    @State private var selectedCriticalPlaceKinds: Set<ArkFileCriticalPlaceKind>?
    @State private var highlightedCriticalPlace: ArkFileCriticalPlace?
    @State private var nearestPlaceSections: [ArkFileNearestPlacesSection] = []
    @State private var nearestOriginText: String?
    @State private var isShowingNearestPlaces = false
    @State private var isLoadingNearestPlaces = false
    @State private var isShowingMapPacks = false
    @State private var mapPackCenter: ArkFileMapCoordinate?
    @State private var selectedMapRegion: ArkFileMapRegionIndex.Region?
    @State private var previewMapRegion: ArkFileMapRegionIndex.Region?
    @StateObject private var waypointStore = ArkFileMapWaypointStore.shared
    @State private var isAccessBlocked: Bool
    @State private var mapNotice: String?
    @State private var mapError: String?
    @State private var waypointEditor: ArkFileWaypointEditorState?
    @State private var isShowingWaypointList = false
    @State private var focusRequest: ArkFileMapFocusRequest?
    @State private var isMeasuring = false
    @State private var measurePoints: [ArkFileMapCoordinate] = []
    @StateObject private var trackRecorder = ArkFileMapTrackRecorder.shared
    @State private var isNamingTrack = false
    @State private var pendingTrackName = ""
    @State private var selectedTrackIDs: Set<String> = []
    @State private var isAddingCoordinateWaypoint = false
    @State private var pasteCandidates: [ArkFileParsedCoordinate] = []
    @State private var pasteError: String?
    @State private var inboundLocationPrompt: ArkFileInboundLocationPrompt?
    @State private var sharePayload: ArkFileMapSharePayload?
    @State private var isImportingGPX = false
    @State private var gpxReview: ArkFileGPXReviewRequest?
    @State private var pendingGPXReview: ArkFileGPXReviewRequest?
    @State private var importsGPXAfterListDismissal = false
    @State private var gpxImportTask: Task<Void, Never>?
    @State private var isWaitingForContentMutation: Bool
    @State private var isMapVisible = false
    @State private var ownsLiveUpdateRequest = false
    @State private var selectedCoordinateCandidate: ArkFileMapCoordinate?
    @State private var coordinateSelectionCenter: ArkFileMapCoordinate?

    init(
        contentRoot: URL?,
        initialSelectedCoordinate: ArkFileMapCoordinate? = nil,
        initialMapRegionID: String? = nil,
        showsMapDownloadsInitially: Bool = false,
        onSelectCoordinate: ((ArkFileMapCoordinate) -> Void)? = nil
    ) {
        self.contentRoot = contentRoot
        self.automaticallyTracksLocation = !showsMapDownloadsInitially && initialMapRegionID == nil
        self.onSelectCoordinate = onSelectCoordinate
        let initialCamera = Self.initialCamera()
        let readToken = ArkFileManagedContentConcurrencyGate.tryBeginMapRead()
        let canOpenContent = readToken != nil && Self.canOpenMapContentRoot(contentRoot)
        let initialResources = canOpenContent
            ? ArkFileOfflineMapResources.locate(contentRoot: contentRoot)
            : Self.emptyMapResources()
        let initiallyShowsMapDownloads = showsMapDownloadsInitially && onSelectCoordinate == nil
        let retainedReadToken: ArkFileManagedContentReaderToken?
        if initialResources.hasVectorMap && !initiallyShowsMapDownloads {
            retainedReadToken = readToken
        } else {
            // Download discovery has no renderer to own a long-lived lease.
            readToken?.release()
            retainedReadToken = nil
        }
        _managedContentReadToken = State(initialValue: retainedReadToken)
        _resources = State(initialValue: initialResources)
        let initialIndex = ArkFileMapRegionIndex.loadBundled()
        let initialRegion = initialIndex?.regions.first { $0.id == initialMapRegionID }
        _regionIndex = State(initialValue: initialIndex)
        _selectedMapRegion = State(initialValue: initialRegion)
        _isShowingMapPacks = State(initialValue: initiallyShowsMapDownloads)
        _isBelowPlacesZoom = State(
            initialValue: initialCamera.zoom < ArkFileCriticalPlacesStore.minimumViewportZoom
        )
        _dismissedRegionHintIDs = State(initialValue: Self.loadDismissedRegionHintIDs())
        _dismissedCriticalPlacesUnavailableHint = State(
            initialValue: UserDefaults.standard.bool(forKey: Self.dismissedCriticalPlacesUnavailableHintKey)
        )
        _selectedCriticalPlaceKinds = State(initialValue: Self.loadSelectedCriticalPlaceKinds())
        _isAccessBlocked = State(initialValue: !canOpenContent)
        _isWaitingForContentMutation = State(initialValue: readToken == nil)
        _selectedCoordinateCandidate = State(initialValue: initialSelectedCoordinate)
        _coordinateSelectionCenter = State(
            initialValue: initialSelectedCoordinate
                ?? ArkFileMapCoordinate(
                    latitude: initialCamera.center.latitude,
                    longitude: initialCamera.center.longitude
                )
        )
        if let initialSelectedCoordinate {
            _focusRequest = State(
                initialValue: ArkFileMapFocusRequest(
                    nonce: UUID(),
                    coordinate: initialSelectedCoordinate
                )
            )
        } else if let initialRegion, let center = initialRegion.center {
            _focusRequest = State(initialValue: ArkFileMapFocusRequest(
                nonce: UUID(), coordinate: center, bounds: initialRegion.bounds
            ))
        }
    }

    init(tilesRoot: URL) {
        self.init(contentRoot: Self.contentRoot(fromLegacyMapURL: tilesRoot))
    }

    private var mapStatusOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Label(mapCoverageStatus, systemImage: "map")
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("arkfile_map_coverage_status")
                if let mapZoomOutTarget {
                    Button {
                        guard let center = placesController.lastCenter else { return }
                        focusRequest = ArkFileMapFocusRequest(
                            nonce: UUID(), coordinate: center, zoom: mapZoomOutTarget
                        )
                    } label: {
                        Label("Zoom out for a clearer map", systemImage: "minus.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 11)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .accessibilityIdentifier("arkfile_map_zoom_to_detail")
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            topContextualPill
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var mapActionBar: some View {
        HStack(spacing: 12) {
            Button {
                showMapDownloads()
            } label: {
                Label("Download Maps", systemImage: "arrow.down.circle")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(Color.arkTeal, in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("arkfile_download_maps")

            Spacer(minLength: 0)

            Button {
                locateMe()
            } label: {
                Image(systemName: "location")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.arkInteractiveForeground)
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.arkBorder.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .disabled(isAccessBlocked || !resources.hasVectorMap)
            .accessibilityLabel("Go to my location")
            .accessibilityIdentifier("arkfile_map_location")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var mapCanvas: some View {
        ZStack(alignment: .top) {
            if isShowingMapPacks {
                // The download sheet owns this surface while browsing. Removing
                // MapLibre lets its coordinator end the map-reader lifetime,
                // so an explicitly requested map can activate behind the sheet.
                Color.arkMapBackground
                    .ignoresSafeArea(edges: .bottom)
            } else if isAccessBlocked {
                accessBlockedState
            } else if resources.hasVectorMap,
                      let managedContentReadToken,
                      !managedContentReadToken.isReleased {
                ArkFileMapLibreView(
                    resources: resources,
                    managedContentReadToken: managedContentReadToken,
                    center: Self.initialCamera().center,
                    zoom: Self.initialCamera().zoom,
                    persistsCamera: !isCoordinateSelectionMode,
                    waypoints: displayedWaypoints,
                    focusRequest: focusRequest,
                    coverageRegion: previewMapRegion,
                    isMeasuring: isMeasuring,
                    measurePoints: measurePoints,
                    showsUserLocation: isMapVisible && !isCoordinateSelectionMode
                        && !trackRecorder.isAuthorizationDenied,
                    activeTrackPoints: !isCoordinateSelectionMode && trackRecorder.isRecording
                        ? trackRecorder.activePoints
                        : [],
                    selectedTracks: isCoordinateSelectionMode ? [] : selectedTracks,
                    criticalPlaces: mapCriticalPlaces,
                    highlightedCriticalPlaceID: highlightedCriticalPlace?.id,
                    mapError: $mapError,
                    onLongPress: { coordinate in
                        guard !isMeasuring else { return }
                        if isCoordinateSelectionMode {
                            selectedCoordinateCandidate = coordinate
                            focusRequest = ArkFileMapFocusRequest(
                                nonce: UUID(),
                                coordinate: coordinate
                            )
                        } else {
                            waypointEditor = .create(coordinate: coordinate)
                        }
                    },
                    onMeasureTap: { coordinate in
                        if measurePoints.count >= 2 {
                            measurePoints = [coordinate]
                        } else {
                            measurePoints.append(coordinate)
                        }
                    },
                    onCameraChanged: { camera in
                        handleCameraChange(camera)
                    },
                    onShareWaypoint: { waypointID in
                        if let waypoint = waypointStore.waypoints.first(where: { $0.id == waypointID }) {
                            sharePayload = .message(shareMessage(for: waypoint))
                        }
                    },
                    onSaveCriticalPlace: { placeID in
                        if let place = mapCriticalPlaces.first(where: { $0.id == placeID }) {
                            waypointEditor = .create(
                                coordinate: place.coordinate,
                                suggestedName: place.displayName,
                                kind: place.kind.waypointKind
                            )
                        }
                    },
                    onShareCriticalPlace: { placeID in
                        if let place = mapCriticalPlaces.first(where: { $0.id == placeID }) {
                            sharePayload = .message(shareMessage(for: place))
                        }
                    }
                )
                .ignoresSafeArea(edges: isCoordinateSelectionMode ? .bottom : [])
            } else {
                unavailableState
            }

            if !isShowingMapPacks, !isAccessBlocked, !isCoordinateSelectionMode {
                mapStatusOverlay
            } else if !isShowingMapPacks, isAccessBlocked, !isCoordinateSelectionMode,
                      trackRecorder.isRecording {
                recordingPill
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            if !isShowingMapPacks, !isAccessBlocked, !isCoordinateSelectionMode,
               previewMapRegion != nil || showsRegionalOffer {
                VStack {
                    Spacer(minLength: 0)
                    Group {
                        if let previewMapRegion {
                            regionPreviewPill(previewMapRegion)
                        } else if let hint = regionHint, showsRegionalOffer {
                            regionHintPill(hint)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 80)
                }
            }

            if !isShowingMapPacks, !isAccessBlocked, isCoordinateSelectionMode {
                coordinateSelectionOverlay
            }
        }
    }

    var body: some View {
        mapCanvas
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arkfile_map_root")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isCoordinateSelectionMode {
                mapActionBar
            }
        }
        .tint(Color.arkInteractiveForeground)
        .background(Color.arkMapBackground)
        .task {
            refreshAccessAndResources()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .arkFileManagedContentMutationDidEnd)
        ) { _ in
            refreshAccessAndResources()
        }
        .onChange(of: selectedCriticalPlaceKinds) { _, _ in
            persistSelectedCriticalPlaceKinds()
            placesController.kindsDidChange(effectiveCriticalPlaceKinds)
        }
        .onChange(of: resources.signature) { _, _ in
            placesController.configure(
                databaseURL: isShowingMapPacks || isAccessBlocked ? nil : resources.criticalPlacesURL
            )
            placesController.kindsDidChange(effectiveCriticalPlaceKinds)
        }
        .onChange(of: isShowingMapPacks) { _, _ in
            refreshAccessAndResources()
        }
        .onChange(of: isImportingGPX) { _, presented in
            if !presented { presentPendingGPXAction() }
        }
        .onChange(of: isNamingTrack) { _, presented in
            if !presented { presentPendingGPXAction() }
        }
        .toolbar {
            // The everyday actions have their own bottom row, leaving room
            // for the title and dismissal even on a narrow iPhone.
            ToolbarItemGroup(placement: .primaryAction) {
                if !isCoordinateSelectionMode {
                    Menu {
                        Button {
                            isShowingWaypointList = true
                        } label: {
                            Label("Waypoints", systemImage: "mappin.and.ellipse")
                        }
                        Button {
                            showNearestPlaces()
                        } label: {
                            Label("Find Places in This Area", systemImage: "cross.circle")
                        }
                        .disabled(isAccessBlocked || !resources.hasVectorMap)
                        Button {
                            shareMyLocation()
                        } label: {
                            Label("Share My Location", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isAccessBlocked || !resources.hasVectorMap)
                        Section {
                            Button { exportGPX() } label: {
                                Label(LocalString.arkfile_content_offline_map_gpx_export, systemImage: "square.and.arrow.up")
                            }
                            .disabled(waypointStore.waypoints.isEmpty && trackRecorder.savedTracks.isEmpty)
                            .accessibilityIdentifier("arkfile_gpx_export")
                            Button { beginGPXImport() } label: {
                                Label(LocalString.arkfile_content_offline_map_gpx_import, systemImage: "square.and.arrow.down")
                            }
                            .accessibilityIdentifier("arkfile_gpx_import")
                        }
                        Button {
                            isMeasuring.toggle()
                            if !isMeasuring {
                                measurePoints = []
                            }
                        } label: {
                            Label(
                                isMeasuring ? "Stop Measuring" : "Measure Distance",
                                systemImage: isMeasuring ? "ruler.fill" : "ruler"
                            )
                        }
                        .disabled(isAccessBlocked || !resources.hasVectorMap)
                        Button {
                            if trackRecorder.isRecording {
                                pendingTrackName = ""
                                isNamingTrack = true
                            } else {
                                trackRecorder.startRecording()
                            }
                        } label: {
                            Label(
                                trackRecorder.isRecording ? "Stop Trail" : "Record Trail",
                                systemImage: trackRecorder.isRecording ? "stop.circle.fill" : "record.circle"
                            )
                        }
                        .disabled((isAccessBlocked || !resources.hasVectorMap) && !trackRecorder.isRecording)
                    } label: {
                        Label("More Map Tools", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("More map tools")
                    .accessibilityIdentifier("arkfile_map_more_tools")
                }
            }
        }
        .onAppear {
            refreshAccessAndResources()
            // Coordinate selection is deliberately map-only. It must not
            // borrow the trail recorder's continuous location pipeline.
            isMapVisible = !isCoordinateSelectionMode && automaticallyTracksLocation
            reconcileLocationAccess()
            if !isCoordinateSelectionMode {
                consumePendingMapLocationIfNeeded()
                consumePendingGPXImportIfNeeded()
            }
        }
        .onDisappear {
            isMapVisible = false
            reconcileLocationAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileOpenMapLocation)) { notification in
            if let link = ArkFileMapLocationRouter.link(from: notification) {
                _ = ArkFileMapLocationRouter.takePendingLink()
                presentInboundMapLocation(link)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arkFileImportMapGPX)) { notification in
            if let url = ArkFileMapGPXRouter.url(from: notification) {
                _ = ArkFileMapGPXRouter.takePendingImportURL()
                importGPX(from: url)
            }
        }
        .alert("Save Trail", isPresented: $isNamingTrack) {
            TextField("Name (e.g. Route to camp)", text: $pendingTrackName)
            Button("Save Trail") {
                trackRecorder.stopRecordingAndSave(name: pendingTrackName)
            }
            Button("Discard", role: .destructive) {
                trackRecorder.discardRecording()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("Saved trails stay on this device and can be viewed on the map anytime.")
        }
        .sheet(isPresented: $isAddingCoordinateWaypoint, onDismiss: presentPendingGPXAction) {
            ArkFileCoordinateWaypointSheet { name, coordinate, kind in
                saveNewWaypoint(name: name, coordinate: coordinate, kind: kind)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $waypointEditor, onDismiss: presentPendingGPXAction) { editor in
            ArkFileWaypointEditorSheet(editor: editor) { name, kind in
                saveWaypoint(editor: editor, name: name, kind: kind)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $inboundLocationPrompt, onDismiss: presentPendingGPXAction) { prompt in
            ArkFileInboundLocationSheet(link: prompt.link) {
                saveMapLocationLink(prompt.link)
                inboundLocationPrompt = nil
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $gpxReview, onDismiss: presentPendingGPXAction) { request in
            ArkFileGPXReviewSheet(request: request) { result in
                showGPXItemsOnMap(result)
            }
            .presentationDetents([.large])
        }
        .sheet(item: $sharePayload, onDismiss: presentPendingGPXAction) { payload in
            ArkFileActivityView(activityItems: payload.activityItems)
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isImportingGPX,
            allowedContentTypes: [Self.gpxContentType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importGPX(from: url)
                }
            case .failure(let error):
                mapError = error.localizedDescription
                mapNotice = nil
            }
        }
        .sheet(isPresented: $isShowingNearestPlaces, onDismiss: presentPendingGPXAction) {
            ArkFileNearestPlacesSheet(
                originText: nearestOriginText ?? "Near the area shown on your map",
                sections: nearestPlaceSections,
                isLoading: isLoadingNearestPlaces
            ) { place in
                highlightedCriticalPlace = place
                focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: place.coordinate)
                isShowingNearestPlaces = false
                placesController.ensureVisible(place)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingMapPacks, onDismiss: presentPendingGPXAction) {
            NavigationStack {
                if let regionIndex {
                    ArkFileMapPacksSheet(
                        index: regionIndex,
                        center: mapPackCenter ?? ArkFileMapCoordinate(
                            latitude: Self.defaultCenter.latitude,
                            longitude: Self.defaultCenter.longitude
                        ),
                        installedRegionIDs: Set(resources.regions.compactMap(\.id)),
                        currentCoverageDescription: resources.coverageSummary,
                        hasMapDetail: resources.hasDetailMap,
                        hasCriticalPlaces: resources.criticalPlacesURL != nil,
                        initialRegion: selectedMapRegion,
                        onView: { region in
                            isShowingMapPacks = false
                            if let region {
                                previewMapRegion = nil
                                focusMap(on: region)
                            }
                        },
                        onPreview: { region in
                            isShowingMapPacks = false
                            previewMapRegion = region
                            focusMap(on: region)
                        },
                        onCompare: { region in
                            isShowingMapPacks = false
                            DispatchQueue.main.async {
                                openPackComparison(relativePath: region?.relativePath)
                            }
                        },
                        onManage: { region in
                            isShowingMapPacks = false
                            DispatchQueue.main.async {
                                openDownloads(relativePath: region.relativePath)
                            }
                        }
                    )
                    .navigationTitle("Download Maps")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                isShowingMapPacks = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Maps Unavailable",
                        systemImage: "map",
                        description: Text("The map catalog could not be opened. Close this screen and try again.")
                    )
                }
            }
            .tint(Color.arkInteractiveForeground)
            .modifier(ArkFileMapDownloadPresentation())
        }
        .sheet(
            isPresented: Binding(
                get: { !pasteCandidates.isEmpty },
                set: { if !$0 { pasteCandidates = [] } }
            ),
            onDismiss: presentPendingGPXAction
        ) {
            ArkFilePasteCoordinateCandidatesSheet(candidates: pasteCandidates) { candidate in
                pasteCandidates = []
                waypointEditor = .create(
                    coordinate: candidate.coordinate,
                    suggestedName: candidate.name,
                    kind: nil
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingWaypointList, onDismiss: presentPendingGPXAction) {
            NavigationStack {
                waypointList
                    .navigationTitle("Waypoints & Trails")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                isShowingWaypointList = false
                            }
                            .fontWeight(.semibold)
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .tint(Color.arkInteractiveForeground)
    }

    private var isCoordinateSelectionMode: Bool {
        onSelectCoordinate != nil
    }

    private var displayedWaypoints: [ArkFileMapWaypoint] {
        guard isCoordinateSelectionMode else {
            return waypointStore.waypoints
        }
        guard let candidate = selectedCoordinateCandidate else {
            return []
        }
        return [
            ArkFileMapWaypoint(
                id: "arkfile-weather-selection-candidate",
                name: "Weather location",
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                createdAt: .distantPast,
                kind: .other
            )
        ]
    }

    private var coordinateSelectionOverlay: some View {
        VStack(spacing: 12) {
            Text(
                "Touch and hold the map, or move it and choose Select Map "
                    + "Center, to set the point ArkFile will use for Weather."
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.arkTextPrimary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.arkTeal.opacity(0.55), lineWidth: 1)
                }
                .padding(.top, 54)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 9) {
                Button {
                    if let center = coordinateSelectionCenter {
                        selectedCoordinateCandidate = center
                        focusRequest = ArkFileMapFocusRequest(
                            nonce: UUID(),
                            coordinate: center
                        )
                    }
                } label: {
                    Label("Select Map Center", systemImage: "scope")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.arkTeal)
                .disabled(coordinateSelectionCenter == nil)
                .accessibilityHint(
                    "Uses the current map center without requiring a touch-and-hold gesture."
                )
                .accessibilityIdentifier(
                    "arkfile_weather_map_select_center"
                )

                if let candidate = selectedCoordinateCandidate {
                    Text("Selected point")
                        .font(.caption.weight(.semibold))
                    Text(
                        String(
                            format: "%.4f, %.4f",
                            candidate.latitude,
                            candidate.longitude
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel(
                        "Latitude \(candidate.latitude.formatted()), longitude \(candidate.longitude.formatted())"
                    )
                } else {
                    Text("No point selected yet")
                        .font(.caption.weight(.semibold))
                }

                Button {
                    if let candidate = selectedCoordinateCandidate {
                        onSelectCoordinate?(candidate)
                    }
                } label: {
                    Label("Use This Location", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.arkTeal)
                .disabled(selectedCoordinateCandidate == nil)
                .accessibilityIdentifier("arkfile_weather_map_use_location")
            }
            .foregroundStyle(Color.arkTextPrimary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkTeal.opacity(0.55), lineWidth: 1)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
    }

    private var waypointList: some View {
        List {
            Section {
                if waypointStore.waypoints.isEmpty {
                    Text("Touch and hold anywhere on the map to save a meeting point, water source, or shelter location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(waypointStore.waypoints) { waypoint in
                    HStack(spacing: 10) {
                        Button {
                            isShowingWaypointList = false
                            DispatchQueue.main.async {
                                waypointEditor = .edit(waypoint)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: waypoint.kind?.systemImage ?? "mappin.circle.fill")
                                    .foregroundStyle(waypoint.kind?.swiftUIColor ?? Color.arkTeal)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(waypoint.name)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.arkTextPrimary)
                                    HStack(spacing: 6) {
                                        if let kind = waypoint.kind {
                                            Text(kind.displayName)
                                        }
                                        Text(waypoint.coordinateText)
                                            .monospacedDigit()
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 8)

                        if let createdAt = waypoint.createdAt {
                            Text(createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: waypoint.coordinate)
                            isShowingWaypointList = false
                        } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Focus \(waypoint.name)")

                        ShareLink(item: shareMessage(for: waypoint)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Share \(waypoint.name)")
                    }
                    .contextMenu {
                        Button {
                            isShowingWaypointList = false
                            DispatchQueue.main.async {
                                waypointEditor = .edit(waypoint)
                            }
                        } label: {
                            Label("Edit Waypoint", systemImage: "pencil")
                        }
                        ShareLink(item: shareMessage(for: waypoint)) {
                            Label("Share Waypoint", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            waypointStore.remove(id: waypoint.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    waypointStore.remove(atOffsets: offsets)
                }
                Button {
                    isShowingWaypointList = false
                    DispatchQueue.main.async {
                        isAddingCoordinateWaypoint = true
                    }
                } label: {
                    Label("Add by Coordinates", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                Button {
                    pasteCoordinatesFromMessage()
                } label: {
                    Label("Paste from a Message", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                Button {
                    exportGPX()
                } label: {
                    Label(LocalString.arkfile_content_offline_map_gpx_export, systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                }
                .disabled(waypointStore.waypoints.isEmpty && trackRecorder.savedTracks.isEmpty)
                Button {
                    beginGPXImport()
                } label: {
                    Label(LocalString.arkfile_content_offline_map_gpx_import, systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                if let pasteError {
                    Text(pasteError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Waypoints")
            }

            Section {
                if trackRecorder.savedTracks.isEmpty {
                    Text("Record a trail from the map toolbar to retrace your route later — it works with no cell service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(trackRecorder.savedTracks) { track in
                    Button {
                        selectedTrackIDs = [track.id]
                        focusGPXItems(waypoints: [], tracks: [track])
                        isShowingWaypointList = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .foregroundStyle(selectedTrackIDs.contains(track.id) ? Color.arkGold : Color.arkReef)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.arkTextPrimary)
                                Text("\(track.kind.displayName) · " + String(format: "%.1f mi · %d points", track.totalDistanceMeters / 1_609.344, track.points.count))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let startedAt = track.startedAt {
                                Text(startedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    trackRecorder.removeTracks(atOffsets: offsets)
                }
                if !selectedTrackIDs.isEmpty {
                    Button("Hide Paths from Map") {
                        selectedTrackIDs = []
                        isShowingWaypointList = false
                    }
                    .font(.subheadline)
                }
            } header: {
                Text("Trails")
            }
        }
    }

    private var accessBlockedState: some View {
        ContentUnavailableView {
            Label(
                LocalString.arkfile_content_offline_map_title,
                systemImage: isWaitingForContentMutation ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver"
            )
        } description: {
            if isWaitingForContentMutation {
                Text("ArkFile is finishing a verified content update. The offline map will reopen automatically.")
            } else {
                Text("The installed offline map could not be opened from verified local storage. Keep your other offline content in place and use Manage Downloads to repair the map when a network is available.")
            }
        }
        .padding()
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label(LocalString.arkfile_content_offline_map_title, systemImage: "map")
        } description: {
            if resources.hasLegacyTiles {
                Text("This install has an older map format. Install the current ArkFile Essentials pack to use the offline vector map.")
            } else {
                Text(LocalString.arkfile_content_offline_map_reference_notice)
            }
        }
        .padding()
    }

    private var topOverlayContext: ArkFileMapTopOverlayContext {
        ArkFileMapOverlayBudget.topContext(
            hasError: mapError != nil,
            hasNotice: mapNotice != nil,
            isMeasuring: isMeasuring,
            isRecording: trackRecorder.isRecording,
            hasCriticalPlacesHint: criticalPlacesHintMessage != nil,
            isCriticalPlacesStoreAvailable: placesController.isStoreAvailable
        )
    }

    private var showsRegionalOffer: Bool {
        ArkFileMapOverlayBudget.showsRegionalOffer(
            hasRegionHint: regionHint != nil,
            topContext: topOverlayContext,
            isCriticalPlacesStoreAvailable: placesController.isStoreAvailable
        )
    }

    @ViewBuilder
    private var topContextualPill: some View {
        switch topOverlayContext {
        case .none:
            EmptyView()
        case .error:
            if let mapError {
                errorPill(mapError)
            }
        case .notice:
            if let mapNotice {
                noticePill(mapNotice)
            }
        case .measure:
            measurePill
        case .recording:
            recordingPill
        case .criticalPlacesHint:
            if let message = criticalPlacesHintMessage {
                criticalPlacesHintPill(
                    message,
                    isDismissible: !placesController.isStoreAvailable
                )
            }
        case .criticalPlacesChips:
            criticalPlacesChips
        }
    }

    private var criticalPlacesChips: some View {
        Menu {
            Button {
                showNearestPlaces()
            } label: {
                Label("Find Places in This Area", systemImage: "cross.circle")
            }
            Divider()
            Button {
                selectedCriticalPlaceKinds = ArkFileCriticalPlaceSearchGroup.allKinds
            } label: {
                Label("Show All", systemImage: "checkmark.circle")
            }
            Button {
                selectedCriticalPlaceKinds = []
            } label: {
                Label("Hide All", systemImage: "circle.slash")
            }
            Divider()
            ForEach(ArkFileCriticalPlaceSearchGroup.mapChips) { group in
                Button {
                    toggleCriticalPlaceGroup(group)
                } label: {
                    Label(
                        group.title,
                        systemImage: isCriticalPlaceGroupSelected(group)
                            ? "checkmark.circle.fill"
                            : group.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(Color.arkInteractiveForeground)
                Text("Critical Places")
                Text(criticalPlacesSelectionSummary)
                    .foregroundStyle(Color.arkTextMuted)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.arkTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.arkBorder.opacity(0.8), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            "Critical Places filters, \(selectedCriticalPlaceGroupCount) of \(ArkFileCriticalPlaceSearchGroup.mapChips.count) enabled"
        )
    }

    private var selectedCriticalPlaceGroupCount: Int {
        ArkFileCriticalPlaceSearchGroup.mapChips.filter(isCriticalPlaceGroupSelected).count
    }

    private var effectiveCriticalPlaceKinds: Set<ArkFileCriticalPlaceKind> {
        ArkFileCriticalPlaceSelection.effectiveKinds(selectedCriticalPlaceKinds)
    }

    private var hasCriticalPlacesAccess: Bool {
        ArkFileContentPackInstaller.shared.hasSavedLiteAccess
    }

    private var criticalPlacesSelectionSummary: String {
        if selectedCriticalPlaceGroupCount == 0 {
            return "Hidden"
        }
        if selectedCriticalPlaceGroupCount == ArkFileCriticalPlaceSearchGroup.mapChips.count {
            return "All"
        }
        return "\(selectedCriticalPlaceGroupCount)/\(ArkFileCriticalPlaceSearchGroup.mapChips.count)"
    }

    private var criticalPlacesHintMessage: String? {
        if !placesController.isStoreAvailable, !dismissedCriticalPlacesUnavailableHint {
            return hasCriticalPlacesAccess
                ? "Download U.S. hospitals, water, fuel, food, and more for offline use."
                : "U.S. hospitals, water, fuel, food, and more. Included with Essentials and Complete."
        }
        if placesController.isStoreAvailable,
           !effectiveCriticalPlaceKinds.isEmpty,
           isBelowPlacesZoom {
            return "Zoom in to see Critical Places on the map."
        }
        return nil
    }

    private func criticalPlacesHintPill(
        _ message: String,
        isDismissible: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cross.circle")
                    .foregroundStyle(Color.arkInteractiveForeground)
                VStack(alignment: .leading, spacing: 4) {
                    if !placesController.isStoreAvailable {
                        Text("Find Critical Places offline")
                            .fontWeight(.bold)
                            .accessibilityIdentifier("arkfile_critical_places_hint")
                    }
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isDismissible {
                    Button {
                        dismissCriticalPlacesUnavailableHint()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss Critical Places hint")
                }
            }
            if !placesController.isStoreAvailable {
                Button {
                    if hasCriticalPlacesAccess {
                        openCriticalPlacesDownloads()
                    } else {
                        openPackComparison(returnToMapDownloads: false)
                    }
                } label: {
                    Text(criticalPlacesActionTitle)
                        .foregroundStyle(.white)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(Color.arkTeal)
                .accessibilityIdentifier("arkfile_critical_places_action")
            }
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkTeal.opacity(0.45), lineWidth: 1)
        }
    }

    private var mapCriticalPlaces: [ArkFileCriticalPlace] {
        let visible = placesController.visiblePlaces
        guard let highlightedCriticalPlace,
              !visible.contains(where: { $0.id == highlightedCriticalPlace.id }) else {
            return visible
        }
        return visible + [highlightedCriticalPlace]
    }

    private func toggleCriticalPlaceGroup(_ group: ArkFileCriticalPlaceSearchGroup) {
        var kinds = effectiveCriticalPlaceKinds
        if isCriticalPlaceGroupSelected(group) {
            kinds.subtract(group.kinds)
        } else {
            kinds.formUnion(group.kinds)
        }
        selectedCriticalPlaceKinds = kinds
    }

    private func isCriticalPlaceGroupSelected(_ group: ArkFileCriticalPlaceSearchGroup) -> Bool {
        !effectiveCriticalPlaceKinds.intersection(group.kinds).isEmpty
    }

    /// Called from the map coordinator when the camera settles. Feeds the
    /// places controller (which debounces its own database work) and distills
    /// the camera into the two cheap `@State` values the body actually reads,
    /// assigning them only on real changes so panning does not re-render the
    /// whole screen.
    private func handleCameraChange(_ camera: ArkFileMapCameraState) {
        guard !isShowingMapPacks else { return }
        let newCoverage = resources.coverageStatus(
            at: camera.center, zoom: camera.zoom, viewport: camera.bounds
        )
        if mapCoverageStatus != newCoverage { mapCoverageStatus = newCoverage }
        let availableZoom = resources.bestAvailableMaxZoom(at: camera.center)
        let zoomOutTarget = availableZoom > 0 && camera.zoom > availableZoom + 0.5
            ? availableZoom : nil
        if mapZoomOutTarget != zoomOutTarget { mapZoomOutTarget = zoomOutTarget }
        placesController.cameraDidChange(
            center: camera.center,
            zoom: camera.zoom,
            bounds: camera.bounds,
            kinds: effectiveCriticalPlaceKinds
        )
        if isCoordinateSelectionMode,
           coordinateSelectionCenter != camera.center {
            coordinateSelectionCenter = camera.center
        }
        let newBelowPlacesZoom = camera.zoom < ArkFileCriticalPlacesStore.minimumViewportZoom
        if isBelowPlacesZoom != newBelowPlacesZoom {
            isBelowPlacesZoom = newBelowPlacesZoom
        }
        let newHint = ArkFileMapRegionHint.resolve(
            center: camera.center,
            zoom: camera.zoom,
            bestAvailableMaxZoom: resources.bestAvailableMaxZoom(at: camera.center),
            index: regionIndex,
            installedRegionIDs: Set(resources.regions.compactMap(\.id)),
            dismissedRegionIDs: dismissedRegionHintIDs,
            // Read imperatively: observing the installer here re-rendered the
            // map on every download progress tick.
            hasCompleteAccess: ArkFileContentPackInstaller.shared.hasSavedCompleteAccess
        )
        if regionHint != newHint {
            regionHint = newHint
        }
    }

    private func showNearestPlaces() {
        guard placesController.isStoreAvailable, let store = placesController.store else {
            showMapDownloads()
            return
        }
        // Panning expresses the area being explored. My Location can center
        // the map first when the user wants places near their phone.
        let initialCenter = Self.initialCamera().center
        let origin = placesController.lastCenter ?? ArkFileMapCoordinate(
            latitude: initialCenter.latitude, longitude: initialCenter.longitude
        )
        nearestOriginText = "Near the area shown on your map. Tap My Location first to search near you."
        // Open the sheet immediately; the ring search runs on the store's
        // queue so a wide search never blocks the map.
        let groups = ArkFileCriticalPlaceSearchGroup.nearestGroups
        nearestPlaceSections = []
        isLoadingNearestPlaces = true
        isShowingNearestPlaces = true
        store.nearestAsync(
            to: origin,
            kindGroups: groups.map(\.kinds),
            limit: 3
        ) { results in
            isLoadingNearestPlaces = false
            let sections = zip(groups, results).compactMap { group, matches -> ArkFileNearestPlacesSection? in
                guard !matches.isEmpty else { return nil }
                return ArkFileNearestPlacesSection(group: group, matches: matches)
            }
            if sections.isEmpty {
                isShowingNearestPlaces = false
                mapError = "No Critical Places were found within 500 km of this location."
            } else {
                nearestPlaceSections = sections
            }
        }
    }

    private func regionHintPill(_ hint: ArkFileMapRegionHint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "map")
                    .foregroundStyle(Color.arkAmber)
                Text(hint.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_map_region_offer")
                Spacer(minLength: 0)
                Button {
                    for region in hint.regions { dismissRegionHint(region.id) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss region detail hint")
            }
            Button {
                showMapDownloads(region: hint.regions.count == 1 ? hint.region : nil)
            } label: {
                Text(hint.regions.count > 1 ? "Choose Map" : "View Map Details")
                    .foregroundStyle(.white)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(Color.arkTeal)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkGold.opacity(0.55), lineWidth: 1)
        }
    }

    private var measurePill: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if measurePoints.count < 2 {
                    Label(
                        measurePoints.isEmpty
                            ? "Tap the map to set the first point."
                            : "Tap the map to set the second point.",
                        systemImage: "ruler"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                } else {
                    Label(measureSummary, systemImage: "ruler")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Straight-line distance. Tap the map again to start a new measurement.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Done") {
                isMeasuring = false
                measurePoints = []
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop measuring")
        }
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkTeal.opacity(0.5), lineWidth: 1)
        }
        .accessibilityLabel(measurePoints.count < 2 ? "Measuring: tap the map" : measureSummary)
    }

    private var selectedTracks: [ArkFileMapTrack] {
        trackRecorder.savedTracks.filter { selectedTrackIDs.contains($0.id) }
    }

    private func locateMe() {
        isMapVisible = true
        reconcileLocationAccess()
        trackRecorder.beginLiveUpdates()
        trackRecorder.endLiveUpdates()
        if let location = trackRecorder.currentLocation {
            focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: location)
        } else if trackRecorder.isAuthorizationDenied {
            mapError = "Location access is off. Allow it in Settings to see your position on the offline map."
        } else {
            // First fix can take a few seconds; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let location = trackRecorder.currentLocation {
                    focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: location)
                }
            }
        }
    }

    private func shareMyLocation() {
        trackRecorder.beginLiveUpdates()
        if let location = trackRecorder.currentLocation {
            presentShareForMyLocation(location)
            trackRecorder.endLiveUpdates()
            return
        }
        if trackRecorder.isAuthorizationDenied {
            mapError = "Location access is off. Allow it in Settings to share your position from the offline map."
            trackRecorder.endLiveUpdates()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let location = trackRecorder.currentLocation {
                presentShareForMyLocation(location)
            } else if trackRecorder.isAuthorizationDenied {
                mapError = "Location access is off. Allow it in Settings to share your position from the offline map."
            } else {
                mapError = "ArkFile could not get your location yet. Try again in a moment."
            }
            trackRecorder.endLiveUpdates()
        }
    }

    private func presentShareForMyLocation(_ location: ArkFileMapCoordinate) {
        let link = ArkFileMapLocationLink(
            name: "My Location",
            latitude: location.latitude,
            longitude: location.longitude,
            kind: .meeting
        )
        sharePayload = .message(link.shareMessage)
    }

    private func shareMessage(for waypoint: ArkFileMapWaypoint) -> String {
        ArkFileMapLocationLink(
            name: waypoint.name,
            latitude: waypoint.latitude,
            longitude: waypoint.longitude,
            kind: waypoint.kind
        ).shareMessage
    }

    private func shareMessage(for place: ArkFileCriticalPlace) -> String {
        ArkFileMapLocationLink(
            name: place.displayName,
            latitude: place.latitude,
            longitude: place.longitude,
            kind: place.kind.waypointKind
        ).shareMessage
    }

    private func saveWaypoint(editor: ArkFileWaypointEditorState, name: String, kind: ArkFileMapWaypointKind?) {
        switch editor.mode {
        case .create(let coordinate):
            saveNewWaypoint(name: name, coordinate: coordinate, kind: kind)
        case .edit(let waypoint):
            waypointStore.update(id: waypoint.id, name: name, kind: kind)
            focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: waypoint.coordinate)
        }
    }

    private func saveNewWaypoint(
        name: String,
        coordinate: ArkFileMapCoordinate,
        kind: ArkFileMapWaypointKind?
    ) {
        guard let waypoint = waypointStore.add(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: kind
        ) else {
            mapError = "Waypoint limit reached. Delete an older waypoint before adding another."
            return
        }
        focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: waypoint.coordinate)
    }

    private func saveMapLocationLink(_ link: ArkFileMapLocationLink) {
        let name = link.name ?? link.kind?.displayName ?? "Shared Location"
        saveNewWaypoint(name: name, coordinate: link.coordinate, kind: link.kind)
    }

    private func consumePendingMapLocationIfNeeded() {
        guard let link = ArkFileMapLocationRouter.takePendingLink() else { return }
        presentInboundMapLocation(link)
    }

    private func consumePendingGPXImportIfNeeded() {
        guard let url = ArkFileMapGPXRouter.takePendingImportURL() else { return }
        importGPX(from: url)
    }

    private func presentInboundMapLocation(_ link: ArkFileMapLocationLink) {
        inboundLocationPrompt = ArkFileInboundLocationPrompt(link: link)
    }

    private func pasteCoordinatesFromMessage() {
        let text = UIPasteboard.general.string ?? ""
        let parsed = ArkFileCoordinateParser.parse(text)
        if parsed.isEmpty {
            pasteError = "No usable coordinates found on the clipboard."
            return
        }
        pasteError = nil
        isShowingWaypointList = false
        if parsed.count == 1, let candidate = parsed.first {
            DispatchQueue.main.async {
                waypointEditor = .create(
                    coordinate: candidate.coordinate,
                    suggestedName: candidate.name,
                    kind: nil
                )
            }
        } else {
            DispatchQueue.main.async {
                pasteCandidates = parsed
            }
        }
    }

    private func exportGPX() {
        presentGPXReview(ArkFileGPXReviewRequest(
            mode: .shareFile,
            document: ArkFileMapGPXDocument(waypoints: waypointStore.waypoints, tracks: trackRecorder.savedTracks),
            filename: "Saved places and trails"
        ))
    }

    private func beginGPXImport() {
        if isShowingWaypointList {
            importsGPXAfterListDismissal = true
            isShowingWaypointList = false
        } else {
            isImportingGPX = true
        }
    }

    private var hasBlockingGPXPresentation: Bool {
        gpxReview != nil || isShowingWaypointList || isShowingMapPacks
            || isAddingCoordinateWaypoint || waypointEditor != nil
            || inboundLocationPrompt != nil || sharePayload != nil
            || isShowingNearestPlaces || !pasteCandidates.isEmpty
            || isImportingGPX || isNamingTrack
    }

    private func presentPendingGPXAction() {
        guard !hasBlockingGPXPresentation else { return }
        if let request = pendingGPXReview {
            pendingGPXReview = nil
            importsGPXAfterListDismissal = false
            gpxReview = request
        } else if importsGPXAfterListDismissal {
            importsGPXAfterListDismissal = false
            isImportingGPX = true
        }
    }

    private func presentGPXReview(_ request: ArkFileGPXReviewRequest) {
        if isShowingWaypointList || isShowingMapPacks {
            pendingGPXReview = request
            isShowingWaypointList = false
            isShowingMapPacks = false
        } else if hasBlockingGPXPresentation {
            // Incoming files wait for an active editor or share sheet to close.
            // Preserve both the user's in-progress work and the parsed file.
            pendingGPXReview = request
        } else {
            gpxReview = request
        }
    }

    private func importGPX(from url: URL) {
        // Read once while access is valid. Confirmation operates on this parsed
        // snapshot, never on a provider URL that may have expired or changed.
        gpxImportTask?.cancel()
        mapNotice = "Reading places and paths…"
        mapError = nil
        gpxImportTask = Task {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try ArkFileMapGPX.parse(url: url)
                }.value
                guard !Task.isCancelled else { return }
                mapNotice = nil
                // The native file picker is finishing dismissal when it calls
                // its completion. Give its presentation transaction a turn.
                await Task.yield()
                guard !Task.isCancelled else { return }
                presentGPXReview(ArkFileGPXReviewRequest(
                    mode: .importFile, document: document, filename: url.lastPathComponent
                ))
            } catch {
                guard !Task.isCancelled else { return }
                mapError = error.localizedDescription
                mapNotice = nil
            }
        }
    }

    private func showGPXItemsOnMap(_ result: ArkFileGPXImportResult) {
        selectedTrackIDs = Set(result.tracks.map(\.id))
        mapNotice = result.summary
        focusGPXItems(waypoints: result.waypoints, tracks: result.tracks)
    }

    private func focusGPXItems(waypoints: [ArkFileMapWaypoint], tracks: [ArkFileMapTrack]) {
        let coordinates = waypoints.map(\.coordinate) + tracks.flatMap { track in
            track.points.map { ArkFileMapCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        }
        guard let first = coordinates.first else { return }
        let bounds = ArkFileMapGPX.displayBounds(for: coordinates)
        focusRequest = ArkFileMapFocusRequest(
            nonce: UUID(), coordinate: first, bounds: bounds,
            zoom: bounds == nil ? 14 : nil
        )
    }

    private var recordingPill: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                Text(recordingSummary)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            if let backToStart = trackRecorder.backToStartSummary {
                Text(backToStart)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.4), lineWidth: 1)
        }
        .accessibilityLabel("Recording trail. \(recordingSummary)")
    }

    private var recordingSummary: String {
        let miles = trackRecorder.activeDistanceMeters / 1_609.344
        let distanceText = miles < 0.19
            ? String(format: "%.0f ft", trackRecorder.activeDistanceMeters * 3.28084)
            : String(format: "%.1f mi", miles)
        return "Recording trail · \(distanceText) · \(trackRecorder.activePoints.count) points"
    }

    private var measureSummary: String {
        guard measurePoints.count == 2 else { return "" }
        let a = measurePoints[0]
        let b = measurePoints[1]
        let distance = ArkFileMapMeasurement.distanceMeters(
            fromLatitude: a.latitude, longitude: a.longitude,
            toLatitude: b.latitude, longitude: b.longitude
        )
        let bearing = ArkFileMapMeasurement.bearingDegrees(
            fromLatitude: a.latitude, longitude: a.longitude,
            toLatitude: b.latitude, longitude: b.longitude
        )
        return ArkFileMapMeasurement.summaryText(distanceMeters: distance, bearingDegrees: bearing)
    }

    private func errorPill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func noticePill(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(Color.arkInk)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkGold.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static func contentRoot(fromLegacyMapURL url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let last = standardized.lastPathComponent.lowercased()
        if last == "tiles" {
            return standardized
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        if last == "maps" {
            return standardized.deletingLastPathComponent()
        }
        return standardized
    }

    private func refreshAccessAndResources() {
        if isShowingMapPacks {
            refreshMapDownloadResources()
            return
        }
        if managedContentReadToken?.isReleased != false {
            managedContentReadToken = ArkFileManagedContentConcurrencyGate.tryBeginMapRead()
        }
        guard let readToken = managedContentReadToken, !readToken.isReleased else {
            isWaitingForContentMutation = true
            isAccessBlocked = true
            resources = Self.emptyMapResources()
            placesController.configure(databaseURL: nil)
            reconcileLocationAccess()
            return
        }
        isWaitingForContentMutation = false
        isAccessBlocked = !Self.canOpenMapContentRoot(contentRoot)
        resources = isAccessBlocked
            ? Self.emptyMapResources()
            : ArkFileOfflineMapResources.locate(contentRoot: contentRoot)
        if isAccessBlocked || !resources.hasVectorMap {
            // No MapLibre lifetime will exist to own this token. Discovery was
            // protected, so it is safe to release immediately instead of
            // needlessly deferring a future map install.
            readToken.release()
            managedContentReadToken = nil
        }
        regionIndex = ArkFileMapRegionIndex.loadBundled()
        placesController.configure(databaseURL: isAccessBlocked ? nil : resources.criticalPlacesURL)
        placesController.kindsDidChange(effectiveCriticalPlaceKinds)
        reconcileLocationAccess()
    }

    private func refreshMapDownloadResources() {
        // Drop only the parent's reference. An existing MapLibre coordinator
        // remains the sole owner responsible for releasing its live token at
        // actual UIView teardown; never release that token from sheet state.
        managedContentReadToken = nil
        placesController.configure(databaseURL: nil)
        guard let discoveryToken = ArkFileManagedContentConcurrencyGate.tryBeginMapRead() else {
            isWaitingForContentMutation = true
            reconcileLocationAccess()
            return
        }
        defer { discoveryToken.release() }
        isWaitingForContentMutation = false
        isAccessBlocked = !Self.canOpenMapContentRoot(contentRoot)
        resources = isAccessBlocked
            ? Self.emptyMapResources()
            : ArkFileOfflineMapResources.locate(contentRoot: contentRoot)
        regionIndex = ArkFileMapRegionIndex.loadBundled()
        reconcileLocationAccess()
    }

    /// A sentinel with no URLs or leases. It is the only resource value built
    /// without a map-reader token, and can never create an MLNMapView.
    private static func emptyMapResources() -> ArkFileOfflineMapResources {
        ArkFileOfflineMapResources.locate(
            contentRoot: nil,
            bundleResourceRoot: nil,
            canOpenFile: { _ in false }
        )
    }

    private func reconcileLocationAccess() {
        let actions = ArkFileMapLocationAccessPolicy.actions(
            isAccessBlocked: isAccessBlocked,
            isMapVisible: isMapVisible && !isShowingMapPacks,
            ownsLiveUpdateRequest: ownsLiveUpdateRequest,
            isRecording: trackRecorder.isRecording
        )
        if actions.contains(.stopAndSaveRecording) {
            isNamingTrack = false
            trackRecorder.stopRecordingAndSave(name: "")
        }
        if actions.contains(.releaseLiveUpdates) {
            ownsLiveUpdateRequest = false
            trackRecorder.endLiveUpdates()
        }
        if actions.contains(.acquireLiveUpdates) {
            ownsLiveUpdateRequest = true
            trackRecorder.beginLiveUpdates()
        }
    }

    private static func canOpenMapContentRoot(_ contentRoot: URL?) -> Bool {
        guard let contentRoot else {
            return true
        }
        return ArkFileEssentialsAccessGate.canOpenEssentialsURLSync(contentRoot)
    }

    private var criticalPlacesActionTitle: String {
        hasCriticalPlacesAccess ? "View Map Downloads" : "Compare Packs"
    }

    private func openCriticalPlacesDownloads() {
        showMapDownloads()
    }

    private func showMapDownloads(region: ArkFileMapRegionIndex.Region? = nil) {
        mapPackCenter = placesController.lastCenter ?? ArkFileMapCoordinate(
            latitude: Self.defaultCenter.latitude,
            longitude: Self.defaultCenter.longitude
        )
        // The camera is saved when the renderer is dismantled. An earlier
        // focus request must not replay over that camera when it is recreated.
        focusRequest = nil
        selectedMapRegion = region
        isShowingMapPacks = true
    }

    private func focusMap(on region: ArkFileMapRegionIndex.Region) {
        guard let center = region.center else { return }
        focusRequest = ArkFileMapFocusRequest(nonce: UUID(), coordinate: center, bounds: region.bounds)
    }

    private func regionPreviewPill(_ region: ArkFileMapRegionIndex.Region) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(region.displayName, systemImage: "map")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button { previewMapRegion = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Close coverage preview")
            }
            Text("Approximate download coverage. Neighboring regions can overlap.")
                .font(.caption)
            Button("View Map Details") { showMapDownloads(region: region) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.arkTeal)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("arkfile_map_coverage_preview")
    }

    private func openDownloads(relativePath: String? = nil) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var userInfo: [String: String]?
            if let relativePath {
                userInfo = ["relativePath": relativePath]
            }
            NotificationCenter.default.post(
                name: .arkFileOpenContentDownloads,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func openPackComparison(relativePath: String? = nil, returnToMapDownloads: Bool = true) {
        // The scene root owns closing Map and presenting the comparison. A
        // single event keeps the region context with that navigation action.
        var userInfo: [String: Any] = ["returnToMaps": true, "returnToMapDownloads": returnToMapDownloads]
        if let relativePath { userInfo["relativePath"] = relativePath }
        NotificationCenter.default.post(
            name: .arkFileOpenPackComparison,
            object: nil,
            userInfo: userInfo
        )
    }

    private func dismissRegionHint(_ regionID: String) {
        dismissedRegionHintIDs.insert(regionID)
        UserDefaults.standard.set(Array(dismissedRegionHintIDs), forKey: Self.dismissedRegionHintsKey)
        if regionHint?.regions.contains(where: { $0.id == regionID }) == true {
            regionHint = nil
        }
    }

    private func dismissCriticalPlacesUnavailableHint() {
        dismissedCriticalPlacesUnavailableHint = true
        UserDefaults.standard.set(true, forKey: Self.dismissedCriticalPlacesUnavailableHintKey)
    }

    private static func loadDismissedRegionHintIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: dismissedRegionHintsKey) ?? [])
    }

    private func persistSelectedCriticalPlaceKinds() {
        guard let selectedCriticalPlaceKinds else { return }
        UserDefaults.standard.set(
            selectedCriticalPlaceKinds.map(\.rawValue).sorted(),
            forKey: Self.selectedCriticalPlaceKindsKey
        )
    }

    private static func loadSelectedCriticalPlaceKinds() -> Set<ArkFileCriticalPlaceKind>? {
        ArkFileCriticalPlaceSelection.load(from: .standard, key: selectedCriticalPlaceKindsKey)
    }
}

/// One-shot request to move the camera to a waypoint; the nonce makes each
/// tap distinct even for the same coordinate.
struct ArkFileMapFocusRequest: Equatable {
    let nonce: UUID
    let coordinate: ArkFileMapCoordinate
    var bounds: [Double]? = nil
    var zoom: Double? = nil
}

private struct ArkFileMapCameraState: Equatable {
    let center: ArkFileMapCoordinate
    let zoom: Double
    var bounds: ArkFileCriticalPlacesBoundingBox?
}

private struct ArkFileWaypointEditorState: Identifiable {
    enum Mode {
        case create(ArkFileMapCoordinate)
        case edit(ArkFileMapWaypoint)
    }

    let id: String
    let mode: Mode
    let initialName: String
    let initialKind: ArkFileMapWaypointKind?

    var coordinate: ArkFileMapCoordinate {
        switch mode {
        case .create(let coordinate):
            return coordinate
        case .edit(let waypoint):
            return waypoint.coordinate
        }
    }

    static func create(
        coordinate: ArkFileMapCoordinate,
        suggestedName: String? = nil,
        kind: ArkFileMapWaypointKind? = nil
    ) -> ArkFileWaypointEditorState {
        ArkFileWaypointEditorState(
            id: UUID().uuidString,
            mode: .create(coordinate),
            initialName: suggestedName ?? "",
            initialKind: kind
        )
    }

    static func edit(_ waypoint: ArkFileMapWaypoint) -> ArkFileWaypointEditorState {
        ArkFileWaypointEditorState(
            id: waypoint.id,
            mode: .edit(waypoint),
            initialName: waypoint.name,
            initialKind: waypoint.kind
        )
    }
}

private struct ArkFileInboundLocationPrompt: Identifiable {
    let id = UUID()
    let link: ArkFileMapLocationLink
}

private struct ArkFileMapSharePayload: Identifiable {
    let id = UUID()
    let activityItems: [Any]

    static func message(_ message: String) -> ArkFileMapSharePayload {
        ArkFileMapSharePayload(activityItems: [message])
    }

    static func file(_ url: URL) -> ArkFileMapSharePayload {
        ArkFileMapSharePayload(activityItems: [url])
    }
}

private struct ArkFileCriticalPlaceSearchGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let kinds: Set<ArkFileCriticalPlaceKind>

    static let medical = ArkFileCriticalPlaceSearchGroup(
        id: "medical",
        title: "Hospitals",
        systemImage: "cross.case.fill",
        kinds: [.hospital, .clinic]
    )
    static let pharmacies = ArkFileCriticalPlaceSearchGroup(
        id: "pharmacies",
        title: "Pharmacies",
        systemImage: "pills.fill",
        kinds: [.pharmacy]
    )
    static let fuel = ArkFileCriticalPlaceSearchGroup(
        id: "fuel",
        title: "Fuel",
        systemImage: "fuelpump.fill",
        kinds: [.fuel]
    )
    static let food = ArkFileCriticalPlaceSearchGroup(
        id: "food",
        title: "Food",
        systemImage: "cart.fill",
        kinds: [.food]
    )
    static let water = ArkFileCriticalPlaceSearchGroup(
        id: "water",
        title: "Water",
        systemImage: "drop.fill",
        kinds: [.water]
    )
    static let safety = ArkFileCriticalPlaceSearchGroup(
        id: "safety",
        title: "Police/Fire",
        systemImage: "shield.lefthalf.filled",
        kinds: [.police, .fire]
    )

    static let mapChips: [ArkFileCriticalPlaceSearchGroup] = [
        .medical, .pharmacies, .fuel, .food, .water, .safety
    ]

    static let allKinds = mapChips.reduce(into: Set<ArkFileCriticalPlaceKind>()) { result, group in
        result.formUnion(group.kinds)
    }

    static let nearestGroups: [ArkFileCriticalPlaceSearchGroup] = mapChips
}

private struct ArkFileMapPacksSheet: View {
    let index: ArkFileMapRegionIndex
    let center: ArkFileMapCoordinate
    let installedRegionIDs: Set<String>
    let currentCoverageDescription: String
    let hasMapDetail: Bool
    let hasCriticalPlaces: Bool
    let onView: (ArkFileMapRegionIndex.Region?) -> Void
    let onPreview: (ArkFileMapRegionIndex.Region) -> Void
    let onCompare: (ArkFileMapRegionIndex.Region?) -> Void
    let onManage: (ArkFileMapRegionIndex.Region) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var installer = ArkFileContentPackInstaller.shared
    @State private var searchText = ""
    @State private var filter = ArkFileMapDiscoveryFilter.all
    @State private var selectedRegion: ArkFileMapRegionIndex.Region?

    init(
        index: ArkFileMapRegionIndex,
        center: ArkFileMapCoordinate,
        installedRegionIDs: Set<String>,
        currentCoverageDescription: String,
        hasMapDetail: Bool,
        hasCriticalPlaces: Bool,
        initialRegion: ArkFileMapRegionIndex.Region?,
        onView: @escaping (ArkFileMapRegionIndex.Region?) -> Void,
        onPreview: @escaping (ArkFileMapRegionIndex.Region) -> Void,
        onCompare: @escaping (ArkFileMapRegionIndex.Region?) -> Void,
        onManage: @escaping (ArkFileMapRegionIndex.Region) -> Void
    ) {
        self.index = index
        self.center = center
        self.installedRegionIDs = installedRegionIDs
        self.currentCoverageDescription = currentCoverageDescription
        self.hasMapDetail = hasMapDetail
        self.hasCriticalPlaces = hasCriticalPlaces
        self.onView = onView
        self.onPreview = onPreview
        self.onCompare = onCompare
        self.onManage = onManage
        _selectedRegion = State(initialValue: initialRegion)
    }

    private var visibleRegions: [ArkFileMapRegionIndex.Region] {
        index.discoveryRegions(query: searchText, around: center).filter {
            filter.includes(
                isInstalled: installedRegionIDs.contains($0.id),
                hasAccess: installer.hasSavedCompleteAccess
            )
        }
    }

    var body: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Label("World overview · Included with ArkFile", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(currentCoverageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Essentials adds North America map detail and U.S. Critical Places. Complete includes Essentials and all \(index.regions.count) U.S. street-map regions. Choose only the areas you need; there are no separate map purchases.")
                        .font(.subheadline)
                }

                Section("Map detail & places") {
                    Text("Find U.S. hospitals, pharmacies, fuel, food, water, and police/fire locations offline. This download also adds North America map detail.")
                        .font(.subheadline)
                    Text("North America detail: \(hasMapDetail ? "Downloaded" : "Not downloaded") · Critical Places: \(hasCriticalPlaces ? "Downloaded" : "Not downloaded")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ArkFileMapDownloadControl(
                        itemKey: nil,
                        title: "Map detail & places",
                        isInstalled: hasMapDetail && hasCriticalPlaces,
                        tier: .lite,
                        onOpen: { onView(nil) },
                        onUpgrade: { onCompare(nil) }
                    )
                }
            }

            Section("Regional street maps") {
                if dynamicTypeSize.isAccessibilitySize {
                    regionFilterPicker.pickerStyle(.menu).frame(minHeight: 44)
                } else {
                    regionFilterPicker.pickerStyle(.segmented)
                }
            }

            if visibleRegions.isEmpty {
                Section {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Maps in This View" : "No Matching Maps",
                        systemImage: "map",
                        description: Text(searchText.isEmpty
                            ? "Choose All to explore regional street maps."
                            : "Search by state name, state abbreviation, or region.")
                    )
                }
            } else {
                Section {
                    ForEach(visibleRegions) { region in
                        HStack(alignment: .center, spacing: 12) {
                            Button {
                                if installedRegionIDs.contains(region.id) {
                                    onView(region)
                                } else {
                                    selectedRegion = region
                                }
                            } label: {
                                regionRow(region)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("arkfile_map_region_\(region.id)")
                            if installedRegionIDs.contains(region.id) {
                                Button {
                                    selectedRegion = region
                                } label: {
                                    Image(systemName: "info.circle")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Details for \(region.displayName)")
                            }
                        }
                    }
                } header: {
                    Text("Regional street maps")
                } footer: {
                    Text("Regions covering the current map location appear first. Sizes may change with map updates; the download total is checked before you confirm.")
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search state or region"
        )
        .navigationDestination(item: $selectedRegion) { region in
            regionDetails(region)
        }
        .accessibilityIdentifier("arkfile_map_downloads_root")
    }

    private func regionRow(_ region: ArkFileMapRegionIndex.Region) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "map")
                .font(.title3)
                .foregroundStyle(Color.arkInteractiveForeground)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(region.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                Text(region.statesDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if region.contains(center) {
                    Label("Around this map location", systemImage: "scope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(regionStatus(region))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                if let size = region.formattedSize {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: installedRegionIDs.contains(region.id) ? "arrow.up.right" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }

    private var regionFilterPicker: some View {
        Picker("Show regional maps", selection: $filter) {
            ForEach(ArkFileMapDiscoveryFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .accessibilityIdentifier("arkfile_map_download_filter")
    }

    private func regionStatus(_ region: ArkFileMapRegionIndex.Region) -> String {
        if installedRegionIDs.contains(region.id) { return "Downloaded · Open map" }
        switch installer.downloadQueueState(for: region.relativePath) {
        case .queued:
            return installer.downloadQueue.isPaused ? "Queued · Downloads paused" : "Queued for download"
        case .active: return "Downloading"
        case .paused: return "Paused · Resume download"
        case .none:
            return installer.hasSavedCompleteAccess
                ? "Included with Complete · Not downloaded"
                : "Requires Complete"
        }
    }

    private func regionDetails(_ region: ArkFileMapRegionIndex.Region) -> some View {
        List {
            Section {
                Label(region.displayName, systemImage: "map.fill")
                    .font(.title2.weight(.semibold))
                Text(region.statesDescription)
                Text("Adds street-level detail to ArkFile’s offline map. Download before traveling; no connection is needed to view the downloaded map.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let size = region.formattedSize {
                    Label("Regional download: \(size)", systemImage: "internaldrive")
                        .font(.subheadline)
                }
                Button("Preview Coverage", systemImage: "viewfinder") { onPreview(region) }
                    .accessibilityIdentifier("arkfile_map_preview_\(region.id)")
                Text("The preview uses your downloaded map. Its outline shows approximate coverage, including overlap with neighboring regions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ArkFileMapDownloadControl(
                    itemKey: region.relativePath,
                    title: region.displayName,
                    isInstalled: installedRegionIDs.contains(region.id),
                    tier: .complete,
                    onOpen: { onView(region) },
                    onUpgrade: { onCompare(region) }
                )
                if installedRegionIDs.contains(region.id) {
                    Button("Manage Download", systemImage: "internaldrive") { onManage(region) }
                }
            } footer: {
                Text("All \(index.regions.count) U.S. street-map regions are included with Complete. Buying or upgrading unlocks them; downloads are your choice.")
            }
        }
        .navigationTitle(region.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("arkfile_map_region_details")
    }
}

private struct ArkFileMapDownloadPresentation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .presentationSizing(.page)
                .presentationDetents([.large])
        } else {
            content.presentationDetents([.large])
        }
    }
}

/// This small download surface observes transfer ticks; the MapLibre parent
/// deliberately does not, so a transfer never makes the whole map re-render.
private struct ArkFileMapDownloadControl: View {
    let itemKey: String?
    let title: String
    let isInstalled: Bool
    let tier: ArkFileContentTier
    let onOpen: () -> Void
    let onUpgrade: () -> Void

    @StateObject private var installer = ArkFileContentPackInstaller.shared
    @State private var isPreparing = false
    @State private var preview: ArkFileContentDownloadPreview?
    @State private var preparationError: String?
    @State private var showsConfirmation = false

    private var hasAccess: Bool {
        tier == .complete ? installer.hasSavedCompleteAccess : installer.hasSavedLiteAccess
    }

    private var queueState: ArkFileDownloadQueueItemState {
        itemKey.map { installer.downloadQueueState(for: $0) } ?? installer.mapFoundationQueueState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isInstalled {
                Label("Downloaded · Works offline", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Button("Open Map", systemImage: "map", action: onOpen)
                    .buttonStyle(.borderedProminent)
            } else if queueState != .none {
                queueControl
                if !hasAccess {
                    Text("Restore or update your purchase access before resuming this map download.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(upgradeTitle, action: onUpgrade)
                        .buttonStyle(.bordered)
                }
            } else if !hasAccess {
                Text(tier == .complete ? "Requires Complete" : "Included with Essentials and Complete")
                    .font(.subheadline.weight(.semibold))
                Button(upgradeTitle, action: onUpgrade)
                    .buttonStyle(.borderedProminent)
            } else {
                queueControl
            }
            if let preparationError {
                Text(preparationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
        .tint(Color.arkPrimary)
        .confirmationDialog(
            "Download \(title)?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Download — \(formatted(preview?.downloadBytes ?? 0))") {
                if let itemKey {
                    installer.includeItemAndDownload(key: itemKey, tier: tier)
                } else {
                    installer.downloadMapFoundation()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var upgradeTitle: String {
        guard tier == .complete else { return "View Content Packs" }
        return installer.hasSavedLiteAccess ? "Upgrade to Complete" : "View Complete"
    }

    @ViewBuilder
    private var queueControl: some View {
        switch queueState {
        case .none:
            Text(tier == .complete ? "Included with Complete · Not downloaded" : "Included with your purchase · Not downloaded")
                .font(.subheadline.weight(.semibold))
            if isPreparing {
                ProgressView("Checking download size…")
            } else {
                Button(preparationError == nil ? "Review Download" : "Retry Download Check", systemImage: "arrow.down.circle") {
                    prepareDownload()
                }
                .buttonStyle(.borderedProminent)
            }
        case .queued:
            Label("Queued for download", systemImage: "clock")
            if installer.downloadQueue.isPaused {
                Text("Your download queue is paused.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Resume Downloads") { installer.resumeQueuedDownloads() }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.isBusy || !hasAccess)
            } else {
                Text("Starts after the current downloads finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let itemKey {
                Button("Remove from Queue", role: .destructive) { installer.removeQueuedItem(key: itemKey) }
            } else if installer.hasQueuedStandaloneMapFoundation {
                Button("Remove from Queue", role: .destructive) { installer.removeQueuedMapFoundation() }
            } else {
                Text("Needed by a queued regional map.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .active:
            ProgressView(value: installer.state.progressFraction)
            Text("\(activePhaseTitle) · Keep ArkFile open for the most reliable download")
                .font(.caption)
            if installer.canPauseLiteDownload {
                Button("Pause Downloads") { installer.cancelLiteDownload() }
            }
        case .paused:
            Label(installer.state.phase == .failed ? "Download needs attention" : "Download paused", systemImage: "pause.circle")
            if let error = installer.state.errorMessage, installer.state.phase == .failed {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if hasAccess {
                Button("Resume Downloads") { installer.resumeQueuedDownloads() }
                    .buttonStyle(.borderedProminent)
            }
            if installer.canCancelPausedDownloadRequest {
                Button("Remove Stopped Download", role: .destructive) {
                    installer.cancelPausedDownloadRequest()
                }
                Text("Removes the stopped batch from the queue. Downloaded maps stay available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var activePhaseTitle: String {
        switch installer.state.phase {
        case .preparing, .purchasing: "Preparing download"
        case .verifying: "Checking download"
        case .installing: "Adding to your offline map"
        default: "Downloading"
        }
    }

    private var confirmationMessage: String {
        guard let preview else { return "" }
        var message = "Current total to download: \(formatted(preview.downloadBytes))."
        if itemKey != nil, preview.mapFoundationBytes > 0 {
            message += " This includes \(formatted(preview.mapFoundationBytes)) of Map detail & places needed by the regional map."
        }
        message += " Existing downloads stay available and are reused. Queued downloads may reduce this total."
        return message
    }

    private func prepareDownload() {
        isPreparing = true
        preparationError = nil
        Task {
            defer { isPreparing = false }
            do {
                preview = try await installer.downloadPreview(
                    keys: itemKey.map { [$0] } ?? [],
                    tier: tier,
                    includesMapFoundation: itemKey == nil
                )
                showsConfirmation = true
            } catch {
                preparationError = "The download could not be prepared. \(error.localizedDescription)"
            }
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ArkFileNearestPlacesSection: Identifiable, Equatable {
    let group: ArkFileCriticalPlaceSearchGroup
    let matches: [ArkFileCriticalPlaceMatch]

    var id: String { group.id }
}

private struct ArkFileNearestPlacesSheet: View {
    let originText: String
    let sections: [ArkFileNearestPlacesSection]
    var isLoading = false
    let onSelect: (ArkFileCriticalPlace) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(originText, systemImage: "location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isLoading && sections.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching nearby places…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(sections) { section in
                    Section(section.group.title) {
                        ForEach(section.matches) { match in
                            Button {
                                onSelect(match.place)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: match.place.kind.systemImage)
                                        .foregroundStyle(match.place.kind.waypointKind.swiftUIColor)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(match.place.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(Color.arkTextPrimary)
                                        Text(match.place.detailText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(match.summaryText)
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Places in This Area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ArkFileWaypointEditorSheet: View {
    let editor: ArkFileWaypointEditorState
    let onSave: (String, ArkFileMapWaypointKind?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedKind: ArkFileMapWaypointKind?

    init(
        editor: ArkFileWaypointEditorState,
        onSave: @escaping (String, ArkFileMapWaypointKind?) -> Void
    ) {
        self.editor = editor
        self.onSave = onSave
        _name = State(initialValue: editor.initialName)
        _selectedKind = State(initialValue: editor.initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Text(coordinateText(editor.coordinate))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ArkFileCoordinateDetailText(coordinate: editor.coordinate)
                }
                Section("Kind") {
                    ArkFileWaypointKindGrid(selectedKind: $selectedKind)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, selectedKind)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var title: String {
        switch editor.mode {
        case .create:
            return "Save Waypoint"
        case .edit:
            return "Edit Waypoint"
        }
    }
}

private struct ArkFileCoordinateWaypointSheet: View {
    let onSave: (String, ArkFileMapCoordinate, ArkFileMapWaypointKind?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var coordinateEntry = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var selectedKind: ArkFileMapWaypointKind?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField(LocalString.arkfile_content_offline_map_coordinate_entry_placeholder, text: $coordinateEntry)
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Latitude (e.g. 39.7392)", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude (e.g. -104.9903)", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(LocalString.arkfile_content_offline_map_coordinate_entry_footer)
                }
                Section("Kind") {
                    ArkFileWaypointKindGrid(selectedKind: $selectedKind)
                }
            }
            .navigationTitle("Add by Coordinates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let trimmedCoordinateEntry = coordinateEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCoordinateEntry.isEmpty {
            guard let parsed = ArkFileCoordinateParser.parse(trimmedCoordinateEntry).first else {
                errorMessage = LocalString.arkfile_content_offline_map_coordinate_entry_error
                return
            }
            onSave(name, parsed.coordinate, selectedKind)
            dismiss()
            return
        }

        let trimmedLat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lat = Double(trimmedLat),
              let lon = Double(trimmedLon),
              ArkFileMapLocationLink.isValid(latitude: lat, longitude: lon) else {
            errorMessage = "Enter latitude between -90 and 90 and longitude between -180 and 180."
            return
        }
        onSave(name, ArkFileMapCoordinate(latitude: lat, longitude: lon), selectedKind)
        dismiss()
    }
}

private struct ArkFileInboundLocationSheet: View {
    let link: ArkFileMapLocationLink
    let onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(link.displayTitle, systemImage: link.kind?.systemImage ?? "mappin.circle.fill")
                        .foregroundStyle(link.kind?.swiftUIColor ?? Color.arkTeal)
                    Text(coordinateText(link.coordinate))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ArkFileCoordinateDetailText(coordinate: link.coordinate)
                } footer: {
                    Text("ArkFile never adds pins from links automatically. Confirm before saving this location on your map.")
                }
            }
            .navigationTitle("Add Shared Location?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ArkFilePasteCoordinateCandidatesSheet: View {
    let candidates: [ArkFileParsedCoordinate]
    let onSelect: (ArkFileParsedCoordinate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates) { candidate in
                Button {
                    onSelect(candidate)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name ?? "Pasted Location")
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextPrimary)
                        Text(coordinateText(candidate.coordinate))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        ArkFileCoordinateDetailText(coordinate: candidate.coordinate)
                        Text(candidate.sourceFormat)
                            .font(.caption2)
                            .foregroundStyle(Color.arkTaupe)
                    }
                }
            }
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

enum ArkFileWaypointKindGridLayoutPolicy {
    static func usesSingleColumn(isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize
    }

    static func columns(isAccessibilitySize: Bool) -> [GridItem] {
        if usesSingleColumn(isAccessibilitySize: isAccessibilitySize) {
            return [GridItem(.flexible(minimum: 0), spacing: 8)]
        }
        return [GridItem(.adaptive(minimum: 92), spacing: 8)]
    }
}

private struct ArkFileWaypointKindGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selectedKind: ArkFileMapWaypointKind?

    private var isAccessibilitySize: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        LazyVGrid(
            columns: ArkFileWaypointKindGridLayoutPolicy.columns(
                isAccessibilitySize: isAccessibilitySize
            ),
            alignment: .leading,
            spacing: 8
        ) {
            kindButton(nil, title: "No Kind", systemImage: "mappin.circle")
            ForEach(ArkFileMapWaypointKind.allCases, id: \.rawValue) { kind in
                kindButton(kind, title: kind.displayName, systemImage: kind.systemImage)
            }
        }
        .padding(.vertical, 4)
    }

    private func kindButton(
        _ kind: ArkFileMapWaypointKind?,
        title: String,
        systemImage: String
    ) -> some View {
        let isSelected = selectedKind == kind
        let tint = kind?.swiftUIColor ?? Color.arkTaupe
        return Button {
            selectedKind = kind
        } label: {
            Group {
                if isAccessibilitySize {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.headline)
                        Text(title)
                            .font(.body)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: systemImage)
                            .font(.headline)
                        Text(title)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: isAccessibilitySize ? 44 : 58
            )
            .foregroundStyle(isSelected ? Color.white : tint)
            .background(isSelected ? tint : Color.arkSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ArkFileActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ArkFileCoordinateDetailText: View {
    let coordinate: ArkFileMapCoordinate

    var body: some View {
        let text = ArkFileGridCoordinate.detailText(for: coordinate)
        if !text.isEmpty {
            Text(text)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.arkTaupe)
                .lineLimit(2)
        }
    }
}

private func coordinateText(_ coordinate: ArkFileMapCoordinate) -> String {
    "\(ArkFileMapLocationLink.coordinateString(coordinate.latitude)), \(ArkFileMapLocationLink.coordinateString(coordinate.longitude))"
}

private extension ArkFileMapWaypointKind {
    var swiftUIColor: Color {
        Color(red: colorComponents.red, green: colorComponents.green, blue: colorComponents.blue)
    }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(colorComponents.red),
            green: CGFloat(colorComponents.green),
            blue: CGFloat(colorComponents.blue),
            alpha: 1
        )
    }
}

private final class ArkFileWaypointAnnotation: MLNPointAnnotation {
    let waypointID: String
    var kind: ArkFileMapWaypointKind?

    init(waypointID: String, kind: ArkFileMapWaypointKind?) {
        self.waypointID = waypointID
        self.kind = kind
        super.init()
    }

    required init?(coder: NSCoder) {
        self.waypointID = ""
        self.kind = nil
        super.init(coder: coder)
    }
}

private final class ArkFileCriticalPlaceAnnotation: MLNPointAnnotation {
    let placeID: Int64
    let kind: ArkFileCriticalPlaceKind
    var isHighlighted: Bool

    init(placeID: Int64, kind: ArkFileCriticalPlaceKind, isHighlighted: Bool) {
        self.placeID = placeID
        self.kind = kind
        self.isHighlighted = isHighlighted
        super.init()
    }

    required init?(coder: NSCoder) {
        self.placeID = 0
        self.kind = .hospital
        self.isHighlighted = false
        super.init(coder: coder)
    }
}

private enum ArkFileWaypointPinImage {
    static func make(kind: ArkFileMapWaypointKind?) -> UIImage {
        let size = CGSize(width: 34, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let fill = kind?.uiColor ?? UIColor(red: 0.06, green: 0.43, blue: 0.42, alpha: 1)
        let symbolName = kind?.systemImage ?? "mappin.circle.fill"
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            fill.setFill()
            let circleRect = CGRect(x: 3, y: 1, width: 28, height: 28)
            cgContext.fillEllipse(in: circleRect)
            cgContext.move(to: CGPoint(x: 17, y: 39))
            cgContext.addLine(to: CGPoint(x: 10, y: 25))
            cgContext.addLine(to: CGPoint(x: 24, y: 25))
            cgContext.closePath()
            cgContext.fillPath()
            cgContext.setShadow(offset: .zero, blur: 0, color: nil)

            if let symbol = UIImage(systemName: symbolName)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(in: CGRect(x: 9, y: 7, width: 16, height: 16))
            }
        }
    }
}

private enum ArkFileCriticalPlacePinImage {
    static func make(kind: ArkFileCriticalPlaceKind, highlighted: Bool) -> UIImage {
        let size = highlighted ? CGSize(width: 38, height: 44) : CGSize(width: 30, height: 34)
        let renderer = UIGraphicsImageRenderer(size: size)
        let fill = kind.waypointKind.uiColor
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.24).cgColor)
            fill.setFill()
            let circleInset = highlighted ? CGFloat(3) : CGFloat(2)
            let circleSize = highlighted ? CGFloat(32) : CGFloat(26)
            let circleRect = CGRect(x: circleInset, y: 1, width: circleSize, height: circleSize)
            cgContext.fillEllipse(in: circleRect)
            if highlighted {
                UIColor.white.withAlphaComponent(0.9).setStroke()
                cgContext.setLineWidth(2)
                cgContext.strokeEllipse(in: circleRect.insetBy(dx: 1, dy: 1))
            }
            if let symbol = UIImage(systemName: kind.systemImage)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let symbolSize = highlighted ? CGFloat(17) : CGFloat(14)
                let origin = CGPoint(
                    x: (size.width - symbolSize) / 2,
                    y: highlighted ? 8 : 7
                )
                symbol.draw(in: CGRect(origin: origin, size: CGSize(width: symbolSize, height: symbolSize)))
            }
        }
    }
}

private struct ArkFileMapLibreView: UIViewRepresentable {
    let resources: ArkFileOfflineMapResources
    let managedContentReadToken: ArkFileManagedContentReaderToken
    let center: CLLocationCoordinate2D
    let zoom: Double
    let persistsCamera: Bool
    var waypoints: [ArkFileMapWaypoint] = []
    var focusRequest: ArkFileMapFocusRequest?
    var coverageRegion: ArkFileMapRegionIndex.Region?
    var isMeasuring = false
    var measurePoints: [ArkFileMapCoordinate] = []
    var showsUserLocation = false
    var activeTrackPoints: [ArkFileTrackPoint] = []
    var selectedTracks: [ArkFileMapTrack] = []
    var criticalPlaces: [ArkFileCriticalPlace] = []
    var highlightedCriticalPlaceID: Int64?
    @Binding var mapError: String?
    var onLongPress: ((ArkFileMapCoordinate) -> Void)?
    var onMeasureTap: ((ArkFileMapCoordinate) -> Void)?
    var onCameraChanged: ((ArkFileMapCameraState) -> Void)?
    var onShareWaypoint: ((String) -> Void)?
    var onSaveCriticalPlace: ((Int64) -> Void)?
    var onShareCriticalPlace: ((Int64) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            managedContentReadToken: managedContentReadToken,
            mapError: $mapError,
            persistsCamera: persistsCamera,
            onLongPress: onLongPress,
            onMeasureTap: onMeasureTap,
            onCameraChanged: onCameraChanged,
            onShareWaypoint: onShareWaypoint,
            onSaveCriticalPlace: onSaveCriticalPlace,
            onShareCriticalPlace: onShareCriticalPlace
        )
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL(context: context))
        mapView.accessibilityIdentifier = "arkfile_map_canvas"
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.minimumZoomLevel = 0
        mapView.maximumZoomLevel = resources.displayMaxZoom
        mapView.setCenter(center, zoomLevel: zoom, animated: false)
        // ArkFile owns the permission prompt; browsing download coverage must
        // never let the map renderer request location on its own.
        mapView.shouldRequestAuthorizationToUseLocationServices = false
        mapView.showsUserLocation = showsUserLocation
        mapView.showsScale = true
        if persistsCamera {
            // Keep native ornaments clear of the status and filter controls.
            // The footer is outside this view, so attribution remains visible.
            mapView.scaleBarPosition = .bottomLeft
            mapView.scaleBarMargins = CGPoint(x: 14, y: 36)
            mapView.compassViewPosition = .bottomRight
            mapView.compassViewMargins = CGPoint(x: 14, y: 36)
        }
        context.coordinator.signature = resources.signature
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        mapView.addGestureRecognizer(longPress)
        let measureTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMeasureTap(_:))
        )
        measureTap.isEnabled = isMeasuring
        mapView.addGestureRecognizer(measureTap)
        context.coordinator.measureTapRecognizer = measureTap
        context.coordinator.syncAnnotations(on: mapView, waypoints: waypoints)
        context.coordinator.syncCriticalPlaces(
            on: mapView,
            places: criticalPlaces,
            highlightedPlaceID: highlightedCriticalPlaceID
        )
        DispatchQueue.main.async {
            context.coordinator.reportCamera(on: mapView)
        }
        return mapView
    }

    static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
        // MapLibre may open PMTiles lazily for the whole UIView lifetime. End
        // the managed-content session only when SwiftUI actually tears down
        // that UIView, never from the parent view's onDisappear callback.
        coordinator.saveCamera(on: mapView)
        mapView.delegate = nil
        mapView.styleURL = nil
        coordinator.releaseManagedContentReadToken()
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Runs for every SwiftUI invalidation of the parent, so each step
        // below must be a cheap no-op when its inputs did not change.
        if mapView.maximumZoomLevel != resources.displayMaxZoom {
            mapView.maximumZoomLevel = resources.displayMaxZoom
        }
        if context.coordinator.signature != resources.signature {
            mapView.styleURL = styleURL(context: context)
            mapView.setCenter(center, zoomLevel: min(zoom, resources.displayMaxZoom), animated: false)
            context.coordinator.signature = resources.signature
        }
        context.coordinator.syncAnnotations(on: mapView, waypoints: waypoints)
        context.coordinator.syncCriticalPlaces(
            on: mapView,
            places: criticalPlaces,
            highlightedPlaceID: highlightedCriticalPlaceID
        )
        if context.coordinator.measureTapRecognizer?.isEnabled != isMeasuring {
            context.coordinator.measureTapRecognizer?.isEnabled = isMeasuring
        }
        context.coordinator.syncMeasureOverlay(on: mapView, points: isMeasuring ? measurePoints : [])
        if mapView.showsUserLocation != showsUserLocation {
            mapView.showsUserLocation = showsUserLocation
        }
        context.coordinator.syncTrackOverlays(
            on: mapView,
            activePoints: activeTrackPoints,
            selectedTracks: selectedTracks
        )
        context.coordinator.syncCoverageOverlay(on: mapView, region: coverageRegion)
        if let focusRequest, context.coordinator.handledFocusNonce != focusRequest.nonce {
            context.coordinator.handledFocusNonce = focusRequest.nonce
            if let bounds = focusRequest.bounds, bounds.count == 4 {
                mapView.setVisibleCoordinateBounds(
                    MLNCoordinateBounds(
                        sw: CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[0]),
                        ne: CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[2])
                    ),
                    edgePadding: UIEdgeInsets(top: 100, left: 28, bottom: coverageRegion == nil ? 60 : 190, right: 28),
                    animated: true,
                    completionHandler: nil
                )
            } else {
                let requestedZoom = focusRequest.zoom
                    ?? max(mapView.zoomLevel, min(9, resources.displayMaxZoom))
                let targetZoom = min(max(requestedZoom, mapView.minimumZoomLevel), resources.displayMaxZoom)
                mapView.setCenter(focusRequest.coordinate.clCoordinate, zoomLevel: targetZoom, animated: true)
            }
        }
    }

    private func styleURL(context: Context) -> URL? {
        do {
            let url = try resources.writeMapLibreStyleFile()
            context.coordinator.mapError.wrappedValue = nil
            return url
        } catch {
            context.coordinator.mapError.wrappedValue = error.localizedDescription
            return nil
        }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var signature = ""
        var mapError: Binding<String?>
        var handledFocusNonce: UUID?
        var measureTapRecognizer: UITapGestureRecognizer?
        private let onLongPress: ((ArkFileMapCoordinate) -> Void)?
        private let persistsCamera: Bool
        private let onMeasureTap: ((ArkFileMapCoordinate) -> Void)?
        private let onCameraChanged: ((ArkFileMapCameraState) -> Void)?
        private let onShareWaypoint: ((String) -> Void)?
        private let onSaveCriticalPlace: ((Int64) -> Void)?
        private let onShareCriticalPlace: ((Int64) -> Void)?
        private var annotationsByWaypointID: [String: ArkFileWaypointAnnotation] = [:]
        private var annotationsByCriticalPlaceID: [Int64: ArkFileCriticalPlaceAnnotation] = [:]
        private var measureLine: MLNPolyline?
        private var measureEndpoints: [MLNPointAnnotation] = []
        private var activeTrackLine: MLNPolyline?
        private var activeTrackPointCount = 0
        private var selectedTrackLines: [MLNPolyline] = []
        private var selectedTrackSingletons: [MLNPointAnnotation] = []
        private var displayedTracks: [ArkFileMapTrack] = []
        private var coverageOutline: MLNPolyline?
        private var coverageRegionID: String?
        private var lastCameraSaveAt = Date.distantPast
        private var lastReportedCamera: ArkFileMapCameraState?
        // SwiftUI re-runs updateUIView for unrelated state changes (pills,
        // recording ticks). These snapshots let every sync bail out in O(1)
        // when nothing it owns actually changed.
        private var lastSyncedWaypoints: [ArkFileMapWaypoint] = []
        private var lastSyncedMeasurePoints: [ArkFileMapCoordinate]?
        private var lastSyncedPlaceIDs: [Int64] = []
        private var lastSyncedHighlightedPlaceID: Int64?
        private var managedContentReadToken: ArkFileManagedContentReaderToken?

        init(
            managedContentReadToken: ArkFileManagedContentReaderToken,
            mapError: Binding<String?>,
            persistsCamera: Bool,
            onLongPress: ((ArkFileMapCoordinate) -> Void)?,
            onMeasureTap: ((ArkFileMapCoordinate) -> Void)?,
            onCameraChanged: ((ArkFileMapCameraState) -> Void)?,
            onShareWaypoint: ((String) -> Void)?,
            onSaveCriticalPlace: ((Int64) -> Void)?,
            onShareCriticalPlace: ((Int64) -> Void)?
        ) {
            self.managedContentReadToken = managedContentReadToken
            self.mapError = mapError
            self.persistsCamera = persistsCamera
            self.onLongPress = onLongPress
            self.onMeasureTap = onMeasureTap
            self.onCameraChanged = onCameraChanged
            self.onShareWaypoint = onShareWaypoint
            self.onSaveCriticalPlace = onSaveCriticalPlace
            self.onShareCriticalPlace = onShareCriticalPlace
        }

        func releaseManagedContentReadToken() {
            managedContentReadToken?.release()
            managedContentReadToken = nil
        }

        deinit {
            // UIKit normally reaches dismantleUIView first. This is the safety
            // path for an interrupted SwiftUI teardown.
            managedContentReadToken?.release()
        }

        @objc @MainActor func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MLNMapView else {
                return
            }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            onLongPress?(ArkFileMapCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ))
        }

        @objc @MainActor func handleMeasureTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let mapView = gesture.view as? MLNMapView else {
                return
            }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            onMeasureTap?(ArkFileMapCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ))
        }

        @MainActor func syncMeasureOverlay(on mapView: MLNMapView, points: [ArkFileMapCoordinate]) {
            guard points != lastSyncedMeasurePoints else { return }
            lastSyncedMeasurePoints = points
            if let measureLine {
                mapView.removeAnnotation(measureLine)
                self.measureLine = nil
            }
            for endpoint in measureEndpoints {
                mapView.removeAnnotation(endpoint)
            }
            measureEndpoints = []

            guard !points.isEmpty else { return }
            for (index, point) in points.enumerated() {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = point.clCoordinate
                annotation.title = index == 0 ? "Point A" : "Point B"
                mapView.addAnnotation(annotation)
                measureEndpoints.append(annotation)
            }
            if points.count == 2 {
                var coordinates = points.map(\.clCoordinate)
                let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                mapView.addAnnotation(line)
                measureLine = line
            }
        }

        @MainActor func syncTrackOverlays(
            on mapView: MLNMapView,
            activePoints: [ArkFileTrackPoint],
            selectedTracks: [ArkFileMapTrack]
        ) {
            // Active recording: refresh only when new points arrived.
            if activePoints.count != activeTrackPointCount {
                if let activeTrackLine {
                    mapView.removeAnnotation(activeTrackLine)
                    self.activeTrackLine = nil
                }
                activeTrackPointCount = activePoints.count
                if activePoints.count > 1 {
                    var coordinates = activePoints.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                    let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                    mapView.addAnnotation(line)
                    activeTrackLine = line
                }
            }

            // Compare the selected models, including identities and geometry.
            // Each GPX segment gets its own line so gaps are never connected.
            if selectedTracks != displayedTracks {
                mapView.removeAnnotations(selectedTrackLines)
                mapView.removeAnnotations(selectedTrackSingletons)
                selectedTrackLines = []
                selectedTrackSingletons = []
                displayedTracks = selectedTracks
                for track in selectedTracks {
                    for segment in track.segments {
                        if segment.count == 1, let point = segment.first {
                            let marker = MLNPointAnnotation()
                            marker.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                            marker.title = track.name
                            marker.subtitle = "Isolated recorded point"
                            selectedTrackSingletons.append(marker)
                            continue
                        }
                        guard segment.count > 1 else { continue }
                        var coordinates = segment.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        }
                        let line = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
                        selectedTrackLines.append(line)
                    }
                }
                mapView.addAnnotations(selectedTrackLines)
                mapView.addAnnotations(selectedTrackSingletons)
            }
        }

        func syncCoverageOverlay(on mapView: MLNMapView, region: ArkFileMapRegionIndex.Region?) {
            guard coverageRegionID != region?.id else { return }
            if let coverageOutline { mapView.removeAnnotation(coverageOutline) }
            coverageOutline = nil
            coverageRegionID = region?.id
            guard let region, region.bounds.count == 4 else { return }
            let b = region.bounds
            var coordinates = [
                CLLocationCoordinate2D(latitude: b[1], longitude: b[0]),
                CLLocationCoordinate2D(latitude: b[3], longitude: b[0]),
                CLLocationCoordinate2D(latitude: b[3], longitude: b[2]),
                CLLocationCoordinate2D(latitude: b[1], longitude: b[2]),
                CLLocationCoordinate2D(latitude: b[1], longitude: b[0])
            ]
            let outline = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
            mapView.addAnnotation(outline)
            coverageOutline = outline
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation === coverageOutline { return UIColor.systemTeal }
            if annotation === activeTrackLine {
                // Live recording: red, matching the recording indicator.
                return UIColor(red: 0.82, green: 0.22, blue: 0.18, alpha: 0.9)
            }
            if selectedTrackLines.contains(where: { annotation === $0 }) {
                // Saved trail: deep teal.
                return UIColor(red: 0.07, green: 0.25, blue: 0.24, alpha: 0.9)
            }
            // Measure line: brand gold.
            return UIColor(red: 0.85, green: 0.51, blue: 0.12, alpha: 0.9)
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            3
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            // Throttled intermediate updates during continuous movement. The
            // old 1 Hz guard also swallowed the FINAL camera event, which left
            // stale places and a stale saved camera; mapViewDidBecomeIdle now
            // guarantees the trailing update instead.
            let now = Date()
            guard now.timeIntervalSince(lastCameraSaveAt) > 0.35 else { return }
            lastCameraSaveAt = now
            reportCameraIfChanged(on: mapView)
        }

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            // The camera settled: persist it and deliver the authoritative
            // final state exactly once.
            saveCamera(on: mapView)
            reportCameraIfChanged(on: mapView)
        }

        func saveCamera(on mapView: MLNMapView) {
            if persistsCamera {
                ArkFileOfflineMapView.saveCamera(
                    center: mapView.centerCoordinate,
                    zoom: mapView.zoomLevel
                )
            }
        }

        private func reportCameraIfChanged(on mapView: MLNMapView) {
            let state = cameraState(for: mapView)
            guard state != lastReportedCamera else { return }
            lastReportedCamera = state
            onCameraChanged?(state)
        }

        private func cameraState(for mapView: MLNMapView) -> ArkFileMapCameraState {
            let visible = mapView.visibleCoordinateBounds
            return ArkFileMapCameraState(
                center: ArkFileMapCoordinate(
                    latitude: mapView.centerCoordinate.latitude,
                    longitude: mapView.centerCoordinate.longitude
                ),
                zoom: mapView.zoomLevel,
                bounds: ArkFileCriticalPlacesBoundingBox(
                    west: visible.sw.longitude,
                    south: visible.sw.latitude,
                    east: visible.ne.longitude,
                    north: visible.ne.latitude
                )
            )
        }

        @MainActor func reportCamera(on mapView: MLNMapView) {
            reportCameraIfChanged(on: mapView)
        }

        @MainActor func syncAnnotations(on mapView: MLNMapView, waypoints: [ArkFileMapWaypoint]) {
            guard waypoints != lastSyncedWaypoints else { return }
            lastSyncedWaypoints = waypoints
            let currentIDs = Set(waypoints.map(\.id))
            for (id, annotation) in annotationsByWaypointID where !currentIDs.contains(id) {
                mapView.removeAnnotation(annotation)
                annotationsByWaypointID.removeValue(forKey: id)
            }
            for waypoint in waypoints {
                if let existing = annotationsByWaypointID[waypoint.id] {
                    if existing.kind != waypoint.kind {
                        mapView.removeAnnotation(existing)
                        annotationsByWaypointID.removeValue(forKey: waypoint.id)
                    } else {
                        existing.title = waypoint.name
                        existing.subtitle = waypointSubtitle(waypoint)
                        continue
                    }
                }
                if annotationsByWaypointID[waypoint.id] == nil {
                    let annotation = ArkFileWaypointAnnotation(waypointID: waypoint.id, kind: waypoint.kind)
                    annotation.coordinate = CLLocationCoordinate2D(
                        latitude: waypoint.latitude,
                        longitude: waypoint.longitude
                    )
                    annotation.title = waypoint.name
                    annotation.subtitle = waypointSubtitle(waypoint)
                    mapView.addAnnotation(annotation)
                    annotationsByWaypointID[waypoint.id] = annotation
                }
            }
        }

        @MainActor func syncCriticalPlaces(
            on mapView: MLNMapView,
            places: [ArkFileCriticalPlace],
            highlightedPlaceID: Int64?
        ) {
            let placeIDs = places.map(\.id)
            guard placeIDs != lastSyncedPlaceIDs || highlightedPlaceID != lastSyncedHighlightedPlaceID else {
                return
            }
            lastSyncedPlaceIDs = placeIDs
            lastSyncedHighlightedPlaceID = highlightedPlaceID
            let currentIDs = Set(places.map(\.id))
            for (id, annotation) in annotationsByCriticalPlaceID where !currentIDs.contains(id) {
                mapView.removeAnnotation(annotation)
                annotationsByCriticalPlaceID.removeValue(forKey: id)
            }
            for place in places {
                let highlighted = place.id == highlightedPlaceID
                if let existing = annotationsByCriticalPlaceID[place.id] {
                    if existing.isHighlighted != highlighted {
                        mapView.removeAnnotation(existing)
                        annotationsByCriticalPlaceID.removeValue(forKey: place.id)
                    } else {
                        existing.title = place.displayName
                        existing.subtitle = place.detailText
                        continue
                    }
                }
                if annotationsByCriticalPlaceID[place.id] == nil {
                    let annotation = ArkFileCriticalPlaceAnnotation(
                        placeID: place.id,
                        kind: place.kind,
                        isHighlighted: highlighted
                    )
                    annotation.coordinate = CLLocationCoordinate2D(
                        latitude: place.latitude,
                        longitude: place.longitude
                    )
                    annotation.title = place.displayName
                    annotation.subtitle = place.detailText
                    mapView.addAnnotation(annotation)
                    annotationsByCriticalPlaceID[place.id] = annotation
                }
            }
        }

        private func waypointSubtitle(_ waypoint: ArkFileMapWaypoint) -> String {
            if let kind = waypoint.kind {
                return "\(kind.displayName) · \(waypoint.coordinateText)"
            }
            return waypoint.coordinateText
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            true
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            if let waypointAnnotation = annotation as? ArkFileWaypointAnnotation {
                let reuseIdentifier = "arkfile-waypoint-\(waypointAnnotation.kind?.rawValue ?? "plain")"
                return MLNAnnotationImage(
                    image: ArkFileWaypointPinImage.make(kind: waypointAnnotation.kind),
                    reuseIdentifier: reuseIdentifier
                )
            }
            if let placeAnnotation = annotation as? ArkFileCriticalPlaceAnnotation {
                let reuseIdentifier = "arkfile-critical-\(placeAnnotation.kind.rawValue)-\(placeAnnotation.isHighlighted)"
                return MLNAnnotationImage(
                    image: ArkFileCriticalPlacePinImage.make(
                        kind: placeAnnotation.kind,
                        highlighted: placeAnnotation.isHighlighted
                    ),
                    reuseIdentifier: reuseIdentifier
                )
            }
            return nil
        }

        func mapView(_ mapView: MLNMapView, leftCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            guard annotation is ArkFileCriticalPlaceAnnotation else { return nil }
            let button = UIButton(type: .contactAdd)
            button.tag = 1
            button.accessibilityLabel = "Save critical place as waypoint"
            return button
        }

        func mapView(_ mapView: MLNMapView, rightCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            guard annotation is ArkFileWaypointAnnotation || annotation is ArkFileCriticalPlaceAnnotation else { return nil }
            let button = UIButton(type: .detailDisclosure)
            button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
            button.tag = 2
            button.accessibilityLabel = annotation is ArkFileWaypointAnnotation ? "Share waypoint" : "Share critical place"
            return button
        }

        func mapView(_ mapView: MLNMapView, annotation: MLNAnnotation, calloutAccessoryControlTapped control: UIControl) {
            if let waypointAnnotation = annotation as? ArkFileWaypointAnnotation {
                onShareWaypoint?(waypointAnnotation.waypointID)
            } else if let placeAnnotation = annotation as? ArkFileCriticalPlaceAnnotation {
                if control.tag == 1 {
                    onSaveCriticalPlace?(placeAnnotation.placeID)
                } else {
                    onShareCriticalPlace?(placeAnnotation.placeID)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            mapError.wrappedValue = nil
        }

        func mapView(_ mapView: MLNMapView, didFailLoadingMapWithError error: Error) {
            mapError.wrappedValue = "Some local map resources could not be loaded."
        }
    }
}
#endif
