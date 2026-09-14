// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
#if os(iOS)
import CoreLocation
#endif

struct ArkFileWeatherLocationMeasurement: Equatable, Sendable {
    let coordinate: ArkFileWeatherCoordinate
    let measuredAt: Date
    let horizontalAccuracyMeters: Double
    let isApproximate: Bool
}

enum ArkFileWeatherLocationRequestMode: Equatable, Sendable {
    /// May present the system authorization prompt because the user explicitly
    /// asked ArkFile to use the current location.
    case userInitiated
    /// Must never present a system prompt. Used only to keep an already
    /// authorized follow-current-location briefing aligned in the foreground.
    case automaticSilent
}

enum ArkFileWeatherLocationError: Error, Equatable, Sendable {
    case requestAlreadyInProgress
    case authorizationRequired
    case permissionDenied
    case servicesDisabled
    case unavailable
    case cancelled
}

@MainActor
protocol ArkFileWeatherLocationProviding: AnyObject {
    func requestLocation(
        mode: ArkFileWeatherLocationRequestMode
    ) async throws -> ArkFileWeatherLocationMeasurement
    func cancel()
}

#if os(iOS)
/// A one-shot, foreground-only location adapter. Saved Weather never starts
/// continuous updates and background refresh never calls this service.
@MainActor
final class ArkFileWeatherLocationService:
    NSObject,
    ArkFileWeatherLocationProviding,
    @preconcurrency CLLocationManagerDelegate
{
    static let userInitiatedRequestTimeout: TimeInterval = 20
    static let automaticRequestTimeout: TimeInterval = 10

    private let manager: CLLocationManager
    private var continuation:
        CheckedContinuation<ArkFileWeatherLocationMeasurement, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var requestMode: ArkFileWeatherLocationRequestMode?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation(
        mode: ArkFileWeatherLocationRequestMode
    ) async throws -> ArkFileWeatherLocationMeasurement {
        guard continuation == nil else {
            throw ArkFileWeatherLocationError.requestAlreadyInProgress
        }
        if !CLLocationManager.locationServicesEnabled() {
            throw ArkFileWeatherLocationError.servicesDisabled
        }
        if mode == .automaticSilent,
           manager.authorizationStatus == .notDetermined {
            throw ArkFileWeatherLocationError.authorizationRequired
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                requestMode = mode
                let timeout = mode == .userInitiated
                    ? Self.userInitiatedRequestTimeout
                    : Self.automaticRequestTimeout
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(
                            timeout * 1_000_000_000
                        )
                    )
                    guard !Task.isCancelled,
                          self?.continuation != nil else {
                        return
                    }
                    self?.finish(
                        throwing: ArkFileWeatherLocationError.unavailable
                    )
                }
                beginRequestForCurrentAuthorization()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        manager.stopUpdatingLocation()
        finish(throwing: ArkFileWeatherLocationError.cancelled)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        beginRequestForCurrentAuthorization()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard continuation != nil else { return }
        let recentCutoff = Date().addingTimeInterval(-5 * 60)
        guard let location = locations
            .filter({
                $0.horizontalAccuracy >= 0
                    && $0.timestamp >= recentCutoff
                    && (-90 ... 90).contains($0.coordinate.latitude)
                    && (-180 ... 180).contains($0.coordinate.longitude)
            })
            .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
            finish(throwing: ArkFileWeatherLocationError.unavailable)
            return
        }
        finish(
            returning: ArkFileWeatherLocationMeasurement(
                coordinate: ArkFileWeatherCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                ),
                measuredAt: location.timestamp,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                isApproximate: manager.accuracyAuthorization == .reducedAccuracy
            )
        )
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        if let coreLocationError = error as? CLError,
           coreLocationError.code == .denied {
            finish(throwing: ArkFileWeatherLocationError.permissionDenied)
        } else {
            finish(throwing: ArkFileWeatherLocationError.unavailable)
        }
    }

    private func beginRequestForCurrentAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            if requestMode == .userInitiated {
                manager.requestWhenInUseAuthorization()
            } else {
                finish(
                    throwing: ArkFileWeatherLocationError.authorizationRequired
                )
            }
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(throwing: ArkFileWeatherLocationError.permissionDenied)
        @unknown default:
            finish(throwing: ArkFileWeatherLocationError.unavailable)
        }
    }

    private func finish(returning measurement: ArkFileWeatherLocationMeasurement) {
        let pending = continuation
        continuation = nil
        requestMode = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        pending?.resume(returning: measurement)
    }

    private func finish(throwing error: Error) {
        let pending = continuation
        continuation = nil
        requestMode = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        pending?.resume(throwing: error)
    }
}
#endif
