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

import Combine
import Foundation
#if os(iOS)
import UIKit

struct ArkFileWeatherBackgroundDiagnosticState: Equatable, Sendable {
    var registrationSucceeded: Bool?
    var requestPending = false
    var lastRequestedAt: Date?
    var lastStartedAt: Date?
    var lastCompletedAt: Date?
    var lastCompletionSucceeded: Bool?
    var lastSubmissionErrorCode: Int?
}

@MainActor
enum ArkFileWeatherBackgroundDiagnostics {
    private(set) static var state =
        ArkFileWeatherBackgroundDiagnosticState()

    static func recordRegistration(succeeded: Bool) {
        state.registrationSucceeded = succeeded
    }

    static func recordSubmission(
        requestedAt: Date,
        errorCode: Int?
    ) {
        state.lastRequestedAt = requestedAt
        state.lastSubmissionErrorCode = errorCode
        state.requestPending = errorCode == nil
    }

    static func recordStart(at date: Date = Date()) {
        state.lastStartedAt = date
        state.requestPending = false
    }

    static func recordCompletion(
        succeeded: Bool,
        at date: Date = Date()
    ) {
        state.lastCompletedAt = date
        state.lastCompletionSucceeded = succeeded
    }

    static func recordCancellation() {
        state.requestPending = false
    }
}
#endif

enum ArkFileSavedWeatherControllerError: Error, Equatable, Sendable {
    case storageUnavailable
    case storageRead
    case storageWrite
    case deletionIncomplete
    case invalidLocation
    case locationPermissionDenied
    case locationServicesDisabled
    case locationUnavailable
    case wifiRequired
    case refreshDeferred(Date?)
    case refreshFailed
}

enum ArkFileWeatherCurrentLocationNotice: Equatable, Sendable {
    case authorizationRequired
    case permissionDenied
    case servicesDisabled
    case locationUnavailable
    case offline
    case wifiRequired
    case travelUpdateFailed

    var message: String {
        switch self {
        case .authorizationRequired:
            "Current Location following is paused until you choose Follow Current Location again and allow access."
        case .permissionDenied:
            "Location access is off. Showing the last saved forecast; turn access on to follow Current Location."
        case .servicesDisabled:
            "Location Services are unavailable. Showing the last saved forecast."
        case .locationUnavailable:
            "ArkFile could not confirm the current location. Showing the last saved forecast."
        case .offline:
            "ArkFile is offline. Showing the last saved forecast for the last confirmed location."
        case .wifiRequired:
            "Automatic updates are set to Wi-Fi only. Showing the last saved forecast for the last confirmed location."
        case .travelUpdateFailed:
            "ArkFile detected a new location but could not save a usable forecast for it. The prior location and briefing remain available."
        }
    }

    var shortMessage: String {
        switch self {
        case .authorizationRequired, .permissionDenied:
            "Location access needed · showing last saved location"
        case .servicesDisabled, .locationUnavailable:
            "Current location unavailable · showing last saved location"
        case .offline:
            "Offline · showing last saved location"
        case .wifiRequired:
            "Waiting for Wi-Fi · showing last saved location"
        case .travelUpdateFailed:
            "New forecast unavailable · showing prior location"
        }
    }
}

extension ArkFileSavedWeatherControllerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Weather storage is unavailable."
        case .storageRead:
            "ArkFile could not read the saved weather briefing."
        case .storageWrite:
            "ArkFile could not save the weather briefing."
        case .deletionIncomplete:
            "ArkFile could not remove all Weather data. Automatic updates "
                + "remain off; try Remove Weather Data again."
        case .invalidLocation:
            "Choose a valid saved weather location."
        case .locationPermissionDenied:
            "Location access is off. You can still choose a point on the offline map or enter coordinates."
        case .locationServicesDisabled:
            "Location Services are unavailable. You can still choose a point on the offline map or enter coordinates."
        case .locationUnavailable:
            "ArkFile could not get a one-time location. Try again or choose another location method."
        case .wifiRequired:
            "Weather is set to refresh on Wi-Fi only. This connection may use "
                + "cellular data or a Personal Hotspot."
        case let .refreshDeferred(until):
            if let until {
                "Update is temporarily paused by the provider or tap cooldown. Try again after \(until.formatted(date: .omitted, time: .shortened))."
            } else {
                "Update is temporarily paused. Try again shortly."
            }
        case .refreshFailed:
            "ArkFile could not update the briefing. The last saved weather remains available."
        }
    }
}

