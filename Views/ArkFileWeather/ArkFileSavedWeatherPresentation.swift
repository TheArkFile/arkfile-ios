// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Foundation

struct ArkFileSavedWeatherPlanningHighlight: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let title: String
    let detail: String
}

enum ArkFileSavedWeatherPresentation {
    enum DisplayUnits: Equatable {
        case us
        case metric
    }

    static func matchingSnapshot(
        settings: ArkFileWeatherSettings,
        snapshot: ArkFileWeatherSnapshot?
    ) -> ArkFileWeatherSnapshot? {
        guard let location = settings.savedLocation,
              let snapshot,
              snapshot.locationRevision == location.revision else {
            return nil
        }
        return snapshot
    }

    static func locationDisplayName(
        settings: ArkFileWeatherSettings,
        snapshot: ArkFileWeatherSnapshot?
    ) -> String? {
        let matching = matchingSnapshot(settings: settings, snapshot: snapshot)
        return matching?.resolvedPlaceName
            ?? settings.savedLocation?.displayName
    }

    static func displayUnits(
        preference: ArkFileWeatherUnitPreference,
        locale: Locale
    ) -> DisplayUnits {
        switch preference {
        case .us:
            return .us
        case .metric:
            return .metric
        case .automatic:
            return locale.measurementSystem == .us ? .us : .metric
        }
    }

    static func temperature(
        celsius: Double?,
        units: DisplayUnits
    ) -> String? {
        guard let celsius, celsius.isFinite else { return nil }
        switch units {
        case .us:
            return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        case .metric:
            return "\(Int(celsius.rounded()))°C"
        }
    }

    static func windSpeed(
        metersPerSecond: Double?,
        units: DisplayUnits
    ) -> String? {
        guard let metersPerSecond,
              metersPerSecond.isFinite,
              metersPerSecond >= 0 else {
            return nil
        }
        switch units {
        case .us:
            return "\(Int((metersPerSecond * 2.236_936).rounded())) mph"
        case .metric:
            return "\(Int((metersPerSecond * 3.6).rounded())) km/h"
        }
    }

