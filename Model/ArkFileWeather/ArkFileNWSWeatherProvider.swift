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

struct ArkFileNWSPointAstronomicalData: Equatable, Sendable {
    let sunrise: Date?
    let sunset: Date?
    let civilTwilightBegin: Date?
    let civilTwilightEnd: Date?
}

struct ArkFileNWSPointRadioMetadata: Equatable, Sendable {
    let transmitterCallSign: String?
    let sameCode: String?
    let hasAreaBroadcast: Bool
    let hasPointBroadcast: Bool
}

/// Non-coordinate metadata resolved by the NWS `/points` endpoint.
///
/// Returned endpoint URLs are intentionally not exposed or persisted. The
/// provider validates and follows them internally, while diagnostics and
/// durable settings retain only bounded identifiers.
struct ArkFileNWSResolvedMetadata: Equatable, Sendable {
    let forecastOfficeID: String?
    let gridID: String
    let gridX: Int
    let gridY: Int
    let forecastZoneID: String?
    let countyZoneID: String?
    let fireWeatherZoneID: String?
    let timeZoneIdentifier: String?
    let placeName: String?
    let radarStationID: String?
    let astronomicalData: ArkFileNWSPointAstronomicalData?
    let radio: ArkFileNWSPointRadioMetadata?
}

/// Each component is already merged with its matching last-known-good value.
/// A coordinator only needs to revision-check the location before persisting.
struct ArkFileNWSRefreshResult: Equatable, Sendable {
    let hourly: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>
    let daily: ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]>
    let alerts: ArkFileWeatherComponent<[ArkFileWeatherAlert]>
    let resolvedMetadata: ArkFileNWSResolvedMetadata?
}

/// A bounded, U.S.-first provider for public National Weather Service data.
///
/// Forecast resolution and active-alert retrieval run independently. A points
/// or forecast failure therefore cannot turn a failed alert check into an
/// authoritative empty result, and an alert outage cannot erase a valid
/// forecast.
actor ArkFileNWSWeatherProvider {
    static let providerHost = "api.weather.gov"
    static let defaultUserAgent =
        "ArkFile Saved Weather/1.0 (+https://thearkfile.com/support)"

    private static let pointBodyLimit = 256_000
    private static let dailyBodyLimit = 768_000
    private static let hourlyBodyLimit = 2_000_000
    private static let alertsBodyLimit = 2_000_000
    private static let maximumHourlyPeriods = 192
    private static let maximumDailySourcePeriods = 32
    private static let maximumAlerts = 128

    private let transport: any ArkFileWeatherTransport
    private let userAgent: String
    private let acceptLanguage: String

    init(
        transport: any ArkFileWeatherTransport,
        userAgent: String = ArkFileNWSWeatherProvider.defaultUserAgent,
        acceptLanguage: String = "en-US"
    ) {
        self.transport = transport
        self.userAgent = Self.safeHeaderValue(
            userAgent,
            fallback: Self.defaultUserAgent,
            maximumLength: 256
        )
        self.acceptLanguage = Self.safeHeaderValue(
            acceptLanguage,
            fallback: "en-US",
            maximumLength: 64
        )
    }

    func refresh(
        location: ArkFileWeatherSavedLocation,
        previous: ArkFileWeatherSnapshot?,
        now: Date = Date()
    ) async -> ArkFileNWSRefreshResult {
        let matchingPrevious = previous?.locationRevision == location.revision
            ? previous
            : nil
        let previousHourly = matchingPrevious?.hourly
        let previousDaily = matchingPrevious?.daily
        let previousAlerts = matchingPrevious?.alerts

        guard location.coordinate.isValid,
              now.timeIntervalSince1970.isFinite else {
            let failure = FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "invalid_location"
            )
            return ArkFileNWSRefreshResult(
                hourly: Self.failedComponent(
                    previousHourly,
                    descriptor: failure,
                    at: now
                ),
                daily: Self.failedComponent(
                    previousDaily,
                    descriptor: failure,
                    at: now
                ),
                alerts: Self.failedComponent(
                    previousAlerts,
                    descriptor: failure,
                    at: now
                ),
                resolvedMetadata: nil
            )
        }

        let coordinate = Self.coordinateString(location.coordinate)
        let transport = transport
        let userAgent = userAgent
        let acceptLanguage = acceptLanguage

        async let refreshedAlerts = Self.fetchAlertsRespectingBackoff(
            coordinate: coordinate,
            previous: previousAlerts,
            transport: transport,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage,
            now: now
        )

        if Self.isBackedOff(previousHourly, at: now),
           Self.isBackedOff(previousDaily, at: now),
           let previousHourly,
           let previousDaily {
            return await ArkFileNWSRefreshResult(
                hourly: previousHourly,
                daily: previousDaily,
                alerts: refreshedAlerts,
                resolvedMetadata: nil
            )
        }

        let pointOutcome = await Self.resolvePoint(
            coordinate: coordinate,
            transport: transport,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage,
            now: now
        )

        switch pointOutcome {
        case let .success(point):
            async let refreshedHourly = Self.fetchHourlyRespectingBackoff(
                point: point,
                previous: previousHourly,
                transport: transport,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage,
                now: now
            )
            async let refreshedDaily = Self.fetchDailyRespectingBackoff(
                point: point,
                previous: previousDaily,
                transport: transport,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage,
                now: now
            )
            return await ArkFileNWSRefreshResult(
                hourly: refreshedHourly,
                daily: refreshedDaily,
                alerts: refreshedAlerts,
                resolvedMetadata: point.metadata
            )

        case let .failure(descriptor):
            let alertResult = await refreshedAlerts
            let boundedAlerts: ArkFileWeatherComponent<[ArkFileWeatherAlert]>
            if descriptor.providerCode == "not_supported" {
                switch alertResult.availability {
                case .available where !(alertResult.value ?? []).isEmpty,
                     .failed:
                    // Point metadata and point-alert coverage are independent
                    // NWS surfaces. Preserve a real alert result (or a failed
                    // check retaining last-known alerts) even when /points
                    // cannot resolve forecast grid metadata.
                    boundedAlerts = alertResult
                case .available, .successfulEmpty, .unavailable, .unsupported:
                    // An empty point-alert response cannot prove that an
                    // unsupported forecast point has authoritative coverage.
                    boundedAlerts = .unsupported(.notSupportedForLocation)
                }
            } else {
                boundedAlerts = alertResult
            }
            return ArkFileNWSRefreshResult(
                hourly: Self.failedComponent(
                    previousHourly,
                    descriptor: descriptor,
                    at: now
                ),
                daily: Self.failedComponent(
                    previousDaily,
                    descriptor: descriptor,
                    at: now
                ),
                alerts: boundedAlerts,
                resolvedMetadata: nil
            )
        }
    }
}

// MARK: - Request flow

private extension ArkFileNWSWeatherProvider {
    enum PointOutcome: Sendable {
        case success(ResolvedPoint)
        case failure(FailureDescriptor)
    }

    struct ResolvedPoint: Sendable {
        let dailyURL: URL
        let hourlyURL: URL
        let metadata: ArkFileNWSResolvedMetadata
    }

