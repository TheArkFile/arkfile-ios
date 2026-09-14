// This file is part of ArkFile and is licensed under GPL-3.0-or-later.

#if os(iOS)
import SwiftUI

struct ArkFileTitleDetailView: View {
    let item: ArkFileLibraryContentItem
    let presentation: ArkFileLockedContentPresentation
    let transferStatus: String?
    let actionTitle: String
    let actionSystemImage: String
    let isActionEnabled: Bool
    let licenseEntry: ArkFileContentLicenseEntry?
    let ledgerVersion: String
    let primaryAction: () -> Void
    let restoreAction: () -> Void
    var removeAction: (() -> Void)?

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: item.type.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(Color.arkInteractiveForeground)
                        .accessibilityHidden(true)
                    Text(item.displayName)
                        .font(.title2.bold())
                        .foregroundStyle(Color.arkTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(presentation.statusTitle, systemImage: presentation.statusSystemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .foregroundStyle(Color.arkTextPrimary)
                    } else {
                        Text("A title in \(item.sampleOriginalSubcategory ?? item.subcategory).")
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    LabeledContent("Format", value: item.type.displayLabel)
                    LabeledContent(item.isInstalled ? "On this device" : "Download size", value: formattedSize)
                    if let variant = item.variantLabel, !variant.isEmpty {
                        LabeledContent("Edition", value: variant)
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    if let transferStatus {
                        Label(transferStatus, systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.arkTextMuted)
                    }
                    Button(action: primaryAction) {
                        Label(actionTitle, systemImage: actionSystemImage)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.arkPrimary)
                    .disabled(!isActionEnabled)
                    .accessibilityIdentifier("arkfile_title_detail_primary_action")

                    if presentation.accessState == .locked {
                        Text(presentation.message)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if presentation.isRestoreAvailable {
                            Button("Restore Purchases", action: restoreAction)
                                .disabled(!presentation.isRestoreActionEnabled)
                                .frame(minHeight: 44)
                        }
                    } else if presentation.accessState == .downloadable {
                        Text("Your purchase unlocks this title. Downloading saves a copy on this device for use without a connection.")
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let licenseEntry {
                    NavigationLink {
                        ArkFileContentLicenseDetailView(entry: licenseEntry, ledgerVersion: ledgerVersion)
                    } label: {
                        Label("Source & License", systemImage: "info.circle")
                            .frame(minHeight: 44)
                    }
                }
                if let removeAction {
                    Button("Remove Download", role: .destructive, action: removeAction)
                        .frame(minHeight: 44)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.arkAppBackground.ignoresSafeArea())
        .tint(Color.arkInteractiveForeground)
        .navigationTitle("About this title")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("arkfile_title_detail")
    }
}
#endif
