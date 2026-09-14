// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import SwiftUI

enum ArkFileTitleSummaryDisclosureState {
    static func nextExpandedItemID(current: String?, tapped: String) -> String? {
        current == tapped ? nil : tapped
    }
}

struct ArkFileTitleSummaryDisclosure: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                    Text("About this title")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkPrimary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the title summary." : "Shows a short title summary.")

            if isExpanded {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.arkPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
#endif