    struct FailureDescriptor: Error, Equatable, Sendable {
        let kind: ArkFileWeatherFailureKind
        let retryAfter: Date?
        let providerCode: String
    }

    static func isBackedOff<Value>(
        _ previous: ArkFileWeatherComponent<Value>?,
        at now: Date
    ) -> Bool where Value: Codable & Equatable & Sendable {
        guard let retryAfter = previous?.failure?.retryAfter else {
            return false
        }
        return now < retryAfter
    }

    static func fetchHourlyRespectingBackoff(
        point: ResolvedPoint,
        previous: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]> {
        if let previous, isBackedOff(previous, at: now) {
            return previous
        }
        return await fetchHourly(
            point: point,
            previous: previous,
            transport: transport,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage,
            now: now
        )
    }

    static func fetchDailyRespectingBackoff(
        point: ResolvedPoint,
        previous: ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]> {
        if let previous, isBackedOff(previous, at: now) {
            return previous
        }
        return await fetchDaily(
            point: point,
            previous: previous,
            transport: transport,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage,
            now: now
        )
    }

    static func fetchAlertsRespectingBackoff(
        coordinate: String,
        previous: ArkFileWeatherComponent<[ArkFileWeatherAlert]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherAlert]> {
        if let previous, isBackedOff(previous, at: now) {
            return previous
        }
        return await fetchAlerts(
            coordinate: coordinate,
            previous: previous,
            transport: transport,
            userAgent: userAgent,
            acceptLanguage: acceptLanguage,
            now: now
        )
    }

    static func resolvePoint(
        coordinate: String,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> PointOutcome {
        guard let url = URL(
            string: "https://\(providerHost)/points/\(coordinate)"
        ) else {
            return .failure(
                FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "endpoint"
                )
            )
        }

        do {
            let request = makeRequest(
                url: url,
                validators: nil,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage
            )
            let response = try await response(
                for: request,
                maximumBodyBytes: pointBodyLimit,
                transport: transport,
                now: now
            )
            guard response.statusCode == 200 else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "not_modified_without_cache"
                )
            }

            let envelope: PointEnvelope = try decode(
                PointEnvelope.self,
                from: response.body
            )
            let properties = envelope.properties
            guard let gridID = boundedIdentifier(
                properties.gridID,
                maximumLength: 16
            ),
                let gridX = properties.gridX,
                let gridY = properties.gridY,
                (0 ... 1_000_000).contains(gridX),
                (0 ... 1_000_000).contains(gridY),
                let dailyURL = validatedForecastURL(
                    properties.forecast,
                    expectedGridID: gridID,
                    expectedGridX: gridX,
                    expectedGridY: gridY,
                    hourly: false
                ),
                let hourlyURL = validatedForecastURL(
                    properties.forecastHourly,
                    expectedGridID: gridID,
                    expectedGridX: gridX,
                    expectedGridY: gridY,
                    hourly: true
                ) else {
                throw FailureDescriptor(
                    kind: .integrity,
                    retryAfter: nil,
                    providerCode: "endpoint"
                )
            }

            let metadata = ArkFileNWSResolvedMetadata(
                forecastOfficeID: boundedIdentifier(
                    properties.forecastOfficeID,
                    maximumLength: 16
                ),
                gridID: gridID,
                gridX: gridX,
                gridY: gridY,
                forecastZoneID: terminalZoneID(properties.forecastZone),
                countyZoneID: terminalZoneID(properties.county),
                fireWeatherZoneID: terminalZoneID(properties.fireWeatherZone),
                timeZoneIdentifier: validTimeZoneIdentifier(properties.timeZone),
                placeName: placeName(properties.relativeLocation),
                radarStationID: boundedIdentifier(
                    properties.radarStation,
                    maximumLength: 32
                ),
                astronomicalData: astronomicalMetadata(
                    properties.astronomicalData
                ),
                radio: radioMetadata(properties.nwr)
            )
            return .success(
                ResolvedPoint(
                    dailyURL: dailyURL,
                    hourlyURL: hourlyURL,
                    metadata: metadata
                )
            )
        } catch {
            return .failure(normalizedFailure(error, now: now))
        }
    }

    static func fetchHourly(
        point: ResolvedPoint,
        previous: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]> {
        do {
            let requestValidators = previous?.stamp.map {
                ArkFileWeatherHTTPValidators(
                    entityTag: $0.entityTag,
                    lastModified: $0.lastModified
                )
            }
            let request = makeRequest(
                url: point.hourlyURL,
                validators: requestValidators,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage
            )
            let response = try await response(
                for: request,
                maximumBodyBytes: hourlyBodyLimit,
                transport: transport,
                now: now
            )
            if response.statusCode == 304 {
                return try revalidatedComponent(
                    previous,
                    response: response,
                    requestValidators: requestValidators,
                    sourceID: "nws-hourly",
                    freshness: .hourly,
                    now: now
                )
            }

            let envelope: ForecastEnvelope = try decode(
                ForecastEnvelope.self,
                from: response.body
            )
            guard envelope.properties.periods.count <= maximumHourlyPeriods,
                  !envelope.properties.periods.isEmpty else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let periods = try envelope.properties.periods.enumerated().map {
                try normalizeHourly(
                    $0.element,
                    fallbackNumber: $0.offset + 1,
                    now: now
                )
            }.sorted { $0.startsAt < $1.startsAt }

            let stamp = forecastStamp(
                sourceID: "nws-hourly",
                properties: envelope.properties,
                response: response,
                periodsStart: periods.first?.startsAt,
                periodsEnd: periods.last?.endsAt,
                freshness: .hourly,
                now: now
            )
            return .available(periods, stamp: stamp)
        } catch {
            return failedComponent(
                previous,
                descriptor: normalizedFailure(error, now: now),
                at: now
            )
        }
    }

    static func fetchDaily(
        point: ResolvedPoint,
        previous: ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]> {
        do {
            let requestValidators = previous?.stamp.map {
                ArkFileWeatherHTTPValidators(
                    entityTag: $0.entityTag,
                    lastModified: $0.lastModified
                )
            }
            let request = makeRequest(
                url: point.dailyURL,
                validators: requestValidators,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage
            )
            let response = try await response(
                for: request,
                maximumBodyBytes: dailyBodyLimit,
                transport: transport,
                now: now
            )
            if response.statusCode == 304 {
                return try revalidatedComponent(
                    previous,
                    response: response,
                    requestValidators: requestValidators,
                    sourceID: "nws-daily",
                    freshness: .daily,
                    now: now
                )
            }

            let envelope: ForecastEnvelope = try decode(
                ForecastEnvelope.self,
                from: response.body
            )
            guard envelope.properties.periods.count
                    <= maximumDailySourcePeriods,
                  !envelope.properties.periods.isEmpty else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let sourcePeriods = try envelope.properties.periods
                .enumerated()
                .map {
                    try normalizeDailySource(
                        $0.element,
                        fallbackNumber: $0.offset + 1,
                        now: now
                    )
                }
                .sorted { $0.startsAt < $1.startsAt }
            let periods = try groupDaily(
                sourcePeriods,
                timeZoneIdentifier: point.metadata.timeZoneIdentifier
            )
            guard !periods.isEmpty else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }

            let stamp = forecastStamp(
                sourceID: "nws-daily",
                properties: envelope.properties,
                response: response,
                periodsStart: periods.first?.startsAt,
                periodsEnd: periods.last?.endsAt,
                freshness: .daily,
                now: now
            )
            return .available(periods, stamp: stamp)
        } catch {
            return failedComponent(
                previous,
                descriptor: normalizedFailure(error, now: now),
                at: now
            )
        }
    }

    static func fetchAlerts(
        coordinate: String,
        previous: ArkFileWeatherComponent<[ArkFileWeatherAlert]>?,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        acceptLanguage: String,
        now: Date
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherAlert]> {
        guard let url = URL(
            string: "https://\(providerHost)/alerts/active?point=\(coordinate)"
        ) else {
            return failedComponent(
                previous,
                descriptor: FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "endpoint"
                ),
                at: now
            )
        }

        do {
            let requestValidators = previous?.stamp.map {
                ArkFileWeatherHTTPValidators(
                    entityTag: $0.entityTag,
                    lastModified: $0.lastModified
                )
            }
            let request = makeRequest(
                url: url,
                validators: requestValidators,
                userAgent: userAgent,
                acceptLanguage: acceptLanguage
            )
            let response = try await response(
                for: request,
                maximumBodyBytes: alertsBodyLimit,
                transport: transport,
                now: now
            )
            if response.statusCode == 304 {
                return try revalidatedComponent(
                    previous,
                    response: response,
                    requestValidators: requestValidators,
                    sourceID: "nws-alerts",
                    freshness: .alerts,
                    now: now
                )
            }

            let envelope: AlertEnvelope = try decode(
                AlertEnvelope.self,
                from: response.body
            )
            guard (envelope.features != nil) != (envelope.graph != nil) else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let sourceAlerts = envelope.features?.map(\.properties)
                ?? envelope.graph
                ?? []
            guard sourceAlerts.count <= maximumAlerts else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let alerts = try normalizeAlerts(sourceAlerts, now: now)
            let validFrom = alerts.map {
                $0.effectiveAt ?? $0.sentAt
            }.min()
            let validUntil = alerts.map {
                min($0.endsAt ?? $0.expiresAt, $0.expiresAt)
            }.max()
            let collectionUpdatedAt = parseDate(envelope.updated)
            if alerts.isEmpty, collectionUpdatedAt == nil {
                // A successful-empty result can clear retained alerts, so it
                // needs the collection's bounded authoritative update time.
                // Retrieval time alone cannot make a truncated empty envelope
                // an authoritative all-clear.
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let issuedAt = collectionUpdatedAt
                ?? alerts.map(\.sentAt).max()
            let stamp = componentStamp(
                sourceID: "nws-alerts",
                issuedAt: issuedAt,
                validFrom: validFrom,
                validUntil: validUntil,
                response: response,
                freshness: .alerts,
                now: now
            )

            if alerts.isEmpty {
                return .successfulEmpty(stamp: stamp)
            }
            return .available(alerts, stamp: stamp)
        } catch {
            return failedComponent(
                previous,
                descriptor: normalizedFailure(error, now: now),
                at: now
            )
        }
    }
}

