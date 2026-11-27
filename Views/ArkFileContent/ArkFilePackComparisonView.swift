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

#if os(iOS)
import SwiftUI
import StoreKit

enum ArkFilePackComparisonAction: Equatable {
    case manageDownloads
    case restorePurchases
    case purchase(ArkFileContentTier)
}

enum ArkFilePackComparisonActionResolver {
    static func resolve(
        tier: ArkFileContentTier,
        hasEssentialsAccess: Bool,
        hasCompleteAccess: Bool,
        hasResolvedCurrentStoreKitProof: Bool,
        hasCurrentEssentialsStoreKitProof: Bool,
        hasCurrentCompleteStoreKitProof: Bool
    ) -> ArkFilePackComparisonAction {
        let hasRequestedAccess = tier == .complete
            ? hasCompleteAccess
            : hasEssentialsAccess
        let hasCurrentRequestedProof = tier == .complete
            ? hasCurrentCompleteStoreKitProof
            : hasCurrentEssentialsStoreKitProof

        if hasRequestedAccess {
            return !hasResolvedCurrentStoreKitProof || hasCurrentRequestedProof
                ? .manageDownloads
                : .restorePurchases
        }

        if tier == .complete,
           hasEssentialsAccess,
           hasResolvedCurrentStoreKitProof,
           !hasCurrentEssentialsStoreKitProof {
            return .restorePurchases
        }

        return .purchase(tier)
    }
}

enum ArkFilePackPurchaseCopy {
    static func pricedAction(_ title: String, displayPrice: String?) -> String {
        guard let displayPrice, !displayPrice.isEmpty else { return title }
        return "\(title) · \(displayPrice)"
    }

    /// Final purchase button copy. This is the only commerce copy that names a
    /// charge; it carries Apple's localized price for the exact SKU when loaded
    /// (the button stays disabled until it is).
    static func purchaseTitle(
        for role: ArkFileStoreKitProductRole,
        displayPrice: String?
    ) -> String {
        let title = switch role {
        case .lite:
            "Buy \(ArkFileContentPackDisplayName.libraryName(for: .lite))"
        case .complete, .completeUpgrade:
            "Buy \(ArkFileContentPackDisplayName.libraryName(for: .complete))"
        }
        return pricedAction(title, displayPrice: displayPrice)
    }

    /// Card price line. A verified Essentials owner sees the upgrade SKU's
    /// price labelled as their own, never the outright Full Library price.
    static func priceLine(
        for role: ArkFileStoreKitProductRole,
        displayPrice: String
    ) -> String {
        role == .completeUpgrade
            ? "Your one-time upgrade price: \(displayPrice)"
            : "\(displayPrice) one-time"
    }

    static func needsEssentialsRestoreToUpgrade(
        hasEssentialsAccess: Bool,
        hasResolvedCurrentStoreKitProof: Bool,
        hasCurrentEssentialsProof: Bool
    ) -> Bool {
        hasEssentialsAccess
            && hasResolvedCurrentStoreKitProof
            && !hasCurrentEssentialsProof
    }

    static func completeReviewTitle(
        hasEssentialsAccess: Bool,
        hasResolvedCurrentStoreKitProof: Bool,
        hasCurrentEssentialsProof: Bool
    ) -> String {
        if needsEssentialsRestoreToUpgrade(
            hasEssentialsAccess: hasEssentialsAccess,
            hasResolvedCurrentStoreKitProof: hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsProof: hasCurrentEssentialsProof
        ) {
            return "Restore \(ArkFileContentPackDisplayName.libraryName(for: .lite)) to Upgrade"
        }
        // Review entry points only open the comparison; the priced Buy button
        // there is the purchase.
        return ArkFileLockedContentPresentation.browseTitle(
            tier: .complete,
            ownsEssentials: hasEssentialsAccess
        )
    }
}

