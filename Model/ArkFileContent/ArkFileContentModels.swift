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

enum ArkFileContentTier: String, Codable, Hashable, Sendable {
    case lite
    case standard
    case complete

    var isIOSInstallable: Bool {
        switch self {
        case .lite, .complete:
            true
        case .standard:
            false
        }
    }

    static func iOSInstallableTier(named value: String?) -> ArkFileContentTier? {
        guard let value,
              let tier = ArkFileContentTier(rawValue: value.lowercased()),
              tier.isIOSInstallable else {
            return nil
        }
        return tier
    }

    static func isIOSInstallableTier(_ value: String?) -> Bool {
        iOSInstallableTier(named: value) != nil
    }
}

enum ArkFileContentPackDisplayName {
    static func name(for tier: ArkFileContentTier?) -> String {
        tier == .complete ? "Complete" : "Essentials"
    }
}

/// Authorization and transfer are deliberately separate decisions. Restoring
/// an App Store entitlement must never begin a multi-gigabyte download without
/// a subsequent, explicit content choice.
enum ArkFileContentAuthorizationMode: Equatable, Sendable {
    case purchaseOrCurrentEntitlement
    case purchaseOrCurrentEntitlementWithoutDownload
    case restoreEntitlement
    case restoreHighestOwnedEntitlement
    case currentEntitlementOnly

    var startsDownloadAfterAuthorization: Bool {
        switch self {
        case .purchaseOrCurrentEntitlementWithoutDownload,
             .restoreEntitlement,
             .restoreHighestOwnedEntitlement:
            false
        case .purchaseOrCurrentEntitlement, .currentEntitlementOnly:
            true
        }
    }

    var isRestore: Bool {
        switch self {
        case .restoreEntitlement, .restoreHighestOwnedEntitlement:
            true
        case .purchaseOrCurrentEntitlement,
             .purchaseOrCurrentEntitlementWithoutDownload,
             .currentEntitlementOnly:
            false
        }
    }

    /// Restore recovers ownership only. It must not initialize, save, or alter
    /// the user's per-tier download selection.
    var appliesStoredDownloadSelection: Bool {
        switch self {
        case .purchaseOrCurrentEntitlement, .currentEntitlementOnly:
            true
        case .purchaseOrCurrentEntitlementWithoutDownload,
             .restoreEntitlement,
             .restoreHighestOwnedEntitlement:
            false
        }
    }
}

enum ArkFileContentEntitlementOutcomeAction: Equatable, Sendable {
    case restored
    case purchased
    case accessConfirmed
    case pendingApproval
}

struct ArkFileContentRestoreOutcome: Equatable, Sendable {
    let tier: ArkFileContentTier
    let requestedTier: ArkFileContentTier
    let action: ArkFileContentEntitlementOutcomeAction

    init(
        tier: ArkFileContentTier,
        requestedTier: ArkFileContentTier? = nil,
        action: ArkFileContentEntitlementOutcomeAction = .restored
    ) {
        self.tier = tier
        self.requestedTier = requestedTier ?? tier
        self.action = action
    }

    var statusMessage: String {
        let packName = ArkFileContentPackDisplayName.name(for: tier)
        return switch action {
        case .restored:
            "\(packName) restored. No content was downloaded."
        case .purchased:
            "\(packName) purchased. No content was downloaded."
        case .accessConfirmed:
            "\(packName) access confirmed. No content was downloaded."
        case .pendingApproval:
            "\(packName) purchase is pending approval. No content was downloaded."
        }
    }
}

enum ArkFileContentInstallPhase: String, Codable, Sendable {
    case idle
    case preparing
    case purchasing
    case readyToDownload
    case downloading
    case verifying
    case installing
    case installed
    case failed

    var isBusy: Bool {
        switch self {
        case .preparing, .purchasing, .downloading, .verifying, .installing:
            true
        case .idle, .readyToDownload, .installed, .failed:
            false
        }
    }
}