// MARK: - HTTP policy

private extension ArkFileNWSWeatherProvider {
    enum FreshnessKind {
        case hourly
        case daily
        case alerts
    }

    static func makeRequest(
        url: URL,
        validators: ArkFileWeatherHTTPValidators?,
        userAgent: String,
        acceptLanguage: String
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/geo+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            acceptLanguage,
            forHTTPHeaderField: "Accept-Language"
        )
        validators?.apply(to: &request)
        return request
    }

    static func response(
        for request: URLRequest,
        maximumBodyBytes: Int,
        transport: any ArkFileWeatherTransport,
        now: Date
    ) async throws -> ArkFileWeatherHTTPResponse {
        if Task.isCancelled {
            throw FailureDescriptor(
                kind: .cancelled,
                retryAfter: nil,
                providerCode: "cancelled"
            )
        }

        let response: ArkFileWeatherHTTPResponse
        do {
            response = try await transport.response(
                for: request,
                maximumBodyBytes: maximumBodyBytes
            )
        } catch {
            throw normalizedFailure(error, now: now)
        }

        guard isTrustedAPIURL(response.finalURL),
              response.finalURL == request.url else {
            throw FailureDescriptor(
                kind: .integrity,
                retryAfter: nil,
                providerCode: "redirect_policy"
            )
        }
        switch response.statusCode {
        case 200:
            guard isAcceptedJSONMIMEType(response.mimeType) else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "mime_type"
                )
            }
            return response
        case 304:
            return response
        case 408:
            throw FailureDescriptor(
                kind: .timedOut,
                retryAfter: nil,
                providerCode: "timeout"
            )
        case 429:
            throw FailureDescriptor(
                kind: .rateLimited,
                retryAfter: response.retryAfterDate(relativeTo: now)
                    ?? now.addingTimeInterval(15 * 60),
                providerCode: "rate_limited"
            )
        case 404 where request.url?.pathComponents.dropFirst().first == "points":
            // `/points/{lat},{lon}` is the NWS coverage boundary. Treat that
            // specific response as an unsupported saved point, not as a
            // generic outage. A 404 from an endpoint already returned by a
            // successful points lookup remains an invalid provider response.
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "not_supported"
            )
        case 500 ... 599:
            throw FailureDescriptor(
                kind: .server,
                retryAfter: response.retryAfterDate(relativeTo: now)
                    ?? now.addingTimeInterval(15 * 60),
                providerCode: "server"
            )
        default:
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "http_status"
            )
        }
    }

    static func isTrustedAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == providerHost
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
    }

    static func isAcceptedJSONMIMEType(_ mimeType: String?) -> Bool {
        guard let type = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return type == "application/geo+json"
            || type == "application/ld+json"
    }

    static func validatedForecastURL(
        _ rawValue: String?,
        expectedGridID: String,
        expectedGridX: Int,
        expectedGridY: Int,
        hourly: Bool
    ) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              isTrustedAPIURL(url),
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let expectedCount = hourly ? 5 : 4
        guard parts.count == expectedCount,
              parts[0] == "gridpoints",
              parts[1].caseInsensitiveCompare(expectedGridID) == .orderedSame,
              parts[2] == "\(expectedGridX),\(expectedGridY)",
              parts[3] == "forecast",
              (!hourly || parts[4] == "hourly") else {
            return nil
        }
        return url
    }

    static func normalizedFailure(
        _ error: Error,
        now: Date
    ) -> FailureDescriptor {
        if let descriptor = error as? FailureDescriptor {
            return descriptor
        }
        if error is CancellationError {
            return FailureDescriptor(
                kind: .cancelled,
                retryAfter: nil,
                providerCode: "cancelled"
            )
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return FailureDescriptor(
                    kind: .offline,
                    retryAfter: nil,
                    providerCode: "offline"
                )
            case .timedOut:
                return FailureDescriptor(
                    kind: .timedOut,
                    retryAfter: nil,
                    providerCode: "timeout"
                )
            case .cancelled:
                return FailureDescriptor(
                    kind: .cancelled,
                    retryAfter: nil,
                    providerCode: "cancelled"
                )
            default:
                return FailureDescriptor(
                    kind: .unknown,
                    retryAfter: nil,
                    providerCode: "transport"
                )
            }
        }
        if let transportError = error as? ArkFileWeatherTransportError {
            switch transportError {
            case .untrustedDestination:
                return FailureDescriptor(
                    kind: .integrity,
                    retryAfter: nil,
                    providerCode: "redirect_policy"
                )
            case .responseTooLarge:
                return FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "response_size"
                )
            case .invalidMaximumBodySize, .nonHTTPResponse:
                return FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "transport"
                )
            }
        }
        if error is DecodingError {
            return FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "decode"
            )
        }
        return FailureDescriptor(
            kind: .unknown,
            retryAfter: nil,
            providerCode: "unknown"
        )
    }
}

