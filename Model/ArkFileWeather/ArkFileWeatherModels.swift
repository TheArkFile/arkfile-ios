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

import Foundation

// MARK: - Saved location and settings

/// A portable coordinate that keeps Saved Weather independent of CoreLocation
/// and, importantly, out of UserDefaults.
struct ArkFileWeatherCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90 ... 90).contains(latitude)
            && (-180 ... 180).contains(longitude)
    }

    /// Great-circle distance without importing CoreLocation into the durable
    /// weather model. The result is used only to suppress foreground GPS
    /// jitter before a followed location is replaced.
    func distanceMeters(to other: Self) -> Double? {
        guard isValid, other.isValid else { return nil }
        let earthRadiusMeters = 6_371_008.8
        let latitude1 = latitude * .pi / 180
        let latitude2 = other.latitude * .pi / 180
        let latitudeDelta = (other.latitude - latitude) * .pi / 180
        let longitudeDelta = (other.longitude - longitude) * .pi / 180
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(latitude1)
                * cos(latitude2)
                * pow(sin(longitudeDelta / 2), 2)
        let centralAngle = 2 * atan2(
            sqrt(haversine),
            sqrt(max(0, 1 - haversine))
        )
        let distance = earthRadiusMeters * centralAngle
        return distance.isFinite ? distance : nil
    }
}

enum ArkFileWeatherLocationSource: String, Codable, Equatable, Sendable {
    case currentLocation
    case enteredCoordinate
    case offlineMap
    case savedWaypoint
}

enum ArkFileWeatherUnitPreference: String, Codable, Equatable, Sendable {
    case automatic
    case us
    case metric
}

/// Exactly one location can be active. `revision` changes whenever its
/// coordinate changes, allowing refresh code to reject an old in-flight result.
struct ArkFileWeatherSavedLocation: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
    let coordinate: ArkFileWeatherCoordinate
    let displayName: String
    let timeZoneIdentifier: String?
    let source: ArkFileWeatherLocationSource
    let selectedAt: Date
    let measuredAt: Date?
    let horizontalAccuracyMeters: Double?
}

struct ArkFileWeatherEnvironmentalPreferences: Codable, Equatable, Sendable {
    var airQualityEnabled: Bool
    var smokeEnabled: Bool
    var riverConditionsEnabled: Bool
    var droughtEnabled: Bool
    var selectedRiverGaugeID: String?

    static let disabled = ArkFileWeatherEnvironmentalPreferences(
        airQualityEnabled: false,
        smokeEnabled: false,
        riverConditionsEnabled: false,
        droughtEnabled: false,
        selectedRiverGaugeID: nil
    )
}

struct ArkFileWeatherSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var savedLocation: ArkFileWeatherSavedLocation?
    var automaticRefreshEnabled: Bool
    var refreshOnWiFiOnly: Bool
    var unitPreference: ArkFileWeatherUnitPreference
    var environmental: ArkFileWeatherEnvironmentalPreferences
    var modifiedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        savedLocation: ArkFileWeatherSavedLocation? = nil,
        automaticRefreshEnabled: Bool = false,
        refreshOnWiFiOnly: Bool = false,
        unitPreference: ArkFileWeatherUnitPreference = .automatic,
        environmental: ArkFileWeatherEnvironmentalPreferences = .disabled,
        modifiedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.savedLocation = savedLocation
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.refreshOnWiFiOnly = refreshOnWiFiOnly
        self.unitPreference = unitPreference
        self.environmental = environmental
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Component state and provenance

enum ArkFileWeatherComponentAvailability: String, Codable, Equatable, Sendable {
    /// The last attempt returned one or more normalized values.
    case available
    /// The last attempt succeeded and authoritatively returned no values.
    case successfulEmpty
    /// The last attempt failed. A prior value and stamp may still be retained.
    case failed
    /// The component is temporarily unavailable or has not been configured.
    case unavailable
    /// The source does not cover this location or app configuration.
    case unsupported
}

enum ArkFileWeatherFailureKind: String, Codable, Equatable, Sendable {
    case offline
    case timedOut
    case rateLimited
    case server
    case invalidResponse
    case integrity
    case cancelled
    case unknown
}

enum ArkFileWeatherUnavailableReason: String, Codable, Equatable, Sendable {
    case notConfigured
    case permissionDenied
    case sourceUnavailable
    case notSupportedForLocation
    case noMatchingStation
}

/// Provider failures are deliberately normalized. Raw URLs, coordinates,
/// response bodies, alert text, and location labels do not belong here.
struct ArkFileWeatherComponentFailure: Codable, Equatable, Sendable {
    let kind: ArkFileWeatherFailureKind
    let occurredAt: Date
    let retryAfter: Date?
    let providerCode: String?
}

