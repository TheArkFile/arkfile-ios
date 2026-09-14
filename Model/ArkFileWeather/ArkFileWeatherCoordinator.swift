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

import Foundation

/// The narrow provider contracts make refresh orchestration deterministic in
/// tests and keep optional outlook sources from becoming a dependency of the
/// core NWS briefing.
protocol ArkFileWeatherCoreProviding: Sendable {
    func refresh(
        location: ArkFileWeatherSavedLocation,
        previous: ArkFileWeatherSnapshot?,
        now: Date
    ) async -> ArkFileNWSRefreshResult
}

extension ArkFileNWSWeatherProvider: ArkFileWeatherCoreProviding {}

protocol ArkFileWeatherClimateOutlookProviding: Sendable {
    func refresh(
        coordinate: ArkFileWeatherCoordinate,
        prior: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        at now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>
}

extension ArkFileCPCOutlookProvider: ArkFileWeatherClimateOutlookProviding {}

enum ArkFileWeatherCoordinatorError: Error, Equatable, Sendable {
    case invalidLocation
    case storageRead
    case storageWrite
    case providerUnavailable
}

enum ArkFileWeatherRefreshOutcome: Equatable, Sendable {
    case refreshed(ArkFileWeatherSnapshot)
    case skipped(ArkFileWeatherRefreshPolicyDecision)
    case discardedLocationChanged
    case cancelled
    case failed(ArkFileWeatherCoordinatorError)
}

struct ArkFileWeatherCoordinatorState: Equatable, Sendable {
    let settings: ArkFileWeatherSettings
    let snapshot: ArkFileWeatherSnapshot?
    let storageSizeBytes: Int64
    let recoveredFromPreviousCopy: Bool
    let deletionPending: Bool
}

/// Owns all durable Saved Weather mutations and refresh flights.
///
/// A flight is keyed by the saved-location revision. Refresh results are
/// merged component-by-component, then the durable settings are re-read before
/// commit. Cancellation is checked immediately before every write so a
/// background-expiration handler cannot save a late response.
actor ArkFileWeatherCoordinator {
    private struct Flight {
        let token: UUID
        let task: Task<ArkFileWeatherRefreshOutcome, Never>
        var waiters: Set<UUID> = []
    }

    private struct FollowFlight {
        let revision: Int
        let token: UUID
        let task: Task<ArkFileWeatherRefreshOutcome, Never>
    }

    private let store: ArkFileWeatherStore
    private let coreProvider: any ArkFileWeatherCoreProviding
    private let climateProvider: (any ArkFileWeatherClimateOutlookProviding)?
    private var flights: [Int: Flight] = [:]
    private var followFlight: FollowFlight?
    private var lastAttemptAtByRevision: [Int: Date] = [:]
    private var mutationEpoch: UInt64 = 0

    init(
        store: ArkFileWeatherStore,
        coreProvider: any ArkFileWeatherCoreProviding,
        climateProvider: (any ArkFileWeatherClimateOutlookProviding)? = nil
    ) {
        self.store = store
        self.coreProvider = coreProvider
        self.climateProvider = climateProvider
    }

    func loadState(now: Date = Date()) async throws -> ArkFileWeatherCoordinatorState {
        let read: ArkFileWeatherStoreStateRead
        do {
            read = try await store.loadState()
        } catch {
            throw ArkFileWeatherCoordinatorError.storageRead
        }
        let settingsResult = read.settings
        let settings: ArkFileWeatherSettings
        if let loaded = settingsResult.value {
            settings = loaded
        } else if Self.onlyMissingFiles(
            settingsResult.currentError,
            settingsResult.previousError
        ) {
            settings = ArkFileWeatherSettings(modifiedAt: now)
        } else {
            throw ArkFileWeatherCoordinatorError.storageRead
        }

        let snapshotResult = read.snapshot
        let snapshot: ArkFileWeatherSnapshot?
        if let loaded = snapshotResult.value,
           loaded.locationRevision == settings.savedLocation?.revision {
            snapshot = loaded
        } else {
            snapshot = nil
        }

        let snapshotHasReadFailure = snapshotResult.value == nil
            && !Self.onlyMissingFiles(
                snapshotResult.currentError,
                snapshotResult.previousError
            )
        guard !snapshotHasReadFailure else {
            throw ArkFileWeatherCoordinatorError.storageRead
        }

        return ArkFileWeatherCoordinatorState(
            settings: settings,
            snapshot: snapshot,
            storageSizeBytes: read.storageSizeBytes,
            recoveredFromPreviousCopy:
                settingsResult.loadedPreviousAfterCurrentFailure
                    || snapshotResult.loadedPreviousAfterCurrentFailure,
            deletionPending: read.deletionPending
        )
    }

    func refresh(
        trigger: ArkFileWeatherRefreshTrigger,
        now: Date = Date()
    ) async -> ArkFileWeatherRefreshOutcome {
        let preflightEpoch = mutationEpoch
        guard !(await store.isDeletionPending()) else {
            return .failed(.storageRead)
        }
        let settingsResult = await store.loadSettings()
        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }
        if settingsResult.currentError != nil,
           !Self.onlyMissingFiles(
               settingsResult.currentError,
               settingsResult.previousError
           ) {
            return .failed(.storageRead)
        }
        guard let settings = settingsResult.value else {
            if Self.onlyMissingFiles(
                settingsResult.currentError,
                settingsResult.previousError
            ) {
                return .skipped(.wait(.notConfigured))
            }
            return .failed(.storageRead)
        }
        guard let location = settings.savedLocation else {
            return .skipped(.wait(.notConfigured))
        }

        if let existing = flights[location.revision] {
            return await awaitFlight(existing, revision: location.revision)
        }

        let snapshotResult = await store.loadSnapshot(
            matchingLocationRevision: location.revision
        )
        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }
        if snapshotResult.currentError != nil,
           !Self.onlyMissingFiles(
               snapshotResult.currentError,
               snapshotResult.previousError
           ) {
            return .failed(.storageRead)
        }
        let previous = snapshotResult.value?.locationRevision == location.revision
            ? snapshotResult.value
            : nil