// MARK: - Stamps and last-good merge

private extension ArkFileNWSWeatherProvider {
    static func failedComponent<Value>(
        _ previous: ArkFileWeatherComponent<Value>?,
        descriptor: FailureDescriptor,
        at date: Date
    ) -> ArkFileWeatherComponent<Value>
    where Value: Codable & Equatable & Sendable {
        if previous == nil, descriptor.providerCode == "not_supported" {
            return .unsupported(.notSupportedForLocation)
        }
        let failure = ArkFileWeatherComponentFailure(
            kind: descriptor.kind,
            occurredAt: date,
            retryAfter: descriptor.retryAfter,
            providerCode: descriptor.providerCode
        )
        if let previous {
            return previous.recordingFailure(failure)
        }
        return ArkFileWeatherComponent(
            availability: .failed,
            value: nil,
            stamp: nil,
            failure: failure,
            unavailableReason: nil
        )
    }

    static func revalidatedComponent<Value>(
        _ previous: ArkFileWeatherComponent<Value>?,
        response: ArkFileWeatherHTTPResponse,
        requestValidators: ArkFileWeatherHTTPValidators?,
        sourceID: String,
        freshness: FreshnessKind,
        now: Date
    ) throws -> ArkFileWeatherComponent<Value>
    where Value: Codable & Equatable & Sendable {
        guard let requestValidators,
              !requestValidators.isEmpty,
              response.body.isEmpty else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "invalid_not_modified"
            )
        }
        guard let previous,
              let oldStamp = previous.stamp else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "not_modified_without_cache"
            )
        }
        if let validUntil = oldStamp.validUntil,
           validUntil <= now {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "not_modified_expired"
            )
        }
        let stamp = componentStamp(
            sourceID: sourceID,
            issuedAt: oldStamp.issuedAt,
            validFrom: oldStamp.validFrom,
            validUntil: oldStamp.validUntil,
            response: response,
            freshness: freshness,
            now: now,
            fallbackValidators: ArkFileWeatherHTTPValidators(
                entityTag: oldStamp.entityTag,
                lastModified: oldStamp.lastModified
            )
        )
        if let value = previous.value {
            return .available(value, stamp: stamp)
        }
        return .successfulEmpty(stamp: stamp)
    }

    static func forecastStamp(
        sourceID: String,
        properties: ForecastProperties,
        response: ArkFileWeatherHTTPResponse,
        periodsStart: Date?,
        periodsEnd: Date?,
        freshness: FreshnessKind,
        now: Date
    ) -> ArkFileWeatherComponentStamp {
        componentStamp(
            sourceID: sourceID,
            issuedAt: parseDate(properties.generatedAt)
                ?? parseDate(properties.updateTime),
            validFrom: periodsStart,
            validUntil: periodsEnd,
            response: response,
            freshness: freshness,
            now: now
        )
    }

    static func componentStamp(
        sourceID: String,
        issuedAt: Date?,
        validFrom: Date?,
        validUntil: Date?,
        response: ArkFileWeatherHTTPResponse,
        freshness: FreshnessKind,
        now: Date,
        fallbackValidators: ArkFileWeatherHTTPValidators? = nil
    ) -> ArkFileWeatherComponentStamp {
        let freshInterval: TimeInterval
        let agingInterval: TimeInterval
        let minimumExpiryInterval: TimeInterval
        let historyInterval: TimeInterval
        switch freshness {
        case .hourly:
            freshInterval = 3 * 60 * 60
            agingInterval = 6 * 60 * 60
            minimumExpiryInterval = 8 * 60 * 60
            historyInterval = 7 * 24 * 60 * 60
        case .daily:
            freshInterval = 6 * 60 * 60
            agingInterval = 12 * 60 * 60
            minimumExpiryInterval = 24 * 60 * 60
            historyInterval = 14 * 24 * 60 * 60
        case .alerts:
            freshInterval = 15 * 60
            agingInterval = 30 * 60
            minimumExpiryInterval = 60 * 60
            historyInterval = 24 * 60 * 60
        }

        // A 200 response does not make an old forecast cycle newly issued.
        // Bound freshness by both retrieval and provider issue time while
        // preserving the store invariant that a stamp cannot predate fetch.
        let sourceAnchor: Date
        switch freshness {
        case .alerts:
            // Alert issuance is provenance. Retrieval/revalidation is the
            // authoritative check time used for freshness.
            sourceAnchor = now
        case .hourly, .daily:
            sourceAnchor = min(issuedAt ?? now, now)
        }
        let freshUntil = max(
            now,
            min(
                now.addingTimeInterval(freshInterval),
                sourceAnchor.addingTimeInterval(freshInterval)
            )
        )
        let agingUntil = max(
            freshUntil,
            min(
                now.addingTimeInterval(agingInterval),
                sourceAnchor.addingTimeInterval(agingInterval)
            )
        )
        let expiresAt = max(
            agingUntil,
            now.addingTimeInterval(minimumExpiryInterval),
            validUntil ?? now
        )
        let responseValidators = response.validators
        return ArkFileWeatherComponentStamp(
            sourceID: sourceID,
            issuedAt: issuedAt,
            fetchedAt: now,
            validFrom: validFrom,
            validUntil: validUntil,
            freshUntil: freshUntil,
            agingUntil: agingUntil,
            expiresAt: expiresAt,
            historicalAt: expiresAt.addingTimeInterval(historyInterval),
            entityTag: responseValidators.entityTag
                ?? fallbackValidators?.entityTag,
            lastModified: responseValidators.lastModified
                ?? fallbackValidators?.lastModified
        )
    }
}

// MARK: - Forecast normalization

private extension ArkFileNWSWeatherProvider {
    struct DailySourcePeriod {
        let number: Int
        let startsAt: Date
        let endsAt: Date
        let isDaytime: Bool
        let condition: ArkFileWeatherConditionCode
        let summary: String
        let temperatureCelsius: Double?
        let precipitationProbabilityFraction: Double?
        let windSpeedMetersPerSecond: Double?
        let windGustMetersPerSecond: Double?
    }

    struct DailyAccumulator {
        var startsAt: Date
        var endsAt: Date
        var conditions: [ArkFileWeatherConditionCode]
        var summaries: [String]
        var minimumTemperatureCelsius: Double?
        var maximumTemperatureCelsius: Double?
        var precipitationProbabilityFraction: Double?
        var maximumWindSpeedMetersPerSecond: Double?
        var maximumWindGustMetersPerSecond: Double?
    }