/// Absolute freshness boundaries are captured with the data so the app can
/// classify it consistently while offline without consulting a provider.
struct ArkFileWeatherComponentStamp: Codable, Equatable, Sendable {
    let sourceID: String
    let issuedAt: Date?
    let fetchedAt: Date
    let validFrom: Date?
    let validUntil: Date?
    let freshUntil: Date
    let agingUntil: Date
    let expiresAt: Date
    let historicalAt: Date
    let entityTag: String?
    let lastModified: String?
    /// Optional normalized source artifacts used for independent conditional
    /// requests. This is populated only by the CPC climate component. Keeping
    /// the national products with the stamp also preserves them for a
    /// successful-empty result, whose component value is intentionally nil.
    let climateSourceProducts: [ArkFileWeatherClimateSourceProduct]?

    init(
        sourceID: String,
        issuedAt: Date?,
        fetchedAt: Date,
        validFrom: Date?,
        validUntil: Date?,
        freshUntil: Date,
        agingUntil: Date,
        expiresAt: Date,
        historicalAt: Date,
        entityTag: String?,
        lastModified: String?,
        climateSourceProducts: [ArkFileWeatherClimateSourceProduct]? = nil
    ) {
        self.sourceID = sourceID
        self.issuedAt = issuedAt
        self.fetchedAt = fetchedAt
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.freshUntil = freshUntil
        self.agingUntil = agingUntil
        self.expiresAt = expiresAt
        self.historicalAt = historicalAt
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.climateSourceProducts = climateSourceProducts
    }
}

struct ArkFileWeatherComponent<Value>: Codable, Equatable, Sendable
where Value: Codable & Equatable & Sendable {
    var availability: ArkFileWeatherComponentAvailability
    var value: Value?
    var stamp: ArkFileWeatherComponentStamp?
    var failure: ArkFileWeatherComponentFailure?
    var unavailableReason: ArkFileWeatherUnavailableReason?

    static func available(
        _ value: Value,
        stamp: ArkFileWeatherComponentStamp
    ) -> Self {
        Self(
            availability: .available,
            value: value,
            stamp: stamp,
            failure: nil,
            unavailableReason: nil
        )
    }

    static func successfulEmpty(stamp: ArkFileWeatherComponentStamp) -> Self {
        Self(
            availability: .successfulEmpty,
            value: nil,
            stamp: stamp,
            failure: nil,
            unavailableReason: nil
        )
    }

    /// A failed refresh keeps the last known-good value and its original stamp.
    /// An empty or unavailable response must never masquerade as fresh data.
    func recordingFailure(_ failure: ArkFileWeatherComponentFailure) -> Self {
        Self(
            availability: .failed,
            value: value,
            stamp: stamp,
            failure: failure,
            unavailableReason: nil
        )
    }

    static func unavailable(_ reason: ArkFileWeatherUnavailableReason) -> Self {
        Self(
            availability: .unavailable,
            value: nil,
            stamp: nil,
            failure: nil,
            unavailableReason: reason
        )
    }

    static func unsupported(_ reason: ArkFileWeatherUnavailableReason) -> Self {
        Self(
            availability: .unsupported,
            value: nil,
            stamp: nil,
            failure: nil,
            unavailableReason: reason
        )
    }
}

// MARK: - Normalized forecast data

enum ArkFileWeatherConditionCode: String, Codable, Equatable, Sendable {
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case rain
    case freezingRain
    case sleet
    case snow
    case thunderstorm
    case wind
    case smoke
    case dust
    case unknown
}

/// Canonical storage units are encoded in field names:
/// Celsius, meters/second, millimeters, meters, hectopascals, degrees, and
/// unit fractions in the closed range 0...1. Display conversion is a UI concern.
struct ArkFileWeatherHourlyPeriod: Codable, Equatable, Sendable {
    let id: String
    let startsAt: Date
    let endsAt: Date
    let condition: ArkFileWeatherConditionCode
    let summary: String
    let temperatureCelsius: Double?
    let apparentTemperatureCelsius: Double?
    let dewPointCelsius: Double?
    let relativeHumidityFraction: Double?
    let precipitationProbabilityFraction: Double?
    let precipitationMillimeters: Double?
    let windSpeedMetersPerSecond: Double?
    let windGustMetersPerSecond: Double?
    let windDirectionDegrees: Double?
    let cloudCoverFraction: Double?
    let visibilityMeters: Double?
    let pressureHectopascals: Double?
}

