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

import SwiftUI
import Defaults

enum PortNumberFormatter {
    static let instance: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

#if os(macOS)
struct ReadingSettings: View {
    @EnvironmentObject private var colorSchemeStore: UserColorSchemeStore
    @Default(.externalLinkLoadingPolicy) private var externalLinkLoadingPolicy
    @Default(.searchResultSnippetMode) private var searchResultSnippetMode
    @Default(.webViewPageZoom) private var webViewPageZoom

    var body: some View {
        let isSnippet = Binding {
            switch searchResultSnippetMode {
            case .matches: return true
            case .disabled: return false
            }
        } set: { isOn in
            searchResultSnippetMode = isOn ? .matches : .disabled
        }
        VStack(spacing: 16) {
            SettingSection(name: LocalString.reading_settings_zoom_title) {
                HStack {
                    Stepper(webViewPageZoom.formatted(.percent), value: $webViewPageZoom, in: 0.5...2, step: 0.05)
                    Spacer()
                    Button(LocalString.reading_settings_zoom_reset_button) {
                        webViewPageZoom = 1
                    }.disabled(webViewPageZoom == 1)
                }
            }
            if FeatureFlags.showExternalLinkOptionInSettings {
                SettingSection(name: LocalString.reading_settings_external_link_title) {
                    Picker(selection: $externalLinkLoadingPolicy) {
                        ForEach(ExternalLinkLoadingPolicy.allCases) { loadingPolicy in
                            Text(loadingPolicy.name).tag(loadingPolicy)
                        }
                    } label: { }
                }
            }
            // Theme
            SettingSection(name: LocalString.theme_settings_title) {
                Picker(selection: $colorSchemeStore.userColorScheme) {
                    ForEach(UserColorScheme.allCases) { colorScheme in
                        Text(colorScheme.name).tag(colorScheme)
                    }
                } label: { }
            }
            
            if FeatureFlags.showSearchSnippetInSettings {
                SettingSection(name: LocalString.reading_settings_search_snippet_title) {
                    Toggle(" ", isOn: isSnippet)
                }
            }
            Spacer()
        }
        .padding()
        .tabItem { Label(LocalString.reading_settings_tab_reading, systemImage: "book") }
    }
}

struct LibrarySettings: View {
    @Default(.libraryAutoRefresh) private var libraryAutoRefresh
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            SettingSection(name: LocalString.library_settings_catalog_title, alignment: .top) {
                HStack(spacing: 6) {
                    Button(LocalString.library_settings_button_refresh_now) {
                        Task { [weak library] in
                            await library?.start(isUserInitiated: true)
                        }
                    }.disabled(library.state == .inProgress)
                    if library.state == .inProgress {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.5).frame(height: 1)
                    }
                    Spacer()
                    if library.state == .error {
                        Text(LocalString.library_refresh_error_retrieve_description).foregroundColor(.red)
                    } else {
                        Text(LocalString.library_settings_last_refresh_text + ":").foregroundColor(.secondary)
                        LibraryLastRefreshTime().foregroundColor(.secondary)
                    }

                }
                VStack(alignment: .leading) {
                    Toggle(LocalString.library_settings_auto_refresh_toggle, isOn: $libraryAutoRefresh)
                    Text(LocalString.library_settings_catalog_warning_text)
                        .foregroundColor(.secondary)
                }
            }
            SettingSection(name: LocalString.library_settings_languages_title, alignment: .top) {
                LanguageSelector()
                    .environmentObject(library)
            }
        }
        .padding()
        .tabItem { Label(LocalString.library_settings_catalog_title, systemImage: "folder.badge.gearshape") }
    }
}

struct HotspotSettings: View {
    
    @State private var portNumber: Int
    @Environment(\.controlActiveState) var controlActiveState
    
    init() {
        self.portNumber = Defaults[.hotspotPortNumber]
    }
    