struct ArkFileContentInstallState: Codable, Equatable, Sendable {
    /// Version 1 means `completedBytes`/`totalBytes` describe network-transfer
    /// progress only. Older builds mixed already-installed bytes into those
    /// fields, so a missing version is intentionally treated as legacy state.
    var transferAccountingVersion: Int?
    var tier: ArkFileContentTier?
    var phase: ArkFileContentInstallPhase
    var completedBytes: Int64
    var totalBytes: Int64
    /// Total size of the user's selected manifest, including files that were
    /// already present and therefore do not need another network transfer.
    var selectedBytes: Int64?
    /// Selected bytes that checksum verification found locally before this
    /// install operation began.
    var locallyVerifiedBytes: Int64?
    var currentFile: String
    var activePath: String
    var installedAt: Date?
    var errorMessage: String?
    /// Canonical lowercased catalog paths the user chose NOT to download.
    /// Empty/nil means the full pack; storing exclusions (not selections) keeps
    /// future catalog additions included by default.
    var excludedItemPaths: Set<String>?
    var completedFiles: Int?
    var totalFiles: Int?
    /// Local checksum-inspection progress. These are separate from
    /// `completedFiles`/`totalFiles`, which describe network transfers.
    var checkedFiles: Int?
    var totalSelectedFiles: Int?
    /// When non-nil, this is the persisted, operation-scoped set of catalog
    /// anchors the next/current transfer may download. It is intentionally
    /// separate from `excludedItemPaths`, which remains the user's durable
    /// library preference. Keeping this request in the install state prevents
    /// a retry or relaunch from widening a one-title download into the whole
    /// saved selection.
    var addedItemPaths: Set<String>?
    var addedItemNames: [String]?
    /// Tier associated with the explicit request. This cannot reuse `tier`:
    /// while an Essentials library is installed, a pending Complete selection
    /// must not replace the valid installed presentation before purchase.
    var activeDownloadRequestTier: ArkFileContentTier?
    /// Explicitly requested map detail and places. Nil in older states; book
    /// downloads never infer this choice from pack ownership.
    var includesMapFoundation: Bool?
    /// Catalog anchors the current durable activation commit is expected to
    /// contain. Nil is a legacy state and falls back to the saved selection;
    /// a non-nil set is independent of what the user chooses to download next.
    var installedCoverageItemPaths: Set<String>?

    init(
        transferAccountingVersion: Int? = 1,
        tier: ArkFileContentTier?,
        phase: ArkFileContentInstallPhase,
        completedBytes: Int64,
        totalBytes: Int64,
        selectedBytes: Int64? = nil,
        locallyVerifiedBytes: Int64? = nil,
        currentFile: String,
        activePath: String,
        installedAt: Date?,
        errorMessage: String?,
        excludedItemPaths: Set<String>? = nil,
        completedFiles: Int? = nil,
        totalFiles: Int? = nil,
        checkedFiles: Int? = nil,
        totalSelectedFiles: Int? = nil,
        addedItemPaths: Set<String>? = nil,
        addedItemNames: [String]? = nil,
        activeDownloadRequestTier: ArkFileContentTier? = nil,
        includesMapFoundation: Bool? = nil,
        installedCoverageItemPaths: Set<String>? = nil
    ) {
        self.transferAccountingVersion = transferAccountingVersion
        self.tier = tier
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.selectedBytes = selectedBytes
        self.locallyVerifiedBytes = locallyVerifiedBytes
        self.currentFile = currentFile
        self.activePath = activePath
        self.installedAt = installedAt
        self.errorMessage = errorMessage
        self.excludedItemPaths = excludedItemPaths
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.checkedFiles = checkedFiles
        self.totalSelectedFiles = totalSelectedFiles
        self.addedItemPaths = addedItemPaths
        self.addedItemNames = addedItemNames
        self.activeDownloadRequestTier = activeDownloadRequestTier
        self.includesMapFoundation = includesMapFoundation
        self.installedCoverageItemPaths = installedCoverageItemPaths
    }