/// App Store product names are edited in App Store Connect and can lag the
/// app's copy. When Apple's localized name for the exact SKU differs from the
/// name ArkFile now uses, say so beside the Buy button so the purchase sheet
/// is not a surprise.
enum ArkFilePackStorefrontName {
    static func expected(for role: ArkFileStoreKitProductRole) -> String {
        switch role {
        case .lite:
            ArkFileContentPackDisplayName.storefrontName(for: .lite)
        case .complete:
            ArkFileContentPackDisplayName.storefrontName(for: .complete)
        case .completeUpgrade:
            "\(ArkFileContentPackDisplayName.storefrontName(for: .complete)) Upgrade"
        }
    }

    static func transitionalNotice(
        appleDisplayName: String?,
        role: ArkFileStoreKitProductRole
    ) -> String? {
        guard let appleName = appleDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !appleName.isEmpty,
              appleName.compare(
                expected(for: role),
                options: [.caseInsensitive, .diacriticInsensitive]
              ) != .orderedSame else {
            return nil
        }
        return "Apple’s purchase sheet may show this as “\(appleName)”."
    }
}

enum ArkFilePackComparisonLayout {
    static func orderedTiers(
        initialTier: ArkFileContentTier?,
        hasEssentialsAccess: Bool,
        hasCompleteAccess: Bool
    ) -> [ArkFileContentTier] {
        if initialTier == .complete || hasEssentialsAccess || hasCompleteAccess {
            return [.complete, .lite]
        }
        return [.lite, .complete]
    }
}

enum ArkFilePackComparisonFocus: Equatable {
    case general
    case tier(ArkFileContentTier)
    case mapRegion

    var initialTier: ArkFileContentTier? {
        switch self {
        case .general: nil
        case .tier(let tier): tier
        case .mapRegion: .complete
        }
    }

    func title(hasEssentialsAccess: Bool, hasCompleteAccess: Bool) -> String {
        if hasCompleteAccess { return "Your library" }
        if hasEssentialsAccess {
            return "What Full Library adds"
        }
        // The focused tier is ordered first; the heading stays a choice.
        return "Choose your library"
    }

    var subtitle: String {
        let essentials = ArkFileContentPackDisplayName.libraryName(for: .lite)
        let full = ArkFileContentPackDisplayName.libraryName(for: .complete)
        return switch self {
        case .mapRegion:
            "Regional maps are included with \(full), along with everything in \(essentials)."
        case .tier(.lite):
            "One-time purchase. You can upgrade to \(full) later."
        case .general, .tier:
            "One-time purchase. \(full) includes everything in \(essentials)."
        }
    }
}

enum ArkFilePurchasePresentation {
    static func shouldBlockForAppleAccountCheck(
        isCheckingApplePurchases: Bool,
        hasResolvedCurrentStoreKitProof: Bool = true,
        hasEssentialsAccess: Bool,
        hasCompleteAccess: Bool,
        hasLocalPaidContent: Bool = false
    ) -> Bool {
        (isCheckingApplePurchases || !hasResolvedCurrentStoreKitProof)
            && (
                hasEssentialsAccess
                    || hasCompleteAccess
                    || hasLocalPaidContent
            )
    }

    static func isPrimaryActionDisabled(
        action: ArkFilePackComparisonAction,
        hasLocalizedPrice: Bool,
        blocksForAppleAccountCheck: Bool,
        isUpgradeEligibilityResolved: Bool = true
    ) -> Bool {
        guard case .purchase = action else { return false }
        return !hasLocalizedPrice
            || blocksForAppleAccountCheck
            || !isUpgradeEligibilityResolved
    }
}

enum ArkFilePostRestoreContinuation: Equatable {
    case chooseDownloads(ArkFileContentTier)
    case continueCompletePurchase

    static func resolve(
        restoredTier: ArkFileContentTier,
        requestedTier: ArkFileContentTier? = nil,
        pendingPurchaseTier: ArkFileContentTier?
    ) -> Self {
        if (pendingPurchaseTier == .complete || requestedTier == .complete),
           restoredTier != .complete {
            return .continueCompletePurchase
        }
        return .chooseDownloads(restoredTier)
    }
}

enum ArkFilePurchaseArtwork {
    static func assetName(for role: ArkFileStoreKitProductRole) -> String {
        switch role {
        case .lite: return "ArkFilePurchaseEssentials"
        case .complete: return "ArkFilePurchaseComplete"
        case .completeUpgrade: return "ArkFilePurchaseCompleteUpgrade"
        }
    }
}

