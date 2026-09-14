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
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import Foundation

struct ArkFileLockedContentResolutionInput: Equatable, Sendable {
    let installedTier: ArkFileContentTier?
    let activeTier: ArkFileContentTier?
    let isBusy: Bool
    let hasSavedLiteAccess: Bool
    let hasSavedCompleteAccess: Bool
    let isLiteAccessRevoked: Bool
    let isCompleteAccessRevoked: Bool
    let hasResumableDownload: Bool
    let needsLiteRepair: Bool
    let needsCompleteRepair: Bool
    let canRestoreLite: Bool
    let excludedLiteItemKeys: Set<String>
    let excludedCompleteItemKeys: Set<String>
    let isCheckingApplePurchases: Bool
    let hasResolvedCurrentStoreKitProof: Bool
    let hasAuthoritativeNoPurchase: Bool

    init(
        installedTier: ArkFileContentTier?,
        activeTier: ArkFileContentTier?,
        isBusy: Bool,
        hasSavedLiteAccess: Bool,
        hasSavedCompleteAccess: Bool,
        isLiteAccessRevoked: Bool,
        isCompleteAccessRevoked: Bool,
        hasResumableDownload: Bool,
        needsLiteRepair: Bool,
        needsCompleteRepair: Bool,
        canRestoreLite: Bool,
        excludedLiteItemKeys: Set<String>,
        excludedCompleteItemKeys: Set<String>,
        isCheckingApplePurchases: Bool = false,
        hasResolvedCurrentStoreKitProof: Bool = true,
        hasAuthoritativeNoPurchase: Bool
    ) {
        self.installedTier = installedTier
        self.activeTier = activeTier
        self.isBusy = isBusy
        self.hasSavedLiteAccess = hasSavedLiteAccess
        self.hasSavedCompleteAccess = hasSavedCompleteAccess
        self.isLiteAccessRevoked = isLiteAccessRevoked
        self.isCompleteAccessRevoked = isCompleteAccessRevoked
        self.hasResumableDownload = hasResumableDownload
        self.needsLiteRepair = needsLiteRepair
        self.needsCompleteRepair = needsCompleteRepair
        self.canRestoreLite = canRestoreLite
        self.excludedLiteItemKeys = Set(excludedLiteItemKeys.map { $0.lowercased() })
        self.excludedCompleteItemKeys = Set(excludedCompleteItemKeys.map { $0.lowercased() })
        self.isCheckingApplePurchases = isCheckingApplePurchases
        self.hasResolvedCurrentStoreKitProof = hasResolvedCurrentStoreKitProof
        self.hasAuthoritativeNoPurchase = hasAuthoritativeNoPurchase
    }

    @MainActor
    init(
        installer: ArkFileContentPackInstaller,
        hasAuthoritativeNoPurchase: Bool,
        hasEssentialsAccess: Bool,
        essentialsInstallNeedsRepair: Bool,
        completeInstallNeedsRepair: Bool
    ) {
        self.init(
            installedTier: installer.installedTier,
            activeTier: installer.state.tier,
            isBusy: installer.isBusy,
            hasSavedLiteAccess: hasEssentialsAccess,
            hasSavedCompleteAccess: installer.hasSavedCompleteAccess,
            isLiteAccessRevoked: installer.isLiteAccessRevoked,
            isCompleteAccessRevoked: installer.isCompleteAccessRevoked,
            hasResumableDownload: installer.hasResumableLiteDownload,
            needsLiteRepair: essentialsInstallNeedsRepair,
            needsCompleteRepair: completeInstallNeedsRepair,
            canRestoreLite: installer.canRestoreLite,
            excludedLiteItemKeys: installer.excludedItemKeys(for: .lite),
            excludedCompleteItemKeys: installer.excludedItemKeys(for: .complete),
            isCheckingApplePurchases: installer.isCheckingApplePurchases,
            hasResolvedCurrentStoreKitProof: installer.hasResolvedCurrentStoreKitProof,
            hasAuthoritativeNoPurchase: hasAuthoritativeNoPurchase
        )
    }

    func hasSavedAccess(for tier: ArkFileContentTier) -> Bool {
        tier == .complete ? hasSavedCompleteAccess : hasSavedLiteAccess
    }

    func needsRepair(for tier: ArkFileContentTier) -> Bool {
        tier == .complete ? needsCompleteRepair : needsLiteRepair
    }

    func excludedItemKeys(for tier: ArkFileContentTier) -> Set<String> {
        tier == .complete ? excludedCompleteItemKeys : excludedLiteItemKeys
    }

