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

#if os(iOS)
import Foundation
import CryptoKit

extension Notification.Name {
    static let arkFileImportMapGPX = Notification.Name("arkFileImportMapGPX")
}

struct ArkFileMapGPXDocument: Equatable, Sendable {
    var waypoints: [ArkFileMapWaypoint]
    var tracks: [ArkFileMapTrack]
    var warnings: [String] = []
}

struct ArkFileMapImportPlan<Item: Identifiable & Sendable>: Sendable where Item.ID == String {
    let accepted: [Item]
    let duplicateIDs: Set<String>
    let capacitySkippedIDs: Set<String>

    var duplicateCount: Int { duplicateIDs.count }
    var capacitySkippedCount: Int { capacitySkippedIDs.count }
    var hasChanges: Bool { !accepted.isEmpty }
}

/// Planning and JSON encoding are background-safe. Applying this value only
/// validates the current store and writes the already-encoded replacement.
struct ArkFileMapPreparedImport<Item: Codable & Equatable & Identifiable & Sendable>: Sendable where Item.ID == String {
    let existingItems: [Item]
    let plan: ArkFileMapImportPlan<Item>
    let updatedItems: [Item]
    let encodedData: Data?
}

enum ArkFileMapImportError: Error, LocalizedError, Equatable {
    case storeChanged

    var errorDescription: String? {
        "Your saved items changed. Review the updated selection before importing."
    }
}

enum ArkFileMapGPXError: Error, LocalizedError, Equatable {
    case invalidUTF8
    case parseFailed(String)
    case emptyDocument
    case documentTooLarge
    case unsafeDocument
    case resourceLimit
    case notGPX
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return LocalString.arkfile_content_offline_map_gpx_error_read
        case .parseFailed(let message):
            return message
        case .emptyDocument:
            return LocalString.arkfile_content_offline_map_gpx_error_empty
        case .documentTooLarge:
            return "This GPX file is too large to import safely."
        case .unsafeDocument:
            return "This GPX file contains unsupported XML declarations."
        case .resourceLimit:
            return "This GPX file contains too many items or is too deeply nested."
        case .notGPX:
            return "This file is not a supported GPX document. Choose a GPX 1.0 or 1.1 file."
        case .invalidCoordinate:
            return "This GPX file contains an invalid location. Nothing was imported."
        }
    }
}

enum ArkFileMapGPX {
    static let maximumDocumentBytes = 64 * 1_024 * 1_024
    // Parsing ceilings exceed storage capacity so the review can explain which
    // items fit, while still bounding work for untrusted documents.
    static let maximumWaypoints = 2_000
    static let maximumTracks = 100
    static let maximumTrackPoints = 20_000
    static let maximumTotalTrackPoints = 400_000
    // Each segment can become a native map annotation. Bound that independent
    // of point count, including empty segments and single-point segments.
    static let maximumTotalSegments = 512
    static let maximumElementDepth = 64
    static let maximumElementTextBytes = 4_096

    static func export(waypoints: [ArkFileMapWaypoint], tracks: [ArkFileMapTrack]) -> Data {
        let dateFormatter = preciseDateFormatter()
        var xml: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="ArkFile" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
            "    <name>ArkFile Map Export</name>",
            "    <time>\(dateFormatter.string(from: Date()))</time>",
            "  </metadata>"
        ]

        for waypoint in waypoints {
            xml.append(#"  <wpt lat="\#(coordinateString(waypoint.latitude))" lon="\#(coordinateString(waypoint.longitude))">"#)
            if let createdAt = waypoint.createdAt {
                xml.append("    <time>\(dateFormatter.string(from: createdAt))</time>")
            }
            xml.append("    <name>\(escape(waypoint.name))</name>")
            if let kind = waypoint.kind {
                xml.append("    <type>\(escape(kind.rawValue))</type>")
            }
            xml.append("  </wpt>")
        }

        // GPX 1.1 requires every route before every track at the root level.
        for route in tracks where route.kind == .plannedRoute {
            xml.append("  <rte>")
            xml.append("    <name>\(escape(route.name))</name>")
            for point in route.points {
                append(point, element: "rtept", indent: "    ", dateFormatter: dateFormatter, to: &xml)
            }
            xml.append("  </rte>")
        }
        for track in tracks where track.kind == .recordedTrail {
            xml.append("  <trk>")
            xml.append("    <name>\(escape(track.name))</name>")
            for segment in track.segments {
                xml.append("    <trkseg>")
                for point in segment {
                    append(point, element: "trkpt", indent: "      ", dateFormatter: dateFormatter, to: &xml)
                }
                xml.append("    </trkseg>")
            }
            xml.append("  </trk>")
        }

        xml.append("</gpx>")
        return Data(xml.joined(separator: "\n").utf8)
    }