    static func normalizeHourly(
        _ source: ForecastPeriod,
        fallbackNumber: Int,
        now: Date
    ) throws -> ArkFileWeatherHourlyPeriod {
        let (startsAt, endsAt) = try forecastDateRange(source, now: now)
        let summary = try forecastSummary(source)
        let temperature = try temperatureCelsius(
            source.temperature,
            legacyUnit: source.temperatureUnit
        )
        let humidity = try fraction(source.relativeHumidity)
        let windSpeed = try speedMetersPerSecond(source.windSpeed)
        return ArkFileWeatherHourlyPeriod(
            id: "nws-hourly-\(source.number ?? fallbackNumber)-\(Int(startsAt.timeIntervalSince1970))",
            startsAt: startsAt,
            endsAt: endsAt,
            condition: conditionCode(summary),
            summary: summary,
            temperatureCelsius: temperature,
            apparentTemperatureCelsius:
                ArkFileWeatherThermalIndex.apparentTemperatureCelsius(
                    temperatureCelsius: temperature,
                    relativeHumidityFraction: humidity,
                    windSpeedMetersPerSecond: windSpeed
                ),
            dewPointCelsius: try temperatureCelsius(
                source.dewpoint,
                legacyUnit: nil
            ),
            relativeHumidityFraction: humidity,
            precipitationProbabilityFraction: try fraction(
                source.probabilityOfPrecipitation
            ),
            precipitationMillimeters: nil,
            windSpeedMetersPerSecond: windSpeed,
            windGustMetersPerSecond: try speedMetersPerSecond(
                source.windGust
            ),
            windDirectionDegrees: windDirectionDegrees(source.windDirection),
            cloudCoverFraction: nil,
            visibilityMeters: nil,
            pressureHectopascals: nil
        )
    }

    static func normalizeDailySource(
        _ source: ForecastPeriod,
        fallbackNumber: Int,
        now: Date
    ) throws -> DailySourcePeriod {
        let (startsAt, endsAt) = try forecastDateRange(source, now: now)
        let summary = try forecastSummary(source)
        guard let isDaytime = source.isDaytime else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return DailySourcePeriod(
            number: source.number ?? fallbackNumber,
            startsAt: startsAt,
            endsAt: endsAt,
            isDaytime: isDaytime,
            condition: conditionCode(summary),
            summary: summary,
            temperatureCelsius: try temperatureCelsius(
                source.temperature,
                legacyUnit: source.temperatureUnit
            ),
            precipitationProbabilityFraction: try fraction(
                source.probabilityOfPrecipitation
            ),
            windSpeedMetersPerSecond: try speedMetersPerSecond(
                source.windSpeed
            ),
            windGustMetersPerSecond: try speedMetersPerSecond(
                source.windGust
            )
        )
    }

    static func forecastDateRange(
        _ source: ForecastPeriod,
        now: Date
    ) throws -> (Date, Date) {
        guard let startsAt = parseDate(source.startTime),
              let endsAt = parseDate(source.endTime),
              startsAt < endsAt,
              endsAt.timeIntervalSince(startsAt) <= 48 * 60 * 60,
              startsAt >= now.addingTimeInterval(-3 * 24 * 60 * 60),
              endsAt <= now.addingTimeInterval(16 * 24 * 60 * 60) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return (startsAt, endsAt)
    }

    static func forecastSummary(_ source: ForecastPeriod) throws -> String {
        if let short = try boundedPlainText(
            source.shortForecast,
            maximumLength: 1_024,
            allowEmpty: true
        ), !short.isEmpty {
            return compactWhitespace(short)
        }
        if let detailed = try boundedPlainText(
            source.detailedForecast,
            maximumLength: 1_024,
            allowEmpty: true
        ), !detailed.isEmpty {
            return compactWhitespace(detailed)
        }
        return "Forecast unavailable"
    }

