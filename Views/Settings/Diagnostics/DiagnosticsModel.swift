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
import Defaults
import OSLog
import Combine
import SwiftUI

struct DiagnosticItem: Identifiable, Equatable {
    let id: Identifier
    var title: String
    var status: Status
    
    init(id: Identifier, title: String? = nil, status: Status = .initial) {
        self.id = id
        if let title {
            self.title = title
        } else {
            self.title = id.defaultTitle
        }
        self.status = status
    }
    
    enum Status: Equatable {
        case initial
        case inProgress
        case complete(Bool)
        
        var isComplete: Bool {
            if case .complete = self {
                return true
            }
            return false
        }
        
        var systemImage: String {
            switch self {
            case .initial: "circle"
            case .inProgress: "circle.dashed"
            case .complete: "checkmark.circle.fill"
            }
        }
        var tintColor: Color {
            switch self {
            case .initial: .gray
            case .inProgress: .orange
            case .complete: .green
            }
        }
        
        static func from(checkState: ZimIntegrityModel.CheckState) -> Self {
            switch checkState {
            case .enqued: Status.initial
            case .running: Status.inProgress
            case .complete(let isValid): Status.complete(isValid)
            }
        }
    }
    
    enum Identifier: Hashable {
        case integrityCheck
        case integrityZIM(UUID)
        case applicationLogs
        case arkFileState
        case languageSettings
        case listOfZimFiles
        case deviceDetails
        case fileSystemDetails
        
        var defaultTitle: String {
            switch self {
            case .integrityCheck: "Integrity check of ZIM files"
            case .integrityZIM: "Integrity check of ZIM files"
            case .applicationLogs: "Application logs"
            case .arkFileState: "ArkFile account and Essentials state"
            case .languageSettings: "Your language settings"
            case .listOfZimFiles: "List of your ZIM files"
            case .deviceDetails: "Device details"
            case .fileSystemDetails: "File system details"
            }
        }
    }
}

private enum Const {
    static let defaultItems: [DiagnosticItem] = [
        DiagnosticItem(id: .listOfZimFiles),
        DiagnosticItem(id: .integrityCheck),
        DiagnosticItem(id: .arkFileState),
        DiagnosticItem(id: .applicationLogs),
        DiagnosticItem(id: .languageSettings),
        DiagnosticItem(id: .deviceDetails),
        DiagnosticItem(id: .fileSystemDetails)
    ]
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    
    @Published
    var items: [DiagnosticItem] = Const.defaultItems
    
    private var integrityModel = ZimIntegrityModel()
    private var cancellable: AnyCancellable?
    
    func cancel() {
        cancellable?.cancel()
        integrityModel.reset()
        items = Const.defaultItems
        integrityModel = ZimIntegrityModel()
    }
    
    func start(using zimFiles: [ZimFile]) async -> [String] {
        updateItemBy(id: .listOfZimFiles, status: .complete(true))
        updateItemBy(id: .integrityCheck, status: .inProgress)
        cancellable = integrityModel.$checks.sink(receiveValue: { [weak self] (infos: [ZimIntegrityModel.Info]) in
            self?.didReceive(checkInfos: infos)
        })
        
        await integrityModel.check(zimFiles: zimFiles)
        guard !Task.isCancelled else { return [] }
        updateItemBy(id: .arkFileState, status: .inProgress)
        guard !Task.isCancelled else { return [] }
        updateItemBy(id: .applicationLogs, status: .inProgress)
        guard !Task.isCancelled else { return [] }
        let entries = await Diagnostics.entriesSeparated()
        guard !Task.isCancelled else { return [] }
        updateItemBy(id: .arkFileState, status: .complete(true))
        updateItemBy(id: .applicationLogs, status: .complete(true))
        updateItemBy(id: .languageSettings, status: .complete(true))
        updateItemBy(id: .deviceDetails, status: .complete(true))
        updateItemBy(id: .fileSystemDetails, status: .complete(true))
        return entries
    }
    
