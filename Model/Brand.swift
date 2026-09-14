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
import os

enum AppType {
    case kiwix
    case custom(zimFileURL: URL)

    static let current = AppType()

    static var isCustom: Bool {
        switch current {
        case .kiwix: return false
        case .custom: return true
        }
    }

    private init() {
        guard let zimFileName: String = Config.value(for: .customZimFile),
              !zimFileName.isEmpty else {
            // it's not a custom app as it has no zim file set
            self = .kiwix
            return
        }
        guard let zimURL: URL = Bundle.main.url(forResource: zimFileName, withExtension: "zim") else {
            fatalError("zim file named: \(zimFileName) cannot be found")
        }
        self = .custom(zimFileURL: zimURL)
    }
}

enum Brand {
    static let appName: String = Config.value(for: .displayName) ?? "Kiwix"
    static let appStoreId: String = Config.value(for: .appStoreID) ?? ""
    static let arkFileSiteURL: String = Config.value(for: .arkFileSiteURL) ?? "https://thearkfile.com"
    static let arkFileContentAuthToken: String = Config.value(for: .arkFileContentAuthToken) ?? ""
    static var hasDeveloperContentAuthToken: Bool {
        !arkFileContentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static var allowsDeveloperFixtureCatalog: Bool {
        #if DEBUG
        Self.shouldAllowDeveloperFixtureCatalog(
            hasDeveloperToken: hasDeveloperContentAuthToken,
            hasExplicitOptIn: ProcessInfo.processInfo.environment["ARKFILE_ALLOW_FIXTURE_CATALOG"] == "1",
            hasTestingArgument: ProcessInfo.processInfo.arguments.contains("testing"),
            siteHost: URL(string: arkFileSiteURL)?.host
        )
        #else
        false
        #endif
    }

    static func shouldAllowDeveloperFixtureCatalog(
        hasDeveloperToken: Bool,
        hasExplicitOptIn: Bool,
        hasTestingArgument: Bool,
        siteHost: String?
    ) -> Bool {
        #if DEBUG
        guard hasDeveloperToken,
              hasExplicitOptIn,
              hasTestingArgument,
              let siteHost else {
            return false
        }
        return ArkFileContentAPI.usesRelaxedDebugNetworking(host: siteHost)
        #else
        return false
        #endif
    }
    static let arkFileLiteProductID: String = Config.value(for: .arkFileLiteProductID) ?? "app.arkfile.ios.lite"
    static let arkFileCompleteProductID: String = Config.value(for: .arkFileCompleteProductID) ?? "app.arkfile.ios.complete"
    static let arkFileCompleteUpgradeProductID: String = Config.value(for: .arkFileCompleteUpgradeProductID) ?? "app.arkfile.ios.complete.upgrade"
    static let loadingLogoImage: String = "welcomeLogo"
    static let loadingLogoSize: CGSize = ImageInfo.sizeOf(imageName: loadingLogoImage)!
    static let hideFindInPage: Bool = Config.value(for: .hideFindInPage) ?? false
    static let hidePrintButton: Bool = Config.value(for: .hidePrintButton) ?? false
    static let hideRandomButton: Bool = Config.value(for: .hideRandomButton) ?? false
    static let hideShareButton: Bool = Config.value(for: .hideShareButton) ?? false
    static let hideTOCButton: Bool = Config.value(for: .hideTOCButton) ?? false

    static let aboutText: String = Config.value(for: .aboutText) ?? LocalString.settings_about_description
    static let aboutWebsite: String = Config.value(for: .aboutWebsite) ?? "https://www.kiwix.org"
    static let sourceWebsite: String = Config.value(for: .sourceWebsite) ?? "https://github.com/kiwix/kiwix-apple"
    static let feedbackEmail: String = Config.value(for: .feedbackEmail) ?? "support@thearkfile.com"
    static let hideRateApp: Bool = Config.value(for: .hideRateApp) ?? false
    // currently only used under the Kiwix brand
    // if this is set to true in Support/Info.plist the support/donation button is hidden (for macOS FTP)
    // if not set, we fall back to false, and display the support/donation button
    // for non Kiwix brands, it has no effect
    static let hideDonation: Bool = Config.value(for: .hideDonation) ?? false
    
    /// Some custom apps (eg: PhET) have a content that collides with immersive reading
    /// we provide an optional way to turn this feature off.
    /// Immersive reading remains enabled by default, unless declared otherwise.
    static let disableImmersiveReading: Bool = Config.value(for: .disableImmersiveReading) ?? false

    static var defaultExternalLinkPolicy: ExternalLinkLoadingPolicy {
        guard let policyString: String = Config.value(for: .externalLinkDefaultPolicy),
              let policy = ExternalLinkLoadingPolicy(rawValue: policyString) else {
            return .alwaysAsk
        }
        return policy
    }

    static var defaultSearchSnippetMode: SearchResultSnippetMode {
        guard FeatureFlags.showSearchSnippetInSettings else {
            // for custom apps, where we do not show this in settings, it should be disabled by default
            return .disabled
        }
        return .matches
    }
}

enum Config: String {

