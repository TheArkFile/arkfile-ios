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
import StoreKit

struct ArkFilePendingStoreKitPurchase: Codable, Equatable, Sendable {
    let productID: String
    let signedTransactionInfo: String
    let accountUserID: String?
    let accountEmail: String?
    let createdAt: Date

    func matches(productID: String, user: ArkFileAccountUser?) -> Bool {
        guard self.productID == productID else {
            return false
        }
        guard let user else {
            return false
        }
        if let accountUserID, !accountUserID.isEmpty {
            return accountUserID == user.id
        }
        if let accountEmail, !accountEmail.isEmpty {
            return accountEmail.caseInsensitiveCompare(user.email) == .orderedSame
        }
        return false
    }
}

struct ArkFilePendingStoreKitPurchaseStore {
    private let keychainAccount: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let readData: (String) -> Data?
    private let writeData: (Data, String) -> Void
    private let deleteData: (String) -> Void

    init(
        keychainAccount: String = "arkfile.storekit.pending-lite.v1",
        readData: ((String) -> Data?)? = nil,
        writeData: ((Data, String) -> Void)? = nil,
        deleteData: ((String) -> Void)? = nil
    ) {
        self.keychainAccount = keychainAccount
        self.readData = readData ?? { ArkFilePendingStoreKitKeychain.data(account: $0) }
        self.writeData = writeData ?? { _ = ArkFilePendingStoreKitKeychain.set(data: $0, account: $1) }
        self.deleteData = deleteData ?? { ArkFilePendingStoreKitKeychain.delete(account: $0) }
    }

    func save(_ purchase: ArkFilePendingStoreKitPurchase) {
        guard let data = try? encoder.encode(purchase) else {
            return
        }
        writeData(data, keychainAccount)
    }

    func pendingPurchase() -> ArkFilePendingStoreKitPurchase? {
        guard let data = readData(keychainAccount) else {
            return nil
        }
        return try? decoder.decode(ArkFilePendingStoreKitPurchase.self, from: data)
    }

    func pendingPurchase(productID: String, user: ArkFileAccountUser?) -> ArkFilePendingStoreKitPurchase? {
        guard let purchase = pendingPurchase(),
              purchase.matches(productID: productID, user: user) else {
            return nil
        }
        return purchase
    }

    func clear() {
        deleteData(keychainAccount)
    }
}

struct ArkFileIOSContentAccessState: Codable, Equatable, Sendable {
    static let usableAccessBuffer: TimeInterval = 5 * 60

    let productID: String
    let signedTransactionInfo: String
    let contentAccessToken: String
    let tier: String
    let expiresAt: Date
    let createdAt: Date
    var revokedAt: Date?

    var isRevoked: Bool {
        revokedAt != nil
    }

    var contentTier: ArkFileContentTier? {
        ArkFileContentTier.iOSInstallableTier(named: tier)
    }

    func isUsable(now: Date = Date()) -> Bool {
        !isRevoked && expiresAt > now.addingTimeInterval(Self.usableAccessBuffer)
    }
}

enum ArkFileStoreKitProductValidator {
    static func validateProduct(
        productID: String,
        expectedProductID: String,
        isNonConsumable: Bool
    ) throws {
        guard productID == expectedProductID, isNonConsumable else {
            throw ArkFileContentError.productMisconfigured
        }
    }

    static func validateLiteProduct(
        productID: String,
        expectedProductID: String,
        isNonConsumable: Bool
    ) throws {
        try validateProduct(
            productID: productID,
            expectedProductID: expectedProductID,
            isNonConsumable: isNonConsumable
        )
    }
}

enum ArkFileStoreKitProductRole: String, Hashable, Sendable {
    case lite
    case complete
    case completeUpgrade
}

struct ArkFileStoreKitContentAccessProof: Equatable, Sendable {
    let productID: String
    let signedTransactionInfo: String
    let role: ArkFileStoreKitProductRole
}

enum ArkFileStoreKitCompleteProductRoleResolver {
    static func resolve(
        hasEssentialsProof: Bool
    ) -> ArkFileStoreKitProductRole {
        hasEssentialsProof ? .completeUpgrade : .complete
    }

    static func resolve(
        proofs: [ArkFileStoreKitContentAccessProof]
    ) -> ArkFileStoreKitProductRole {
        resolve(hasEssentialsProof: proofs.contains { $0.role == .lite })
    }

    /// Resolves only a product that is safe to place in front of Apple for a new
    /// charge. An ordinary empty `currentEntitlements` read is not enough to
    /// distinguish a new customer from an existing owner whose StoreKit cache is
    /// temporarily unavailable.
    static func purchaseRole(
        proofs: [ArkFileStoreKitContentAccessProof],
        ownership: ArkFileStoreKitOwnershipState
    ) -> ArkFileStoreKitProductRole? {
        if let plan = ArkFileStoreKitContentAccessRequestPlan.make(from: proofs) {
            return plan.requestedTier == .lite ? .completeUpgrade : nil
        }
        guard proofs.isEmpty else {
            // In particular, never turn an orphaned upgrade proof into an
            // outright Complete charge.
            return nil
        }
        switch ownership {
        case .notOwned, .ineligibleFamilyShared:
            return .complete
        case .checking, .essentials, .complete:
            return nil
        }
    }
}

struct ArkFileStoreKitEntitlementSnapshot: Equatable, Sendable {
    let proofs: [ArkFileStoreKitContentAccessProof]
    let ineligibleOwnershipRoles: Set<ArkFileStoreKitProductRole>

    init(
        proofs: [ArkFileStoreKitContentAccessProof],
        ineligibleOwnershipRoles: Set<ArkFileStoreKitProductRole> = []
    ) {
        self.proofs = proofs
        self.ineligibleOwnershipRoles = ineligibleOwnershipRoles
    }
}

/// Durable product ownership is a StoreKit fact, not a property of ArkFile's
/// short-lived content-service token. UI can therefore keep showing a pack as
/// owned while download authorization is temporarily unavailable.
enum ArkFileStoreKitOwnershipState: Equatable, Sendable {
    case checking
    case notOwned
    case essentials
    case complete
    case ineligibleFamilyShared

    var ownedTier: ArkFileContentTier? {
        switch self {
        case .essentials:
            .lite
        case .complete:
            .complete
        case .checking, .notOwned, .ineligibleFamilyShared:
            nil
        }
    }

    func owns(_ tier: ArkFileContentTier) -> Bool {
        switch (self, tier) {
        case (.essentials, .lite),
             (.complete, .lite),
             (.complete, .complete):
            true
        case (_, .standard),
             (.checking, _),
             (.notOwned, _),
             (.essentials, .complete),
             (.ineligibleFamilyShared, _):
            false
        }
    }

    static func resolve(
        _ snapshot: ArkFileStoreKitEntitlementSnapshot
    ) -> ArkFileStoreKitOwnershipState {
        if let plan = ArkFileStoreKitContentAccessRequestPlan.make(from: snapshot.proofs) {
            return plan.requestedTier == .complete ? .complete : .essentials
        }
        if !snapshot.proofs.isEmpty {
            // A non-empty but incomplete proof set (most importantly a
            // Complete Upgrade proof whose Essentials proof has not appeared
            // yet) is not evidence that the customer owns nothing. Keep every
            // purchase SKU closed until an authoritative account-wide read
            // resolves the pair.
            return .checking
        }
        if !snapshot.ineligibleOwnershipRoles.isEmpty {
            return .ineligibleFamilyShared
        }
        return .notOwned
    }
}

/// Readiness to call ArkFile's paid content endpoints is intentionally
/// independent from StoreKit ownership. A verified owner can be `.unavailable`
/// or `.preparing` while offline, during a backend outage, or between tokens.
enum ArkFileContentAuthorizationReadiness: Equatable, Sendable {
    case unavailable
    case preparing(ArkFileContentTier)
    case ready(ArkFileContentTier, expiresAt: Date?)
}

/// Evidence belongs to the restore that failed, not the durable ownership
/// snapshot that can predate an account change or even an app reinstall.
struct ArkFileVerifiedRestoreAuthorizationError: LocalizedError {
    let verifiedTier: ArkFileContentTier
    let underlyingError: Error

    var errorDescription: String? {
        (underlyingError as? LocalizedError)?.errorDescription
            ?? underlyingError.localizedDescription
    }
}

struct ArkFileStoreKitContentAccessRequestPlan: Equatable, Sendable {
    let primary: ArkFileStoreKitContentAccessProof
    let additional: [ArkFileStoreKitContentAccessProof]

    private init(
        primary: ArkFileStoreKitContentAccessProof,
        additional: [ArkFileStoreKitContentAccessProof]
    ) {
        self.primary = primary
        self.additional = additional
    }

    var requestedTier: ArkFileContentTier {
        switch primary.role {
        case .complete, .completeUpgrade:
            .complete
        case .lite:
            .lite
        }
    }

    var additionalSignedTransactionInfos: [String] {
        additional.map(\.signedTransactionInfo)
    }

    var grantsEssentialsAccess: Bool {
        switch primary.role {
        case .lite, .complete:
            true
        case .completeUpgrade:
            additional.contains { $0.role == .lite }
        }
    }

    /// True only for the user-initiated Restore Purchases fallback where
    /// StoreKit returned a directly purchased Complete Upgrade transaction but
    /// omitted the qualifying Essentials transaction from currentEntitlements.
    /// The backend must recover and verify that dependency from Apple's
    /// transaction history before ArkFile can publish Complete ownership.
    var requiresServerHistoryRecovery: Bool {
        primary.role == .completeUpgrade
            && !additional.contains { $0.role == .lite }
    }

    static func make(from proofs: [ArkFileStoreKitContentAccessProof]) -> ArkFileStoreKitContentAccessRequestPlan? {
        let lite = proofs.first { $0.role == .lite }
        if let complete = proofs.first(where: { $0.role == .complete }) {
            return ArkFileStoreKitContentAccessRequestPlan(primary: complete, additional: [])
        }
        if let completeUpgrade = proofs.first(where: { $0.role == .completeUpgrade }) {
            guard let lite else {
                // The upgrade SKU is not independently sufficient. Requiring
                // its current Essentials proof here keeps every purchase,
                // restore, and Transaction.updates path on the same rule.
                return nil
            }
            return ArkFileStoreKitContentAccessRequestPlan(
                primary: completeUpgrade,
                additional: [lite]
            )
        }
        if let lite {
            return ArkFileStoreKitContentAccessRequestPlan(primary: lite, additional: [])
        }
        return nil
    }

    /// Builds the one intentionally incomplete proof plan accepted by the
    /// backend's Apple-history recovery path. Ordinary purchase routing,
    /// entitlement updates, and foreground reconciliation continue to use
    /// `make(from:)`, where an upgrade without Essentials remains fail-closed.
    static func makeServerHistoryRecovery(
        from proofs: [ArkFileStoreKitContentAccessProof]
    ) -> ArkFileStoreKitContentAccessRequestPlan? {
        guard make(from: proofs) == nil,
              proofs.first(where: { $0.role == .complete }) == nil,
              proofs.first(where: { $0.role == .lite }) == nil,
              let completeUpgrade = proofs.first(where: {
                  $0.role == .completeUpgrade
              }) else {
            return nil
        }
        return ArkFileStoreKitContentAccessRequestPlan(
            primary: completeUpgrade,
            additional: []
        )
    }

    func stateProof(for responseTier: ArkFileContentTier) -> ArkFileStoreKitContentAccessProof {
        guard responseTier == .lite else {
            return primary
        }
        if primary.role == .lite {
            return primary
        }
        return additional.first { $0.role == .lite } ?? primary
    }
}

struct ArkFileStoreKitContentAccessResponse: Equatable, Sendable {
    let contentAccessToken: String
    let tier: String
    let expiresAt: Date
}