    static let idle = ArkFileContentInstallState(
        transferAccountingVersion: 1,
        tier: nil,
        phase: .idle,
        completedBytes: 0,
        totalBytes: 0,
        currentFile: "",
        activePath: "",
        installedAt: nil,
        errorMessage: nil,
        excludedItemPaths: nil,
        completedFiles: nil,
        totalFiles: nil,
        checkedFiles: nil,
        totalSelectedFiles: nil
    )

    var normalizedExcludedItemPaths: Set<String> {
        Set((excludedItemPaths ?? []).map { $0.lowercased() })
    }

    var normalizedAddedItemPaths: Set<String> {
        Set((addedItemPaths ?? []).map(ArkFileContentCanonicalPath.key))
    }

    var hasExplicitDownloadRequest: Bool {
        addedItemPaths != nil
    }

    var hasPendingExplicitDownloadRequest: Bool {
        !normalizedAddedItemPaths.isEmpty || includesMapFoundation == true
    }

    var effectiveActiveDownloadRequestTier: ArkFileContentTier? {
        activeDownloadRequestTier ?? (hasExplicitDownloadRequest ? tier : nil)
    }

    var normalizedInstalledCoverageItemPaths: Set<String>? {
        installedCoverageItemPaths.map {
            Set($0.map(ArkFileContentCanonicalPath.key))
        }
    }

    var nonEmptyAddedItemNames: [String] {
        (addedItemNames ?? []).compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var progressFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var hasResumableDownloadProgress: Bool {
        phase != .installed && completedBytes > 0
    }

    var usesNetworkTransferAccounting: Bool {
        transferAccountingVersion == 1
    }
}

struct ArkFileContentAuthorization: Sendable {
    let bearerToken: String?
    let storeKitTransactionJWS: String?
    let expiresAt: Date?
    let allowsCellularDownload: Bool

    init(
        bearerToken: String?,
        storeKitTransactionJWS: String?,
        expiresAt: Date? = nil,
        allowsCellularDownload: Bool = false
    ) {
        self.bearerToken = bearerToken
        self.storeKitTransactionJWS = storeKitTransactionJWS
        self.expiresAt = expiresAt
        self.allowsCellularDownload = allowsCellularDownload
    }

    static func developerToken(_ token: String, allowsCellularDownload: Bool = false) -> ArkFileContentAuthorization {
        ArkFileContentAuthorization(
            bearerToken: token,
            storeKitTransactionJWS: nil,
            allowsCellularDownload: allowsCellularDownload
        )
    }

    static func accountToken(
        _ token: String,
        storeKitTransactionJWS: String? = nil,
        allowsCellularDownload: Bool = false
    ) -> ArkFileContentAuthorization {
        ArkFileContentAuthorization(
            bearerToken: token,
            storeKitTransactionJWS: storeKitTransactionJWS,
            allowsCellularDownload: allowsCellularDownload
        )
    }

    static func iOSContentToken(
        _ token: String,
        expiresAt: Date?,
        storeKitTransactionJWS: String? = nil,
        allowsCellularDownload: Bool = false
    ) -> ArkFileContentAuthorization {
        ArkFileContentAuthorization(
            bearerToken: token,
            storeKitTransactionJWS: storeKitTransactionJWS,
            expiresAt: expiresAt,
            allowsCellularDownload: allowsCellularDownload
        )
    }

    static func storeKitTransaction(_ jws: String) -> ArkFileContentAuthorization {
        ArkFileContentAuthorization(bearerToken: nil, storeKitTransactionJWS: jws)
    }

    var headers: [String: String] {
        var values: [String: String] = [:]
        if let bearerToken, !bearerToken.isEmpty {
            values["Authorization"] = "Bearer \(bearerToken)"
        }
        return values
    }

