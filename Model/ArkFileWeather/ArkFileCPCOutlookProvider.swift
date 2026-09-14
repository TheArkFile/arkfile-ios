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
import ZIPFoundation

/// Downloads NOAA Climate Prediction Center national outlook polygons and
/// resolves them on-device. CPC receives no saved coordinate: every request is
/// for the same national KMZ artifact.
///
/// Official machine-source directory, verified 2026-07-23:
/// https://ftp.cpc.ncep.noaa.gov/GIS/us_tempprcpfcst/
///
/// The fixed allowlist is exactly `610temp_latest.kmz`,
/// `610prcp_latest.kmz`, `814temp_latest.kmz`, `814prcp_latest.kmz`,
/// `wk34temp_latest.kmz`, and `wk34prcp_latest.kmz` on that host.
actor ArkFileCPCOutlookProvider {
    static let providerHost = "ftp.cpc.ncep.noaa.gov"
    static let sourceID = "noaa-cpc-us-outlooks"
    static let defaultUserAgent =
        "ArkFile Saved Weather/1.0 (+https://thearkfile.com/support)"

    private static let maximumCompressedBodyBytes = 1_500_000
    private static let maximumKMLBytes = 2_000_000
    private static let maximumCompressionRatio: UInt64 = 32

    private let transport: any ArkFileWeatherTransport
    private let userAgent: String

    init(
        transport: any ArkFileWeatherTransport,
        userAgent: String = ArkFileCPCOutlookProvider.defaultUserAgent
    ) {
        self.transport = transport
        self.userAgent = Self.safeHeader(
            userAgent,
            fallback: Self.defaultUserAgent
        )
    }

    /// The six products form one provenance unit. A partial fetch never mixes a
    /// new variable/cycle with an older one; it records the failure against the
    /// complete last-known-good component and preserves that component's stamp.
    func refresh(
        coordinate: ArkFileWeatherCoordinate,
        prior: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        at now: Date = Date()
    ) async -> ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]> {
        guard coordinate.isValid, now.timeIntervalSince1970.isFinite else {
            return Self.recordFailure(
                on: prior,
                descriptor: .invalidInput,
                at: now.timeIntervalSince1970.isFinite ? now : Date()
            )
        }

        let transport = transport
        let userAgent = userAgent
        let priorProducts = Self.cachedProducts(from: prior, at: now)
        let outcomes = await withTaskGroup(
            of: ProductOutcome.self,
            returning: [ProductOutcome].self
        ) { group in
            for product in Product.allCases {
                group.addTask {
                    await Self.fetch(
                        product: product,
                        coordinate: coordinate,
                        transport: transport,
                        userAgent: userAgent,
                        prior: priorProducts[product],
                        now: now
                    )
                }
            }
            var values: [ProductOutcome] = []
            values.reserveCapacity(Product.allCases.count)
            for await value in group {
                values.append(value)
            }
            return values.sorted { $0.product.sortIndex < $1.product.sortIndex }
        }

        var successful: [Product: FetchedProduct] = [:]
        var failures: [FailureDescriptor] = []
        for outcome in outcomes {
            switch outcome.result {
            case let .success(value):
                successful[outcome.product] = value
            case let .failure(failure):
                failures.append(failure)
            }
        }

        guard failures.isEmpty,
              successful.count == Product.allCases.count else {
            return Self.recordFailure(
                on: prior,
                descriptor: Self.collapsedFailure(failures),
                at: now
            )
        }

        var outlooks: [ArkFileWeatherClimateOutlook] = []
        var hasNewDistribution = false

        for period in Product.Period.allCases {
            let temperatureProduct = Product(period: period, variable: .temperature)
            let precipitationProduct = Product(period: period, variable: .precipitation)
            guard let temperature = successful[temperatureProduct],
                  let precipitation = successful[precipitationProduct] else {
                return Self.recordFailure(
                    on: prior,
                    descriptor: .incomplete,
                    at: now
                )
            }
            guard temperature.parsed.validFrom == precipitation.parsed.validFrom,
                  temperature.parsed.validUntil == precipitation.parsed.validUntil else {
                return Self.recordFailure(
                    on: prior,
                    descriptor: .cycleMismatch,
                    at: now
                )
            }
            let anchor = temperature.parsed.issuedAt >= precipitation.parsed.issuedAt
                ? temperature.parsed
                : precipitation.parsed
            let temperatureDistribution = Self.distribution(
                from: temperature.parsed,
                matching: anchor,
                prior: nil
            )
            let precipitationDistribution = Self.distribution(
                from: precipitation.parsed,
                matching: anchor,
                prior: nil
            )
            hasNewDistribution = hasNewDistribution
                || temperature.parsed.distribution?.hasKnownValue == true
                || precipitation.parsed.distribution?.hasKnownValue == true

            outlooks.append(
                ArkFileWeatherClimateOutlook(
                    id: Self.outlookID(period: period, anchor: anchor),
                    period: period.modelValue,
                    issuedAt: anchor.issuedAt,
                    validFrom: anchor.validFrom,
                    validUntil: anchor.validUntil,
                    temperature: temperatureDistribution,
                    precipitation: precipitationDistribution
                )
            )
        }

        outlooks.sort { $0.period.sortIndex < $1.period.sortIndex }
        let sourceProducts = Product.allCases.compactMap {
            successful[$0]?.sourceProduct(productID: $0.baseName)
        }
        guard sourceProducts.count == Product.allCases.count else {
            return Self.recordFailure(
                on: prior,
                descriptor: .incomplete,
                at: now
            )
        }

        // Six authoritative products with no matching polygon establish a
        // dated successful-empty result. Its stamp prevents alert-cadence core
        // refreshes from redownloading the national CPC set repeatedly.
        if !hasNewDistribution {
            return .successfulEmpty(
                stamp: Self.stamp(
                    for: outlooks,
                    sourceProducts: sourceProducts,
                    at: now
                )
            )
        }

        let stamp = Self.stamp(
            for: outlooks,
            sourceProducts: sourceProducts,
            at: now
        )
        return .available(outlooks, stamp: stamp)
    }
}

