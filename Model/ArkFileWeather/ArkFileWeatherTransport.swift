// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

struct ArkFileWeatherHTTPValidators: Codable, Equatable, Sendable {
    var entityTag: String?
    var lastModified: String?

    init(entityTag: String?, lastModified: String?) {
        self.entityTag = Self.normalized(entityTag)
        self.lastModified = Self.normalized(lastModified)
    }

    var isEmpty: Bool {
        entityTag == nil && lastModified == nil
    }

    func apply(to request: inout URLRequest) {
        if let entityTag = Self.normalized(entityTag) {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = Self.normalized(lastModified) {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  (0x20 ... 0x7E).contains($0.value)
              }) else {
            return nil
        }
        return trimmed
    }
}

struct ArkFileWeatherHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let finalURL: URL
    let headers: [String: String]
    let mimeType: String?
    let body: Data

    var validators: ArkFileWeatherHTTPValidators {
        ArkFileWeatherHTTPValidators(
            entityTag: headers["etag"],
            lastModified: headers["last-modified"]
        )
    }

    func retryAfterDate(relativeTo now: Date) -> Date? {
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 24 * 60 * 60))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let parsed = formatter.date(from: value) else {
            return nil
        }
        return min(
            max(parsed, now),
            now.addingTimeInterval(24 * 60 * 60)
        )
    }
}

protocol ArkFileWeatherTransport: Sendable {
    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> ArkFileWeatherHTTPResponse
}

enum ArkFileWeatherTransportError: Error, Equatable, Sendable {
    case invalidMaximumBodySize
    case untrustedDestination
    case nonHTTPResponse
    case responseTooLarge(maximumBytes: Int)
}

extension ArkFileWeatherTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidMaximumBodySize:
            "The weather response size limit is invalid."
        case .untrustedDestination:
            "The weather provider returned an untrusted destination."
        case .nonHTTPResponse:
            "The weather provider returned an invalid response."
        case .responseTooLarge:
            "The weather provider response exceeded ArkFile's safety limit."
        }
    }
}

/// An ephemeral, bounded transport used only by Saved Weather. It has no
/// content-delivery credentials, shared cookies, or shared URL cache.
actor ArkFileURLSessionWeatherTransport: ArkFileWeatherTransport {
    private let allowedHosts: Set<String>
    private let session: URLSession

    init(
        allowedHosts: Set<String>,
        configuration suppliedConfiguration: URLSessionConfiguration? = nil
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })

        let configuration = suppliedConfiguration ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false

        let redirectDelegate = ArkFileWeatherRedirectDelegate(
            allowedHosts: self.allowedHosts
        )
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> ArkFileWeatherHTTPResponse {
        guard maximumBodyBytes > 0 else {
            throw ArkFileWeatherTransportError.invalidMaximumBodySize
        }
        guard Self.isAllowed(request.url, allowedHosts: allowedHosts) else {
            throw ArkFileWeatherTransportError.untrustedDestination
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url else {
            throw ArkFileWeatherTransportError.nonHTTPResponse
        }
        guard Self.isAllowed(finalURL, allowedHosts: allowedHosts) else {
            throw ArkFileWeatherTransportError.untrustedDestination
        }

        let expectedLength = httpResponse.expectedContentLength
        if expectedLength > Int64(maximumBodyBytes) {
            throw ArkFileWeatherTransportError.responseTooLarge(
                maximumBytes: maximumBodyBytes
            )
        }

        var body = Data()
        if expectedLength > 0 {
            body.reserveCapacity(min(Int(expectedLength), maximumBodyBytes))
        }
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else {
                throw ArkFileWeatherTransportError.responseTooLarge(
                    maximumBytes: maximumBodyBytes
                )
            }
            body.append(byte)
        }

        return ArkFileWeatherHTTPResponse(
            statusCode: httpResponse.statusCode,
            finalURL: finalURL,
            headers: Self.headers(from: httpResponse),
            mimeType: httpResponse.mimeType?.lowercased(),
            body: body
        )
    }

    private static func isAllowed(
        _ url: URL?,
        allowedHosts: Set<String>
    ) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else { continue }
            headers[name.lowercased()] = String(describing: rawValue)
        }
        return headers
    }
}

private final class ArkFileWeatherRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil else {
            completionHandler(nil)
            return
        }
        // Weather endpoint identity is part of the data-integrity boundary.
        // Even a same-host redirect could silently substitute another point
        // or grid, so callers receive the 3xx response and fail closed.
        completionHandler(nil)
    }
}
