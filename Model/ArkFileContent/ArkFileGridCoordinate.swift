// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileUTMCoordinate: Equatable, Sendable {
    let zone: Int
    let band: String
    let easting: Double
    let northing: Double

    var formatted: String {
        "UTM \(zone)\(band) \(Int(easting.rounded())) \(Int(northing.rounded()))"
    }
}

enum ArkFileGridCoordinate {
    private static let semiMajorAxis = 6_378_137.0
    private static let flattening = 1.0 / 298.257_223_563
    private static let scaleFactor = 0.9996
    private static let falseEasting = 500_000.0
    private static let falseNorthing = 10_000_000.0
    private static let latitudeBands: [String] = [
        "C", "D", "E", "F", "G", "H", "J", "K", "L", "M",
        "N", "P", "Q", "R", "S", "T", "U", "V", "W", "X"
    ]
    private static let columnLetterSets: [[String]] = [
        ["A", "B", "C", "D", "E", "F", "G", "H"],
        ["J", "K", "L", "M", "N", "P", "Q", "R"],
        ["S", "T", "U", "V", "W", "X", "Y", "Z"]
    ]
    private static let rowLetters: [String] = [
        "A", "B", "C", "D", "E", "F", "G", "H", "J", "K",
        "L", "M", "N", "P", "Q", "R", "S", "T", "U", "V"
    ]

