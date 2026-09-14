// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import SwiftUI
import UIKit

struct ArkFileSavedWeatherView: View {
    @ObservedObject private var controller: ArkFileSavedWeatherController
    @ObservedObject private var waypointStore = ArkFileMapWaypointStore.shared
    @Environment(\.dismiss) private var dismiss

    private let contentRoot: URL?
    private let requestCurrentLocationOverride: (() -> Void)?
    private let saveManualLocationOverride: ((
        ArkFileWeatherCoordinate,
        String
    ) -> Void)?
    private let selectWaypointOverride: ((ArkFileMapWaypoint) -> Void)?
    private let chooseMapOverride: (() -> Void)?
    private let openGuidanceOverride: ((
        ArkFileWeatherPreparednessLink
    ) -> Void)?

    @State private var isChoosingLocation = false
    @State private var showsOtherPlaceOptions = false
    @State private var isShowingMapPicker = false
    @State private var guidanceTarget: ArkFileWeatherPreparednessLink?
    @State private var isRequestingCurrentLocation = false
    @State private var currentLocationTask: Task<Void, Never>?

    init(
        controller: ArkFileSavedWeatherController = .shared,
        contentRoot: URL? = nil,
        startsChoosingLocation: Bool = false,
        requestCurrentLocation: (() -> Void)? = nil,
        saveManualLocation: ((
            ArkFileWeatherCoordinate,
            String
        ) -> Void)? = nil,
        selectWaypoint: ((ArkFileMapWaypoint) -> Void)? = nil,
        chooseOnMap: (() -> Void)? = nil,
        openGuidance: ((
            ArkFileWeatherPreparednessLink
        ) -> Void)? = nil
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        _isChoosingLocation = State(initialValue: startsChoosingLocation)
        self.contentRoot = contentRoot
        requestCurrentLocationOverride = requestCurrentLocation
        saveManualLocationOverride = saveManualLocation
        selectWaypointOverride = selectWaypoint
        chooseMapOverride = chooseOnMap
        openGuidanceOverride = openGuidance
    }

