// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation

#if os(iOS)
import UIKit
#endif

/// Central wording policy for user-visible device references.
///
/// Prefer the generic references when the hardware does not change the
/// behavior. Use the form-factor helpers only for real platform differences,
/// such as the name of the Storage screen in Settings.
enum ArkFileDeviceCopy {
    enum FormFactor: Equatable, Sendable {
        case iPhone
        case iPad
        case other
    }

    static let thisDevice = "this device"
    static let thisDeviceCapitalized = "This device"
    static let yourDevice = "your device"
    static let localWebAddressAndQRCode =
        "a local web address and QR code on \(thisDevice)"
    static let compatibleCallingService =
        "a compatible calling service on \(thisDevice)"

    static func productName(for formFactor: FormFactor) -> String {
        switch formFactor {
        case .iPhone:
            "iPhone"
        case .iPad:
            "iPad"
        case .other:
            "device"
        }
    }

    static func thisProductName(for formFactor: FormFactor) -> String {
        "this \(productName(for: formFactor))"
    }

    static func yourProductName(for formFactor: FormFactor) -> String {
        "your \(productName(for: formFactor))"
    }

    static func storageSettingsPath(for formFactor: FormFactor) -> String {
        switch formFactor {
        case .iPhone:
            "Settings › General › iPhone Storage"
        case .iPad:
            "Settings › General › iPad Storage"
        case .other:
            "Settings › General › Storage"
        }
    }

    #if os(iOS)
    @MainActor
    static var currentFormFactor: FormFactor {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            .iPhone
        case .pad:
            .iPad
        default:
            .other
        }
    }

    @MainActor
    static var currentProductName: String {
        productName(for: currentFormFactor)
    }

    @MainActor
    static var currentStorageSettingsPath: String {
        storageSettingsPath(for: currentFormFactor)
    }
    #endif
}