/// Main-actor bridge between lifecycle/UI events and the durable coordinator.
///
/// A Current Location selection may request a silent one-shot fix while ArkFile
/// is active. Pinned locations and background refreshes never start Core
/// Location, and no automatic request may present the authorization prompt.
@MainActor
final class ArkFileSavedWeatherController: ObservableObject {
    nonisolated static let backgroundTaskIdentifier =
        "app.arkfile.saved-weather.refresh"

    static let shared: ArkFileSavedWeatherController = {
        do {
            let store = try ArkFileWeatherStore()
            let transport = ArkFileURLSessionWeatherTransport(
                allowedHosts: [
                    ArkFileNWSWeatherProvider.providerHost,
                    ArkFileCPCOutlookProvider.providerHost
                ]
            )
            let provider = ArkFileNWSWeatherProvider(transport: transport)
            let climateProvider: ArkFileCPCOutlookProvider? =
                FeatureFlags.savedWeatherClimateOutlooks
                    ? ArkFileCPCOutlookProvider(transport: transport)
                    : nil
            return ArkFileSavedWeatherController(
                coordinator: ArkFileWeatherCoordinator(
                    store: store,
                    coreProvider: provider,
                    climateProvider: climateProvider
                )
            )
        } catch {
            return ArkFileSavedWeatherController(
                coordinator: nil,
                startupError: .storageUnavailable
            )
        }
    }()

    @Published private(set) var settings: ArkFileWeatherSettings
    @Published private(set) var snapshot: ArkFileWeatherSnapshot?
    @Published private(set) var connectivity: ArkFileWeatherConnectivity = .unknown
    @Published private(set) var usesExpensiveNetwork = false
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: ArkFileSavedWeatherControllerError?
    @Published private(set) var storageSizeBytes: Int64 = 0
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var hasUnreadableSavedWeatherData = false
    @Published private(set) var isDeletionBlocked = false
    @Published private(set) var isCheckingCurrentLocation = false
    @Published private(set) var currentLocationNotice:
        ArkFileWeatherCurrentLocationNotice?
    private(set) var refreshAttemptCount = 0
    private(set) var lastRefreshAttemptAt: Date?
    private(set) var lastRefreshTrigger:
        ArkFileWeatherRefreshTrigger?

    var isConfigured: Bool {
        settings.savedLocation != nil
    }

    var canResetSavedWeatherData: Bool {
        guard coordinator != nil else { return false }
        if settings.savedLocation != nil
            || storageSizeBytes > 0
            || hasUnreadableSavedWeatherData
            || isDeletionBlocked {
            return true
        }
        if case .storageRead = lastError {
            return true
        }
        return false
    }

    private let coordinator: ArkFileWeatherCoordinator?
    private var refreshCount = 0
    private var hasLoadedState = false
    private var stateGeneration: UInt64 = 0
    private var locationRequestGeneration: UInt64 = 0
    private var automaticLocationTask: Task<Void, Never>?
    private var automaticLocationTaskToken: UUID?
    private var lastAutomaticLocationCheckAt: Date?
    private var isUserInitiatedLocationRequestInProgress = false
    private var isAppActive = false
    private var scheduleBackgroundRefreshHook: ((Date) -> Void)?
    private var cancelBackgroundRefreshHook: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    #if os(iOS)
    private let connectivityMonitor: ArkFileWeatherConnectivityMonitor
    private var locationService: any ArkFileWeatherLocationProviding
    #endif

