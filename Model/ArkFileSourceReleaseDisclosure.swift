// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import CoreFoundation

enum ArkFileSourceReleaseDisclosure: Equatable, Sendable {
    case published(URL)
    case internalTestFlight
    case unavailable

    static func resolve(
        infoDictionary: [String: Any]?,
        sourceWebsite: String
    ) -> Self {
        guard let infoDictionary else {
            return .unavailable
        }

        guard let rawMarker = infoDictionary["TFInternalTestingOnly"] else {
            return .unavailable
        }
        let markerType = CFGetTypeID(rawMarker as CFTypeRef)
        guard markerType == CFBooleanGetTypeID(),
              let internalOnly = rawMarker as? Bool else {
            return .unavailable
        }
        if internalOnly {
            return .internalTestFlight
        }

        guard let sourceURL = URL(string: sourceWebsite),
              sourceURL.scheme?.lowercased() == "https",
              sourceURL.host != nil else {
            return .unavailable
        }
        return .published(sourceURL)
    }

    static var current: Self {
        resolve(
            infoDictionary: Bundle.main.infoDictionary,
            sourceWebsite: Brand.sourceWebsite
        )
    }

    var sourceReleaseURL: URL? {
        guard case let .published(url) = self else {
            return nil
        }
        return url
    }

    var disclosureText: String {
        switch self {
        case let .published(url):
            "Corresponding source code for this app version is published at \(url.absoluteString)."
        case .internalTestFlight:
            "This internal-only TestFlight build may not have a public corresponding-source release."
        case .unavailable:
            "Public corresponding-source release information is unavailable for this build."
        }
    }
}