    static func probability(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    static func hourlyChartTemperatureDomain(
        _ temperatures: [Double]
    ) -> ClosedRange<Double>? {
        let finiteTemperatures = temperatures.filter(\.isFinite)
        guard let observedLow = finiteTemperatures.min(),
              let observedHigh = finiteTemperatures.max() else {
            return nil
        }

        let minimumSpan = 10.0
        let observedSpan = observedHigh - observedLow
        let paddedSpan = max(minimumSpan, observedSpan * 1.25)
        let midpoint = (observedLow + observedHigh) / 2
        let rawLow = midpoint - paddedSpan / 2
        let rawHigh = midpoint + paddedSpan / 2
        let roundedLow = floor(rawLow / 5) * 5
        let roundedHigh = ceil(rawHigh / 5) * 5

        if roundedHigh - roundedLow >= minimumSpan {
            return roundedLow...roundedHigh
        }
        return roundedLow...(roundedLow + minimumSpan)
    }

    static func precipitationChartValue(
        fraction: Double?,
        temperatureDomain: ClosedRange<Double>
    ) -> Double? {
        guard let fraction, fraction.isFinite else { return nil }
        let clampedFraction = min(1, max(0, fraction))
        let span =
            temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard span.isFinite, span > 0 else { return nil }
        return temperatureDomain.lowerBound + clampedFraction * span
    }

    static func precipitationPercent(
        chartValue: Double,
        temperatureDomain: ClosedRange<Double>
    ) -> Int? {
        let span =
            temperatureDomain.upperBound - temperatureDomain.lowerBound
        guard chartValue.isFinite, span.isFinite, span > 0 else {
            return nil
        }
        let fraction =
            (chartValue - temperatureDomain.lowerBound) / span
        return Int((min(1, max(0, fraction)) * 100).rounded())
    }

    static func conditionSystemImage(
        _ condition: ArkFileWeatherConditionCode
    ) -> String {
        switch condition {
        case .clear:
            return "sun.max.fill"
        case .partlyCloudy:
            return "cloud.sun.fill"
        case .cloudy:
            return "cloud.fill"
        case .fog:
            return "cloud.fog.fill"
        case .drizzle:
            return "cloud.drizzle.fill"
        case .rain:
            return "cloud.rain.fill"
        case .freezingRain, .sleet:
            return "cloud.sleet.fill"
        case .snow:
            return "cloud.snow.fill"
        case .thunderstorm:
            return "cloud.bolt.rain.fill"
        case .wind:
            return "wind"
        case .smoke, .dust:
            return "aqi.medium"
        case .unknown:
            return "cloud.fill"
        }
    }

    static func currentHourlyPeriod(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> ArkFileWeatherHourlyPeriod? {
        snapshot.hourly.value?
            .filter { $0.endsAt > now }
            .sorted { $0.startsAt < $1.startsAt }
            .first
    }

    static func futureHourlyPeriods(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date,
        hours: TimeInterval = 24
    ) -> [ArkFileWeatherHourlyPeriod] {
        let cutoff = now.addingTimeInterval(hours * 60 * 60)
        return Array(
            (snapshot.hourly.value ?? [])
                .filter { $0.endsAt > now && $0.startsAt < cutoff }
                .sorted { $0.startsAt < $1.startsAt }
                .prefix(24)
        )
    }

    static func futureDailyPeriods(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> [ArkFileWeatherDailyPeriod] {
        Array(
            (snapshot.daily.value ?? [])
                .filter { $0.endsAt > now }
                .sorted { $0.startsAt < $1.startsAt }
                .prefix(7)
        )
    }

    static func currentClimateOutlooks(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> [ArkFileWeatherClimateOutlook] {
        (snapshot.climateOutlooks.value ?? [])
            .filter { $0.validUntil > now }
            .sorted { $0.validFrom < $1.validFrom }
    }

    static func expiredClimateOutlookCount(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> Int {
        (snapshot.climateOutlooks.value ?? []).filter {
            $0.validUntil <= now
        }.count
    }

    /// Returns the next time-sensitive boundary that can change visible
    /// weather meaning. The UI still refreshes at a bounded cadence for
    /// relative-age copy, while alert activation/expiration and official
    /// outlook validity are allowed to update immediately.
    static func nextPresentationUpdate(
        snapshot: ArkFileWeatherSnapshot?,
        after now: Date,
        maximumInterval: TimeInterval = 30
    ) -> Date {
        let boundedInterval = maximumInterval.isFinite && maximumInterval > 0
            ? min(maximumInterval, 30)
            : 30
        let cadenceDeadline = now.addingTimeInterval(boundedInterval)
        guard let snapshot else { return cadenceDeadline }

        var boundaries: [Date] = []
        for alert in snapshot.alerts.value ?? [] {
            let beginsAt = alert.effectiveAt ?? alert.sentAt
            let finishesAt = min(alert.endsAt ?? alert.expiresAt, alert.expiresAt)
            if beginsAt > now {
                boundaries.append(beginsAt)
            }
            if finishesAt > now {
                boundaries.append(finishesAt)
            }
        }
        for outlook in snapshot.climateOutlooks.value ?? []
            where outlook.validUntil > now {
            boundaries.append(outlook.validUntil)
        }
        for stamp in [
            snapshot.hourly.stamp,
            snapshot.daily.stamp,
            snapshot.alerts.stamp,
            snapshot.climateOutlooks.stamp
        ].compactMap({ $0 }) {
            boundaries.append(contentsOf: [
                stamp.freshUntil,
                stamp.agingUntil,
                stamp.expiresAt,
                stamp.historicalAt
            ].filter { $0 > now })
        }

        return boundaries.min().map {
            min($0, cadenceDeadline)
        } ?? cadenceDeadline
    }

    static func visibleAlerts(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> [ArkFileWeatherAlert] {
        (snapshot.alerts.value ?? []).sorted { lhs, rhs in
            let lhsState = alertTemporalRank(lhs, at: now)
            let rhsState = alertTemporalRank(rhs, at: now)
            if lhsState != rhsState {
                return lhsState > rhsState
            }
            if lhs.severity != rhs.severity {
                return severityRank(lhs.severity) > severityRank(rhs.severity)
            }
            return lhs.sentAt > rhs.sentAt
        }
    }

    static func alertPresentation(
        for alert: ArkFileWeatherAlert,
        component: ArkFileWeatherComponent<[ArkFileWeatherAlert]>,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> ArkFileWeatherAlertPresentation {
        guard let stamp = component.stamp else {
            return ArkFileWeatherAlertPresentation(
                emphasis: .historical,
                isUrgent: false,
                cacheNotice: ArkFileWeatherAlertPresentationSemantics
                    .cachedAlertNotice
            )
        }
        let base = ArkFileWeatherAlertPresentationSemantics.presentation(
            for: alert,
            componentStamp: stamp,
            connectivity: connectivity,
            at: now
        )
        guard component.availability == .failed,
              base.emphasis != .historical else {
            return base
        }
        return ArkFileWeatherAlertPresentation(
            emphasis: base.emphasis == .upcoming ? .upcoming : .caution,
            isUrgent: false,
            cacheNotice: alert.isUpcoming(at: now)
                ? ArkFileWeatherAlertPresentationSemantics
                    .cachedUpcomingAlertNotice
                : ArkFileWeatherAlertPresentationSemantics
                    .cachedAlertNotice
        )
    }

    static func alertsEligibleForGuidance(
        in snapshot: ArkFileWeatherSnapshot,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> [ArkFileWeatherAlert] {
        (snapshot.alerts.value ?? []).filter { alert in
            (alert.isActive(at: now) || alert.isUpcoming(at: now))
                && alertPresentation(
                    for: alert,
                    component: snapshot.alerts,
                    connectivity: connectivity,
                    at: now
                ).emphasis != .historical
        }
    }

    static func primaryStamp(
        in snapshot: ArkFileWeatherSnapshot
    ) -> ArkFileWeatherComponentStamp? {
        snapshot.hourly.stamp
            ?? snapshot.daily.stamp
            ?? snapshot.alerts.stamp
            ?? snapshot.climateOutlooks.stamp
    }

    static func aggregateCoreFreshness(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> ArkFileWeatherFreshness? {
        coreReferenceStamp(in: snapshot, at: now).map {
            ArkFileWeatherFreshnessSemantics.classify(stamp: $0, at: now)
        }
    }

    static func hasCoreRefreshFailure(
        in snapshot: ArkFileWeatherSnapshot
    ) -> Bool {
        snapshot.hourly.availability == .failed
            || snapshot.daily.availability == .failed
            || snapshot.alerts.availability == .failed
    }

    static func hasForecastRefreshFailure(
        in snapshot: ArkFileWeatherSnapshot
    ) -> Bool {
        snapshot.hourly.availability == .failed
            || snapshot.daily.availability == .failed
    }

    static func forecastFreshnessTitle(
        snapshot: ArkFileWeatherSnapshot,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> String {
        let freshness = aggregateCoreFreshness(in: snapshot, at: now)
        if freshness == .clockUncertain {
            return "Check Device Date & Time"
        }
        if hasCoreRefreshFailure(in: snapshot) {
            return "Briefing Update Was Incomplete"
        }
        switch freshness {
        case .fresh where connectivity == .online:
            return "Saved Forecast Is Up to Date"
        case .fresh:
            return "Offline Saved Forecast"
        case .aging:
            return "Saved Forecast Is Aging"
        case .stale:
            return "Saved Forecast Is Stale"
        case .expired:
            return "Saved Forecast Has Expired"
        case .historical:
            return "Historical Saved Forecast"
        case .clockUncertain:
            return "Check Device Date & Time"
        case nil:
            return "Forecast Timing Unavailable"
        }
    }

    static func savedOfflineExplanation(
        connectivity: ArkFileWeatherConnectivity
    ) -> String {
        switch connectivity {
        case .online:
            return "ArkFile saves this briefing on "
                + "\(ArkFileDeviceCopy.yourDevice) for offline "
                + "viewing. Update while connected to save the latest "
                + "available forecast."
        case .offline:
            return "This briefing is saved on "
                + "\(ArkFileDeviceCopy.yourDevice) for offline "
                + "viewing. Reconnect and update to save the latest "
                + "available forecast."
        case .unknown:
            return "ArkFile saves this briefing on "
                + "\(ArkFileDeviceCopy.yourDevice) for offline "
                + "viewing. When connected, update to save the latest "
                + "available forecast."
        }
    }

    static func homeHeadline(
        settings: ArkFileWeatherSettings,
        snapshot: ArkFileWeatherSnapshot?,
        connectivity: ArkFileWeatherConnectivity,
        isRefreshing: Bool,
        at now: Date,
        locale: Locale
    ) -> String {
        guard settings.savedLocation != nil else {
            return connectivity == .offline
                ? "Choose a place; connect once to save its forecast."
                : "Keep a weather briefing available offline."
        }
        guard let snapshot = matchingSnapshot(
            settings: settings,
            snapshot: snapshot
        ) else {
            if isRefreshing {
                return "Saving the first weather briefing…"
            }
            return connectivity == .offline
                ? "No forecast has been saved for this place yet."
                : "Ready to save weather for this place."
        }

        if snapshot.hourly.availability == .unsupported,
           snapshot.daily.availability == .unsupported {
            return "NWS forecasts are not available for this location."
        }

        if let alert = visibleAlerts(in: snapshot, at: now).first,
           (
               alert.isActive(at: now)
                   || alert.isUpcoming(at: now)
           ),
           snapshot.alerts.stamp != nil {
            let presentation = alertPresentation(
                for: alert,
                component: snapshot.alerts,
                connectivity: connectivity,
                at: now
            )
            if presentation.isUrgent,
               presentation.cacheNotice == nil {
                return "NWS alert: \(alert.event)"
            }
            if alert.isUpcoming(at: now) {
                return presentation.cacheNotice == nil
                    ? "Upcoming NWS alert: \(alert.event)"
                    : "Saved upcoming alert: \(alert.event)"
            }
            return "Saved alert may be outdated: \(alert.event)"
        }

        if let period = currentHourlyPeriod(in: snapshot, at: now) {
            let units = displayUnits(
                preference: settings.unitPreference,
                locale: locale
            )
            if let temperature = temperature(
                celsius: period.temperatureCelsius,
                units: units
            ) {
                return forecastHeadline(
                    "\(temperature) · \(period.summary)",
                    component: snapshot.hourly,
                    at: now
                )
            }
            return forecastHeadline(
                period.summary,
                component: snapshot.hourly,
                at: now
            )
        }
        return "Saved forecast is outside its forecast period."
    }

    static func homeStatus(
        settings: ArkFileWeatherSettings,
        snapshot: ArkFileWeatherSnapshot?,
        connectivity: ArkFileWeatherConnectivity,
        isRefreshing: Bool,
        at now: Date
    ) -> String {
        if isRefreshing {
            return matchingSnapshot(settings: settings, snapshot: snapshot) == nil
                ? "Connecting to NOAA"
                : "Updating; saved data stays available"
        }
        guard let snapshot = matchingSnapshot(
            settings: settings,
            snapshot: snapshot
        ) else {
            return connectivity == .offline ? "Offline" : "Tap to set up"
        }
        if snapshot.hourly.availability == .unsupported,
           snapshot.daily.availability == .unsupported {
            return "Choose another location"
        }
        if snapshot.alerts.availability == .failed {
            return failedComponentHomeStatus(
                name: "Alerts",
                stamp: snapshot.alerts.stamp,
                connectivity: connectivity,
                at: now
            )
        }
        if snapshot.hourly.availability == .failed
            || snapshot.daily.availability == .failed {
            return failedComponentHomeStatus(
                name: "Forecast",
                stamp: snapshot.hourly.stamp ?? snapshot.daily.stamp,
                connectivity: connectivity,
                at: now
            )
        }
        guard let stamp = homeReferenceStamp(in: snapshot, at: now) else {
            return connectivity == .offline ? "Offline" : "Tap to update"
        }
        let age = relativeAge(from: stamp.fetchedAt, to: now)
        return connectivity == .offline
            ? "Offline · saved \(age)"
            : "Saved on \(ArkFileDeviceCopy.thisDevice) \(age)"
    }

    static func freshnessMessage(
        snapshot: ArkFileWeatherSnapshot,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date,
        timeZoneID: String? = nil
    ) -> String {
        guard let stamp = coreReferenceStamp(in: snapshot, at: now) else {
            return "Saved forecast timing is unavailable. Conditions may have changed."
        }
        let freshness = ArkFileWeatherFreshnessSemantics.classify(
            stamp: stamp,
            at: now
        )
        let checked = timestamp(stamp.fetchedAt, timeZoneID: timeZoneID)
        switch freshness {
        case .clockUncertain:
            return "Forecast age is unavailable because the device date or time may be incorrect."
        case .fresh where connectivity == .online:
            return "Forecast last checked \(checked)."
        case .fresh:
            return "Offline—showing a forecast saved \(checked). Updates are unavailable."
        case .aging:
            return "Saved \(checked). This forecast is aging and conditions may have changed."
        case .stale:
            return "Last updated \(checked). This forecast is stale and conditions may have changed."
        case .expired:
            return "This saved forecast has expired. Reconnect to update it."
        case .historical:
            return "Historical saved forecast from \(checked). Do not treat it as current."
        }
    }

    static func planningHighlights(
        snapshot: ArkFileWeatherSnapshot,
        settings: ArkFileWeatherSettings,
        at now: Date,
        locale: Locale
    ) -> [ArkFileSavedWeatherPlanningHighlight] {
        let periods = futureHourlyPeriods(in: snapshot, at: now)
        guard !periods.isEmpty else { return [] }
        let units = displayUnits(
            preference: settings.unitPreference,
            locale: locale
        )
        var highlights: [ArkFileSavedWeatherPlanningHighlight] = []

        if let wetPeriod = periods.first(where: {
            ($0.precipitationProbabilityFraction ?? 0) >= 0.4
        }), let probability = probability(
            wetPeriod.precipitationProbabilityFraction
        ) {
            highlights.append(
                ArkFileSavedWeatherPlanningHighlight(
                    id: "precipitation-window",
                    systemImage: "drop.fill",
                    title: "Precipitation timing",
                    detail: "Saved chance reaches \(probability) around "
                        + time(wetPeriod.startsAt, timeZoneID: settings.savedLocation?.timeZoneIdentifier)
                        + "."
                )
            )
        }

        let temperatures = periods.compactMap(\.temperatureCelsius)
        if let low = temperatures.min(),
           let high = temperatures.max(),
           high - low >= 5,
           let lowText = temperature(celsius: low, units: units),
           let highText = temperature(celsius: high, units: units) {
            highlights.append(
                ArkFileSavedWeatherPlanningHighlight(
                    id: "temperature-range",
                    systemImage: "thermometer.medium",
                    title: "Temperature span",
                    detail: "Saved hourly temperatures range from \(lowText) to \(highText)."
                )
            )
        }

        if let strongestWind = periods.compactMap(\.windGustMetersPerSecond).max()
            ?? periods.compactMap(\.windSpeedMetersPerSecond).max(),
           strongestWind >= 10,
           let windText = windSpeed(
               metersPerSecond: strongestWind,
               units: units
           ) {
            highlights.append(
                ArkFileSavedWeatherPlanningHighlight(
                    id: "strongest-wind",
                    systemImage: "wind",
                    title: "Strongest saved wind",
                    detail: "About \(windText) in the next 24 hours."
                )
            )
        }

        let daily = futureDailyPeriods(in: snapshot, at: now)
        if daily.count >= 2,
           let change = nextDayChangeHighlight(
               from: daily[0],
               to: daily[1],
               units: units
           ) {
            highlights.append(change)
        }
        return highlights
    }

    private static func nextDayChangeHighlight(
        from first: ArkFileWeatherDailyPeriod,
        to second: ArkFileWeatherDailyPeriod,
        units: DisplayUnits
    ) -> ArkFileSavedWeatherPlanningHighlight? {
        var details: [String] = []

        if let firstHigh = first.maximumTemperatureCelsius,
           let secondHigh = second.maximumTemperatureCelsius,
           abs(secondHigh - firstHigh) >= 8,
           let firstText = temperature(celsius: firstHigh, units: units),
           let secondText = temperature(celsius: secondHigh, units: units) {
            details.append("saved high changes from \(firstText) to \(secondText)")
        }
        if let firstChance = first.precipitationProbabilityFraction,
           let secondChance = second.precipitationProbabilityFraction,
           secondChance >= 0.4,
           secondChance - firstChance >= 0.3,
           let chance = probability(secondChance) {
            details.append("saved precipitation chance rises to \(chance)")
        }
        if first.condition != second.condition {
            details.append(
                "summary shifts from \(first.summary) to \(second.summary)"
            )
        }

        guard !details.isEmpty else { return nil }
        let sentence = details.joined(separator: "; ")
        let capitalizedSentence =
            sentence.prefix(1).uppercased() + String(sentence.dropFirst())
        return ArkFileSavedWeatherPlanningHighlight(
            id: "next-day-change",
            systemImage: "arrow.left.arrow.right",
            title: "Next-day change",
            detail: capitalizedSentence + "."
        )
    }

    static func favoredCategory(
        _ distribution: ArkFileWeatherProbabilityDistribution
    ) -> String {
        let candidates = [
            ("Below normal", distribution.belowNormalFraction),
            ("Near normal", distribution.nearNormalFraction),
            ("Above normal", distribution.aboveNormalFraction)
        ].compactMap { name, value -> (String, Double)? in
            guard let value, value.isFinite else { return nil }
            return (name, value)
        }
        guard let favored = candidates.max(by: { $0.1 < $1.1 }) else {
            return "Probabilities unavailable"
        }
        if candidates.count == 3,
           let minimum = candidates.map(\.1).min(),
           let maximum = candidates.map(\.1).max(),
           maximum - minimum <= 0.01 {
            return "Equal chances"
        }
        let ordered = candidates.sorted { $0.1 > $1.1 }
        if ordered.count > 1,
           ordered[0].1 - ordered[1].1 <= 0.005 {
            return "No single category favored"
        }
        return "\(favored.0) favored (\(Int((min(1, max(0, favored.1)) * 100).rounded()))%)"
    }

    static func windDirection(degrees: Double?) -> String? {
        guard let degrees, degrees.isFinite else { return nil }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let labels = [
            "N", "NE", "E", "SE", "S", "SW", "W", "NW"
        ]
        let index = Int((positive / 45).rounded()) % labels.count
        return labels[index]
    }

    /// CPC validity ends are exclusive in ArkFile's normalized model. UI that
    /// presents an inclusive date range must step back into the covered range.
    static func inclusiveOutlookEnd(
        validFrom: Date,
        validUntil: Date
    ) -> Date {
        guard validUntil > validFrom else { return validUntil }
        return validUntil.addingTimeInterval(-1)
    }

    static func astronomyDay(
        in snapshot: ArkFileWeatherSnapshot,
        timeZoneID: String?,
        at now: Date
    ) -> ArkFileWeatherAstronomyDay? {
        let sortedDays = (snapshot.astronomy.value ?? []).sorted {
            $0.localDayStart < $1.localDayStart
        }
        guard !sortedDays.isEmpty else { return nil }
        guard let timeZoneID,
              let timeZone = TimeZone(identifier: timeZoneID) else {
            return sortedDays.first
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return sortedDays.first(where: {
            calendar.isDate($0.localDayStart, inSameDayAs: now)
        }) ?? sortedDays.first
    }

    static func astronomyDay(
        in snapshot: ArkFileWeatherSnapshot,
        timeZoneID: String?,
        matching date: Date
    ) -> ArkFileWeatherAstronomyDay? {
        guard let days = snapshot.astronomy.value,
              let timeZoneID,
              let timeZone = TimeZone(identifier: timeZoneID) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return days.first {
            calendar.isDate($0.localDayStart, inSameDayAs: date)
        }
    }

    static func moonPhaseName(_ phase: ArkFileWeatherMoonPhase) -> String {
        switch phase {
        case .new:
            return "New moon"
        case .waxingCrescent:
            return "Waxing crescent"
        case .firstQuarter:
            return "First quarter"
        case .waxingGibbous:
            return "Waxing gibbous"
        case .full:
            return "Full moon"
        case .waningGibbous:
            return "Waning gibbous"
        case .lastQuarter:
            return "Last quarter"
        case .waningCrescent:
            return "Waning crescent"
        }
    }

    static func moonIlluminationPercent(_ fraction: Double) -> Int? {
        guard fraction.isFinite else { return nil }
        return Int((min(1, max(0, fraction)) * 100).rounded())
    }

    static func daylightDuration(
        for day: ArkFileWeatherAstronomyDay
    ) -> TimeInterval? {
        guard let sunrise = day.sunrise,
              let sunset = day.sunset,
              sunset > sunrise else {
            return nil
        }
        return sunset.timeIntervalSince(sunrise)
    }

    static func daylightRemaining(
        for day: ArkFileWeatherAstronomyDay,
        at now: Date
    ) -> TimeInterval? {
        guard let sunrise = day.sunrise,
              let sunset = day.sunset,
              sunset > sunrise,
              now < sunset else {
            return nil
        }
        return sunset.timeIntervalSince(max(now, sunrise))
    }

    static func radioNoCoverageMessage(
        component: ArkFileWeatherComponent<
            [ArkFileWeatherRadioTransmitter]
        >,
        areas: [ArkFileWeatherRadioAreaIdentity]?,
        timeZoneID: String?
    ) -> String? {
        guard component.availability == .successfulEmpty,
              areas?.count == 1,
              let area = areas?.first,
              let catalogDate = component.stamp?.issuedAt else {
            return nil
        }
        return "NOAA's catalog lists no coverage assignment for SAME "
            + "\(area.sameCode) (\(area.displayName)) as of "
            + timestamp(catalogDate, timeZoneID: timeZoneID)
            + ". Directory assignments may change."
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        if minutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(minutes) min"
    }

    static func relativeAge(from date: Date, to now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval >= 0 else { return "at an uncertain time" }
        if interval < 60 {
            return "just now"
        }
        if interval < 3_600 {
            let minutes = max(1, Int(interval / 60))
            return "\(minutes) min ago"
        }
        if interval < 86_400 {
            let hours = max(1, Int(interval / 3_600))
            return "\(hours) hr ago"
        }
        let days = max(1, Int(interval / 86_400))
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    static func timestamp(
        _ date: Date,
        timeZoneID: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var suffix = ""
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }

    static func time(_ date: Date, timeZoneID: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var suffix = ""
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }

    static func dayAndDate(_ date: Date, timeZoneID: String?) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        var suffix = ""
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }

    static func compactDayAndDate(
        _ date: Date,
        timeZoneID: String?
    ) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        var suffix = ""
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }

    private static func severityRank(
        _ severity: ArkFileWeatherAlertSeverity
    ) -> Int {
        switch severity {
        case .extreme:
            return 5
        case .severe:
            return 4
        case .moderate:
            return 3
        case .minor:
            return 2
        case .unknown:
            return 1
        }
    }

    private static func alertTemporalRank(
        _ alert: ArkFileWeatherAlert,
        at now: Date
    ) -> Int {
        if alert.isActive(at: now) { return 2 }
        if alert.isUpcoming(at: now) { return 1 }
        return 0
    }

    private static func homeReferenceStamp(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> ArkFileWeatherComponentStamp? {
        if let firstAlert = visibleAlerts(in: snapshot, at: now).first,
           firstAlert.isActive(at: now) {
            return snapshot.alerts.stamp
        }
        return primaryStamp(in: snapshot)
    }

    private static func coreReferenceStamp(
        in snapshot: ArkFileWeatherSnapshot,
        at now: Date
    ) -> ArkFileWeatherComponentStamp? {
        // Alert checks deliberately age much faster than forecast products.
        // They have their own status and must not make a still-valid seven-day
        // forecast appear expired.
        let stamps = [
            snapshot.hourly.stamp,
            snapshot.daily.stamp
        ].compactMap { $0 }
        return stamps.max { lhs, rhs in
            let lhsFreshness = ArkFileWeatherFreshnessSemantics.classify(
                stamp: lhs,
                at: now
            )
            let rhsFreshness = ArkFileWeatherFreshnessSemantics.classify(
                stamp: rhs,
                at: now
            )
            let lhsRank = freshnessConservatismRank(lhsFreshness)
            let rhsRank = freshnessConservatismRank(rhsFreshness)
            if lhsRank == rhsRank {
                return lhs.fetchedAt > rhs.fetchedAt
            }
            return lhsRank < rhsRank
        }
    }

    private static func freshnessConservatismRank(
        _ freshness: ArkFileWeatherFreshness
    ) -> Int {
        switch freshness {
        case .fresh:
            return 0
        case .aging:
            return 1
        case .stale:
            return 2
        case .expired:
            return 3
        case .historical:
            return 4
        case .clockUncertain:
            return 5
        }
    }

    private static func failedComponentHomeStatus(
        name: String,
        stamp: ArkFileWeatherComponentStamp?,
        connectivity: ArkFileWeatherConnectivity,
        at now: Date
    ) -> String {
        let prefix = connectivity == .offline ? "Offline · " : ""
        guard let stamp else {
            return "\(prefix)\(name) not updated · current status unknown"
        }
        return "\(prefix)\(name) not updated · last checked "
            + relativeAge(from: stamp.fetchedAt, to: now)
    }

    private static func forecastHeadline(
        _ content: String,
        component: ArkFileWeatherComponent<[ArkFileWeatherHourlyPeriod]>,
        at now: Date
    ) -> String {
        guard let stamp = component.stamp else {
            return "Last saved forecast: \(content)"
        }
        let freshness = ArkFileWeatherFreshnessSemantics.classify(
            stamp: stamp,
            at: now
        )
        if component.availability == .failed {
            return "Last saved forecast: \(content)"
        }
        switch freshness {
        case .fresh, .aging:
            return content
        case .stale:
            return "Last saved forecast: \(content)"
        case .expired:
            return "Saved forecast expired: \(content)"
        case .historical:
            return "Historical saved forecast: \(content)"
        case .clockUncertain:
            return "Last saved forecast, age uncertain: \(content)"
        }
    }
}
#endif