    static func groupDaily(
        _ sourcePeriods: [DailySourcePeriod],
        timeZoneIdentifier: String?
    ) throws -> [ArkFileWeatherDailyPeriod] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: 0)!

        var order: [String] = []
        var groups: [String: DailyAccumulator] = [:]
        for period in sourcePeriods {
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: period.startsAt
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let key = String(
                format: "%04d-%02d-%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                year,
                month,
                day
            )
            if groups[key] == nil {
                order.append(key)
                groups[key] = DailyAccumulator(
                    startsAt: period.startsAt,
                    endsAt: period.endsAt,
                    conditions: [],
                    summaries: [],
                    minimumTemperatureCelsius: nil,
                    maximumTemperatureCelsius: nil,
                    precipitationProbabilityFraction: nil,
                    maximumWindSpeedMetersPerSecond: nil,
                    maximumWindGustMetersPerSecond: nil
                )
            }
            guard var group = groups[key] else { continue }
            group.startsAt = min(group.startsAt, period.startsAt)
            group.endsAt = max(group.endsAt, period.endsAt)
            if !group.conditions.contains(period.condition) {
                group.conditions.append(period.condition)
            }
            if !group.summaries.contains(period.summary) {
                group.summaries.append(period.summary)
            }
            if period.isDaytime {
                group.maximumTemperatureCelsius = maximum(
                    group.maximumTemperatureCelsius,
                    period.temperatureCelsius
                )
            } else {
                group.minimumTemperatureCelsius = minimum(
                    group.minimumTemperatureCelsius,
                    period.temperatureCelsius
                )
            }
            group.precipitationProbabilityFraction = maximum(
                group.precipitationProbabilityFraction,
                period.precipitationProbabilityFraction
            )
            group.maximumWindSpeedMetersPerSecond = maximum(
                group.maximumWindSpeedMetersPerSecond,
                period.windSpeedMetersPerSecond
            )
            group.maximumWindGustMetersPerSecond = maximum(
                group.maximumWindGustMetersPerSecond,
                period.windGustMetersPerSecond
            )
            groups[key] = group
        }

        return try order.compactMap {
            key -> ArkFileWeatherDailyPeriod? in
            guard let group = groups[key] else { return nil }
            let summary = group.summaries.joined(separator: " / ")
            guard summary.count <= 1_024 else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            var minimumTemperature = group.minimumTemperatureCelsius
            var maximumTemperature = group.maximumTemperatureCelsius
            if let minimumValue = minimumTemperature,
               let maximumValue = maximumTemperature,
               minimumValue > maximumValue {
                minimumTemperature = maximumValue
                maximumTemperature = minimumValue
            }
            return ArkFileWeatherDailyPeriod(
                id: "nws-daily-\(key)",
                startsAt: group.startsAt,
                endsAt: group.endsAt,
                condition: preferredCondition(group.conditions),
                summary: summary,
                minimumTemperatureCelsius: minimumTemperature,
                maximumTemperatureCelsius: maximumTemperature,
                precipitationProbabilityFraction:
                    group.precipitationProbabilityFraction,
                precipitationMillimeters: nil,
                maximumWindSpeedMetersPerSecond:
                    group.maximumWindSpeedMetersPerSecond,
                maximumWindGustMetersPerSecond:
                    group.maximumWindGustMetersPerSecond
            )
        }
    }

    static func temperatureCelsius(
        _ source: FlexibleValue?,
        legacyUnit: String?
    ) throws -> Double? {
        guard let source else { return nil }
        let value: Double?
        let unit: String?
        switch source {
        case let .number(number):
            value = number
            unit = legacyUnit
        case let .text(text):
            value = numericValues(text).first
            unit = legacyUnit ?? text
        case let .quantity(quantity):
            value = quantity.value ?? quantity.maxValue ?? quantity.minValue
            unit = quantity.unitCode ?? legacyUnit
        case .null:
            return nil
        }
        guard let value, value.isFinite else { return nil }
        guard let normalizedUnit = unit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedUnit.isEmpty else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        let celsius: Double
        if normalizedUnit == "f"
            || normalizedUnit.contains("degf")
            || normalizedUnit.contains("fahrenheit") {
            celsius = (value - 32) * 5 / 9
        } else if normalizedUnit == "c"
            || normalizedUnit.contains("degc")
            || normalizedUnit.contains("celsius") {
            celsius = value
        } else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        guard (-150 ... 100).contains(celsius) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return celsius
    }

    static func speedMetersPerSecond(
        _ source: FlexibleValue?
    ) throws -> Double? {
        guard let source else { return nil }
        let value: Double?
        let unit: String?
        switch source {
        case let .number(number):
            value = number
            unit = nil
        case let .text(text):
            value = numericValues(text).max()
            unit = text
        case let .quantity(quantity):
            value = [quantity.value, quantity.maxValue, quantity.minValue]
                .compactMap { $0 }
                .max()
            unit = quantity.unitCode
        case .null:
            return nil
        }
        guard let value, value.isFinite, value >= 0 else { return nil }
        guard let unit = unit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !unit.isEmpty else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        let metersPerSecond: Double
        if unit.contains("mph")
            || unit.contains("[mi_i]/h")
            || unit.contains("mi_h-1") {
            metersPerSecond = value * 0.44704
        } else if unit.contains("km/h")
            || unit.contains("km_h-1")
            || unit.contains("kmh") {
            metersPerSecond = value / 3.6
        } else if unit.contains("knot") || unit.contains("kt") {
            metersPerSecond = value * 0.514_444
        } else if unit.contains("m/s") || unit.contains("m_s-1") {
            metersPerSecond = value
        } else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        guard metersPerSecond <= 250 else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return metersPerSecond
    }

    static func fraction(_ source: FlexibleValue?) throws -> Double? {
        guard let source else { return nil }
        let value: Double?
        let unit: String?
        switch source {
        case let .number(number):
            value = number
            unit = nil
        case let .text(text):
            value = numericValues(text).first
            unit = text
        case let .quantity(quantity):
            value = quantity.value
            unit = quantity.unitCode
        case .null:
            return nil
        }
        guard let value, value.isFinite else { return nil }
        guard let unit = unit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !unit.isEmpty else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        let fraction: Double
        if unit.contains("percent") || unit.contains("%") {
            fraction = value / 100
        } else if unit == "1" || unit.contains("dimensionless") {
            fraction = value
        } else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        guard (0 ... 1).contains(fraction) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return fraction
    }

    static func numericValues(_ string: String) -> [Double] {
        string.components(
            separatedBy: CharacterSet(
                charactersIn: "0123456789.-"
            ).inverted
        ).compactMap { token in
            guard !token.isEmpty else { return nil }
            return Double(token)
        }
    }

    static func windDirectionDegrees(_ source: String?) -> Double? {
        let values: [String: Double] = [
            "N": 0, "NNE": 22.5, "NE": 45, "ENE": 67.5,
            "E": 90, "ESE": 112.5, "SE": 135, "SSE": 157.5,
            "S": 180, "SSW": 202.5, "SW": 225, "WSW": 247.5,
            "W": 270, "WNW": 292.5, "NW": 315, "NNW": 337.5
        ]
        guard let source else { return nil }
        return values[source.uppercased()]
    }

    static func conditionCode(
        _ summary: String
    ) -> ArkFileWeatherConditionCode {
        let value = summary.lowercased()
        if value.contains("thunder") { return .thunderstorm }
        if value.contains("freezing rain") { return .freezingRain }
        if value.contains("sleet") || value.contains("ice pellet") {
            return .sleet
        }
        if value.contains("snow") || value.contains("blizzard") {
            return .snow
        }
        if value.contains("drizzle") { return .drizzle }
        if value.contains("rain") || value.contains("shower") {
            return .rain
        }
        if value.contains("fog") || value.contains("mist") { return .fog }
        if value.contains("smoke") { return .smoke }
        if value.contains("dust") || value.contains("sand") { return .dust }
        if value.contains("wind") || value.contains("breezy") {
            return .wind
        }
        if value.contains("partly") || value.contains("mostly sunny")
            || value.contains("mostly clear") {
            return .partlyCloudy
        }
        if value.contains("cloud") || value.contains("overcast") {
            return .cloudy
        }
        if value.contains("clear") || value.contains("sunny") {
            return .clear
        }
        return .unknown
    }

    static func preferredCondition(
        _ conditions: [ArkFileWeatherConditionCode]
    ) -> ArkFileWeatherConditionCode {
        let priority: [ArkFileWeatherConditionCode] = [
            .thunderstorm, .freezingRain, .sleet, .snow, .rain, .drizzle,
            .smoke, .dust, .fog, .wind, .cloudy, .partlyCloudy, .clear,
            .unknown
        ]
        return priority.first(where: conditions.contains) ?? .unknown
    }

    static func maximum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    static func minimum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}

// MARK: - Alert normalization

private extension ArkFileNWSWeatherProvider {
    struct NormalizedAlert {
        let alert: ArkFileWeatherAlert
        let referencedIDs: [String]
    }