    func allowingCellularDownload(_ allowed: Bool) -> ArkFileContentAuthorization {
        ArkFileContentAuthorization(
            bearerToken: bearerToken,
            storeKitTransactionJWS: storeKitTransactionJWS,
            expiresAt: expiresAt,
            allowsCellularDownload: allowed
        )
    }
}

struct ArkFileDownloadInfo: Decodable, Sendable {
    let tier: String?
    let baselineTier: String?
    let deliveryMode: String?
    let installMode: String?
    let manifestObjectKey: String?
    let fileName: String?
    let objectKey: String?
    let url: String?
    let sizeBytes: Int64?
    let sha256: String?
}

struct ArkFilePackageManifest: Codable, Sendable {
    static let maxSupportedContentSchema = 1

    let format: Int?
    let product: String?
    let variant: String?
    let tier: String?
    let baselineTier: String?
    let deliveryMode: String?
    let sourceEdition: String?
    let baselineEdition: String?
    let installMode: String?
    let installedBytes: Int64?
    let filesIncluded: Int?
    let declaredBytesIncluded: Int64?
    let generatedAt: String?
    let files: [Entry]
    let compat: Compat?
    let deletedPaths: [String]?

    init(
        format: Int?,
        tier: String?,
        baselineTier: String?,
        deliveryMode: String?,
        installedBytes: Int64?,
        files: [Entry],
        compat: Compat? = nil,
        deletedPaths: [String]? = nil,
        product: String? = nil,
        variant: String? = nil,
        sourceEdition: String? = nil,
        baselineEdition: String? = nil,
        installMode: String? = nil,
        filesIncluded: Int? = nil,
        declaredBytesIncluded: Int64? = nil,
        generatedAt: String? = nil
    ) {
        self.format = format
        self.product = product
        self.variant = variant
        self.tier = tier
        self.baselineTier = baselineTier
        self.deliveryMode = deliveryMode
        self.sourceEdition = sourceEdition
        self.baselineEdition = baselineEdition
        self.installMode = installMode
        self.installedBytes = installedBytes
        self.filesIncluded = filesIncluded
        self.declaredBytesIncluded = declaredBytesIncluded
        self.generatedAt = generatedAt
        self.files = files
        self.compat = compat
        self.deletedPaths = deletedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case product
        case variant
        case tier
        case baselineTier
        case deliveryMode
        case sourceEdition
        case baselineEdition
        case installMode
        case installedBytes
        case filesIncluded
        case declaredBytesIncluded = "bytesIncluded"
        case generatedAt
        case files
        case compat
        case deletedPaths
    }

    var bytesIncluded: Int64 {
        var total: Int64 = 0
        for entry in files {
            let (next, overflow) = total.addingReportingOverflow(entry.sizeBytes)
            if overflow {
                return entry.sizeBytes >= 0 ? .max : .min
            }
            total = next
        }
        return total
    }

    var hasOfflineVectorMapDetail: Bool {
        files.contains { entry in
            entry.normalizedRelativePath.lowercased() == "maps/detail/north_america.pmtiles"
        }
    }

    func validateForInstall(tier expectedTier: ArkFileContentTier) throws {
        guard expectedTier.isIOSInstallable else {
            throw ArkFileContentError.invalidManifestTier(expectedTier.rawValue)
        }
        if let format, format != 1 {
            throw ArkFileContentError.unsupportedManifestFormat(format)
        }
        if let tier, tier.lowercased() != expectedTier.rawValue {
            throw ArkFileContentError.invalidManifestTier(tier)
        }
        if let deletedPaths, !deletedPaths.isEmpty {
            throw ArkFileContentError.automaticManifestDeletionUnsupported
        }
        try validateCompatibility()
        guard !files.isEmpty else {
            throw ArkFileContentError.emptyContentManifest
        }

        var normalizedPaths = Set<String>()
        var hasZim = false
        var validatedBytes: Int64 = 0
        for entry in files {
            try entry.validate()
            let (nextValidatedBytes, overflow) = validatedBytes
                .addingReportingOverflow(entry.sizeBytes)
            guard !overflow else {
                throw ArkFileContentError.manifestSizeOverflow
            }
            validatedBytes = nextValidatedBytes
            let relativePath = entry.normalizedRelativePath.lowercased()
            guard !ArkFileContentRetirementPolicy.isRetired(relativePath: entry.normalizedRelativePath) else {
                throw ArkFileContentError.retiredManifestFile(entry.normalizedRelativePath)
            }
            guard normalizedPaths.insert(relativePath).inserted else {
                throw ArkFileContentError.duplicateManifestFile(entry.normalizedRelativePath)
            }
            hasZim = hasZim || entry.isZim
        }
        guard hasZim else {
            throw ArkFileContentError.noReadableZims
        }
    }

