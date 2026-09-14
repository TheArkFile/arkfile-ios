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
import Security

struct ArkFileAccountUser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let emailVerified: Bool?
    let hasPurchased: Bool
    let purchasedAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case emailVerified
        case hasPurchased
        case purchasedAt
    }

    init(
        id: String,
        email: String,
        emailVerified: Bool? = nil,
        hasPurchased: Bool = false,
        purchasedAt: Int64? = nil
    ) {
        self.id = id
        self.email = email
        self.emailVerified = emailVerified
        self.hasPurchased = hasPurchased
        self.purchasedAt = purchasedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        emailVerified = try container.decodeIfPresent(Bool.self, forKey: .emailVerified)
        hasPurchased = try container.decodeIfPresent(Bool.self, forKey: .hasPurchased) ?? false
        purchasedAt = try container.decodeIfPresent(Int64.self, forKey: .purchasedAt)
    }
}

@MainActor
final class ArkFileAccountSession: ObservableObject {
    static let shared = ArkFileAccountSession()

    @Published private(set) var token: String?
    @Published private(set) var user: ArkFileAccountUser?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let api: ArkFileAccountAPI
    private static let keychainAccount = "arkfile.account.session.v1"

    private init() {
        self.api = ArkFileAccountAPI(siteURL: URL(string: Brand.arkFileSiteURL))
        if let persisted = Self.loadPersistedSession() {
            self.token = persisted.token
            self.user = persisted.user
        }
    }

    var isSignedIn: Bool {
        token?.isEmpty == false
    }

    var hasPurchased: Bool {
        user?.hasPurchased == true
    }

