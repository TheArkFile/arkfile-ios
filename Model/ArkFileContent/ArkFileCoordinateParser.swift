// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileParsedCoordinate: Equatable, Identifiable, Sendable {
    var name: String?
    var latitude: Double
    var longitude: Double
    var sourceFormat: String

    var id: String {
        "\(ArkFileMapLocationLink.coordinateString(latitude)),\(ArkFileMapLocationLink.coordinateString(longitude))-\(sourceFormat)-\(name ?? "")"
    }

    var coordinate: ArkFileMapCoordinate {
        ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
    }
}

enum ArkFileCoordinateParser {
    static func parse(_ text: String) -> [ArkFileParsedCoordinate] {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }

        var results: [ArkFileParsedCoordinate] = []
        appendURLCoordinates(from: input, to: &results)
        appendGridCoordinates(from: input, to: &results)
        appendDMSCoordinates(from: input, to: &results)
        appendDecimalCoordinates(from: input, to: &results)
        return results
    }

    private static func appendURLCoordinates(from input: String, to results: inout [ArkFileParsedCoordinate]) {
        for token in urlTokens(in: input) {
            guard let url = URL(string: token) else { continue }
            if let link = ArkFileMapLocationLink.parse(url) {
                appendUnique(
                    ArkFileParsedCoordinate(
                        name: link.name,
                        latitude: link.latitude,
                        longitude: link.longitude,
                        sourceFormat: "ArkFile link"
                    ),
                    to: &results
                )
                continue
            }
            if let coordinate = parseGeoURL(url) {
                appendUnique(coordinate, to: &results)
                continue
            }
            if let coordinate = parseMapURL(url) {
                appendUnique(coordinate, to: &results)
            }
        }
    }

    private static func parseGeoURL(_ url: URL) -> ArkFileParsedCoordinate? {
        guard url.scheme?.caseInsensitiveCompare("geo") == .orderedSame else { return nil }
        let raw = url.absoluteString.dropFirst("geo:".count)
        let coordinatePart = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? String(raw)
        guard let (latitude, longitude) = parseDecimalPair(coordinatePart) else { return nil }
        return ArkFileParsedCoordinate(
            name: nil,
            latitude: latitude,
            longitude: longitude,
            sourceFormat: "geo URI"
        )
    }

    private static func parseMapURL(_ url: URL) -> ArkFileParsedCoordinate? {
        let host = (url.host ?? "").lowercased()
        let absolute = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if host.contains("maps.apple.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            let name = queryValue("q", in: items).flatMap { value -> String? in
                parseDecimalPair(value) == nil ? ArkFileMapLocationLink.sanitizedName(value) : nil
            }
            for key in ["ll", "coordinate", "q"] {
                guard let value = queryValue(key, in: items),
                      let (latitude, longitude) = parseDecimalPair(value) else {
                    continue
                }
                return ArkFileParsedCoordinate(
                    name: name,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: "Apple Maps URL"
                )
            }
        }
        if host.contains("google.") || absolute.contains("google.com/maps") {
            if let match = firstMatch(
                #"(?:@|!3d)([-+]?\d{1,2}(?:\.\d+)?)(?:,|!4d)([-+]?\d{1,3}(?:\.\d+)?)"#,
                in: absolute
            ), let latitude = Double(match[0]), let longitude = Double(match[1]),
               ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) {
                return ArkFileParsedCoordinate(
                    name: nil,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: "Google Maps URL"
                )
            }
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let value = queryValue("q", in: components.queryItems ?? []),
               let (latitude, longitude) = parseDecimalPair(value) {
                return ArkFileParsedCoordinate(
                    name: nil,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: "Google Maps URL"
                )
            }
        }
        return nil
    }

    private static func appendDecimalCoordinates(from input: String, to results: inout [ArkFileParsedCoordinate]) {
        let commaPattern = #"(?<![\d.])([-+]?(?:[0-8]?\d(?:\.\d+)?|90(?:\.0+)?))\s*[,;]\s*([-+]?(?:[01]?\d\d?(?:\.\d+)?|180(?:\.0+)?))(?![\d.])"#
        appendDecimalMatches(pattern: commaPattern, input: input, sourceFormat: "Decimal degrees", to: &results)

        let spacedPattern = #"(?<![\d.])([-+]?(?:[0-8]?\d\.\d+|90\.0+))\s+([-+]?(?:[01]?\d\d?\.\d+|180\.0+))(?![\d.])"#
        appendDecimalMatches(pattern: spacedPattern, input: input, sourceFormat: "Decimal degrees", to: &results)
    }

    private static func appendGridCoordinates(from input: String, to results: inout [ArkFileParsedCoordinate]) {
        for coordinate in ArkFileGridCoordinate.parseMGRSCoordinates(input) {
            appendUnique(coordinate, to: &results)
        }
        for coordinate in ArkFileGridCoordinate.parseUTMCoordinates(input) {
            appendUnique(coordinate, to: &results)
        }
    }

    private static func appendDecimalMatches(
        pattern: String,
        input: String,
        sourceFormat: String,
        to results: inout [ArkFileParsedCoordinate]
    ) {
        for match in matches(pattern, in: input) where match.count == 2 {
            guard let latitude = Double(match[0]),
                  let longitude = Double(match[1]),
                  ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
                continue
            }
            appendUnique(
                ArkFileParsedCoordinate(
                    name: nil,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: sourceFormat
                ),
                to: &results
            )
        }
    }

    private static func appendDMSCoordinates(from input: String, to results: inout [ArkFileParsedCoordinate]) {
        let suffixPattern = #"(?i)(\d{1,2})[°\s]+(\d{1,2}(?:\.\d+)?)(?:['’\s]+(\d{1,2}(?:\.\d+)?))?\s*(?:"|”)?\s*([NS])\s+(\d{1,3})[°\s]+(\d{1,2}(?:\.\d+)?)(?:['’\s]+(\d{1,2}(?:\.\d+)?))?\s*(?:"|”)?\s*([EW])"#
        for match in matches(suffixPattern, in: input) where match.count == 8 {
            guard let latitude = coordinateValue(
                degrees: match[0],
                minutes: match[1],
                seconds: match[2],
                hemisphere: match[3]
            ), let longitude = coordinateValue(
                degrees: match[4],
                minutes: match[5],
                seconds: match[6],
                hemisphere: match[7]
            ), ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
                continue
            }
            appendUnique(
                ArkFileParsedCoordinate(
                    name: nil,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: "DMS coordinates"
                ),
                to: &results
            )
        }

        let prefixPattern = #"(?i)([NS])\s*(\d{1,2})\s+(\d{1,2}(?:\.\d+)?)\s+([EW])\s*(\d{1,3})\s+(\d{1,2}(?:\.\d+)?)"#
        for match in matches(prefixPattern, in: input) where match.count == 6 {
            guard let latitude = coordinateValue(
                degrees: match[1],
                minutes: match[2],
                seconds: nil,
                hemisphere: match[0]
            ), let longitude = coordinateValue(
                degrees: match[4],
                minutes: match[5],
                seconds: nil,
                hemisphere: match[3]
            ), ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
                continue
            }
            appendUnique(
                ArkFileParsedCoordinate(
                    name: nil,
                    latitude: latitude,
                    longitude: longitude,
                    sourceFormat: "Degrees decimal minutes"
                ),
                to: &results
            )
        }
    }

    private static func coordinateValue(
        degrees: String,
        minutes: String,
        seconds: String?,
        hemisphere: String
    ) -> Double? {
        guard let degreesValue = Double(degrees),
              let minutesValue = Double(minutes),
              minutesValue >= 0,
              minutesValue < 60 else {
            return nil
        }
        let secondsValue = Double(seconds ?? "0") ?? 0
        guard secondsValue >= 0, secondsValue < 60 else { return nil }
        var value = degreesValue + minutesValue / 60 + secondsValue / 3600
        if hemisphere.caseInsensitiveCompare("S") == .orderedSame ||
            hemisphere.caseInsensitiveCompare("W") == .orderedSame {
            value *= -1
        }
        return value
    }

    private static func parseDecimalPair(_ text: String) -> (Double, Double)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^\s*([-+]?\d{1,2}(?:\.\d+)?)\s*[,;]\s*([-+]?\d{1,3}(?:\.\d+)?)\s*$"#,
            #"^\s*([-+]?\d{1,2}(?:\.\d+)?)\s+([-+]?\d{1,3}(?:\.\d+)?)\s*$"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: trimmed),
                  let latitude = Double(match[0]),
                  let longitude = Double(match[1]),
                  ArkFileMapLocationLink.isValid(latitude: latitude, longitude: longitude) else {
                continue
            }
            return (latitude, longitude)
        }
        return nil
    }

    private static func appendUnique(_ coordinate: ArkFileParsedCoordinate, to results: inout [ArkFileParsedCoordinate]) {
        guard ArkFileMapLocationLink.isValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        let alreadyExists = results.contains {
            abs($0.latitude - coordinate.latitude) < 0.000001 &&
                abs($0.longitude - coordinate.longitude) < 0.000001
        }
        if !alreadyExists {
            results.append(coordinate)
        }
    }

    private static func queryValue(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func urlTokens(in input: String) -> [String] {
        matches(#"(?i)(\b(?:arkfile://|geo:|https?://)\S+)"#, in: input)
            .compactMap(\.first)
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r<>[]{}()\"'.,"))
            }
    }

    private static func firstMatch(_ pattern: String, in input: String) -> [String]? {
        matches(pattern, in: input).first
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
