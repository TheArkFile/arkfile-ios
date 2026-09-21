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

actor ArkFileContentAPI {
    private let siteURL: URL
    private let urlSession: URLSession
    private let jsonDecoder: JSONDecoder

    init(siteURL: URL, urlSession: URLSession = .shared) throws {
        guard let host = siteURL.host else {
            throw ArkFileContentError.invalidSiteURL
        }
        guard Self.isAllowed(host: host, allowDeveloperFixtureHosts: Brand.hasDeveloperContentAuthToken) else {
            throw ArkFileContentError.unsupportedHost(host)
        }
        guard siteURL.scheme?.lowercased() == "https"
                || Self.usesRelaxedDebugNetworking(host: host) else {
            throw ArkFileContentError.invalidSiteURL
        }
        self.siteURL = siteURL
        self.urlSession = urlSession
        self.jsonDecoder = JSONDecoder()
    }

    func requestDownloadInfo(
        tier: ArkFileContentTier,
        installedTier: ArkFileContentTier?,
        authorization: ArkFileContentAuthorization,
        package: String? = nil
    ) async throws -> ArkFileDownloadInfo {
        var components = URLComponents(
            url: endpoint("request-download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "tier", value: tier.rawValue)
        ]
        if let installedTier {
            components?.queryItems?.append(URLQueryItem(name: "installedTier", value: installedTier.rawValue))
        }
        if let package, !package.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "package", value: package))
        }
        guard let url = components?.url else {
            throw ArkFileContentError.invalidSiteURL
        }
        let data = try await requestData(url: url, authorization: authorization)
        return try jsonDecoder.decode(ArkFileDownloadInfo.self, from: data)
    }

    func packageManifest(
        objectKey: String,
        authorization: ArkFileContentAuthorization
    ) async throws -> ArkFilePackageManifest {
        var components = URLComponents(
            url: endpoint("package-manifest"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "objectKey", value: objectKey)
        ]
        guard let url = components?.url else {
            throw ArkFileContentError.invalidSiteURL
        }
        let data = try await requestData(url: url, authorization: authorization)
        if let wrapped = try? jsonDecoder.decode(ArkFilePackageManifestResponse.self, from: data),
           let manifest = wrapped.manifest {
            return manifest
        }
        return try jsonDecoder.decode(ArkFilePackageManifest.self, from: data)
    }

    func packageFileURL(objectKey: String) throws -> URL {
        var components = URLComponents(
            url: endpoint("package-file"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "objectKey", value: objectKey)
        ]
        guard let url = components?.url else {
            throw ArkFileContentError.invalidSiteURL
        }
        return url
    }

    func contentPublication() async throws -> Data {
        try await publicReleaseData(leaf: "publication", query: [.init(name: "channel", value: "stable")])
    }

    func contentRelease(_ binding: ArkFileContentReleaseBinding) async throws -> Data {
        try await publicReleaseData(leaf: "release", query: bindingQuery(binding))
    }

    func releaseFileURL(_ file: ArkFileContentRelease.File,
                        binding: ArkFileContentReleaseBinding) throws -> URL {
        try releaseURL(leaf: "file", query: bindingQuery(binding) + [.init(name: "fileID", value: file.fileID)])
    }

    /// HEAD proves the pinned edition is still deliverable before delete-first.
    func preflightReleaseFile(_ file: ArkFileContentRelease.File,
                              binding: ArkFileContentReleaseBinding,
                              authorization: ArkFileContentAuthorization) async throws {
        var request = URLRequest(url: try releaseFileURL(file, binding: binding), timeoutInterval: 30)
        request.httpMethod = "HEAD"
        authorization.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength == file.sizeBytes else {
            throw ArkFileContentReleaseError.releaseUnavailable
        }
    }

    private func bindingQuery(_ binding: ArkFileContentReleaseBinding) -> [URLQueryItem] {
        [.init(name: "releaseID", value: binding.releaseID), .init(name: "releaseSHA256", value: binding.releaseSHA256)]
    }
    private func releaseURL(leaf: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: siteURL.appendingPathComponent("api/content/v2/" + leaf),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw ArkFileContentError.invalidSiteURL }
        return url
    }
    private func publicReleaseData(leaf: String, query: [URLQueryItem]) async throws -> Data {
        let url = try releaseURL(leaf: leaf, query: query)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= ArkFileContentReleaseVerifier.maximumPayloadBytes * 2 else {
            throw ArkFileContentReleaseError.releaseUnavailable
        }
        return data
    }

    private func requestData(url: URL, authorization: ArkFileContentAuthorization) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        authorization.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        let endpointDescription = Self.diagnosticEndpoint(for: url)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ArkFileContentError.requestFailed(endpointDescription, error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkFileContentError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let productIDs = Self.confirmedRefundProductIDs(
                statusCode: httpResponse.statusCode,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                responseBody: data,
                responseURL: httpResponse.url
            ) {
                throw ArkFileContentError.confirmedStoreKitRefund(
                    productIDs: productIDs
                )
            }
            let apiMessage = (try? jsonDecoder.decode(APIErrorResponse.self, from: data))?.error
            throw ArkFileContentError.httpStatusWithEndpoint(
                httpResponse.statusCode,
                endpointDescription,
                apiMessage
            )
        }
        return data
    }

    private func endpoint(_ leaf: String) -> URL {
        siteURL
            .appendingPathComponent("api")
            .appendingPathComponent("content")
            .appendingPathComponent("v1")
            .appendingPathComponent(leaf)
    }

    private static func diagnosticEndpoint(for url: URL) -> String {
        let host = url.host ?? "content-server"
        return "\(host)\(url.path)"
    }

    private struct APIErrorResponse: Decodable {
        let error: String
        let code: String?
        let productIds: [String]?
    }

    nonisolated static func confirmedRefundProductIDs(
        statusCode: Int,
        contentType: String?,
        responseBody: Data,
        responseURL: URL?
    ) -> [String]? {
        let mimeType = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard statusCode == 401,
              mimeType == "application/json",
              Self.isTrustedConfirmedRefundResponseURL(responseURL),
              let response = try? JSONDecoder().decode(
                  APIErrorResponse.self,
                  from: responseBody
              ),
              response.code == "storekit_entitlement_refunded",
              let productIDs = response.productIds,
              !productIDs.isEmpty else {
            return nil
        }
        let knownProductIDs = ArkFileStoreKitProductConfiguration.current.productIDs
        guard Set(productIDs).count == productIDs.count,
              productIDs.allSatisfy({ knownProductIDs.contains($0) }) else {
            return nil
        }
        return productIDs.sorted()
    }

    private nonisolated static func isTrustedConfirmedRefundResponseURL(
        _ url: URL?
    ) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "thearkfile.com" || host == "www.thearkfile.com",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return false
        }
        switch url.path {
        case "/api/content/v2/file",
             "/api/storekit/ios-content-access-v2",
             "/api/storekit/testflight-ios-content-access-v2",
             "/api/content/v1/request-download",
             "/api/content/v1/package-manifest",
             "/api/content/v1/package-file",
             "/api/storekit/ios-content-access",
             "/api/storekit/testflight-ios-content-access":
            return true
        default:
            return false
        }
    }

    static func isAllowed(host: String, allowDeveloperFixtureHosts: Bool = false) -> Bool {
        let normalized = host.lowercased()
        if normalized == "thearkfile.com" || normalized == "www.thearkfile.com" {
            return true
        }
        #if DEBUG
        if Self.isLocalDebugHost(host: normalized) {
            return true
        }
        return allowDeveloperFixtureHosts && isPrivateIPv4Host(normalized)
        #else
        return false
        #endif
    }

    static func isLocalDebugHost(host: String) -> Bool {
        #if DEBUG
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
        #else
        return false
        #endif
    }

    static func usesRelaxedDebugNetworking(host: String) -> Bool {
        #if DEBUG
        let normalized = host.lowercased()
        return isLocalDebugHost(host: normalized) || isPrivateIPv4Host(normalized)
        #else
        return false
        #endif
    }

    #if DEBUG
    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              parts.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else {
            return false
        }

        return first == 10
            || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }
    #endif
}
