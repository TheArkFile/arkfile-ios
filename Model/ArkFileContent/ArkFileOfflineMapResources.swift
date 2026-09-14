// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Foundation

struct ArkFileOfflineMapCoverage: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case worldOverview
        case northAmericaDetail
        case streetMap
        case unavailable
        case notDownloaded
    }

    let kind: Kind
    var isBeyondDownloadedDetail = false
    var hasMixedCoverage = false

    var summary: String {
        let title: String
        switch kind {
        case .worldOverview: title = "World overview"
        case .northAmericaDetail: title = "North America detail"
        case .streetMap: title = "Street map"
        case .unavailable: title = "Map coverage could not be checked"
        case .notDownloaded: title = "No map downloaded for this area"
        }
        var parts = [title]
        if isBeyondDownloadedDetail { parts.append("Detail is limited at this zoom") }
        if hasMixedCoverage { parts.append("Some visible areas have less detail") }
        return parts.joined(separator: " · ")
    }
}

struct ArkFileOfflineMapArchive: Equatable, Sendable {
    let id: String?
    let displayName: String?
    /// Logical active-tree path used for access decisions. `fileURL` may be a
    /// physical transaction snapshot held alive by `readLease`.
    let logicalFileURL: URL
    let fileURL: URL
    let relativePath: String
    let minZoom: Double
    let maxZoom: Double
    let bounds: [Double]
    let sizeBytes: Int64
    let sha256: String?
    let readLease: ArkFileAuthoritativeReadLease?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.logicalFileURL == rhs.logicalFileURL
            && lhs.fileURL == rhs.fileURL
            && lhs.relativePath == rhs.relativePath
            && lhs.minZoom == rhs.minZoom
            && lhs.maxZoom == rhs.maxZoom
            && lhs.bounds == rhs.bounds
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.sha256 == rhs.sha256
    }
}

struct ArkFileOfflineMapResources: Equatable, Sendable {
    static let attribution = "© Protomaps © OpenStreetMap contributors"
    static let regionLayerMinZoom = 10.01