struct ArkFileWeatherDailyPeriod: Codable, Equatable, Sendable {
    let id: String
    let startsAt: Date
    let endsAt: Date
    let condition: ArkFileWeatherConditionCode
    let summary: String
    let minimumTemperatureCelsius: Double?
    let maximumTemperatureCelsius: Double?
    let precipitationProbabilityFraction: Double?
    let precipitationMillimeters: Double?
    let maximumWindSpeedMetersPerSecond: Double?
    let maximumWindGustMetersPerSecond: Double?
}

// MARK: - Alerts

enum ArkFileWeatherAlertSeverity: String, Codable, Equatable, Sendable {
    case unknown
    case minor
    case moderate
    case severe
    case extreme
}

enum ArkFileWeatherAlertUrgency: String, Codable, Equatable, Sendable {
    case unknown
    case past
    case future
    case expected
    case immediate
}

enum ArkFileWeatherAlertCertainty: String, Codable, Equatable, Sendable {
    case unknown
    case unlikely
    case possible
    case likely
    case observed
}

enum ArkFileWeatherAlertMessageType: String, Codable, Equatable, Sendable {
    case alert
    case update
    case cancel
    case acknowledge
    case error
    case unknown
}

struct ArkFileWeatherAlert: Codable, Equatable, Sendable {
    let id: String
    let sourceID: String
    /// The agency that authored/issued the alert. NWS can redistribute alerts
    /// from local or civil authorities, so this must not be hard-coded in UI.
    let issuingAgency: String?
    let event: String
    let headline: String
    let areaDescription: String
    let description: String
    let instruction: String?
    let severity: ArkFileWeatherAlertSeverity
    let urgency: ArkFileWeatherAlertUrgency
    let certainty: ArkFileWeatherAlertCertainty
    let messageType: ArkFileWeatherAlertMessageType
    let sentAt: Date
    let effectiveAt: Date?
    let onsetAt: Date?
    let expiresAt: Date
    let endsAt: Date?
    let affectedZoneIDs: [String]

    func isActive(at date: Date) -> Bool {
        // CAP `effective` controls when a message applies. `onset` describes
        // when the underlying hazard is expected to begin and can be later;
        // watches and warnings must remain visible before that event time.
        let beginsAt = effectiveAt ?? sentAt
        let finishesAt = min(endsAt ?? expiresAt, expiresAt)
        let isHazardMessage = messageType == .alert || messageType == .update
        return isHazardMessage && date >= beginsAt && date < finishesAt
    }

    func isUpcoming(at date: Date) -> Bool {
        let beginsAt = effectiveAt ?? sentAt
        let finishesAt = min(endsAt ?? expiresAt, expiresAt)
        let isHazardMessage = messageType == .alert || messageType == .update
        return isHazardMessage && date < beginsAt && date < finishesAt
    }
}

// MARK: - Climate outlooks

enum ArkFileWeatherOutlookPeriodKind: String, Codable, Equatable, Sendable {
    case sixToTenDay
    case eightToFourteenDay
    case weekThreeToFour
}

struct ArkFileWeatherProbabilityDistribution: Codable, Equatable, Sendable {
    let belowNormalFraction: Double?
    let nearNormalFraction: Double?
    let aboveNormalFraction: Double?
}

/// A normalized CPC source artifact. These six small records are sufficient to
/// apply per-product HTTP validators and safely rebuild a 304 response without
/// retaining the national KMZ archives.
struct ArkFileWeatherClimateSourceProduct: Codable, Equatable, Sendable {
    static let cpcProductIDs: Set<String> = [
        "610temp_latest",
        "610prcp_latest",
        "814temp_latest",
        "814prcp_latest",
        "wk34temp_latest",
        "wk34prcp_latest"
    ]

    let productID: String
    let issuedAt: Date
    let validFrom: Date
    let validUntil: Date
    let distribution: ArkFileWeatherProbabilityDistribution?
    let entityTag: String?
    let lastModified: String?
}

struct ArkFileWeatherClimateOutlook: Codable, Equatable, Sendable {
    let id: String
    let period: ArkFileWeatherOutlookPeriodKind
    let issuedAt: Date
    let validFrom: Date
    let validUntil: Date
    let temperature: ArkFileWeatherProbabilityDistribution
    let precipitation: ArkFileWeatherProbabilityDistribution
}

// MARK: - Astronomy

enum ArkFileWeatherMoonPhase: String, Codable, Equatable, Sendable {
    case new
    case waxingCrescent
    case firstQuarter
    case waxingGibbous
    case full
    case waningGibbous
    case lastQuarter
    case waningCrescent
}

struct ArkFileWeatherAstronomyDay: Codable, Equatable, Sendable {
    let localDayStart: Date
    let sunrise: Date?
    let sunset: Date?
    let civilDawn: Date?
    let civilDusk: Date?
    let moonrise: Date?
    let moonset: Date?
    let moonPhase: ArkFileWeatherMoonPhase
    let moonIlluminationFraction: Double
}