    static func normalizeAlerts(
        _ sourceAlerts: [AlertProperties],
        now: Date
    ) throws -> [ArkFileWeatherAlert] {
        var normalized: [NormalizedAlert] = []
        var cancelledIDs = Set<String>()
        var replacedIDs = Set<String>()

        for source in sourceAlerts {
            guard let status = source.status?.lowercased() else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            switch status {
            case "actual":
                break
            case "exercise", "system", "test", "draft":
                continue
            default:
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            guard let scope = source.scope?.lowercased() else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            switch scope {
            case "public":
                break
            case "restricted", "private":
                // Restricted and private CAP messages are not public warning
                // products and must not be redistributed by ArkFile.
                continue
            default:
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            let id = try requiredPlainText(
                source.id,
                maximumLength: 512
            )
            let references = try (source.references ?? []).map {
                try requiredPlainText(
                    $0.identifier,
                    maximumLength: 512
                )
            }
            let messageType = alertMessageType(source.messageType)
            switch messageType {
            case .cancel:
                cancelledIDs.insert(id)
                cancelledIDs.formUnion(references)
                continue
            case .acknowledge, .error:
                // CAP acknowledgement/error messages are protocol responses,
                // not hazards for the selected point.
                continue
            case .unknown:
                // Fail closed rather than turning an unknown CAP message into
                // either a warning or an authoritative empty-alert result.
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            case .alert, .update:
                break
            }
            if messageType == .update {
                replacedIDs.formUnion(references.filter { $0 != id })
            }

            let sentAt = try requiredDate(source.sent, now: now)
            let effectiveAt = try optionalAlertDate(source.effective, now: now)
            let onsetAt = try optionalAlertDate(source.onset, now: now)
            let expiresAt = try requiredDate(source.expires, now: now)
            let endsAt = try optionalAlertDate(source.ends, now: now)
            let maximumAlertSpan: TimeInterval = 31 * 24 * 60 * 60
            guard sentAt >= now.addingTimeInterval(-maximumAlertSpan),
                  sentAt <= now.addingTimeInterval(24 * 60 * 60),
                  (effectiveAt ?? sentAt)
                    <= now.addingTimeInterval(maximumAlertSpan),
                  expiresAt <= now.addingTimeInterval(maximumAlertSpan),
                  endsAt.map({
                      $0 <= now.addingTimeInterval(maximumAlertSpan)
                  }) != false else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            guard expiresAt >= (effectiveAt ?? sentAt) else {
                throw FailureDescriptor(
                    kind: .invalidResponse,
                    retryAfter: nil,
                    providerCode: "schema"
                )
            }
            if (endsAt ?? expiresAt) <= now {
                continue
            }

            let event = try requiredPlainText(
                source.event,
                maximumLength: 256
            )
            let issuingAgency = try boundedPlainText(
                source.senderName,
                maximumLength: 512,
                allowEmpty: true
            ).flatMap { $0.isEmpty ? nil : $0 }
            let headline = try boundedPlainText(
                source.headline,
                maximumLength: 1_024,
                allowEmpty: true
            ).flatMap { $0.isEmpty ? nil : $0 } ?? event
            let area = try boundedPlainText(
                source.areaDescription,
                maximumLength: 4_096,
                allowEmpty: true
            ) ?? ""
            let description = try boundedPlainText(
                source.description,
                maximumLength: 32_768,
                allowEmpty: true
            ) ?? ""
            let instruction = try boundedPlainText(
                source.instruction,
                maximumLength: 32_768,
                allowEmpty: true
            ).flatMap { $0.isEmpty ? nil : $0 }
            let affectedZoneIDs = try normalizedZoneIDs(
                source.affectedZones ?? []
            )
            normalized.append(
                NormalizedAlert(
                    alert: ArkFileWeatherAlert(
                        id: id,
                        sourceID: "nws-alerts",
                        issuingAgency: issuingAgency,
                        event: event,
                        headline: headline,
                        areaDescription: area,
                        description: description,
                        instruction: instruction,
                        severity: alertSeverity(source.severity),
                        urgency: alertUrgency(source.urgency),
                        certainty: alertCertainty(source.certainty),
                        messageType: messageType,
                        sentAt: sentAt,
                        effectiveAt: effectiveAt,
                        onsetAt: onsetAt,
                        expiresAt: expiresAt,
                        endsAt: endsAt,
                        affectedZoneIDs: affectedZoneIDs
                    ),
                    referencedIDs: references
                )
            )
        }

        var byID: [String: NormalizedAlert] = [:]
        for candidate in normalized {
            if let existing = byID[candidate.alert.id],
               existing.alert.sentAt >= candidate.alert.sentAt {
                continue
            }
            byID[candidate.alert.id] = candidate
        }
        return byID.values
            .filter {
                !cancelledIDs.contains($0.alert.id)
                    && !replacedIDs.contains($0.alert.id)
            }
            .map(\.alert)
            .sorted {
                let left = severityRank($0.severity)
                let right = severityRank($1.severity)
                if left != right { return left > right }
                if $0.sentAt != $1.sentAt { return $0.sentAt > $1.sentAt }
                return $0.id < $1.id
            }
    }

    static func normalizedZoneIDs(_ rawValues: [String]) throws -> [String] {
        guard rawValues.count <= 256 else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        var seen = Set<String>()
        var values: [String] = []
        for rawValue in rawValues {
            guard let url = URL(string: rawValue),
                  isTrustedAPIURL(url),
                  let value = boundedIdentifier(
                    url.pathComponents.last,
                    maximumLength: 512
                  ) else {
                throw FailureDescriptor(
                    kind: .integrity,
                    retryAfter: nil,
                    providerCode: "endpoint"
                )
            }
            if seen.insert(value).inserted {
                values.append(value)
            }
        }
        return values
    }

    static func requiredDate(_ value: String?, now: Date) throws -> Date {
        guard let date = parseDate(value),
              date >= now.addingTimeInterval(-10 * 365 * 24 * 60 * 60),
              date <= now.addingTimeInterval(5 * 365 * 24 * 60 * 60) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return date
    }

    static func optionalAlertDate(
        _ value: String?,
        now: Date
    ) throws -> Date? {
        guard let value else { return nil }
        return try requiredDate(value, now: now)
    }

    static func alertSeverity(_ value: String?) -> ArkFileWeatherAlertSeverity {
        switch value?.lowercased() {
        case "minor": .minor
        case "moderate": .moderate
        case "severe": .severe
        case "extreme": .extreme
        default: .unknown
        }
    }

    static func alertUrgency(_ value: String?) -> ArkFileWeatherAlertUrgency {
        switch value?.lowercased() {
        case "past": .past
        case "future": .future
        case "expected": .expected
        case "immediate": .immediate
        default: .unknown
        }
    }

    static func alertCertainty(
        _ value: String?
    ) -> ArkFileWeatherAlertCertainty {
        switch value?.lowercased() {
        case "unlikely": .unlikely
        case "possible": .possible
        case "likely": .likely
        case "observed": .observed
        default: .unknown
        }
    }

    static func alertMessageType(
        _ value: String?
    ) -> ArkFileWeatherAlertMessageType {
        switch value?.lowercased() {
        case "alert": .alert
        case "update": .update
        case "cancel": .cancel
        case "acknowledge": .acknowledge
        case "error": .error
        default: .unknown
        }
    }

    static func severityRank(_ severity: ArkFileWeatherAlertSeverity) -> Int {
        switch severity {
        case .extreme: 4
        case .severe: 3
        case .moderate: 2
        case .minor: 1
        case .unknown: 0
        }
    }
}

// MARK: - Point metadata and bounded text

private extension ArkFileNWSWeatherProvider {
    static func astronomicalMetadata(
        _ source: PointAstronomicalDTO?
    ) -> ArkFileNWSPointAstronomicalData? {
        guard let source else { return nil }
        let value = ArkFileNWSPointAstronomicalData(
            sunrise: parseDate(source.sunrise),
            sunset: parseDate(source.sunset),
            civilTwilightBegin: parseDate(source.civilTwilightBegin),
            civilTwilightEnd: parseDate(source.civilTwilightEnd)
        )
        guard value.sunrise != nil
                || value.sunset != nil
                || value.civilTwilightBegin != nil
                || value.civilTwilightEnd != nil else {
            return nil
        }
        return value
    }

    static func radioMetadata(
        _ source: PointRadioDTO?
    ) -> ArkFileNWSPointRadioMetadata? {
        guard let source else { return nil }
        let transmitter = boundedIdentifier(
            source.transmitter,
            maximumLength: 32
        )
        let sameCode: String?
        if let value = source.sameCode,
           value.count == 6,
           value.allSatisfy(\.isNumber) {
            sameCode = value
        } else {
            sameCode = nil
        }
        let value = ArkFileNWSPointRadioMetadata(
            transmitterCallSign: transmitter,
            sameCode: sameCode,
            hasAreaBroadcast: isTrustedAPIRawURL(source.areaBroadcast),
            hasPointBroadcast: isTrustedAPIRawURL(source.pointBroadcast)
        )
        guard value.transmitterCallSign != nil
                || value.sameCode != nil
                || value.hasAreaBroadcast
                || value.hasPointBroadcast else {
            return nil
        }
        return value
    }

    static func terminalZoneID(_ rawValue: String?) -> String? {
        guard let rawValue,
              let url = URL(string: rawValue),
              isTrustedAPIURL(url) else {
            return nil
        }
        return boundedIdentifier(
            url.pathComponents.last,
            maximumLength: 64
        )
    }

    static func validTimeZoneIdentifier(_ rawValue: String?) -> String? {
        guard let value = boundedIdentifier(
            rawValue,
            maximumLength: 128
        ),
            TimeZone(identifier: value) != nil else {
            return nil
        }
        return value
    }

    static func placeName(_ relativeLocation: PointRelativeLocationDTO?) -> String? {
        guard let properties = relativeLocation?.properties,
              let city = boundedIdentifier(
                  properties.city,
                  maximumLength: 96
              ) else {
            return nil
        }
        let state = boundedIdentifier(
            properties.state,
            maximumLength: 32
        )
        return state.map { "\(city), \($0)" } ?? city
    }

    static func isTrustedAPIRawURL(_ rawValue: String?) -> Bool {
        guard let rawValue, let url = URL(string: rawValue) else {
            return false
        }
        return isTrustedAPIURL(url)
    }

    static func boundedIdentifier(
        _ rawValue: String?,
        maximumLength: Int
    ) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumLength,
              !value.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            return nil
        }
        return value
    }