struct ArkFileStoreKitReleaseAccessResponse: Decodable, Sendable {
    let contentAccessToken: String
    let tier: String
    let expiresAt: String
    let releaseID: String
    let releaseSHA256: String
    let success: Bool?
}

enum ArkFileStoreKitReleaseAccessValidator {
    static func validate(_ response: ArkFileStoreKitReleaseAccessResponse,
                         binding: ArkFileContentReleaseBinding, tier: ArkFileContentTier,
                         now: Date = Date()) throws -> ArkFileValidatedStoreKitContentAccess {
        guard response.releaseID == binding.releaseID, response.releaseSHA256 == binding.releaseSHA256 else {
            throw ArkFileContentReleaseError.staleSelection
        }
        let validated = try ArkFileStoreKitContentAccessValidator.validate(
            contentAccessToken: response.contentAccessToken, tier: response.tier,
            expiresAt: response.expiresAt, success: response.success)
        guard tier.isIOSInstallable, validated.tier == "complete" || tier == .lite,
              validated.expiresAt > now else { throw ArkFileContentError.purchaseRequired }
        return validated
    }
}

protocol ArkFileStoreKitContentAccessServing: Sendable {
    func releaseAccess(plan: ArkFileStoreKitContentAccessRequestPlan,
                       binding: ArkFileContentReleaseBinding,
                       previousContentAccessToken: String?) async throws -> ArkFileStoreKitReleaseAccessResponse

    func contentAccess(
        plan: ArkFileStoreKitContentAccessRequestPlan
    ) async throws -> ArkFileStoreKitContentAccessResponse
}

extension ArkFileStoreKitContentAccessServing {
    func releaseAccess(plan: ArkFileStoreKitContentAccessRequestPlan,
                       binding: ArkFileContentReleaseBinding,
                       previousContentAccessToken: String?) async throws -> ArkFileStoreKitReleaseAccessResponse {
        throw ArkFileContentReleaseError.releaseUnavailable
    }
}

struct ArkFileStoreKitAccessMintEvent: Equatable, Sendable {
    let id: UUID
    let tier: ArkFileContentTier
    let productID: String
    let mintedAt: Date
}

struct ArkFileRestoredContentAccess: Sendable {
    let tier: ArkFileContentTier
    let authorization: ArkFileContentAuthorization
}

struct ArkFileConfirmedRefundRecovery: Sendable {
    let authorization: ArkFileContentAuthorization
    let acquisitionLease: ArkFileStoreKitAcquisitionLease
}

struct ArkFileStoreKitAcquisitionLease: Equatable, Sendable {
    let tier: ArkFileContentTier
    fileprivate let entitlementGeneration: UInt64
}

enum ArkFileStoreKitMintError: Error, Equatable, LocalizedError, Sendable {
    case supersededByEntitlementChange
    case contentAccessPersistenceFailed

    var errorDescription: String? {
        switch self {
        case .supersededByEntitlementChange:
            "App Store access changed while ArkFile was checking this purchase. Restore Purchases to re-check access."
        case .contentAccessPersistenceFailed:
            "Your purchase is confirmed, but ArkFile could not save download access on this device. Try Restore Purchases again. Your installed content is still available."
        }
    }
}

struct ArkFileStoreKitRevocationOutcome: Equatable, Sendable {
    let revokeLite: Bool
    let revokeComplete: Bool

    static func resolve(
        remainingProofs: [ArkFileStoreKitContentAccessProof]
    ) -> ArkFileStoreKitRevocationOutcome {
        guard let plan = ArkFileStoreKitContentAccessRequestPlan.make(from: remainingProofs) else {
            return ArkFileStoreKitRevocationOutcome(revokeLite: true, revokeComplete: true)
        }
        switch plan.requestedTier {
        case .complete:
            return ArkFileStoreKitRevocationOutcome(revokeLite: false, revokeComplete: false)
        case .lite:
            return ArkFileStoreKitRevocationOutcome(revokeLite: false, revokeComplete: true)
        case .standard:
            return ArkFileStoreKitRevocationOutcome(revokeLite: true, revokeComplete: true)
        }
    }
}

struct ArkFileStoreKitContentAccessRequest: Encodable, Equatable, Sendable {
    let signedTransactionInfo: String
    let additionalSignedTransactionInfos: [String]?

    init(
        signedTransactionInfo: String,
        additionalSignedTransactionInfos: [String] = []
    ) {
        self.signedTransactionInfo = signedTransactionInfo
        self.additionalSignedTransactionInfos = additionalSignedTransactionInfos.isEmpty
            ? nil
            : additionalSignedTransactionInfos
    }
}

struct ArkFileStoreKitProductConfiguration: Equatable, Sendable {
    let liteProductID: String
    let completeProductID: String
    let completeUpgradeProductID: String

    static var current: ArkFileStoreKitProductConfiguration {
        ArkFileStoreKitProductConfiguration(
            liteProductID: Brand.arkFileLiteProductID.trimmingCharacters(in: .whitespacesAndNewlines),
            completeProductID: Brand.arkFileCompleteProductID.trimmingCharacters(in: .whitespacesAndNewlines),
            completeUpgradeProductID: Brand.arkFileCompleteUpgradeProductID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var productIDs: Set<String> {
        Set([liteProductID, completeProductID, completeUpgradeProductID].filter { !$0.isEmpty })
    }

    func role(for productID: String) -> ArkFileStoreKitProductRole? {
        if productID == liteProductID {
            return .lite
        }
        if productID == completeProductID {
            return .complete
        }
        if productID == completeUpgradeProductID {
            return .completeUpgrade
        }
        return nil
    }

    func productID(for role: ArkFileStoreKitProductRole) -> String {
        switch role {
        case .lite:
            liteProductID
        case .complete:
            completeProductID
        case .completeUpgrade:
            completeUpgradeProductID
        }
    }

    func effectiveTier(forOwnedProductIDs productIDs: Set<String>) -> ArkFileContentTier? {
        if !completeProductID.isEmpty, productIDs.contains(completeProductID) {
            return .complete
        }
        if !liteProductID.isEmpty,
           !completeUpgradeProductID.isEmpty,
           productIDs.contains(liteProductID),
           productIDs.contains(completeUpgradeProductID) {
            return .complete
        }
        if !liteProductID.isEmpty, productIDs.contains(liteProductID) {
            return .lite
        }
        return nil
    }
}

enum ArkFileStoreKitOwnershipPolicy {
    static func accepts(_ ownershipType: Transaction.OwnershipType) -> Bool {
        switch ownershipType {
        case .purchased:
            true
        case .familyShared:
            false
        default:
            false
        }
    }
}

enum ArkFileStoreKitOwnershipRevisionPolicy {
    static func acceptsSnapshot(
        startedAt readRevision: UInt64,
        currentRevision: UInt64
    ) -> Bool {
        readRevision == currentRevision
    }
}

protocol ArkFileStoreKitEntitlementSource: Sendable {
    func synchronize() async throws
    func currentSnapshot(
        configuration: ArkFileStoreKitProductConfiguration,
        excludingProductID: String?
    ) async -> ArkFileStoreKitEntitlementSnapshot
    func confirmedRefundedProductIDs(
        configuration: ArkFileStoreKitProductConfiguration
    ) async -> Set<String>
}

extension ArkFileStoreKitEntitlementSource {
    func confirmedRefundedProductIDs(
        configuration: ArkFileStoreKitProductConfiguration
    ) async -> Set<String> {
        []
    }
}

struct ArkFileSystemStoreKitEntitlementSource: ArkFileStoreKitEntitlementSource {
    func synchronize() async throws {
        try await AppStore.sync()
    }

    func currentSnapshot(
        configuration: ArkFileStoreKitProductConfiguration,
        excludingProductID: String?
    ) async -> ArkFileStoreKitEntitlementSnapshot {
        guard !configuration.productIDs.isEmpty else {
            return ArkFileStoreKitEntitlementSnapshot(proofs: [])
        }
        var proofs: [ArkFileStoreKitContentAccessProof] = []
        var ineligibleOwnershipRoles = Set<ArkFileStoreKitProductRole>()
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.revocationDate == nil,
                  transaction.productID != excludingProductID,
                  let role = configuration.role(for: transaction.productID) else {
                continue
            }
            guard ArkFileStoreKitOwnershipPolicy.accepts(transaction.ownershipType) else {
                ineligibleOwnershipRoles.insert(role)
                continue
            }
            proofs.append(ArkFileStoreKitContentAccessProof(
                productID: transaction.productID,
                signedTransactionInfo: result.jwsRepresentation,
                role: role
            ))
        }
        return ArkFileStoreKitEntitlementSnapshot(
            proofs: proofs,
            ineligibleOwnershipRoles: ineligibleOwnershipRoles
        )
    }

    func confirmedRefundedProductIDs(
        configuration: ArkFileStoreKitProductConfiguration
    ) async -> Set<String> {
        var refunded = Set<String>()
        for productID in configuration.productIDs.sorted() {
            guard let result = await Transaction.latest(for: productID),
                  case let .verified(transaction) = result,
                  transaction.productID == productID,
                  transaction.revocationDate != nil,
                  ArkFileStoreKitOwnershipPolicy.accepts(
                      transaction.ownershipType
                  ) else {
                continue
            }
            refunded.insert(productID)
        }
        return refunded
    }
}

private struct ArkFileIOSContentAccessSnapshot: Codable, Equatable, Sendable {
    var statesByTier: [String: ArkFileIOSContentAccessState]
}

struct ArkFileIOSContentAccessStore {
    private let keychainAccount: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let readData: (String) -> Data?
    private let writeData: (Data, String) -> Bool
    private let deleteData: (String) -> Void

    init(
        keychainAccount: String = "arkfile.storekit.ios-content-access.v1",
        readData: ((String) -> Data?)? = nil,
        writeData: ((Data, String) -> Bool)? = nil,
        deleteData: ((String) -> Void)? = nil
    ) {
        self.keychainAccount = keychainAccount
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.readData = readData ?? { ArkFilePendingStoreKitKeychain.data(account: $0) }
        self.writeData = writeData ?? { ArkFilePendingStoreKitKeychain.set(data: $0, account: $1) }
        self.deleteData = deleteData ?? { ArkFilePendingStoreKitKeychain.delete(account: $0) }
    }

    @discardableResult
    func save(_ access: ArkFileIOSContentAccessState) -> Bool {
        var states = accessStates()
        let tierKey = access.contentTier?.rawValue ?? access.tier.lowercased()
        states[tierKey] = access
        return save(statesByTier: states)
    }

    func accessStates() -> [String: ArkFileIOSContentAccessState] {
        guard let data = readData(keychainAccount) else {
            return [:]
        }
        if let snapshot = try? decoder.decode(ArkFileIOSContentAccessSnapshot.self, from: data) {
            return snapshot.statesByTier
        }
        guard let legacyState = try? decoder.decode(ArkFileIOSContentAccessState.self, from: data),
              let tier = legacyState.contentTier else {
            return [:]
        }
        return [tier.rawValue: legacyState]
    }

    @discardableResult
    private func save(statesByTier: [String: ArkFileIOSContentAccessState]) -> Bool {
        guard let data = try? encoder.encode(ArkFileIOSContentAccessSnapshot(statesByTier: statesByTier)) else {
            return false
        }
        return writeData(data, keychainAccount)
    }

    func accessState() -> ArkFileIOSContentAccessState? {
        accessStates()
            .values
            .sorted { lhs, rhs in
                let lhsRank = Self.tierRank(lhs.contentTier)
                let rhsRank = Self.tierRank(rhs.contentTier)
                if lhsRank != rhsRank {
                    return lhsRank > rhsRank
                }
                return lhs.createdAt > rhs.createdAt
            }
            .first
    }