// MARK: - Requests and archive handling

private extension ArkFileCPCOutlookProvider {
    enum Variable: Sendable {
        case temperature
        case precipitation
    }

    enum Product: CaseIterable, Hashable, Sendable {
        enum Period: CaseIterable, Sendable {
            case sixToTen
            case eightToFourteen
            case weekThreeToFour

            var modelValue: ArkFileWeatherOutlookPeriodKind {
                switch self {
                case .sixToTen: .sixToTenDay
                case .eightToFourteen: .eightToFourteenDay
                case .weekThreeToFour: .weekThreeToFour
                }
            }
        }

        case sixToTenTemperature
        case sixToTenPrecipitation
        case eightToFourteenTemperature
        case eightToFourteenPrecipitation
        case weekThreeToFourTemperature
        case weekThreeToFourPrecipitation

        init(period: Period, variable: Variable) {
            switch (period, variable) {
            case (.sixToTen, .temperature): self = .sixToTenTemperature
            case (.sixToTen, .precipitation): self = .sixToTenPrecipitation
            case (.eightToFourteen, .temperature): self = .eightToFourteenTemperature
            case (.eightToFourteen, .precipitation): self = .eightToFourteenPrecipitation
            case (.weekThreeToFour, .temperature): self = .weekThreeToFourTemperature
            case (.weekThreeToFour, .precipitation): self = .weekThreeToFourPrecipitation
            }
        }

        var period: Period {
            switch self {
            case .sixToTenTemperature, .sixToTenPrecipitation: .sixToTen
            case .eightToFourteenTemperature, .eightToFourteenPrecipitation:
                .eightToFourteen
            case .weekThreeToFourTemperature, .weekThreeToFourPrecipitation:
                .weekThreeToFour
            }
        }

        var variable: Variable {
            switch self {
            case .sixToTenTemperature,
                 .eightToFourteenTemperature,
                 .weekThreeToFourTemperature:
                .temperature
            case .sixToTenPrecipitation,
                 .eightToFourteenPrecipitation,
                 .weekThreeToFourPrecipitation:
                .precipitation
            }
        }

        var baseName: String {
            switch self {
            case .sixToTenTemperature: "610temp_latest"
            case .sixToTenPrecipitation: "610prcp_latest"
            case .eightToFourteenTemperature: "814temp_latest"
            case .eightToFourteenPrecipitation: "814prcp_latest"
            case .weekThreeToFourTemperature: "wk34temp_latest"
            case .weekThreeToFourPrecipitation: "wk34prcp_latest"
            }
        }

        var sortIndex: Int {
            Self.allCases.firstIndex(of: self) ?? .max
        }
    }

    struct ProductOutcome: Sendable {
        let product: Product
        let result: Result<FetchedProduct, FailureDescriptor>
    }

    struct CachedProduct: Sendable {
        let parsed: ParsedProduct
        let validators: ArkFileWeatherHTTPValidators
    }

    struct FetchedProduct: Sendable {
        let parsed: ParsedProduct
        let validators: ArkFileWeatherHTTPValidators

        func sourceProduct(
            productID: String
        ) -> ArkFileWeatherClimateSourceProduct {
            ArkFileWeatherClimateSourceProduct(
                productID: productID,
                issuedAt: parsed.issuedAt,
                validFrom: parsed.validFrom,
                validUntil: parsed.validUntil,
                distribution: parsed.distribution,
                entityTag: validators.entityTag,
                lastModified: validators.lastModified
            )
        }
    }

    struct FailureDescriptor: Error, Equatable, Sendable {
        let kind: ArkFileWeatherFailureKind
        let retryAfter: Date?
        let providerCode: String

        static let invalidInput = Self(
            kind: .invalidResponse,
            retryAfter: nil,
            providerCode: "invalid_input"
        )
        static let cycleMismatch = Self(
            kind: .invalidResponse,
            retryAfter: nil,
            providerCode: "cycle_mismatch"
        )
        static let incomplete = Self(
            kind: .invalidResponse,
            retryAfter: nil,
            providerCode: "incomplete"
        )
    }