        // Loading the durable snapshot yields the coordinator actor. A second
        // caller may have installed a flight during that suspension, so join
        // it before evaluating policy or creating another provider task.
        if let existing = flights[location.revision] {
            return await awaitFlight(existing, revision: location.revision)
        }

        let decision = ArkFileWeatherRefreshPolicy.decision(
            trigger: trigger,
            settings: settings,
            snapshot: previous,
            lastAttemptAt: lastAttemptAtByRevision[location.revision],
            // NWS endpoints enforce Retry-After independently. A backed-off
            // forecast must not suppress an eligible official-alert check.
            providerRetryAfter: nil,
            now: now
        )
        guard decision.shouldRefresh else {
            return .skipped(decision)
        }

        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }
        lastAttemptAtByRevision[location.revision] = now
        let token = UUID()
        let store = store
        let coreProvider = coreProvider
        let climateProvider = climateProvider
        let task = Task {
            await Self.performRefresh(
                store: store,
                coreProvider: coreProvider,
                climateProvider: climateProvider,
                location: location,
                previous: previous,
                now: now
            )
        }
        let flight = Flight(token: token, task: task)
        flights[location.revision] = flight
        return await awaitFlight(flight, revision: location.revision)
    }

    func cancelRefreshes() {
        cancelForecastFlights()
        followFlight?.task.cancel()
        followFlight = nil
    }

    private func cancelForecastFlights() {
        for flight in flights.values {
            flight.task.cancel()
        }
        flights.removeAll()
    }

    func followCurrentLocation(
        coordinate: ArkFileWeatherCoordinate,
        displayName: String,
        measuredAt: Date,
        horizontalAccuracyMeters: Double,
        now: Date = Date()
    ) async -> ArkFileWeatherRefreshOutcome {
        let preflightEpoch = mutationEpoch
        guard coordinate.isValid,
              let normalizedName = Self.normalizedDisplayName(displayName),
              measuredAt.timeIntervalSince1970.isFinite,
              horizontalAccuracyMeters.isFinite,
              (0 ... 1_000_000).contains(horizontalAccuracyMeters) else {
            return .failed(.invalidLocation)
        }
        guard !(await store.isDeletionPending()) else {
            return .failed(.storageRead)
        }
        let settingsResult = await store.loadSettings()
        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }
        if settingsResult.currentError != nil,
           !Self.onlyMissingFiles(
               settingsResult.currentError,
               settingsResult.previousError
           ) {
            return .failed(.storageRead)
        }
        guard let settings = settingsResult.value,
              let current = settings.savedLocation,
              current.source == .currentLocation,
              settings.automaticRefreshEnabled else {
            return .discardedLocationChanged
        }
        if let flight = followFlight,
           flight.revision == current.revision {
            return await flight.task.value
        }
        let (candidateRevision, overflow) =
            current.revision.addingReportingOverflow(1)
        guard !overflow, candidateRevision > 0 else {
            return .failed(.storageWrite)
        }
        let candidateLocation = ArkFileWeatherSavedLocation(
            id: current.id,
            revision: candidateRevision,
            coordinate: Self.providerResolutionCoordinate(coordinate),
            displayName: normalizedName,
            timeZoneIdentifier: nil,
            source: .currentLocation,
            selectedAt: current.selectedAt,
            measuredAt: measuredAt,
            horizontalAccuracyMeters: horizontalAccuracyMeters
        )
        let token = UUID()
        let task = Task {
            await self.performFollowFlight(
                expectedRevision: current.revision,
                preflightEpoch: preflightEpoch,
                location: candidateLocation,
                now: now
            )
        }
        followFlight = FollowFlight(
            revision: current.revision,
            token: token,
            task: task
        )
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.cancelFollowFlight(token: token)
            }
        }
        if followFlight?.token == token {
            followFlight = nil
        }
        return outcome
    }

    func replaceLocation(
        coordinate: ArkFileWeatherCoordinate,
        displayName: String,
        timeZoneIdentifier: String?,
        source: ArkFileWeatherLocationSource,
        measuredAt: Date?,
        horizontalAccuracyMeters: Double?,
        now: Date = Date(),
        automaticRefreshEnabled: Bool? = nil
    ) async throws -> ArkFileWeatherSettings {
        guard coordinate.isValid,
              let normalizedName = Self.normalizedDisplayName(displayName),
              Self.validTimeZoneIdentifier(timeZoneIdentifier),
              horizontalAccuracyMeters?.isFinite != false,
              horizontalAccuracyMeters.map({ $0 >= 0 && $0 <= 1_000_000 }) != false else {
            throw ArkFileWeatherCoordinatorError.invalidLocation
        }

        mutationEpoch &+= 1
        cancelRefreshes()
        let updated: ArkFileWeatherSettings
        let durableCoordinate = Self.providerResolutionCoordinate(coordinate)
        do {
            // Keep the prior briefing as a last-good recovery copy until the
            // new location refreshes. Its mismatched revision prevents it from
            // being displayed for this location.
            updated = try await store.replaceLocation(
                coordinate: durableCoordinate,
                displayName: normalizedName,
                timeZoneIdentifier: timeZoneIdentifier,
                source: source,
                measuredAt: measuredAt,
                horizontalAccuracyMeters: horizontalAccuracyMeters,
                modifiedAt: now,
                automaticRefreshEnabled: automaticRefreshEnabled
            )
        } catch {
            throw ArkFileWeatherCoordinatorError.storageWrite
        }
        guard let revision = updated.savedLocation?.revision else {
            throw ArkFileWeatherCoordinatorError.storageWrite
        }
        lastAttemptAtByRevision = lastAttemptAtByRevision.filter {
            $0.key == revision
        }
        return updated
    }

    func setAutomaticRefreshEnabled(
        _ enabled: Bool,
        now: Date = Date()
    ) async throws -> ArkFileWeatherSettings {
        try await updateSettings(
            .automaticRefreshEnabled(enabled),
            now: now
        )
    }

    func setRefreshOnWiFiOnly(
        _ enabled: Bool,
        now: Date = Date()
    ) async throws -> ArkFileWeatherSettings {
        try await updateSettings(.refreshOnWiFiOnly(enabled), now: now)
    }

    func setUnitPreference(
        _ preference: ArkFileWeatherUnitPreference,
        now: Date = Date()
    ) async throws -> ArkFileWeatherSettings {
        try await updateSettings(.unitPreference(preference), now: now)
    }

    func setEnvironmentalPreferences(
        _ preferences: ArkFileWeatherEnvironmentalPreferences,
        now: Date = Date()
    ) async throws -> ArkFileWeatherSettings {
        try await updateSettings(.environmental(preferences), now: now)
    }

    @discardableResult
    func deleteAll() async throws -> Int {
        mutationEpoch &+= 1
        cancelRefreshes()
        lastAttemptAtByRevision.removeAll()
        do {
            return try await store.deleteAll()
        } catch {
            throw ArkFileWeatherCoordinatorError.storageWrite
        }
    }

    private func updateSettings(
        _ mutation: ArkFileWeatherSettingsMutation,
        now: Date
    ) async throws -> ArkFileWeatherSettings {
        do {
            return try await store.mutateSettings(
                mutation,
                modifiedAt: now
            )
        } catch {
            throw ArkFileWeatherCoordinatorError.storageWrite
        }
    }

    private func awaitFlight(
        _ flight: Flight,
        revision: Int
    ) async -> ArkFileWeatherRefreshOutcome {
        let waiter = UUID()
        if var stored = flights[revision],
           stored.token == flight.token {
            stored.waiters.insert(waiter)
            flights[revision] = stored
        }
        let token = flight.token
        let outcome = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiter,
                    token: token,
                    revision: revision
                )
            }
        }
        if flights[revision]?.token == token {
            flights[revision] = nil
        }
        return outcome
    }

    private func cancelWaiter(
        _ waiter: UUID,
        token: UUID,
        revision: Int
    ) {
        guard var flight = flights[revision],
              flight.token == token else {
            return
        }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights[revision] = nil
        } else {
            flights[revision] = flight
        }
    }

    private func cancelFollowFlight(token: UUID) {
        guard followFlight?.token == token else { return }
        followFlight?.task.cancel()
        followFlight = nil
    }

    private func performFollowFlight(
        expectedRevision: Int,
        preflightEpoch: UInt64,
        location: ArkFileWeatherSavedLocation,
        now: Date
    ) async -> ArkFileWeatherRefreshOutcome {
        let assembly = await Self.assembleRefresh(
            coreProvider: coreProvider,
            climateProvider: climateProvider,
            location: location,
            // A candidate location must never inherit alerts, place metadata,
            // radio data, or forecast values from the prior coordinate.
            previous: nil,
            now: now
        )
        guard !Task.isCancelled else { return .cancelled }
        guard assembly.hasUsableForecast else {
            return .failed(.providerUnavailable)
        }
        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }

        let committed: ArkFileWeatherSettings?
        do {
            committed = try await store.commitFollowedLocation(
                expectedRevision: expectedRevision,
                coordinate: location.coordinate,
                displayName: location.displayName,
                timeZoneIdentifier:
                    assembly.resolvedLocation.timeZoneIdentifier,
                measuredAt: location.measuredAt ?? now,
                horizontalAccuracyMeters:
                    location.horizontalAccuracyMeters ?? 0,
                snapshot: assembly.snapshot,
                modifiedAt: now
            )
        } catch {
            return .failed(.storageWrite)
        }
        guard committed != nil else {
            return .discardedLocationChanged
        }
        guard !Task.isCancelled else { return .cancelled }
        guard preflightEpoch == mutationEpoch else {
            return .discardedLocationChanged
        }
        mutationEpoch &+= 1
        cancelForecastFlights()
        lastAttemptAtByRevision = [
            location.revision: now
        ]
        return .refreshed(assembly.snapshot)
    }
}

