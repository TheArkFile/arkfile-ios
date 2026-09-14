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

/// Common emergency phone numbers, deliberately kept off the home screen so
/// dialing always takes an intentional tap here plus iOS's own call
/// confirmation — no accidental 911 calls from a scrolling thumb.
struct ArkFileEmergencyNumbersView: View {
    @Environment(\.openURL) private var openURL

    private struct EmergencyNumber: Identifiable {
        let name: String
        let displayNumber: String
        let dialString: String
        let detail: String
        let systemImage: String

        var id: String { dialString }
    }

    private let numbers: [EmergencyNumber] = [
        EmergencyNumber(
            name: "Emergency Services",
            displayNumber: "911",
            dialString: "911",
            detail: "Life-threatening danger, severe injury, fire, or crime in progress (US).",
            systemImage: "cross.circle.fill"
        ),
        EmergencyNumber(
            name: "Poison Control",
            displayNumber: "1-800-222-1222",
            dialString: "18002221222",
            detail: "Free, 24 hours. Swallowed chemicals or medication, bites, stings, fumes.",
            systemImage: "cross.vial.fill"
        ),
        EmergencyNumber(
            name: "Suicide & Crisis Lifeline",
            displayNumber: "988",
            dialString: "988",
            detail: "Free, 24 hours. Call or text for a mental health or suicide crisis.",
            systemImage: "heart.circle.fill"
        )
    ]

    var body: some View {
        List {
            Section {
                Text(
                    "Tapping Call asks iOS to open "
                        + "\(ArkFileDeviceCopy.compatibleCallingService). "
                        + "Availability and confirmation depend on the "
                        + "calling services configured for this device. "
                        + "The guidance in the Survival Guide works fully "
                        + "offline."
                )
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            Section {
                ForEach(numbers) { number in
                    HStack(spacing: 12) {
                        Image(systemName: number.systemImage)
                            .font(.title3)
                            .foregroundStyle(.red)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(number.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.arkTextPrimary)
                            Text(number.displayNumber)
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(Color.arkTextPrimary)
                            Text(number.detail)
                                .font(.caption2)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button {
                            if let url = URL(string: "tel:\(number.dialString)") {
                                openURL(url)
                            }
                        } label: {
                            Label("Call", systemImage: "phone.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityLabel("Call \(number.name) at \(number.displayNumber)")
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Write these numbers on paper too — a dead battery takes this list with it. Add your local non-emergency line, utility outage line, and out-of-area contact to your paper plan.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Emergency Numbers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