    func validateForLiteInstall() throws {
        try validateForInstall(tier: .lite)
    }

    private func validateCompatibility() throws {
        guard let compat else { return }
        if let contentSchema = compat.contentSchema,
           contentSchema > Self.maxSupportedContentSchema {
            throw ArkFileContentError.appUpdateRequired(
                "This content pack uses content schema \(contentSchema); this app supports schema \(Self.maxSupportedContentSchema)."
            )
        }
        if let minIOSBuild = compat.minIOSBuild,
           minIOSBuild > Self.currentIOSBuild {
            throw ArkFileContentError.appUpdateRequired(
                "This content pack requires iOS build \(minIOSBuild); this app is build \(Self.currentIOSBuild)."
            )
        }
    }

    private static var currentIOSBuild: Int {
        guard let rawBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return 0
        }
        let numericPrefix = rawBuild.split(separator: ".").first.map(String.init) ?? rawBuild
        return Int(numericPrefix) ?? 0
    }

    struct Compat: Codable, Equatable, Sendable {
        let contentSchema: Int?
        let minDesktopVersion: String?
        let minIOSBuild: Int?

        init(
            contentSchema: Int? = nil,
            minDesktopVersion: String? = nil,
            minIOSBuild: Int? = nil
        ) {
            self.contentSchema = contentSchema
            self.minDesktopVersion = minDesktopVersion
            self.minIOSBuild = minIOSBuild
        }
    }

    struct Entry: Codable, Hashable, Sendable {
        let relativePath: String
        let objectKey: String
        let sizeBytes: Int64
        let sha256: String
        let mode: Int?
        let variantGroup: String?
        let variantLabel: String?
        let variantDefault: Bool?

        init(
            relativePath: String,
            objectKey: String,
            sizeBytes: Int64,
            sha256: String,
            mode: Int? = nil,
            variantGroup: String? = nil,
            variantLabel: String? = nil,
            variantDefault: Bool? = nil
        ) {
            self.relativePath = relativePath
            self.objectKey = objectKey
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
            self.mode = mode
            self.variantGroup = variantGroup
            self.variantLabel = variantLabel
            self.variantDefault = variantDefault
        }

