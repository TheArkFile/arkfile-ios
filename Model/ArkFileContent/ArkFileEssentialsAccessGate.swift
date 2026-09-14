// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

/// Compatibility facade retained for the readers that historically called the
/// Essentials entitlement gate.
///
/// Read decisions now come only from the durable local install commit. The
/// legacy UserDefaults flags remain visible temporarily so shipped commerce
/// state and older tests can migrate without being mistaken for file access.
enum ArkFileEssentialsAccessGate {
    private static let liteRevocationDefaultsKey = "arkfile.storekit.lite-access-revoked.v1"
    private static let completeRevocationDefaultsKey = "arkfile.storekit.complete-access-revoked.v1"

    static var isRevokedForFileRead: Bool {
        isRevokedForFileRead(tier: .lite)
    }

    static var isCompleteRevokedForFileRead: Bool {
        isRevokedForFileRead(tier: .complete)
    }

    static func isRevokedForFileRead(tier: ArkFileContentTier) -> Bool {
        UserDefaults.standard.bool(forKey: revocationDefaultsKey(for: tier))
    }

    static func setRevokedForFileRead(_ revoked: Bool) {
        setRevokedForFileRead(revoked, tier: .lite)
    }

    static func setRevokedForFileRead(_ revoked: Bool, tier: ArkFileContentTier) {
        if revoked {
            UserDefaults.standard.set(true, forKey: revocationDefaultsKey(for: tier))
        } else {
            UserDefaults.standard.removeObject(forKey: revocationDefaultsKey(for: tier))
        }
    }

    static func clearLegacyReadRevocationFlags() {
        UserDefaults.standard.removeObject(forKey: liteRevocationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: completeRevocationDefaultsKey)
    }

    static func canOpenEssentialsURLSync(_ url: URL) -> Bool {
        ArkFileInstalledContentAccess.canRead(url)
    }

    static func resolvedURLForReadingSync(_ url: URL) -> URL? {
        ArkFileInstalledContentAccess.resolvedURLForReading(url)
    }

    @MainActor
    static func canOpenEssentialsURL(_ url: URL) -> Bool {
        ArkFileInstalledContentAccess.canRead(url)
    }

    @MainActor
    static func resolvedURLForReading(_ url: URL) -> URL? {
        ArkFileInstalledContentAccess.resolvedURLForReading(url)
    }

    static func requiredTierForManagedURLSync(_ url: URL) -> ArkFileContentTier? {
        ArkFileInstalledContentAccess.requiredTier(for: url)
    }

    @MainActor
    static func requiredTierForManagedURL(_ url: URL) -> ArkFileContentTier? {
        ArkFileInstalledContentAccess.requiredTier(for: url)
    }

    @MainActor
    static func isManagedEssentialsURL(_ url: URL) -> Bool {
        ArkFileInstalledContentAccess.isManaged(url)
    }

    private static func revocationDefaultsKey(for tier: ArkFileContentTier) -> String {
        tier == .complete ? completeRevocationDefaultsKey : liteRevocationDefaultsKey
    }
}