    private static func append(
        _ point: ArkFileTrackPoint, element: String, indent: String,
        dateFormatter: ISO8601DateFormatter, to xml: inout [String]
    ) {
        xml.append("\(indent)<\(element) lat=\"\(coordinateString(point.latitude))\" lon=\"\(coordinateString(point.longitude))\">")
        if let timestamp = point.timestamp {
            xml.append("\(indent)  <time>\(dateFormatter.string(from: timestamp))</time>")
        }
        xml.append("\(indent)</\(element)>")
    }

    /// Bounds for MapLibre's documented unwrapped-longitude camera API.
    /// Put the seam in the largest empty interval so nearby date-line points
    /// stay nearby instead of making Show on map zoom out to the whole world.
    static func displayBounds(for coordinates: [ArkFileMapCoordinate]) -> [Double]? {
        guard coordinates.count > 1 else { return nil }
        let longitudes = coordinates.map {
            ($0.longitude.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }.sorted()
        var origin = longitudes[0]
        var largestGap = -Double.infinity
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            if next - longitudes[index] > largestGap {
                largestGap = next - longitudes[index]
                origin = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let west = origin > 180 ? origin - 360 : origin
        let east = west + 360 - largestGap
        let south = coordinates.map(\.latitude).min()!
        let north = coordinates.map(\.latitude).max()!
        guard west != east || south != north else { return nil }
        return [west, south, east, north]
    }

    static func planWaypoints(
        _ candidates: [ArkFileMapWaypoint], existing: [ArkFileMapWaypoint],
        capacity: Int = ArkFileMapWaypointStore.maxWaypoints
    ) -> ArkFileMapImportPlan<ArkFileMapWaypoint> {
        plan(candidates, existing: existing, capacity: capacity, identity: waypointIdentity)
    }

    static func planTracks(
        _ candidates: [ArkFileMapTrack], existing: [ArkFileMapTrack],
        capacity: Int = ArkFileMapTrackRecorder.maximumSavedTracks
    ) -> ArkFileMapImportPlan<ArkFileMapTrack> {
        plan(candidates, existing: existing, capacity: capacity, identity: trackIdentity)
    }

    static func prepareWaypoints(
        _ candidates: [ArkFileMapWaypoint], existing: [ArkFileMapWaypoint]
    ) throws -> ArkFileMapPreparedImport<ArkFileMapWaypoint> {
        try Task.checkCancellation()
        return try prepare(planWaypoints(candidates, existing: existing), existing: existing)
    }

    static func prepareTracks(
        _ candidates: [ArkFileMapTrack], existing: [ArkFileMapTrack]
    ) throws -> ArkFileMapPreparedImport<ArkFileMapTrack> {
        try Task.checkCancellation()
        return try prepare(planTracks(candidates, existing: existing), existing: existing)
    }

    private static func prepare<Item: Codable & Equatable & Identifiable & Sendable>(
        _ plan: ArkFileMapImportPlan<Item>, existing: [Item]
    ) throws -> ArkFileMapPreparedImport<Item> where Item.ID == String {
        try Task.checkCancellation()
        let updated = plan.accepted + existing
        let encoded = plan.hasChanges ? try JSONEncoder().encode(updated) : nil
        try Task.checkCancellation()
        return ArkFileMapPreparedImport(existingItems: existing, plan: plan, updatedItems: updated, encodedData: encoded)
    }

    private static func plan<Item: Identifiable & Sendable>(
        _ candidates: [Item], existing: [Item], capacity: Int, identity: (Item) -> Data
    ) -> ArkFileMapImportPlan<Item> where Item.ID == String {
        var known = Set(existing.map(identity))
        var accepted: [Item] = []
        var duplicateIDs: Set<String> = []
        var capacitySkippedIDs: Set<String> = []
        let available = max(0, capacity - existing.count)
        for candidate in candidates {
            let fingerprint = identity(candidate)
            guard known.insert(fingerprint).inserted else {
                duplicateIDs.insert(candidate.id)
                continue
            }
            guard accepted.count < available else {
                capacitySkippedIDs.insert(candidate.id)
                continue
            }
            accepted.append(candidate)
        }
        return ArkFileMapImportPlan(
            accepted: accepted, duplicateIDs: duplicateIDs, capacitySkippedIDs: capacitySkippedIDs
        )
    }

    private static func waypointIdentity(_ waypoint: ArkFileMapWaypoint) -> Data {
        // Renaming a saved place must not create it again on the next import.
        fingerprint([
            waypoint.kind?.rawValue ?? "", coordinateString(waypoint.latitude), coordinateString(waypoint.longitude)
        ])
    }

    private static func trackIdentity(_ track: ArkFileMapTrack) -> Data {
        var fingerprint = FingerprintBuilder()
        fingerprint.append(track.kind.rawValue)
        let segmentStarts = Set(track.segmentStartIndices)
        for (index, point) in track.points.enumerated() {
            if segmentStarts.contains(index) { fingerprint.append("segment") }
            fingerprint.append(coordinateString(point.latitude))
            fingerprint.append(coordinateString(point.longitude))
            // A new recording of the same walk remains a separate activity.
            if track.kind == .recordedTrail {
                // ISO8601DateFormatter exports rounded milliseconds. Numeric
                // canonicalization avoids formatting every point during review.
                let milliseconds = point.timestamp.map { ($0.timeIntervalSince1970 * 1_000).rounded() }
                fingerprint.append(milliseconds.map { String(format: "%.0f", $0) } ?? "undated")
            }
        }
        return fingerprint.finish()
    }

    private static func fingerprint(_ fields: [String]) -> Data {
        var builder = FingerprintBuilder()
        for field in fields { builder.append(field) }
        return builder.finish()
    }

    private struct FingerprintBuilder {
        private var hasher = SHA256()
        private var buffer = ""

        mutating func append(_ field: String) {
            buffer += "\(field.utf8.count):\(field)"
            if buffer.utf8.count >= 4_096 { flush() }
        }

        mutating func finish() -> Data {
            flush()
            return Data(hasher.finalize())
        }

        private mutating func flush() {
            hasher.update(data: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }
    }

    static func parse(data: Data) throws -> ArkFileMapGPXDocument {
        guard !data.isEmpty else { throw ArkFileMapGPXError.emptyDocument }
        guard data.count <= maximumDocumentBytes else {
            throw ArkFileMapGPXError.documentTooLarge
        }
        guard autoreleasepool(invoking: {
            String(data: data, encoding: .utf8) != nil
        }) else {
            throw ArkFileMapGPXError.invalidUTF8
        }
        guard !containsASCIICaseInsensitive(Data("<!doctype".utf8), in: data),
              !containsASCIICaseInsensitive(Data("<!entity".utf8), in: data) else {
            throw ArkFileMapGPXError.unsafeDocument
        }
        let parser = XMLParser(data: data)
        let delegate = GPXParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            if let failure = delegate.failure {
                throw failure
            }
            let message = parser.parserError?.localizedDescription ?? LocalString.arkfile_content_offline_map_gpx_error_parse
            throw ArkFileMapGPXError.parseFailed(message)
        }
        if let failure = delegate.failure {
            throw failure
        }
        let document = delegate.document
        guard !document.waypoints.isEmpty || !document.tracks.isEmpty else {
            throw ArkFileMapGPXError.emptyDocument
        }
        return document
    }

    static func parse(url: URL) throws -> ArkFileMapGPXDocument {
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maximumDocumentBytes {
            throw ArkFileMapGPXError.documentTooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumDocumentBytes + 1) ?? Data()
        guard data.count <= maximumDocumentBytes else {
            throw ArkFileMapGPXError.documentTooLarge
        }
        return try parse(data: data)
    }

    private static func containsASCIICaseInsensitive(_ needle: Data, in data: Data) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { dataBytes in
            needle.withUnsafeBytes { needleBytes in
                guard let dataBase = dataBytes.bindMemory(to: UInt8.self).baseAddress,
                      let needleBase = needleBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                for offset in 0...(data.count - needle.count) {
                    var matched = true
                    for index in 0..<needle.count {
                        let candidate = dataBase[offset + index]
                        let normalizedCandidate = candidate >= 65 && candidate <= 90
                            ? candidate + 32
                            : candidate
                        if normalizedCandidate != needleBase[index] {
                            matched = false
                            break
                        }
                    }
                    if matched { return true }
                }
                return false
            }
        }
    }

    static func temporaryExportURL(waypoints: [ArkFileMapWaypoint], tracks: [ArkFileMapTrack]) throws -> URL {
        let data = export(waypoints: waypoints, tracks: tracks)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArkFileMapExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        // Leave active shares alone; discard only our exports older than a day.
        if let previous = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for file in previous where file.lastPathComponent.hasPrefix("arkfile-map-")
                && file.pathExtension.lowercased() == "gpx" {
                if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(modified) > 24 * 60 * 60 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let url = directory.appendingPathComponent("arkfile-map-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8)).gpx")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func escape(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13
                || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func coordinateString(_ value: Double) -> String {
        let normalized = abs(value) < 0.00000005 ? 0 : value
        return String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), normalized)
    }

    private static func preciseDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private final class GPXParserDelegate: NSObject, XMLParserDelegate {
        private struct Element {
            let name: String
            let namespace: String
        }

        private struct ParsedWaypoint {
            var coordinate: ArkFileMapCoordinate
            var name = ""
            var kind: ArkFileMapWaypointKind?
            var createdAt: Date?
        }

        private struct ParsedPoint {
            var coordinate: ArkFileMapCoordinate
            var timestamp: Date?
        }

        private struct ParsedTrack {
            var name = ""
            var kind: ArkFileMapTrackKind
            var points: [ArkFileTrackPoint] = []
            var segmentStarts: [Int] = []
        }

        private(set) var document = ArkFileMapGPXDocument(waypoints: [], tracks: [])
        private(set) var failure: ArkFileMapGPXError?
        private var currentWaypoint: ParsedWaypoint?
        private var currentTrack: ParsedTrack?
        private var currentPoint: ParsedPoint?
        private var textBuffer = ""
        private var elementStack: [Element] = []
        private var documentNamespace = ""
        private var extensionDepth: Int?
        private var waypointCount = 0
        private var trackCount = 0
        private var currentTrackPointCount = 0
        private var totalTrackPointCount = 0
        private var totalSegmentCount = 0
        private var omittedDetails = false
        private var omittedPaths = false
        private var omittedDates = false
        private let preciseDateFormatter = ArkFileMapGPX.preciseDateFormatter()
        private let fallbackDateFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard failure == nil else { return }
            let namespace = namespaceURI ?? ""
            guard elementStack.count < ArkFileMapGPX.maximumElementDepth else {
                fail(parser, with: .resourceLimit)
                return
            }
            if elementStack.isEmpty {
                guard elementName == "gpx",
                      ["", "http://www.topografix.com/GPX/1/1", "http://www.topografix.com/GPX/1/0"].contains(namespace),
                      attributeDict["version"].map({ ["1.0", "1.1"].contains($0) }) ?? true else {
                    fail(parser, with: .notGPX)
                    return
                }
                documentNamespace = namespace
            }
            elementStack.append(Element(name: elementName, namespace: namespace))
            textBuffer = ""
            guard extensionDepth == nil else { return }
            if elementName == "extensions" {
                extensionDepth = elementStack.count
                omittedDetails = true
                return
            }
            guard namespace == documentNamespace else {
                omittedDetails = true
                return
            }

            if isPath(["gpx", "wpt"]) {
                waypointCount += 1
                guard waypointCount <= ArkFileMapGPX.maximumWaypoints else {
                    fail(parser, with: .resourceLimit)
                    return
                }
                guard let coordinate = coordinate(from: attributeDict) else {
                    fail(parser, with: .invalidCoordinate)
                    return
                }
                currentWaypoint = ParsedWaypoint(coordinate: coordinate)
            } else if isPath(["gpx", "trk"]) || isPath(["gpx", "rte"]) {
                trackCount += 1
                guard trackCount <= ArkFileMapGPX.maximumTracks else {
                    fail(parser, with: .resourceLimit)
                    return
                }
                currentTrack = ParsedTrack(kind: elementName == "rte" ? .plannedRoute : .recordedTrail)
                currentTrackPointCount = 0
                if elementName == "rte" {
                    guard beginSegment(parser) else { return }
                    currentTrack?.segmentStarts = [0]
                }
            } else if isPath(["gpx", "trk", "trkseg"]) {
                guard beginSegment(parser) else { return }
                if let currentTrack {
                    self.currentTrack?.segmentStarts.append(currentTrack.points.count)
                }
            } else if isPath(["gpx", "trk", "trkseg", "trkpt"]) || isPath(["gpx", "rte", "rtept"]) {
                currentTrackPointCount += 1
                totalTrackPointCount += 1
                guard currentTrackPointCount <= ArkFileMapGPX.maximumTrackPoints,
                      totalTrackPointCount <= ArkFileMapGPX.maximumTotalTrackPoints else {
                    fail(parser, with: .resourceLimit)
                    return
                }
                guard let coordinate = coordinate(from: attributeDict) else {
                    // Silently deleting a bad point could create a false shortcut.
                    fail(parser, with: .invalidCoordinate)
                    return
                }
                currentPoint = ParsedPoint(coordinate: coordinate)
            } else if ["ele", "cmt", "desc", "src", "link", "number", "magvar", "geoidheight", "fix", "sat", "hdop", "vdop", "pdop", "ageofdgpsdata", "dgpsid"].contains(elementName) {
                omittedDetails = true
            } else if ["type", "sym"].contains(elementName), !isPath(["gpx", "wpt", elementName]) {
                omittedDetails = true
            } else if elementName == "name", currentPoint != nil {
                omittedDetails = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard failure == nil else { return }
            guard textBuffer.utf8.count + string.utf8.count <= ArkFileMapGPX.maximumElementTextBytes else {
                fail(parser, with: .resourceLimit)
                return
            }
            textBuffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard failure == nil else { return }
            defer {
                if extensionDepth == elementStack.count { extensionDepth = nil }
                if !elementStack.isEmpty { elementStack.removeLast() }
                textBuffer = ""
            }
            guard extensionDepth == nil, (namespaceURI ?? "") == documentNamespace else { return }
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

            if isPath(["gpx", "wpt", "name"]) {
                currentWaypoint?.name = text
            } else if isPath(["gpx", "trk", "name"]) || isPath(["gpx", "rte", "name"]) {
                currentTrack?.name = text
            } else if isPath(["gpx", "wpt", "type"]) || isPath(["gpx", "wpt", "sym"]) {
                if let kind = waypointKind(from: text) {
                    currentWaypoint?.kind = kind
                } else if !text.isEmpty {
                    omittedDetails = true
                }
            } else if isPath(["gpx", "wpt", "time"]) {
                currentWaypoint?.createdAt = date(from: text)
                if currentWaypoint?.createdAt == nil { omittedDates = true }
            } else if isPath(["gpx", "trk", "trkseg", "trkpt", "time"]) || isPath(["gpx", "rte", "rtept", "time"]) {
                currentPoint?.timestamp = date(from: text)
                if currentPoint?.timestamp == nil { omittedDates = true }
            } else if isPath(["gpx", "wpt"]) {
                if let waypoint = currentWaypoint {
                    document.waypoints.append(ArkFileMapWaypoint(
                        id: UUID().uuidString,
                        name: waypoint.name.isEmpty
                            ? LocalString.arkfile_content_offline_map_gpx_imported_waypoint_name : waypoint.name,
                        latitude: waypoint.coordinate.latitude,
                        longitude: waypoint.coordinate.longitude,
                        createdAt: waypoint.createdAt,
                        kind: waypoint.kind
                    ))
                }
                currentWaypoint = nil
            } else if isPath(["gpx", "trk", "trkseg", "trkpt"]) || isPath(["gpx", "rte", "rtept"]) {
                if let point = currentPoint {
                    currentTrack?.points.append(ArkFileTrackPoint(
                        latitude: point.coordinate.latitude,
                        longitude: point.coordinate.longitude,
                        timestamp: point.timestamp
                    ))
                }
                currentPoint = nil
            } else if isPath(["gpx", "trk"]) || isPath(["gpx", "rte"]) {
                if let track = currentTrack, track.points.count > 1 {
                    let defaultName = track.kind == .plannedRoute
                        ? "Imported Route" : LocalString.arkfile_content_offline_map_gpx_imported_trail_name
                    document.tracks.append(ArkFileMapTrack(
                        id: UUID().uuidString,
                        name: track.name.isEmpty ? defaultName : track.name,
                        points: track.points,
                        startedAt: track.points.first?.timestamp,
                        endedAt: track.points.last?.timestamp,
                        kind: track.kind,
                        segmentStartIndices: track.segmentStarts
                    ))
                } else {
                    omittedPaths = true
                }
                currentTrack = nil
                currentTrackPointCount = 0
            } else if isPath(["gpx"]) {
                if omittedDetails {
                    document.warnings.append("Extra GPX details such as elevation, notes, links, custom symbols, and extensions are not kept.")
                }
                if omittedPaths {
                    document.warnings.append("Paths with fewer than two usable points were skipped.")
                }
                if omittedDates {
                    document.warnings.append("Some dates could not be read and were left blank.")
                }
            }
        }

        private func isPath(_ names: [String]) -> Bool {
            elementStack.count == names.count && zip(elementStack, names).allSatisfy {
                $0.0.name == $0.1 && $0.0.namespace == documentNamespace
            }
        }

        private func fail(_ parser: XMLParser, with error: ArkFileMapGPXError) {
            failure = error
            parser.abortParsing()
        }

        private func beginSegment(_ parser: XMLParser) -> Bool {
            totalSegmentCount += 1
            guard totalSegmentCount <= ArkFileMapGPX.maximumTotalSegments else {
                fail(parser, with: .resourceLimit)
                return false
            }
            return true
        }

        private func coordinate(from attributes: [String: String]) -> ArkFileMapCoordinate? {
            guard let latText = attributes["lat"],
                  let lonText = attributes["lon"],
                  let latitude = Double(latText),
                  let longitude = Double(lonText),
                  latitude.isFinite, longitude.isFinite,
                  abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            return ArkFileMapCoordinate(latitude: latitude, longitude: longitude)
        }

        private func waypointKind(from text: String) -> ArkFileMapWaypointKind? {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ArkFileMapWaypointKind(rawValue: normalized)
                ?? ArkFileMapWaypointKind.allCases.first { $0.displayName.lowercased() == normalized }
        }

        private func date(from text: String) -> Date? {
            ArkFileMapStoredDate.restore(
                preciseDateFormatter.date(from: text) ?? fallbackDateFormatter.date(from: text)
            )
        }
    }
}

@MainActor
enum ArkFileMapGPXRouter {
    private static var pendingImportURL: URL?

    static var hasPendingImport: Bool {
        pendingImportURL != nil
    }

    static func dispatch(_ url: URL) {
        pendingImportURL = url
        NotificationCenter.default.post(
            name: .arkFileImportMapGPX,
            object: nil,
            userInfo: ["url": url]
        )
    }

    static func takePendingImportURL() -> URL? {
        let url = pendingImportURL
        pendingImportURL = nil
        return url
    }

    static func url(from notification: Notification) -> URL? {
        notification.userInfo?["url"] as? URL
    }
}
#endif