    func usableAccess(productID: String, now: Date = Date()) -> ArkFileIOSContentAccessState? {
        accessStates().values.first { state in
            state.productID == productID && state.isUsable(now: now)
        }
    }

    func usableAccess(tier: ArkFileContentTier, now: Date = Date()) -> ArkFileIOSContentAccessState? {
        guard let state = accessStates()[tier.rawValue],
              state.isUsable(now: now) else {
            return nil
        }
        return state
    }

    func clear() {
        deleteData(keychainAccount)
    }

    func markRevoked(tier: ArkFileContentTier? = nil, now: Date = Date()) {
        var states = accessStates()
        let key = tier?.rawValue ?? accessState()?.contentTier?.rawValue
        guard let key,
              var state = states[key] else { return }
        state.revokedAt = now
        states[key] = state
        save(statesByTier: states)
    }

    func markRevoked(tiers: Set<ArkFileContentTier>, now: Date = Date()) {
        guard !tiers.isEmpty else { return }
        var states = accessStates()
        var changed = false
        for tier in tiers {
            guard var state = states[tier.rawValue],
                  state.revokedAt == nil else {
                continue
            }
            state.revokedAt = now
            states[tier.rawValue] = state
            changed = true
        }
        if changed {
            save(statesByTier: states)
        }
    }

    private static func tierRank(_ tier: ArkFileContentTier?) -> Int {
        switch tier {
        case .complete:
            2
        case .lite:
            1
        case .standard, nil:
            0
        }
    }
}

enum ArkFileStoreKitDateParser {
    static func parseContentAccessExpiresAt(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

struct ArkFileValidatedStoreKitContentAccess: Equatable, Sendable {
    let contentAccessToken: String
    let tier: String
    let expiresAt: Date
}

enum ArkFileStoreKitContentAccessValidator {
    static func validate(
        contentAccessToken: String,
        tier: String,
        expiresAt: String,
        success: Bool?
    ) throws -> ArkFileValidatedStoreKitContentAccess {
        guard success != false,
              !contentAccessToken.isEmpty,
              let contentTier = ArkFileContentTier.iOSInstallableTier(named: tier),
              let expiresAt = ArkFileStoreKitDateParser.parseContentAccessExpiresAt(expiresAt) else {
            throw ArkFileContentError.invalidResponse
        }
        return ArkFileValidatedStoreKitContentAccess(
            contentAccessToken: contentAccessToken,
            tier: contentTier.rawValue,
            expiresAt: expiresAt
        )
    }
}

actor ArkFileStoreKitContentAccessAPI: ArkFileStoreKitContentAccessServing {
    private let siteURL: URL?
    private let urlSession: URLSession
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(siteURL: URL?, urlSession: URLSession = .shared) {
        self.siteURL = siteURL
        self.urlSession = urlSession
    }

    func contentAccess(
        plan: ArkFileStoreKitContentAccessRequestPlan
    ) async throws -> ArkFileStoreKitContentAccessResponse {
        let endpointPath = Bundle.main.usesSandboxAppStoreReceipt
            ? "storekit/testflight-ios-content-access"
            : "storekit/ios-content-access"
        let response: APIContentAccessResponse = try await request(
            path: endpointPath,
            body: ArkFileStoreKitContentAccessRequest(
                signedTransactionInfo: plan.primary.signedTransactionInfo,
                additionalSignedTransactionInfos: plan.additionalSignedTransactionInfos
            )
        )
        let validated = try ArkFileStoreKitContentAccessValidator.validate(
            contentAccessToken: response.contentAccessToken,
            tier: response.tier,
            expiresAt: response.expiresAt,
            success: response.success
        )
        return ArkFileStoreKitContentAccessResponse(
            contentAccessToken: validated.contentAccessToken,
            tier: validated.tier,
            expiresAt: validated.expiresAt
        )
    }

    func releaseAccess(plan: ArkFileStoreKitContentAccessRequestPlan,
                       binding: ArkFileContentReleaseBinding,
                       previousContentAccessToken: String?) async throws -> ArkFileStoreKitReleaseAccessResponse {
        struct Request: Encodable {
            let protocolVersion = 2
            let releaseID: String
            let releaseSHA256: String
            let signedTransactionInfo: String
            let additionalSignedTransactionInfos: [String]
            let previousContentAccessToken: String?
        }
        return try await request(path: Bundle.main.usesSandboxAppStoreReceipt
            ? "storekit/testflight-ios-content-access-v2" : "storekit/ios-content-access-v2",
            body: Request(releaseID: binding.releaseID, releaseSHA256: binding.releaseSHA256,
                signedTransactionInfo: plan.primary.signedTransactionInfo,
                additionalSignedTransactionInfos: plan.additionalSignedTransactionInfos,
                previousContentAccessToken: previousContentAccessToken))
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let endpoint = try endpoint(path)
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(body)

        let endpointDescription = Self.diagnosticEndpoint(for: endpoint)
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
            if let productIDs = ArkFileContentAPI.confirmedRefundProductIDs(
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
        return try jsonDecoder.decode(Response.self, from: data)
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let siteURL, let host = siteURL.host else {
            throw ArkFileContentError.invalidSiteURL
        }
        guard ArkFileContentAPI.isAllowed(host: host, allowDeveloperFixtureHosts: Brand.hasDeveloperContentAuthToken) else {
            throw ArkFileContentError.unsupportedHost(host)
        }
        guard siteURL.scheme?.lowercased() == "https"
                || ArkFileContentAPI.usesRelaxedDebugNetworking(host: host) else {
            throw ArkFileContentError.invalidSiteURL
        }
        return siteURL
            .appendingPathComponent("api")
            .appendingPathComponent(path)
    }

    private static func diagnosticEndpoint(for url: URL) -> String {
        let host = url.host ?? "storekit-server"
        return "\(host)\(url.path)"
    }

    private struct APIContentAccessResponse: Decodable {
        let success: Bool?
        let contentAccessToken: String
        let tier: String
        let expiresAt: String
    }

    private struct APIErrorResponse: Decodable {
        let error: String
    }
}

@MainActor
final class ArkFileLitePurchaseManager: ObservableObject {
    static let shared = ArkFileLitePurchaseManager()

    private let pendingPurchaseStore: ArkFilePendingStoreKitPurchaseStore
    private let contentAccessStore: ArkFileIOSContentAccessStore
    private let contentAccessAPI: any ArkFileStoreKitContentAccessServing
    private let entitlementSource: any ArkFileStoreKitEntitlementSource
    private let productConfiguration: ArkFileStoreKitProductConfiguration
    private let now: @Sendable () -> Date
    private let hadInstalledPaidContentAtInitialization: Bool
    private let stopAcquisitionAfterEntitlementLoss: @MainActor (
        ArkFileContentTier,
        Bool
    ) -> Void
    private var transactionUpdatesTask: Task<Void, Never>?
    private var entitlementGeneration: UInt64 = 0
    private var entitlementStateRevision: UInt64 = 0
    private var ownershipStateRevision: UInt64 = 0
    private var authorizationAttemptRevision: UInt64 = 0
    private var servicedRevocationState = ArkFileStoreKitRevocationOutcome(
        revokeLite: false,
        revokeComplete: false
    )
    @Published private(set) var isLiteAccessRevoked: Bool
    @Published private(set) var isCompleteAccessRevoked: Bool
    @Published private(set) var lastAccessMintedEvent: ArkFileStoreKitAccessMintEvent?
    @Published private(set) var ownershipSnapshot: ArkFileStoreKitOwnershipState
    /// True only when the current process has observed a direct StoreKit proof.
    /// Cached access keeps installed content usable, but must not be presented as
    /// current-account ownership until StoreKit confirms it again.
    @Published private(set) var hasCurrentStoreKitProof: Bool
    @Published private(set) var currentStoreKitProofTier: ArkFileContentTier?
    @Published private(set) var hasResolvedCurrentStoreKitProof: Bool
    @Published private(set) var contentAuthorizationReadiness: ArkFileContentAuthorizationReadiness

    init(
        pendingPurchaseStore: ArkFilePendingStoreKitPurchaseStore = ArkFilePendingStoreKitPurchaseStore(),
        contentAccessStore: ArkFileIOSContentAccessStore = ArkFileIOSContentAccessStore(),
        contentAccessAPI: any ArkFileStoreKitContentAccessServing = ArkFileStoreKitContentAccessAPI(
            siteURL: URL(string: Brand.arkFileSiteURL)
        ),
        entitlementSource: any ArkFileStoreKitEntitlementSource = ArkFileSystemStoreKitEntitlementSource(),
        productConfiguration: ArkFileStoreKitProductConfiguration = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        hasInstalledPaidContent: @escaping @MainActor @Sendable () -> Bool = {
            ArkFileContentPackInstaller
                .managedContentRootWithAnyReadableContentIfAvailable() != nil
        },
        stopAcquisitionAfterEntitlementLoss: @escaping @MainActor (
            ArkFileContentTier,
            Bool
        ) -> Void = { tier, cancelCurrentInstallTask in
            ArkFileContentPackInstaller.shared.cancelActiveDownloadAfterRevocation(
                of: tier,
                cancelCurrentInstallTask: cancelCurrentInstallTask
            )
        }
    ) {
        self.pendingPurchaseStore = pendingPurchaseStore
        self.contentAccessStore = contentAccessStore
        self.contentAccessAPI = contentAccessAPI
        self.entitlementSource = entitlementSource
        self.productConfiguration = productConfiguration
        self.now = now
        self.hadInstalledPaidContentAtInitialization = hasInstalledPaidContent()
        self.stopAcquisitionAfterEntitlementLoss = stopAcquisitionAfterEntitlementLoss
        let accessStates = contentAccessStore.accessStates()
        // Shipped UserDefaults read-lock flags are deliberately not restored.
        // Durable local commits control reads; these properties describe only
        // whether future acquisition is currently allowed.
        self.isLiteAccessRevoked = accessStates[ArkFileContentTier.lite.rawValue]?.isRevoked == true
        self.isCompleteAccessRevoked = accessStates[ArkFileContentTier.complete.rawValue]?.isRevoked == true
        self.lastAccessMintedEvent = nil
        self.ownershipSnapshot = Self.lastKnownVerifiedOwnership(
            from: Array(accessStates.values)
        ) ?? .checking
        self.hasCurrentStoreKitProof = false
        self.currentStoreKitProofTier = nil
        self.hasResolvedCurrentStoreKitProof = false
        self.contentAuthorizationReadiness = .unavailable
        // Migrate away from the shipped read-lock flags. Commerce state is
        // already persisted in the content-access store above.
        ArkFileEssentialsAccessGate.clearLegacyReadRevocationFlags()
        Self.clearLegacyPendingStoreKitPurchaseOnce(pendingPurchaseStore)
    }

    var hasPendingLitePurchaseForCurrentAccount: Bool {
        false
    }

    var hasCachedLiteContentAccess: Bool {
        (contentAccessStore.usableAccess(tier: .lite) != nil ||
            contentAccessStore.usableAccess(tier: .complete) != nil) &&
            !isLiteAccessRevoked
    }

    var hasCachedCompleteContentAccess: Bool {
        contentAccessStore.usableAccess(tier: .complete) != nil
            && !isLiteAccessRevoked
            && !isCompleteAccessRevoked
    }

    var isCheckingApplePurchases: Bool {
        ownershipSnapshot == .checking
            && !hasCachedLiteContentAccess
            && !hasCachedCompleteContentAccess
            && !isLiteAccessRevoked
            && !isCompleteAccessRevoked
            && !Brand.hasDeveloperContentAuthToken
    }

    func startObservingTransactions() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(transactionResult: result)
            }
        }
    }

    func stopObservingTransactions() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = nil
    }