struct ArkFileOfferCodeOwnershipSnapshot: Equatable {
    let hasResolvedProof: Bool
    let tier: ArkFileContentTier?

    var verifiedTier: ArkFileContentTier? {
        hasResolvedProof && tier?.isIOSInstallable == true ? tier : nil
    }
}

/// The Apple sheet's result describes presentation, not a verified purchase.
/// This coordinator can only refresh ownership; it has no download or sync action.
@MainActor
final class ArkFileOfferCodeRedemptionCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshGeneration = 0
    @Published private(set) var snapshot: ArkFileOfferCodeOwnershipSnapshot?
    @Published private(set) var outcome = Outcome.none
    enum Outcome: Equatable { case none, closed, cancelled, failed }

    private let refresh: @MainActor () async -> ArkFileOfferCodeOwnershipSnapshot
    private var attempt = 0
    private var refreshedAttempt: Int?
    private var observedRevision = 0

    init(refresh: @escaping @MainActor () async -> ArkFileOfferCodeOwnershipSnapshot = {
        let manager = ArkFileLitePurchaseManager.shared
        await manager.reconcileLiteEntitlementOnLaunchOrForeground()
        return ArkFileOfferCodeOwnershipSnapshot(
            hasResolvedProof: manager.hasResolvedCurrentStoreKitProof,
            tier: manager.currentStoreKitProofTier
        )
    }) {
        self.refresh = refresh
    }

    func present() {
        guard !isPresented, !isRefreshing else { return }
        attempt += 1
        refreshedAttempt = nil
        snapshot = nil
        outcome = .none
        isPresented = true
    }

    func sheetCompleted(_ result: Result<Void, Error>) async {
        guard attempt > 0 else { return }
        switch result {
        case .success: outcome = .closed
        case .failure(let error):
            let isCancelled: Bool
            if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError {
                isCancelled = true
            } else if let legacyError = error as? SKError, legacyError.code == .paymentCancelled {
                isCancelled = true
            } else {
                isCancelled = error is CancellationError
            }
            outcome = isCancelled ? .cancelled : .failed
        }
        isPresented = false
        await refreshAfterDismissal()
    }

    func sheetDismissed() async {
        guard attempt > 0 else { return }
        if outcome == .none { outcome = .closed }
        isPresented = false
        await refreshAfterDismissal()
    }

    func observeVerifiedOwnership(_ value: ArkFileOfferCodeOwnershipSnapshot) {
        guard attempt > 0 else { return }
        observedRevision += 1
        snapshot = value
    }

    var statusMessage: String? {
        guard outcome != .none else { return nil }
        if isRefreshing { return "Checking Apple purchases…" }
        if outcome == .cancelled { return "Code redemption was cancelled." }
        if outcome == .failed {
            return "Apple could not complete code redemption. Try again, or use Restore Purchases if you already redeemed a code."
        }
        if let tier = snapshot?.verifiedTier {
            let name = ArkFileContentPackDisplayName.libraryName(for: tier)
            return "Apple purchase found: \(name). Your download choices remain unchanged."
        }
        return "No new purchase is verified yet. If you redeemed a code, allow a moment for Apple to update your purchases or use Restore Purchases."
    }

    private func refreshAfterDismissal() async {
        guard refreshedAttempt != attempt else { return }
        refreshedAttempt = attempt
        isRefreshing = true
        let currentAttempt = attempt
        let revision = observedRevision
        let refreshed = await refresh()
        guard currentAttempt == attempt else { return }
        if revision == observedRevision { snapshot = refreshed }
        isRefreshing = false
        refreshGeneration += 1
    }
}