    static func requiredPlainText(
        _ rawValue: String?,
        maximumLength: Int
    ) throws -> String {
        guard let value = try boundedPlainText(
            rawValue,
            maximumLength: maximumLength,
            allowEmpty: false
        ) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return value
    }

    static func boundedPlainText(
        _ rawValue: String?,
        maximumLength: Int,
        allowEmpty: Bool
    ) throws -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let filteredScalars = normalized.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t"
                || $0.properties.generalCategory != .control
        }
        let value = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= maximumLength,
              allowEmpty || !value.isEmpty else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "schema"
            )
        }
        return value
    }

    static func compactWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, value.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    static func coordinateString(
        _ coordinate: ArkFileWeatherCoordinate
    ) -> String {
        let latitude = abs(coordinate.latitude) < 0.000_05
            ? 0
            : coordinate.latitude
        let longitude = abs(coordinate.longitude) < 0.000_05
            ? 0
            : coordinate.longitude
        return String(
            format: "%.4f,%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude
        )
    }

    static func safeHeaderValue(
        _ rawValue: String,
        fallback: String,
        maximumLength: Int
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              !value.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }) else {
            return fallback
        }
        return value
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "decode"
            )
        }
    }
}

// MARK: - NWS transport DTOs

private struct PointEnvelope: Decodable {
    let properties: PointProperties
}

private struct PointProperties: Decodable {
    let forecastOfficeID: String?
    let gridID: String?
    let gridX: Int?
    let gridY: Int?
    let forecast: String?
    let forecastHourly: String?
    let forecastZone: String?
    let county: String?
    let fireWeatherZone: String?
    let timeZone: String?
    let relativeLocation: PointRelativeLocationDTO?
    let radarStation: String?
    let astronomicalData: PointAstronomicalDTO?
    let nwr: PointRadioDTO?

    private enum CodingKeys: String, CodingKey {
        case forecastOfficeID = "cwa"
        case gridID = "gridId"
        case gridX
        case gridY
        case forecast
        case forecastHourly
        case forecastZone
        case county
        case fireWeatherZone
        case timeZone
        case relativeLocation
        case radarStation
        case astronomicalData
        case nwr
    }
}

private struct PointRelativeLocationDTO: Decodable {
    let properties: PointRelativeLocationPropertiesDTO?
}

private struct PointRelativeLocationPropertiesDTO: Decodable {
    let city: String?
    let state: String?
}

private struct PointAstronomicalDTO: Decodable {
    let sunrise: String?
    let sunset: String?
    let civilTwilightBegin: String?
    let civilTwilightEnd: String?
}

private struct PointRadioDTO: Decodable {
    let transmitter: String?
    let sameCode: String?
    let areaBroadcast: String?
    let pointBroadcast: String?
}

private struct ForecastEnvelope: Decodable {
    let properties: ForecastProperties
}

private struct ForecastProperties: Decodable {
    let generatedAt: String?
    let updateTime: String?
    let periods: [ForecastPeriod]
}

private struct ForecastPeriod: Decodable {
    let number: Int?
    let startTime: String?
    let endTime: String?
    let isDaytime: Bool?
    let temperature: FlexibleValue?
    let temperatureUnit: String?
    let probabilityOfPrecipitation: FlexibleValue?
    let dewpoint: FlexibleValue?
    let relativeHumidity: FlexibleValue?
    let windSpeed: FlexibleValue?
    let windGust: FlexibleValue?
    let windDirection: String?
    let shortForecast: String?
    let detailedForecast: String?
}

private struct QuantitativeValueDTO: Decodable {
    let value: Double?
    let maxValue: Double?
    let minValue: Double?
    let unitCode: String?
}

private enum FlexibleValue: Decodable {
    case number(Double)
    case text(String)
    case quantity(QuantitativeValueDTO)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .quantity(try container.decode(QuantitativeValueDTO.self))
        }
    }
}

private struct AlertEnvelope: Decodable {
    let updated: String?
    let features: [AlertFeature]?
    let graph: [AlertProperties]?

    private enum CodingKeys: String, CodingKey {
        case updated
        case features
        case graph = "@graph"
    }
}

private struct AlertFeature: Decodable {
    let properties: AlertProperties
}

private struct AlertProperties: Decodable {
    let id: String?
    let senderName: String?
    let areaDescription: String?
    let affectedZones: [String]?
    let references: [AlertReferenceDTO]?
    let sent: String?
    let effective: String?
    let onset: String?
    let expires: String?
    let ends: String?
    let status: String?
    let scope: String?
    let messageType: String?
    let severity: String?
    let certainty: String?
    let urgency: String?
    let event: String?
    let headline: String?
    let description: String?
    let instruction: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case senderName
        case areaDescription = "areaDesc"
        case affectedZones
        case references
        case sent
        case effective
        case onset
        case expires
        case ends
        case status
        case scope
        case messageType
        case severity
        case certainty
        case urgency
        case event
        case headline
        case description
        case instruction
    }
}

private struct AlertReferenceDTO: Decodable {
    let identifier: String?
}