// MARK: - NOAA Weather Radio / SAME

struct ArkFileWeatherSAMECounty: Codable, Equatable, Sendable {
    let code: String
    let displayName: String
}

struct ArkFileWeatherRadioTransmitter: Codable, Equatable, Sendable {
    let id: String
    let callSign: String
    let frequencyMegahertz: Double
    let channel: String?
    let siteName: String
    let coordinate: ArkFileWeatherCoordinate?
    let sameCounties: [ArkFileWeatherSAMECounty]
    let coverageNote: String?

    /// iPhone hardware cannot receive NOAA Weather Radio broadcasts.
    var requiresExternalReceiver: Bool { true }
}

// MARK: - Separately gated environmental modules

struct ArkFileWeatherAirQuality: Codable, Equatable, Sendable {
    let observedAt: Date
    let airQualityIndex: Int
    let category: String
    let primaryPollutant: String?
}

struct ArkFileWeatherSmoke: Codable, Equatable, Sendable {
    let validAt: Date
    let category: String
    let summary: String
}

struct ArkFileWeatherRiverCondition: Codable, Equatable, Sendable {
    let gaugeID: String
    let gaugeName: String
    let observedAt: Date
    let stageMeters: Double?
    let flowCubicMetersPerSecond: Double?
    let category: String?
}

enum ArkFileWeatherDroughtCategory: String, Codable, Equatable, Sendable {
    case none
    case abnormallyDry
    case moderate
    case severe
    case extreme
    case exceptional
}

struct ArkFileWeatherDroughtCondition: Codable, Equatable, Sendable {
    let validAt: Date
    let category: ArkFileWeatherDroughtCategory
    let summary: String?
}

// MARK: - Durable briefing snapshot

struct ArkFileWeatherSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let locationRevision: Int
    let assembledAt: Date
    /// NOAA's nearest relative city/state label from the last successful
    /// point lookup. Keeping it with the snapshot makes the friendly location
    /// name available offline without overwriting a user-named waypoint.
    var resolvedPlaceName: String?
    var hourly: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>
    var daily: ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]>
    var alerts: ArkFileWeatherComponent<[ArkFileWeatherAlert]>
    var climateOutlooks: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>
    var astronomy: ArkFileWeatherComponent<[ArkFileWeatherAstronomyDay]>
    var radioTransmitters: ArkFileWeatherComponent<[ArkFileWeatherRadioTransmitter]>
    var airQuality: ArkFileWeatherComponent<ArkFileWeatherAirQuality>
    var smoke: ArkFileWeatherComponent<ArkFileWeatherSmoke>
    var riverConditions: ArkFileWeatherComponent<[ArkFileWeatherRiverCondition]>
    var drought: ArkFileWeatherComponent<ArkFileWeatherDroughtCondition>
    /// Exact SAME area identities resolved from the bundled NOAA directory.
    /// This remains useful when NOAA lists no transmitter or when a partial
    /// county cannot be selected unambiguously.
    var radioAreas: [ArkFileWeatherRadioAreaIdentity]?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        locationRevision: Int,
        assembledAt: Date,
        resolvedPlaceName: String? = nil,
        hourly: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>,
        daily: ArkFileWeatherComponent<[ArkFileWeatherDailyPeriod]>,
        alerts: ArkFileWeatherComponent<[ArkFileWeatherAlert]>,
        climateOutlooks: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        astronomy: ArkFileWeatherComponent<[ArkFileWeatherAstronomyDay]>,
        radioTransmitters: ArkFileWeatherComponent<[ArkFileWeatherRadioTransmitter]>,
        airQuality: ArkFileWeatherComponent<ArkFileWeatherAirQuality>,
        smoke: ArkFileWeatherComponent<ArkFileWeatherSmoke>,
        riverConditions: ArkFileWeatherComponent<[ArkFileWeatherRiverCondition]>,
        drought: ArkFileWeatherComponent<ArkFileWeatherDroughtCondition>,
        radioAreas: [ArkFileWeatherRadioAreaIdentity]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.locationRevision = locationRevision
        self.assembledAt = assembledAt
        self.resolvedPlaceName = resolvedPlaceName
        self.hourly = hourly
        self.daily = daily
        self.alerts = alerts
        self.climateOutlooks = climateOutlooks
        self.astronomy = astronomy
        self.radioTransmitters = radioTransmitters
        self.airQuality = airQuality
        self.smoke = smoke
        self.riverConditions = riverConditions
        self.drought = drought
        self.radioAreas = radioAreas
    }
}