/// A user-requested comparison surface. Opening this view is the point where
/// ArkFile asks StoreKit for localized prices; app launch stays network-free.
struct ArkFilePackComparisonView: View {
    let catalog: ArkFileContentCatalog?
    let hasEssentialsAccess: Bool
    let hasCompleteAccess: Bool
    let hasLocalPaidContent: Bool
    let hasCurrentEssentialsStoreKitProof: Bool
    let hasCurrentCompleteStoreKitProof: Bool
    let hasResolvedCurrentStoreKitProof: Bool
    let essentialsInstalledCount: Int
    let completeInstalledCount: Int
    let completeInstalledMapCount: Int
    let isBusy: Bool
    let isCheckingApplePurchases: Bool
    let chooseEssentials: () -> Void
    let chooseComplete: (Bool) -> Void
    let manageDownloads: () -> Void
    let restorePurchases: () -> Void
    var focus: ArkFilePackComparisonFocus = .general

    @ObservedObject private var merchandisingStore = ArkFileStoreKitMerchandisingStore.shared
    @ObservedObject private var purchaseManager = ArkFileLitePurchaseManager.shared
    @StateObject private var redemption = ArkFileOfferCodeRedemptionCoordinator()
    @State private var hasCurrentEssentialsProof = false
    @State private var didResolveUpgradeEligibility = false
    @State private var upgradeEligibilityGeneration = 0

    private var metrics: ArkFilePackCatalogMetrics? {
        catalog.map(ArkFilePackCatalogMetrics.make(catalog:))
    }

    private var blocksForAppleAccountCheck: Bool {
        ArkFilePurchasePresentation.shouldBlockForAppleAccountCheck(
            isCheckingApplePurchases: isCheckingApplePurchases,
            hasResolvedCurrentStoreKitProof: hasResolvedCurrentStoreKitProof,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: hasCompleteAccess,
            hasLocalPaidContent: hasLocalPaidContent
        )
    }

    private var comparisonSubtitle: String {
        if hasEssentialsAccess && !hasCompleteAccess && hasResolvedCurrentStoreKitProof && hasCurrentEssentialsStoreKitProof {
            return "You already own Essentials Library."
        }
        return focus.subtitle
    }

    private var effectiveCurrentEssentialsProof: Bool {
        didResolveUpgradeEligibility && hasCurrentEssentialsProof
    }

    private var essentialsAction: ArkFilePackComparisonAction {
        return ArkFilePackComparisonActionResolver.resolve(
            tier: .lite,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: hasCompleteAccess,
            hasResolvedCurrentStoreKitProof: hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsStoreKitProof: hasCurrentEssentialsStoreKitProof,
            hasCurrentCompleteStoreKitProof: hasCurrentCompleteStoreKitProof
        )
    }

    private var completeAction: ArkFilePackComparisonAction {
        if hasEssentialsAccess,
           !hasCompleteAccess,
           !didResolveUpgradeEligibility {
            return .purchase(.complete)
        }
        return ArkFilePackComparisonActionResolver.resolve(
            tier: .complete,
            hasEssentialsAccess: hasEssentialsAccess,
            hasCompleteAccess: hasCompleteAccess,
            hasResolvedCurrentStoreKitProof: hasResolvedCurrentStoreKitProof,
            hasCurrentEssentialsStoreKitProof: effectiveCurrentEssentialsProof,
            hasCurrentCompleteStoreKitProof: hasCurrentCompleteStoreKitProof
        )
    }