    func isAccessRevoked(for tier: ArkFileContentTier) -> Bool {
        isLiteAccessRevoked || (tier == .complete && isCompleteAccessRevoked)
    }

    /// A brand-new device has no paid-content evidence to protect, so a
    /// background StoreKit read must not hide an otherwise safe purchase
    /// choice. Returning purchasers still wait until ArkFile knows whether to
    /// offer Complete outright or the lower-priced upgrade.
    var blocksForApplePurchaseCheck: Bool {
        (isCheckingApplePurchases || !hasResolvedCurrentStoreKitProof)
            && (
                installedTier != nil
                    || hasSavedLiteAccess
                    || hasSavedCompleteAccess
            )
    }
}

enum ArkFileLockedContentRestoreRoute: Equatable, Sendable {
    case restore(ArkFileContentTier)
    case restoreEssentialsThenReviewComplete
}

/// Keeps navigation semantics separate from user-visible button copy. Copy can
/// change without silently turning a purchase into a restore, or vice versa.
enum ArkFileLockedContentPrimaryAction: Equatable, Sendable {
    case regular(title: String)
    case restore(title: String, route: ArkFileLockedContentRestoreRoute)

    var title: String {
        switch self {
        case .regular(let title), .restore(let title, _):
            return title
        }
    }

    var restoreRoute: ArkFileLockedContentRestoreRoute? {
        switch self {
        case .regular:
            return nil
        case .restore(_, let route):
            return route
        }
    }
}

enum ArkFileLockedContentAccessState: Equatable, Sendable {
    case sample
    case installed
    case downloadable
    case locked
}

enum ArkFileContentOpenRoute: Equatable, Sendable {
    case accessPrompt
    case continueOpening

    static func resolve(
        presentation: ArkFileLockedContentPresentation
    ) -> Self {
        presentation.requiresAccessPrompt ? .accessPrompt : .continueOpening
    }
}

/// Keeps the Complete card's primary action consistent across the welcome and
/// library surfaces. A saved purchase should always lead to the per-title
/// manager once interruption and repair work have been handled.
enum ArkFileCompleteManagementRoute: Equatable, Sendable {
    case resumeDownload
    case repairDownload
    case manageDownloads
    case reviewPurchase

    static func resolve(
        hasSavedCompleteAccess: Bool,
        hasInterruptedCompleteDownload: Bool,
        hasResumableCompleteDownload: Bool,
        needsCompleteRepair: Bool
    ) -> ArkFileCompleteManagementRoute {
        if hasInterruptedCompleteDownload || hasResumableCompleteDownload {
            return .resumeDownload
        }
        if needsCompleteRepair {
            return .repairDownload
        }
        return hasSavedCompleteAccess ? .manageDownloads : .reviewPurchase
    }
}

struct ArkFileLockedContentPresentation: Equatable, Sendable {
    let resolvedTier: ArkFileContentTier
    let accessState: ArkFileLockedContentAccessState
    let packName: String
    let fullPackName: String
    let primaryActionTitle: String
    let isPrimaryActionEnabled: Bool
    let isPrimaryActionRestore: Bool
    let primaryRestoreRoute: ArkFileLockedContentRestoreRoute?
    let restoreActionTitle: String
    let isRestoreAvailable: Bool
    let isRestoreActionEnabled: Bool
    let canDownloadOnlyThisTitle: Bool
    let message: String

    var statusTitle: String {
        switch accessState {
        case .sample: "Included · Ready offline"
        case .installed: "Ready offline"
        case .downloadable: "Included with \(packName) · Not downloaded"
        case .locked: "Requires \(packName)"
        }
    }

    var statusSystemImage: String {
        switch accessState {
        case .sample, .installed: "checkmark.circle.fill"
        case .downloadable: "arrow.down.circle"
        case .locked: "lock.fill"
        }
    }

    var requiresAccessPrompt: Bool {
        accessState == .locked || accessState == .downloadable
    }