// MARK: - Refresh assembly

private extension ArkFileWeatherCoordinator {
    struct RefreshAssembly {
        let resolvedLocation: ArkFileWeatherSavedLocation
        let snapshot: ArkFileWeatherSnapshot
        let coreAllFailed: Bool

        var hasUsableForecast: Bool {
            snapshot.hourly.availability == .available
                || snapshot.daily.availability == .available
        }
    }

    static func performRefresh(
        store: ArkFileWeatherStore,
        coreProvider: any ArkFileWeatherCoreProviding,
        climateProvider: (any ArkFileWeatherClimateOutlookProviding)?,
        location: ArkFileWeatherSavedLocation,
        previous: ArkFileWeatherSnapshot?,
        now: Date
    ) async -> ArkFileWeatherRefreshOutcome {
        let assembly = await assembleRefresh(
            coreProvider: coreProvider,
            climateProvider: climateProvider,
            location: location,
            previous: previous,
            now: now
        )
        guard !Task.isCancelled else { return .cancelled }
        if let timeZoneIdentifier = assembly.resolvedLocation.timeZoneIdentifier,
           timeZoneIdentifier != location.timeZoneIdentifier {
            do {
                let updated = try await store.updateLocationTimeZone(
                    timeZoneIdentifier,
                    ifCurrentLocationRevision: location.revision,
                    modifiedAt: now
                )
                guard !Task.isCancelled else { return .cancelled }
                guard updated else { return .discardedLocationChanged }
            } catch {
                return .failed(.storageWrite)
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        do {
            let committed = try await store.saveSnapshot(
                assembly.snapshot,
                ifCurrentLocationRevision: location.revision
            )
            guard !Task.isCancelled else { return .cancelled }
            guard committed else { return .discardedLocationChanged }
        } catch {
            return .failed(.storageWrite)
        }
        if assembly.coreAllFailed {
            return .failed(.providerUnavailable)
        }
        return .refreshed(assembly.snapshot)
    }

    static func assembleRefresh(
        coreProvider: any ArkFileWeatherCoreProviding,
        climateProvider: (any ArkFileWeatherClimateOutlookProviding)?,
        location: ArkFileWeatherSavedLocation,
        previous: ArkFileWeatherSnapshot?,
        now: Date
    ) async -> RefreshAssembly {
        let base = previous ?? emptySnapshot(
            revision: location.revision,
            at: now
        )
        async let coreResult = coreProvider.refresh(
            location: location,
            previous: previous,
            now: now
        )
        async let climateResult = refreshClimate(
            provider: climateProvider,
            coordinate: location.coordinate,
            prior: base.climateOutlooks,
            now: now
        )
        let (core, climate) = await (coreResult, climateResult)

        let resolvedLocation = locationWithResolvedTimeZone(
            location,
            metadata: core.resolvedMetadata
        )
        let astronomy = astronomyComponent(
            location: resolvedLocation,
            previous: base.astronomy,
            core: core,
            now: now
        )
        let radio = radioAssembly(
            metadata: core.resolvedMetadata,
            previous: base.radioTransmitters,
            previousAreas: base.radioAreas,
            core: core,
            now: now
        )
        let snapshot = ArkFileWeatherSnapshot(
            locationRevision: location.revision,
            assembledAt: now,
            resolvedPlaceName:
                core.resolvedMetadata?.placeName ?? base.resolvedPlaceName,
            hourly: core.hourly,
            daily: core.daily,
            alerts: core.alerts,
            climateOutlooks: climate,
            astronomy: astronomy,
            radioTransmitters: radio.transmitters,
            airQuality: base.airQuality,
            smoke: base.smoke,
            riverConditions: base.riverConditions,
            drought: base.drought,
            radioAreas: radio.areas
        )
        return RefreshAssembly(
            resolvedLocation: resolvedLocation,
            snapshot: snapshot,
            coreAllFailed:
                core.hourly.availability == .failed
                    && core.daily.availability == .failed
                    && core.alerts.availability == .failed
        )
    }

    static func refreshClimate(
        provider: (any ArkFileWeatherClimateOutlookProviding)?,
        coordinate: ArkFileWeatherCoordinate,
        prior: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]> {
        guard let provider else { return prior }
        if let retryAfter = prior.failure?.retryAfter,
           now < retryAfter {
            return prior
        }
        if let stamp = prior.stamp,
           now < stamp.freshUntil {
            return prior
        }
        if let failureAt = prior.failure?.occurredAt,
           now < failureAt.addingTimeInterval(60 * 60) {
            return prior
        }
        return await provider.refresh(
            coordinate: coordinate,
            prior: prior,
            at: now
        )
    }

    static func emptySnapshot(
        revision: Int,
        at now: Date
    ) -> ArkFileWeatherSnapshot {
        ArkFileWeatherSnapshot(
            locationRevision: revision,
            assembledAt: now,
            resolvedPlaceName: nil,
            hourly: .unavailable(.sourceUnavailable),
            daily: .unavailable(.sourceUnavailable),
            alerts: .unavailable(.sourceUnavailable),
            climateOutlooks: .unavailable(.sourceUnavailable),
            astronomy: .unavailable(.notConfigured),
            radioTransmitters: .unavailable(.sourceUnavailable),
            airQuality: .unsupported(.notConfigured),
            smoke: .unsupported(.notConfigured),
            riverConditions: .unsupported(.notConfigured),
            drought: .unsupported(.notConfigured)
        )
    }

    static func locationWithResolvedTimeZone(
        _ location: ArkFileWeatherSavedLocation,
        metadata: ArkFileNWSResolvedMetadata?
    ) -> ArkFileWeatherSavedLocation {
        guard let identifier = metadata?.timeZoneIdentifier,
              TimeZone(identifier: identifier) != nil else {
            return location
        }
        return ArkFileWeatherSavedLocation(
            id: location.id,
            revision: location.revision,
            coordinate: location.coordinate,
            displayName: location.displayName,
            timeZoneIdentifier: identifier,
            source: location.source,
            selectedAt: location.selectedAt,
            measuredAt: location.measuredAt,
            horizontalAccuracyMeters: location.horizontalAccuracyMeters
        )
    }

    static func astronomyComponent(
        location: ArkFileWeatherSavedLocation,
        previous: ArkFileWeatherComponent<[ArkFileWeatherAstronomyDay]>,
        core: ArkFileNWSRefreshResult,
        now: Date
    ) -> ArkFileWeatherComponent<[ArkFileWeatherAstronomyDay]> {
        guard location.timeZoneIdentifier != nil else {
            return componentAfterDependentFailure(
                previous,
                core: core,
                now: now,
                unavailableReason: .notConfigured
            )
        }
        do {
            let days = try ArkFileWeatherAstronomyCalculator.days(
                startingAt: now,
                count: 30,
                for: location
            )
            guard let first = days.first, let last = days.last else {
                return .successfulEmpty(
                    stamp: derivedStamp(
                        sourceID: "arkfile-offline-astronomy",
                        issuedAt: now,
                        validFrom: now,
                        validUntil: now,
                        now: now
                    )
                )
            }
            let stamp = derivedStamp(
                sourceID: "arkfile-offline-astronomy",
                issuedAt: now,
                validFrom: first.localDayStart,
                validUntil: last.localDayStart.addingTimeInterval(36 * 60 * 60),
                now: now
            )
            return .available(days, stamp: stamp)
        } catch {
            return previous.recordingFailure(
                ArkFileWeatherComponentFailure(
                    kind: .invalidResponse,
                    occurredAt: now,
                    retryAfter: nil,
                    providerCode: "astronomy"
                )
            )
        }
    }

    struct RadioAssembly {
        let transmitters:
            ArkFileWeatherComponent<[ArkFileWeatherRadioTransmitter]>
        let areas: [ArkFileWeatherRadioAreaIdentity]?
    }

    static func radioAssembly(
        metadata: ArkFileNWSResolvedMetadata?,
        previous: ArkFileWeatherComponent<[ArkFileWeatherRadioTransmitter]>,
        previousAreas: [ArkFileWeatherRadioAreaIdentity]?,
        core: ArkFileNWSRefreshResult,
        now: Date
    ) -> RadioAssembly {
        guard let metadata else {
            return RadioAssembly(
                transmitters: componentAfterDependentFailure(
                    previous,
                    core: core,
                    now: now,
                    unavailableReason: .sourceUnavailable
                ),
                areas: previousAreas
            )
        }
        let resolution = ArkFileWeatherRadioResolver.resolveBundled(
            sameCode: metadata.radio?.sameCode,
            countyZoneID: metadata.countyZoneID
        )
        switch resolution {
        case let .designated(area, transmitters, generatedAt):
            let stamp = radioCatalogStamp(generatedAt: generatedAt)
            return RadioAssembly(
                transmitters: transmitters.isEmpty
                    ? .successfulEmpty(stamp: stamp)
                    : .available(transmitters, stamp: stamp),
                areas: [area]
            )
        case let .noCoverage(area, generatedAt):
            return RadioAssembly(
                transmitters: .successfulEmpty(
                    stamp: radioCatalogStamp(generatedAt: generatedAt)
                ),
                areas: [area]
            )
        case let .ambiguous(candidates, _):
            return RadioAssembly(
                transmitters: .unavailable(.noMatchingStation),
                areas: candidates
            )
        case let .unavailable(reason):
            switch reason {
            case .lookupMetadataMissing, .noMatchingArea:
                return RadioAssembly(
                    transmitters: .unavailable(.noMatchingStation),
                    areas: previousAreas
                )
            case .catalogMissing, .catalogInvalid:
                return RadioAssembly(
                    transmitters: previous.recordingFailure(
                        ArkFileWeatherComponentFailure(
                            kind: .integrity,
                            occurredAt: now,
                            retryAfter: nil,
                            providerCode: "nwr_catalog"
                        )
                    ),
                    areas: previousAreas
                )
            }
        }
    }

    static func componentAfterDependentFailure<Value>(
        _ previous: ArkFileWeatherComponent<Value>,
        core: ArkFileNWSRefreshResult,
        now: Date,
        unavailableReason: ArkFileWeatherUnavailableReason
    ) -> ArkFileWeatherComponent<Value>
    where Value: Codable & Equatable & Sendable {
        if let failure = core.daily.failure ?? core.hourly.failure {
            return previous.recordingFailure(failure)
        }
        return .unavailable(unavailableReason)
    }

    static func derivedStamp(
        sourceID: String,
        issuedAt: Date?,
        validFrom: Date?,
        validUntil: Date?,
        now: Date
    ) -> ArkFileWeatherComponentStamp {
        ArkFileWeatherComponentStamp(
            sourceID: sourceID,
            issuedAt: issuedAt,
            fetchedAt: now,
            validFrom: validFrom,
            validUntil: validUntil,
            freshUntil: now.addingTimeInterval(24 * 60 * 60),
            agingUntil: now.addingTimeInterval(3 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(35 * 24 * 60 * 60),
            historicalAt: now.addingTimeInterval(90 * 24 * 60 * 60),
            entityTag: nil,
            lastModified: nil
        )
    }

    /// NOAA Weather Radio status is bundled reference data, not a live lookup
    /// performed during a forecast refresh. Use the catalog generation time as
    /// the check time so UI cannot accidentally present an old station status
    /// as if it were verified when weather was just updated.
    static func radioCatalogStamp(
        generatedAt: Date
    ) -> ArkFileWeatherComponentStamp {
        ArkFileWeatherComponentStamp(
            sourceID: "noaa-nwr-catalog",
            issuedAt: generatedAt,
            fetchedAt: generatedAt,
            validFrom: generatedAt,
            validUntil: nil,
            freshUntil: generatedAt.addingTimeInterval(30 * 24 * 60 * 60),
            agingUntil: generatedAt.addingTimeInterval(60 * 24 * 60 * 60),
            expiresAt: generatedAt.addingTimeInterval(365 * 24 * 60 * 60),
            historicalAt: generatedAt.addingTimeInterval(5 * 365 * 24 * 60 * 60),
            entityTag: nil,
            lastModified: nil
        )
    }

    static func onlyMissingFiles(
        _ current: ArkFileWeatherStoreError?,
        _ previous: ArkFileWeatherStoreError?
    ) -> Bool {
        (current == nil || current == .notFound)
            && (previous == nil || previous == .notFound)
    }

    static func normalizedDisplayName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return nil }
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        return trimmed.unicodeScalars.contains(where: forbidden.contains)
            ? nil
            : trimmed
    }

    static func validTimeZoneIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return identifier.count <= 128 && TimeZone(identifier: identifier) != nil
    }

    /// NWS requests use four decimal places (roughly 11 m latitude). Persist
    /// only that same forecast resolution instead of retaining unused GPS
    /// precision. Points near a forecast-zone boundary may be adjusted by the
    /// user with the map or coordinate entry if a different side is intended.
    static func providerResolutionCoordinate(
        _ coordinate: ArkFileWeatherCoordinate
    ) -> ArkFileWeatherCoordinate {
        func rounded(_ value: Double) -> Double {
            let result = (value * 10_000).rounded() / 10_000
            return result == 0 ? 0 : result
        }
        return ArkFileWeatherCoordinate(
            latitude: rounded(coordinate.latitude),
            longitude: rounded(coordinate.longitude)
        )
    }
}
