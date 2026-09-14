// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileWeatherAstronomyError: Error, Equatable, Sendable {
    case invalidCoordinate
    case missingOrInvalidTimeZone
    case invalidDayCount
    case calendarFailure
}

/// Produces a bounded, fully offline astronomy summary for the saved location.
///
/// Solar events use the public NOAA solar-calculator equations. They are
/// estimates, not authoritative observations: terrain, buildings, elevation,
/// and local atmospheric conditions can move the visible event. Moon phase is
/// an approximate synodic-cycle calculation; moonrise and moonset intentionally
/// remain nil until ArkFile has a vetted lunar-position implementation.
enum ArkFileWeatherAstronomyCalculator {
    private static let standardSolarZenithDegrees = 90.833
    private static let civilTwilightZenithDegrees = 96.0
    private static let synodicMonthDays = 29.530588853
    private static let knownNewMoon = Date(
        timeIntervalSince1970: 947_182_440
    ) // 2000-01-06T18:14:00Z

    static func day(
        containing date: Date,
        for location: ArkFileWeatherSavedLocation
    ) throws -> ArkFileWeatherAstronomyDay {
        guard let identifier = location.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else {
            throw ArkFileWeatherAstronomyError.missingOrInvalidTimeZone
        }
        return try day(
            containing: date,
            coordinate: location.coordinate,
            timeZone: timeZone
        )
    }

    static func day(
        containing date: Date,
        coordinate: ArkFileWeatherCoordinate,
        timeZone: TimeZone
    ) throws -> ArkFileWeatherAstronomyDay {
        guard coordinate.isValid else {
            throw ArkFileWeatherAstronomyError.invalidCoordinate
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let localDayStart = calendar.startOfDay(for: date)
        guard let followingDayStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: localDayStart
        ) else {
            throw ArkFileWeatherAstronomyError.calendarFailure
        }
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: localDayStart
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            throw ArkFileWeatherAstronomyError.calendarFailure
        }

        let julianDay = julianDayAtUTCMidnight(
            year: year,
            month: month,
            day: day
        )
        let sunrise = solarEvent(
            julianDay: julianDay,
            coordinate: coordinate,
            zenithDegrees: standardSolarZenithDegrees,
            isMorning: true,
            year: year,
            month: month,
            day: day,
            localDayStart: localDayStart,
            followingDayStart: followingDayStart
        )
        let sunset = solarEvent(
            julianDay: julianDay,
            coordinate: coordinate,
            zenithDegrees: standardSolarZenithDegrees,
            isMorning: false,
            year: year,
            month: month,
            day: day,
            localDayStart: localDayStart,
            followingDayStart: followingDayStart
        )
        let civilDawn = solarEvent(
            julianDay: julianDay,
            coordinate: coordinate,
            zenithDegrees: civilTwilightZenithDegrees,
            isMorning: true,
            year: year,
            month: month,
            day: day,
            localDayStart: localDayStart,
            followingDayStart: followingDayStart
        )
        let civilDusk = solarEvent(
            julianDay: julianDay,
            coordinate: coordinate,
            zenithDegrees: civilTwilightZenithDegrees,
            isMorning: false,
            year: year,
            month: month,
            day: day,
            localDayStart: localDayStart,
            followingDayStart: followingDayStart
        )

