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
            return "Restore Essentials to Upgrade"
        }
        return hasEssentialsAccess ? "Upgrade to Complete" : "Buy Complete"
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
    var initialTier: ArkFileContentTier? = nil

    @ObservedObject private var merchandisingStore = ArkFileStoreKitMerchandisingStore.shared
    @State private var hasCurrentEssentialsProof = false
    @State private var didResolveUpgradeEligibility = false

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
                    Text(hasCompleteAccess ? "Your content packs" : hasEssentialsAccess ? "Explore your upgrade" : "Choose your pack")
                        .font(.title2.bold())
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(initialTier == .complete
                        ? "Regional maps are included with Complete. Essentials is included too."
                        : "One-time purchase. Complete includes everything in Essentials.")
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
                    initialTier: initialTier,
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

                if priceLoadNeedsRetry {
                    Button {
                        Task {
                            await merchandisingStore.retry()
                        }
                    } label: {
                        Label("Retry Prices", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
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
        .navigationTitle("Compare Packs")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let metadataLoad: Void = merchandisingStore.loadIfNeeded()
            hasCurrentEssentialsProof = await ArkFileLitePurchaseManager.shared
                .hasCurrentEssentialsProofForUpgradeOffer()
            didResolveUpgradeEligibility = true
            await metadataLoad
        }
    }

    private var essentialsCard: some View {
        packCard(
            accessibilityID: "arkfile_pack_essentials_card",
            priceAccessibilityID: "arkfile_pack_essentials_price",
            primaryAccessibilityID: "arkfile_pack_essentials_primary_action",
            title: "ArkFile Essentials",
            benefit: "Preparedness, medical, food, travel and practical reference.",
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
            title: "ArkFile Complete",
            benefit: "Essentials plus full Wikipedia choices, textbooks and regional maps.",
            price: completePrice,
            ownership: completeOwnershipStatus,
            isOwned: hasCompleteAccess,
            device: completeDeviceStatus,
            scope: completeScope,
            details: [
                completeAdditions,
                "Choose individual titles, maps, or entire categories after purchase",
                "Nothing downloads until you confirm your choices",
                hasEssentialsAccess && hasCurrentEssentialsProof
                    ? "Upgrading keeps Essentials and everything already downloaded"
                    : hasEssentialsAccess
                        ? "Complete includes Essentials and keeps everything already downloaded"
                        : "Buy Complete directly — Essentials is included with no separate purchase"
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
        primaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(isBusy || isPrimaryDisabled)
            .accessibilityIdentifier(primaryAccessibilityID)

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
        guard let metrics else { return "Essentials catalog" }
        return "\(metrics.essentials.titleSlotCount) titles"
    }

    private var completeScope: String {
        guard let metrics else { return "Complete catalog, including optional maps" }
        return "\(metrics.complete.titleSlotCount) titles + \(metrics.complete.mapCount) regional maps"
    }

    private var completeDeviceStatus: String {
        let titles = "\(completeInstalledCount) \(completeInstalledCount == 1 ? "title" : "titles")"
        let maps = "\(completeInstalledMapCount) regional \(completeInstalledMapCount == 1 ? "map" : "maps")"
        return "On this device: \(titles) · \(maps)"
    }

    private var completeAdditions: String {
        guard let metrics else {
            return "Adds full Wikipedia choices, textbooks, expanded references, classics, and regional maps"
        }
        return "Adds \(metrics.completeAdditionalTitleSlotCount) title choices and \(metrics.completeOptionalMapCount) optional regional maps beyond Essentials"
    }

    private var essentialsUpgradeDetail: String {
        if let upgradePrice = displayPrice(for: .completeUpgrade) {
            return "Upgrade to Complete later for \(upgradePrice) one-time"
        }
        return "Upgrade to Complete later at the App Store price shown before purchase"
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
            return "Restore Essentials to see your upgrade price"
        }
        return price(for: completePurchaseRole)
    }

    private var completePrimaryTitle: String {
        switch completeAction {
        case .manageDownloads:
            return "Manage Complete Downloads"
        case .restorePurchases:
            return hasEssentialsAccess
                ? "Restore Essentials to Upgrade"
                : "Restore Purchases"
        case .purchase:
            break
        }
        guard didResolveUpgradeEligibility else {
            return "Loading Purchase Options…"
        }
        guard hasEssentialsAccess else {
            return ArkFilePackPurchaseCopy.pricedAction(
                "Buy Complete",
                displayPrice: displayPrice(for: .complete)
            )
        }
        return effectiveCurrentEssentialsProof
            ? ArkFilePackPurchaseCopy.pricedAction(
                "Upgrade to Complete",
                displayPrice: displayPrice(for: .completeUpgrade)
            )
            : "Restore Essentials to Upgrade"
    }

    private var essentialsPurchaseTitle: String {
        ArkFilePackPurchaseCopy.pricedAction(
            "Buy Essentials",
            displayPrice: displayPrice(for: .lite)
        )
    }

    private var essentialsPrimaryTitle: String {
        switch essentialsAction {
        case .manageDownloads:
            return hasCompleteAccess
                ? "Manage Downloads"
                : "Choose Essentials Downloads"
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
            return "Access: Essentials owned — checking upgrade price"
        }
        return hasCurrentEssentialsProof
            ? "Access: Essentials owned — upgrade available"
            : "Access: Essentials available — restore to upgrade"
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
            return "\(value) one-time"
        }
        switch merchandisingStore.state {
        case .idle, .loading:
            return "Loading price…"
        case .loaded, .partial, .failed:
            return "Price unavailable"
        }
    }

    private func displayPrice(for role: ArkFileStoreKitProductRole) -> String? {
        merchandisingStore.state.snapshot?.offer(for: role)?.displayPrice
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