    private var completePurchaseRole: ArkFileStoreKitProductRole {
        ArkFileStoreKitCompleteProductRoleResolver.resolve(
            hasEssentialsProof: effectiveCurrentEssentialsProof
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(focus.title(hasEssentialsAccess: hasEssentialsAccess, hasCompleteAccess: hasCompleteAccess))
                        .font(.title2.bold())
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(comparisonSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if blocksForAppleAccountCheck {
                    ArkFileApplePurchaseCheckingView(
                        isBusy: isBusy,
                        checkAppleAccount: restorePurchases
                    )
                }

                ForEach(ArkFilePackComparisonLayout.orderedTiers(
                    initialTier: focus.initialTier,
                    hasEssentialsAccess: hasEssentialsAccess,
                    hasCompleteAccess: hasCompleteAccess
                ), id: \.self) { tier in
                    if tier == .complete {
                        completeCard
                    } else {
                        essentialsCard
                    }
                }

                Text("You choose what to download after purchase. Nothing downloads automatically. Purchases use your Apple Account; no ArkFile account is required.")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    redemption.present()
                } label: {
                    Label("Redeem Offer Code", systemImage: "gift")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || redemption.isRefreshing || redemption.isPresented)
                .accessibilityIdentifier("arkfile_pack_redeem_action")

                if let message = redemption.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("arkfile_pack_redemption_status")
                }

                Button {
                    restorePurchases()
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityIdentifier("arkfile_pack_restore_action")

                Text("Restore Purchases checks this Apple Account and does not download content.")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .background(Color.arkAppBackground.ignoresSafeArea())
        .navigationTitle("Libraries")
        .navigationBarTitleDisplayMode(.inline)
        .offerCodeRedemption(isPresented: $redemption.isPresented) { result in
            Task { await redemption.sheetCompleted(result) }
        }
        .onChange(of: redemption.isPresented) { _, presented in
            if !presented { Task { await redemption.sheetDismissed() } }
        }
        .onChange(of: redemptionOwnershipSnapshot) { _, snapshot in
            // Transaction.updates can arrive after the native sheet has closed.
            redemption.observeVerifiedOwnership(snapshot)
        }
        .task { await merchandisingStore.loadForPurchasePresentation() }
        .task(id: purchaseManager.ownershipSnapshot) { await refreshUpgradeEligibility() }
        .task(id: redemption.refreshGeneration) {
            if redemption.refreshGeneration > 0 { await refreshUpgradeEligibility() }
        }
    }

    private var redemptionOwnershipSnapshot: ArkFileOfferCodeOwnershipSnapshot {
        ArkFileOfferCodeOwnershipSnapshot(
            hasResolvedProof: purchaseManager.hasResolvedCurrentStoreKitProof,
            tier: purchaseManager.currentStoreKitProofTier
        )
    }

    private func refreshUpgradeEligibility() async {
        upgradeEligibilityGeneration += 1
        let generation = upgradeEligibilityGeneration
        didResolveUpgradeEligibility = false
        let verifiedEssentials = await purchaseManager.hasCurrentEssentialsProofForUpgradeOffer()
        guard !Task.isCancelled, generation == upgradeEligibilityGeneration else { return }
        hasCurrentEssentialsProof = verifiedEssentials
        didResolveUpgradeEligibility = true
    }

    private var essentialsCard: some View {
        packCard(
            accessibilityID: "arkfile_pack_essentials_card",
            priceAccessibilityID: "arkfile_pack_essentials_price",
            primaryAccessibilityID: "arkfile_pack_essentials_primary_action",
            title: ArkFileContentPackDisplayName.libraryName(for: .lite),
            artworkRole: .lite,
            benefit: "Simple Wikipedia, the USDA home canning guide, and practical preparedness, medical, food and travel references.",
            price: essentialsPrice,
            ownership: essentialsOwnershipStatus,
            isOwned: hasEssentialsAccess,
            device: "On this device: \(essentialsInstalledCount) \(essentialsInstalledCount == 1 ? "title" : "titles")",
            scope: essentialsScope,
            details: [
                "Preparedness, medical, food, travel, reference, books, and field manuals",
                "North America map detail and U.S. Critical Places, available to download",
                "Choose individual titles or select a category after purchase",
                "Nothing downloads until you confirm your choices",
                hasCompleteAccess
                    ? "Unselected titles remain available later"
                    : essentialsUpgradeDetail
            ],
            tint: Color.arkPrimary,
            labelTint: Color.arkInteractiveForeground,
            primaryTitle: essentialsPrimaryTitle,
            primarySystemImage: essentialsPrimarySystemImage,
            isPrimaryDisabled: ArkFilePurchasePresentation.isPrimaryActionDisabled(
                action: essentialsAction,
                hasLocalizedPrice: displayPrice(for: .lite) != nil,
                blocksForAppleAccountCheck: blocksForAppleAccountCheck
            ),
            storefrontNameNotice: essentialsStorefrontNotice,
            primaryAction: {
                switch essentialsAction {
                case .manageDownloads:
                    manageDownloads()
                case .restorePurchases, .purchase:
                    chooseEssentials()
                }
            }
        )
    }

    private var completeCard: some View {
        packCard(
            accessibilityID: "arkfile_pack_complete_card",
            priceAccessibilityID: "arkfile_pack_complete_price",
            primaryAccessibilityID: "arkfile_pack_complete_primary_action",
            title: ArkFileContentPackDisplayName.libraryName(for: .complete),
            artworkRole: hasCompleteAccess ? .complete : completePurchaseRole,
            benefit: "Everything in Essentials Library plus \(ArkFileLibraryBenefits.fullLibraryAdditions).",
            price: completePrice,
            ownership: completeOwnershipStatus,
            isOwned: hasCompleteAccess,
            device: completeDeviceStatus,
            scope: completeScope,
            details: [
                "Everything in Essentials Library, including Simple Wikipedia and the USDA home canning guide",
                completeAdditions,
                "Textbook subjects include algebra, biology, chemistry and physics.",
                "Choose individual titles, maps, or entire categories after purchase",
                "Nothing downloads until you confirm your choices",
                hasEssentialsAccess && effectiveCurrentEssentialsProof
                    ? "Upgrading keeps Essentials Library and everything already downloaded"
                    : hasEssentialsAccess
                        ? "Full Library includes Essentials Library and keeps everything already downloaded"
                        : "Buy Full Library directly — Essentials Library is included with no separate purchase"
            ],
            tint: Color.arkAccentSecondary,
            labelTint: Color.arkTextPrimary,
            primaryTitle: completePrimaryTitle,
            primarySystemImage: completePrimarySystemImage,
            isPrimaryDisabled: ArkFilePurchasePresentation.isPrimaryActionDisabled(
                action: completeAction,
                hasLocalizedPrice: displayPrice(for: completePurchaseRole) != nil,
                blocksForAppleAccountCheck: blocksForAppleAccountCheck,
                isUpgradeEligibilityResolved: didResolveUpgradeEligibility
            ),
            storefrontNameNotice: completeStorefrontNotice,
            primaryAction: {
                switch completeAction {
                case .manageDownloads:
                    manageDownloads()
                case .restorePurchases, .purchase:
                    chooseComplete(hasCurrentEssentialsProof)
                }
            }
        )
    }

    private func packCard(
        accessibilityID: String,
        priceAccessibilityID: String,
        primaryAccessibilityID: String,
        title: String,
        artworkRole: ArkFileStoreKitProductRole,
        benefit: String,
        price: String,
        ownership: String,
        isOwned: Bool,
        device: String,
        scope: String,
        details: [String],
        tint: Color,
        labelTint: Color? = nil,
        primaryTitle: String,
        primarySystemImage: String,
        isPrimaryDisabled: Bool = false,
        storefrontNameNotice: String? = nil,
        primaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(ArkFilePurchaseArtwork.assetName(for: artworkRole))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                // A container-level identifier masks the distinct price and
                // button identifiers on iOS, so the rendered title anchors the card.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.title3.bold())
                            .foregroundStyle(Color.arkTextPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier(accessibilityID)
                        Spacer(minLength: 0)
                        Text(price)
                            .font(.headline)
                            .foregroundStyle(Color.arkTextPrimary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier(priceAccessibilityID)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.title3.bold())
                            .foregroundStyle(Color.arkTextPrimary)
                            .accessibilityIdentifier(accessibilityID)
                        Text(price)
                            .font(.headline)
                            .foregroundStyle(Color.arkTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(priceAccessibilityID)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(scope, systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
                Text(benefit)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if isOwned || hasLocalPaidContent {
                    Label(ownership, systemImage: isOwned ? "checkmark.seal.fill" : "lock.open")
                        .font(.caption)
                        .accessibilityIdentifier("arkfile_pack_ownership_status")
                    Label(device, systemImage: "internaldrive")
                        .font(.caption)
                        .accessibilityIdentifier("arkfile_pack_device_status")
                }
            }
            .foregroundStyle(Color.arkTextMuted)

            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: primarySystemImage)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(isBusy || redemption.isRefreshing || redemption.isPresented || isPrimaryDisabled)
            .accessibilityIdentifier(primaryAccessibilityID)
            .accessibilityLabel(Text(primaryTitle.replacingOccurrences(of: " · ", with: ", ")
                + (primaryTitle.contains(" · ") ? ", one-time purchase" : "")))

            if let storefrontNameNotice, !isPrimaryDisabled {
                Text(storefrontNameNotice)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(primaryAccessibilityID)_storefront_name")
            }

            if isPrimaryDisabled && displayPrice(for: artworkRole) == nil && priceLoadNeedsRetry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can’t load the App Store price. Connect to the internet and try again.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry Prices") {
                        Task { await merchandisingStore.retry() }
                    }
                    .frame(minHeight: 44)
                    .disabled(isBusy)
                }
                .foregroundStyle(Color.arkInteractiveForeground)
            }

