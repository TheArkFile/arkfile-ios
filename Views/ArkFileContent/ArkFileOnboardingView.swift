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
}

/// One-time first-launch introduction: what ArkFile is, what is already included,
/// and how Essentials and Complete differ before anyone spends money.
struct ArkFileOnboardingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    static let completedDefaultsKey = "arkfile.onboarding.completed.v1"

    let finish: (ArkFileOnboardingDestination) -> Void

    @State private var pageIndex = 0

    private struct Page {
        let systemImage: String
        let title: String
        let message: String
        let accent: Color
    }

    private let pages: [Page] = [
        Page(
            systemImage: "wifi.slash",
            title: "Ready When Networks Are Not",
            message: "ArkFile is an offline preparedness library. Everything you install lives on this device and keeps working with no signal or Wi-Fi. No ArkFile account is required; Apple handles content-pack purchases and restores.",
            accent: Color.arkTeal
        ),
        Page(
            systemImage: "checklist",
            title: "5 Sample Titles Included",
            message: "Five sample titles, the Survival Guide, preparedness calculators, and the offline base map are included with ArkFile. No purchase is required—explore them now so they feel familiar before you need them.",
            accent: Color.arkAmber
        ),
        Page(
            systemImage: "externaldrive.badge.plus",
            title: "Choose Essentials or Complete",
            message: "Essentials and Complete are one-time purchases. Essentials adds a practical offline library. Complete includes Essentials plus more reference works, textbooks, Wikipedia choices, and optional regional maps. After purchase, choose only what you want on this device and add more later.",
            accent: Color.arkReef
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    pageView(page, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            onboardingFooter
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(
                    minHeight: dynamicTypeSize.isAccessibilitySize ? 190 : 144,
                    alignment: .top
                )
        }
        .background(Color.arkSand.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func pageView(_ page: Page, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(page.accent)
                    .frame(width: 110, height: 110)
                    .background(page.accent.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_onboarding_title_\(index + 1)")
                Text(page.message)
                    .font(.body)
                    .foregroundStyle(Color.arkTaupe)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arkfile_onboarding_message_\(index + 1)")

            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("arkfile_onboarding_page_\(index + 1)")
    }

    private var finalActions: some View {
        VStack(spacing: 12) {
            Button {
                finish(.includedSamples)
            } label: {
                Text("Explore 5 Included Samples")
                    .font(.headline)
                    .foregroundStyle(Color.arkSurface)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.arkTeal)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("arkfile_onboarding_explore_samples")

            Button {
                finish(.packs)
            } label: {
                Text("Compare Essentials and Complete")
                    .font(.headline)
                    .foregroundStyle(Color.arkTeal)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.arkSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.arkTeal, lineWidth: 1.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("arkfile_onboarding_compare_packs")
        }
    }

    @ViewBuilder
    private var onboardingFooter: some View {
        if pageIndex < pages.count - 1 {
            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut) {
                        pageIndex += 1
                    }
                } label: {
                    Text("Next")
                        .font(.headline)
                        .foregroundStyle(Color.arkSurface)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.arkTeal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("arkfile_onboarding_next")

                Button("Skip") {
                    finish(.home)
                }
                .font(.subheadline)
                .foregroundStyle(Color.arkTaupe)
                .accessibilityIdentifier("arkfile_onboarding_skip")
            }
        } else {
            finalActions
        }
    }
}
#endif