    static func fetch(
        product: Product,
        coordinate: ArkFileWeatherCoordinate,
        transport: any ArkFileWeatherTransport,
        userAgent: String,
        prior: CachedProduct?,
        now: Date
    ) async -> ProductOutcome {
        guard let url = URL(
            string: "https://\(providerHost)/GIS/us_tempprcpfcst/\(product.baseName).kmz"
        ) else {
            return ProductOutcome(product: product, result: .failure(.invalidInput))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/vnd.google-earth.kmz",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        prior?.validators.apply(to: &request)

        do {
            let response = try await transport.response(
                for: request,
                maximumBodyBytes: maximumCompressedBodyBytes
            )
            try validateDestination(response, requestedURL: url)
            if response.statusCode == 304 {
                guard let prior,
                      !prior.validators.isEmpty,
                      response.body.isEmpty else {
                    throw FailureDescriptor(
                        kind: .invalidResponse,
                        retryAfter: nil,
                        providerCode: "invalid_not_modified"
                    )
                }
                try validateCycle(prior.parsed, at: now)
                let returned = normalizedValidators(response.validators)
                return ProductOutcome(
                    product: product,
                    result: .success(
                        FetchedProduct(
                            parsed: prior.parsed,
                            validators: ArkFileWeatherHTTPValidators(
                                entityTag: returned.entityTag
                                    ?? prior.validators.entityTag,
                                lastModified: returned.lastModified
                                    ?? prior.validators.lastModified
                            )
                        )
                    )
                )
            }
            try validate(response: response, requestedURL: url, now: now)
            let kml = try extractKML(
                from: response.body,
                expectedFileName: "\(product.baseName).kml"
            )
            let parsed = try CPCStreamingKMLParser.parse(
                kml,
                coordinate: coordinate
            )
            try validateCycle(parsed, at: now)
            return ProductOutcome(
                product: product,
                result: .success(
                    FetchedProduct(
                        parsed: parsed,
                        validators: normalizedValidators(response.validators)
                    )
                )
            )
        } catch let failure as FailureDescriptor {
            return ProductOutcome(product: product, result: .failure(failure))
        } catch let error as URLError {
            return ProductOutcome(
                product: product,
                result: .failure(networkFailure(error))
            )
        } catch let error as ArkFileWeatherTransportError {
            let code: String
            switch error {
            case .responseTooLarge: code = "body_limit"
            case .untrustedDestination: code = "destination"
            case .nonHTTPResponse: code = "http_response"
            case .invalidMaximumBodySize: code = "transport_configuration"
            }
            return ProductOutcome(
                product: product,
                result: .failure(
                    FailureDescriptor(
                        kind: .invalidResponse,
                        retryAfter: nil,
                        providerCode: code
                    )
                )
            )
        } catch is CPCArchiveError {
            return ProductOutcome(
                product: product,
                result: .failure(
                    FailureDescriptor(
                        kind: .integrity,
                        retryAfter: nil,
                        providerCode: "archive"
                    )
                )
            )
        } catch {
            return ProductOutcome(
                product: product,
                result: .failure(
                    FailureDescriptor(
                        kind: .invalidResponse,
                        retryAfter: nil,
                        providerCode: "kml"
                    )
                )
            )
        }
    }

    static func validate(
        response: ArkFileWeatherHTTPResponse,
        requestedURL: URL,
        now: Date
    ) throws {
        try validateDestination(response, requestedURL: requestedURL)
        guard response.statusCode == 200 else {
            let kind: ArkFileWeatherFailureKind
            if response.statusCode == 429 {
                kind = .rateLimited
            } else if (500 ... 599).contains(response.statusCode) {
                kind = .server
            } else {
                kind = .invalidResponse
            }
            throw FailureDescriptor(
                kind: kind,
                retryAfter: (response.statusCode == 429
                    || (500 ... 599).contains(response.statusCode))
                    ? response.retryAfterDate(relativeTo: now)
                        ?? now.addingTimeInterval(15 * 60)
                    : nil,
                providerCode: "http_status"
            )
        }
        let allowedMIMETypes: Set<String> = [
            "application/vnd.google-earth.kmz",
            "application/zip",
            "application/octet-stream"
        ]
        guard let mimeType = response.mimeType?.lowercased(),
              allowedMIMETypes.contains(mimeType),
              !response.body.isEmpty,
              response.body.count <= maximumCompressedBodyBytes else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "response_bounds"
            )
        }
    }

    static func validateDestination(
        _ response: ArkFileWeatherHTTPResponse,
        requestedURL: URL
    ) throws {
        guard response.finalURL == requestedURL,
              response.finalURL.scheme?.lowercased() == "https",
              response.finalURL.host?.lowercased() == providerHost,
              response.finalURL.port == nil || response.finalURL.port == 443,
              response.finalURL.user == nil,
              response.finalURL.password == nil else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "destination"
            )
        }
    }

    static func extractKML(
        from data: Data,
        expectedFileName: String
    ) throws -> Data {
        try CPCZIPPreflight.validate(
            data,
            expectedFileName: expectedFileName,
            maximumKMLBytes: maximumKMLBytes,
            maximumCompressionRatio: maximumCompressionRatio
        )
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw CPCArchiveError.malformed
        }
        let entries = Array(archive)
        guard entries.count == 1,
              let entry = entries.first,
              entry.type == .file,
              entry.path == expectedFileName,
              entry.uncompressedSize > 0,
              entry.uncompressedSize <= UInt64(maximumKMLBytes) else {
            throw CPCArchiveError.invalidEntry
        }

        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        do {
            let checksum = try archive.extract(
                entry,
                bufferSize: 64 * 1_024,
                skipCRC32: false
            ) { chunk in
                guard result.count <= maximumKMLBytes - chunk.count else {
                    throw CPCArchiveError.expandedTooLarge
                }
                result.append(chunk)
            }
            guard checksum == entry.checksum,
                  result.count == Int(entry.uncompressedSize) else {
                throw CPCArchiveError.checksum
            }
        } catch let error as CPCArchiveError {
            throw error
        } catch {
            throw CPCArchiveError.checksum
        }
        return result
    }

    static func validateCycle(_ product: ParsedProduct, at now: Date) throws {
        let day: TimeInterval = 24 * 60 * 60
        guard product.issuedAt.timeIntervalSince1970.isFinite,
              product.validFrom.timeIntervalSince1970.isFinite,
              product.validUntil.timeIntervalSince1970.isFinite,
              product.issuedAt >= now.addingTimeInterval(-14 * day),
              product.issuedAt <= now.addingTimeInterval(day),
              product.validFrom >= now.addingTimeInterval(-14 * day),
              product.validFrom <= now.addingTimeInterval(35 * day),
              product.validUntil > now,
              product.validUntil <= now.addingTimeInterval(45 * day) else {
            throw FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "cycle_time"
            )
        }
    }
}