    static func utm(from coordinate: ArkFileMapCoordinate) -> ArkFileUTMCoordinate? {
        guard let band = latitudeBand(forLatitude: coordinate.latitude) else { return nil }
        let zone = zoneNumber(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let projected = projectToUTM(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            zone: zone
        )
        return ArkFileUTMCoordinate(
            zone: zone,
            band: band,
            easting: projected.easting,
            northing: projected.northing
        )
    }

    static func mgrsString(from coordinate: ArkFileMapCoordinate) -> String? {
        guard let utm = utm(from: coordinate) else { return nil }
        let eastingBand = Int(utm.easting / 100_000)
        guard (1...8).contains(eastingBand) else { return nil }
        let columnSet = columnLetterSets[(utm.zone - 1) % columnLetterSets.count]
        let column = columnSet[eastingBand - 1]

        let northingBand = Int(utm.northing / 100_000) % rowLetters.count
        let rowOffset = utm.zone.isMultiple(of: 2) ? 5 : 0
        let row = rowLetters[(northingBand + rowOffset) % rowLetters.count]

        let eastingRemainder = Int(utm.easting.rounded(.down)) % 100_000
        let northingRemainder = Int(utm.northing.rounded(.down)) % 100_000
        return "\(utm.zone)\(utm.band) \(column)\(row) \(String(format: "%05d", eastingRemainder)) \(String(format: "%05d", northingRemainder))"
    }

    static func detailText(for coordinate: ArkFileMapCoordinate) -> String {
        let utm = utm(from: coordinate)?.formatted
        let mgrs = mgrsString(from: coordinate).map { "MGRS \($0)" }
        return [utm, mgrs].compactMap { $0 }.joined(separator: "\n")
    }

    static func parseUTM(_ text: String) -> ArkFileParsedCoordinate? {
        parseUTMCoordinates(text).first
    }

    static func parseUTMCoordinates(_ text: String) -> [ArkFileParsedCoordinate] {
        let pattern = #"(?i)\b(?:UTM\s+)?([1-5]?\d|60)\s*([C-HJ-NP-X])\s+(\d{5,6}(?:\.\d+)?)\s+(\d{1,8}(?:\.\d+)?)\b"#
        return matches(pattern, in: text).compactMap(parseUTMMatch)
    }

    static func parseMGRS(_ text: String) -> ArkFileParsedCoordinate? {
        parseMGRSCoordinates(text).first
    }

    static func parseMGRSCoordinates(_ text: String) -> [ArkFileParsedCoordinate] {
        let pattern = #"(?i)\b(?:MGRS\s+)?([1-5]?\d|60)\s*([C-HJ-NP-X])\s*([A-HJ-NP-Z])\s*([A-HJ-NP-Z])\s*(\d{1,5}\s+\d{1,5}|\d{2,10})\b"#
        return matches(pattern, in: text).compactMap(parseMGRSMatch)
    }

    private static func parseUTMMatch(_ match: [String]) -> ArkFileParsedCoordinate? {
        guard match.count == 4,
              let zone = Int(match[0]),
              let easting = Double(match[2]),
              let northing = Double(match[3]) else { return nil }
        let band = match[1].uppercased()
        guard isValidZone(zone),
              latitudeBands.contains(band),
              easting >= 100_000,
              easting < 900_000,
              northing >= 0,
              northing <= falseNorthing else {
            return nil
        }
        let hemisphere: Hemisphere = isNorthernBand(band) ? .north : .south
        guard let coordinate = inverseUTM(
            zone: zone,
            easting: easting,
            northing: northing,
            hemisphere: hemisphere
        ), latitudeBand(forLatitude: coordinate.latitude) == band else {
            return nil
        }
        return ArkFileParsedCoordinate(
            name: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            sourceFormat: "UTM coordinates"
        )
    }

    private static func parseMGRSMatch(_ match: [String]) -> ArkFileParsedCoordinate? {
        guard match.count == 5,
              let zone = Int(match[0]) else { return nil }
        let band = match[1].uppercased()
        let column = match[2].uppercased()
        let row = match[3].uppercased()
        let digits = match[4].replacingOccurrences(of: " ", with: "")
        guard isValidZone(zone),
              latitudeBands.contains(band),
              digits.count >= 2,
              digits.count <= 10,
              digits.count.isMultiple(of: 2),
              let columnIndex = columnLetterSets[(zone - 1) % columnLetterSets.count].firstIndex(of: column),
              let rowIndex = rowLetters.firstIndex(of: row) else {
            return nil
        }

        let precision = digits.count / 2
        let split = digits.index(digits.startIndex, offsetBy: precision)
        guard let eastingDigits = Int(digits[..<split]),
              let northingDigits = Int(digits[split...]) else {
            return nil
        }

        let scale = pow(10.0, Double(5 - precision))
        let easting = Double((columnIndex + 1) * 100_000) + Double(eastingDigits) * scale
        let rowOffset = zone.isMultiple(of: 2) ? 5 : 0
        let northingBand = (rowIndex - rowOffset + rowLetters.count) % rowLetters.count
        var northing = Double(northingBand * 100_000) + Double(northingDigits) * scale
        let minimumNorthing = minimumNorthing(forBand: band, zone: zone)
        while northing < minimumNorthing {
            northing += 2_000_000
        }

        let hemisphere: Hemisphere = isNorthernBand(band) ? .north : .south
        guard let coordinate = inverseUTM(
            zone: zone,
            easting: easting,
            northing: northing,
            hemisphere: hemisphere
        ), latitudeBand(forLatitude: coordinate.latitude) == band else {
            return nil
        }
        return ArkFileParsedCoordinate(
            name: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            sourceFormat: "MGRS coordinates"
        )
    }

    private enum Hemisphere {
        case north
        case south
    }

    private static var eccentricitySquared: Double {
        flattening * (2 - flattening)
    }

    private static var eccentricityPrimeSquared: Double {
        eccentricitySquared / (1 - eccentricitySquared)
    }

    private static func isValidZone(_ zone: Int) -> Bool {
        (1...60).contains(zone)
    }

    private static func isNorthernBand(_ band: String) -> Bool {
        guard let first = band.unicodeScalars.first else {
            return true
        }
        return first.value >= UnicodeScalar("N").value
    }

    private static func latitudeBand(forLatitude latitude: Double) -> String? {
        guard latitude >= -80, latitude <= 84 else { return nil }
        let rawIndex = Int(floor((latitude + 80) / 8))
        let index = min(max(rawIndex, 0), latitudeBands.count - 1)
        return latitudeBands[index]
    }

    private static func minimumLatitude(forBand band: String) -> Double {
        guard let index = latitudeBands.firstIndex(of: band) else { return 0 }
        return index == latitudeBands.count - 1 ? 72 : -80 + Double(index * 8)
    }

    private static func minimumNorthing(forBand band: String, zone: Int) -> Double {
        let projected = projectToUTM(
            latitude: minimumLatitude(forBand: band),
            longitude: centralMeridian(forZone: zone),
            zone: zone
        )
        return projected.northing
    }

    private static func zoneNumber(latitude: Double, longitude: Double) -> Int {
        let normalizedLongitude = normalizeLongitude(longitude)
        if latitude >= 56, latitude < 64, normalizedLongitude >= 3, normalizedLongitude < 12 {
            return 32
        }
        if latitude >= 72, latitude < 84 {
            if normalizedLongitude >= 0, normalizedLongitude < 9 { return 31 }
            if normalizedLongitude >= 9, normalizedLongitude < 21 { return 33 }
            if normalizedLongitude >= 21, normalizedLongitude < 33 { return 35 }
            if normalizedLongitude >= 33, normalizedLongitude < 42 { return 37 }
        }
        let rawZone = Int(floor((normalizedLongitude + 180) / 6)) + 1
        return min(max(rawZone, 1), 60)
    }

    private static func normalizeLongitude(_ longitude: Double) -> Double {
        var value = longitude
        while value < -180 { value += 360 }
        while value >= 180 { value -= 360 }
        return value
    }

    private static func centralMeridian(forZone zone: Int) -> Double {
        Double((zone - 1) * 6 - 180 + 3)
    }

    private static func projectToUTM(latitude: Double, longitude: Double, zone: Int) -> (easting: Double, northing: Double) {
        let latRad = latitude * .pi / 180
        let lonRad = normalizeLongitude(longitude) * .pi / 180
        let lonOriginRad = centralMeridian(forZone: zone) * .pi / 180
        let eccSquared = eccentricitySquared
        let eccPrimeSquared = eccentricityPrimeSquared

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let tanLat = tan(latRad)
        let n = semiMajorAxis / sqrt(1 - eccSquared * sinLat * sinLat)
        let t = tanLat * tanLat
        let c = eccPrimeSquared * cosLat * cosLat
        let a = cosLat * (lonRad - lonOriginRad)
        let m = semiMajorAxis * (
            (1 - eccSquared / 4 - 3 * pow(eccSquared, 2) / 64 - 5 * pow(eccSquared, 3) / 256) * latRad
            - (3 * eccSquared / 8 + 3 * pow(eccSquared, 2) / 32 + 45 * pow(eccSquared, 3) / 1024) * sin(2 * latRad)
            + (15 * pow(eccSquared, 2) / 256 + 45 * pow(eccSquared, 3) / 1024) * sin(4 * latRad)
            - (35 * pow(eccSquared, 3) / 3072) * sin(6 * latRad)
        )

        let easting = scaleFactor * n * (
            a
            + (1 - t + c) * pow(a, 3) / 6
            + (5 - 18 * t + t * t + 72 * c - 58 * eccPrimeSquared) * pow(a, 5) / 120
        ) + falseEasting
        var northing = scaleFactor * (
            m + n * tanLat * (
                pow(a, 2) / 2
                + (5 - t + 9 * c + 4 * c * c) * pow(a, 4) / 24
                + (61 - 58 * t + t * t + 600 * c - 330 * eccPrimeSquared) * pow(a, 6) / 720
            )
        )
        if latitude < 0 {
            northing += falseNorthing
        }
        return (easting, northing)
    }

    private static func inverseUTM(
        zone: Int,
        easting: Double,
        northing: Double,
        hemisphere: Hemisphere
    ) -> ArkFileMapCoordinate? {
        guard isValidZone(zone),
              easting >= 100_000,
              easting < 900_000,
              northing >= 0,
              northing <= falseNorthing else {
            return nil
        }

        let eccSquared = eccentricitySquared
        let eccPrimeSquared = eccentricityPrimeSquared
        var y = northing
        if hemisphere == .south {
            y -= falseNorthing
        }
        let x = easting - falseEasting
        let m = y / scaleFactor
        let mu = m / (semiMajorAxis * (1 - eccSquared / 4 - 3 * pow(eccSquared, 2) / 64 - 5 * pow(eccSquared, 3) / 256))
        let e1 = (1 - sqrt(1 - eccSquared)) / (1 + sqrt(1 - eccSquared))
        let phi1Rad = mu
            + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
            + (21 * pow(e1, 2) / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
            + (151 * pow(e1, 3) / 96) * sin(6 * mu)
            + (1097 * pow(e1, 4) / 512) * sin(8 * mu)

        let sinPhi1 = sin(phi1Rad)
        let cosPhi1 = cos(phi1Rad)
        let tanPhi1 = tan(phi1Rad)
        let n1 = semiMajorAxis / sqrt(1 - eccSquared * sinPhi1 * sinPhi1)
        let t1 = tanPhi1 * tanPhi1
        let c1 = eccPrimeSquared * cosPhi1 * cosPhi1
        let r1 = semiMajorAxis * (1 - eccSquared) / pow(1 - eccSquared * sinPhi1 * sinPhi1, 1.5)
        let d = x / (n1 * scaleFactor)

        let latRad = phi1Rad - (n1 * tanPhi1 / r1) * (
            pow(d, 2) / 2
            - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * eccPrimeSquared) * pow(d, 4) / 24
            + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * eccPrimeSquared - 3 * c1 * c1) * pow(d, 6) / 720
        )
        let lonRad = centralMeridian(forZone: zone) * .pi / 180 + (
            d
            - (1 + 2 * t1 + c1) * pow(d, 3) / 6
            + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * eccPrimeSquared + 24 * t1 * t1) * pow(d, 5) / 120
        ) / cosPhi1

        let latitude = latRad * 180 / .pi
        let longitude = normalizeLongitude(lonRad * 180 / .pi)
        guard ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        return ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func matches(_ pattern: String, in input: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: input) else {
                    return ""
                }
                return String(input[swiftRange])
            }
        }
    }
}
