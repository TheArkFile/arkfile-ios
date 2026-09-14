// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import SwiftUI

/// The home entry point is deliberately one large button. The sun artwork is
/// decorative; VoiceOver receives the same useful state a sighted user sees.
struct ArkFileSavedWeatherHomeCard: View {
    @ObservedObject private var controller: ArkFileSavedWeatherController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var now = Date()

    let openWeather: () -> Void

    init(
        controller: ArkFileSavedWeatherController = .shared,
        openWeather: @escaping () -> Void
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.openWeather = openWeather
    }

    var body: some View {
        Button(action: openWeather) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .accessibilityHidden(true)
                    Text("Weather")
                        .font(.headline)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }

                if let locationName = ArkFileSavedWeatherPresentation
                    .locationDisplayName(
                        settings: controller.settings,
                        snapshot: controller.snapshot
                    ) {
                    Text(locationName)
                        .font(.subheadline.weight(.semibold))
                }

                Text(headline)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if controller.isLoading
                        || controller.isCheckingCurrentLocation {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(
                            systemName: controller.connectivity == .offline
                                ? "wifi.slash"
                                : "clock"
                        )
                        .accessibilityHidden(true)
                    }
                    Text(status)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color.white)
            .padding(14)
            .frame(
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 164 : 112,
                alignment: .leading
            )
            .background {
                ZStack {
                    Image("ArkFileBackground")
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.78),
                            Color.black.opacity(0.44),
                            Color.black.opacity(0.20)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .accessibilityHidden(true)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            "Opens the weather briefing saved on "
                + "\(ArkFileDeviceCopy.thisDevice)."
        )
        .accessibilityIdentifier("arkfile_saved_weather_card")
        .task(id: controller.snapshot?.assembledAt) {
            while !Task.isCancelled {
                let deadline = ArkFileSavedWeatherPresentation
                    .nextPresentationUpdate(
                        snapshot: controller.snapshot,
                        after: now
                    )
                let interval = max(
                    0.05,
                    deadline.timeIntervalSinceNow + 0.05
                )
                try? await Task.sleep(
                    nanoseconds: UInt64(interval * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
    }

    private var matchingSnapshot: ArkFileWeatherSnapshot? {
        ArkFileSavedWeatherPresentation.matchingSnapshot(
            settings: controller.settings,
            snapshot: controller.snapshot
        )
    }

    private var headline: String {
        ArkFileSavedWeatherPresentation.homeHeadline(
            settings: controller.settings,
            snapshot: controller.snapshot,
            connectivity: controller.connectivity,
            isRefreshing:
                controller.isLoading || controller.isCheckingCurrentLocation,
            at: now,
            locale: locale
        )
    }

    private var status: String {
        if controller.isCheckingCurrentLocation {
            return "Checking current location…"
        }
        if let notice = controller.currentLocationNotice {
            return notice.shortMessage
        }
        return ArkFileSavedWeatherPresentation.homeStatus(
            settings: controller.settings,
            snapshot: controller.snapshot,
            connectivity: controller.connectivity,
            isRefreshing: controller.isLoading,
            at: now
        )
    }

    private var borderColor: Color {
        guard let snapshot = matchingSnapshot,
              let alert = ArkFileSavedWeatherPresentation.visibleAlerts(
                  in: snapshot,
                  at: now
              ).first,
              snapshot.alerts.stamp != nil else {
            return Color.arkAppBorder
        }
        let presentation = ArkFileSavedWeatherPresentation.alertPresentation(
            for: alert,
            component: snapshot.alerts,
            connectivity: controller.connectivity,
            at: now
        )
        return presentation.isUrgent ? Color.red : Color.arkAppBorder
    }

    private var accessibilityLabel: String {
        let location = ArkFileSavedWeatherPresentation.locationDisplayName(
            settings: controller.settings,
            snapshot: controller.snapshot
        )
        return [
            "Weather",
            location,
            headline,
            status
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}
#endif