    func signIn(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = LocalString.arkfile_account_error_missing_credentials
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let session = try await api.login(email: email, password: password)
            save(session: session)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func createAccount(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = LocalString.arkfile_account_error_missing_credentials
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let session = try await api.register(email: email, password: password)
            save(session: session)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func refresh() async throws {
        guard let token, !token.isEmpty else {
            throw ArkFileContentError.accountSignInRequired
        }
        let refreshedUser = try await api.me(token: token)
        save(session: PersistedSession(token: token, user: refreshedUser))
    }

    func refreshIfSignedIn() async {
        guard isSignedIn else { return }
        do {
            try await refresh()
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func contentAuthorizationIfPurchased() async throws -> ArkFileContentAuthorization? {
        guard let token, !token.isEmpty else {
            return nil
        }
        try await refresh()
        guard user?.hasPurchased == true else {
            return nil
        }
        return .accountToken(token)
    }

    func completeStoreKitPurchase(signedTransactionInfo: String) async throws -> ArkFileContentAuthorization {
        guard let token, !token.isEmpty else {
            throw ArkFileContentError.accountSignInRequired
        }
        let updatedUser: ArkFileAccountUser
        do {
            updatedUser = try await api.completeStoreKitPurchase(
                signedTransactionInfo: signedTransactionInfo,
                token: token
            )
        } catch let error as ArkFileAccountError {
            if error.storeKitCode == "storekit_owned_by_other_account" {
                throw ArkFileContentError.purchaseOwnedByOtherAccount(maskedEmail: error.maskedEmail)
            }
            throw error
        }
        save(session: PersistedSession(token: token, user: updatedUser))
        return .accountToken(token, storeKitTransactionJWS: signedTransactionInfo)
    }

    func signOut() {
        token = nil
        user = nil
        errorMessage = nil
        Self.deletePersistedSession()
    }

    private func save(session: PersistedSession) {
        token = session.token
        user = session.user
        errorMessage = nil
        Self.persist(session: session)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func persist(session: PersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        ArkFileKeychain.set(data: data, account: keychainAccount)
    }

    private static func loadPersistedSession() -> PersistedSession? {
        guard let data = ArkFileKeychain.data(account: keychainAccount) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    private static func deletePersistedSession() {
        ArkFileKeychain.delete(account: keychainAccount)
    }

    fileprivate struct PersistedSession: Codable {
        let token: String
        let user: ArkFileAccountUser
    }
}

private actor ArkFileAccountAPI {
    private let siteURL: URL?
    private let urlSession: URLSession
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(siteURL: URL?, urlSession: URLSession = .shared) {
        self.siteURL = siteURL
        self.urlSession = urlSession
    }

    func login(email: String, password: String) async throws -> ArkFileAccountSession.PersistedSession {
        let response: LoginResponse = try await request(
            path: "login",
            method: "POST",
            body: LoginRequest(email: email, password: password),
            token: nil
        )
        return ArkFileAccountSession.PersistedSession(token: response.token, user: response.user)
    }

    func register(email: String, password: String) async throws -> ArkFileAccountSession.PersistedSession {
        let response: LoginResponse = try await request(
            path: "register",
            method: "POST",
            body: LoginRequest(email: email, password: password),
            token: nil
        )
        return ArkFileAccountSession.PersistedSession(token: response.token, user: response.user)
    }

    func me(token: String) async throws -> ArkFileAccountUser {
        let response: MeResponse = try await request(
            path: "me",
            method: "GET",
            body: Optional<EmptyRequest>.none,
            token: token
        )
        return response.user
    }

    func completeStoreKitPurchase(
        signedTransactionInfo: String,
        token: String
    ) async throws -> ArkFileAccountUser {
        let response: StoreKitCompleteResponse = try await request(
            path: "storekit/complete-purchase",
            method: "POST",
            body: StoreKitCompleteRequest(signedTransactionInfo: signedTransactionInfo),
            token: token
        )
        return response.user
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> Response {
        let endpoint = try endpoint(path)
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try jsonEncoder.encode(body)
        }

        let endpointDescription = Self.diagnosticEndpoint(for: endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ArkFileAccountError.transport(endpointDescription, error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArkFileAccountError.invalidResponse(endpointDescription)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? jsonDecoder.decode(APIErrorResponse.self, from: data), !error.error.isEmpty {
                throw ArkFileAccountError.server(
                    statusCode: httpResponse.statusCode,
                    endpoint: endpointDescription,
                    message: error.error,
                    code: error.code,
                    maskedEmail: error.maskedEmail
                )
            }
            throw ArkFileAccountError.server(
                statusCode: httpResponse.statusCode,
                endpoint: endpointDescription,
                message: "",
                code: nil,
                maskedEmail: nil
            )
        }
        return try jsonDecoder.decode(Response.self, from: data)
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let siteURL, let host = siteURL.host else {
            throw ArkFileContentError.invalidSiteURL
        }
        guard ArkFileContentAPI.isAllowed(host: host, allowDeveloperFixtureHosts: Brand.hasDeveloperContentAuthToken) else {
            throw ArkFileContentError.unsupportedHost(host)
        }
        return siteURL
            .appendingPathComponent("api")
            .appendingPathComponent(path)
    }

    private static func diagnosticEndpoint(for url: URL) -> String {
        let host = url.host ?? "account-server"
        return "\(host)\(url.path)"
    }

    private struct LoginRequest: Encodable {
        let email: String
        let password: String
    }

    private struct LoginResponse: Decodable {
        let token: String
        let user: ArkFileAccountUser
    }

    private struct EmptyRequest: Encodable {}

    private struct MeResponse: Decodable {
        let user: ArkFileAccountUser
    }

    private struct StoreKitCompleteRequest: Encodable {
        let signedTransactionInfo: String
    }

    private struct StoreKitCompleteResponse: Decodable {
        let success: Bool?
        let user: ArkFileAccountUser
    }

    private struct APIErrorResponse: Decodable {
        let error: String
        let code: String?
        let maskedEmail: String?
    }
}

private enum ArkFileAccountError: LocalizedError {
    case server(statusCode: Int, endpoint: String, message: String, code: String?, maskedEmail: String?)
    case transport(String, String)
    case invalidResponse(String)

    var storeKitCode: String? {
        switch self {
        case let .server(_, _, _, code, _):
            code
        default:
            nil
        }
    }

    var maskedEmail: String? {
        switch self {
        case let .server(_, _, _, _, maskedEmail):
            maskedEmail
        default:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case let .server(statusCode, endpoint, message, _, _):
            if message.isEmpty {
                "ArkFile account server returned HTTP \(statusCode) for \(endpoint)."
            } else {
                "\(message) (api: \(endpoint), HTTP \(statusCode))"
            }
        case let .transport(endpoint, message):
            "ArkFile could not reach \(endpoint): \(message)"
        case let .invalidResponse(endpoint):
            "ArkFile received an invalid response from \(endpoint)."
        }
    }
}

private enum ArkFileKeychain {
    private static let service = "app.arkfile.ios"

    static func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(data: Data, account: String) {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            _ = SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