private enum CPCArchiveError: Error {
    case malformed
    case invalidEntry
    case encrypted
    case unsupportedCompression
    case expandedTooLarge
    case suspiciousRatio
    case checksum
}

/// ZIPFoundation deliberately hides encrypted entries from iteration, so a
/// raw central-directory preflight is required before extraction.
private enum CPCZIPPreflight {
    static func validate(
        _ data: Data,
        expectedFileName: String,
        maximumKMLBytes: Int,
        maximumCompressionRatio: UInt64
    ) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 22,
              let endOffset = endOfCentralDirectory(in: bytes),
              read32(bytes, endOffset) == 0x0605_4b50,
              read16(bytes, endOffset + 4) == 0,
              read16(bytes, endOffset + 6) == 0,
              read16(bytes, endOffset + 8) == 1,
              read16(bytes, endOffset + 10) == 1,
              let centralSize = read32(bytes, endOffset + 12),
              let centralOffset = read32(bytes, endOffset + 16),
              let commentLength = read16(bytes, endOffset + 20),
              endOffset + 22 + Int(commentLength) == bytes.count,
              centralSize != UInt32.max,
              centralOffset != UInt32.max,
              Int(centralOffset) + Int(centralSize) == endOffset else {
            throw CPCArchiveError.malformed
        }

        let offset = Int(centralOffset)
        guard read32(bytes, offset) == 0x0201_4b50,
              let flags = read16(bytes, offset + 8),
              let method = read16(bytes, offset + 10),
              let compressed = read32(bytes, offset + 20),
              let uncompressed = read32(bytes, offset + 24),
              let nameLength = read16(bytes, offset + 28),
              let extraLength = read16(bytes, offset + 30),
              let entryCommentLength = read16(bytes, offset + 32),
              read16(bytes, offset + 34) == 0,
              let externalAttributes = read32(bytes, offset + 38),
              let localOffset = read32(bytes, offset + 42) else {
            throw CPCArchiveError.malformed
        }
        guard flags & 0x0001 == 0, flags & 0x0040 == 0 else {
            throw CPCArchiveError.encrypted
        }
        guard method == 0 || method == 8 else {
            throw CPCArchiveError.unsupportedCompression
        }
        let nameStart = offset + 46
        let centralEnd = nameStart
            + Int(nameLength)
            + Int(extraLength)
            + Int(entryCommentLength)
        guard centralEnd == endOffset,
              let fileName = utf8(bytes, nameStart, Int(nameLength)),
              fileName == expectedFileName,
              fileName.count <= 64,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("..") else {
            throw CPCArchiveError.invalidEntry
        }

        let madeByOS = (read16(bytes, offset + 4) ?? 0) >> 8
        if madeByOS == 3 || madeByOS == 19 {
            let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
            let fileType = mode & 0o170000
            guard fileType == 0 || fileType == 0o100000 else {
                throw CPCArchiveError.invalidEntry
            }
        }

        let compressed64 = UInt64(compressed)
        let uncompressed64 = UInt64(uncompressed)
        guard compressed64 > 0,
              uncompressed64 > 0,
              uncompressed64 <= UInt64(maximumKMLBytes) else {
            throw CPCArchiveError.expandedTooLarge
        }
        guard uncompressed64 <= compressed64 * maximumCompressionRatio else {
            throw CPCArchiveError.suspiciousRatio
        }