        var normalizedRelativePath: String {
            relativePath
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        var isZim: Bool {
            normalizedRelativePath.lowercased().hasSuffix(".zim")
        }

        func validate() throws {
            let rawPath = relativePath.replacingOccurrences(of: "\\", with: "/")
            let relativePath = normalizedRelativePath
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !relativePath.isEmpty,
                  !rawPath.contains("\0"),
                  !entryContainsUnsafeComponent(components),
                  !objectKey.isEmpty,
                  sizeBytes >= 0,
                  sha256.range(
                    of: "^[A-Fa-f0-9]{64}$",
                    options: .regularExpression
                  ) != nil else {
                throw ArkFileContentError.invalidManifestFile(self.relativePath)
            }
        }

        private func entryContainsUnsafeComponent(_ components: [Substring]) -> Bool {
            components.contains { component in
                component.isEmpty || component == "." || component == ".."
            }
        }
    }
}

struct ArkFilePackageManifestResponse: Decodable {
    let manifest: ArkFilePackageManifest?
}

enum ArkFileContentError: LocalizedError {
    case invalidSiteURL
    case unsupportedHost(String)
    case purchaseRequired
    case accountSignInRequired
    case productNotConfigured
    case productUnavailable(String)
    case productMisconfigured
    case purchaseCancelled
    case purchasePending
    case unverifiedPurchase
    case noStoreKitPurchaseFound
    case ownershipVerificationRequired
    case completeVerificationPending
    case purchaseLinkingFailed(String)
    case purchaseOwnedByOtherAccount(maskedEmail: String?)
    case liteAccessRevoked
    case confirmedStoreKitRefund(productIDs: [String])
    case localPurchaseAccessUpdateFailed
    case invalidResponse
    case httpStatus(Int)
    case httpStatusWithEndpoint(Int, String, String?)
    case requestFailed(String, String)
    case unsupportedManifestFormat(Int)
    case invalidManifestTier(String)
    case emptyContentManifest
    case manifestSizeOverflow
    case unsupportedInstallMode(String)
    case requestedCatalogItemUnavailable(String)
    case conflictingDownloadVariants
    case invalidManifestFile(String)
    case duplicateManifestFile(String)
    case retiredManifestFile(String)
    case automaticManifestDeletionUnsupported
    case checksumMismatch(String)
    case fileSizeMismatch(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case storageAvailabilityUnavailable(requiredBytes: Int64)
    case networkUnavailable
    case wifiRequired
    case constrainedNetwork
    case noReadableZims
    case incompleteInstalledCatalog(installedCount: Int, expectedCount: Int)
    case appUpdateRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidSiteURL:
            "ArkFile content server is not configured."
        case let .unsupportedHost(host):
            "ArkFile blocked an unexpected content host: \(host)."
        case .purchaseRequired:
            "Buy ArkFile Essentials with your Apple Account, or use Restore Purchases if you already bought it."
        case .completeVerificationPending:
            "The App Store confirmed your Complete upgrade, but Apple has not finished registering it for this Apple Account. Your Essentials content is unaffected. Try Restore Purchases (Settings) in a few minutes — you will not be charged again."
        case .accountSignInRequired:
            "ArkFile account sign-in is not required for ArkFile Essentials purchases."
        case .productNotConfigured:
            "The ArkFile Essentials product is not configured for this build."
        case .productUnavailable(_):
            "ArkFile Essentials is not available from the App Store right now. Try again in a moment."
        case .productMisconfigured:
            "The ArkFile Essentials product is not configured as a one-time App Store purchase."
        case .purchaseCancelled:
            "Purchase cancelled. You were not charged."
        case .purchasePending:
            "The purchase is pending approval. ArkFile will unlock Essentials after Apple approves it."
        case .unverifiedPurchase:
            "The App Store could not verify this purchase. Try again, or contact ArkFile support if this keeps happening."
        case .noStoreKitPurchaseFound:
            "No ArkFile purchases found on this Apple Account."
        case .ownershipVerificationRequired:
            "ArkFile previously verified an Apple purchase on this device, but Apple did not return a current entitlement. Use Restore Purchases before buying so ArkFile cannot select or charge for the wrong product."
        case let .purchaseLinkingFailed(message):
            "The App Store confirmed the purchase, but ArkFile could not verify content access. Restore Purchases to try again, or contact ArkFile support if this keeps happening. \(Self.purchaseLinkingFailureDetail(message))"
        case let .purchaseOwnedByOtherAccount(maskedEmail):
            if let maskedEmail, !maskedEmail.isEmpty {
                "This App Store purchase was linked to ArkFile account \(maskedEmail) in an older test build. Restore Purchases in the current app, or contact ArkFile support if this keeps happening."
            } else {
                "This App Store purchase was linked to another ArkFile account in an older test build. Restore Purchases in the current app, or contact ArkFile support if this keeps happening."
            }
        case .liteAccessRevoked:
            "ArkFile could not confirm an active Essentials purchase for this Apple Account. Restore Purchases if you already bought it, or remove Essentials from this device."
        case .confirmedStoreKitRefund:
            "This ArkFile purchase was refunded. Buy again or restore if the refund was reversed."
        case .localPurchaseAccessUpdateFailed:
            "ArkFile confirmed the purchase but could not finish saving access. Try Restore Purchases."
        case .invalidResponse:
            "ArkFile received an invalid content server response."
        case let .httpStatus(statusCode):
            "ArkFile content server returned HTTP \(statusCode)."
        case let .httpStatusWithEndpoint(statusCode, endpoint, message):
            if let message, !message.isEmpty {
                "ArkFile content server returned HTTP \(statusCode) for \(endpoint): \(message)"
            } else {
                "ArkFile content server returned HTTP \(statusCode) for \(endpoint)."
            }
        case let .requestFailed(endpoint, message):
            "ArkFile could not reach \(endpoint): \(message)"
        case let .unsupportedManifestFormat(format):
            "This iOS build supports ArkFile manifest format 1. Received: \(format)."
        case let .invalidManifestTier(tier):
            "This iOS build can install ArkFile Essentials and ArkFile Complete. Received: \(tier)."
        case .emptyContentManifest:
            "ArkFile received an empty content manifest."
        case .manifestSizeOverflow:
            "The content manifest declares more data than this device can safely account for."
        case let .unsupportedInstallMode(mode):
            "This iOS build supports manifest content packs only. Received: \(mode)."
        case let .requestedCatalogItemUnavailable(path):
            "ArkFile could not find the selected title in this content pack: \(path)."
        case .conflictingDownloadVariants:
            "Choose one edition of each title. Finish or remove a different queued edition before choosing another."
        case let .invalidManifestFile(path):
            "The content manifest contains an invalid path: \(path)."
        case let .duplicateManifestFile(path):
            "The content manifest lists the same file more than once: \(path)."
        case let .retiredManifestFile(path):
            "This content manifest requests a retired ArkFile title: \(path). Update ArkFile content and try again."
        case .automaticManifestDeletionUnsupported:
            "ArkFile will not install a manifest that requests automatic deletion of offline library files."
        case let .checksumMismatch(path):
            "Downloaded content failed verification: \(path)."
        case let .fileSizeMismatch(path):
            "Downloaded content size did not match the manifest: \(path)."
        case let .insufficientStorage(requiredBytes, availableBytes):
            "Free up space to finish Essentials. ArkFile needs about \(Self.formattedBytes(requiredBytes)) available, and this device reports \(Self.formattedBytes(availableBytes))."
        case let .storageAvailabilityUnavailable(requiredBytes):
            "ArkFile could not confirm available storage on this device. Free at least \(Self.formattedBytes(requiredBytes)) and try again."
        case .networkUnavailable:
            "Connect to the internet before downloading ArkFile Essentials."
        case .wifiRequired:
            "Connect to Wi-Fi to download ArkFile Essentials, or choose Use Cellular Data if you understand the data use."
        case .constrainedNetwork:
            "Turn off Low Data Mode, choose another Wi-Fi network, or use cellular data only if you understand the data use."
        case .noReadableZims:
            "The pack installed, but ArkFile did not find a readable ZIM archive."
        case let .incompleteInstalledCatalog(installedCount, expectedCount):
            if expectedCount > 0, installedCount > 0 {
                "Essentials download did not finish. Continue Download to keep the files already here and download what is missing."
            } else {
                "Essentials download did not finish. Continue Download to pick up where it left off."
            }
        case let .appUpdateRequired(message):
            "This content pack needs a newer ArkFile app. Update ArkFile, then install Essentials again. \(message)"
        }
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func purchaseLinkingFailureDetail(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("storekit transaction environment is not accepted")
            || normalized.contains("testflight")
            || (normalized.contains("http 403") && normalized.contains("storekit")) {
            return "This beta build is connected to a purchase server that does not accept TestFlight purchases yet."
        }
        if normalized.contains("storekit content access verification failed") {
            return "ArkFile could not verify the App Store purchase with the content server."
        }
        return "ArkFile could not verify the App Store purchase with the content server."
    }
}