            DisclosureGroup("What’s included") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details, id: \.self) { detail in
                        Label {
                            Text(detail)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(labelTint ?? tint)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.arkTextMuted)
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
            .tint(Color.arkInteractiveForeground)
            .accessibilityIdentifier("\(accessibilityID)_details")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var essentialsScope: String {
        guard let metrics else { return "Essentials Library catalog" }
        return "\(metrics.essentials.titleSlotCount) titles"
    }

    private var completeScope: String {
        guard let metrics else { return "Full Library catalog, including optional regional maps" }
        return "\(metrics.complete.titleSlotCount) titles + \(metrics.complete.mapCount) regional maps"
    }

    private var completeDeviceStatus: String {
        let titles = "\(completeInstalledCount) \(completeInstalledCount == 1 ? "title" : "titles")"
        let maps = "\(completeInstalledMapCount) regional \(completeInstalledMapCount == 1 ? "map" : "maps")"
        return "On this device: \(titles) · \(maps)"
    }

    private var completeAdditions: String {
        guard let metrics else {
            return "Adds full Wikipedia choices, \(ArkFileLibraryBenefits.textbookCollection), expanded references, classics, and regional street maps"
        }
        return "Adds \(metrics.completeAdditionalTitleSlotCount) title choices and \(metrics.completeOptionalMapCount) optional regional street maps beyond Essentials Library"
    }

    private var essentialsUpgradeDetail: String {
        if let upgradePrice = displayPrice(for: .completeUpgrade) {
            return "Upgrade to Full Library later for \(upgradePrice) one-time"
        }
        return "Upgrade to Full Library later at the App Store price shown before purchase"
    }

    private var essentialsPrice: String {
        if hasEssentialsAccess {
            if !hasResolvedCurrentStoreKitProof { return "Checking purchase…" }
            return hasCurrentEssentialsStoreKitProof ? "Owned" : "Restore purchase"
        }
        return price(
            for: .lite
        )
    }

    private var completePrice: String {
        if hasCompleteAccess {
            if !hasResolvedCurrentStoreKitProof { return "Checking purchase…" }
            return hasCurrentCompleteStoreKitProof ? "Owned" : "Restore purchase"
        }
        guard didResolveUpgradeEligibility else {
            return "Loading price…"
        }
        if hasEssentialsAccess, !hasCurrentEssentialsProof {
            return "Restore Essentials Library to see your upgrade price"
        }
        return price(for: completePurchaseRole)
    }

    private var restoreEssentialsToUpgradeTitle: String {
        "Restore \(ArkFileContentPackDisplayName.libraryName(for: .lite)) to Upgrade"
    }

    private var completePrimaryTitle: String {
        switch completeAction {
        case .manageDownloads:
            return "Manage Full Library Downloads"
        case .restorePurchases:
            return hasEssentialsAccess && !hasCompleteAccess
                ? restoreEssentialsToUpgradeTitle
                : "Restore Purchases"
        case .purchase:
            break
        }
        guard didResolveUpgradeEligibility else {
            return "Loading Purchase Options…"
        }
        guard hasEssentialsAccess else {
            return ArkFilePackPurchaseCopy.purchaseTitle(
                for: .complete,
                displayPrice: displayPrice(for: .complete)
            )
        }
        return effectiveCurrentEssentialsProof
            ? ArkFilePackPurchaseCopy.purchaseTitle(
                for: .completeUpgrade,
                displayPrice: displayPrice(for: .completeUpgrade)
            )
            : restoreEssentialsToUpgradeTitle
    }

    private var essentialsPurchaseTitle: String {
        ArkFilePackPurchaseCopy.purchaseTitle(
            for: .lite,
            displayPrice: displayPrice(for: .lite)
        )
    }

    /// Shown only beside a live purchase button, for the exact SKU it buys.
    private var essentialsStorefrontNotice: String? {
        guard case .purchase = essentialsAction,
              !blocksForAppleAccountCheck else { return nil }
        return ArkFilePackStorefrontName.transitionalNotice(
            appleDisplayName: offer(for: .lite)?.displayName,
            role: .lite
        )
    }

    private var completeStorefrontNotice: String? {
        guard case .purchase = completeAction,
              didResolveUpgradeEligibility,
              !blocksForAppleAccountCheck,
              !hasEssentialsAccess || effectiveCurrentEssentialsProof else {
            // An unverified Essentials owner sees a restore button, not a purchase.
            return nil
        }
        return ArkFilePackStorefrontName.transitionalNotice(
            appleDisplayName: offer(for: completePurchaseRole)?.displayName,
            role: completePurchaseRole
        )
    }

    private var essentialsPrimaryTitle: String {
        switch essentialsAction {
        case .manageDownloads:
            return hasCompleteAccess
                ? "Manage Downloads"
                : "Choose Essentials Library Downloads"
        case .restorePurchases:
            return "Restore Purchases"
        case .purchase:
            return essentialsPurchaseTitle
        }
    }

    private var essentialsPrimarySystemImage: String {
        switch essentialsAction {
        case .manageDownloads:
            return "internaldrive"
        case .restorePurchases:
            return "arrow.clockwise.circle"
        case .purchase:
            return "lock.open"
        }
    }

    private var completePrimarySystemImage: String {
        switch completeAction {
        case .manageDownloads:
            return "internaldrive"
        case .restorePurchases:
            return "arrow.clockwise.circle"
        case .purchase:
            return effectiveCurrentEssentialsProof ? "arrow.up.circle" : "checklist"
        }
    }

    private var completeOwnershipStatus: String {
        if hasCompleteAccess {
            guard hasResolvedCurrentStoreKitProof else {
                return "Access: Checking Apple purchases"
            }
            return hasCurrentCompleteStoreKitProof
                ? "Access: Owned"
                : "Access: Available on this device"
        }
        guard hasEssentialsAccess else { return "Access: Not purchased" }
        guard hasResolvedCurrentStoreKitProof else {
            return "Access: Checking Apple purchases"
        }
        guard didResolveUpgradeEligibility else {
            return "Access: Checking upgrade eligibility"
        }
        return hasCurrentEssentialsProof
            ? "Access: Essentials Library owned — upgrade available"
            : "Access: Essentials Library available — restore to upgrade"
    }

    private var essentialsOwnershipStatus: String {
        guard hasEssentialsAccess else { return "Access: Not purchased" }
        guard hasResolvedCurrentStoreKitProof else {
            return "Access: Checking Apple purchases"
        }
        return hasCurrentEssentialsStoreKitProof
            ? "Access: Owned"
            : "Access: Available on this device"
    }

    private func price(for role: ArkFileStoreKitProductRole) -> String {
        if let value = displayPrice(for: role) {
            return ArkFilePackPurchaseCopy.priceLine(for: role, displayPrice: value)
        }
        switch merchandisingStore.state {
        case .idle, .loading:
            return "Loading price…"
        case .loaded, .partial, .failed:
            return "Price unavailable"
        }
    }

    private func displayPrice(for role: ArkFileStoreKitProductRole) -> String? {
        offer(for: role)?.displayPrice
    }

    private func offer(for role: ArkFileStoreKitProductRole) -> ArkFileStoreKitProductMetadata? {
        merchandisingStore.state.snapshot?.offer(for: role)
    }

    private var priceLoadNeedsRetry: Bool {
        switch merchandisingStore.state {
        case .partial, .failed:
            true
        case .idle, .loading, .loaded:
            false
        }
    }

}
#endif