    private func integrityCheckProgress(title: String) {
        items = items.map { item in
            if item.id == .integrityCheck {
                var newItem = item
                newItem.title = title
                newItem.status = .inProgress
                return newItem
            } else {
                return item
            }
        }
    }
    
    private func updateItemBy(id: DiagnosticItem.Identifier, status: DiagnosticItem.Status) {
        items = items.map { item in
            if item.id == id {
                var newItem = item
                newItem.status = status
                return newItem
            } else {
                return item
            }
        }
    }
    
    private func didReceive(checkInfos: [ZimIntegrityModel.Info]) {
        if let integrityIndex = items.firstIndex(where: { $0.id == .integrityCheck }) {
            items.remove(at: integrityIndex)
        }
        for check in checkInfos {
            if let index = items.firstIndex(where: { $0.id == .integrityZIM(check.id) }) {
                var item: DiagnosticItem = items[index]
                item.status = .from(checkState: check.state)
                items[index] = item
            } else {
                let title = LocalString.zim_file_integrity_check_in_progress(withArgs: check.zimFile.name)
                let newItem = DiagnosticItem(id: .integrityZIM(check.id),
                                             title: title,
                                             status: .from(checkState: check.state))
                let insertIndex: Int = items.firstIndex(where: { $0.id == .applicationLogs }) ?? 0
                items.insert(newItem, at: insertIndex)
            }
        }
    }
}

enum Diagnostics {
    
    /// Log the os and app related infos
    static func start() async {
        let device = await MainActor.run { Device.current }
        Log.Environment.notice("app: \(appVersion(), privacy: .public)")
        Log.Environment.notice("os: \(osName(device: device), privacy: .public)")
        Log.Environment.notice("\(languageCurrent(), privacy: .public)")
        Log.Environment.notice("\(libraryLanguageCodes(), privacy: .public)")
    }
    
    static func entriesSeparated() async -> [String] {
#if os(macOS)
        guard !Task.isCancelled else { return [] }
        await MacUser.isUserAdmin()
#endif
        guard !Task.isCancelled else { return [] }
        DownloadDiagnostics.testWritingAFile()
#if os(iOS)
        await ArkFileDiagnosticSnapshot.log()
#endif
        
        guard !Task.isCancelled else { return [] }
        guard let logStore = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? logStore.getEntries(
                matching: NSPredicate(format: "subsystem == %@", KiwixLogger.subsystem)
              ) else {
            Log.Environment.error("couldn't collect logs")
            return []
        }
        
        var logs: [String] = []
        for entry in entries.makeIterator() {
            let line = "\(entry.date.ISO8601Format()); \(entry.composedMessage)"
            logs.append(ArkFileDiagnosticPrivacy.sanitizeForExport(line))
        }
        return logs
    }
    
    public static func fileName(using date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withDashSeparatorInDate, .withFullDate]
        let dateString = formatter.string(from: date)
        return "arkfile_diagnostic_\(dateString)"
    }
    
    private static func appVersion() -> String {
        let unknown = "unknown"
        let bundle = Bundle.main
        let infoDict = bundle.infoDictionary
        
        let bundleIdentifier = bundle.bundleIdentifier ?? unknown
        let releaseVersion = (infoDict?["CFBundleShortVersionString"] as? String) ?? unknown
        let buildNumber = (infoDict?["CFBundleVersion"] as? String) ?? unknown
        
        return "\(bundleIdentifier): \(releaseVersion) (\(buildNumber))"
    }
    
    private static func osName(device: Device) -> String {
        let deviceType = device.rawValue
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(deviceType): \(osVersion)"
    }
    
    private static func languageCurrent() -> String {
        let current = Locale.current.language.languageCode?.identifier ?? "unknown"
        return "Current language: \(current)"
    }
    
    private static func libraryLanguageCodes() -> String {
        let languageCodes: Set<String> = Defaults[.libraryLanguageCodes]
        return "Library language codes: \(languageCodes.joined(separator: ", "))"
    }
    
}