        let local = Int(localOffset)
        guard read32(bytes, local) == 0x0403_4b50,
              read16(bytes, local + 6) == flags,
              read16(bytes, local + 8) == method,
              let localNameLength = read16(bytes, local + 26),
              let localExtraLength = read16(bytes, local + 28),
              let localName = utf8(bytes, local + 30, Int(localNameLength)),
              localName == fileName else {
            throw CPCArchiveError.malformed
        }
        let payloadStart = local + 30 + Int(localNameLength) + Int(localExtraLength)
        guard payloadStart >= 0,
              payloadStart <= offset,
              Int(compressed) <= offset - payloadStart else {
            throw CPCArchiveError.malformed
        }
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        let lowerBound = max(0, bytes.count - 65_557)
        guard bytes.count >= 22 else { return nil }
        for index in stride(from: bytes.count - 22, through: lowerBound, by: -1) {
            if read32(bytes, index) == 0x0605_4b50 {
                return index
            }
        }
        return nil
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func utf8(
        _ bytes: [UInt8],
        _ offset: Int,
        _ length: Int
    ) -> String? {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else {
            return nil
        }
        return String(bytes: bytes[offset ..< offset + length], encoding: .utf8)
    }
}

// MARK: - Bounded streaming KML parser

private struct ParsedProduct: Equatable, Sendable {
    let issuedAt: Date
    let validFrom: Date
    /// Exclusive end: CPC's printed End Date is inclusive.
    let validUntil: Date
    let distribution: ArkFileWeatherProbabilityDistribution?
}

private final class CPCStreamingKMLParser: NSObject, XMLParserDelegate {
    private static let maximumKMLBytes = 2_000_000
    private static let maximumElements = 200_000
    private static let maximumDepth = 64
    private static let maximumPlacemarks = 256
    private static let maximumPolygons = 1_024
    private static let maximumCoordinateTuples = 150_000
    private static let maximumDescriptionBytes = 32_768
    private static let maximumCoordinateTextBytes = 1_500_000

    private enum Capture {
        case description
        case coordinates
    }

    private enum Boundary {
        case outer
        case inner
    }

    private struct PolygonState {
        var sawOuter = false
        var outerContainsPoint = false
        var innerContainsPoint = false
    }

    private struct PlacemarkState {
        var metadata: Metadata?
        var polygonCount = 0
        var containsPoint = false
    }

    private struct Metadata: Equatable {
        enum Category: Int {
            case equalChances = 0
            case below = 1
            case near = 2
            case above = 3
        }

        let issuedAt: Date
        let validFrom: Date
        let validUntil: Date
        let probability: Double
        let category: Category

        var distribution: ArkFileWeatherProbabilityDistribution {
            if category == .equalChances {
                let third = 1.0 / 3.0
                return ArkFileWeatherProbabilityDistribution(
                    belowNormalFraction: third,
                    nearNormalFraction: third,
                    aboveNormalFraction: third
                )
            }
            let favored = probability / 100
            // CPC publishes the favored category probability, not a complete
            // three-bin distribution. Do not invent precision by splitting the
            // unreported remainder between the other categories.
            switch category {
            case .below:
                return ArkFileWeatherProbabilityDistribution(
                    belowNormalFraction: favored,
                    nearNormalFraction: nil,
                    aboveNormalFraction: nil
                )
            case .near:
                return ArkFileWeatherProbabilityDistribution(
                    belowNormalFraction: nil,
                    nearNormalFraction: favored,
                    aboveNormalFraction: nil
                )
            case .above:
                return ArkFileWeatherProbabilityDistribution(
                    belowNormalFraction: nil,
                    nearNormalFraction: nil,
                    aboveNormalFraction: favored
                )
            case .equalChances:
                preconditionFailure("Handled above")
            }
        }
    }

    private let point: ArkFileWeatherCoordinate
    private var depth = 0
    private var elementCount = 0
    private var placemarkCount = 0
    private var polygonCount = 0
    private var coordinateTupleCount = 0
    private var capture: Capture?
    private var capturedText = ""
    private var capturedByteCount = 0
    private var boundary: Boundary?
    private var polygon: PolygonState?
    private var placemark: PlacemarkState?
    private var sharedMetadata: Metadata?
    private var selectedMetadata: Metadata?
    private var failure: Error?

    private init(point: ArkFileWeatherCoordinate) {
        self.point = point
    }