    case appStoreID = "APP_STORE_ID"
    case displayName = "CFBundleDisplayName"

    // this marks if the app is custom or not
    case customZimFile = "CUSTOM_ZIM_FILE"
    case showExternalLinkSettings = "SETTINGS_SHOW_EXTERNAL_LINK_OPTION"
    case externalLinkDefaultPolicy = "SETTINGS_DEFAULT_EXTERNAL_LINK_TO"
    case showSearchSnippetInSettings = "SETTINGS_SHOW_SEARCH_SNIPPET"
    case showSearchSuggestionsSpellChecked = "SHOW_SEARCH_SUGGESTIONS_SPELLCHECKED"
    case aboutText = "CUSTOM_ABOUT_TEXT"
    case aboutWebsite = "CUSTOM_ABOUT_WEBSITE"
    case sourceWebsite = "CUSTOM_SOURCE_WEBSITE"
    case feedbackEmail = "FEEDBACK_EMAIL"
    case arkFileSiteURL = "ARKFILE_SITE_URL"
    case arkFileContentAuthToken = "ARKFILE_CONTENT_AUTH_TOKEN"
    case arkFileLiteProductID = "ARKFILE_LITE_PRODUCT_ID"
    case arkFileCompleteProductID = "ARKFILE_COMPLETE_PRODUCT_ID"
    case arkFileCompleteUpgradeProductID = "ARKFILE_COMPLETE_UPGRADE_PRODUCT_ID"
    case hideKiwixCatalog = "HIDE_KIWIX_CATALOG"
    case hideRateApp = "HIDE_RATE_APP"
    case paymentMerchantID = "PAYMENT_MERCHANT_ID"
    case disableImmersiveReading = "DISABLE_IMMERSIVE_READING"
    case hideDonation = "HIDE_DONATION"
    case hideFindInPage = "HIDE_FIND_IN_PAGE"
    case hidePrintButton = "HIDE_PRINT_BUTTON"
    case hideRandomButton = "HIDE_RANDOM_BUTTON"
    case hideShareButton = "HIDE_SHARE_BUTTON"
    case hideTOCButton = "HIDE_TOC_BUTTON"

    static func value<T>(for key: Config) -> T? where T: LosslessStringConvertible {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[key.rawValue],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let value = T(override) else {
                Log.Branding.error("Invalid environment override for key: \(key.rawValue, privacy: .public)")
                return nil
            }
            return value
        }
        #endif

        guard let object = Bundle.main.object(forInfoDictionaryKey: key.rawValue) else {
            Log.Branding.debug("Missing key from bundle: \(key.rawValue, privacy: .public)")
            return nil
        }
        switch object {
        case let value as T:
            return value
        case let string as String:
            guard let value = T(string) else { fallthrough }
            return value
        default:
            Log.Branding.error("Invalid value type found for key: \(key.rawValue, privacy: .public)")
            return nil
        }
    }
}
