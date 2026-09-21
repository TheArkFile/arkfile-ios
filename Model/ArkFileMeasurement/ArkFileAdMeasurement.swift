// This file is part of Kiwix for iOS & macOS.
// SPDX-License-Identifier: GPL-3.0-or-later

#if os(iOS)
import AdSupport
import AppTrackingTransparency
import Combine
import CryptoKit
import Foundation
import StoreKit
import UIKit

enum ArkFileMeasurementAuthorizationStatus: Equatable {
    case notDetermined, restricted, denied, authorized
}

@MainActor
protocol ArkFileMeasurementAuthorization {
    var status: ArkFileMeasurementAuthorizationStatus { get }
    func request() async
    /// Called only after both explicit ArkFile consent and ATT authorization.
    func advertisingIdentifier() -> UUID?
}

@MainActor
private struct ArkFileSystemMeasurementAuthorization: ArkFileMeasurementAuthorization {
    var status: ArkFileMeasurementAuthorizationStatus {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    func request() async { _ = await ATTrackingManager.requestTrackingAuthorization() }
    func advertisingIdentifier() -> UUID? {
        guard status == .authorized else { return nil }
        let value = ASIdentifierManager.shared().advertisingIdentifier
        return value.uuidString == "00000000-0000-0000-0000-000000000000" ? nil : value
    }
}

struct ArkFileMeasurementEvent: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let bundleID: String
        let version: String
        let build: String
        let osVersion: String
    }
    let schemaVersion: Int
    let eventName: String
    let eventID: String
    let eventTime: Int64
    let advertisingID: String
    let app: App
    /// Goes only to ArkFile's dedicated relay, which verifies Apple and removes
    /// the proof before forwarding the event to Meta. Never logged or persisted.
    let signedTransactionInfo: String?
}

enum ArkFileMeasurementDelivery: Sendable { case delivered, retry, discard }
protocol ArkFileMeasurementTransport: Sendable {
    func send(_ event: ArkFileMeasurementEvent) async throws -> ArkFileMeasurementDelivery
}

/// Separate tracking host: denying tracking must never block content APIs.
/// No redirects, cookies, URL cache, background delivery, or embedded secret.
private final class ArkFileMeasurementRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
private actor ArkFileMeasurementRelay: ArkFileMeasurementTransport {
    static let endpoint = URL(string: "https://events.thearkfile.com/api/app-events")!
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: ArkFileMeasurementRedirectPolicy(), delegateQueue: nil)
    }()
    func send(_ event: ArkFileMeasurementEvent) async throws -> ArkFileMeasurementDelivery {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(event)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { return .discard }
        if (200...299).contains(response.statusCode) { return .delivered }
        return response.statusCode == 429 || (500...599).contains(response.statusCode) ? .retry : .discard
    }
}

struct ArkFileMeasurementFreshInstallProof: Sendable {
    let isVerifiedProduction: Bool
    let bundleID: String
    let originalAppVersion: String
    let originalPurchaseDate: Date
}

struct ArkFileMeasurementPurchase: Sendable {
    let transactionID: String
    let purchaseDate: Date
    let purchaseStartedAt: Date
    let isVerifiedProduction: Bool
    let isDirectPurchase: Bool
    let isRevoked: Bool
    let price: Decimal?
    let currency: String?
    let signedTransactionInfo: String
}

/// Measurement is optional and independent from every purchase/download/read
/// path. Events are observed once, even when consent is absent; enabling later
/// never reconstructs history. The retry queue exists only in RAM, is bounded,
/// and is destroyed on revoke/background. Only non-identifying suppression
/// markers persist. Lost metrics are preferable to retaining tracking data.
@MainActor
final class ArkFileAdMeasurement: ObservableObject {
    static let shared = ArkFileAdMeasurement(
        enabled: Bundle.main.object(forInfoDictionaryKey: "ARKFILE_AD_MEASUREMENT_ENABLED") as? Bool == true,
        defaults: .standard,
        authorization: ArkFileSystemMeasurementAuthorization(),
        transport: ArkFileMeasurementRelay(),
        app: .init(bundleID: Bundle.main.bundleIdentifier ?? "",
                   version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                   build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                   osVersion: UIDevice.current.systemVersion),
        initiallyActive: UIApplication.shared.applicationState == .active,
        freshInstallProof: {
            guard let verification = try? await AppTransaction.shared,
                  case .verified(let transaction) = verification else { return nil }
            return .init(isVerifiedProduction: transaction.environment == .production,
                         bundleID: transaction.bundleID, originalAppVersion: transaction.originalAppVersion,
                         originalPurchaseDate: transaction.originalPurchaseDate)
        }
    )