    func makeAcquisitionLease(
        for tier: ArkFileContentTier
    ) throws -> ArkFileStoreKitAcquisitionLease {
        let lease = ArkFileStoreKitAcquisitionLease(
            tier: tier,
            entitlementGeneration: entitlementGeneration
        )
        try validateAcquisitionLease(lease)
        return lease
    }

    func validateAcquisitionLease(
        _ lease: ArkFileStoreKitAcquisitionLease
    ) throws {
        guard lease.entitlementGeneration == entitlementGeneration else {
            throw ArkFileStoreKitMintError.supersededByEntitlementChange
        }
        switch lease.tier {
        case .lite:
            guard !isLiteAccessRevoked else {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
        case .complete:
            guard !isLiteAccessRevoked, !isCompleteAccessRevoked else {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
        case .standard:
            throw ArkFileContentError.invalidManifestTier(
                ArkFileContentTier.standard.rawValue
            )
        }
    }

    /// A release token is minted directly from verified StoreKit proofs. Never
    /// downgrade to a v1 token or retarget a persisted request during renewal.
    func releaseAuthorization(for request: ArkFileContentReleaseRequest,
                              allowsCellular: Bool = false,
                              previousContentAccessToken: String? = nil) async throws -> ArkFileContentAuthorization {
        guard let plan = try await currentStoreKitContentAccessPlan(),
              plan.requestedTier == .complete || request.tier == .lite else {
            throw ArkFileContentError.purchaseRequired
        }
        let generation = entitlementGeneration
        let response = try await contentAccessAPI.releaseAccess(plan: plan, binding: request.binding,
                                                                previousContentAccessToken: previousContentAccessToken)
        guard generation == entitlementGeneration else {
            throw ArkFileStoreKitMintError.supersededByEntitlementChange
        }
        let validated = try ArkFileStoreKitReleaseAccessValidator.validate(response, binding: request.binding, tier: request.tier)
        return .iOSContentToken(validated.contentAccessToken, expiresAt: validated.expiresAt,
                                storeKitTransactionJWS: plan.primary.signedTransactionInfo)
            .allowingCellularDownload(allowsCellular)
    }

    func authorizationForLite(allowPurchase: Bool) async throws -> ArkFileContentAuthorization {
        try await authorization(for: .lite, allowPurchase: allowPurchase)
    }

    func authorization(
        for tier: ArkFileContentTier,
        allowPurchase: Bool
    ) async throws -> ArkFileContentAuthorization {
        let developerToken = Brand.arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !developerToken.isEmpty {
            publishDeveloperAuthorization()
            return .developerToken(developerToken)
        }
        let currentAuthorization: ArkFileContentAuthorization?
        do {
            currentAuthorization = try await currentEntitlementAuthorization(
                requiredTier: tier
            )
        } catch ArkFileStoreKitMintError.supersededByEntitlementChange {
            // Launch reconciliation and the first purchase tap may issue the
            // same currentEntitlements read concurrently. If the other read
            // wins ownership publication, retry once against that revision so
            // a new customer never sees a transient verification error.
            // Never retry a superseded token mint: a refund or other
            // entitlement-loss transition deliberately invalidates that work.
            guard ownershipSnapshot == .notOwned,
                  !isLiteAccessRevoked,
                  !isCompleteAccessRevoked else {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
            currentAuthorization = try await currentEntitlementAuthorization(
                requiredTier: tier
            )
        }
        if let authorization = currentAuthorization {
            return authorization
        }
        guard allowPurchase else {
            await markAccessRevokedIfNeeded()
            throw Self.requiresOwnershipVerificationBeforePurchase(
                ownershipSnapshot
            )
                ? ArkFileContentError.ownershipVerificationRequired
                : ArkFileContentError.purchaseRequired
        }
        guard Self.canBeginProductPurchase(
            requestedTier: tier,
            ownership: ownershipSnapshot
        ) else {
            throw ArkFileContentError.ownershipVerificationRequired
        }
        switch tier {
        case .lite:
            return try await purchaseLite()
        case .complete:
            return try await purchaseComplete()
        case .standard:
            throw ArkFileContentError.invalidManifestTier(tier.rawValue)
        }
    }

    func reconcileLiteEntitlementOnLaunchOrForeground() async {
        let developerToken = Brand.arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !developerToken.isEmpty {
            isLiteAccessRevoked = false
            isCompleteAccessRevoked = false
            publishDeveloperAuthorization()
            return
        }
        do {
            let confirmedRefundedProductIDs = await entitlementSource
                .confirmedRefundedProductIDs(
                    configuration: productConfiguration
                )
            if !confirmedRefundedProductIDs.isEmpty {
                _ = await applyConfirmedRefund(
                    productIDs: confirmedRefundedProductIDs.sorted(),
                    cancelCurrentInstallTask: true
                )
            }
            guard let plan = try await currentStoreKitContentAccessPlan() else {
                contentAuthorizationReadiness = .unavailable
                await markAccessRevokedIfNeeded()
                return
            }
            let cached = contentAccessStore.usableAccess(tier: plan.requestedTier)
            let hasRelevantRevocation = plan.requestedTier == .complete
                ? isCompleteAccessRevoked || isLiteAccessRevoked
                : isLiteAccessRevoked
            if let cached {
                contentAuthorizationReadiness = .ready(
                    plan.requestedTier,
                    expiresAt: cached.expiresAt
                )
            }
            guard cached == nil
                    || hasRelevantRevocation else {
                return
            }
            _ = try await mintContentAccessToken(
                plan: plan,
                notifyAccessMinted: false,
                requiredTier: plan.requestedTier
            )
        } catch {
            Log.ContentPack.error(
                "Unable to reconcile StoreKit entitlement state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func restoreLiteAuthorization() async throws -> ArkFileContentAuthorization {
        try await restoreAuthorization(for: .lite)
    }

    /// Synchronizes StoreKit first, then resolves and mints the highest tier the
    /// current Apple Account owns as one operation. Keeping the tier and token
    /// together prevents a stale pre-sync tier choice from silently restoring
    /// Complete owners as Essentials users.
    func restoreHighestOwnedAuthorization() async throws -> ArkFileRestoredContentAccess {
        let developerToken = Brand.arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !developerToken.isEmpty {
            publishDeveloperAuthorization()
            return ArkFileRestoredContentAccess(
                tier: .complete,
                authorization: .developerToken(developerToken)
            )
        }

        let plan = try await synchronizedRestorePlan()
        let authorization = try await mintRestoredContentAccessToken(
            plan: plan,
            requiredTier: plan.requestedTier
        )
        return ArkFileRestoredContentAccess(
            tier: plan.requestedTier,
            authorization: authorization
        )
    }

    func restoreAuthorization(for tier: ArkFileContentTier) async throws -> ArkFileContentAuthorization {
        let developerToken = Brand.arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !developerToken.isEmpty {
            publishDeveloperAuthorization()
            return .developerToken(developerToken)
        }

        let plan = try await synchronizedRestorePlan()
        return try await mintRestoredContentAccessToken(
            plan: plan,
            requiredTier: tier
        )
    }

    private func mintRestoredContentAccessToken(
        plan: ArkFileStoreKitContentAccessRequestPlan,
        requiredTier: ArkFileContentTier
    ) async throws -> ArkFileContentAuthorization {
        let restoreGeneration = entitlementGeneration
        var verifiedRevision = ownershipStateRevision
        var verifiedTier: ArkFileContentTier? = plan.requiresServerHistoryRecovery
            ? nil
            : plan.requestedTier
        do {
            guard Self.tier(plan.requestedTier, satisfies: requiredTier) else {
                throw ArkFileContentError.purchaseRequired
            }
            return try await mintContentAccessToken(
                plan: plan,
                requiredTier: requiredTier,
                serverHistoryVerified: { tier in
                    // An orphaned upgrade becomes evidence only when this
                    // request's server response verifies its Essentials leg.
                    verifiedTier = tier
                    verifiedRevision = self.ownershipStateRevision
                }
            )
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  error as? ArkFileStoreKitMintError != .supersededByEntitlementChange,
                  restoreGeneration == entitlementGeneration,
                  verifiedRevision == ownershipStateRevision,
                  let verifiedTier else {
                throw error
            }
            if case ArkFileContentError.confirmedStoreKitRefund = error {
                throw error
            }
            if case ArkFileContentError.purchaseCancelled = error {
                throw error
            }
            if case ArkFileContentError.completeVerificationPending = error {
                throw error
            }
            throw ArkFileVerifiedRestoreAuthorizationError(
                verifiedTier: verifiedTier,
                underlyingError: error
            )
        }
    }

    private func synchronizedRestorePlan() async throws -> ArkFileStoreKitContentAccessRequestPlan {
        var synchronizationError: Error?
        do {
            try await entitlementSource.synchronize()
        } catch {
            synchronizationError = error
        }

        let synchronizedSnapshot: ArkFileStoreKitEntitlementSnapshot
        do {
            synchronizedSnapshot = try await currentStoreKitEntitlementSnapshot(
                allowFreshNotOwnedResolution: synchronizationError == nil
            )
        } catch ArkFileStoreKitMintError.supersededByEntitlementChange {
            // A foreground currentEntitlements read can resolve a truly fresh
            // installation to not-owned while this explicit restore is already
            // in flight. Re-read once against the winning ownership revision so
            // that benign race does not turn Restore Purchases into an error.
            synchronizedSnapshot = try await currentStoreKitEntitlementSnapshot(
                allowFreshNotOwnedResolution: synchronizationError == nil
            )
        }
        if !synchronizedSnapshot.ineligibleOwnershipRoles.isEmpty {
            await reconcileIneligibleOwnership(
                using: synchronizedSnapshot.proofs,
                ineligibleRoles: synchronizedSnapshot.ineligibleOwnershipRoles
            )
        }
        if let plan = ArkFileStoreKitContentAccessRequestPlan.make(
            from: synchronizedSnapshot.proofs
        ) {
            if synchronizationError != nil {
                Log.ContentPack.info("Restore Purchases recovered an entitlement after App Store sync failed")
            } else {
                // A successful user-requested synchronization is authoritative
                // at the tier boundary too. If only Essentials remains, close
                // previously held Complete access even if its revocation update
                // was missed while the app was not running.
                if plan.requestedTier == .lite, hasLocalCompleteAccessEvidence {
                    await invalidateCompleteContentAccessAfterRevocation()
                } else if hasCachedLiteContentAccess {
                    Log.ContentPack.info("Restore Purchases was triggered while ArkFile content is already entitled")
                }
            }
            return plan
        }

        if let recoveryPlan = ArkFileStoreKitContentAccessRequestPlan
            .makeServerHistoryRecovery(from: synchronizedSnapshot.proofs) {
            // Restore Purchases is the only caller allowed to send an orphaned
            // upgrade proof. The backend verifies the missing Essentials leg
            // against Apple's transaction history before returning Complete.
            Log.ContentPack.info(
                "Restore Purchases is asking the content service to recover the Essentials dependency for a verified Complete Upgrade"
            )
            return recoveryPlan
        }

        if let synchronizationError {
            throw synchronizationError
        }

        guard synchronizedSnapshot.proofs.isEmpty else {
            // A completed synchronization can authoritatively prove that an
            // account has no ArkFile transactions, but it cannot turn a
            // non-empty, incomplete history into "not owned." The critical
            // case is Complete Upgrade arriving without its qualifying
            // Essentials proof. Keep every purchase SKU closed until StoreKit
            // returns a coherent proof set.
            contentAuthorizationReadiness = .unavailable
            throw ArkFileContentError.ownershipVerificationRequired
        }

        Log.ContentPack.info("Restore Purchases found no ArkFile StoreKit entitlement")
        // A user-initiated App Store sync that completed and returned no proofs
        // is authoritative, unlike an ordinary foreground StoreKit snapshot.
        await markAccessRevokedIfNeeded(authoritativeAbsence: true)
        contentAuthorizationReadiness = .unavailable
        throw ArkFileContentError.noStoreKitPurchaseFound
    }

    private var hasLocalCompleteAccessEvidence: Bool {
        guard !isCompleteAccessRevoked else {
            return false
        }
        return contentAccessStore.accessStates()[ArkFileContentTier.complete.rawValue]?.isRevoked == false
            || ArkFileContentPackInstaller.shared.installedTier == .complete
            || ArkFileContentPackInstaller.shared.state.tier == .complete
    }

    func refreshLiteContentAuthorization(
        allowingCellularDownload allowsCellularDownload: Bool = false
    ) async throws -> ArkFileContentAuthorization {
        try await refreshContentAuthorization(for: .lite, allowingCellularDownload: allowsCellularDownload)
    }

    func refreshContentAuthorization(
        for tier: ArkFileContentTier,
        allowingCellularDownload allowsCellularDownload: Bool = false
    ) async throws -> ArkFileContentAuthorization {
        let developerToken = Brand.arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !developerToken.isEmpty {
            publishDeveloperAuthorization()
            return ArkFileContentAuthorization
                .developerToken(developerToken)
                .allowingCellularDownload(allowsCellularDownload)
        }
        guard let plan = try await currentStoreKitContentAccessPlan() else {
            contentAuthorizationReadiness = .unavailable
            await markAccessRevokedIfNeeded()
            throw Self.requiresOwnershipVerificationBeforePurchase(
                ownershipSnapshot
            )
                ? ArkFileContentError.ownershipVerificationRequired
                : ArkFileContentError.purchaseRequired
        }
        guard Self.tier(plan.requestedTier, satisfies: tier) else {
            throw ArkFileContentError.purchaseRequired
        }
        let refreshed = try await mintContentAccessToken(
            plan: plan,
            notifyAccessMinted: false,
            requiredTier: tier
        )
        Log.ContentPack.info("Refreshed iOS content token after content API authorization failure")
        return refreshed.allowingCellularDownload(allowsCellularDownload)
    }

    func invalidateLiteContentAccessAfterRevocation() async {
        publishOwnership(.checking)
        commitEntitlementState(liteRevoked: true, completeRevoked: nil)
        performEntitlementLossSideEffects()
    }

    private func currentEntitlementAuthorization(
        requiredTier: ArkFileContentTier
    ) async throws -> ArkFileContentAuthorization? {
        guard let plan = try await currentStoreKitContentAccessPlan() else {
            contentAuthorizationReadiness = .unavailable
            return nil
        }
        guard Self.tier(plan.requestedTier, satisfies: requiredTier) else {
            refreshAuthorizationReadinessFromCache()
            return nil
        }
        if let cached = contentAccessStore.usableAccess(tier: plan.requestedTier) {
            clearLiteRevocationAfterConfirmedAccess()
            if plan.requestedTier == .complete {
                clearCompleteRevocationAfterConfirmedAccess()
            }
            contentAuthorizationReadiness = .ready(
                plan.requestedTier,
                expiresAt: cached.expiresAt
            )
            return .iOSContentToken(
                cached.contentAccessToken,
                expiresAt: cached.expiresAt,
                storeKitTransactionJWS: cached.signedTransactionInfo
            )
        }
        return try await mintContentAccessToken(plan: plan, requiredTier: requiredTier)
    }

    private func currentStoreKitContentAccessPlan() async throws -> ArkFileStoreKitContentAccessRequestPlan? {
        let snapshot = try await currentStoreKitEntitlementSnapshot()
        if !snapshot.ineligibleOwnershipRoles.isEmpty {
            await reconcileIneligibleOwnership(
                using: snapshot.proofs,
                ineligibleRoles: snapshot.ineligibleOwnershipRoles
            )
        }
        guard let plan = ArkFileStoreKitContentAccessRequestPlan.make(from: snapshot.proofs) else {
            return nil
        }
        return plan
    }

    /// Whether this Apple Account holds a StoreKit entitlement that grants
    /// Complete (outright or upgrade). Used to pick the tier for the single
    /// Restore Purchases action in Settings.
    func ownsCompleteGrantingEntitlement() async -> Bool {
        (try? await currentStoreKitContentAccessPlan()?.requestedTier) == .complete
    }

    /// Read-only merchandising eligibility for the Complete upgrade offer.
    /// This intentionally reads the current verified StoreKit snapshot without
    /// synchronizing purchases, minting a content token, or changing cached
    /// access. Family-shared and otherwise ineligible ownership never appears
    /// in `proofs`, so it cannot advertise the upgrade SKU.
    func hasCurrentEssentialsProofForUpgradeOffer() async -> Bool {
        guard let snapshot = try? await currentStoreKitEntitlementSnapshot() else {
            return false
        }
        return snapshot.proofs.contains { $0.role == .lite }
    }

    private func currentStoreKitContentAccessProofs(
        excludingProductID excludedProductID: String? = nil
    ) async throws -> [ArkFileStoreKitContentAccessProof] {
        let snapshot = try await currentStoreKitEntitlementSnapshot(
            excludingProductID: excludedProductID
        )
        return snapshot.proofs
    }

    private func currentStoreKitEntitlementSnapshot(
        excludingProductID excludedProductID: String? = nil,
        allowFreshNotOwnedResolution: Bool = true
    ) async throws -> ArkFileStoreKitEntitlementSnapshot {
        let readOwnershipRevision = ownershipStateRevision
        let readEntitlementGeneration = entitlementGeneration
        let snapshot = await entitlementSource.currentSnapshot(
            configuration: productConfiguration,
            excludingProductID: excludedProductID
        )
        guard readEntitlementGeneration == entitlementGeneration,
              ArkFileStoreKitOwnershipRevisionPolicy.acceptsSnapshot(
                  startedAt: readOwnershipRevision,
                  currentRevision: ownershipStateRevision
              ) else {
            throw ArkFileStoreKitMintError.supersededByEntitlementChange
        }
        if excludedProductID == nil {
            guard publishOwnership(
                snapshot,
                ifCurrentRevisionIs: readOwnershipRevision,
                preservingCurrentStateOnEmptySnapshot: true,
                allowFreshNotOwnedResolution: allowFreshNotOwnedResolution
            ) else {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
        }
        return snapshot
    }

    private func purchaseLite() async throws -> ArkFileContentAuthorization {
        try await purchaseProduct(role: .lite, requiredTier: .lite)
    }

    private func purchaseComplete() async throws -> ArkFileContentAuthorization {
        let existingProofs = try await currentStoreKitContentAccessProofs()
        guard let role = ArkFileStoreKitCompleteProductRoleResolver.purchaseRole(
            proofs: existingProofs,
            ownership: ownershipSnapshot
        ) else {
            throw ArkFileContentError.ownershipVerificationRequired
        }
        return try await purchaseProduct(
            role: role,
            requiredTier: .complete,
            additionalProofs: existingProofs
        )
    }

    private func purchaseProduct(
        role: ArkFileStoreKitProductRole,
        requiredTier: ArkFileContentTier,
        additionalProofs: [ArkFileStoreKitContentAccessProof] = []
    ) async throws -> ArkFileContentAuthorization {
        let productID = productConfiguration.productID(for: role)
        guard !productID.isEmpty else {
            throw ArkFileContentError.productNotConfigured
        }
        let products = try await Product.products(for: [productID])
        guard let product = products.first(where: { $0.id == productID }) else {
            Log.ContentPack.error("ArkFile Essentials StoreKit product unavailable: \(productID, privacy: .public)")
            throw ArkFileContentError.productUnavailable(productID)
        }
        try ArkFileStoreKitProductValidator.validateProduct(
            productID: product.id,
            expectedProductID: productID,
            isNonConsumable: product.type == .nonConsumable
        )
        let purchaseStartedAt = now()
        let result = try await product.purchase()
        switch result {
        case let .success(verification):
            guard case let .verified(transaction) = verification else {
                Log.ContentPack.info("StoreKit returned an unverified ArkFile Essentials purchase result")
                throw ArkFileContentError.unverifiedPurchase
            }
            guard ArkFileStoreKitOwnershipPolicy.accepts(transaction.ownershipType) else {
                Log.ContentPack.info("Ignoring non-purchased StoreKit ownership for a direct ArkFile product")
                publishOwnership(.ineligibleFamilyShared)
                contentAuthorizationReadiness = .unavailable
                throw ArkFileContentError.unverifiedPurchase
            }
#if os(iOS)
            ArkFileAdMeasurement.shared.recordPaidPurchase(
                transaction: transaction,
                signedTransactionInfo: verification.jwsRepresentation,
                purchaseStartedAt: purchaseStartedAt
            )
#endif
            let primary = ArkFileStoreKitContentAccessProof(
                productID: transaction.productID,
                signedTransactionInfo: verification.jwsRepresentation,
                role: role
            )
            let additional = additionalProofs.filter { $0.productID != primary.productID }
            publishOwnership(ArkFileStoreKitEntitlementSnapshot(
                proofs: [primary] + additional
            ))
            guard let plan = ArkFileStoreKitContentAccessRequestPlan.make(
                from: [primary] + additional
            ) else {
                throw ArkFileContentError.completeVerificationPending
            }
            do {
                return try await mintContentAccessToken(
                    plan: plan,
                    transactionToFinish: transaction,
                    requiredTier: requiredTier
                )
            } catch {
                // Product.purchase has returned a verified, directly owned
                // transaction. From this point onward, every mint/finish
                // non-refund failure must tell the UI that payment may have
                // completed and direct the customer to recovery instead of
                // another purchase. Exact refund evidence keeps its specific,
                // actionable meaning.
                if case ArkFileContentError.confirmedStoreKitRefund = error {
                    throw error
                }
                throw Self.purchaseLinkingError(afterVerifiedPurchase: error)
            }
        case .pending:
            throw ArkFileContentError.purchasePending
        case .userCancelled:
            throw ArkFileContentError.purchaseCancelled
        @unknown default:
            throw ArkFileContentError.invalidResponse
        }
    }

    private func mintContentAccessToken(
        plan: ArkFileStoreKitContentAccessRequestPlan,
        transactionToFinish: Transaction? = nil,
        notifyAccessMinted: Bool = false,
        requiredTier: ArkFileContentTier = .lite,
        serverHistoryVerified: ((ArkFileContentTier) -> Void)? = nil
    ) async throws -> ArkFileContentAuthorization {
        let mintGeneration = entitlementGeneration
        let mintOwnershipRevision = ownershipStateRevision
        authorizationAttemptRevision &+= 1
        let authorizationAttempt = authorizationAttemptRevision
        contentAuthorizationReadiness = .preparing(plan.requestedTier)
        do {
            let response = try await contentAccessAPI.contentAccess(plan: plan)
            try ensureMintGenerationIsCurrent(mintGeneration)
            let createdAt = now()
            guard let responseTier = ArkFileContentTier.iOSInstallableTier(named: response.tier) else {
                throw ArkFileContentError.invalidResponse
            }
            guard responseTier == plan.requestedTier else {
                if plan.primary.role == .completeUpgrade,
                   plan.requestedTier == .complete,
                   responseTier == .lite {
                    throw ArkFileContentError.completeVerificationPending
                }
                throw ArkFileContentError.invalidResponse
            }
            guard Self.tier(responseTier, satisfies: requiredTier) else {
                // The server fell back to an Essentials token for a Complete
                // request. For an upgrade purchase this almost always means
                // Apple's ownership-history check has not caught up yet — a
                // retryable state, not a missing purchase.
                if requiredTier == .complete, plan.primary.role == .completeUpgrade {
                    throw ArkFileContentError.completeVerificationPending
                }
                throw ArkFileContentError.purchaseRequired
            }
            if plan.requiresServerHistoryRecovery,
               !ArkFileStoreKitOwnershipRevisionPolicy.acceptsSnapshot(
                   startedAt: mintOwnershipRevision,
                   currentRevision: ownershipStateRevision
               ) {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
            let stateProof = plan.stateProof(for: responseTier)
            let state = ArkFileIOSContentAccessState(
                productID: stateProof.productID,
                signedTransactionInfo: stateProof.signedTransactionInfo,
                contentAccessToken: response.contentAccessToken,
                tier: responseTier.rawValue,
                expiresAt: response.expiresAt,
                createdAt: createdAt,
                revokedAt: nil
            )
            let didRestorePreviouslyRevokedAccess = isLiteAccessRevoked
                || (
                    responseTier == .complete
                        && isCompleteAccessRevoked
                )
            if plan.requiresServerHistoryRecovery {
                // The exact Complete response is the authoritative confirmation
                // that Apple's history contains both the Upgrade and its
                // qualifying Essentials purchase. Preserve that ownership even
                // if saving the separate download authorization fails below.
                // The saved state's upgrade product/JWS retains both-leg loss
                // handling once persistence succeeds.
                currentStoreKitProofTier = .complete
                hasCurrentStoreKitProof = true
                publishOwnership(.complete)
                serverHistoryVerified?(.complete)
            }
            guard contentAccessStore.save(state) else {
                throw ArkFileStoreKitMintError.contentAccessPersistenceFailed
            }
            if authorizationAttempt == authorizationAttemptRevision {
                contentAuthorizationReadiness = .ready(
                    responseTier,
                    expiresAt: response.expiresAt
                )
            }
            entitlementStateRevision &+= 1
            servicedRevocationState = ArkFileStoreKitRevocationOutcome(
                revokeLite: false,
                revokeComplete: responseTier == .complete
                    ? false
                    : servicedRevocationState.revokeComplete
            )
            isLiteAccessRevoked = false
            if responseTier == .complete {
                isCompleteAccessRevoked = false
            }
            if didRestorePreviouslyRevokedAccess {
                await LibraryOperations.reValidate()
                try ensureMintGenerationIsCurrent(mintGeneration)
                await ArkFileLocalContentLibrary.shared.refresh()
                try ensureMintGenerationIsCurrent(mintGeneration)
            }
            if notifyAccessMinted {
                lastAccessMintedEvent = ArkFileStoreKitAccessMintEvent(
                    id: UUID(),
                    tier: responseTier,
                    productID: plan.primary.productID,
                    mintedAt: createdAt
                )
            }
            if let transactionToFinish {
                // Do not finish Apple's transaction until acquisition and any
                // restored download authority are durably saved. If the write
                // fails, StoreKit can redeliver the transaction and the user
                // can recover with Restore Purchases.
                try ensureMintGenerationIsCurrent(mintGeneration)
                await transactionToFinish.finish()
                try ensureMintGenerationIsCurrent(mintGeneration)
            }
            return .iOSContentToken(
                response.contentAccessToken,
                expiresAt: response.expiresAt,
                storeKitTransactionJWS: stateProof.signedTransactionInfo
            )
        } catch {
            if authorizationAttempt == authorizationAttemptRevision {
                refreshAuthorizationReadinessFromCache()
            }
            if case let ArkFileContentError.confirmedStoreKitRefund(productIDs) = error {
                await applyConfirmedRefund(productIDs: productIDs)
                throw error
            }
            if entitlementGeneration != mintGeneration
                || error as? ArkFileStoreKitMintError == .supersededByEntitlementChange {
                throw ArkFileStoreKitMintError.supersededByEntitlementChange
            }
            throw error
        }
    }

    private func ensureMintGenerationIsCurrent(_ generation: UInt64) throws {
        guard generation == entitlementGeneration else {
            throw ArkFileStoreKitMintError.supersededByEntitlementChange
        }
    }

    @discardableResult
    private func publishOwnership(
        _ snapshot: ArkFileStoreKitEntitlementSnapshot,
        ifCurrentRevisionIs expectedRevision: UInt64? = nil,
        preservingCurrentStateOnEmptySnapshot: Bool = false,
        allowFreshNotOwnedResolution: Bool = true
    ) -> Bool {
        if let expectedRevision,
           !ArkFileStoreKitOwnershipRevisionPolicy.acceptsSnapshot(
               startedAt: expectedRevision,
               currentRevision: ownershipStateRevision
        ) {
            return false
        }
        hasResolvedCurrentStoreKitProof = true
        currentStoreKitProofTier = ArkFileStoreKitContentAccessRequestPlan.make(
            from: snapshot.proofs
        )?.requestedTier
        hasCurrentStoreKitProof = currentStoreKitProofTier != nil
        if preservingCurrentStateOnEmptySnapshot,
           snapshot.proofs.isEmpty,
           snapshot.ineligibleOwnershipRoles.isEmpty {
            if allowFreshNotOwnedResolution,
               ownershipSnapshot == .checking,
               !hasLocalPaidAccessEvidence {
                // A genuinely fresh installation has no prior purchase fact to
                // protect. Resolve the ordinary currentEntitlements read so the
                // user can see a purchase option without first invoking the
                // account-wide, UI-presenting AppStore.sync() flow. This is only
                // an ownership publication; it must not persist revocation.
                publishOwnership(.notOwned)
            }
            // Any cached authorization or installed paid content is durable
            // evidence that this device previously verified a purchase. An
            // ordinary local StoreKit miss cannot erase that fact, so retain
            // checking, last-known ownership, or an earlier authoritative
            // result until explicit Restore Purchases resolves the account.
            return true
        }
        publishOwnership(ArkFileStoreKitOwnershipState.resolve(snapshot))
        return true
    }

    private var hasLocalPaidAccessEvidence: Bool {
        hadInstalledPaidContentAtInitialization
            || !contentAccessStore.accessStates().isEmpty
    }

    private func publishOwnership(_ state: ArkFileStoreKitOwnershipState) {
        if state == .checking || state == .notOwned || state == .ineligibleFamilyShared {
            currentStoreKitProofTier = nil
            hasCurrentStoreKitProof = false
        }
        guard ownershipSnapshot != state else {
            return
        }
        ownershipStateRevision &+= 1
        ownershipSnapshot = state
    }

    private func invalidateOwnershipSnapshotReads() {
        ownershipStateRevision &+= 1
    }

    private func publishDeveloperAuthorization() {
        // The developer override authorizes fixture content but is deliberately
        // not represented as an Apple purchase.
        hasResolvedCurrentStoreKitProof = true
        publishOwnership(.notOwned)
        contentAuthorizationReadiness = .ready(.complete, expiresAt: nil)
    }

    private func refreshAuthorizationReadinessFromCache() {
        if !isLiteAccessRevoked,
           !isCompleteAccessRevoked,
           let complete = contentAccessStore.usableAccess(tier: .complete, now: now()) {
            contentAuthorizationReadiness = .ready(
                .complete,
                expiresAt: complete.expiresAt
            )
            return
        }
        if !isLiteAccessRevoked,
           let essentials = contentAccessStore.usableAccess(tier: .lite, now: now()) {
            contentAuthorizationReadiness = .ready(
                .lite,
                expiresAt: essentials.expiresAt
            )
            return
        }
        contentAuthorizationReadiness = .unavailable
    }

    private func invalidateEntitlementGeneration() {
        entitlementGeneration &+= 1
    }

    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result else {
            Log.ContentPack.info("Ignoring unverified StoreKit transaction update for ArkFile Essentials")
            return
        }
        guard let role = productConfiguration.role(for: transaction.productID) else {
            return
        }
        let hasDirectOwnership = ArkFileStoreKitOwnershipPolicy.accepts(transaction.ownershipType)
        let isConfirmedRefund = transaction.revocationDate != nil
            && hasDirectOwnership
        if isConfirmedRefund || !hasDirectOwnership {
            // Close paid acquisition in this transaction handler's synchronous
            // prefix. There must be no `await` between recognizing the verified
            // loss and invalidating every lease issued by the prior generation.
            let localStatesBeforeLoss = beginProvisionalEntitlementLoss(for: role)
            let provisionalRevision = entitlementStateRevision
            if !hasDirectOwnership {
                Log.ContentPack.info(
                    "Treating non-purchased StoreKit ownership as ineligible for direct ArkFile access"
                )
                publishOwnership(.ineligibleFamilyShared)
            } else {
                publishOwnership(.checking)
            }
            await handleEntitlementLoss(
                transaction: transaction,
                role: role,
                includesIneligibleFamilyOwnership: !hasDirectOwnership,
                isConfirmedRefund: isConfirmedRefund,
                localStatesBeforeLoss: localStatesBeforeLoss,
                provisionalRevision: provisionalRevision
            )
            return
        }
        do {
            // This verified transaction is newer than any StoreKit snapshot
            // already in flight, even when an upgrade still needs its matching
            // Essentials proof before an ownership tier can be published.
            invalidateOwnershipSnapshotReads()
            let updateProof = ArkFileStoreKitContentAccessProof(
                productID: transaction.productID,
                signedTransactionInfo: result.jwsRepresentation,
                role: role
            )
            let currentProofs = try await currentStoreKitContentAccessProofs()
                .filter { $0.productID != transaction.productID }
            let combinedProofs = [updateProof] + currentProofs
            publishOwnership(ArkFileStoreKitEntitlementSnapshot(proofs: combinedProofs))
            guard let plan = ArkFileStoreKitContentAccessRequestPlan.make(
                from: combinedProofs
            ) else {
                Log.ContentPack.info(
                    "Waiting for the current Essentials entitlement before applying the Complete upgrade transaction"
                )
                // Finishing a non-consumable update removes it only from the
                // unfinished queue, not currentEntitlements. A later Essentials
                // purchase or foreground reconciliation can still combine it.
                await transaction.finish()
                return
            }
            _ = try await mintContentAccessToken(
                plan: plan,
                transactionToFinish: transaction,
                notifyAccessMinted: true,
                requiredTier: plan.requestedTier
            )
        } catch {
            Log.ContentPack.error(
                "Unable to mint iOS content access from StoreKit transaction update: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleEntitlementLoss(
        transaction: Transaction,
        role: ArkFileStoreKitProductRole,
        includesIneligibleFamilyOwnership: Bool,
        isConfirmedRefund: Bool,
        localStatesBeforeLoss: [ArkFileIOSContentAccessState],
        provisionalRevision: UInt64
    ) async {
        let remainingProofs: [ArkFileStoreKitContentAccessProof]
        do {
            remainingProofs = try await currentStoreKitContentAccessProofs()
        } catch {
            // A newer entitlement event superseded this StoreKit read. Keep the
            // newer ownership state and service whichever revocation state won.
            performEntitlementLossSideEffects()
            await transaction.finish()
            return
        }
        guard entitlementStateRevision == provisionalRevision else {
            // A newer restore, mint, or entitlement update superseded this
            // snapshot while StoreKit was being read. Reconcile cleanup against
            // the state that actually won so a provisional gate never becomes
            // an unserviced revocation.
            performEntitlementLossSideEffects()
            await transaction.finish()
            return
        }
        publishOwnership(Self.ownershipAfterLoss(
            directProofs: remainingProofs,
            affectedRoles: [role],
            localStates: localStatesBeforeLoss,
            includesIneligibleFamilyOwnership: includesIneligibleFamilyOwnership,
            configuration: productConfiguration
        ))
        currentStoreKitProofTier = ArkFileStoreKitContentAccessRequestPlan.make(
            from: remainingProofs
        )?.requestedTier
        hasCurrentStoreKitProof = currentStoreKitProofTier != nil
        if isConfirmedRefund,
           remainingProofs.contains(where: { $0.role == role }) {
            // StoreKit is simultaneously presenting an active proof for the
            // refunded SKU. Revalidate it with the backend before reopening
            // acquisition.
            if let activePlan = ArkFileStoreKitContentAccessRequestPlan.make(
                from: remainingProofs
            ) {
                do {
                    _ = try await mintContentAccessToken(
                        plan: activePlan,
                        notifyAccessMinted: false,
                        requiredTier: activePlan.requestedTier
                    )
                } catch {
                    Log.ContentPack.info(
                        "Preserving installed reads while active StoreKit proof conflicts with confirmed refund evidence"
                    )
                }
            }
            await transaction.finish()
            return
        }
        let finalOutcome = ownershipLossOutcome(
            directProofs: remainingProofs,
            affectedRoles: [role],
            localStates: localStatesBeforeLoss
        )
        commitEntitlementState(
            liteRevoked: finalOutcome.revokeLite,
            completeRevoked: finalOutcome.revokeComplete,
            invalidateGeneration: false
        )
        let finalRevision = entitlementStateRevision
        performEntitlementLossSideEffects()

        guard entitlementStateRevision == finalRevision else {
            await transaction.finish()
            return
        }

        if let remainingPlan = ArkFileStoreKitContentAccessRequestPlan.make(from: remainingProofs) {
            do {
                _ = try await mintContentAccessToken(
                    plan: remainingPlan,
                    notifyAccessMinted: false,
                    requiredTier: remainingPlan.requestedTier
                )
            } catch {
                // Acquisition already reflects the verified loss. A later
                // foreground reconciliation can refresh any surviving tier.
                Log.ContentPack.error(
                    "Unable to refresh surviving StoreKit access after entitlement loss: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await transaction.finish()
    }

    /// Applies exact structured refund evidence returned by ArkFile's own
    /// StoreKit/content endpoints. Acquisition closes immediately while
    /// verified installed content remains readable.
    @discardableResult
    func applyConfirmedRefund(
        productIDs: [String],
        revalidating tier: ArkFileContentTier? = nil,
        allowingCellularDownload: Bool = false,
        cancelCurrentInstallTask: Bool = false
    ) async -> ArkFileConfirmedRefundRecovery? {
        let exactProductIDs = Set(productIDs)
        let affectedRoles = Set(exactProductIDs.compactMap {
            productConfiguration.role(for: $0)
        })
        guard !affectedRoles.isEmpty,
              affectedRoles.count == exactProductIDs.count else {
            return nil
        }

        let localStatesBeforeLoss = contentAccessStore.accessStates().values
            .filter { !$0.isRevoked }
        var provisionalOutcome = ArkFileStoreKitRevocationOutcome(
            revokeLite: false,
            revokeComplete: false
        )
        for role in affectedRoles {
            let roleOutcome = Self.provisionalRevocationOutcome(for: role)
            provisionalOutcome = ArkFileStoreKitRevocationOutcome(
                revokeLite: provisionalOutcome.revokeLite || roleOutcome.revokeLite,
                revokeComplete: provisionalOutcome.revokeComplete || roleOutcome.revokeComplete
            )
        }
        publishOwnership(.checking)
        commitEntitlementState(
            liteRevoked: provisionalOutcome.revokeLite,
            completeRevoked: provisionalOutcome.revokeComplete,
            persistentlyRevokedTiers: Self.cachedTiersAffectedByLoss(
                accessStates: localStatesBeforeLoss,
                affectedRoles: affectedRoles,
                configuration: productConfiguration
            )
        )
        let provisionalRevision = entitlementStateRevision
        // A structured response can arrive inside the install task that must
        // finish the bounded StoreKit/backend reconciliation below. Foreground
        // latest-transaction reconciliation opts into cancelling a separate
        // active install; in-band callers stop only background transfer work.
        performEntitlementLossSideEffects(
            cancelCurrentInstallTask: cancelCurrentInstallTask
        )

        let snapshot: ArkFileStoreKitEntitlementSnapshot
        do {
            snapshot = try await currentStoreKitEntitlementSnapshot()
        } catch {
            Log.ContentPack.info(
                "Preserving installed reads because confirmed refund reconciliation was superseded"
            )
            return nil
        }
        guard entitlementStateRevision == provisionalRevision else {
            return nil
        }

        let hasConflictingActiveProof = snapshot.proofs.contains {
            exactProductIDs.contains($0.productID)
        }
        if let tier,
           let activePlan = ArkFileStoreKitContentAccessRequestPlan.make(
               from: snapshot.proofs
            ),
           Self.tier(activePlan.requestedTier, satisfies: tier) {
            do {
                let authorization = try await mintContentAccessToken(
                    plan: activePlan,
                    notifyAccessMinted: false,
                    requiredTier: tier
                ).allowingCellularDownload(allowingCellularDownload)
                return ArkFileConfirmedRefundRecovery(
                    authorization: authorization,
                    acquisitionLease: try makeAcquisitionLease(for: tier)
                )
            } catch ArkFileContentError.confirmedStoreKitRefund {
                // `mintContentAccessToken` has already reconciled that exact
                // structured response without another mint attempt.
                return nil
            } catch {
                Log.ContentPack.info(
                    "Unable to revalidate an active StoreKit proof after a confirmed-refund response: \(error.localizedDescription, privacy: .public)"
                )
                if hasConflictingActiveProof {
                    return nil
                }
            }
        }

        guard !hasConflictingActiveProof else {
            // A direct active proof for the same SKU conflicts with the server
            // signal. Keep new acquisition closed, but never turn that conflict
            // into a durable offline read lock.
            return nil
        }

        let remainingProofs = snapshot.proofs
        publishOwnership(Self.ownershipAfterLoss(
            directProofs: remainingProofs,
            affectedRoles: affectedRoles,
            localStates: localStatesBeforeLoss,
            includesIneligibleFamilyOwnership: !snapshot.ineligibleOwnershipRoles.isEmpty,
            configuration: productConfiguration
        ))
        currentStoreKitProofTier = ArkFileStoreKitContentAccessRequestPlan.make(
            from: remainingProofs
        )?.requestedTier
        hasCurrentStoreKitProof = currentStoreKitProofTier != nil
        let finalOutcome = ownershipLossOutcome(
            directProofs: remainingProofs,
            affectedRoles: affectedRoles,
            localStates: localStatesBeforeLoss
        )
        commitEntitlementState(
            liteRevoked: finalOutcome.revokeLite,
            completeRevoked: finalOutcome.revokeComplete,
            invalidateGeneration: false
        )
        performEntitlementLossSideEffects()

        return nil
    }

    /// Applies the restrictive half of a verified entitlement-loss transition
    /// synchronously. Transaction handling calls this before its first StoreKit
    /// suspension so an active transfer cannot outrun the positive loss signal.
    @discardableResult
    func beginProvisionalEntitlementLoss(
        for role: ArkFileStoreKitProductRole
    ) -> [ArkFileIOSContentAccessState] {
        let localStates = contentAccessStore.accessStates().values.filter {
            !$0.isRevoked
        }
        let provisionalOutcome = Self.provisionalRevocationOutcome(for: role)
        let affectedCachedTiers = Self.cachedTiersAffectedByLoss(
            accessStates: localStates,
            affectedRoles: [role],
            configuration: productConfiguration
        )
        commitEntitlementState(
            liteRevoked: provisionalOutcome.revokeLite,
            completeRevoked: provisionalOutcome.revokeComplete,
            persistentlyRevokedTiers: affectedCachedTiers
        )
        performEntitlementLossSideEffects()
        return localStates
    }

    nonisolated static func provisionalRevocationOutcome(
        for role: ArkFileStoreKitProductRole
    ) -> ArkFileStoreKitRevocationOutcome {
        switch role {
        case .completeUpgrade:
            ArkFileStoreKitRevocationOutcome(revokeLite: false, revokeComplete: true)
        case .lite, .complete:
            ArkFileStoreKitRevocationOutcome(revokeLite: true, revokeComplete: true)
        }
    }

    nonisolated static func cachedTiersAffectedByLoss(
        accessStates: [ArkFileIOSContentAccessState],
        affectedRoles: Set<ArkFileStoreKitProductRole>,
        configuration: ArkFileStoreKitProductConfiguration
    ) -> Set<ArkFileContentTier> {
        Set(accessStates.compactMap { state in
            guard !state.isRevoked,
                  let tier = state.contentTier,
                  let stateRole = configuration.role(for: state.productID) else {
                return nil
            }
            let dependsOnLostRole: Bool
            switch stateRole {
            case .lite:
                dependsOnLostRole = affectedRoles.contains(.lite)
            case .complete:
                dependsOnLostRole = affectedRoles.contains(.complete)
            case .completeUpgrade:
                // An upgrade-backed Complete token depends on both the upgrade
                // transaction and its matching Essentials transaction.
                dependsOnLostRole = affectedRoles.contains(.completeUpgrade)
                    || affectedRoles.contains(.lite)
            }
            return dependsOnLostRole ? tier : nil
        })
    }

    /// Resolves ownership after positive loss evidence without treating an
    /// ordinary miss for every *other* product as authoritative. For example,
    /// refunding Complete outright must not erase an independently verified,
    /// expired Essentials ownership record.
    nonisolated static func ownershipAfterLoss(
        directProofs: [ArkFileStoreKitContentAccessProof],
        affectedRoles: Set<ArkFileStoreKitProductRole>,
        localStates: [ArkFileIOSContentAccessState],
        includesIneligibleFamilyOwnership: Bool,
        configuration: ArkFileStoreKitProductConfiguration
    ) -> ArkFileStoreKitOwnershipState {
        if let plan = ArkFileStoreKitContentAccessRequestPlan.make(
            from: directProofs
        ) {
            return plan.requestedTier == .complete ? .complete : .essentials
        }

        let survivingLocalStates = localStates.filter { state in
            guard !state.isRevoked,
                  let stateRole = configuration.role(for: state.productID) else {
                return false
            }
            switch stateRole {
            case .lite:
                return !affectedRoles.contains(.lite)
            case .complete:
                return !affectedRoles.contains(.complete)
            case .completeUpgrade:
                return !affectedRoles.contains(.completeUpgrade)
                    && !affectedRoles.contains(.lite)
            }
        }
        if let lastKnown = lastKnownVerifiedOwnership(
            from: survivingLocalStates
        ) {
            return lastKnown
        }

        // An orphaned direct proof or an upgrade-only loss does not establish
        // that Essentials is absent. Keep purchase routing closed until Restore
        // produces an authoritative account-wide answer.
        if !directProofs.isEmpty || affectedRoles == [.completeUpgrade] {
            return .checking
        }
        if includesIneligibleFamilyOwnership {
            return .ineligibleFamilyShared
        }
        return .notOwned
    }

    private func invalidateCompleteContentAccessAfterRevocation() async {
        commitEntitlementState(liteRevoked: nil, completeRevoked: true)
        performEntitlementLossSideEffects()
    }

    private func markAccessRevokedIfNeeded(authoritativeAbsence: Bool = false) async {
        // Transaction.currentEntitlements is a local StoreKit snapshot. Its absence is
        // not proof of a refund merely because NWPath reports a route: captive portals,
        // App Store outages, account refreshes, and transient StoreKit cache misses can
        // all produce the same result. Preserve already-installed offline content unless
        // Apple sends a verified revocation update or a user-requested AppStore.sync()
        // completes successfully and still returns no proof.
        guard authoritativeAbsence else {
            Log.ContentPack.info(
                "Preserving installed access because missing StoreKit proofs were not authoritatively synchronized"
            )
            return
        }
        // Unlike an ordinary cache miss, a completed user-requested sync with
        // no direct proof is authoritative for merchandising and purchase
        // routing even when this installation has no paid files to revoke.
        publishOwnership(.notOwned)
        let cachedAccessStates = contentAccessStore.accessStates()
        let liteAccessState = cachedAccessStates[ArkFileContentTier.lite.rawValue]
        // A Complete token proves Essentials entitlement too, so Complete-outright
        // owners (who never hold a lite keychain entry) count as cached owners.
        let completeAccessState = cachedAccessStates[ArkFileContentTier.complete.rawValue]
        let hasCachedAccessState = liteAccessState != nil || completeAccessState != nil
        let hasManagedContent = ArkFileContentPackInstaller.managedContentRootWithAnyReadableContentIfAvailable() != nil
        let hasDeveloperToken = Brand.hasDeveloperContentAuthToken
        guard Self.hasPaidAccessEvidenceToRevoke(
            hasCachedAccessState: hasCachedAccessState,
            hasManagedContent: hasManagedContent,
            hasDeveloperToken: hasDeveloperToken
        ) else {
            return
        }
        commitEntitlementState(liteRevoked: true, completeRevoked: true)
        performEntitlementLossSideEffects()
    }

    /// Applies commerce flags and persisted acquisition state without
    /// suspension. Installed-content reads remain independent.
    private func commitEntitlementState(
        liteRevoked: Bool?,
        completeRevoked: Bool?,
        invalidateGeneration: Bool = true,
        persistentlyRevokedTiers: Set<ArkFileContentTier>? = nil
    ) {
        if invalidateGeneration {
            invalidateEntitlementGeneration()
        }
        entitlementStateRevision &+= 1

        let revokesLite = liteRevoked == true
        let revokesComplete = completeRevoked == true
        let tiersToPersist = persistentlyRevokedTiers ?? Set(
            [
                revokesLite ? ArkFileContentTier.lite : nil,
                revokesComplete ? ArkFileContentTier.complete : nil
            ].compactMap { $0 }
        )
        contentAccessStore.markRevoked(tiers: tiersToPersist, now: now())

        // Apply restrictive transitions before any surviving-tier clears. The
        // acquisition state changes immediately, but installed file reads do
        // not depend on this commerce transition.
        if revokesLite {
            let newlyRevoked = !isLiteAccessRevoked
            isLiteAccessRevoked = true
            if newlyRevoked {
                Log.ContentPack.info("StoreKit revocation detected for ArkFile Essentials")
            }
        }
        if revokesComplete {
            let newlyRevoked = !isCompleteAccessRevoked
            isCompleteAccessRevoked = true
            if newlyRevoked {
                Log.ContentPack.info("StoreKit revocation detected for ArkFile Complete")
            }
        }

        if completeRevoked == false {
            clearCompleteRevocationAfterConfirmedAccess()
        }
        if liteRevoked == false {
            clearLiteRevocationAfterConfirmedAccess()
        }

        refreshAuthorizationReadinessFromCache()
        if revokesLite || revokesComplete {
            lastAccessMintedEvent = nil
            pendingPurchaseStore.clear()
        }
    }

    private func performEntitlementLossSideEffects(
        cancelCurrentInstallTask: Bool = true
    ) {
        let current = currentRevocationState
        let transition = ArkFileStoreKitRevocationOutcome(
            revokeLite: current.revokeLite && !servicedRevocationState.revokeLite,
            revokeComplete: current.revokeComplete && !servicedRevocationState.revokeComplete
        )
        guard transition.revokeLite || transition.revokeComplete else {
            return
        }
        // Claim the transition before suspension so a concurrent restore or
        // StoreKit update cannot start duplicate cleanup for the same gate.
        servicedRevocationState = ArkFileStoreKitRevocationOutcome(
            revokeLite: servicedRevocationState.revokeLite || transition.revokeLite,
            revokeComplete: servicedRevocationState.revokeComplete || transition.revokeComplete
        )
        if transition.revokeLite {
            stopAcquisitionAfterEntitlementLoss(.lite, cancelCurrentInstallTask)
        } else {
            stopAcquisitionAfterEntitlementLoss(.complete, cancelCurrentInstallTask)
        }
        // Acquisition loss does not close readers or alter installed content.
    }

    private var currentRevocationState: ArkFileStoreKitRevocationOutcome {
        ArkFileStoreKitRevocationOutcome(
            revokeLite: isLiteAccessRevoked,
            revokeComplete: isCompleteAccessRevoked
        )
    }

    private func reconcileIneligibleOwnership(
        using directProofs: [ArkFileStoreKitContentAccessProof],
        ineligibleRoles: Set<ArkFileStoreKitProductRole>
    ) async {
        let localStates = contentAccessStore.accessStates().values.filter {
            !$0.isRevoked
        }
        let outcome = ownershipLossOutcome(
            directProofs: directProofs,
            affectedRoles: ineligibleRoles,
            localStates: localStates
        )
        guard outcome != currentRevocationState else {
            return
        }
        commitEntitlementState(
            liteRevoked: outcome.revokeLite,
            completeRevoked: outcome.revokeComplete,
            persistentlyRevokedTiers: Self.cachedTiersAffectedByLoss(
                accessStates: localStates,
                affectedRoles: ineligibleRoles,
                configuration: productConfiguration
            )
        )
        performEntitlementLossSideEffects()
    }

    private func ownershipLossOutcome(
        directProofs: [ArkFileStoreKitContentAccessProof],
        affectedRoles: Set<ArkFileStoreKitProductRole>,
        localStates: [ArkFileIOSContentAccessState]? = nil
    ) -> ArkFileStoreKitRevocationOutcome {
        // Missing direct proofs in an ordinary currentEntitlements snapshot are
        // still non-authoritative. Preserve locally verified grants that are not
        // attributable to the refunded or ineligible ownership role.
        let verifiedLocalStates = localStates
            ?? contentAccessStore.accessStates().values.filter { !$0.isRevoked }
        let hasIndependentLite = verifiedLocalStates.contains { state in
            state.contentTier == .lite
                && productConfiguration.role(for: state.productID) == .lite
                && !affectedRoles.contains(.lite)
        }
        let hasIndependentCompleteOutright = verifiedLocalStates.contains { state in
            state.contentTier == .complete
                && productConfiguration.role(for: state.productID) == .complete
                && !affectedRoles.contains(.complete)
        }
        let hasIndependentUpgrade = verifiedLocalStates.contains { state in
            state.contentTier == .complete
                && productConfiguration.role(for: state.productID) == .completeUpgrade
                && !affectedRoles.contains(.completeUpgrade)
        }
        return Self.ownershipLossOutcome(
            affectedRoles: affectedRoles,
            directProofs: directProofs,
            hasIndependentLocalLite: hasIndependentLite,
            hasIndependentLocalCompleteOutright: hasIndependentCompleteOutright,
            hasIndependentLocalUpgrade: hasIndependentUpgrade
        )
    }

    nonisolated static func ownershipLossOutcome(
        affectedRoles: Set<ArkFileStoreKitProductRole>,
        directProofs: [ArkFileStoreKitContentAccessProof],
        hasIndependentLocalLite: Bool,
        hasIndependentLocalCompleteOutright: Bool,
        hasIndependentLocalUpgrade: Bool
    ) -> ArkFileStoreKitRevocationOutcome {
        var revokeLite = false
        var revokeComplete = false
        for role in affectedRoles {
            let affected = provisionalRevocationOutcome(for: role)
            revokeLite = revokeLite || affected.revokeLite
            revokeComplete = revokeComplete || affected.revokeComplete
        }

        // A current direct proof always wins over an unrelated loss event.
        if let directPlan = ArkFileStoreKitContentAccessRequestPlan.make(from: directProofs) {
            revokeLite = false
            if directPlan.requestedTier == .complete {
                revokeComplete = false
            }
        }

        let hasIndependentComplete = hasIndependentLocalCompleteOutright
            || (hasIndependentLocalUpgrade && hasIndependentLocalLite)
        if hasIndependentComplete {
            revokeLite = false
            revokeComplete = false
        } else if hasIndependentLocalLite {
            revokeLite = false
        }
        return ArkFileStoreKitRevocationOutcome(
            revokeLite: revokeLite,
            revokeComplete: revokeComplete
        )
    }

    private func clearLiteRevocationAfterConfirmedAccess() {
        let changed = isLiteAccessRevoked
        if isLiteAccessRevoked {
            isLiteAccessRevoked = false
        }
        if changed {
            entitlementStateRevision &+= 1
            servicedRevocationState = ArkFileStoreKitRevocationOutcome(
                revokeLite: false,
                revokeComplete: servicedRevocationState.revokeComplete
            )
        }
    }

    private func clearCompleteRevocationAfterConfirmedAccess() {
        let changed = isCompleteAccessRevoked
        if isCompleteAccessRevoked {
            isCompleteAccessRevoked = false
        }
        if changed {
            entitlementStateRevision &+= 1
            servicedRevocationState = ArkFileStoreKitRevocationOutcome(
                revokeLite: servicedRevocationState.revokeLite,
                revokeComplete: false
            )
        }
    }

    nonisolated static func lastKnownVerifiedOwnership(
        from accessStates: [ArkFileIOSContentAccessState]
    ) -> ArkFileStoreKitOwnershipState? {
        let nonRevoked = accessStates.filter { !$0.isRevoked }
        if nonRevoked.contains(where: { $0.contentTier == .complete }) {
            return .complete
        }
        if nonRevoked.contains(where: { $0.contentTier == .lite }) {
            return .essentials
        }
        return nil
    }

    nonisolated static func requiresOwnershipVerificationBeforePurchase(
        _ ownership: ArkFileStoreKitOwnershipState
    ) -> Bool {
        switch ownership {
        case .checking, .essentials, .complete:
            true
        case .notOwned, .ineligibleFamilyShared:
            false
        }
    }

    /// Allows the ordinary resolved-new-customer path plus the one safe owned
    /// transition: an Essentials owner requesting Complete. `purchaseComplete`
    /// immediately re-reads current direct proofs and only selects the upgrade
    /// SKU when that live snapshot still contains Essentials. Empty or orphaned
    /// proof sets therefore remain fail-closed.
    nonisolated static func canBeginProductPurchase(
        requestedTier: ArkFileContentTier,
        ownership: ArkFileStoreKitOwnershipState
    ) -> Bool {
        if requestedTier == .complete, ownership == .essentials {
            return true
        }
        return !requiresOwnershipVerificationBeforePurchase(ownership)
    }

    nonisolated static func purchaseLinkingError(
        afterVerifiedPurchase error: Error
    ) -> ArkFileContentError {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return ArkFileContentError.purchaseLinkingFailed(message)
    }

    private nonisolated static func tier(
        _ granted: ArkFileContentTier,
        satisfies required: ArkFileContentTier
    ) -> Bool {
        switch (granted, required) {
        case (_, .standard):
            return false
        case (.complete, .complete), (.complete, .lite), (.lite, .lite):
            return true
        case (.lite, .complete), (.standard, _):
            return false
        }
    }

    nonisolated static func hasPaidAccessEvidenceToRevoke(
        hasCachedAccessState: Bool,
        hasManagedContent: Bool,
        hasDeveloperToken: Bool
    ) -> Bool {
        !hasDeveloperToken && (hasCachedAccessState || hasManagedContent)
    }

    private static func clearLegacyPendingStoreKitPurchaseOnce(
        _ store: ArkFilePendingStoreKitPurchaseStore
    ) {
        let key = "arkfile.storekit.split-cleared-pending.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        store.clear()
        UserDefaults.standard.set(true, forKey: key)
    }
}

private enum ArkFilePendingStoreKitKeychain {
    private static let service = "app.arkfile.ios"

    static func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func set(data: Data, account: String) -> Bool {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
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