    static func parse(
        _ data: Data,
        coordinate: ArkFileWeatherCoordinate
    ) throws -> ParsedProduct {
        guard data.count <= maximumKMLBytes,
              let source = String(data: data, encoding: .utf8) else {
            throw CPCParseError.encoding
        }
        let lower = source.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else {
            throw CPCParseError.unsafeXML
        }

        let delegate = CPCStreamingKMLParser(point: coordinate)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard parsed,
              let metadata = delegate.sharedMetadata,
              delegate.placemarkCount > 0 else {
            throw CPCParseError.malformed
        }
        return ParsedProduct(
            issuedAt: metadata.issuedAt,
            validFrom: metadata.validFrom,
            validUntil: metadata.validUntil,
            distribution: delegate.selectedMetadata?.distribution
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        depth += 1
        elementCount += 1
        guard depth <= Self.maximumDepth,
              elementCount <= Self.maximumElements else {
            return abort(parser, .semanticBounds)
        }

        switch elementName.lowercased() {
        case "placemark":
            placemarkCount += 1
            guard placemark == nil,
                  placemarkCount <= Self.maximumPlacemarks else {
                return abort(parser, .semanticBounds)
            }
            placemark = PlacemarkState()
        case "polygon":
            polygonCount += 1
            guard placemark != nil,
                  polygon == nil,
                  polygonCount <= Self.maximumPolygons else {
                return abort(parser, .semanticBounds)
            }
            polygon = PolygonState()
        case "outerboundaryis":
            guard polygon != nil, boundary == nil else {
                return abort(parser, .malformed)
            }
            boundary = .outer
        case "innerboundaryis":
            guard polygon != nil, boundary == nil else {
                return abort(parser, .malformed)
            }
            boundary = .inner
        case "description":
            if placemark != nil {
                beginCapture(.description)
            }
        case "coordinates":
            guard polygon != nil, boundary != nil else {
                return abort(parser, .malformed)
            }
            beginCapture(.coordinates)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            return abort(parser, .encoding)
        }
        append(string, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { depth -= 1 }
        guard failure == nil else { return }

        switch elementName.lowercased() {
        case "description" where capture == .description:
            guard let metadata = Self.parseMetadata(capturedText) else {
                return abort(parser, .metadata)
            }
            placemark?.metadata = metadata
            endCapture()
        case "coordinates" where capture == .coordinates:
            do {
                let contains = try ringContainsPoint(capturedText)
                switch boundary {
                case .outer:
                    guard polygon?.sawOuter == false else {
                        return abort(parser, .malformed)
                    }
                    polygon?.sawOuter = true
                    polygon?.outerContainsPoint = contains
                case .inner:
                    if var currentPolygon = polygon {
                        currentPolygon.innerContainsPoint =
                            currentPolygon.innerContainsPoint || contains
                        polygon = currentPolygon
                    }
                case nil:
                    return abort(parser, .malformed)
                }
                endCapture()
            } catch let error as CPCParseError {
                abort(parser, error)
            } catch {
                abort(parser, .coordinates)
            }
        case "outerboundaryis", "innerboundaryis":
            boundary = nil
        case "polygon":
            guard let polygon, polygon.sawOuter else {
                return abort(parser, .malformed)
            }
            placemark?.polygonCount += 1
            if polygon.outerContainsPoint, !polygon.innerContainsPoint {
                placemark?.containsPoint = true
            }
            self.polygon = nil
        case "placemark":
            guard let placemark,
                  let metadata = placemark.metadata,
                  placemark.polygonCount > 0 else {
                return abort(parser, .metadata)
            }
            if let sharedMetadata {
                guard sharedMetadata.issuedAt == metadata.issuedAt,
                      sharedMetadata.validFrom == metadata.validFrom,
                      sharedMetadata.validUntil == metadata.validUntil else {
                    return abort(parser, .metadata)
                }
            } else {
                sharedMetadata = metadata
            }
            if placemark.containsPoint, shouldSelect(metadata) {
                selectedMetadata = metadata
            }
            self.placemark = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil {
            failure = CPCParseError.malformed
        }
    }

    private func beginCapture(_ capture: Capture) {
        self.capture = capture
        capturedText.removeAll(keepingCapacity: true)
        capturedByteCount = 0
    }

    private func endCapture() {
        capture = nil
        capturedText.removeAll(keepingCapacity: true)
        capturedByteCount = 0
    }

    private func append(_ string: String, parser: XMLParser) {
        guard let capture else { return }
        capturedByteCount += string.utf8.count
        let limit = capture == .description
            ? Self.maximumDescriptionBytes
            : Self.maximumCoordinateTextBytes
        guard capturedByteCount <= limit else {
            return abort(parser, .semanticBounds)
        }
        capturedText.append(string)
    }

    private func shouldSelect(_ metadata: Metadata) -> Bool {
        guard let selectedMetadata else { return true }
        if metadata.probability != selectedMetadata.probability {
            return metadata.probability > selectedMetadata.probability
        }
        return metadata.category.rawValue > selectedMetadata.category.rawValue
    }

    private func ringContainsPoint(_ text: String) throws -> Bool {
        let tuples = text.split(whereSeparator: { $0.isWhitespace })
        guard tuples.count >= 4 else { throw CPCParseError.coordinates }
        coordinateTupleCount += tuples.count
        guard coordinateTupleCount <= Self.maximumCoordinateTuples else {
            throw CPCParseError.semanticBounds
        }

        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(tuples.count)
        for tuple in tuples {
            let parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  let longitude = Double(parts[0]),
                  let latitude = Double(parts[1]),
                  longitude.isFinite,
                  latitude.isFinite,
                  (-180 ... 180).contains(longitude),
                  (-90 ... 90).contains(latitude),
                  parts.count != 3 || Double(parts[2])?.isFinite == true else {
                throw CPCParseError.coordinates
            }
            points.append((
                Self.longitude(longitude, relativeTo: point.longitude),
                latitude
            ))
        }
        guard let first = points.first, let last = points.last,
              abs(first.x - last.x) <= 1e-8,
              abs(first.y - last.y) <= 1e-8 else {
            throw CPCParseError.coordinates
        }
        return Self.contains(
            x: point.longitude,
            y: point.latitude,
            ring: points
        )
    }

    private static func longitude(_ value: Double, relativeTo origin: Double) -> Double {
        var normalized = value
        while normalized - origin > 180 { normalized -= 360 }
        while normalized - origin < -180 { normalized += 360 }
        return normalized
    }

    private static func contains(
        x: Double,
        y: Double,
        ring: [(x: Double, y: Double)]
    ) -> Bool {
        var inside = false
        for index in 0 ..< ring.count - 1 {
            let start = ring[index]
            let end = ring[index + 1]
            if pointOnSegment(x: x, y: y, start: start, end: end) {
                return true
            }
            let crosses = (start.y > y) != (end.y > y)
            if crosses {
                let intersection = (end.x - start.x)
                    * (y - start.y)
                    / (end.y - start.y)
                    + start.x
                if intersection > x {
                    inside.toggle()
                }
            }
        }
        return inside
    }

    private static func pointOnSegment(
        x: Double,
        y: Double,
        start: (x: Double, y: Double),
        end: (x: Double, y: Double)
    ) -> Bool {
        let cross = (x - start.x) * (end.y - start.y)
            - (y - start.y) * (end.x - start.x)
        let scale = max(
            1,
            abs(end.x - start.x),
            abs(end.y - start.y)
        )
        guard abs(cross) <= 1e-10 * scale else { return false }
        return x >= min(start.x, end.x) - 1e-10
            && x <= max(start.x, end.x) + 1e-10
            && y >= min(start.y, end.y) - 1e-10
            && y <= max(start.y, end.y) + 1e-10
    }

    private static func parseMetadata(_ html: String) -> Metadata? {
        guard let issuedText = tableValue("Fcst Date", in: html),
              let startText = tableValue("Start Date", in: html),
              let endText = tableValue("End Date", in: html),
              let probabilityText = tableValue("Probability", in: html),
              let categoryText = tableValue("Category", in: html),
              let issuedAt = parseDay(issuedText),
              let validFrom = parseDay(startText),
              let inclusiveEnd = parseDay(endText),
              let validUntil = Calendar.utc.date(
                  byAdding: .day,
                  value: 1,
                  to: inclusiveEnd
              ),
              let probability = Double(probabilityText),
              probability.isFinite,
              (33 ... 100).contains(probability),
              issuedAt <= validUntil,
              validFrom < validUntil,
              validUntil.timeIntervalSince(validFrom) <= 45 * 86_400 else {
            return nil
        }
        let category: Metadata.Category
        switch categoryText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "above", "a":
            category = .above
        case "below", "b":
            category = .below
        case "normal", "near normal", "n":
            category = .near
        case "ec", "equal chances":
            category = .equalChances
        default:
            return nil
        }
        return Metadata(
            issuedAt: issuedAt,
            validFrom: validFrom,
            validUntil: validUntil,
            probability: probability,
            category: category
        )
    }

    private static func tableValue(_ label: String, in source: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern =
            #"<td(?:\s+[^>]*)?>\s*"# + escaped
            + #"\s*</td>\s*<td(?:\s+[^>]*)?>\s*([^<]{1,64})\s*</td>"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = expression.firstMatch(
            in: source,
            range: range
        ),
            let valueRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[valueRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDay(_ value: String) -> Date? {
        let parts = value.split(separator: "/")
        guard parts.count == 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let year = Int(parts[2]),
              (1900 ... 2200).contains(year) else {
            return nil
        }
        return Calendar.utc.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: year,
                month: month,
                day: day
            )
        )
    }

    private func abort(_ parser: XMLParser, _ error: CPCParseError) {
        failure = error
        parser.abortParsing()
    }
}

private enum CPCParseError: Error {
    case encoding
    case unsafeXML
    case malformed
    case metadata
    case coordinates
    case semanticBounds
}

// MARK: - Merge, stamps, and normalized failures

private extension ArkFileCPCOutlookProvider {
    static func cachedProducts(
        from prior: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        at now: Date
    ) -> [Product: CachedProduct] {
        guard prior.stamp?.sourceID == sourceID,
              let sourceProducts = prior.stamp?.climateSourceProducts else {
            return [:]
        }
        var result: [Product: CachedProduct] = [:]
        for product in Product.allCases {
            let matches = sourceProducts.filter {
                $0.productID == product.baseName
            }
            guard matches.count == 1, let source = matches.first else {
                continue
            }
            let parsed = ParsedProduct(
                issuedAt: source.issuedAt,
                validFrom: source.validFrom,
                validUntil: source.validUntil,
                distribution: source.distribution
            )
            guard isValidCachedDistribution(source.distribution),
                  (try? validateCycle(parsed, at: now)) != nil else {
                continue
            }
            result[product] = CachedProduct(
                parsed: parsed,
                validators: normalizedValidators(
                    ArkFileWeatherHTTPValidators(
                        entityTag: source.entityTag,
                        lastModified: source.lastModified
                    )
                )
            )
        }
        return result
    }