    enum Keys {
        static let optedIn = "arkfile.measurement.opted-in.v1"
        static let sessionSeen = "arkfile.measurement.session-seen.v1"
        static let installObserved = "arkfile.measurement.install-observed.v1"
        static let contentObserved = "arkfile.measurement.content-observed.v1"
        static let purchaseIDs = "arkfile.measurement.observed-purchases.v1"
    }
    @Published private(set) var optedIn: Bool
    @Published private(set) var authorizationStatus: ArkFileMeasurementAuthorizationStatus
    @Published private(set) var isRequestingPermission = false
    let isConfigured: Bool
    private let defaults: UserDefaults
    private let authorization: any ArkFileMeasurementAuthorization
    private let transport: any ArkFileMeasurementTransport
    private let app: ArkFileMeasurementEvent.App
    private let now: () -> Date
    private let freshInstallProof: () async -> ArkFileMeasurementFreshInstallProof?
    private let automaticallyFlush: Bool
    private let retryDelay: @Sendable (UInt64) async throws -> Void
    private let firstSession: Bool
    private let sessionStartedAt: Date
    private var didCheckInstall = false
    private var isActive: Bool
    private var generation = 0
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private struct Pending {
        let event: ArkFileMeasurementEvent
        let enqueuedAt: Date
        var attempts = 0
    }
    private var queue: [Pending] = []
    var pendingEventCount: Int { queue.count }

    init(enabled: Bool, defaults: UserDefaults,
         authorization: any ArkFileMeasurementAuthorization,
         transport: any ArkFileMeasurementTransport,
         app: ArkFileMeasurementEvent.App,
         now: @escaping () -> Date = Date.init,
         automaticallyFlush: Bool = true,
         initiallyActive: Bool = false,
         retryDelay: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         freshInstallProof: @escaping () async -> ArkFileMeasurementFreshInstallProof? = { nil }) {
        self.isConfigured = enabled
        self.defaults = defaults
        self.authorization = authorization
        self.transport = transport
        self.app = app
        self.now = now
        self.automaticallyFlush = automaticallyFlush
        self.isActive = initiallyActive
        self.retryDelay = retryDelay
        self.freshInstallProof = freshInstallProof
        self.optedIn = defaults.bool(forKey: Keys.optedIn)
        self.authorizationStatus = authorization.status
        self.firstSession = !defaults.bool(forKey: Keys.sessionSeen)
        self.sessionStartedAt = now()
        defaults.set(true, forKey: Keys.sessionSeen)
    }

    func start(hasReadableContent: Bool) {
        // Existing content on upgrade is not a new first-content conversion.
        if hasReadableContent { defaults.set(true, forKey: Keys.contentObserved) }
        refreshAuthorization()
    }

    func setOptedIn(_ value: Bool) async {
        guard isConfigured || !value else { return }
        optedIn = value
        defaults.set(value, forKey: Keys.optedIn)
        guard value else { clearPendingEvents(); return }
        if authorization.status == .notDetermined, isActive, !isRequestingPermission {
            isRequestingPermission = true
            await authorization.request()
            isRequestingPermission = false
        }
        refreshAuthorization()
        if maySend { await recordFreshInstallIfEligible() }
    }

    func appDidBecomeActive() {
        isActive = true
        refreshAuthorization()
        scheduleFlush()
        if maySend { Task { await recordFreshInstallIfEligible() } }
    }
    func appWillResignActive() {
        isActive = false
        // No background tracking; cancel in-flight sends and abandon retries.
        clearPendingEvents()
    }
    func refreshAuthorization() {
        authorizationStatus = authorization.status
        if !maySend { clearPendingEvents() }
    }
    private var maySend: Bool {
        isConfigured && optedIn && isActive && authorization.status == .authorized
    }
    private func clearPendingEvents() {
        generation += 1
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
    }

    private func recordFreshInstallIfEligible() async {
        guard !didCheckInstall, firstSession, maySend,
              !defaults.bool(forKey: Keys.installObserved),
              now().timeIntervalSince(sessionStartedAt) <= 15 * 60 else { return }
        didCheckInstall = true
        let snapshot = generation
        guard let proof = await freshInstallProof(), snapshot == generation, maySend,
              proof.isVerifiedProduction, proof.bundleID == app.bundleID,
              proof.originalAppVersion == app.build,
              proof.originalPurchaseDate <= now(),
              now().timeIntervalSince(proof.originalPurchaseDate) <= 24 * 60 * 60 else { return }
        defaults.set(true, forKey: Keys.installObserved)
        enqueue(name: "MobileAppInstall", id: UUID().uuidString)
    }