    static func resolve(
        item: ArkFileLibraryContentItem,
        input: ArkFileLockedContentResolutionInput
    ) -> ArkFileLockedContentPresentation {
        let resolvedTier = item.requiredTier
        let packName = ArkFileContentPackDisplayName.name(for: resolvedTier)
        let fullPackName = "ArkFile \(packName)"
        let hasSavedAccess = input.hasSavedAccess(for: resolvedTier)
        let accessState: ArkFileLockedContentAccessState
        if item.isSampleContent {
            accessState = .sample
        } else if item.isInstalled {
            // A readable installed item represents a durable local commit.
            // Commerce loss can stop future acquisition but does not relock
            // bytes already verified on this device.
            accessState = .installed
        } else if input.isAccessRevoked(for: resolvedTier) {
            accessState = .locked
        } else if hasSavedAccess {
            accessState = .downloadable
        } else {
            accessState = .locked
        }

        let primaryAction = primaryAction(
            tier: resolvedTier,
            input: input
        )
        let primaryRestoreRoute = primaryAction.restoreRoute
        let isPrimaryActionRestore = primaryRestoreRoute != nil
        let hasSeparateRestoreAction = !isPrimaryActionRestore
            && (input.hasAuthoritativeNoPurchase
                || (resolvedTier == .complete ? !input.isBusy : input.canRestoreLite))
        return ArkFileLockedContentPresentation(
            resolvedTier: resolvedTier,
            accessState: accessState,
            packName: packName,
            fullPackName: fullPackName,
            primaryActionTitle: primaryAction.title,
            isPrimaryActionEnabled: !input.blocksForApplePurchaseCheck && (!isPrimaryActionRestore || !input.isBusy),
            isPrimaryActionRestore: isPrimaryActionRestore,
            primaryRestoreRoute: primaryRestoreRoute,
            restoreActionTitle: resolvedTier == .complete ? "Restore Complete Purchase" : "Restore Purchases",
            isRestoreAvailable: hasSeparateRestoreAction,
            isRestoreActionEnabled: !input.isBusy,
            canDownloadOnlyThisTitle: canDownloadOnlyThisTitle(
                item: item,
                tier: resolvedTier,
                input: input
            ),
            message: message(
                item: item,
                tier: resolvedTier,
                fullPackName: fullPackName,
                input: input
            )
        )
    }

    private static func primaryAction(
        tier: ArkFileContentTier,
        input: ArkFileLockedContentResolutionInput
    ) -> ArkFileLockedContentPrimaryAction {
        if input.blocksForApplePurchaseCheck {
            return .regular(title: "Checking Apple Purchases…")
        }
        if input.isAccessRevoked(for: tier) {
            if input.hasAuthoritativeNoPurchase {
                // A completed empty restore opens shopping without restoring
                // acquisition flags or changing readable installed content.
                return .regular(title: "Compare Packs")
            }
            return .restore(
                title: tier == .complete ? "Restore Complete Purchase" : "Restore Purchases",
                route: .restore(tier)
            )
        }
        if input.hasSavedAccess(for: tier) {
            return .regular(title: "Choose Downloads")
        }
        if tier == .complete {
            return .regular(
                title: input.hasSavedLiteAccess ? "Upgrade to Complete" : "View Complete"
            )
        }
        return .regular(title: "View Essentials")
    }

    private static func canDownloadOnlyThisTitle(
        item: ArkFileLibraryContentItem,
        tier: ArkFileContentTier,
        input: ArkFileLockedContentResolutionInput
    ) -> Bool {
        !item.isInstalled
            && !item.isSampleContent
            && !input.blocksForApplePurchaseCheck
            && !input.isAccessRevoked(for: tier)
            && input.hasSavedAccess(for: tier)
    }

    private static func message(
        item: ArkFileLibraryContentItem,
        tier: ArkFileContentTier,
        fullPackName: String,
        input: ArkFileLockedContentResolutionInput
    ) -> String {
        let title = item.displayName
        if input.blocksForApplePurchaseCheck {
            return "ArkFile is checking this device’s Apple purchases before "
                + "showing whether \(title) is owned. No purchase will start "
                + "while this check is in progress."
        }
        if input.isAccessRevoked(for: tier) {
            if input.hasAuthoritativeNoPurchase {
                return "No purchase was found for this Apple Account. Compare the one-time pack prices to get \(title), or restore with the Apple Account that bought it. Content already installed on this device remains readable."
            }
            let packName = ArkFileContentPackDisplayName.name(for: tier)
            return "\(title) is part of \(fullPackName), but ArkFile could not confirm active \(packName) access for future downloads. Restore Purchases to re-check access. Valid content already installed on this device remains readable."
        }
        if input.hasSavedAccess(for: tier) {
            return "\(title) is included with \(fullPackName). Download this title to use it offline. You can choose other titles whenever you need them."
        }
        if tier == .complete {
            return "\(title) is included with ArkFile Complete. Complete includes Essentials and additional books, reference works, and regional street maps. Review the one-time price and choose what to download after purchase."
        }
        return "\(title) is included with ArkFile Essentials. Review the one-time price, then choose the titles you want on this device. Complete also includes this title."
    }
}
