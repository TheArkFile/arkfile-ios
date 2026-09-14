// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

enum ArkFileHomeOwnershipMode: Equatable, Sendable {
    case prospective
    case essentialsOwner
    case completeOwner
}

/// Keeps acquisition copy out of an existing owner's Home experience.
///
/// This state describes confirmed access, not local file authority. Downloaded
/// content remains readable independently of StoreKit, while the Home purchase
/// and upgrade affordances follow the access currently saved for this device.
struct ArkFileHomePresentation: Equatable, Sendable {
    let mode: ArkFileHomeOwnershipMode
    let hasLocalPaidContent: Bool

    static func resolve(
        hasEssentialsAccess: Bool,
        hasCompleteAccess: Bool,
        hasLocalPaidContent: Bool = false
    ) -> ArkFileHomePresentation {
        if hasCompleteAccess {
            return ArkFileHomePresentation(mode: .completeOwner, hasLocalPaidContent: hasLocalPaidContent)
        }
        if hasEssentialsAccess {
            return ArkFileHomePresentation(mode: .essentialsOwner, hasLocalPaidContent: hasLocalPaidContent)
        }
        return ArkFileHomePresentation(mode: .prospective, hasLocalPaidContent: hasLocalPaidContent)
    }

    var showsAcquisitionIntroduction: Bool {
        mode == .prospective && !hasLocalPaidContent
    }

    var heroTitle: String {
        switch mode {
        case .prospective:
            "Your Offline Library"
        case .essentialsOwner:
            "Your Essentials Library"
        case .completeOwner:
            "Your Complete Library"
        }
    }

    var heroCopy: String {
        switch mode {
        case .prospective:
            "Choose Essentials or Complete to build your offline library. Download only the titles and maps you want."
        case .essentialsOwner:
            "ArkFile Essentials is yours. Manage what stays on this device, or upgrade to Complete when you need the full library."
        case .completeOwner:
            "ArkFile Complete is yours. Manage which titles and regional maps stay on this device for offline use."
        }
    }

    var heroAccessibilityIdentifier: String {
        switch mode {
        case .prospective:
            "arkfile_acquisition_hero"
        case .essentialsOwner:
            "arkfile_essentials_owner_hero"
        case .completeOwner:
            "arkfile_complete_owner_hero"
        }
    }

    var showsAcquisitionArtwork: Bool {
        mode == .prospective
    }

    var showsPackComparison: Bool {
        mode != .completeOwner
    }

    var showsCompleteOwnerDashboard: Bool {
        mode == .completeOwner
    }

    var showsIncludedSamplesCallout: Bool {
        mode == .prospective
    }

    var showsStandardPackSection: Bool {
        mode != .completeOwner
    }
}

/// Formats only the file-derived titles that ArkFile itself records. Article
/// titles from ZIM and HTML readers retain their original wording.
struct ArkFileHomeReadingPresentation: Equatable {
    let title: String
    let subtitle: String?

    static func make(
        articleTitle: String,
        fileName: String,
        relativePath: String,
        contentType: ArkFileLocalContentType,
        pageNumber: Int?
    ) -> Self {
        let fileTitle = ArkFileContentDisplayName.displayName(
            for: fileName,
            relativePath: relativePath
        )
        if articleTitle.isEmpty || articleTitle == fileName {
            return Self(title: fileTitle, subtitle: nil)
        }
        if contentType == .pdf, let pageNumber,
           articleTitle == "\(fileName) (Page \(pageNumber))" {
            return Self(title: "\(fileTitle) (Page \(pageNumber))", subtitle: nil)
        }
        return Self(title: articleTitle, subtitle: articleTitle == fileTitle ? nil : fileTitle)
    }
}