    func recordFirstContentReady() {
        guard !defaults.bool(forKey: Keys.contentObserved) else { return }
        defaults.set(true, forKey: Keys.contentObserved)
        enqueue(name: "ArkFileFirstContentReady", id: UUID().uuidString)
    }

    func recordPaidPurchase(_ purchase: ArkFileMeasurementPurchase) {
        let digest = SHA256.hash(data: Data(purchase.transactionID.utf8)).map { String(format: "%02x", $0) }.joined()
        var observed = defaults.stringArray(forKey: Keys.purchaseIDs) ?? []
        guard !observed.contains(digest) else { return }
        observed.append(digest)
        defaults.set(Array(observed.suffix(256)), forKey: Keys.purchaseIDs)
        guard purchase.isVerifiedProduction, purchase.isDirectPurchase, !purchase.isRevoked,
              let price = purchase.price, price > 0,
              let currency = purchase.currency, currency.count == 3,
              purchase.purchaseDate >= purchase.purchaseStartedAt.addingTimeInterval(-5),
              purchase.purchaseDate <= now().addingTimeInterval(5),
              now().timeIntervalSince(purchase.purchaseDate) <= 15 * 60,
              !purchase.signedTransactionInfo.isEmpty else { return }
        enqueue(name: "Purchase", id: "purchase-" + digest, signedTransactionInfo: purchase.signedTransactionInfo)
    }

    /// Called solely from the verified, direct Product.purchase success branch.
    /// Transaction.updates, currentEntitlements, restore, and refresh never call it.
    func recordPaidPurchase(transaction: Transaction, signedTransactionInfo: String, purchaseStartedAt: Date) {
        recordPaidPurchase(.init(transactionID: String(transaction.id), purchaseDate: transaction.purchaseDate,
                                 purchaseStartedAt: purchaseStartedAt, isVerifiedProduction: transaction.environment == .production,
                                 isDirectPurchase: transaction.ownershipType == .purchased,
                                 isRevoked: transaction.revocationDate != nil, price: transaction.price,
                                 currency: transaction.currency?.identifier, signedTransactionInfo: signedTransactionInfo))
    }

    private func enqueue(name: String, id: String, signedTransactionInfo: String? = nil) {
        // Do not even read IDFA before both gates. No IDFV or fingerprint fallback.
        guard maySend, let identifier = authorization.advertisingIdentifier(),
              identifier.uuidString != "00000000-0000-0000-0000-000000000000" else { return }
        queue.removeAll { now().timeIntervalSince($0.enqueuedAt) > 60 * 60 }
        guard queue.count < 20 else { return }
        queue.append(Pending(event: .init(schemaVersion: 1, eventName: name, eventID: id,
                                         eventTime: Int64(now().timeIntervalSince1970), advertisingID: identifier.uuidString,
                                         app: app, signedTransactionInfo: signedTransactionInfo), enqueuedAt: now()))
        scheduleFlush()
    }
    private func scheduleFlush() {
        guard automaticallyFlush, !queue.isEmpty, maySend, !isFlushing, flushTask == nil else { return }
        let scheduledGeneration = generation
        flushTask = Task { [weak self] in
            guard let self, self.generation == scheduledGeneration, !Task.isCancelled else { return }
            await self.flush()
        }
    }
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer {
            isFlushing = false
            flushTask = nil
            scheduleFlush()
        }
        let snapshot = generation
        while !queue.isEmpty, snapshot == generation, maySend, !Task.isCancelled {
            guard now().timeIntervalSince(queue[0].enqueuedAt) <= 60 * 60,
                  queue[0].attempts < 3 else { queue.removeFirst(); continue }
            // Consent and ATT are checked anew immediately before every send.
            // A changed advertising ID drops the event instead of linking IDs.
            guard let identifier = authorization.advertisingIdentifier(),
                  identifier.uuidString == queue[0].event.advertisingID else { clearPendingEvents(); break }
            let event = queue[0].event
            queue[0].attempts += 1
            let outcome: ArkFileMeasurementDelivery
            do { outcome = try await transport.send(event) }
            catch { outcome = .retry }
            guard snapshot == generation, maySend, !Task.isCancelled else { break }
            guard queue.first?.event.eventID == event.eventID else { continue }
            switch outcome {
            case .delivered, .discard: queue.removeFirst()
            case .retry:
                if queue[0].attempts >= 3 { queue.removeFirst() }
                else {
                    do { try await retryDelay(30_000_000_000) }
                    catch { return }
                }
            }
        }
        if !maySend { clearPendingEvents() }
    }
}
#endif
