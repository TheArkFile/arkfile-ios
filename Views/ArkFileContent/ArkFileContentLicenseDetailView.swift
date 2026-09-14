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

struct ArkFileContentLicenseDetailView: View {
    let entry: ArkFileContentLicenseEntry
    let ledgerVersion: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Title") {
                detailRow("Title", value: entry.displayName)
                detailRow("Edition / revision", value: entry.artifact.editionOrRevision)
                detailRow("ArkFile path", value: entry.artifact.relativePath)
            }

            Section("Source") {
                detailRow("Original title", value: entry.source.title)
                detailRow("Creator", value: entry.source.creators.joined(separator: ", "))
                detailRow("Publisher", value: entry.source.publisher)
                if let sourceURL = URL(string: entry.source.canonicalUrl) {
                    Link("Open canonical source page", destination: sourceURL)
                }
                if let artifactURLString = entry.source.artifactUrl,
                   let artifactURL = URL(string: artifactURLString) {
                    Link("Open source artifact", destination: artifactURL)
                }
            }

            Section("Content License") {
                detailRow("License", value: "\(entry.license.name) (\(entry.license.id))")
                if let licenseURL = URL(string: entry.license.url) {
                    Link("Read the license", destination: licenseURL)
                }
                detailRow("Commercial use", value: displayPermission(entry.license.commercialUse))
                detailRow("Redistribution", value: displayPermission(entry.license.redistribution))
                detailRow("Modification", value: displayPermission(entry.license.modification))
                detailRow("Share alike", value: entry.license.shareAlike ? "Required" : "Not required")
                detailRow("Review status", value: entry.decision.status.localizedCapitalized)
            }

            Section("Attribution & Changes") {
                Text(entry.notices.attributionText)
                    .textSelection(.enabled)
                Text(entry.notices.changesMade)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                Text(entry.downstreamRights.summary)
                    .textSelection(.enabled)
            } header: {
                Text("Downstream Rights")
            } footer: {
                Text("Title-level content record \(ledgerVersion). App and third-party software licenses are listed separately in Settings > Licenses.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("License & Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func displayPermission(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .localizedCapitalized
    }
}
#endif
