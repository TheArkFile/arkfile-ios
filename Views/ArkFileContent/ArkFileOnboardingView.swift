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

extension Notification.Name {
    static let arkFileReplayOnboarding = Notification.Name(
        "app.arkfile.replay-onboarding"
    )
    static let arkFileOnboardingDestination = Notification.Name(
        "app.arkfile.onboarding-destination"
    )
}

enum ArkFileOnboardingDestination: Equatable, Sendable {
    case home
    case includedSamples
    case packs
    case restore
}

private struct ArkFileOnboardingRequestKey: EnvironmentKey {
    static let defaultValue: Binding<ArkFileOnboardingDestination?> = .constant(nil)
}

extension EnvironmentValues {
    var arkFileOnboardingRequest: Binding<ArkFileOnboardingDestination?> {
        get { self[ArkFileOnboardingRequestKey.self] }
        set { self[ArkFileOnboardingRequestKey.self] = newValue }
    }
}

struct ArkFileOnboardingView: View {
    static let completedDefaultsKey = "arkfile.onboarding.completed.v1"
    let finish: (ArkFileOnboardingDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Free with ArkFile")
                    .foregroundStyle(Color.arkTextPrimary)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("arkfile_onboarding_title_1")
                Text("Start with sample titles, the Survival Guide, preparedness tools and a base map. They work offline.")
                    .foregroundStyle(Color.arkTextPrimary)
                Button("Explore free titles") { finish(.includedSamples) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.arkPrimary)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("arkfile_onboarding_explore_samples")

                Divider()
                Text("Optional libraries").foregroundStyle(Color.arkTextPrimary).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(ArkFileHomePresentation.essentialsDescription)
                    .foregroundStyle(Color.arkTextPrimary)
                Text(ArkFileHomePresentation.fullDescription)
                    .foregroundStyle(Color.arkTextPrimary)
                Text("One-time purchase through Apple. Choose what to download after you buy.")
                    .foregroundStyle(Color.arkTextPrimary)
                    .font(.subheadline)
                Button("See libraries and prices") { finish(.packs) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("arkfile_onboarding_compare_packs")
                Button("Restore Purchases") { finish(.restore) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("arkfile_onboarding_restore")
                Button("Go to Home") { finish(.home) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("arkfile_onboarding_skip")
            }
            .controlSize(.large)
            .tint(Color.arkInteractiveForeground)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.arkAppBackground.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}
#endif
