// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import SwiftUI
import UIKit

/// A List-compatible settings section. Persistence remains controller-owned so
/// toggles cannot drift from the durable Saved Weather settings envelope.
struct ArkFileSavedWeatherSettingsSection: View {
    @ObservedObject private var controller: ArkFileSavedWeatherController

    let openWeather: () -> Void
    let changeLocation: () -> Void

    @State private var isConfirmingDeletion = false
    @State private var didCopyDiagnostics = false

    init(
        controller: ArkFileSavedWeatherController = .shared,
        openWeather: @escaping () -> Void,
        changeLocation: @escaping () -> Void
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.openWeather = openWeather
        self.changeLocation = changeLocation
    }

    var body: some View {
        Section {
            if let error = controller.lastError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        error.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") {
                        controller.clearError()
                    }
                    .frame(minHeight: 44)
                    if error == .storageWrite {
                        Text(
                            "Free space in "
                                + "\(ArkFileDeviceCopy.currentStorageSettingsPath), "
                                + "then retry the update."
                        )
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        Button("Retry Update") {
                            Task {
                                await controller.refreshManually()
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                .accessibilityElement(children: .contain)
            }

            if let location = controller.settings.savedLocation {
                if controller.isCheckingCurrentLocation {
                    Label(
                        "Checking current location…",
                        systemImage: "location.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.arkPrimary)
                } else if let notice =
                    controller.currentLocationNotice {
                    Label(
                        notice.message,
                        systemImage: "location.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(location.displayName, systemImage: "mappin.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.arkTextPrimary)
                    if let accuracy = accuracyDescription(for: location) {
                        Text(accuracy)
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(locationSourceName(location.source))
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                    }
                }
                .accessibilityElement(children: .combine)

                Button(action: openWeather) {
                    Label("Open Weather", systemImage: "sun.max")
                }
                .frame(minHeight: 44)

                Button(action: changeLocation) {
                    Label("Change Saved Location", systemImage: "map")
                }
                .frame(minHeight: 44)

                Toggle(
                    "Keep My Saved Forecast Fresh",
                    isOn: Binding(
                        get: {
                            controller.settings.automaticRefreshEnabled
                        },
                        set: { enabled in
                            Task {
                                await controller
                                    .setAutomaticRefreshEnabled(enabled)
                            }
                        }
                    )
                )

                Toggle(
                    "Automatic Updates on Wi-Fi Only",
                    isOn: Binding(
                        get: {
                            controller.settings.refreshOnWiFiOnly
                        },
                        set: { enabled in
                            Task {
                                await controller
                                    .setRefreshOnWiFiOnly(enabled)
                            }
                        }
                    )
                )
                .disabled(!controller.settings.automaticRefreshEnabled)

                if controller.settings.automaticRefreshEnabled {
                    LabeledContent(
                        "Background App Refresh",
                        value: backgroundRefreshStatus
                    )
                    if ProcessInfo.processInfo.isLowPowerModeEnabled {
                        Label(
                            "Low Power Mode may delay background updates",
                            systemImage: "battery.25"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                    }
                }

                Picker(
                    "Weather Units",
                    selection: Binding(
                        get: {
                            controller.settings.unitPreference
                        },
                        set: { preference in
                            Task {
                                await controller.setUnitPreference(preference)
                            }
                        }
                    )
                ) {
                    Text("Automatic").tag(ArkFileWeatherUnitPreference.automatic)
                    Text("U.S.").tag(ArkFileWeatherUnitPreference.us)
                    Text("Metric").tag(ArkFileWeatherUnitPreference.metric)
                }

                LabeledContent(
                    "Saved Data",
                    value: ByteCountFormatter.string(
                        fromByteCount: controller.storageSizeBytes,
                        countStyle: .file
                    )
                )

                Button(role: .destructive) {
                    isConfirmingDeletion = true
                } label: {
                    Label("Delete Weather Data", systemImage: "trash")
                }
                .frame(minHeight: 44)
            } else {
                Button(action: openWeather) {
                    Label("Set Up Weather", systemImage: "sun.max")
                }
                .frame(minHeight: 44)

                if controller.canResetSavedWeatherData {
                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Label(
                            "Reset Unreadable Weather Data",
                            systemImage: "trash"
                        )
                    }
                    .frame(minHeight: 44)
                }
            }

            Button {
                UIPasteboard.general.string =
                    controller.redactedDiagnosticsText()
                didCopyDiagnostics = true
            } label: {
                Label(
                    didCopyDiagnostics
                        ? "Weather Diagnostics Copied"
                        : "Copy Weather Diagnostics",
                    systemImage: didCopyDiagnostics
                        ? "checkmark.circle"
                        : "doc.on.doc"
                )
            }
            .frame(minHeight: 44)
            .accessibilityHint(
                "Copies status and timestamps without the saved location, "
                    + "coordinates, alert text, or provider payloads."
            )
        } header: {
            Text("Weather")
        } footer: {
            Text(settingsFooter)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            "Delete Weather Data?",
            isPresented: $isConfirmingDeletion
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await controller.deleteSavedWeather()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the saved location, settings, and offline "
                    + "weather briefing from "
                    + "\(ArkFileDeviceCopy.thisDevice). Other ArkFile "
                    + "content and map waypoints are not removed."
            )
        }
        .task {
            await controller.load()
        }
    }

    private var settingsFooter: String {
        guard controller.settings.savedLocation != nil else {
            return "Weather is free and optional. Setup sends the "
                + "selected coordinate directly over HTTPS to NOAA/NWS when "
                + "you request an update."
        }
        if controller.settings.automaticRefreshEnabled {
            let locationBehavior =
                controller.settings.savedLocation?.source == .currentLocation
                    ? "While ArkFile is open, one-shot location checks follow "
                        + "meaningful travel. "
                    : "This saved location remains pinned. "
            return locationBehavior
                + "Opening, foreground, reconnect, and background updates are "
                + "best-effort. iOS decides whether background work runs. "
                + "Background weather updates use the last confirmed point "
                + "and never request location. Background App Refresh is "
                + backgroundRefreshStatus.lowercased()
                + ". Low Power Mode or force-quitting ArkFile can prevent "
                + "background opportunities; Update Now always remains available."
        }
        return "Automatic network updates are off. The saved briefing stays "
            + "on \(ArkFileDeviceCopy.thisDevice) until you update it "
            + "manually or delete it."
    }

    private var backgroundRefreshStatus: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            "Available"
        case .denied:
            "Off"
        case .restricted:
            "Restricted"
        @unknown default:
            "Unknown"
        }
    }

    private func accuracyDescription(
        for location: ArkFileWeatherSavedLocation
    ) -> String? {
        guard location.source == .currentLocation,
              let meters = location.horizontalAccuracyMeters,
              meters.isFinite,
              meters >= 0 else {
            return nil
        }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return "Follows Current Location · last fix about "
            + formatter.string(from: measurement)
            + " accuracy"
    }

    private func locationSourceName(
        _ source: ArkFileWeatherLocationSource
    ) -> String {
        switch source {
        case .currentLocation:
            return controller.settings.automaticRefreshEnabled
                ? "Follows Current Location while ArkFile is open"
                : "Current Location follow is paused"
        case .enteredCoordinate:
            return "Manually entered coordinate"
        case .offlineMap:
            return "Point chosen on the offline map"
        case .savedWaypoint:
            return "Copied from a saved map waypoint"
        }
    }
}
#endif