        let localMidpoint = localDayStart.addingTimeInterval(
            followingDayStart.timeIntervalSince(localDayStart) / 2
        )
        let moon = moonSummary(at: localMidpoint)
        return ArkFileWeatherAstronomyDay(
            localDayStart: localDayStart,
            sunrise: sunrise,
            sunset: sunset,
            civilDawn: civilDawn,
            civilDusk: civilDusk,
            moonrise: nil,
            moonset: nil,
            moonPhase: moon.phase,
            moonIlluminationFraction: moon.illuminationFraction
        )
    }

    static func days(
        startingAt date: Date,
        count: Int,
        for location: ArkFileWeatherSavedLocation
    ) throws -> [ArkFileWeatherAstronomyDay] {
        guard count >= 0 else {
            throw ArkFileWeatherAstronomyError.invalidDayCount
        }
        guard let identifier = location.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: identifier) else {
            throw ArkFileWeatherAstronomyError.missingOrInvalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let firstDay = calendar.startOfDay(for: date)

        return try (0 ..< count).map { offset in
            guard let dateForDay = calendar.date(
                byAdding: .day,
                value: offset,
                to: firstDay
            ) else {
                throw ArkFileWeatherAstronomyError.calendarFailure
            }
            return try day(
                containing: dateForDay,
                coordinate: location.coordinate,
                timeZone: timeZone
            )
        }
    }

    private static func solarEvent(
        julianDay: Double,
        coordinate: ArkFileWeatherCoordinate,
        zenithDegrees: Double,
        isMorning: Bool,
        year: Int,
        month: Int,
        day: Int,
        localDayStart: Date,
        followingDayStart: Date
    ) -> Date? {
        guard abs(coordinate.latitude) < 90,
              let firstEstimate = eventUTCMinutes(
                julianDay: julianDay,
                latitudeDegrees: coordinate.latitude,
                longitudeDegrees: coordinate.longitude,
                zenithDegrees: zenithDegrees,
                isMorning: isMorning
              ),
              let refinedEstimate = eventUTCMinutes(
                julianDay: julianDay + firstEstimate / 1_440,
                latitudeDegrees: coordinate.latitude,
                longitudeDegrees: coordinate.longitude,
                zenithDegrees: zenithDegrees,
                isMorning: isMorning
              ) else {
            // A nil result is intentional for polar day/night or exact poles.
            return nil
        }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = utcCalendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let utcMidnight = utcCalendar.date(from: components) else {
            return nil
        }
        let rawEvent = utcMidnight.addingTimeInterval(
            refinedEstimate * 60
        )
        let localMidpoint = localDayStart.addingTimeInterval(
            followingDayStart.timeIntervalSince(localDayStart) / 2
        )
        return (-2 ... 2)
            .map {
                rawEvent.addingTimeInterval(Double($0) * 24 * 60 * 60)
            }
            .filter {
                $0 >= localDayStart && $0 < followingDayStart
            }
            .min {
                abs($0.timeIntervalSince(localMidpoint))
                    < abs($1.timeIntervalSince(localMidpoint))
            }
    }

    private static func eventUTCMinutes(
        julianDay: Double,
        latitudeDegrees: Double,
        longitudeDegrees: Double,
        zenithDegrees: Double,
        isMorning: Bool
    ) -> Double? {
        let century = julianCentury(for: julianDay)
        let equationOfTime = equationOfTimeMinutes(for: century)
        let declination = solarDeclinationDegrees(for: century)
        let latitude = degreesToRadians(latitudeDegrees)
        let declinationRadians = degreesToRadians(declination)
        let denominator = cos(latitude) * cos(declinationRadians)
        guard denominator.isFinite, abs(denominator) > 1e-12 else {
            return nil
        }

        let cosine = (
            cos(degreesToRadians(zenithDegrees)) / denominator
        ) - tan(latitude) * tan(declinationRadians)
        guard cosine.isFinite, (-1 ... 1).contains(cosine) else {
            return nil
        }

        var hourAngle = acos(cosine)
        if !isMorning {
            hourAngle = -hourAngle
        }
        let deltaDegrees = longitudeDegrees + radiansToDegrees(hourAngle)
        return 720 - (4 * deltaDegrees) - equationOfTime
    }

    private static func moonSummary(
        at date: Date
    ) -> (phase: ArkFileWeatherMoonPhase, illuminationFraction: Double) {
        let elapsedDays = date.timeIntervalSince(knownNewMoon) / 86_400
        var cycleDay = elapsedDays.truncatingRemainder(
            dividingBy: synodicMonthDays
        )
        if cycleDay < 0 {
            cycleDay += synodicMonthDays
        }
        let fraction = cycleDay / synodicMonthDays
        let illumination = (1 - cos(2 * .pi * fraction)) / 2
        let phaseIndex = Int(floor((fraction * 8) + 0.5)) % 8
        let phase: ArkFileWeatherMoonPhase = switch phaseIndex {
        case 0: .new
        case 1: .waxingCrescent
        case 2: .firstQuarter
        case 3: .waxingGibbous
        case 4: .full
        case 5: .waningGibbous
        case 6: .lastQuarter
        default: .waningCrescent
        }
        return (phase, min(1, max(0, illumination)))
    }

    private static func julianDayAtUTCMidnight(
        year: Int,
        month: Int,
        day: Int
    ) -> Double {
        var adjustedYear = year
        var adjustedMonth = month
        if adjustedMonth <= 2 {
            adjustedYear -= 1
            adjustedMonth += 12
        }
        let century = floor(Double(adjustedYear) / 100)
        let correction = 2 - century + floor(century / 4)
        return floor(365.25 * Double(adjustedYear + 4_716))
            + floor(30.6001 * Double(adjustedMonth + 1))
            + Double(day)
            + correction
            - 1_524.5
    }

    private static func julianCentury(for julianDay: Double) -> Double {
        (julianDay - 2_451_545) / 36_525
    }

    private static func geometricMeanLongitudeDegrees(
        for century: Double
    ) -> Double {
        normalizedDegrees(
            280.46646
                + century * (36_000.76983 + century * 0.0003032)
        )
    }

    private static func geometricMeanAnomalyDegrees(
        for century: Double
    ) -> Double {
        357.52911
            + century * (35_999.05029 - 0.0001537 * century)
    }

    private static func earthOrbitEccentricity(for century: Double) -> Double {
        0.016708634
            - century * (0.000042037 + 0.0000001267 * century)
    }

    private static func sunEquationOfCenterDegrees(
        for century: Double
    ) -> Double {
        let anomaly = degreesToRadians(
            geometricMeanAnomalyDegrees(for: century)
        )
        return sin(anomaly) * (
            1.914602 - century * (0.004817 + 0.000014 * century)
        )
            + sin(2 * anomaly) * (
                0.019993 - 0.000101 * century
            )
            + sin(3 * anomaly) * 0.000289
    }

    private static func apparentSolarLongitudeDegrees(
        for century: Double
    ) -> Double {
        let trueLongitude = geometricMeanLongitudeDegrees(for: century)
            + sunEquationOfCenterDegrees(for: century)
        let omega = 125.04 - 1_934.136 * century
        return trueLongitude
            - 0.00569
            - 0.00478 * sin(degreesToRadians(omega))
    }

    private static func meanObliquityDegrees(for century: Double) -> Double {
        let seconds = 21.448
            - century * (
                46.815
                    + century * (0.00059 - century * 0.001813)
            )
        return 23 + (26 + seconds / 60) / 60
    }

    private static func correctedObliquityDegrees(
        for century: Double
    ) -> Double {
        let omega = 125.04 - 1_934.136 * century
        return meanObliquityDegrees(for: century)
            + 0.00256 * cos(degreesToRadians(omega))
    }

    private static func solarDeclinationDegrees(
        for century: Double
    ) -> Double {
        let obliquity = degreesToRadians(
            correctedObliquityDegrees(for: century)
        )
        let apparentLongitude = degreesToRadians(
            apparentSolarLongitudeDegrees(for: century)
        )
        return radiansToDegrees(
            asin(sin(obliquity) * sin(apparentLongitude))
        )
    }

    private static func equationOfTimeMinutes(for century: Double) -> Double {
        let obliquity = degreesToRadians(
            correctedObliquityDegrees(for: century)
        )
        let longitude = degreesToRadians(
            geometricMeanLongitudeDegrees(for: century)
        )
        let anomaly = degreesToRadians(
            geometricMeanAnomalyDegrees(for: century)
        )
        let eccentricity = earthOrbitEccentricity(for: century)
        let y = pow(tan(obliquity / 2), 2)
        let result = y * sin(2 * longitude)
            - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * longitude)
            - 0.5 * pow(y, 2) * sin(4 * longitude)
            - 1.25 * pow(eccentricity, 2) * sin(2 * anomaly)
        return 4 * radiansToDegrees(result)
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result < 0 {
            result += 360
        }
        return result
    }

    private static func degreesToRadians(_ value: Double) -> Double {
        value * .pi / 180
    }

    private static func radiansToDegrees(_ value: Double) -> Double {
        value * 180 / .pi
    }
}
