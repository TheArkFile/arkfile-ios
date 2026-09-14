// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import CoreGraphics

enum ArkFileSavedWeatherLayoutPolicy {
    enum WidthClass: Equatable, Sendable {
        case compact
        case regular
        case unspecified
    }

    static let readableContentMaxWidth: CGFloat = 960
    static let setupColumnMinimumWidth: CGFloat = 320
    static let setupColumnMaximumWidth: CGFloat = 472
    static let setupColumnSpacing: CGFloat = 16
    static let briefingColumnMinimumWidth: CGFloat = 360
    static let briefingColumnMaximumWidth: CGFloat = 472
    static let briefingColumnSpacing: CGFloat = 16
    static let briefingTwoColumnMinimumWidth =
        (briefingColumnMinimumWidth * 2) + briefingColumnSpacing

    static func prefersTwoColumnLocationSetup(
        widthClass: WidthClass,
        isAccessibilitySize: Bool
    ) -> Bool {
        widthClass == .regular && !isAccessibilitySize
    }

    static func prefersTwoColumnBriefing(
        widthClass: WidthClass,
        isAccessibilitySize: Bool,
        availableWidth: CGFloat
    ) -> Bool {
        widthClass == .regular
            && !isAccessibilitySize
            && availableWidth >= briefingTwoColumnMinimumWidth
    }
}
#endif
