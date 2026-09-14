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
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension URL: @retroactive Identifiable {
    public var id: String {
        self.absoluteString
    }
}

extension SwiftUI.View {
    func modify<T: View>(@ViewBuilder _ modifier: (Self) -> T) -> some View {
        modifier(self)
    }
}

/// Brings size classes to macOS, with regular as defaults
#if os(macOS)
enum UserInterfaceSizeClass {
    case compact
    case regular
}
struct HorizontalSizeClassEnvironmentKey: EnvironmentKey {
    static let defaultValue: UserInterfaceSizeClass = .regular
}
struct VerticalSizeClassEnvironmentKey: EnvironmentKey {
    static let defaultValue: UserInterfaceSizeClass = .regular
}
extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass {
        get { self[HorizontalSizeClassEnvironmentKey.self] }
        set { self[HorizontalSizeClassEnvironmentKey.self] = newValue }
    }
    var verticalSizeClass: UserInterfaceSizeClass {
        get { return self[VerticalSizeClassEnvironmentKey.self] }
        set { self[VerticalSizeClassEnvironmentKey.self] = newValue }
    }
}
#endif

/// Ports theme adaptive background colors to SwiftUI
extension Color {
    #if os(macOS)
    static let background = Color(NSColor.windowBackgroundColor)
    static let secondaryBackground = Color(NSColor.underPageBackgroundColor)
    static let tertiaryBackground = Color(NSColor.controlBackgroundColor)
    #elseif os(iOS)
    static let background = Color(UIColor.systemBackground)
    static let secondaryBackground = Color(UIColor.secondarySystemBackground)
    static let tertiaryBackground = Color(UIColor.tertiarySystemBackground)
    #endif

    #if os(iOS)
    private static func arkAdaptiveColor(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat),
        dark: (red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat)
    ) -> Color {
        Color(UIColor { traits in
            let color = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.opacity
            )
        })
    }
    #else
    private static func arkAdaptiveColor(
        light: (red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat),
        dark _: (red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat)
    ) -> Color {
        Color(
            red: Double(light.red),
            green: Double(light.green),
            blue: Double(light.blue),
            opacity: Double(light.opacity)
        )
    }
    #endif

    static let arkSand = Color(red: 248 / 255, green: 233 / 255, blue: 175 / 255)
    static let arkWheat = Color(red: 242 / 255, green: 201 / 255, blue: 121 / 255)
    static let arkSun = Color(red: 233 / 255, green: 194 / 255, blue: 30 / 255)
    static let arkGold = Color(red: 227 / 255, green: 143 / 255, blue: 29 / 255)
    static let arkAmber = Color(red: 182 / 255, green: 82 / 255, blue: 24 / 255)
    static let arkTaupe = Color(red: 108 / 255, green: 90 / 255, blue: 59 / 255)
    static let arkReef = Color(red: 52 / 255, green: 106 / 255, blue: 84 / 255)
    static let arkWood = Color(red: 134 / 255, green: 69 / 255, blue: 31 / 255)
    static let arkTeal = Color(red: 18 / 255, green: 63 / 255, blue: 62 / 255)
    static let arkInk = Color(red: 43 / 255, green: 23 / 255, blue: 14 / 255)
    static let arkSurface = Color(red: 1.0, green: 253 / 255, blue: 246 / 255)
    static let arkBorder = Color(red: 108 / 255, green: 90 / 255, blue: 59 / 255).opacity(0.25)

    static let arkAppBackground = arkAdaptiveColor(
        light: (248 / 255, 233 / 255, 175 / 255, 1),
        dark: (15 / 255, 29 / 255, 27 / 255, 1)
    )
    static let arkMapBackground = arkAdaptiveColor(
        light: (0.77, 0.88, 0.91, 1),
        dark: (15 / 255, 29 / 255, 27 / 255, 1)
    )
    static let arkAppSurface = arkAdaptiveColor(
        light: (1, 253 / 255, 246 / 255, 1),
        dark: (18 / 255, 26 / 255, 25 / 255, 1)
    )
    static let arkAppSurfaceSecondary = arkAdaptiveColor(
        light: (248 / 255, 233 / 255, 175 / 255, 1),
        dark: (24 / 255, 34 / 255, 32 / 255, 1)
    )
    static let arkTextPrimary = arkAdaptiveColor(
        light: (43 / 255, 23 / 255, 14 / 255, 1),
        dark: (241 / 255, 231 / 255, 212 / 255, 1)
    )
    static let arkTextMuted = arkAdaptiveColor(
        light: (108 / 255, 90 / 255, 59 / 255, 1),
        dark: (203 / 255, 180 / 255, 140 / 255, 1)
    )
    static let arkPrimary = arkAdaptiveColor(
        light: (18 / 255, 63 / 255, 62 / 255, 1),
        dark: (52 / 255, 106 / 255, 84 / 255, 1)
    )
    /// Foreground links and icons need a brighter dark-mode color than filled buttons.
    static let arkInteractiveForeground = arkAdaptiveColor(
        light: (18 / 255, 63 / 255, 62 / 255, 1),
        dark: (141 / 255, 206 / 255, 176 / 255, 1)
    )
    static let arkLockedForeground = arkAdaptiveColor(
        light: (151 / 255, 65 / 255, 18 / 255, 1),
        dark: (240 / 255, 172 / 255, 105 / 255, 1)
    )
    static let arkPrimaryHover = arkAdaptiveColor(
        light: (52 / 255, 106 / 255, 84 / 255, 1),
        dark: (62 / 255, 122 / 255, 98 / 255, 1)
    )
    static let arkPrimaryActive = arkAdaptiveColor(
        light: (15 / 255, 53 / 255, 52 / 255, 1),
        dark: (42 / 255, 93 / 255, 75 / 255, 1)
    )
    static let arkAccent = arkAdaptiveColor(
        light: (233 / 255, 194 / 255, 30 / 255, 1),
        dark: (233 / 255, 194 / 255, 30 / 255, 1)
    )
    static let arkAccentSecondary = arkAdaptiveColor(
        light: (182 / 255, 82 / 255, 24 / 255, 1),
        dark: (182 / 255, 82 / 255, 24 / 255, 1)
    )
    static let arkFocusRing = arkAdaptiveColor(
        light: (18 / 255, 63 / 255, 62 / 255, 0.35),
        dark: (233 / 255, 194 / 255, 30 / 255, 0.35)
    )
    static let arkAppBorder = arkAdaptiveColor(
        light: (108 / 255, 90 / 255, 59 / 255, 0.25),
        dark: (248 / 255, 233 / 255, 175 / 255, 0.18)
    )
}