/// Defense in depth for the user-reviewed diagnostic export. Producers should
/// still avoid logging secrets or personal data, but this strips common values
/// that can arrive through system and dependency error messages before a report
/// leaves the device.
enum ArkFileDiagnosticPrivacy {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"(?i)\b(?:authorization|bearer|token|secret|password|api[_ -]?key)\s*[:=]\s*(?:bearer\s+)?[^\s,;]+"#, "credential=[REDACTED]"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, "[REDACTED-JWS]"),
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[REDACTED-EMAIL]"),
        (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#, "[REDACTED-ID]"),
        (#"(?i)(/points/)[+-]?\d{1,3}(?:\.\d+)?\s*,\s*[+-]?\d{1,3}(?:\.\d+)?"#, "$1[REDACTED-COORDINATES]"),
        (#"(?i)\b(lat(?:itude)?|lon(?:gitude)?|lng)\s*[:=]\s*[+-]?\d{1,3}(?:\.\d+)?"#, "$1=[REDACTED-COORDINATE]"),
        (#"(?<![A-Za-z0-9.])[-+]?(?:(?:[0-8]?\d)(?:\.\d{3,})|90(?:\.0{3,}))\s*,\s*[-+]?(?:(?:(?:1[0-7]\d|[0-9]?\d)(?:\.\d{3,}))|180(?:\.0{3,}))(?![A-Za-z0-9.])"#, "[REDACTED-COORDINATES]"),
        (#"(?i)(\b(?:(?:saved[ _-]?weather[ _-]?)?(?:location|place)[ _-]?(?:label|name)|saved[ _-]?weather[ _-]?(?:location|place))\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^,;\r\n]+)"#, "$1[REDACTED-PLACE]"),
        (#"(?i)(\b(?:alert[ _-]?(?:headline|description|instruction|text)|raw[ _-]?alert[ _-]?text)\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^,;\r\n]+)"#, "$1[REDACTED-ALERT-TEXT]"),
        (#"(?i)(\b(?:raw[ _-]?payload[ _-]?url|alert[ _-]?(?:payload[ _-]?)?url)\s*[:=]\s*)[^\s,;\r\n]+"#, "$1[REDACTED-URL]"),
        (#"(?im)(\b(?:raw[ _-]?(?:alert[ _-]?)?payload|alert[ _-]?payload)\s*[:=]\s*).*$"#, "$1[REDACTED-PAYLOAD]"),
        (#"(?i)file://[^\s,;\]\)]+"#, "file://[REDACTED-PATH]"),
        (#"(?<![:A-Za-z0-9])/(?:private|var|Users|Volumes|tmp|Library|Applications?)(?:/[^\s,;\]\)]+)+"#, "[REDACTED-PATH]"),
        (#"(?i)(https?://[^\s?]+)\?[^\s]+"#, "$1?[REDACTED-QUERY]"),
        (#"\b[A-Za-z0-9+/=_-]{96,}\b"#, "[REDACTED-VALUE]")
    ]

    static func sanitizeForExport(_ value: String) -> String {
        replacements.reduce(value) { result, replacement in
            result.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.template,
                options: .regularExpression
            )
        }
    }
}

#if os(iOS)
@MainActor
private enum ArkFileDiagnosticSnapshot {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func log() async {
        let installer = ArkFileContentPackInstaller.shared
        let library = ArkFileLocalContentLibrary.shared
        await library.refresh()

        let state = installer.state
        let progress = state.progressFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "unknown"
        let markerExists = fileExists(
            in: library.contentRoot,
            named: ArkFileContentPackInstaller.contentRootMarkerFileName
        )
        let manifestExists = fileExists(
            in: library.contentRoot,
            named: ArkFileContentPackInstaller.contentRootManifestFileName
        )
        let readableFileCount = library.contentRoot.map(readableFileCount(in:)) ?? 0
        let categorySummary = library.libraryCategories
            .map { category in
                let installed = category.items.filter(\.isInstalled).count
                return "\(category.displayName): \(installed)/\(category.items.count)"
            }
            .joined(separator: "; ")

        Log.Environment.notice(
            "ArkFile account feature enabled=\(FeatureFlags.arkFileUnifiedAccountUI, privacy: .public), developerToken=\(Brand.hasDeveloperContentAuthToken, privacy: .public)"
        )
        Log.Environment.notice(
            "ArkFile Essentials installer: phase=\(state.phase.rawValue, privacy: .public), tier=\(state.tier?.rawValue ?? "none", privacy: .public), progress=\(progress, privacy: .public), completed=\(byteFormatter.string(fromByteCount: state.completedBytes), privacy: .public), total=\(byteFormatter.string(fromByteCount: state.totalBytes), privacy: .public), installedAt=\(state.installedAt?.ISO8601Format() ?? "none", privacy: .public), needsRepair=\(installer.needsLiteRepair, privacy: .public), hasResumableDownload=\(installer.hasResumableLiteDownload, privacy: .public), hasError=\((state.errorMessage?.isEmpty == false), privacy: .public)"
        )
        Log.Environment.notice(
            "ArkFile local library: contentRootPresent=\((library.contentRoot != nil), privacy: .public), markerExists=\(markerExists, privacy: .public), manifestExists=\(manifestExists, privacy: .public), readableFiles=\(readableFileCount, privacy: .public), installedLibraryItems=\(library.installedLibraryItemCount, privacy: .public), installedCatalogItems=\(library.installedCatalogItemCount, privacy: .public), bundledCatalogItems=\(library.bundledCatalogItemCount, privacy: .public), sampleItems=\(library.sampleLibraryItemCount, privacy: .public), lockedItems=\(library.lockedLibraryItemCount, privacy: .public)"
        )
        Log.Environment.notice("ArkFile local library categories: \(categorySummary, privacy: .public)")

        let weather = ArkFileSavedWeatherController.shared
        await weather.load()
        let weatherSnapshot = weather.snapshot
        let hourly = weatherSnapshot?.hourly
        let daily = weatherSnapshot?.daily
        let alerts = weatherSnapshot?.alerts
        let climate = weatherSnapshot?.climateOutlooks
        Log.Environment.notice(
            "ArkFile Saved Weather (redacted): featureEnabled=\(FeatureFlags.savedWeather, privacy: .public), configured=\((weather.settings.savedLocation != nil), privacy: .public), automatic=\(weather.settings.automaticRefreshEnabled, privacy: .public), wifiOnly=\(weather.settings.refreshOnWiFiOnly, privacy: .public), settingsSchema=\(weather.settings.schemaVersion, privacy: .public), snapshotSchema=\(weatherSnapshot?.schemaVersion ?? 0, privacy: .public), cacheBytes=\(weather.storageSizeBytes, privacy: .public), connectivity=\(weather.connectivity.rawValue, privacy: .public), lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled, privacy: .public), unreadableCache=\(weather.hasUnreadableSavedWeatherData, privacy: .public), hourly=\(hourly?.availability.rawValue ?? "none", privacy: .public)/\(hourly?.failure?.kind.rawValue ?? "none", privacy: .public)/count=\(hourly?.value?.count ?? 0, privacy: .public), daily=\(daily?.availability.rawValue ?? "none", privacy: .public)/\(daily?.failure?.kind.rawValue ?? "none", privacy: .public)/count=\(daily?.value?.count ?? 0, privacy: .public), alerts=\(alerts?.availability.rawValue ?? "none", privacy: .public)/\(alerts?.failure?.kind.rawValue ?? "none", privacy: .public)/count=\(alerts?.value?.count ?? 0, privacy: .public), climate=\(climate?.availability.rawValue ?? "none", privacy: .public)/\(climate?.failure?.kind.rawValue ?? "none", privacy: .public)/count=\(climate?.value?.count ?? 0, privacy: .public)"
        )
        let weatherDiagnostics = weather.redactedDiagnosticsText()
            .replacingOccurrences(of: "\n", with: "; ")
        Log.Environment.notice(
            "\(weatherDiagnostics, privacy: .public)"
        )
    }

    private static func fileExists(in root: URL?, named fileName: String) -> Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(fileName).fileSystemPath)
    }

    private static func readableFileCount(in root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            count += 1
        }
        return count
    }
}
#endif