    var body: some View {
        VStack(spacing: 16) {
            SettingSection(name: LocalString.hotspot_settings_port_number) {
                // on macOS we can always focus on the port input
                // regardless if we come from default settings route
                // or being deeplinked from Hotspot error
                PortInput(focusOnPortInput: true)
                Text(Hotspot.validPortRangeMessage())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .tabItem { Label(LocalString.enum_navigation_item_hotspot, systemImage: "wifi") }
    }
}

#elseif os(iOS)

struct Settings: View {

    let scrollToHotspot: Bool
    @Default(.downloadUsingCellular) private var downloadUsingCellular
    @Default(.externalLinkLoadingPolicy) private var externalLinkLoadingPolicy
    @Default(.libraryAutoRefresh) private var libraryAutoRefresh
    @Default(.searchResultSnippetMode) private var searchResultSnippetMode
    @Default(.webViewPageZoom) private var webViewPageZoom
    @ObservedObject private var liteInstaller = ArkFileContentPackInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var colorSchemeStore: UserColorSchemeStore
    @EnvironmentObject private var library: LibraryViewModel
    @State private var showEssentialsRemovalWarning = false
    @State private var essentialsRemovalResultMessage: String?
    @State private var showEssentialsSelectionReview = false
    @State private var showCompleteSelectionReview = false
    @State private var isAwaitingRestoreOutcome = false
    @State private var showSavedWeather = false
    @State private var savedWeatherStartsChoosingLocation = false

    enum Route {
        case languageSelector, about
    }

    var body: some View {
        Group {
            ScrollViewReader { proxy in
                List {
                    if FeatureFlags.hasLibrary {
                        readingSettings
                        if FeatureFlags.hasCatalog {
                            catalogSettings
                        }
                        downloadSettings
                        essentialsSettings
                        if FeatureFlags.savedWeather {
                            ArkFileSavedWeatherSettingsSection(
                                openWeather: {
                                    savedWeatherStartsChoosingLocation = false
                                    showSavedWeather = true
                                },
                                changeLocation: {
                                    savedWeatherStartsChoosingLocation = true
                                    showSavedWeather = true
                                }
                            )
                        }
                        hotspot.id("hotspot")
                        miscellaneous
                    } else {
                        readingSettings
                        hotspot.id("hotspot")
                        miscellaneous
                    }
                }
                .modifier(ToolbarRoleBrowser())
                .navigationTitle(LocalString.settings_navigation_title)
                .alert(
                    "Remove Downloaded Packs?",
                    isPresented: $showEssentialsRemovalWarning
                ) {
                    Button("Keep Downloads", role: .cancel) {}
                    Button("Remove Downloads", role: .destructive) {
                        Task { @MainActor in
                            await liteInstaller.removeLiteContent()
                            essentialsRemovalResultMessage = liteInstaller.removalFailureMessage
                        }
                    }
                } message: {
                    Text("This removes downloaded ArkFile pack content from this device. Your Apple Account purchases remain yours and can be restored. A title marked “No longer distributed by ArkFile” cannot be downloaded again after removal, so review those titles in Manage Downloads before continuing.")
                }
                .alert(
                    "Removal Notice",
                    isPresented: Binding(
                        get: { essentialsRemovalResultMessage != nil },
                        set: { if !$0 { essentialsRemovalResultMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        essentialsRemovalResultMessage = nil
                    }
                } message: {
                    Text(essentialsRemovalResultMessage ?? "")
                }
                .task {
                    if scrollToHotspot {
                        proxy.scrollTo("hotspot", anchor: .top)
                    }
                }
            }
        }
        .accessibilityIdentifier("arkfile_settings_root")
        .sheet(isPresented: $showEssentialsSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .lite,
                    confirmTitle: "Download Selected",
                    managementMode: true,
                    purpose: .downloadOwnedPack,
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .lite),
                    onConfirm: { result in
                        showEssentialsSelectionReview = false
                        liteInstaller.includeItemsAndDownload(
                            keys: result.selectedMissingItemKeys.sorted(),
                            tier: .lite
                        )
                    },
                    onCancel: {
                        showEssentialsSelectionReview = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCompleteSelectionReview) {
            NavigationStack {
                ArkFileEssentialsSelectionReviewView(
                    tier: .complete,
                    confirmTitle: "Download Selected",
                    managementMode: true,
                    purpose: .downloadOwnedPack,
                    initiallyExcluded: liteInstaller.savedExcludedItemKeys(for: .complete),
                    onConfirm: { result in
                        showCompleteSelectionReview = false
                        liteInstaller.includeItemsAndDownload(
                            keys: result.selectedMissingItemKeys.sorted(),
                            tier: .complete
                        )
                    },
                    onCancel: {
                        showCompleteSelectionReview = false
                    }
                )
            }
        }
        .sheet(
            isPresented: $showSavedWeather,
            onDismiss: {
                savedWeatherStartsChoosingLocation = false
            }
        ) {
            NavigationStack {
                ArkFileSavedWeatherView(
                    contentRoot: ArkFileContentPackInstaller
                        .managedContentRootWithAnyReadableContentIfAvailable(),
                    startsChoosingLocation:
                        savedWeatherStartsChoosingLocation
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            showSavedWeather = false
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .arkFileRestoreOutcomePrompt(
            installer: liteInstaller,
            isAwaitingOutcome: $isAwaitingRestoreOutcome,
            chooseDownloads: chooseDownloadsAfterRestore
        )
        .alert(
            "Restore Status",
            isPresented: Binding(
                get: { liteInstaller.purchaseHelpMessage != nil },
                set: { if !$0 { liteInstaller.dismissPurchaseHelpMessage() } }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissPurchaseHelpMessage()
            }
        } message: {
            Text(liteInstaller.purchaseHelpMessage ?? "")
        }
        .alert(
            "Download Could Not Start",
            isPresented: Binding(
                get: { liteInstaller.downloadFailureMessage != nil },
                set: { if !$0 { liteInstaller.dismissDownloadFailureMessage() } }
            )
        ) {
            Button("OK", role: .cancel) {
                liteInstaller.dismissDownloadFailureMessage()
            }
        } message: {
            Text(liteInstaller.downloadFailureMessage ?? "")
        }
    }

    var readingSettings: some View {
        let isSnippet = Binding {
            switch searchResultSnippetMode {
            case .matches: return true
            case .disabled: return false
            }
        } set: { isOn in
            searchResultSnippetMode = isOn ? .matches : .disabled
        }
        return Section(LocalString.reading_settings_tab_reading) {
            // Theme
            Picker(LocalString.theme_settings_title, selection: $colorSchemeStore.userColorScheme) {
                ForEach(UserColorScheme.allCases) { colorScheme in
                    Text(colorScheme.name).tag(colorScheme)
                }
            }
            
            Stepper(value: $webViewPageZoom, in: 0.5...2, step: 0.05) {
                Text(LocalString.reading_settings_zoom_title +
                     ": \(Formatter.percent.string(from: NSNumber(value: webViewPageZoom)) ?? "")")
            }
            if FeatureFlags.showExternalLinkOptionInSettings {
                Picker(LocalString.reading_settings_external_link_title, selection: $externalLinkLoadingPolicy) {
                    ForEach(ExternalLinkLoadingPolicy.allCases) { loadingPolicy in
                        Text(loadingPolicy.name).tag(loadingPolicy)
                    }
                }
            }
            if FeatureFlags.showSearchSnippetInSettings {
                Toggle(LocalString.reading_settings_search_snippet_title, isOn: isSnippet)
            }
        }
    }

    var downloadSettings: some View {
        Section {
            Toggle(LocalString.library_settings_toggle_cellular, isOn: $downloadUsingCellular)
        } footer: {
            Text(LocalString.library_settings_new_download_task_description)
        }
    }

    @ViewBuilder
    var essentialsSettings: some View {
        let showsRemoval = liteInstaller.hasInstalledOrPartialContent || liteInstaller.state.phase.isBusy
        Section {
            Button {
                if liteInstaller.restoreOwnedPacks() {
                    isAwaitingRestoreOutcome = true
                }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise.circle")
            }
            .disabled(liteInstaller.isBusy)
            Button {
                UserDefaults.standard.set(
                    false,
                    forKey: ArkFileOnboardingView.completedDefaultsKey
                )
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(
                        name: .arkFileReplayOnboarding,
                        object: nil
                    )
                }
            } label: {
                Label("Replay Introduction", systemImage: "sparkles.rectangle.stack")
            }
            if showsRemoval {
                Button(role: .destructive) {
                    showEssentialsRemovalWarning = true
                } label: {
                    Label("Remove Downloaded Packs from This Device", systemImage: "trash")
                }
                .disabled(liteInstaller.isBusy)
            }
        } header: {
            Text("ArkFile Packs")
        } footer: {
            Text("Restore Purchases checks the Apple Account that bought ArkFile Essentials or Complete and will not charge you again. Restoring access never starts a download; ArkFile asks what you want afterward. Removing packs clears only the downloaded offline content from this device.")
        }
    }

    private func chooseDownloadsAfterRestore(outcome: ArkFileContentRestoreOutcome) {
        DispatchQueue.main.async {
            if outcome.tier == .complete {
                showCompleteSelectionReview = true
            } else {
                showEssentialsSelectionReview = true
            }
        }
    }

    var catalogSettings: some View {
        Section {
            NavigationLink {
                LanguageSelector()
            } label: {
                SelectedLanaguageLabel()
            }.disabled(library.state != .complete)
            HStack {
                if library.state == .error {
                    Text(LocalString.library_refresh_error_retrieve_description).foregroundColor(.red)
                } else {
                    Text(LocalString.catalog_settings_last_refresh_text)
                    Spacer()
                    LibraryLastRefreshTime().foregroundColor(.secondary)
                }
            }
            if library.state == .inProgress {
                HStack {
                    Text(LocalString.catalog_settings_refreshing_text).foregroundColor(.secondary)
                    Spacer()
                    ProgressView().progressViewStyle(.circular)
                }
            } else {
                Button(LocalString.catalog_settings_refresh_now_button) {
                    Task { [weak library] in
                        await library?.start(isUserInitiated: true)
                    }
                }
            }
            Toggle(LocalString.catalog_settings_auto_refresh_toggle, isOn: $libraryAutoRefresh)
        } header: {
            Text(LocalString.catalog_settings_header_text)
        } footer: {
            Text(LocalString.catalog_settings_footer_text)
        }
    }

    var miscellaneous: some View {
        Section(LocalString.settings_miscellaneous_title) {
            Button(LocalString.settings_miscellaneous_button_feedback) {
                UIApplication.shared.open(URL(string: "mailto:\(Brand.feedbackEmail)")!)
            }
            if !Brand.hideRateApp {
                Button(LocalString.settings_miscellaneous_button_rate_app) {
                    let url = URL(appStoreReviewForName: Brand.appName.lowercased(),
                                  appStoreID: Brand.appStoreId)
                    UIApplication.shared.open(url)
                }
            }
            if FeatureFlags.hasLibrary {
                NavigationLink("Diagnostic report") { DiagnosticsView() }
            }
            NavigationLink(LocalString.settings_miscellaneous_navigation_about) { About() }
        }
    }
    
    var hotspot: some View {
        Section {
            PortInput(focusOnPortInput: scrollToHotspot)
        } header: {
            Text(LocalString.enum_navigation_item_hotspot)
        } footer: {
            Text(Hotspot.validPortRangeMessage())
        }
    }
}

private struct SelectedLanaguageLabel: View {
    @Default(.libraryLanguageCodes) private var languageCodes

    var body: some View {
        HStack {
            Text(LocalString.settings_selected_language_title)
            Spacer()
            if languageCodes.count == 1,
               let languageCode = languageCodes.first,
                let languageName = Locale.current.localizedString(forLanguageCode: languageCode) {
                Text(languageName).foregroundColor(.secondary)
            } else if languageCodes.count > 1 {
                Text("\(languageCodes.count)").foregroundColor(.secondary)
            }
        }
    }
}
#endif