    let base: ArkFileOfflineMapArchive?
    let detail: ArkFileOfflineMapArchive?
    let regions: [ArkFileOfflineMapArchive]
    let criticalPlacesURL: URL?
    let glyphsTemplate: String?
    let spriteURL: URL?
    let legacyTilesRoot: URL?
    private let auxiliaryReadLeases: [ArkFileAuthoritativeReadLease]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.base == rhs.base
            && lhs.detail == rhs.detail
            && lhs.regions == rhs.regions
            && lhs.criticalPlacesURL == rhs.criticalPlacesURL
            && lhs.glyphsTemplate == rhs.glyphsTemplate
            && lhs.spriteURL == rhs.spriteURL
            && lhs.legacyTilesRoot == rhs.legacyTilesRoot
    }

    var hasVectorMap: Bool {
        base != nil || detail != nil || !regions.isEmpty
    }

    var hasDetailMap: Bool {
        detail != nil
    }

    var hasLegacyTiles: Bool {
        legacyTilesRoot != nil
    }

    var maxZoom: Double {
        ([base?.maxZoom, detail?.maxZoom] + regions.map(\.maxZoom))
            .compactMap { $0 }
            .max() ?? 6
    }

    var displayMaxZoom: Double {
        max(maxZoom, 16)
    }

    var signature: String {
        [
            base.map { "\($0.fileURL.fileSystemPath):\($0.sizeBytes)" } ?? "no-base",
            detail.map { "\($0.fileURL.fileSystemPath):\($0.sizeBytes)" } ?? "no-detail",
            regions.isEmpty
                ? "no-regions"
                : regions.map { "\($0.id ?? "region"):\($0.fileURL.fileSystemPath):\($0.sizeBytes)" }
                    .joined(separator: ","),
            criticalPlacesURL.map { "\($0.fileSystemPath):\(Self.fileSize($0))" } ?? "no-critical-places",
            glyphsTemplate ?? "no-glyphs",
            spriteURL?.absoluteString ?? "no-sprite"
        ].joined(separator: "|")
    }

    var statusSummary: String {
        if base != nil || detail != nil || !regions.isEmpty {
            var parts: [String] = []
            parts.append("Offline map ready")
            if detail != nil {
                parts.append("NA detail")
            } else if base != nil {
                parts.append("world base")
            }
            if !regions.isEmpty {
                parts.append("\(regions.count) street-level \(regions.count == 1 ? "region" : "regions")")
            }
            if criticalPlacesURL != nil {
                parts.append("critical places")
            }
            return parts.joined(separator: " · ")
        }
        if criticalPlacesURL != nil {
            return "Critical places ready"
        }
        if legacyTilesRoot != nil {
            return "Legacy PNG map tiles detected"
        }
        return "Offline map resources are not installed"
    }

    var coverageSummary: String {
        var sentences: [String] = []
        if base != nil {
            sentences.append("World overview is included and downloaded.")
        }
        if detail != nil {
            sentences.append("North America detail is downloaded.")
        }
        if !regions.isEmpty {
            let regionLabel = regions.count == 1 ? "region is" : "regions are"
            sentences.append(
                "\(regions.count) U.S. street-map \(regionLabel) downloaded."
            )
        }
        if criticalPlacesURL != nil { sentences.append("Critical Places are downloaded.") }
        if sentences.isEmpty {
            return hasLegacyTiles
                ? "An older map is on this device. Open Download Maps to add current map detail."
                : "No offline map coverage is installed on this device."
        }
        return sentences.joined(separator: " ")
    }

    func coverageStatus(
        at coordinate: ArkFileMapCoordinate,
        zoom: Double = 0,
        viewport: ArkFileCriticalPlacesBoundingBox? = nil
    ) -> String {
        coverage(at: coordinate, zoom: zoom, viewport: viewport).summary
    }

    func coverage(
        at coordinate: ArkFileMapCoordinate,
        zoom: Double = 0,
        viewport: ArkFileCriticalPlacesBoundingBox? = nil
    ) -> ArkFileOfflineMapCoverage {
        // This describes downloaded archive coverage, not whether every street
        // or place has been mapped or whether the renderer has finished loading.
        let regionalLayersVisible = zoom >= Self.regionLayerMinZoom
        let detailLayersVisible = zoom >= 6.01
        let regionalMatches = regionalLayersVisible ? regions.filter { Self.contains($0, coordinate) } : []
        let archives: [ArkFileOfflineMapArchive]
        let kind: ArkFileOfflineMapCoverage.Kind
        let nativeMaxZoom: Double
        if let best = regionalMatches.max(by: { $0.maxZoom < $1.maxZoom }) {
            archives = regions
            kind = .streetMap
            nativeMaxZoom = best.maxZoom
        } else if regionalLayersVisible, regions.contains(where: { !Self.validBounds($0.bounds) }) {
            return .init(kind: .unavailable)
        } else if detailLayersVisible, let detail, Self.contains(detail, coordinate) {
            archives = [detail] + (regionalLayersVisible ? regions : [])
            kind = .northAmericaDetail
            nativeMaxZoom = detail.maxZoom
        } else if let base, Self.contains(base, coordinate) {
            archives = [base] + (detailLayersVisible ? [detail].compactMap { $0 } : [])
                + (regionalLayersVisible ? regions : [])
            kind = .worldOverview
            nativeMaxZoom = base.maxZoom
        } else {
            return .init(kind: .notDownloaded)
        }
        var result = ArkFileOfflineMapCoverage(kind: kind)
        if zoom.isFinite, zoom > nativeMaxZoom + 0.5 {
            result.isBeyondDownloadedDetail = true
        }
        if let viewport = viewport.flatMap(Self.normalizedCoverageViewport),
           !Self.coversViewport(viewport, archives: archives) {
            result.hasMixedCoverage = true
        }
        return result
    }

    func bestAvailableMaxZoom(at coordinate: ArkFileMapCoordinate) -> Double {
        var values: [Double] = []
        if let base, Self.contains(base, coordinate) {
            values.append(base.maxZoom)
        }
        if let detail, Self.contains(detail, coordinate) {
            values.append(detail.maxZoom)
        }
        for region in regions where Self.contains(region, coordinate) {
            values.append(region.maxZoom)
        }
        return values.max() ?? 0
    }

    private static func contains(_ archive: ArkFileOfflineMapArchive, _ coordinate: ArkFileMapCoordinate) -> Bool {
        validBounds(archive.bounds)
            && ArkFileMapRegionIndex.Region.bounds(archive.bounds, contain: coordinate)
    }

    private static func validBounds(_ bounds: [Double]) -> Bool {
        bounds.count == 4 && bounds.allSatisfy(\.isFinite)
            && (-180...180).contains(bounds[0]) && (-180...180).contains(bounds[2])
            && (-90...90).contains(bounds[1]) && (-90...90).contains(bounds[3])
            && bounds[1] < bounds[3] && bounds[0] != bounds[2]
    }

    private static func validZooms(min: Double, max: Double) -> Bool {
        min.isFinite && max.isFinite && min >= 0 && max >= min && max <= 30
    }

    private static func longitudeRanges(west: Double, east: Double) -> [ClosedRange<Double>] {
        west <= east ? [west...east] : [west...180, -180...east]
    }

    private static func normalizedCoverageViewport(
        _ viewport: ArkFileCriticalPlacesBoundingBox
    ) -> ArkFileCriticalPlacesBoundingBox? {
        guard viewport.west.isFinite, viewport.east.isFinite,
              viewport.south.isFinite, viewport.north.isFinite,
              viewport.south >= -90, viewport.north <= 90,
              viewport.south <= viewport.north else { return nil }
        // MapLibre returns unwrapped longitudes when the view crosses the
        // date line or shows another world copy. Preserve the original span
        // before wrapping so a full world never becomes a zero-width slice.
        let span = viewport.east - viewport.west
        if abs(span) >= 360 {
            return ArkFileCriticalPlacesBoundingBox(
                west: -180, south: viewport.south, east: 180, north: viewport.north
            )
        }
        if viewport.isValid { return viewport }
        func wrapped(_ longitude: Double) -> Double {
            let remainder = longitude.truncatingRemainder(dividingBy: 360)
            if remainder < -180 { return remainder + 360 }
            if remainder >= 180 { return remainder - 360 }
            return remainder
        }
        let west = wrapped(viewport.west)
        let east = wrapped(viewport.east)
        return ArkFileCriticalPlacesBoundingBox(
            west: west, south: viewport.south,
            // A nonempty view ending at the date line includes its west-side
            // edge; avoid creating an extra, uncovered point at -180.
            east: east == -180 && span != 0 ? 180 : east,
            north: viewport.north
        )
    }

    private static func coversViewport(
        _ viewport: ArkFileCriticalPlacesBoundingBox,
        archives: [ArkFileOfflineMapArchive]
    ) -> Bool {
        let bounds = archives.map(\.bounds).filter(validBounds)
        // Split at every longitude edge, then cover each vertical strip. This
        // handles adjacent/overlapping downloads without missing gaps between
        // them, and treats an antimeridian viewport as two longitude ranges.
        for viewRange in longitudeRanges(west: viewport.west, east: viewport.east) {
            let rectangles = bounds.flatMap { box in
                longitudeRanges(west: box[0], east: box[2]).compactMap { range -> (ClosedRange<Double>, Double, Double)? in
                    let west = max(viewRange.lowerBound, range.lowerBound)
                    let east = min(viewRange.upperBound, range.upperBound)
                    guard west <= east else { return nil }
                    return (west...east, box[1], box[3])
                }
            }
            let edges = Set([viewRange.lowerBound, viewRange.upperBound] + rectangles.flatMap {
                [$0.0.lowerBound, $0.0.upperBound]
            }).sorted()
            let midpoints = zip(edges, edges.dropFirst()).map { pair in (pair.0 + pair.1) / 2 }
            for longitude in midpoints.isEmpty ? [viewRange.lowerBound] : midpoints {
                let spans = rectangles.filter { $0.0.contains(longitude) }.sorted { $0.1 < $1.1 }
                var coveredNorth = viewport.south
                for span in spans where span.2 >= coveredNorth {
                    if span.1 > coveredNorth { break }
                    coveredNorth = max(coveredNorth, span.2)
                }
                if coveredNorth < viewport.north { return false }
            }
        }
        return true
    }

    static func locate(
        contentRoot: URL?,
        bundle: Bundle = .main
    ) -> ArkFileOfflineMapResources {
        locate(contentRoot: contentRoot, bundleResourceRoot: bundle.resourceURL)
    }

    static func locate(
        contentRoot: URL?,
        bundleResourceRoot: URL?
    ) -> ArkFileOfflineMapResources {
        locate(
            contentRoot: contentRoot,
            bundleResourceRoot: bundleResourceRoot,
            canOpenFile: {
                ArkFileEssentialsAccessGate.resolvedURLForReadingSync($0) != nil
            }
        )
    }

    static func locate(
        contentRoot: URL?,
        bundleResourceRoot: URL?,
        canOpenFile: (URL) -> Bool
    ) -> ArkFileOfflineMapResources {
        // Discovery stays on the logical active tree. Resolving an ancestor to
        // one sparse group snapshot would hide unaffected map groups.
        let mapRoots = mapRootCandidates(contentRoot: contentRoot)
        let contentBaseRoot = mapRoots
            .map { $0.appendingPathComponent("base", isDirectory: true) }
            .first(where: directoryExists)
        let bundleBaseRoot = bundleBaseRootCandidates(bundleResourceRoot: bundleResourceRoot)
            .first(where: directoryExists)
        let baseRoot = contentBaseRoot ?? bundleBaseRoot
        let baseManifest = baseRoot.flatMap { readManifest(in: $0) }
        let base = baseRoot.flatMap {
            archive(
                root: $0,
                id: nil,
                displayName: nil,
                relativePrefix: "maps/base",
                manifest: baseManifest,
                entry: baseManifest?.global,
                defaultFile: "global.pmtiles",
                defaultMinZoom: 0,
                defaultMaxZoom: 6,
                defaultBounds: [-180, -85.05112878, 180, 85.05112878],
                canOpenFile: canOpenFile
            )
        }

        let detailRoot = mapRoots
            .map { $0.appendingPathComponent("detail", isDirectory: true) }
            .first(where: directoryExists)
        let detailManifest = detailRoot.flatMap { readManifest(in: $0) }
        let detail = detailRoot.flatMap {
            archive(
                root: $0,
                id: nil,
                displayName: nil,
                relativePrefix: "maps/detail",
                manifest: detailManifest,
                entry: detailManifest?.northAmerica,
                defaultFile: "north_america.pmtiles",
                defaultMinZoom: 0,
                defaultMaxZoom: 10,
                defaultBounds: [-180, 5, -50, 84],
                canOpenFile: canOpenFile
            )
        }
        let regionsRoot = mapRoots
            .map { $0.appendingPathComponent("regions", isDirectory: true) }
            .first(where: directoryExists)
        let regions = regionArchives(regionsRoot: regionsRoot, canOpenFile: canOpenFile)
        let criticalPlaces = locateCriticalPlaces(mapRoots: mapRoots, canOpenFile: canOpenFile)
        let legacyTiles = mapRoots.compactMap {
            legacyTilesRoot(
                $0.appendingPathComponent("tiles", isDirectory: true),
                canOpenFile: canOpenFile
            )
        }.first

        return ArkFileOfflineMapResources(
            base: base,
            detail: detail,
            regions: regions,
            criticalPlacesURL: criticalPlaces?.url,
            glyphsTemplate: base == nil ? nil : baseRoot.flatMap { glyphsTemplate(root: $0, manifest: baseManifest) },
            spriteURL: base == nil ? nil : baseRoot.flatMap { spriteURL(root: $0, manifest: baseManifest) },
            legacyTilesRoot: legacyTiles?.url,
            auxiliaryReadLeases: [criticalPlaces?.lease, legacyTiles?.lease].compactMap { $0 }
        )
    }

    func mapLibreStyleData() throws -> Data {
        var sources: [String: Any] = [:]
        var styleLayers: [[String: Any]] = []
        let readableBase = base.flatMap {
            ArkFileEssentialsAccessGate.canOpenEssentialsURLSync($0.logicalFileURL) ? $0 : nil
        }
        let readableDetail = detail.flatMap {
            ArkFileEssentialsAccessGate.canOpenEssentialsURLSync($0.logicalFileURL) ? $0 : nil
        }
        let readableRegions = regions.filter {
            ArkFileEssentialsAccessGate.canOpenEssentialsURLSync($0.logicalFileURL)
        }
        let readableGlyphsTemplate = readableBase == nil ? nil : glyphsTemplate
        let readableSpriteURL = readableBase == nil ? nil : spriteURL
        let includeLabels = readableGlyphsTemplate != nil
        let template = Self.protomapsStyleTemplate(includeLabels: includeLabels)

        if let base = readableBase {
            sources["global"] = sourceDefinition(for: base)
            styleLayers.append(contentsOf: template?.globalLayers ?? fallbackLayers(
                source: "global",
                idPrefix: "global",
                includeBackground: true,
                minZoom: nil,
                includeLabels: includeLabels
            ))
        }

        if let detail = readableDetail {
            sources["northAmerica"] = sourceDefinition(for: detail)
            if let template {
                if readableBase == nil {
                    styleLayers.append([
                        "id": "background",
                        "type": "background",
                        "paint": ["background-color": "#cccccc"]
                    ])
                }
                styleLayers.append(contentsOf: template.northAmericaLayers)
            } else {
                styleLayers.append(contentsOf: fallbackLayers(
                    source: "northAmerica",
                    idPrefix: "north-america",
                    includeBackground: readableBase == nil,
                    minZoom: readableBase == nil ? nil : 6.01,
                    includeLabels: includeLabels
                ))
            }
        }

        for region in readableRegions {
            let sourceID = sourceID(forRegionID: region.id ?? region.fileURL.deletingPathExtension().lastPathComponent)
            sources[sourceID] = sourceDefinition(for: region)
            if let template {
                styleLayers.append(contentsOf: template.layersForRegion(region, sourceID: sourceID))
            } else {
                styleLayers.append(contentsOf: fallbackLayers(
                    source: sourceID,
                    idPrefix: sourceID,
                    includeBackground: readableBase == nil && readableDetail == nil && styleLayers.isEmpty,
                    minZoom: Self.regionLayerMinZoom,
                    includeLabels: includeLabels
                ))
            }
        }

        var style: [String: Any] = [
            "version": 8,
            "sources": sources,
            "layers": styleLayers
        ]
        if let readableGlyphsTemplate {
            style["glyphs"] = readableGlyphsTemplate
        }
        if let readableSpriteURL {
            style["sprite"] = readableSpriteURL.absoluteString
        }
        return try JSONSerialization.data(withJSONObject: style, options: [.prettyPrinted, .sortedKeys])
    }

    func writeMapLibreStyleFile() throws -> URL {
        let cacheRoot = try FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            .unwrap()
            .appendingPathComponent("ArkFileOfflineMap", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let styleURL = cacheRoot.appendingPathComponent("style.json")
        let data = try mapLibreStyleData()
        // Skip the disk write when the style is unchanged so reopening the
        // map does not touch storage on the critical path.
        if let existing = try? Data(contentsOf: styleURL), existing == data {
            return styleURL
        }
        try data.write(to: styleURL, options: .atomic)
        return styleURL
    }

    static func mapRootCandidates(contentRoot: URL?) -> [URL] {
        guard let contentRoot else { return [] }
        let root = contentRoot.standardizedFileURL
        var candidates: [URL] = []
        let last = root.lastPathComponent.lowercased()
        let parent = root.deletingLastPathComponent()
        if last == "maps" {
            candidates.append(root)
        } else if last == "tiles" && parent.lastPathComponent.lowercased() == "maps" {
            candidates.append(parent)
        } else if last == "base" || last == "detail" {
            candidates.append(parent)
        }
        candidates.append(root.appendingPathComponent("maps", isDirectory: true))
        return unique(candidates)
    }

    private static func bundleBaseRootCandidates(bundleResourceRoot: URL?) -> [URL] {
        guard let bundleResourceRoot else { return [] }
        return unique([
            bundleResourceRoot.appendingPathComponent("content/maps/base", isDirectory: true),
            bundleResourceRoot.appendingPathComponent("maps/base", isDirectory: true),
            bundleResourceRoot.appendingPathComponent("base", isDirectory: true)
        ])
    }

    private static func archive(
        root: URL,
        id: String?,
        displayName: String?,
        relativePrefix: String,
        manifest: OfflineMapManifest?,
        entry: OfflineMapManifest.Archive?,
        defaultFile: String,
        defaultMinZoom: Double,
        defaultMaxZoom: Double,
        defaultBounds: [Double],
        canOpenFile: (URL) -> Bool
    ) -> ArkFileOfflineMapArchive? {
        let file = entry?.file ?? defaultFile
        let fileURL = root.appendingPathComponent(file)
        guard regularFileExists(fileURL),
              canOpenFile(fileURL),
              let readLease = ArkFileInstalledContentAccess.acquireReadLease(for: fileURL) else {
            return nil
        }
        // A PMTiles header is authoritative for a regional archive's actual
        // native zoom and rectangle. Read only its fixed 127-byte v3 header;
        // never scan or decompress tile directories on the map UI path.
        let header = id == nil ? nil : regionCoverageHeader(at: readLease.url)
        let manifestMinZoom = entry?.minzoom ?? defaultMinZoom
        let manifestMaxZoom = entry?.maxzoom
        let hasRegionManifestCoverage = entry?.bounds.map(validBounds) == true
            && manifestMaxZoom.map { validZooms(min: manifestMinZoom, max: $0) } == true
        let bounds = header?.bounds ?? (id == nil
            ? (entry?.bounds.flatMap { validBounds($0) ? $0 : nil } ?? defaultBounds)
            : (hasRegionManifestCoverage ? entry?.bounds ?? [] : []))
        let minZoom = header?.minZoom ?? (validZooms(min: manifestMinZoom, max: manifestMaxZoom ?? defaultMaxZoom)
            ? manifestMinZoom : defaultMinZoom)
        let maxZoom = header?.maxZoom ?? (manifestMaxZoom.flatMap {
            validZooms(min: minZoom, max: $0) ? $0 : nil
        } ?? defaultMaxZoom)
        return ArkFileOfflineMapArchive(
            id: id,
            displayName: displayName ?? entry?.displayName,
            logicalFileURL: fileURL,
            fileURL: readLease.url,
            relativePath: "\(relativePrefix)/\(file)",
            minZoom: minZoom,
            maxZoom: maxZoom,
            bounds: bounds,
            sizeBytes: entry?.sizeBytes ?? fileSize(fileURL),
            sha256: entry?.sha256,
            readLease: readLease
        )
    }

    private struct RegionCoverageHeader {
        let bounds: [Double]
        let minZoom: Double
        let maxZoom: Double
    }

    private static func regionCoverageHeader(at url: URL) -> RegionCoverageHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 127), data.count == 127 else { return nil }
        let bytes = Array(data)
        guard Array(bytes.prefix(8)) == [80, 77, 84, 105, 108, 101, 115, 3],
              bytes[99] == 1 else { return nil } // PMTiles v3 vector tiles.
        func coordinate(at offset: Int) -> Double {
            let value = (0..<4).reduce(UInt32(0)) { result, byte in
                result | UInt32(bytes[offset + byte]) << (byte * 8)
            }
            return Double(Int32(bitPattern: value)) / 10_000_000
        }
        let bounds = [102, 106, 110, 114].map { coordinate(at: $0) }
        let minZoom = Double(bytes[100])
        let maxZoom = Double(bytes[101])
        guard validBounds(bounds), validZooms(min: minZoom, max: maxZoom) else { return nil }
        return RegionCoverageHeader(bounds: bounds, minZoom: minZoom, maxZoom: maxZoom)
    }

    private static func regionArchives(
        regionsRoot: URL?,
        canOpenFile: (URL) -> Bool
    ) -> [ArkFileOfflineMapArchive] {
        guard let regionsRoot,
              let children = try? FileManager.default.contentsOfDirectory(
                at: regionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return children
            .filter(directoryExists)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { root in
                let regionID = root.lastPathComponent
                let manifest = readManifest(in: root)
                let entry = manifest?.regionArchive
                return archive(
                    root: root,
                    id: regionID,
                    displayName: entry?.displayName ?? titleizedRegionName(regionID),
                    relativePrefix: "maps/regions/\(regionID)",
                    manifest: manifest,
                    entry: entry,
                    defaultFile: "region.pmtiles",
                    defaultMinZoom: 0,
                    defaultMaxZoom: 14,
                    // Missing metadata must not turn one regional download
                    // into worldwide coverage. The archive remains readable.
                    defaultBounds: [],
                    canOpenFile: canOpenFile
                )
            }
    }

    private static func locateCriticalPlaces(
        mapRoots: [URL],
        canOpenFile: (URL) -> Bool
    ) -> (url: URL, lease: ArkFileAuthoritativeReadLease)? {
        let candidates = mapRoots.map { root in
            root
                .appendingPathComponent("poi", isDirectory: true)
                .appendingPathComponent("us_critical_places.sqlite")
        }
        guard let logicalURL = candidates.first(
            where: { regularFileExists($0) && canOpenFile($0) }
        ),
              let lease = ArkFileInstalledContentAccess.acquireReadLease(for: logicalURL) else {
            return nil
        }
        return (lease.url, lease)
    }

    private static func readManifest(in root: URL) -> OfflineMapManifest? {
        let logicalURL = root.appendingPathComponent("manifest.json")
        guard let lease = ArkFileInstalledContentAccess.acquireReadLease(for: logicalURL),
              let data = try? Data(contentsOf: lease.url) else { return nil }
        return try? JSONDecoder().decode(OfflineMapManifest.self, from: data)
    }

    private static func glyphsTemplate(root: URL, manifest: OfflineMapManifest?) -> String? {
        let template = manifest?.assets?.fonts ?? "assets/fonts/{fontstack}/{range}.pbf"
        guard let fontstackRange = template.range(of: "{fontstack}") else { return nil }
        let fontsRelativePath = String(template[..<fontstackRange.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fontsRoot = root.appendingPathComponent(fontsRelativePath, isDirectory: true)
        guard directoryExists(fontsRoot) else { return nil }
        let readableFontsRoot = firstRegularFile(in: fontsRoot).flatMap { logicalFile -> URL? in
            guard let readableFile = ArkFileEssentialsAccessGate
                .resolvedURLForReadingSync(logicalFile) else { return nil }
            let relative = logicalFile.standardizedFileURL.fileSystemPath
                .dropFirst(fontsRoot.standardizedFileURL.fileSystemPath.count + 1)
            var resolvedRoot = readableFile
            for _ in relative.split(separator: "/") {
                resolvedRoot.deleteLastPathComponent()
            }
            return resolvedRoot
        } ?? fontsRoot
        let prefix = readableFontsRoot.absoluteString.hasSuffix("/")
            ? readableFontsRoot.absoluteString
            : readableFontsRoot.absoluteString + "/"
        return prefix + "{fontstack}/{range}.pbf"
    }

    private static func spriteURL(root: URL, manifest: OfflineMapManifest?) -> URL? {
        let sprite = manifest?.assets?.sprite ?? "assets/sprites/v4/light"
        let url = root.appendingPathComponent(sprite)
        let logicalJSON = URL(fileURLWithPath: url.fileSystemPath + ".json")
        guard regularFileExists(logicalJSON),
              let readableJSON = ArkFileEssentialsAccessGate
                .resolvedURLForReadingSync(logicalJSON) else { return nil }
        return URL(fileURLWithPath: String(readableJSON.fileSystemPath.dropLast(5)))
    }

    private static func legacyTilesRoot(
        _ root: URL,
        canOpenFile: (URL) -> Bool
    ) -> (url: URL, lease: ArkFileAuthoritativeReadLease)? {
        let sampleTile = root
            .appendingPathComponent("4")
            .appendingPathComponent("4")
            .appendingPathComponent("6.png")
        guard regularFileExists(sampleTile), canOpenFile(sampleTile),
              let lease = ArkFileInstalledContentAccess.acquireReadLease(for: sampleTile) else {
            return nil
        }
        let root = lease.url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (root, lease)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.fileSystemPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func regularFileExists(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func firstRegularFile(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let url = enumerator.nextObject() as? URL {
            if regularFileExists(url) { return url }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.fileSystemPath).inserted
        }
    }

    private func sourceDefinition(for archive: ArkFileOfflineMapArchive) -> [String: Any] {
        [
            "type": "vector",
            "url": "pmtiles://\(archive.fileURL.absoluteString)",
            "minzoom": archive.minZoom,
            "maxzoom": archive.maxZoom,
            "attribution": Self.attribution
        ]
    }

    private static func protomapsStyleTemplate(includeLabels: Bool) -> ProtomapsStyleTemplate? {
        guard let url = Bundle.main.url(
            forResource: "protomaps-light-style",
            withExtension: "json",
            subdirectory: "OfflineMap"
        ) ?? Bundle.main.url(forResource: "protomaps-light-style", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var globalLayers = object["globalLayers"] as? [[String: Any]],
              var northAmericaLayers = object["northAmericaLayers"] as? [[String: Any]] else {
            return nil
        }
        var regionLayers = object["regionLayers"] as? [[String: Any]] ?? northAmericaLayers

        if !includeLabels {
            globalLayers = globalLayers.filter { $0["type"] as? String != "symbol" }
            northAmericaLayers = northAmericaLayers.filter { $0["type"] as? String != "symbol" }
            regionLayers = regionLayers.filter { $0["type"] as? String != "symbol" }
        }
        return ProtomapsStyleTemplate(
            globalLayers: globalLayers,
            northAmericaLayers: northAmericaLayers,
            regionLayers: regionLayers
        )
    }

    private func sourceID(forRegionID regionID: String) -> String {
        "region-\(regionID)"
    }

    private static func titleizedRegionName(_ id: String) -> String {
        id
            .split(separator: "-")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func fallbackLayers(
        source: String,
        idPrefix: String,
        includeBackground: Bool,
        minZoom: Double?,
        includeLabels: Bool
    ) -> [[String: Any]] {
        var values: [[String: Any]] = []
        if includeBackground {
            values.append([
                "id": "background",
                "type": "background",
                "paint": ["background-color": "#d6ecf2"]
            ])
        }
        values.append(fillLayer(
            id: "\(idPrefix)-earth",
            source: source,
            sourceLayer: "earth",
            color: "#e6dfcf",
            minZoom: minZoom
        ))
        values.append(fillLayer(
            id: "\(idPrefix)-landcover",
            source: source,
            sourceLayer: "landcover",
            color: "#cfe5c4",
            opacity: 0.72,
            minZoom: minZoom
        ))
        values.append(fillLayer(
            id: "\(idPrefix)-landuse",
            source: source,
            sourceLayer: "landuse",
            color: "#d7ead0",
            opacity: 0.58,
            minZoom: minZoom
        ))
        values.append(fillLayer(
            id: "\(idPrefix)-water",
            source: source,
            sourceLayer: "water",
            color: "#86cfe0",
            minZoom: minZoom
        ))
        values.append(lineLayer(
            id: "\(idPrefix)-water-lines",
            source: source,
            sourceLayer: "water",
            color: "#65b9d0",
            width: [
                "interpolate", ["linear"], ["zoom"],
                5, 0.4,
                10, 1.2,
                14, 3.0
            ],
            minZoom: minZoom
        ))
        values.append(lineLayer(
            id: "\(idPrefix)-roads-casing",
            source: source,
            sourceLayer: "roads",
            color: "#d5cec0",
            width: [
                "interpolate", ["exponential", 1.45], ["zoom"],
                3, 0.2,
                6, 1.0,
                10, 3.0,
                14, 8.0
            ],
            minZoom: minZoom
        ))
        values.append(lineLayer(
            id: "\(idPrefix)-roads",
            source: source,
            sourceLayer: "roads",
            color: "#fffaf0",
            width: [
                "interpolate", ["exponential", 1.45], ["zoom"],
                3, 0.1,
                6, 0.55,
                10, 1.8,
                14, 5.5
            ],
            minZoom: minZoom
        ))
        values.append(lineLayer(
            id: "\(idPrefix)-boundaries",
            source: source,
            sourceLayer: "boundaries",
            color: "#8f8777",
            width: [
                "interpolate", ["linear"], ["zoom"],
                0, 0.45,
                6, 0.9,
                10, 1.4
            ],
            minZoom: minZoom,
            dashArray: [3, 2]
        ))
        if includeLabels {
            values.append(symbolLayer(
                id: "\(idPrefix)-places",
                source: source,
                sourceLayer: "places",
                minZoom: minZoom
            ))
        }
        return values
    }

    private func fillLayer(
        id: String,
        source: String,
        sourceLayer: String,
        color: String,
        opacity: Double = 1,
        minZoom: Double?
    ) -> [String: Any] {
        var layer: [String: Any] = [
            "id": id,
            "type": "fill",
            "source": source,
            "source-layer": sourceLayer,
            "paint": [
                "fill-color": color,
                "fill-opacity": opacity
            ]
        ]
        if let minZoom {
            layer["minzoom"] = minZoom
        }
        return layer
    }

    private func lineLayer(
        id: String,
        source: String,
        sourceLayer: String,
        color: String,
        width: [Any],
        minZoom: Double?,
        dashArray: [Double]? = nil
    ) -> [String: Any] {
        var paint: [String: Any] = [
            "line-color": color,
            "line-width": width
        ]
        if let dashArray {
            paint["line-dasharray"] = dashArray
        }
        var layer: [String: Any] = [
            "id": id,
            "type": "line",
            "source": source,
            "source-layer": sourceLayer,
            "paint": paint
        ]
        if let minZoom {
            layer["minzoom"] = minZoom
        }
        return layer
    }

    private func symbolLayer(
        id: String,
        source: String,
        sourceLayer: String,
        minZoom: Double?
    ) -> [String: Any] {
        var layer: [String: Any] = [
            "id": id,
            "type": "symbol",
            "source": source,
            "source-layer": sourceLayer,
            "filter": [
                "in",
                ["get", "kind"],
                ["literal", ["city", "town", "village", "country", "state"]]
            ],
            "layout": [
                "text-field": ["coalesce", ["get", "name:en"], ["get", "name"]],
                "text-font": ["Noto Sans Regular"],
                "text-size": [
                    "interpolate", ["linear"], ["zoom"],
                    2, 9,
                    5, 12,
                    10, 16
                ],
                "text-padding": 2
            ],
            "paint": [
                "text-color": "#344044",
                "text-halo-color": "#f7f1e6",
                "text-halo-width": 1
            ]
        ]
        if let minZoom {
            layer["minzoom"] = minZoom
        }
        return layer
    }

    private struct OfflineMapManifest: Decodable {
        let format: Int?
        let attribution: String?
        let global: Archive?
        let northAmerica: Archive?
        let region: Archive?
        let file: String?
        let bounds: [Double]?
        let minzoom: Double?
        let maxzoom: Double?
        let sizeBytes: Int64?
        let sha256: String?
        let displayName: String?
        let assets: Assets?

        var regionArchive: Archive? {
            // Production packages use { "region": { ... } }. Keep the flat
            // legacy format as a fallback for already-installed older maps.
            if let region { return region }
            let region = Archive(
                file: file,
                bounds: bounds,
                minzoom: minzoom,
                maxzoom: maxzoom,
                sizeBytes: sizeBytes,
                sha256: sha256,
                displayName: displayName
            )
            guard region.file != nil || region.bounds != nil || region.sizeBytes != nil || region.sha256 != nil else {
                return nil
            }
            return region
        }

        struct Archive: Decodable {
            let file: String?
            let bounds: [Double]?
            let minzoom: Double?
            let maxzoom: Double?
            let sizeBytes: Int64?
            let sha256: String?
            let displayName: String?
        }

        struct Assets: Decodable {
            let fonts: String?
            let sprite: String?
        }
    }

    private struct ProtomapsStyleTemplate {
        let globalLayers: [[String: Any]]
        let northAmericaLayers: [[String: Any]]
        let regionLayers: [[String: Any]]

        func layersForRegion(_ region: ArkFileOfflineMapArchive, sourceID: String) -> [[String: Any]] {
            let regionPrefix = "region-\(region.id ?? "street-level")"
            return regionLayers.map { layer in
                var updated = layer
                if let id = layer["id"] as? String {
                    let suffix = id.removingPrefix("north-america-")
                    updated["id"] = "\(regionPrefix)-\(suffix)"
                }
                if updated["source"] != nil {
                    updated["source"] = sourceID
                }
                if updated["type"] as? String != "background" {
                    let existingMinZoom = updated["minzoom"] as? Double
                    updated["minzoom"] = max(existingMinZoom ?? ArkFileOfflineMapResources.regionLayerMinZoom, ArkFileOfflineMapResources.regionLayerMinZoom)
                }
                return updated
            }
        }
    }
}

private extension Optional where Wrapped == URL {
    func unwrap() throws -> URL {
        guard let self else {
            throw ArkFileContentError.invalidResponse
        }
        return self
    }
}