extension Notification.Name {
    static let alert = Notification.Name("alert")
    static let question = Notification.Name("question")
    static let openFiles = Notification.Name("openFiles")
    static let zimIntegrityCheck = Notification.Name("zimIntegrityCheck")
    static let openURL = Notification.Name("openURL")
    static let selectFile = Notification.Name("selectFile")
    static let exportFileData = Notification.Name("exportFileData")
    static let saveContent = Notification.Name("saveContent")
    static let navigateToHotspotSettings = Notification.Name("navigateToHotspotSettings")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let arkFileGoHome = Notification.Name("arkFileGoHome")
    #if os(macOS)
    static let keepOnlyTabs = Notification.Name("keepOnlyTabs")
    static let zimSearch = Notification.Name("zimSearch")
    #endif
    static let goBack = Notification.Name("goBack")
    static let goForward = Notification.Name("goForward")
    #if os(iOS)
    static let openDonations = Notification.Name("openDonations")
    static let hotspotShareURL = Notification.Name("hotspotShareURL")
    #endif
}

extension UTType {
    static let zimFile = UTType(exportedAs: "org.openzim.zim")
}

extension NotificationCenter {
    @MainActor
    static func openURL(
        _ url: URL,
        inNewTab: Bool = false,
        context: OpenURLContext? = nil,
        continuing readerOpenIntent: ArkFileReaderOpenIntent? = nil
    ) {
        let coordinator = ArkFileReaderOpenIntentCoordinator.shared
        let effectiveIntent = readerOpenIntent ?? coordinator.beginForCurrentReader()
        guard coordinator.isCurrent(effectiveIntent) else { return }
        var userInfo: [AnyHashable: Any] = [
            "url": url,
            "inNewTab": inNewTab,
            "arkFileReaderOpenIntent": effectiveIntent
        ]
        if let context {
            userInfo["context"] = context
        }
        NotificationCenter.default.post(
            name: .openURL,
            object: nil,
            userInfo: userInfo
        )
    }
        
    @MainActor
    static func selectFileBy(fileId: UUID) {
        NotificationCenter.default.post(name: .selectFile, object: nil, userInfo: ["fileId": fileId])
    }

    static func openFiles(_ urls: [URL], context: OpenFileContext) {
        NotificationCenter.default.post(name: .openFiles, object: nil, userInfo: ["urls": urls, "context": context])
    }

    static func exportFileData(_ data: FileExportData) {
        NotificationCenter.default.post(name: .exportFileData, object: nil, userInfo: ["data": data])
    }

    static func saveContent(url: URL) {
        NotificationCenter.default.post(name: .saveContent, object: nil, userInfo: ["url": url])
    }
    
    static func navigateToHotspotSettings() {
        if FeatureFlags.hasLibrary {
            NotificationCenter.default.post(name: .navigateToHotspotSettings, object: nil, userInfo: nil)
        }
    }

    static func toggleSidebar() {
        NotificationCenter.default.post(name: .toggleSidebar, object: nil, userInfo: nil)
    }

    #if os(macOS)
    @MainActor static func keepOnlyTabs(_ tabIds: Set<NSManagedObjectID>) {
        NotificationCenter.default.post(name: .keepOnlyTabs,
                                        object: nil,
                                        userInfo: ["tabIds": tabIds])
    }
    #endif
    
    #if os(iOS)
    @MainActor static func openDonations() {
        NotificationCenter.default.post(name: .openDonations, object: nil, userInfo: nil)
    }
    
    @MainActor static func hotspotShare(url: URL) {
        NotificationCenter.default.post(name: .hotspotShareURL, object: nil, userInfo: ["url": url])
    }
    #endif
}
