// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// NOAA/NWS heat-index and wind-chill equations, calculated only inside their
/// published input ranges. A nil result means the air temperature is the more
/// appropriate display; the value is an estimate, not a provider observation.
enum ArkFileWeatherThermalIndex {
    static func apparentTemperatureCelsius(
        temperatureCelsius: Double?,
        relativeHumidityFraction: Double?,
        windSpeedMetersPerSecond: Double?
    ) -> Double? {
        guard let temperatureCelsius,
              temperatureCelsius.isFinite else {
            return nil
        }
        let fahrenheit = (temperatureCelsius * 9 / 5) + 32

        if fahrenheit <= 50,
           let windSpeedMetersPerSecond,
           windSpeedMetersPerSecond.isFinite {
            let milesPerHour = windSpeedMetersPerSecond * 2.236_936_292_1
            if milesPerHour > 3 {
                let windFactor = pow(milesPerHour, 0.16)
                let windChill = 35.74
                    + (0.6215 * fahrenheit)
                    - (35.75 * windFactor)
                    + (0.4275 * fahrenheit * windFactor)
                return boundedCelsius(fromFahrenheit: windChill)
            }
        }

        guard fahrenheit >= 80,
              let relativeHumidityFraction,
              relativeHumidityFraction.isFinite,
              (0 ... 1).contains(relativeHumidityFraction) else {
            return nil
        }
        let humidity = relativeHumidityFraction * 100
        let simple = 0.5 * (
            fahrenheit
                + 61
                + ((fahrenheit - 68) * 1.2)
                + (humidity * 0.094)
        )
        guard (simple + fahrenheit) / 2 >= 80 else {
            return nil
        }

        var heatIndex = -42.379
            + (2.049_015_23 * fahrenheit)
            + (10.143_331_27 * humidity)
            - (0.224_755_41 * fahrenheit * humidity)
            - (0.006_837_83 * fahrenheit * fahrenheit)
            - (0.054_817_17 * humidity * humidity)
            + (
                0.001_228_74
                    * fahrenheit
                    * fahrenheit
                    * humidity
            )
            + (
                0.000_852_82
                    * fahrenheit
                    * humidity
                    * humidity
            )
            - (
                0.000_001_99
                    * fahrenheit
                    * fahrenheit
                    * humidity
                    * humidity
            )

        if humidity < 13, (80 ... 112).contains(fahrenheit) {
            let adjustment = ((13 - humidity) / 4)
                * sqrt(
                    max(
                        0,
                        (17 - abs(fahrenheit - 95)) / 17
                    )
                )
            heatIndex -= adjustment
        } else if humidity > 85, (80 ... 87).contains(fahrenheit) {
            heatIndex += ((humidity - 85) / 10)
                * ((87 - fahrenheit) / 5)
        }
        return boundedCelsius(fromFahrenheit: heatIndex)
    }

    private static func boundedCelsius(
        fromFahrenheit fahrenheit: Double
    ) -> Double? {
        let celsius = (fahrenheit - 32) * 5 / 9
        guard celsius.isFinite, (-100 ... 100).contains(celsius) else {
            return nil
        }
        return celsius
    }
}