    static func isValidCachedDistribution(
        _ distribution: ArkFileWeatherProbabilityDistribution?
    ) -> Bool {
        guard let distribution else {
            return true
        }
        let values = [
            distribution.belowNormalFraction,
            distribution.nearNormalFraction,
            distribution.aboveNormalFraction
        ].compactMap { $0 }
        return values.allSatisfy {
            $0.isFinite && (0 ... 1).contains($0)
        } && values.reduce(0, +) <= 1.000_001
    }

    static func normalizedValidators(
        _ validators: ArkFileWeatherHTTPValidators
    ) -> ArkFileWeatherHTTPValidators {
        ArkFileWeatherHTTPValidators(
            entityTag: safeValidator(validators.entityTag),
            lastModified: safeValidator(validators.lastModified)
        )
    }

    static func safeValidator(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7f
              }) else {
            return nil
        }
        return trimmed
    }

    static let unknownDistribution = ArkFileWeatherProbabilityDistribution(
        belowNormalFraction: nil,
        nearNormalFraction: nil,
        aboveNormalFraction: nil
    )

    static func distribution(
        from product: ParsedProduct?,
        matching anchor: ParsedProduct,
        prior: ArkFileWeatherProbabilityDistribution?
    ) -> ArkFileWeatherProbabilityDistribution {
        guard let product else {
            return prior ?? unknownDistribution
        }
        guard product.validFrom == anchor.validFrom,
              product.validUntil == anchor.validUntil else {
            return prior ?? unknownDistribution
        }
        // A successful no-match is authoritative for that product and must not
        // revive an older probability contour.
        return product.distribution ?? unknownDistribution
    }

    static func outlookID(
        period: Product.Period,
        anchor: ParsedProduct
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .utc
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return [
            "cpc",
            period.modelValue.rawValue,
            formatter.string(from: anchor.validFrom),
            formatter.string(from: anchor.validUntil)
        ].joined(separator: "-")
    }

    static func stamp(
        for outlooks: [ArkFileWeatherClimateOutlook],
        sourceProducts: [ArkFileWeatherClimateSourceProduct],
        at now: Date
    ) -> ArkFileWeatherComponentStamp {
        let issuedAt = outlooks.map(\.issuedAt).max()
        let validFrom = outlooks.map(\.validFrom).min()
        let validUntil = outlooks.map(\.validUntil).max()
        // A successful download does not extend CPC's official validity.
        let expiresAt = validUntil ?? now
        let freshUntil = min(
            now.addingTimeInterval(24 * 60 * 60),
            expiresAt
        )
        let agingUntil = min(
            now.addingTimeInterval(3 * 24 * 60 * 60),
            expiresAt
        )
        return ArkFileWeatherComponentStamp(
            sourceID: sourceID,
            issuedAt: issuedAt,
            fetchedAt: now,
            validFrom: validFrom,
            validUntil: validUntil,
            freshUntil: freshUntil,
            agingUntil: agingUntil,
            expiresAt: expiresAt,
            historicalAt: expiresAt.addingTimeInterval(28 * 24 * 60 * 60),
            entityTag: nil,
            lastModified: nil,
            climateSourceProducts: sourceProducts
        )
    }

    static func recordFailure(
        on prior: ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]>,
        descriptor: FailureDescriptor,
        at now: Date
    ) -> ArkFileWeatherComponent<[ArkFileWeatherClimateOutlook]> {
        prior.recordingFailure(componentFailure(descriptor, at: now))
    }

    static func componentFailure(
        _ descriptor: FailureDescriptor,
        at now: Date
    ) -> ArkFileWeatherComponentFailure {
        ArkFileWeatherComponentFailure(
            kind: descriptor.kind,
            occurredAt: now,
            retryAfter: descriptor.retryAfter,
            providerCode: descriptor.providerCode
        )
    }

    static func collapsedFailure(
        _ failures: [FailureDescriptor]
    ) -> FailureDescriptor {
        guard !failures.isEmpty else {
            return FailureDescriptor(
                kind: .invalidResponse,
                retryAfter: nil,
                providerCode: "incomplete"
            )
        }
        let kind: ArkFileWeatherFailureKind
        if failures.contains(where: { $0.kind == .rateLimited }) {
            kind = .rateLimited
        } else if failures.contains(where: { $0.kind == .offline }) {
            kind = .offline
        } else if failures.contains(where: { $0.kind == .timedOut }) {
            kind = .timedOut
        } else if failures.contains(where: { $0.kind == .server }) {
            kind = .server
        } else if failures.contains(where: { $0.kind == .integrity }) {
            kind = .integrity
        } else {
            kind = .invalidResponse
        }
        return FailureDescriptor(
            kind: kind,
            retryAfter: failures.compactMap(\.retryAfter).max(),
            providerCode: failures.count == Product.allCases.count
                ? "source_unavailable"
                : "partial_source_failure"
        )
    }

    static func networkFailure(_ error: URLError) -> FailureDescriptor {
        let kind: ArkFileWeatherFailureKind
        switch error.code {
        case .cancelled:
            kind = .cancelled
        case .timedOut:
            kind = .timedOut
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            kind = .offline
        default:
            kind = .unknown
        }
        return FailureDescriptor(
            kind: kind,
            retryAfter: nil,
            providerCode: "network"
        )
    }

    static func safeHeader(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7f
              }) else {
            return fallback
        }
        return trimmed
    }
}

private extension ArkFileWeatherProbabilityDistribution {
    var hasKnownValue: Bool {
        belowNormalFraction != nil
            || nearNormalFraction != nil
            || aboveNormalFraction != nil
    }
}

private extension ArkFileWeatherOutlookPeriodKind {
    var sortIndex: Int {
        switch self {
        case .sixToTenDay: 0
        case .eightToFourteenDay: 1
        case .weekThreeToFour: 2
        }
    }
}

private extension Calendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
