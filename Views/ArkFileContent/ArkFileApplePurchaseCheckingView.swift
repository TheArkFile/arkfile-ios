// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import SwiftUI

/// Shared state when this device has prior paid-content evidence but StoreKit
/// has not resolved the current Apple Account.
struct ArkFileApplePurchaseCheckingView: View {
    let isBusy: Bool
    let checkAppleAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(Color.arkPrimary)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        isBusy
                            ? "Checking Apple purchases…"
                            : "Confirm Apple purchases"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                    Text(
                        "Check this Apple Account for an existing ArkFile purchase. "
                            + "No download will start."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: checkAppleAccount) {
                Label(
                    isBusy ? "Checking Apple Account…" : "Check Apple Account",
                    systemImage: "arrow.clockwise.circle"
                )
                .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityIdentifier(
                "arkfile_check_apple_account_action"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arkfile_checking_apple_purchases")
    }
}
#endif