    init(
        coordinator: ArkFileWeatherCoordinator?,
        startupError: ArkFileSavedWeatherControllerError? = nil
    ) {
        self.coordinator = coordinator
        settings = ArkFileWeatherSettings(
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        lastError = startupError

        #if os(iOS)
        let monitor = ArkFileWeatherConnectivityMonitor()
        connectivityMonitor = monitor
        locationService = ArkFileWeatherLocationService()
        monitor.onReconnect = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reconnectDetected()
            }
        }
        monitor.$connectivity
            .sink { [weak self] value in
                guard let self else { return }
                let wasUnknown = connectivity == .unknown
                connectivity = value
                guard wasUnknown, value == .online, isAppActive else {
                    return
                }
                // `ArkFileWeatherConnectivityMonitor.apply` publishes the
                // path state immediately before its expensive-path bit. Yield
                // once so the first automatic decision observes both values.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self,
                          connectivity == .online,
                          settings.automaticRefreshEnabled else {
                        return
                    }
                    await reconnectDetected()
                }
            }
            .store(in: &cancellables)
        monitor.$usesExpensiveNetwork
            .sink { [weak self] value in
                guard let self else { return }
                let becameUnmetered = usesExpensiveNetwork && !value
                usesExpensiveNetwork = value
                guard becameUnmetered,
                      isAppActive,
                      connectivity == .online,
                      settings.automaticRefreshEnabled,
                      settings.refreshOnWiFiOnly else {
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.reconnectDetected()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    #if os(iOS)
    convenience init(
        coordinator: ArkFileWeatherCoordinator?,
        startupError: ArkFileSavedWeatherControllerError? = nil,
        locationService: any ArkFileWeatherLocationProviding,
        initialConnectivity: ArkFileWeatherConnectivity = .online,
        initiallyUsesExpensiveNetwork: Bool = false
    ) {
        self.init(
            coordinator: coordinator,
            startupError: startupError
        )
        self.locationService = locationService
        connectivity = initialConnectivity
        usesExpensiveNetwork = initiallyUsesExpensiveNetwork
    }
    #endif

    func load() async {
        guard let coordinator else {
            lastError = .storageUnavailable
            return
        }
        let generation = stateGeneration
        do {
            let state = try await coordinator.loadState()
            guard generation == stateGeneration else { return }
            apply(state)
            hasUnreadableSavedWeatherData =
                state.recoveredFromPreviousCopy || state.deletionPending
            if state.deletionPending {
                lastError = .deletionIncomplete
            } else if state.recoveredFromPreviousCopy {
                // The recovered data is safe to show, but callers should know
                // that a storage repair may be appropriate.
                lastError = .storageRead
            }
            updateAutomaticLifecycle()
        } catch {
            guard generation == stateGeneration else { return }
            lastError = Self.map(error)
            hasUnreadableSavedWeatherData = true
        }
    }

    func refreshManually() async {
        await performRefresh(trigger: .manual, reportsWiFiBlock: true)
    }

    func briefingOpened() async {
        #if os(iOS)
        let follow = Task { @MainActor [weak self] in
            await self?.followCurrentLocationIfNeeded()
        }
        #endif
        await performRefresh(trigger: .openingBriefing, reportsWiFiBlock: true)
        #if os(iOS)
        await follow.value
        #endif
    }

    func appDidBecomeActive() async {
        isAppActive = true
        if !hasLoadedState {
            await load()
        }
        updateAutomaticLifecycle()
        #if os(iOS)
        let follow = Task { @MainActor [weak self] in
            await self?.followCurrentLocationIfNeeded()
        }
        #endif
        await performRefresh(trigger: .foreground, reportsWiFiBlock: false)
        #if os(iOS)
        await follow.value
        #endif
    }

    func reconnectDetected() async {
        guard isAppActive else { return }
        #if os(iOS)
        let follow = Task { @MainActor [weak self] in
            await self?.followCurrentLocationIfNeeded(bypassingCooldown: true)
        }
        #endif
        await performRefresh(trigger: .reconnect, reportsWiFiBlock: false)
        #if os(iOS)
        await follow.value
        #endif
    }

    /// Return value maps directly to `BGTask.setTaskCompleted(success:)`.
    /// Policy skips are successful; cancellation and durable/provider failures
    /// are not.
    func performBackgroundRefresh() async -> Bool {
        guard !isDeletionBlocked else { return false }
        if !hasLoadedState {
            await load()
        }
        guard hasLoadedState, !hasUnreadableSavedWeatherData else {
            return false
        }
        #if os(iOS)
        if settings.refreshOnWiFiOnly, connectivity == .unknown {
            await awaitConnectivitySettlement()
        }
        #endif
        let outcome = await performRefresh(
            trigger: .background,
            reportsWiFiBlock: false
        )
        scheduleNextBackgroundRefreshIfNeeded()
        switch outcome {
        case .refreshed, .skipped, .discardedLocationChanged:
            return true
        case .cancelled, .failed, .none:
            return false
        }
    }

    func appDidEnterBackground() {
        isAppActive = false
        // Weather location work is foreground-only. Never let a one-shot fix
        // or candidate travel refresh remain live after the app backgrounds.
        locationRequestGeneration &+= 1
        #if os(iOS)
        automaticLocationTask?.cancel()
        automaticLocationTask = nil
        automaticLocationTaskToken = nil
        isCheckingCurrentLocation = false
        isUserInitiatedLocationRequestInProgress = false
        locationService.cancel()
        #endif
        scheduleNextBackgroundRefreshIfNeeded()
    }

    func cancelRefresh() {
        locationRequestGeneration &+= 1
        #if os(iOS)
        automaticLocationTask?.cancel()
        automaticLocationTask = nil
        automaticLocationTaskToken = nil
        isCheckingCurrentLocation = false
        isUserInitiatedLocationRequestInProgress = false
        locationService.cancel()
        #endif
        Task { [coordinator] in
            await coordinator?.cancelRefreshes()
        }
    }

    func installBackgroundSchedulingHooks(
        schedule: @escaping (Date) -> Void,
        cancel: @escaping () -> Void
    ) {
        scheduleBackgroundRefreshHook = schedule
        cancelBackgroundRefreshHook = cancel
        // AppDelegate installs these hooks before durable Saved Weather state
        // is necessarily available. The in-memory defaults represent
        // "unloaded", not an actual opt-out, so acting on them here could
        // cancel a valid request left pending by the previous process.
        // `load()` applies durable settings and then reconciles scheduling.
        guard hasLoadedState else { return }
        updateAutomaticLifecycle()
    }

    nonisolated static func nextBackgroundRefreshDate(
        after date: Date = Date()
    ) -> Date {
        ArkFileWeatherRefreshPolicy.nextBackgroundRequestDate(after: date)
    }

    nonisolated static func shouldMonitorConnectivity(
        settings: ArkFileWeatherSettings
    ) -> Bool {
        // Reachability is presentation state, not automatic-refresh consent.
        // Monitoring a path does not transmit the saved point; reconnect
        // callbacks remain separately gated by the user's opt-in.
        settings.savedLocation != nil
    }

    nonisolated static func blocksAutomaticRefreshForWiFiPolicy(
        settings: ArkFileWeatherSettings,
        trigger: ArkFileWeatherRefreshTrigger,
        connectivity: ArkFileWeatherConnectivity,
        usesExpensiveNetwork: Bool
    ) -> Bool {
        guard settings.refreshOnWiFiOnly else {
            return false
        }
        switch trigger {
        case .manual:
            return false
        case .openingBriefing, .foreground, .reconnect, .background:
            guard settings.automaticRefreshEnabled else {
                return false
            }
            // An unresolved path is treated conservatively. The monitor's
            // first settled Wi-Fi path invokes a reconnect refresh.
            return connectivity != .online || usesExpensiveNetwork
        }
    }

    nonisolated static func currentLocationDisplayName(
        requested: String,
        isApproximate: Bool
    ) -> String {
        isApproximate ? "Approximate current location" : requested
    }

    nonisolated static func shouldFollowCurrentLocation(
        settings: ArkFileWeatherSettings
    ) -> Bool {
        settings.automaticRefreshEnabled
            && settings.savedLocation?.source == .currentLocation
    }

    nonisolated static func hasMeaningfulCurrentLocationMovement(
        from saved: ArkFileWeatherSavedLocation,
        to measurement: ArkFileWeatherLocationMeasurement
    ) -> Bool {
        guard saved.source == .currentLocation,
              measurement.horizontalAccuracyMeters.isFinite,
              (0 ... 100_000).contains(
                  measurement.horizontalAccuracyMeters
              ),
              let distance = saved.coordinate.distanceMeters(
                  to: measurement.coordinate
              ) else {
            return false
        }
        let priorAccuracy = saved.horizontalAccuracyMeters.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        } ?? 0
        let threshold = max(
            1_000,
            priorAccuracy + measurement.horizontalAccuracyMeters
        )
        return distance >= threshold
    }

    func saveLocation(
        coordinate: ArkFileWeatherCoordinate,
        displayName: String,
        timeZoneIdentifier: String? = nil,
        source: ArkFileWeatherLocationSource,
        measuredAt: Date? = nil,
        horizontalAccuracyMeters: Double? = nil,
        refreshImmediately: Bool = true,
        automaticRefreshEnabled: Bool? = nil
    ) async {
        guard let coordinator else {
            lastError = .storageUnavailable
            return
        }
        #if os(iOS)
        if source != .currentLocation {
            cancelCurrentLocationRequest()
        }
        #endif
        stateGeneration &+= 1
        let generation = stateGeneration
        do {
            let updated = try await coordinator.replaceLocation(
                coordinate: coordinate,
                displayName: displayName,
                timeZoneIdentifier: timeZoneIdentifier,
                source: source,
                measuredAt: measuredAt,
                horizontalAccuracyMeters: horizontalAccuracyMeters,
                automaticRefreshEnabled: automaticRefreshEnabled
            )
            guard generation == stateGeneration else { return }
            settings = updated
            hasLoadedState = true
            snapshot = nil
            storageSizeBytes = 0
            lastRefreshAt = nil
            lastError = nil
            currentLocationNotice = nil
            updateAutomaticLifecycle()
            if refreshImmediately {
                await refreshManually()
            } else {
                await reloadState()
            }
        } catch {
            guard generation == stateGeneration else { return }
            let mapped = Self.map(error)
            if mapped == .storageRead {
                hasUnreadableSavedWeatherData = true
            }
            lastError = mapped
        }
    }

    #if os(iOS)
    func saveCurrentLocation(displayName: String = "Current location") async {
        // An explicit tap always wins over a silent foreground check. Cancel
        // the shared one-shot request first so Core Location cannot reject the
        // user action as a concurrent request or leave the silent spinner set.
        cancelCurrentLocationRequest()
        let requestGeneration = locationRequestGeneration
        isUserInitiatedLocationRequestInProgress = true
        defer {
            if requestGeneration == locationRequestGeneration {
                isUserInitiatedLocationRequestInProgress = false
            }
        }
        do {
            let measurement = try await locationService.requestLocation(
                mode: .userInitiated
            )
            guard requestGeneration == locationRequestGeneration else {
                return
            }
            await saveLocation(
                coordinate: measurement.coordinate,
                displayName: Self.currentLocationDisplayName(
                    requested: displayName,
                    isApproximate: measurement.isApproximate
                ),
                source: .currentLocation,
                measuredAt: measurement.measuredAt,
                horizontalAccuracyMeters: measurement.horizontalAccuracyMeters,
                automaticRefreshEnabled: true
            )
        } catch let error as ArkFileWeatherLocationError {
            guard requestGeneration == locationRequestGeneration else {
                return
            }
            switch error {
            case .authorizationRequired, .permissionDenied:
                lastError = .locationPermissionDenied
            case .servicesDisabled:
                lastError = .locationServicesDisabled
            case .requestAlreadyInProgress, .unavailable, .cancelled:
                if error != .cancelled {
                    lastError = .locationUnavailable
                }
            }
        } catch {
            guard requestGeneration == locationRequestGeneration else {
                return
            }
            lastError = .locationUnavailable
        }
    }

    func cancelCurrentLocationRequest() {
        locationRequestGeneration &+= 1
        automaticLocationTask?.cancel()
        automaticLocationTask = nil
        automaticLocationTaskToken = nil
        isCheckingCurrentLocation = false
        isUserInitiatedLocationRequestInProgress = false
        locationService.cancel()
    }
    #endif

    func setAutomaticRefreshEnabled(_ enabled: Bool) async {
        #if os(iOS)
        if !enabled {
            automaticLocationTask?.cancel()
            automaticLocationTask = nil
            automaticLocationTaskToken = nil
            isCheckingCurrentLocation = false
            currentLocationNotice = nil
            locationService.cancel()
        }
        #endif
        await updateSetting {
            try await $0.setAutomaticRefreshEnabled(enabled)
        }
        #if os(iOS)
        if enabled, isAppActive {
            await followCurrentLocationIfNeeded(bypassingCooldown: true)
        }
        #endif
    }

    func setRefreshOnWiFiOnly(_ enabled: Bool) async {
        await updateSetting {
            try await $0.setRefreshOnWiFiOnly(enabled)
        }
    }

    func setUnitPreference(_ preference: ArkFileWeatherUnitPreference) async {
        await updateSetting {
            try await $0.setUnitPreference(preference)
        }
    }

    func setEnvironmentalPreferences(
        _ preferences: ArkFileWeatherEnvironmentalPreferences
    ) async {
        await updateSetting {
            try await $0.setEnvironmentalPreferences(preferences)
        }
    }

    func deleteSavedWeather() async {
        stateGeneration &+= 1
        let generation = stateGeneration
        isDeletionBlocked = true
        hasUnreadableSavedWeatherData = true
        #if os(iOS)
        connectivityMonitor.stop()
        #endif
        cancelBackgroundRefreshHook?()
        cancelRefresh()
        guard let coordinator else {
            lastError = .storageUnavailable
            return
        }
        do {
            _ = try await coordinator.deleteAll()
            guard generation == stateGeneration else { return }
            settings = ArkFileWeatherSettings(modifiedAt: Date())
            hasLoadedState = true
            snapshot = nil
            storageSizeBytes = 0
            lastRefreshAt = nil
            lastError = nil
            hasUnreadableSavedWeatherData = false
            isDeletionBlocked = false
        } catch {
            guard generation == stateGeneration else { return }
            // Deletion attempts every weather file. Reload whatever remains
            // so the UI never claims the cache is gone after a partial error.
            await reloadState()
            isDeletionBlocked = true
            hasUnreadableSavedWeatherData = true
            lastError = .deletionIncomplete
        }
    }

    func clearError() {
        lastError = nil
    }

    #if os(iOS)
    func redactedDiagnosticsText(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        func date(_ value: Date?) -> String {
            value.map(formatter.string(from:)) ?? "none"
        }
        func component<Value>(
            _ name: String,
            _ value: ArkFileWeatherComponent<Value>?,
            count: Int
        ) -> String where Value: Codable & Equatable & Sendable {
            guard let value else { return "\(name)=none" }
            return "\(name)=\(value.availability.rawValue)"
                + "/\(value.failure?.kind.rawValue ?? "none")"
                + "/count:\(count)"
                + "/fetched:\(date(value.stamp?.fetchedAt))"
                + "/validUntil:\(date(value.stamp?.validUntil))"
        }

        let background = ArkFileWeatherBackgroundDiagnostics.state
        let backgroundStatus: String = switch UIApplication.shared
            .backgroundRefreshStatus {
        case .available: "available"
        case .denied: "off"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        return [
            "Saved Weather diagnostics (redacted)",
            "generated=\(date(now))",
            "featureEnabled=\(FeatureFlags.savedWeather)",
            "configured=\(settings.savedLocation != nil)",
            "automatic=\(settings.automaticRefreshEnabled)",
            "followsCurrentLocation=\(Self.shouldFollowCurrentLocation(settings: settings))",
            "checkingCurrentLocation=\(isCheckingCurrentLocation)",
            "currentLocationNotice=\(String(describing: currentLocationNotice))",
            "wifiOnly=\(settings.refreshOnWiFiOnly)",
            "settingsSchema=\(settings.schemaVersion)",
            "snapshotSchema=\(snapshot?.schemaVersion ?? 0)",
            "cacheBytes=\(storageSizeBytes)",
            "connectivity=\(connectivity.rawValue)",
            "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "unreadableCache=\(hasUnreadableSavedWeatherData)",
            "refreshAttempts=\(refreshAttemptCount)",
            "lastAttempt=\(date(lastRefreshAttemptAt))",
            "lastTrigger=\(lastRefreshTrigger?.rawValue ?? "none")",
            component(
                "hourly",
                snapshot?.hourly,
                count: snapshot?.hourly.value?.count ?? 0
            ),
            component(
                "daily",
                snapshot?.daily,
                count: snapshot?.daily.value?.count ?? 0
            ),
            component(
                "alerts",
                snapshot?.alerts,
                count: snapshot?.alerts.value?.count ?? 0
            ),
            component(
                "climate",
                snapshot?.climateOutlooks,
                count: snapshot?.climateOutlooks.value?.count ?? 0
            ),
            component(
                "astronomy",
                snapshot?.astronomy,
                count: snapshot?.astronomy.value?.count ?? 0
            ),
            component(
                "radio",
                snapshot?.radioTransmitters,
                count: snapshot?.radioTransmitters.value?.count ?? 0
            ),
            "backgroundStatus=\(backgroundStatus)",
            "bgRegistered=\(background.registrationSucceeded.map(String.init) ?? "unknown")",
            "bgPending=\(background.requestPending)",
            "bgRequested=\(date(background.lastRequestedAt))",
            "bgStarted=\(date(background.lastStartedAt))",
            "bgCompleted=\(date(background.lastCompletedAt))",
            "bgSucceeded=\(background.lastCompletionSucceeded.map(String.init) ?? "unknown")",
            "bgSubmitCode=\(background.lastSubmissionErrorCode.map(String.init) ?? "none")"
        ].joined(separator: "\n")
    }
    #endif
}

private extension ArkFileSavedWeatherController {
    #if os(iOS)
    func followCurrentLocationIfNeeded(
        bypassingCooldown: Bool = false,
        now: Date = Date()
    ) async {
        guard isAppActive,
              coordinator != nil,
              !isDeletionBlocked,
              !hasUnreadableSavedWeatherData,
              !isUserInitiatedLocationRequestInProgress,
              Self.shouldFollowCurrentLocation(settings: settings) else {
            return
        }
        if connectivity == .offline {
            currentLocationNotice = .offline
            return
        }
        // The first NWPathMonitor result will invoke reconnectDetected().
        guard connectivity == .online else { return }
        if Self.blocksAutomaticRefreshForWiFiPolicy(
            settings: settings,
            trigger: .foreground,
            connectivity: connectivity,
            usesExpensiveNetwork: usesExpensiveNetwork
        ) {
            currentLocationNotice = .wifiRequired
            return
        }
        if !bypassingCooldown,
           let lastAutomaticLocationCheckAt,
           now < lastAutomaticLocationCheckAt.addingTimeInterval(60) {
            return
        }
        if let automaticLocationTask {
            await automaticLocationTask.value
            return
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAutomaticCurrentLocationCheck(now: now)
        }
        automaticLocationTask = task
        automaticLocationTaskToken = token
        await task.value
        if automaticLocationTaskToken == token {
            automaticLocationTask = nil
            automaticLocationTaskToken = nil
        }
    }

    func performAutomaticCurrentLocationCheck(now: Date) async {
        guard let coordinator,
              isAppActive,
              Self.shouldFollowCurrentLocation(settings: settings) else {
            return
        }
        lastAutomaticLocationCheckAt = now
        locationRequestGeneration &+= 1
        let requestGeneration = locationRequestGeneration
        let stateGeneration = stateGeneration
        isCheckingCurrentLocation = true
        defer {
            if requestGeneration == locationRequestGeneration {
                isCheckingCurrentLocation = false
            }
        }

        let measurement: ArkFileWeatherLocationMeasurement
        do {
            measurement = try await locationService.requestLocation(
                mode: .automaticSilent
            )
        } catch let error as ArkFileWeatherLocationError {
            guard requestGeneration == locationRequestGeneration else {
                return
            }
            switch error {
            case .authorizationRequired:
                currentLocationNotice = .authorizationRequired
            case .permissionDenied:
                currentLocationNotice = .permissionDenied
            case .servicesDisabled:
                currentLocationNotice = .servicesDisabled
            case .requestAlreadyInProgress, .unavailable:
                currentLocationNotice = .locationUnavailable
            case .cancelled:
                break
            }
            return
        } catch {
            guard requestGeneration == locationRequestGeneration else {
                return
            }
            currentLocationNotice = .locationUnavailable
            return
        }

        guard requestGeneration == locationRequestGeneration,
              stateGeneration == self.stateGeneration,
              isAppActive,
              let saved = settings.savedLocation,
              Self.shouldFollowCurrentLocation(settings: settings) else {
            return
        }
        guard Self.hasMeaningfulCurrentLocationMovement(
            from: saved,
            to: measurement
        ) else {
            currentLocationNotice = nil
            return
        }

        let outcome = await coordinator.followCurrentLocation(
            coordinate: measurement.coordinate,
            displayName: Self.currentLocationDisplayName(
                requested: "Current Location",
                isApproximate: measurement.isApproximate
            ),
            measuredAt: measurement.measuredAt,
            horizontalAccuracyMeters:
                measurement.horizontalAccuracyMeters,
            now: now
        )
        guard requestGeneration == locationRequestGeneration else {
            return
        }
        if stateGeneration != self.stateGeneration {
            // The durable store CAS may have completed after an interleaved
            // preference or location operation reloaded. Re-read the winning
            // state so the UI cannot remain one generation behind the disk.
            await reloadState()
            return
        }
        switch outcome {
        case let .refreshed(refreshed):
            snapshot = refreshed
            lastRefreshAt = refreshed.assembledAt
            currentLocationNotice = nil
            lastError = nil
            await reloadState()
        case .discardedLocationChanged:
            await reloadState()
        case .cancelled:
            break
        case .failed, .skipped:
            currentLocationNotice = .travelUpdateFailed
            await reloadState()
        }
    }
    #endif

    @discardableResult
    func performRefresh(
        trigger: ArkFileWeatherRefreshTrigger,
        reportsWiFiBlock: Bool
    ) async -> ArkFileWeatherRefreshOutcome? {
        guard let coordinator else {
            lastError = .storageUnavailable
            return .failed(.storageRead)
        }
        guard !isDeletionBlocked else {
            lastError = .deletionIncomplete
            return .failed(.storageRead)
        }
        guard !hasUnreadableSavedWeatherData else {
            lastError = .storageRead
            return .failed(.storageRead)
        }
        guard settings.savedLocation != nil else {
            return .skipped(.wait(.notConfigured))
        }
        guard !Self.blocksAutomaticRefreshForWiFiPolicy(
            settings: settings,
            trigger: trigger,
            connectivity: connectivity,
            usesExpensiveNetwork: usesExpensiveNetwork
        ) else {
            if reportsWiFiBlock {
                lastError = .wifiRequired
            }
            return .skipped(.wait(.recentAttempt))
        }

        refreshCount += 1
        isLoading = true
        defer {
            refreshCount -= 1
            isLoading = refreshCount > 0
        }
        if trigger == .manual || trigger == .openingBriefing {
            lastError = nil
        }

        refreshAttemptCount += 1
        lastRefreshAttemptAt = Date()
        lastRefreshTrigger = trigger
        let generation = stateGeneration
        let outcome = await coordinator.refresh(trigger: trigger)
        switch outcome {
        case let .refreshed(refreshed):
            guard generation == stateGeneration else { return outcome }
            snapshot = refreshed
            lastRefreshAt = refreshed.assembledAt
            lastError = nil
            await reloadState()
            announceRefresh(
                trigger: trigger,
                message: "Weather update complete."
            )
        case let .skipped(decision):
            if trigger == .manual,
               decision.reason == .providerBackoff
                    || decision.reason == .recentAttempt {
                lastError = .refreshDeferred(decision.nextEligibleAt)
                announceRefresh(
                    trigger: trigger,
                    message: lastError?.localizedDescription
                        ?? "Weather update is temporarily paused."
                )
            }
        case .discardedLocationChanged:
            await reloadState()
        case .cancelled:
            break
        case let .failed(error):
            guard generation == stateGeneration else { return outcome }
            lastError = Self.map(error)
            await reloadState(preservingError: true)
            announceRefresh(
                trigger: trigger,
                message: "Weather could not update. Earlier saved information "
                    + "remains available."
            )
        }
        return outcome
    }

    func updateSetting(
        _ operation: (ArkFileWeatherCoordinator) async throws
            -> ArkFileWeatherSettings
    ) async {
        guard let coordinator else {
            lastError = .storageUnavailable
            return
        }
        stateGeneration &+= 1
        let generation = stateGeneration
        do {
            let updated = try await operation(coordinator)
            guard generation == stateGeneration else { return }
            settings = updated
            lastError = nil
            updateAutomaticLifecycle()
            await reloadState()
        } catch {
            guard generation == stateGeneration else { return }
            lastError = Self.map(error)
        }
    }

    func reloadState(preservingError: Bool = false) async {
        guard let coordinator else { return }
        let generation = stateGeneration
        let savedError = lastError
        do {
            let state = try await coordinator.loadState()
            guard generation == stateGeneration else { return }
            apply(state)
            hasUnreadableSavedWeatherData =
                state.recoveredFromPreviousCopy || state.deletionPending
            updateAutomaticLifecycle()
            if preservingError {
                lastError = savedError
            }
        } catch {
            guard generation == stateGeneration else { return }
            if !preservingError {
                lastError = Self.map(error)
            }
        }
    }

    func apply(_ state: ArkFileWeatherCoordinatorState) {
        hasLoadedState = true
        settings = state.settings
        snapshot = state.snapshot
        storageSizeBytes = state.storageSizeBytes
        lastRefreshAt = state.snapshot?.assembledAt
        isDeletionBlocked = state.deletionPending
    }

    func updateAutomaticLifecycle() {
        let shouldMonitor = !isDeletionBlocked
            && !hasUnreadableSavedWeatherData
            && Self.shouldMonitorConnectivity(settings: settings)
        #if os(iOS)
        if shouldMonitor {
            connectivityMonitor.start()
        } else {
            connectivityMonitor.stop()
        }
        #endif
        if !isDeletionBlocked,
           !hasUnreadableSavedWeatherData,
           settings.savedLocation != nil
            && settings.automaticRefreshEnabled {
            scheduleNextBackgroundRefreshIfNeeded()
        } else {
            cancelBackgroundRefreshHook?()
        }
    }

    func scheduleNextBackgroundRefreshIfNeeded(now: Date = Date()) {
        guard !isDeletionBlocked,
              !hasUnreadableSavedWeatherData,
              settings.savedLocation != nil,
              settings.automaticRefreshEnabled else {
            return
        }
        scheduleBackgroundRefreshHook?(
            Self.nextBackgroundRefreshDate(after: now)
        )
    }

    #if os(iOS)
    func awaitConnectivitySettlement() async {
        // NWPathMonitor commonly publishes within a few milliseconds after a
        // cold background launch. Bound the wait so a missing callback cannot
        // hold a BGAppRefreshTask indefinitely.
        for _ in 0 ..< 20 {
            guard connectivity == .unknown else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
        }
    }
    #endif

    static func map(_ error: Error) -> ArkFileSavedWeatherControllerError {
        guard let error = error as? ArkFileWeatherCoordinatorError else {
            return .refreshFailed
        }
        switch error {
        case .invalidLocation:
            return .invalidLocation
        case .storageRead:
            return .storageRead
        case .storageWrite:
            return .storageWrite
        case .providerUnavailable:
            return .refreshFailed
        }
    }

    func announceRefresh(
        trigger: ArkFileWeatherRefreshTrigger,
        message: String
    ) {
        #if os(iOS)
        guard trigger == .manual else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: message
        )
        #endif
    }
}
