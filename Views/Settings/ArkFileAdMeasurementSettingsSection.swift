// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
import SwiftUI

struct ArkFileAdMeasurementSettingsSection: View {
    @ObservedObject private var measurement = ArkFileAdMeasurement.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("Help Measure ArkFile Ads", isOn: Binding(
                get: { measurement.optedIn },
                set: { value in Task { await measurement.setOptedIn(value) } }
            ))
            .disabled(!measurement.isConfigured || measurement.isRequestingPermission)
            .accessibilityIdentifier("arkfile_optional_ad_measurement")
            if !measurement.isConfigured {
                Text("Ad measurement is not enabled in this build.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if measurement.optedIn && measurement.authorizationStatus != .authorized {
                Text("Nothing is sent. Apple’s tracking permission is also required.")
                    .font(.footnote).foregroundStyle(.secondary)
                if measurement.authorizationStatus == .denied {
                    Button("Open Tracking Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        } header: {
            Text("Privacy & Ad Measurement")
        } footer: {
            Text("Optional. With your permission, ArkFile shares your advertising identifier, app and iOS versions, new installs, paid purchases, and the first successful content download with Meta to measure and improve ArkFile ads. Purchase verification goes to ArkFile first; Apple’s signed receipt is not sent to Meta. Your library, reading, searches, and location are not included. Turning this off stops future sharing and discards unsent events; it does not erase events already sent. ArkFile’s features work the same either way.")
        }
        .onAppear { measurement.refreshAuthorization() }
    }
}
#endif
