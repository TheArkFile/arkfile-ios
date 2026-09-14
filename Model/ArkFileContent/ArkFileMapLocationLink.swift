// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

extension Notification.Name {
    static let arkFileOpenMapLocation = Notification.Name("arkFileOpenMapLocation")
}

struct ArkFileMapLocationLink: Equatable, Sendable {
    static let maximumNameLength = 80
    private static let universalLinkHosts: Set<String> = ["thearkfile.com", "www.thearkfile.com"]

    var name: String?
    var latitude: Double
    var longitude: Double
    var kind: ArkFileMapWaypointKind?

    var coordinate: ArkFileMapCoordinate {
        ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
    }

    var url: URL {
        universalURL
    }

    var customSchemeURL: URL {
        var components = URLComponents()
        components.scheme = "arkfile"
        components.host = "map"
        components.queryItems = queryItems
        return components.url ?? URL(string: "arkfile://map")!
    }

    var universalURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "thearkfile.com"
        components.path = "/l"
        components.queryItems = queryItems
        return components.url ?? customSchemeURL
    }

    private var queryItems: [URLQueryItem] {
        var queryItems = [
            URLQueryItem(name: "lat", value: Self.coordinateString(latitude)),
            URLQueryItem(name: "lon", value: Self.coordinateString(longitude))
        ]
        if let name = Self.sanitizedName(name) {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }
        if let kind {
            queryItems.append(URLQueryItem(name: "kind", value: kind.rawValue))
        }
        return queryItems
    }

    var displayTitle: String {
        let title = Self.sanitizedName(name) ?? "Waypoint"
        guard let kind else { return title }
        return "\(title) · \(kind.displayName)"
    }

    var shareMessage: String {
        [
            displayTitle,
            "\(Self.coordinateString(latitude)), \(Self.coordinateString(longitude))",
            "Open in ArkFile: \(url.absoluteString)",
            "Apple Maps: \(appleMapsURL.absoluteString)"
        ].joined(separator: "\n")
    }

    private var appleMapsURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(Self.coordinateString(latitude)),\(Self.coordinateString(longitude))"),
            URLQueryItem(name: "q", value: displayTitle)
        ]
        return components.url ?? URL(string: "https://maps.apple.com/")!
    }

    static func parse(_ url: URL) -> ArkFileMapLocationLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isSupportedLocationURL(url, components: components) else {
            return nil
        }
        let items = components.queryItems ?? []
        guard let latitude = doubleValue(for: "lat", in: items),
              let longitude = doubleValue(for: "lon", in: items),
              isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        let name = sanitizedName(value(for: "name", in: items))
        let kind = value(for: "kind", in: items).flatMap { ArkFileMapWaypointKind(rawValue: $0.lowercased()) }
        return ArkFileMapLocationLink(
            name: name,
            latitude: latitude,
            longitude: longitude,
            kind: kind
        )
    }

    private static func isSupportedLocationURL(_ url: URL, components: URLComponents) -> Bool {
        if url.scheme?.caseInsensitiveCompare("arkfile") == .orderedSame {
            return url.host?.caseInsensitiveCompare("map") == .orderedSame
        }
        guard url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = url.host?.lowercased(),
              universalLinkHosts.contains(host) else {
            return false
        }
        return components.path == "/l" || components.path.hasPrefix("/l/")
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    static func sanitizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maximumNameLength {
            return trimmed
        }
        return String(trimmed.prefix(maximumNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func coordinateString(_ value: Double) -> String {
        let rounded = String(format: "%.6f", value)
        return rounded
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func value(for name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func doubleValue(for name: String, in items: [URLQueryItem]) -> Double? {
        guard let value = value(for: name, in: items),
              let double = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return double
    }
}

@MainActor
enum ArkFileMapLocationRouter {
    private static var pendingLink: ArkFileMapLocationLink?

    static var hasPendingLink: Bool {
        pendingLink != nil
    }

    static func dispatch(_ link: ArkFileMapLocationLink) {
        pendingLink = link
        NotificationCenter.default.post(
            name: .arkFileOpenMapLocation,
            object: nil,
            userInfo: ["link": link]
        )
    }

    static func takePendingLink() -> ArkFileMapLocationLink? {
        let link = pendingLink
        pendingLink = nil
        return link
    }

    static func link(from notification: Notification) -> ArkFileMapLocationLink? {
        notification.userInfo?["link"] as? ArkFileMapLocationLink
    }
}
