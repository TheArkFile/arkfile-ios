// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import SwiftUI

/// Displays a bundled plain-text legal document (license text) fully offline.
struct ArkFileBundledTextView: View {
    let title: String
    let resource: String

    @State private var text: String?

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "Text Unavailable",
                    systemImage: "doc.text",
                    description: Text("The bundled document could not be loaded.")
                )
                .padding(.top, 60)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard text == nil else { return }
            if let url = Bundle.main.url(forResource: resource, withExtension: "txt") {
                text = try? String(contentsOf: url, encoding: .utf8)
            }
        }
    }
}

/// Offline access to the app license, current third-party notices and license
/// references, and content/data attributions. Web pages remain secondary
/// references and should not be required to identify the shipped components.
struct ArkFileLicensesView: View {
    private struct AttributionRow: Identifiable {
        let title: String
        let detail: String

        var id: String { title }
    }

    private let softwareRows: [AttributionRow] = [
        AttributionRow(title: "Kiwix Apple (modified downstream)", detail: "GPL-3.0-or-later"),
        AttributionRow(title: "CoreKiwix / libkiwix 14.2.0", detail: "GPL-3.0-or-later"),
        AttributionRow(title: "libzim (openZIM) 9.6.0", detail: "GPL-2.0-or-later"),
        AttributionRow(title: "Xapian 1.4.23", detail: "GPL-2.0-or-later"),
        AttributionRow(title: "ICU 73.2", detail: "Unicode License v3"),
        AttributionRow(title: "curl 8.4.0", detail: "curl license"),
        AttributionRow(title: "GNU libmicrohttpd 0.9.76", detail: "LGPL-2.1-or-later"),
        AttributionRow(title: "zlib 1.3.1", detail: "Zlib"),
        AttributionRow(title: "pugixml 1.15", detail: "MIT"),
        AttributionRow(title: "kainjow Mustache 4.1", detail: "BSL-1.0"),
        AttributionRow(title: "Zstandard 1.5.7", detail: "BSD-3-Clause"),
        AttributionRow(title: "liblzma 5.2.6", detail: "Public-domain components"),
        AttributionRow(title: "Defaults 8.2.0", detail: "MIT"),
        AttributionRow(title: "ZIPFoundation 0.9.20", detail: "MIT"),
        AttributionRow(title: "MapLibre Native 6.14.0", detail: "BSD-2-Clause"),
        AttributionRow(title: "Noto Fonts", detail: "SIL OFL 1.1"),
        AttributionRow(title: "Protomaps Basemaps style 5.7.2", detail: "BSD-3-Clause / CC0 / MIT notices")
    ]

    private let contentRows: [AttributionRow] = [
        AttributionRow(
            title: "Wikipedia",
            detail: "Text © Wikipedia contributors, licensed CC BY-SA 4.0. Articles carry their own attribution. creativecommons.org/licenses/by-sa/4.0"
        ),
        AttributionRow(
            title: "Offline map data",
            detail: "© OpenStreetMap contributors, licensed ODbL 1.0 (openstreetmap.org/copyright). Basemap tiles produced with Protomaps."
        ),
        AttributionRow(
            title: "Critical Places data",
            detail: "Hospitals, pharmacies, fuel, food, water, police, and fire-station points are derived from OpenStreetMap contributors and licensed ODbL 1.0."
        ),
        AttributionRow(
            title: "US Government publications",
            detail: "Works of the United States Government (Army field manuals, Office of Civil Defense guides, and similar) are in the public domain."
        ),
        AttributionRow(
            title: "Classic books and documents",
            detail: "Included books are public-domain works whose copyright has expired."
        ),
        AttributionRow(
            title: "OpenStax textbooks",
            detail: "The Open Textbooks shelf contains OpenStax titles (College Physics, Physics, Biology 2e, Chemistry, Psychology 2e, and others) licensed Creative Commons Attribution 4.0 International (creativecommons.org/licenses/by/4.0). ArkFile uses frozen 2022-era EPUB artifacts and converts them into offline HTML-book packages; each installed book includes its own License and Attribution page naming the exact work and authors. OpenStax and Rice University do not endorse ArkFile."
        ),
        AttributionRow(
            title: "ArkFile guides and tools",
            detail: "The Survival Guide and Preparedness Toolkit are written for ArkFile, informed by CDC, EPA, FEMA/Ready.gov, NWS, AHA, and USDA public guidance."
        )
    ]

