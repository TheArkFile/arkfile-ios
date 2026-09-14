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

import CoreKiwix

struct About: View {
    @State private var dependencies = [Dependency]()
    @State private var externalLinkURL: URL?

    var body: some View {
        #if os(macOS)
        VStack(spacing: 16) {
            SettingSection(name: LocalString.settings_about_title) {
                about
                ourWebsite
                privacyPolicy
            }
            SettingSection(name: LocalString.settings_about_release) {
                release
                legalNotice
                HStack {
                    source
                    license
                }
                HStack {
                    openSource
                    contentLicenses
                }
            }
            SettingSection(name: LocalString.settings_about_dependencies, alignment: .top) {
                Table(dependencies) {
                    TableColumn(LocalString.settings_about_dependencies_name, value: \.name)
                    TableColumn(LocalString.settings_about_dependencies_license) { dependency in
                        Text(dependency.license ?? "")
                    }
                    TableColumn(LocalString.settings_about_dependencies_version, value: \.version)
                }.tableStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
        .padding()
        .tabItem { Label(LocalString.settings_about_title, systemImage: "info.circle") }
        .task { await getDependencies() }
        .onChange(of: externalLinkURL) { _, url in
            guard let url = url else { return }
            NSWorkspace.shared.open(url)
        }
        #elseif os(iOS)
        List {
            Section {
                about
                ourWebsite
            }
            Section(LocalString.settings_about_release) {
                release
                legalNotice
                appVersion
                buildNumber
                source
                license
                openSource
                contentLicenses
                privacyPolicy
            }
            Section(LocalString.settings_about_dependencies) {
                ForEach(dependencies) { dependency in
                    HStack {
                        Text(dependency.name)
                        Spacer()
                        if let license = dependency.license {
                            Text("\(license) (\(dependency.version))").foregroundColor(.secondary)
                        } else {
                            Text(dependency.version).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(LocalString.settings_about_title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: externalLinkURL) { _, url in
            guard let url = url else { return }
            UIApplication.shared.open(url)
        }
        .task { await getDependencies() }
        #endif
    }

    private var about: some View {
        Text(Brand.aboutText)
    }

    private var release: some View {
        Text(LocalString.settings_about_license_description)
    }

    private var legalNotice: some View {
        Text("ArkFile app source is available under GPL terms. Paid ArkFile content access, account services, download URLs, and ArkFile trademarks are separate from app-code rights. ArkFile is independent and is not affiliated with or endorsed by Kiwix.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var appVersion: some View {
        Attribute(title: LocalString.settings_about_appverion_title,
                  detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    private var buildNumber: some View {
        Attribute(title: LocalString.settings_about_build_title,
                  detail: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    private var ourWebsite: some View {
        Button(LocalString.settings_about_our_website_button) {
            externalLinkURL = URL(string: "\(Brand.aboutWebsite)")
        }
    }

    @ViewBuilder
    private var source: some View {
        if let sourceURL = ArkFileSourceReleaseDisclosure.current.sourceReleaseURL {
            Button(LocalString.settings_about_source_title) {
                externalLinkURL = sourceURL
            }
        }
    }

    private var privacyPolicy: some View {
        Button("Privacy Policy") {
            externalLinkURL = URL(string: "\(Brand.arkFileSiteURL)/privacy")
        }
    }

    @ViewBuilder
    private var license: some View {
        #if os(iOS)
        // Offline-first: the GPL text ships with the app, so the license is
        // readable with no network (and satisfies conveying the license text).
        NavigationLink(LocalString.settings_about_button_license) {
            ArkFileBundledTextView(title: "GNU GPL v3", resource: "gpl-3.0")
        }
        #else
        Button(LocalString.settings_about_button_license) {
            externalLinkURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html")
        }
        #endif
    }

    private var openSource: some View {
        Button("Open Source") {
            externalLinkURL = URL(string: "\(Brand.arkFileSiteURL)/open-source.html")
        }
    }

    @ViewBuilder
    private var contentLicenses: some View {
        #if os(iOS)
        NavigationLink("Licenses & Attributions") {
            ArkFileLicensesView()
        }
        #else
        Button("Licenses & Attributions") {
            externalLinkURL = URL(string: "\(Brand.arkFileSiteURL)/licenses.html")
        }
        #endif
    }

    private func getDependencies() async {
        dependencies = kiwix.getVersions().map { datum in
            Dependency(name: String(datum.first), version: String(datum.second))
        }
    }
}

private struct Dependency: Identifiable {
    var id: String { name }

    let name: String
    let version: String

    var license: String? {
        switch name {
        case "libkiwix":
            "GPLv3"
        case "libzim":
            "GPLv2"
        case "libxapian":
            "GPLv2"
        case "libicu":
            "ICU"
        case "MapLibre":
            "BSD"
        case "ZIPFoundation":
            "MIT"
        case "Defaults":
            "MIT"
        case "SwiftSystem":
            "Apache-2.0"
        default:
            nil
        }
    }
}

#Preview {
    #if os(macOS)
    TabView { About() }
    #elseif os(iOS)
    NavigationStack { About() }
    #endif
}