    var body: some View {
        Group {
            if controller.settings.savedLocation == nil || isChoosingLocation {
                locationSetup
                    .accessibilityIdentifier("arkfile_weather_root")
            } else if let snapshot = matchingSnapshot {
                ArkFileSavedWeatherBriefing(
                    settings: controller.settings,
                    snapshot: snapshot,
                    connectivity: controller.connectivity,
                    isRefreshing: controller.isLoading,
                    isCheckingCurrentLocation:
                        controller.isCheckingCurrentLocation,
                    currentLocationNoticeMessage:
                        controller.currentLocationNotice?.message,
                    controllerErrorMessage: controller.lastError?
                        .localizedDescription,
                    refresh: refresh,
                    cancel: controller.cancelRefresh,
                    dismissError: controller.clearError,
                    openGuidance: openGuidance
                )
                .accessibilityIdentifier("arkfile_weather_root")
            } else {
                firstBriefingState
                    .accessibilityIdentifier("arkfile_weather_root")
            }
        }
        .background(Color.arkAppBackground.ignoresSafeArea())
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if controller.settings.savedLocation != nil,
                   !isChoosingLocation {
                    Menu {
                        Button {
                            isChoosingLocation = true
                        } label: {
                            Label("Change Location", systemImage: "mappin.and.ellipse")
                        }
                        Button(action: refresh) {
                            Label("Update Now", systemImage: "arrow.clockwise")
                        }
                        .disabled(controller.isLoading)
                        Divider()
                        Toggle(
                            "Automatic Updates",
                            isOn: automaticRefreshBinding
                        )
                        Toggle(
                            "Wi-Fi Only",
                            isOn: wifiOnlyBinding
                        )
                        .disabled(!controller.settings.automaticRefreshEnabled)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Weather options")
                }
            }
        }
        .task {
            await controller.load()
        }
        .task(id: controller.settings.savedLocation?.revision) {
            guard controller.settings.savedLocation != nil else { return }
            await controller.briefingOpened()
        }
        .sheet(isPresented: $isShowingMapPicker) {
            NavigationStack {
                ArkFileOfflineMapView(
                    contentRoot: contentRoot,
                    initialSelectedCoordinate: initialMapCoordinate,
                    onSelectCoordinate: useMapCoordinate
                )
                .navigationTitle("Choose Weather Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isShowingMapPicker = false
                        }
                    }
                }
            }
        }
        .sheet(item: $guidanceTarget) { target in
            NavigationStack {
                ArkFileSurvivalGuideView(
                    initialSectionID: target.sectionID,
                    initialBlockID: target.blockID
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            guidanceTarget = nil
                        }
                    }
                }
            }
        }
        .onDisappear {
            cancelCurrentLocationSelection()
        }
    }

    private var matchingSnapshot: ArkFileWeatherSnapshot? {
        ArkFileSavedWeatherPresentation.matchingSnapshot(
            settings: controller.settings,
            snapshot: controller.snapshot
        )
    }

    private var initialMapCoordinate: ArkFileMapCoordinate? {
        guard let coordinate = controller.settings.savedLocation?.coordinate else {
            return nil
        }
        return ArkFileMapCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private var locationSetup: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                setupIntroduction
                if let error = controller.lastError {
                    ArkFileSavedWeatherSectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                error.localizedDescription,
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.subheadline)
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                            Button("Dismiss") {
                                controller.clearError()
                            }
                            .frame(minHeight: 44)
                            if error == .locationPermissionDenied
                                || error == .locationServicesDisabled {
                                Button("Open ArkFile Settings") {
                                    guard let url = URL(
                                        string: UIApplication
                                            .openSettingsURLString
                                    ) else {
                                        return
                                    }
                                    UIApplication.shared.open(url)
                                }
                                .frame(minHeight: 44)
                            }
                            if controller.canResetSavedWeatherData {
                                Button(
                                    "Reset Weather Data",
                                    role: .destructive
                                ) {
                                    Task {
                                        await controller.deleteSavedWeather()
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
                currentLocationChoice
                Button {
                    withAnimation(.easeInOut) {
                        showsOtherPlaceOptions.toggle()
                    }
                } label: {
                    Label(
                        showsOtherPlaceOptions ? "Hide Other Places" : "Choose Another Place",
                        systemImage: showsOtherPlaceOptions ? "chevron.up" : "mappin.and.ellipse"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.arkPrimary)

                if showsOtherPlaceOptions {
                    savedWaypointChoice
                    mapChoice
                }

                if controller.settings.savedLocation != nil {
                    Button("Cancel Location Change") {
                        cancelCurrentLocationSelection()
                        isChoosingLocation = false
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(16)
            .frame(
                maxWidth:
                    ArkFileSavedWeatherLayoutPolicy.readableContentMaxWidth
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var setupIntroduction: some View {
        ArkFileSavedWeatherSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Save weather for offline use", systemImage: "sun.max.fill")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkTextPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(
                    "Save the latest National Weather Service briefing for one "
                    + "supported U.S. location so it remains readable without a network. New "
                    + "updates replace the older saved briefing."
                )
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text(
                        "ArkFile sends the selected location to the National "
                        + "Weather Service and saves the result on this device."
                    )
                } icon: {
                    Image(systemName: "lock.shield")
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(Color.arkTextPrimary)

            }
        }
    }

    private var currentLocationChoice: some View {
        ArkFileSavedWeatherSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(
                    "Use Current Location",
                    systemImage: "location"
                )
                Text(
                    "ArkFile saves weather where you are and updates the saved "
                        + "location after meaningful travel while the app is open. "
                        + "It never requests your location in the background."
                )
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: useCurrentLocation) {
                    Label(
                        controller.isLoading
                            || isRequestingCurrentLocation
                            ? "Getting Location…"
                            : "Use Current Location",
                        systemImage: "location.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.arkPrimary)
                .disabled(
                    controller.isLoading || isRequestingCurrentLocation
                )
            }
        }
    }

    @ViewBuilder
    private var savedWaypointChoice: some View {
        if !waypointStore.waypoints.isEmpty {
            ArkFileSavedWeatherSectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading(
                        "Use a Saved Map Waypoint",
                        systemImage: "mappin.circle"
                    )
                    Text(
                        "Copies the waypoint coordinate into Weather. "
                        + "Changing or deleting the waypoint later does not move the forecast."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(waypointStore.waypoints) { waypoint in
                        Button {
                            selectWaypoint(waypoint)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(
                                    systemName: waypoint.kind?.systemImage
                                        ?? "mappin.circle.fill"
                                )
                                .foregroundStyle(Color.arkPrimary)
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(waypoint.name)
                                        .foregroundStyle(Color.arkTextPrimary)
                                    Text(waypoint.coordinateText)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Color.arkTextMuted)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.arkTextMuted)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Use waypoint \(waypoint.name), \(waypoint.coordinateText)"
                        )

                        if waypoint.id != waypointStore.waypoints.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var mapChoice: some View {
        ArkFileSavedWeatherSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Choose on Offline Map", systemImage: "map")
                Text(
                    "Choose a different place without entering latitude or longitude."
                )
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: chooseOnMap) {
                    Label("Open Offline Map", systemImage: "map.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Color.arkPrimary)
            }
        }
    }

    private var automaticRefreshBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.automaticRefreshEnabled },
            set: { enabled in
                Task {
                    await controller.setAutomaticRefreshEnabled(enabled)
                }
            }
        )
    }

    private var wifiOnlyBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.refreshOnWiFiOnly },
            set: { enabled in
                Task {
                    await controller.setRefreshOnWiFiOnly(enabled)
                }
            }
        )
    }

    private var firstBriefingState: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ArkFileSavedWeatherSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            controller.connectivity == .offline
                                ? "No saved weather yet"
                                : "Ready to save weather",
                            systemImage: controller.connectivity == .offline
                                ? "wifi.slash"
                                : "arrow.down.circle"
                        )
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                        .accessibilityAddTraits(.isHeader)

                        if let location = controller.settings.savedLocation {
                            Text(location.displayName)
                                .font(.headline)
                                .foregroundStyle(Color.arkTextPrimary)
                        }

                        if controller.isCheckingCurrentLocation {
                            Label(
                                "Checking current location…",
                                systemImage: "location.circle"
                            )
                            .font(.subheadline)
                            .foregroundStyle(Color.arkPrimary)
                        } else if let notice =
                            controller.currentLocationNotice {
                            Label(
                                notice.message,
                                systemImage: "location.slash"
                            )
                            .font(.subheadline)
                            .foregroundStyle(Color.orange)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }

                        Text(
                            controller.connectivity == .offline
                                ? "Connect once and tap Update Now to save this location's first briefing."
                                : "Tap Update Now to download this location's first briefing."
                        )
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)

                        if controller.isLoading {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Connecting directly to NOAA/NWS…")
                                }
                                Button {
                                    controller.cancelRefresh()
                                } label: {
                                    Label(
                                        "Cancel Update",
                                        systemImage: "xmark.circle"
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 44
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.arkPrimary)
                            }
                            .foregroundStyle(Color.arkTextMuted)
                        } else {
                            Button(action: refresh) {
                                Label("Update Now", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.arkPrimary)
                        }

                        if controller.lastError != nil {
                            weatherError
                        }

                        Button("Choose a Different Location") {
                            isChoosingLocation = true
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .padding(16)
            .frame(
                maxWidth:
                    ArkFileSavedWeatherLayoutPolicy.readableContentMaxWidth
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var weatherError: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                controller.lastError?.localizedDescription
                    ?? "Weather could not finish the last request. "
                    + "Any earlier saved briefing is unchanged.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") {
                controller.clearError()
            }
            .frame(minHeight: 44)
            if controller.lastError == .storageWrite {
                Text(
                    "Free space in "
                        + "\(ArkFileDeviceCopy.currentStorageSettingsPath), "
                        + "then retry."
                )
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
                Button("Retry Update", action: refresh)
                    .frame(minHeight: 44)
            }
        }
    }

    private func sectionHeading(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(Color.arkTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func useCurrentLocation() {
        cancelCurrentLocationSelection()
        if let requestCurrentLocationOverride {
            requestCurrentLocationOverride()
            return
        }
        currentLocationTask = Task { @MainActor in
            isRequestingCurrentLocation = true
            defer { isRequestingCurrentLocation = false }
            await controller.saveCurrentLocation(displayName: "Current Location")
            guard !Task.isCancelled else { return }
            if controller.settings.savedLocation != nil {
                isChoosingLocation = false
            }
            currentLocationTask = nil
        }
    }

    private func selectWaypoint(_ waypoint: ArkFileMapWaypoint) {
        cancelCurrentLocationSelection()
        if let selectWaypointOverride {
            selectWaypointOverride(waypoint)
            isChoosingLocation = false
            return
        }
        let coordinate = ArkFileWeatherCoordinate(
            latitude: waypoint.latitude,
            longitude: waypoint.longitude
        )
        Task {
            await controller.saveLocation(
                coordinate: coordinate,
                displayName: waypoint.name,
                timeZoneIdentifier: nil,
                source: .savedWaypoint,
                measuredAt: nil,
                horizontalAccuracyMeters: nil,
                refreshImmediately: true
            )
            isChoosingLocation = false
        }
    }

    private func chooseOnMap() {
        cancelCurrentLocationSelection()
        if let chooseMapOverride {
            chooseMapOverride()
        } else {
            isShowingMapPicker = true
        }
    }

    private func useMapCoordinate(_ coordinate: ArkFileMapCoordinate) {
        cancelCurrentLocationSelection()
        isShowingMapPicker = false
        let weatherCoordinate = ArkFileWeatherCoordinate(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        let name = String(
            format: "%.4f, %.4f",
            coordinate.latitude,
            coordinate.longitude
        )
        if let saveManualLocationOverride {
            saveManualLocationOverride(weatherCoordinate, name)
            isChoosingLocation = false
            return
        }
        Task {
            await controller.saveLocation(
                coordinate: weatherCoordinate,
                displayName: name,
                timeZoneIdentifier: nil,
                source: .offlineMap,
                measuredAt: nil,
                horizontalAccuracyMeters: nil,
                refreshImmediately: true
            )
            isChoosingLocation = false
        }
    }

    private func refresh() {
        Task {
            await controller.refreshManually()
        }
    }

    private func cancelCurrentLocationSelection() {
        currentLocationTask?.cancel()
        currentLocationTask = nil
        isRequestingCurrentLocation = false
        controller.cancelCurrentLocationRequest()
    }

    private func openGuidance(_ link: ArkFileWeatherPreparednessLink) {
        if let openGuidanceOverride {
            openGuidanceOverride(link)
        } else {
            guidanceTarget = link
        }
    }

}

struct ArkFileSavedWeatherSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.arkAppSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkAppBorder, lineWidth: 1)
            }
    }
}
#endif