    private let weatherRows: [AttributionRow] = [
        AttributionRow(
            title: "National Weather Service API & alerts — core source",
            detail: "Forecasts and watches, warnings, and advisories are official NOAA/NWS products retrieved from api.weather.gov. U.S. Government source; no NOAA or NWS endorsement of ArkFile is implied. Saved copies identify their source and issue or retrieval time."
        ),
        AttributionRow(
            title: "NOAA Climate Prediction Center outlooks — core source",
            detail: "Official NOAA/NWS CPC 6–10 day, 8–14 day, and week 3–4 temperature and precipitation probability outlooks. These are probabilistic climate outlooks, not precise daily forecasts. Saved snapshots identify their source, issue time, and validity period."
        ),
        AttributionRow(
            title: "NOAA Weather Radio / SAME — reference source",
            detail: "NOAA/NWS transmitter, frequency, coverage, county, and SAME reference information. ArkFile is not a radio receiver; alerts require a compatible external NOAA Weather Radio/SAME receiver. Station data may change and saved records show when ArkFile last updated them."
        ),
        AttributionRow(
            title: "National Water Prediction Service — optional, not active in v1",
            detail: "NOAA/NWS NWPS river-gauge observations and forecasts may be offered only through a separately enabled module with explicit station selection, source times, and coverage limits. No river module is part of the Weather core."
        ),
        AttributionRow(
            title: "AirNow — optional, not active in v1",
            detail: "U.S. EPA AirNow air-quality and smoke data may be offered only through a separately enabled module after API access, current terms, coverage, attribution, and data-quality requirements are verified. AirNow data can be preliminary and is not a substitute for local official instructions."
        ),
        AttributionRow(
            title: "U.S. Drought Monitor — optional, not active in v1",
            detail: "The U.S. Drought Monitor is jointly produced by the National Drought Mitigation Center at the University of Nebraska–Lincoln, the U.S. Department of Agriculture, and NOAA. Any future ArkFile display must preserve the product's date, classification, source credit, and use requirements."
        )
    ]

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ArkFileBundledTextView(
                        title: "GNU GPL v3",
                        resource: "gpl-3.0"
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GNU General Public License v3")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("The ArkFile app is free software; the complete license text is included here and works offline.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("App License")
            } footer: {
                Text(ArkFileSourceReleaseDisclosure.current.disclosureText)
            }

            Section {
                ForEach(softwareRows) { row in
                    HStack {
                        Text(row.title)
                            .font(.subheadline)
                        Spacer()
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    ArkFileBundledTextView(
                        title: "Third-Party Notices",
                        resource: "third-party-licenses"
                    )
                } label: {
                    Text("Third-Party Notices & License References")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            } header: {
                Text("Third-Party Software")
            } footer: {
                Text("The bundled notice identifies the controlled native components. For a public build, the online source links provide matching app source, native source, notices, and relink material.")
            }

            Section {
                ForEach(contentRows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Content & Data Attributions")
            } footer: {
                Text("Emergency and medical content is general reference information, not a substitute for professional training or local official guidance.")
            }

            Section {
                ForEach(weatherRows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Weather & Environmental Data")
            } footer: {
                Text("These source and limitation summaries work offline. Each enabled Weather component also carries its own source, issued or fetched time, validity window, and freshness status.")
            }

            Section {
                if let url = URL(string: "\(Brand.arkFileSiteURL)/licenses.html") {
                    Link("Licenses & attributions on the web", destination: url)
                }
                if let url = URL(string: "\(Brand.arkFileSiteURL)/open-source.html") {
                    Link("Open-source overview on the web", destination: url)
                }
                if let url = ArkFileSourceReleaseDisclosure.current.sourceReleaseURL {
                    Link("Source code release for this build", destination: url)
                }
            } header: {
                Text("Online References")
            } footer: {
                Text("These links need an internet connection. The app license, current notices, and attribution summaries above work offline.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
