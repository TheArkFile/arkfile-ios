// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

#if os(iOS)
import Charts
import SwiftUI
import UIKit

struct ArkFileSavedWeatherBriefing: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    @State private var now = Date()
    @State private var selectedHourlyTime: Date?
    @State private var selectedDailyID: String?
    @State private var selectedOutlookID: String?
    @State private var sourcesAreExpanded = false

    let settings: ArkFileWeatherSettings
    let snapshot: ArkFileWeatherSnapshot
    let connectivity: ArkFileWeatherConnectivity
    let isRefreshing: Bool
    let isCheckingCurrentLocation: Bool
    let currentLocationNoticeMessage: String?
    let controllerErrorMessage: String?
    let refresh: () -> Void
    let cancel: () -> Void
    let dismissError: () -> Void
    let openGuidance: (ArkFileWeatherPreparednessLink) -> Void

    private var locationTimeZoneID: String? {
        settings.savedLocation?.timeZoneIdentifier
    }

    private var displayUnits: ArkFileSavedWeatherPresentation.DisplayUnits {
        ArkFileSavedWeatherPresentation.displayUnits(
            preference: settings.unitPreference,
            locale: locale
        )
    }

    private var widthClass: ArkFileSavedWeatherLayoutPolicy.WidthClass {
        switch horizontalSizeClass {
        case .compact:
            .compact
        case .regular:
            .regular
        case nil:
            .unspecified
        @unknown default:
            .unspecified
        }
    }

    private func usesTwoColumnBriefing(
        availableWidth: CGFloat
    ) -> Bool {
        ArkFileSavedWeatherLayoutPolicy.prefersTwoColumnBriefing(
            widthClass: widthClass,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            availableWidth: availableWidth
        )
    }

    private var briefingColumns: [GridItem] {
        let item = GridItem(
            .flexible(
                minimum:
                    ArkFileSavedWeatherLayoutPolicy
                        .briefingColumnMinimumWidth,
                maximum:
                    ArkFileSavedWeatherLayoutPolicy
                        .briefingColumnMaximumWidth
            ),
            spacing:
                ArkFileSavedWeatherLayoutPolicy
                    .briefingColumnSpacing,
            alignment: .top
        )
        return [item, item]
    }

    var body: some View {
        GeometryReader { geometry in
            let readableWidth = min(
                geometry.size.width,
                ArkFileSavedWeatherLayoutPolicy
                    .readableContentMaxWidth
            )
            let availableGridWidth = max(0, readableWidth - 32)
            let usesTwoColumns = usesTwoColumnBriefing(
                availableWidth: availableGridWidth
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    alertsSection
                    pairedSections(usesTwoColumns: usesTwoColumns) {
                        freshnessSection
                    } second: {
                        updateStatusSection
                    }

                    let highlights = ArkFileSavedWeatherPresentation
                        .planningHighlights(
                            snapshot: snapshot,
                            settings: settings,
                            at: now,
                            locale: locale
                        )
                    if !highlights.isEmpty {
                        planningHighlightsSection(highlights)
                    }

                    hourlySection
                    dailySection
                    if FeatureFlags.savedWeatherClimateOutlooks {
                        pairedSections(
                            usesTwoColumns: usesTwoColumns
                        ) {
                            astronomySection
                        } second: {
                            climateOutlookSection
                        }
                    } else {
                        astronomySection
                    }
                    pairedSections(
                        usesTwoColumns: usesTwoColumns
                    ) {
                        radioSection
                    } second: {
                        relatedGuidanceSection
                    }
                    sourcesAndLimitationsSection
                }
                .padding(16)
                .frame(
                    maxWidth:
                        ArkFileSavedWeatherLayoutPolicy
                            .readableContentMaxWidth
                )
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .refreshable {
                refresh()
            }
            .task(id: snapshot.assembledAt) {
                while !Task.isCancelled {
                    let deadline = ArkFileSavedWeatherPresentation
                        .nextPresentationUpdate(
                            snapshot: snapshot,
                            after: now
                        )
                    let interval = max(
                        0.05,
                        deadline.timeIntervalSinceNow + 0.05
                    )
                    try? await Task.sleep(
                        nanoseconds:
                            UInt64(interval * 1_000_000_000)
                    )
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
        }
    }

    @ViewBuilder
    private func pairedSections<First: View, Second: View>(
        usesTwoColumns: Bool,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second
    ) -> some View {
        if usesTwoColumns {
            LazyVGrid(
                columns: briefingColumns,
                alignment: .leading,
                spacing:
                    ArkFileSavedWeatherLayoutPolicy
                        .briefingColumnSpacing
            ) {
                first()
                second()
            }
        } else {
            first()
            second()
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        sectionCard(
            title: "Official Alerts",
            systemImage: "exclamationmark.triangle.fill"
        ) {
            let alerts = ArkFileSavedWeatherPresentation.visibleAlerts(
                in: snapshot,
                at: now
            )

            if snapshot.alerts.availability == .failed {
                statusMessage(
                    "Alerts could not be updated. Any alert shown below is "
                        + "from an earlier successful check.",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    color: .orange
                )
            }

            if alerts.isEmpty {
                Text(
                    ArkFileWeatherAlertPresentationSemantics.emptyStateMessage(
                        for: snapshot.alerts,
                        connectivity: connectivity,
                        at: now
                    )
                )
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(alerts, id: \.id) { alert in
                    ArkFileSavedWeatherAlertCard(
                        alert: alert,
                        component: snapshot.alerts,
                        connectivity: connectivity,
                        timeZoneID: locationTimeZoneID,
                        now: now
                    )
                    if alert.id != alerts.last?.id {
                        Divider()
                    }
                }
            }
            componentSourceTime(snapshot.alerts)
        }
    }

    // MARK: Freshness and refresh

    private var freshnessSection: some View {
        let freshness = primaryFreshness
        let hasCoreFailure = ArkFileSavedWeatherPresentation
            .hasCoreRefreshFailure(in: snapshot)
        let color: Color = switch freshness {
        case .fresh:
            hasCoreFailure
                ? Color.orange
                : (
                    connectivity == .online
                        ? Color.arkPrimaryHover
                        : Color.orange
                )
        case .aging:
            Color.orange
        case .stale, .expired, .historical, .clockUncertain:
            Color.red
        case nil:
            Color.orange
        }
        let image: String = switch freshness {
        case .clockUncertain:
            "clock.badge.exclamationmark"
        case _ where hasCoreFailure:
            "exclamationmark.arrow.triangle.2.circlepath"
        case .fresh where connectivity == .online:
            "checkmark.circle.fill"
        case .expired, .historical:
            "calendar.badge.exclamationmark"
        default:
            connectivity == .offline ? "wifi.slash" : "clock.badge.exclamationmark"
        }

        return ArkFileSavedWeatherSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: image)
                        .font(.title3)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(freshnessTitle)
                            .font(.headline)
                            .foregroundStyle(Color.arkTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        if let location = settings.savedLocation {
                            Text(
                                ArkFileSavedWeatherPresentation
                                    .locationDisplayName(
                                        settings: settings,
                                        snapshot: snapshot
                                    ) ?? location.displayName
                            )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.arkTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let accuracy = currentLocationAccuracy(location) {
                                Text(accuracy)
                                    .font(.caption)
                                    .foregroundStyle(Color.arkTextMuted)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                            }
                        }
                        Text(briefingFreshnessMessage)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                Label {
                    Text(
                        ArkFileSavedWeatherPresentation
                            .savedOfflineExplanation(
                                connectivity: connectivity
                            )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .foregroundStyle(Color.arkPrimary)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(Color.arkTextPrimary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.arkAppSurfaceSecondary)
                .clipShape(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "arkfile_weather_offline_save_explanation"
                )

                if freshness == .clockUncertain {
                    Button("Open Settings") {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                    .frame(minHeight: 44)
                    .accessibilityHint(
                        "Then open General, Date and Time to review the device clock."
                    )
                }

                Button(action: isRefreshing ? cancel : refresh) {
                    Label(
                        isRefreshing ? "Cancel Update" : "Update Now",
                        systemImage:
                            isRefreshing ? "xmark.circle" : "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.arkPrimary)
            }
        }
    }

    @ViewBuilder
    private var updateStatusSection: some View {
        if isRefreshing
            || isCheckingCurrentLocation
            || currentLocationNoticeMessage != nil
            || controllerErrorMessage != nil {
            ArkFileSavedWeatherSectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    if isCheckingCurrentLocation {
                        HStack(alignment: .center, spacing: 10) {
                            ProgressView()
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Checking Current Location")
                                    .font(.headline)
                                    .foregroundStyle(Color.arkTextPrimary)
                                Text(
                                    "The saved briefing remains available "
                                        + "while ArkFile checks for meaningful travel."
                                )
                                .font(.subheadline)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if isRefreshing {
                        HStack(alignment: .center, spacing: 10) {
                            ProgressView()
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Updating Weather")
                                    .font(.headline)
                                    .foregroundStyle(Color.arkTextPrimary)
                                Text(
                                    "The last saved briefing remains available "
                                        + "while ArkFile checks each source."
                                )
                                .font(.subheadline)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let currentLocationNoticeMessage {
                        statusMessage(
                            currentLocationNoticeMessage,
                            systemImage: "location.slash",
                            color: .orange
                        )
                    }
                    if let controllerErrorMessage {
                        statusMessage(
                            controllerErrorMessage,
                            systemImage: "exclamationmark.triangle",
                            color: .red
                        )
                        Button("Dismiss Update Message", action: dismissError)
                            .frame(minHeight: 44)
                        if !isRefreshing,
                           snapshot.alerts.availability == .failed {
                            Button("Retry Alerts", action: refresh)
                                .frame(minHeight: 44)
                        }
                        if !isRefreshing,
                           (
                               snapshot.hourly.availability == .failed
                                   || snapshot.daily.availability == .failed
                           ) {
                            Button("Retry Forecast", action: refresh)
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
    }

    // MARK: Planning highlights

    private func planningHighlightsSection(
        _ highlights: [ArkFileSavedWeatherPlanningHighlight]
    ) -> some View {
        sectionCard(
            title: "Planning Highlights",
            systemImage: "list.bullet.clipboard"
        ) {
            Text(
                "Neutral summaries calculated from this saved forecast—not "
                    + "official alerts, risk ratings, or safety determinations."
            )
            .font(.footnote)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(highlights) { highlight in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: highlight.systemImage)
                        .foregroundStyle(Color.arkPrimary)
                        .frame(width: 28)
                        .frame(minHeight: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlight.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.arkTextPrimary)
                        Text(highlight.detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Forecast

    private var hourlySection: some View {
        sectionCard(
            title: usesCurrentForecastLanguage
                ? "Next 24 Hours"
                : "Saved Hourly Forecast",
            systemImage: "clock"
        ) {
            let periods = ArkFileSavedWeatherPresentation.futureHourlyPeriods(
                in: snapshot,
                at: now
            )
            componentFailureNotice(
                snapshot.hourly,
                message: "The hourly forecast could not be updated. "
                    + "Showing periods from the earlier saved result."
            )
            if periods.isEmpty {
                componentMessage(
                    snapshot.hourly,
                    unavailable: "No usable hourly periods remain in the saved forecast."
                )
            } else if dynamicTypeSize.isAccessibilitySize {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(periods, id: \.id) { period in
                        hourlyPeriod(period)
                        if period.id != periods.last?.id {
                            Divider()
                        }
                    }
                }
            } else {
                hourlyChart(periods)
            }
            componentSourceTime(snapshot.hourly)
            Text(
                "“Estimated feels like” is calculated on this device from "
                    + "saved NWS temperature, humidity, and wind using "
                    + "NOAA/NWS heat-index or wind-chill equations when applicable."
            )
            .font(.caption2)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hourlyChart(
        _ periods: [ArkFileWeatherHourlyPeriod]
    ) -> some View {
        let chartPeriods = periods.filter {
            $0.temperatureCelsius?.isFinite == true
        }
        let selected = selectedHourlyPeriod(in: periods)
        let temperatures = chartPeriods.compactMap(chartTemperature)
        let temperatureDomain = ArkFileSavedWeatherPresentation
            .hourlyChartTemperatureDomain(temperatures)

        return VStack(alignment: .leading, spacing: 12) {
            if let selected {
                selectedHourlyDetail(selected)
                    .accessibilityIdentifier(
                        "arkfile_weather_selected_hour_detail"
                    )
            }

            if chartPeriods.isEmpty {
                Text(
                    "Temperature values are unavailable for this chart. The "
                        + "saved forecast details are shown above."
                )
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
            } else if let temperatureDomain {
                hourlyChartLegend

                Chart(chartPeriods, id: \.id) { period in
                    if let temperature = chartTemperature(period) {
                        AreaMark(
                            x: .value("Time", period.startsAt),
                            yStart: .value(
                                "Temperature baseline",
                                temperatureDomain.lowerBound
                            ),
                            yEnd: .value("Temperature", temperature)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.arkAccent.opacity(0.32),
                                    Color.arkAccent.opacity(0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", period.startsAt),
                            y: .value("Temperature", temperature),
                            series: .value("Series", "Temperature")
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.arkPrimary)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 3,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )

                        if selected?.id == period.id {
                            RuleMark(
                                x: .value("Selected time", period.startsAt)
                            )
                            .foregroundStyle(Color.arkTextMuted.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))

                            PointMark(
                                x: .value("Selected time", period.startsAt),
                                y: .value("Selected temperature", temperature)
                            )
                            .foregroundStyle(Color.arkAccent)
                            .symbolSize(85)
                        }
                    }

                    if let precipitation =
                        ArkFileSavedWeatherPresentation
                            .precipitationChartValue(
                                fraction:
                                    period
                                        .precipitationProbabilityFraction,
                                temperatureDomain: temperatureDomain
                            ) {
                        LineMark(
                            x: .value("Time", period.startsAt),
                            y: .value(
                                "Precipitation probability",
                                precipitation
                            ),
                            series: .value(
                                "Series",
                                "Precipitation probability"
                            )
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.arkAccentSecondary)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: [5, 4]
                            )
                        )

                        if selected?.id == period.id {
                            PointMark(
                                x: .value(
                                    "Selected time",
                                    period.startsAt
                                ),
                                y: .value(
                                    "Selected precipitation probability",
                                    precipitation
                                )
                            )
                            .foregroundStyle(Color.arkAccentSecondary)
                            .symbolSize(65)
                        }
                    }
                }
                .frame(height: 190)
                .chartYScale(domain: temperatureDomain)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let temperature = value.as(Double.self) {
                                Text(
                                    "\(Int(temperature.rounded()))°"
                                )
                            }
                        }
                    }
                    AxisMarks(
                        position: .trailing,
                        values: [
                            temperatureDomain.lowerBound,
                            (
                                temperatureDomain.lowerBound
                                    + temperatureDomain.upperBound
                            ) / 2,
                            temperatureDomain.upperBound
                        ]
                    ) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let chartValue = value.as(Double.self),
                               let percentage =
                                ArkFileSavedWeatherPresentation
                                    .precipitationPercent(
                                        chartValue: chartValue,
                                        temperatureDomain:
                                            temperatureDomain
                                    ) {
                                Text("\(percentage)%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(
                        values: .stride(by: .hour, count: 6)
                    ) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartXSelection(value: $selectedHourlyTime)
                .accessibilityLabel(
                    "Temperature and precipitation probability over the "
                        + "next 24 hours"
                )
                .accessibilityHint(
                    "Drag across the chart to select an hour and update the "
                        + "forecast details above."
                )
            }
        }
    }

    private var hourlyChartLegend: some View {
        HStack(spacing: 14) {
            Label(
                displayUnits == .us ? "Temperature (°F)" : "Temperature (°C)",
                systemImage: "thermometer.medium"
            )
            .foregroundStyle(Color.arkPrimary)

            Label("Precipitation (%)", systemImage: "drop.fill")
                .foregroundStyle(Color.arkAccentSecondary)
        }
        .font(.caption2.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            displayUnits == .us
                ? "Dark green line: temperature in degrees Fahrenheit. "
                    + "Orange dashed line: precipitation probability in percent."
                : "Dark green line: temperature in degrees Celsius. "
                    + "Orange dashed line: precipitation probability in percent."
        )
    }

    private func selectedHourlyPeriod(
        in periods: [ArkFileWeatherHourlyPeriod]
    ) -> ArkFileWeatherHourlyPeriod? {
        guard let selectedHourlyTime else { return periods.first }
        return periods.min {
            abs($0.startsAt.timeIntervalSince(selectedHourlyTime))
                < abs($1.startsAt.timeIntervalSince(selectedHourlyTime))
        }
    }

    private func chartTemperature(
        _ period: ArkFileWeatherHourlyPeriod
    ) -> Double? {
        guard let celsius = period.temperatureCelsius, celsius.isFinite else {
            return nil
        }
        switch displayUnits {
        case .us:
            return celsius * 9 / 5 + 32
        case .metric:
            return celsius
        }
    }

    private func hourlyPeriod(
        _ period: ArkFileWeatherHourlyPeriod
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                ArkFileSavedWeatherPresentation.time(
                    period.startsAt,
                    timeZoneID: locationTimeZoneID
                )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.arkTextMuted)

            Image(
                systemName: ArkFileSavedWeatherPresentation
                    .conditionSystemImage(period.condition)
            )
            .font(.title2)
            .foregroundStyle(Color.arkPrimary)
            .accessibilityHidden(true)

            if let temperature = ArkFileSavedWeatherPresentation.temperature(
                celsius: period.temperatureCelsius,
                units: displayUnits
            ) {
                Text(temperature)
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(Color.arkTextPrimary)
            }
            if let apparent = ArkFileSavedWeatherPresentation.temperature(
                celsius: period.apparentTemperatureCelsius,
                units: displayUnits
            ) {
                Text("Estimated feels like \(apparent)")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }

            Text(period.summary)
                .font(.caption)
                .foregroundStyle(Color.arkTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let precipitation = ArkFileSavedWeatherPresentation.probability(
                period.precipitationProbabilityFraction
            ) {
                Label(
                    "\(precipitation) precipitation",
                    systemImage: "drop.fill"
                )
                .font(.caption2)
                .foregroundStyle(Color.arkTextMuted)
            }

            if let wind = ArkFileSavedWeatherPresentation.windSpeed(
                metersPerSecond: period.windSpeedMetersPerSecond,
                units: displayUnits
            ) {
                let direction = ArkFileSavedWeatherPresentation
                    .windDirection(degrees: period.windDirectionDegrees)
                Label(
                    [direction, wind].compactMap { $0 }.joined(separator: " "),
                    systemImage: "wind"
                )
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
            if let gust = ArkFileSavedWeatherPresentation.windSpeed(
                metersPerSecond: period.windGustMetersPerSecond,
                units: displayUnits
            ) {
                Text("Gusts \(gust)")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
            if let humidity = ArkFileSavedWeatherPresentation.probability(
                period.relativeHumidityFraction
            ) {
                Text("Humidity \(humidity)")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
            if let dewPoint = ArkFileSavedWeatherPresentation.temperature(
                celsius: period.dewPointCelsius,
                units: displayUnits
            ) {
                Text("Dew point \(dewPoint)")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func selectedHourlyDetail(
        _ period: ArkFileWeatherHourlyPeriod
    ) -> some View {
        let temperature = ArkFileSavedWeatherPresentation.temperature(
            celsius: period.temperatureCelsius,
            units: displayUnits
        )
        let apparentTemperature =
            ArkFileSavedWeatherPresentation.temperature(
                celsius: period.apparentTemperatureCelsius,
                units: displayUnits
            )
        let precipitation = ArkFileSavedWeatherPresentation.probability(
            period.precipitationProbabilityFraction
        )
        let humidity = ArkFileSavedWeatherPresentation.probability(
            period.relativeHumidityFraction
        )
        let wind = ArkFileSavedWeatherPresentation.windSpeed(
            metersPerSecond: period.windSpeedMetersPerSecond,
            units: displayUnits
        )
        let windDirection = ArkFileSavedWeatherPresentation.windDirection(
            degrees: period.windDirectionDegrees
        )
        let windDescription = [windDirection, wind]
            .compactMap { $0 }
            .joined(separator: " ")
        let gust = ArkFileSavedWeatherPresentation.windSpeed(
            metersPerSecond: period.windGustMetersPerSecond,
            units: displayUnits
        )
        let dewPoint = ArkFileSavedWeatherPresentation.temperature(
            celsius: period.dewPointCelsius,
            units: displayUnits
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    ArkFileSavedWeatherPresentation.time(
                        period.startsAt,
                        timeZoneID: locationTimeZoneID
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.arkTextMuted)

                Spacer()

                Image(
                    systemName: ArkFileSavedWeatherPresentation
                        .conditionSystemImage(period.condition)
                )
                .font(.title3)
                .foregroundStyle(Color.arkPrimary)
                .accessibilityHidden(true)
            }

            Text(temperature ?? "Temperature unavailable")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(Color.arkTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(period.summary)
                .font(.caption)
                .foregroundStyle(Color.arkTextPrimary)
                .lineLimit(2, reservesSpace: true)

            Divider()

            Grid(
                alignment: .leading,
                horizontalSpacing: 12,
                verticalSpacing: 7
            ) {
                GridRow {
                    selectedHourlyMetric(
                        "Precipitation",
                        value: precipitation,
                        systemImage: "drop.fill"
                    )
                    selectedHourlyMetric(
                        "Humidity",
                        value: humidity,
                        systemImage: "humidity.fill"
                    )
                }
                GridRow {
                    selectedHourlyMetric(
                        "Wind",
                        value: windDescription.isEmpty
                            ? nil
                            : windDescription,
                        systemImage: "wind"
                    )
                    selectedHourlyMetric(
                        "Gusts",
                        value: gust,
                        systemImage: "wind.circle"
                    )
                }
                GridRow {
                    selectedHourlyMetric(
                        "Feels like",
                        value: apparentTemperature,
                        systemImage: "thermometer.medium"
                    )
                    selectedHourlyMetric(
                        "Dew point",
                        value: dewPoint,
                        systemImage: "thermometer.low"
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func selectedHourlyMetric(
        _ title: String,
        value: String?,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(Color.arkTextMuted)
                .lineLimit(1)
            Text(value ?? "—")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.arkTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            value.map { "\(title) \($0)" } ?? "\(title) unavailable"
        )
    }

    private var dailySection: some View {
        sectionCard(
            title: usesCurrentForecastLanguage
                ? "Seven-Day Forecast"
                : "Saved Seven-Day Forecast",
            systemImage: "calendar"
        ) {
            let periods = ArkFileSavedWeatherPresentation.futureDailyPeriods(
                in: snapshot,
                at: now
            )
            componentFailureNotice(
                snapshot.daily,
                message: "The daily forecast could not be updated. "
                    + "Showing periods from the earlier saved result."
            )
            if periods.isEmpty {
                componentMessage(
                    snapshot.daily,
                    unavailable: "No usable daily periods remain in the saved forecast."
                )
            } else if dynamicTypeSize.isAccessibilitySize {
                ForEach(periods, id: \.id) { period in
                    dailyPeriod(period)
                    if period.id != periods.last?.id {
                        Divider()
                    }
                }
            } else {
                let selected = selectedDailyPeriod(in: periods)
                let selectedAstronomy = selected.flatMap {
                    ArkFileSavedWeatherPresentation.astronomyDay(
                        in: snapshot,
                        timeZoneID: locationTimeZoneID,
                        matching: $0.startsAt
                    )
                }
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 92, maximum: 130),
                            spacing: 8
                        )
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(periods, id: \.id) { period in
                        Button {
                            selectedDailyID = period.id
                        } label: {
                            dailyCalendarCell(
                                period,
                                isSelected:
                                    selectedDailyPeriod(in: periods)?.id
                                        == period.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            "Shows this day's complete saved forecast below."
                        )
                    }
                    dailySunCell(selectedAstronomy)
                    dailyMoonCell(selectedAstronomy)
                }

                if let selected {
                    Divider()
                    dailyPeriod(selected)
                        .accessibilityIdentifier(
                            "arkfile_weather_selected_day_detail"
                        )
                }
            }
            componentSourceTime(snapshot.daily)
        }
    }

    private func dailyPeriod(
        _ period: ArkFileWeatherDailyPeriod
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: ArkFileSavedWeatherPresentation
                    .conditionSystemImage(period.condition)
            )
            .font(.title3)
            .foregroundStyle(Color.arkPrimary)
            .frame(width: 30)
            .frame(minHeight: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    ArkFileSavedWeatherPresentation.dayAndDate(
                        period.startsAt,
                        timeZoneID: locationTimeZoneID
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.arkTextPrimary)

                Text(period.summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)

                let low = ArkFileSavedWeatherPresentation.temperature(
                    celsius: period.minimumTemperatureCelsius,
                    units: displayUnits
                )
                let high = ArkFileSavedWeatherPresentation.temperature(
                    celsius: period.maximumTemperatureCelsius,
                    units: displayUnits
                )
                let precipitation = ArkFileSavedWeatherPresentation.probability(
                    period.precipitationProbabilityFraction
                )
                HStack(spacing: 10) {
                    if let high {
                        Text("High \(high)")
                    }
                    if let low {
                        Text("Low \(low)")
                    }
                    if let precipitation {
                        Label(precipitation, systemImage: "drop.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func dailyCalendarCell(
        _ period: ArkFileWeatherDailyPeriod,
        isSelected: Bool
    ) -> some View {
        let low = ArkFileSavedWeatherPresentation.temperature(
            celsius: period.minimumTemperatureCelsius,
            units: displayUnits
        )
        let high = ArkFileSavedWeatherPresentation.temperature(
            celsius: period.maximumTemperatureCelsius,
            units: displayUnits
        )
        let precipitation = ArkFileSavedWeatherPresentation.probability(
            period.precipitationProbabilityFraction
        )

        return VStack(spacing: 7) {
            Text(
                ArkFileSavedWeatherPresentation.compactDayAndDate(
                    period.startsAt,
                    timeZoneID: locationTimeZoneID
                )
            )
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)

            Image(
                systemName: ArkFileSavedWeatherPresentation
                    .conditionSystemImage(period.condition)
            )
            .font(.title3)
            .foregroundStyle(Color.arkPrimary)
            .accessibilityHidden(true)

            Text([high, low].compactMap { $0 }.joined(separator: " / "))
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let precipitation {
                Label(precipitation, systemImage: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 118)
        .background(
            isSelected
                ? Color.arkPrimary.opacity(0.14)
                : Color.arkAppSurfaceSecondary
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.arkPrimary : Color.arkAppBorder,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dailySunCell(
        _ day: ArkFileWeatherAstronomyDay?
    ) -> some View {
        VStack(spacing: 5) {
            Text("Selected day")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.arkAccentSecondary)
                .multilineTextAlignment(.center)

            Text("Sun Times")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)

            Image(systemName: "sun.and.horizon.fill")
                .font(.title3)
                .foregroundStyle(Color.arkAccentSecondary)
                .accessibilityHidden(true)

            astronomyGridValue(title: "Rise", date: day?.sunrise)
            astronomyGridValue(title: "Set", date: day?.sunset)
        }
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 118)
        .background(Color.arkAccentSecondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.arkAccentSecondary, lineWidth: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dailySunAccessibilityLabel(day))
        .accessibilityHint("Sunrise and sunset for the selected forecast day.")
        .accessibilityIdentifier("arkfile_weather_selected_day_sun")
    }

    private func dailyMoonCell(
        _ day: ArkFileWeatherAstronomyDay?
    ) -> some View {
        let illumination = day.flatMap {
            ArkFileSavedWeatherPresentation
                .moonIlluminationPercent($0.moonIlluminationFraction)
        }

        return VStack(spacing: 5) {
            Text("Selected day")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.arkAccentSecondary)
                .multilineTextAlignment(.center)

            Text("Moon Phase")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)

            Image(systemName: "moon.stars.fill")
                .font(.title3)
                .foregroundStyle(Color.arkAccentSecondary)
                .accessibilityHidden(true)

            if let day {
                Text(
                    ArkFileSavedWeatherPresentation
                        .moonPhaseName(day.moonPhase)
                )
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                if let illumination {
                    Text("Approx. \(illumination)% lit")
                        .font(.caption2)
                        .foregroundStyle(Color.arkTextMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .foregroundStyle(Color.arkTextPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 118)
        .background(Color.arkAccentSecondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.arkAccentSecondary, lineWidth: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dailyMoonAccessibilityLabel(day))
        .accessibilityHint(
            "Approximate moon phase for the selected forecast day."
        )
        .accessibilityIdentifier("arkfile_weather_selected_day_moon")
    }

    @ViewBuilder
    private func astronomyGridValue(
        title: String,
        date: Date?
    ) -> some View {
        if let date {
            Text(
                "\(title) "
                    + ArkFileSavedWeatherPresentation.time(
                        date,
                        timeZoneID: locationTimeZoneID
                    )
            )
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        } else {
            Text("\(title) unavailable")
                .font(.caption2)
                .foregroundStyle(Color.arkTextMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func dailySunAccessibilityLabel(
        _ day: ArkFileWeatherAstronomyDay?
    ) -> String {
        guard let day else {
            return "Selected day sun times unavailable"
        }
        let sunrise = day.sunrise.map {
            ArkFileSavedWeatherPresentation.time(
                $0,
                timeZoneID: locationTimeZoneID
            )
        } ?? "unavailable"
        let sunset = day.sunset.map {
            ArkFileSavedWeatherPresentation.time(
                $0,
                timeZoneID: locationTimeZoneID
            )
        } ?? "unavailable"
        return "Selected day sunrise \(sunrise), sunset \(sunset)"
    }

    private func dailyMoonAccessibilityLabel(
        _ day: ArkFileWeatherAstronomyDay?
    ) -> String {
        guard let day else {
            return "Selected day approximate moon phase unavailable"
        }
        let phase = ArkFileSavedWeatherPresentation
            .moonPhaseName(day.moonPhase)
        guard let illumination = ArkFileSavedWeatherPresentation
            .moonIlluminationPercent(day.moonIlluminationFraction) else {
            return "Selected day approximate moon phase \(phase)"
        }
        return "Selected day approximate moon phase \(phase), "
            + "\(illumination) percent illuminated"
    }

    private func selectedDailyPeriod(
        in periods: [ArkFileWeatherDailyPeriod]
    ) -> ArkFileWeatherDailyPeriod? {
        guard let selectedDailyID else { return periods.first }
        return periods.first(where: { $0.id == selectedDailyID })
            ?? periods.first
    }

    // MARK: Long-range outlook

    private var climateOutlookSection: some View {
        sectionCard(
            title: "Four-Week Outlook",
            systemImage: "calendar.badge.clock"
        ) {
            Text(
                "Broad probabilities for period-average temperature and "
                    + "precipitation—not a day-by-day forecast."
            )
            .font(.subheadline)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)

            let outlooks = ArkFileSavedWeatherPresentation
                .currentClimateOutlooks(in: snapshot, at: now)
            let expiredCount = ArkFileSavedWeatherPresentation
                .expiredClimateOutlookCount(in: snapshot, at: now)
            componentFailureNotice(
                snapshot.climateOutlooks,
                message: "Some outlook products could not be updated. "
                    + "Any earlier products keep their original source times."
            )
            if expiredCount > 0 {
                statusMessage(
                    outlooks.isEmpty
                        ? "All saved outlook periods have ended. Reconnect "
                            + "and update before using this section for planning."
                        : "\(expiredCount) ended outlook period"
                            + "\(expiredCount == 1 ? " was" : "s were") "
                            + "omitted.",
                    systemImage: "clock.badge.exclamationmark",
                    color: .orange
                )
            }
            if outlooks.isEmpty {
                componentMessage(
                    snapshot.climateOutlooks,
                    unavailable: "A NOAA Climate Prediction Center outlook is not saved for this point."
                )
            } else if dynamicTypeSize.isAccessibilitySize {
                ForEach(outlooks, id: \.id) { outlook in
                    climateOutlookDetail(outlook)

                    if outlook.id != outlooks.last?.id {
                        Divider()
                    }
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 92, maximum: 150),
                            spacing: 8
                        )
                    ],
                    spacing: 8
                ) {
                    ForEach(outlooks, id: \.id) { outlook in
                        let isSelected =
                            selectedClimateOutlook(in: outlooks)?.id
                                == outlook.id
                        Button {
                            selectedOutlookID = outlook.id
                        } label: {
                            Text(outlookTitle(outlook.period))
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.arkTextPrimary)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(
                                    isSelected
                                        ? Color.arkPrimary.opacity(0.14)
                                        : Color.arkAppSurfaceSecondary
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                    .stroke(
                                        isSelected
                                            ? Color.arkPrimary
                                            : Color.arkAppBorder,
                                        lineWidth: isSelected ? 2 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            isSelected ? .isSelected : []
                        )
                        .accessibilityHint(
                            "Shows this outlook period's details below."
                        )
                    }
                }

                if let selected = selectedClimateOutlook(in: outlooks) {
                    Divider()
                    climateOutlookDetail(selected)
                        .accessibilityIdentifier(
                            "arkfile_weather_selected_outlook_detail"
                        )
                }
            }
            componentSourceTime(snapshot.climateOutlooks)
        }
    }

    private func climateOutlookDetail(
        _ outlook: ArkFileWeatherClimateOutlook
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(outlookTitle(outlook.period))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.arkTextPrimary)
            Text(
                dateRange(
                    from: outlook.validFrom,
                    through: outlook.validUntil
                )
            )
            .font(.caption)
            .foregroundStyle(Color.arkTextMuted)
            Text("Issued \(sourceTimestamp(outlook.issuedAt))")
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)
            Text(
                "Temperature: "
                    + ArkFileSavedWeatherPresentation
                        .favoredCategory(outlook.temperature)
            )
            .font(.subheadline)
            Text(
                "Precipitation: "
                    + ArkFileSavedWeatherPresentation
                        .favoredCategory(outlook.precipitation)
            )
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func selectedClimateOutlook(
        in outlooks: [ArkFileWeatherClimateOutlook]
    ) -> ArkFileWeatherClimateOutlook? {
        guard let selectedOutlookID else { return outlooks.first }
        return outlooks.first(where: { $0.id == selectedOutlookID })
            ?? outlooks.first
    }

    // MARK: Astronomy

    private var astronomySection: some View {
        sectionCard(
            title: "Sun & Moon",
            systemImage: "sun.and.horizon.fill"
        ) {
            componentFailureNotice(
                snapshot.astronomy,
                message: "The astronomy summary could not be recalculated. "
                    + "Showing the earlier saved calculation."
            )
            if let day = astronomyDay {
                Text(
                    ArkFileSavedWeatherPresentation.dayAndDate(
                        day.localDayStart,
                        timeZoneID: locationTimeZoneID
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.arkTextPrimary)
                astronomyEvent(
                    "Civil dawn",
                    date: day.civilDawn,
                    systemImage: "sun.horizon"
                )
                astronomyEvent(
                    "Sunrise",
                    date: day.sunrise,
                    systemImage: "sunrise.fill"
                )
                astronomyEvent(
                    "Sunset",
                    date: day.sunset,
                    systemImage: "sunset.fill"
                )
                astronomyEvent(
                    "Civil dusk",
                    date: day.civilDusk,
                    systemImage: "sun.horizon.fill"
                )
                if let duration =
                    ArkFileSavedWeatherPresentation.daylightDuration(for: day) {
                    astronomyMetric(
                        "Daylight",
                        value: ArkFileSavedWeatherPresentation
                            .durationText(duration),
                        systemImage: "sun.max.fill"
                    )
                }
                if let remaining =
                    ArkFileSavedWeatherPresentation.daylightRemaining(
                        for: day,
                        at: now
                    ) {
                    astronomyMetric(
                        "Daylight remaining",
                        value: ArkFileSavedWeatherPresentation
                            .durationText(remaining),
                        systemImage: "hourglass"
                    )
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(Color.arkPrimary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moon")
                            .font(.caption)
                            .foregroundStyle(Color.arkTextMuted)
                        Text(
                            ArkFileSavedWeatherPresentation
                                .moonPhaseName(day.moonPhase)
                                + moonIlluminationSuffix(day)
                        )
                        .foregroundStyle(Color.arkTextPrimary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                componentMessage(
                    snapshot.astronomy,
                    unavailable: "Sun and moon calculations are not available for this saved location."
                )
            }

            Text(
                "Calculated on this device for the saved coordinate and "
                    + "time zone. Terrain and local conditions can change "
                    + "visible sunrise or sunset; moon data is not for navigation or tides."
            )
            .font(.footnote)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: NOAA Weather Radio / SAME

    private var radioSection: some View {
        sectionCard(
            title: "NOAA Weather Radio & SAME",
            systemImage: "radio.fill"
        ) {
            statusMessage(
                "\(ArkFileDeviceCopy.thisDeviceCapitalized) cannot receive "
                    + "NOAA Weather Radio broadcasts. "
                    + "Enter this information into a compatible weather-band/SAME radio.",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                color: Color.arkPrimary
            )
            componentFailureNotice(
                snapshot.radioTransmitters,
                message: "The radio directory could not be updated. "
                    + "Showing the earlier saved catalog result."
            )
            Text(radioCatalogStatusDisclosure)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let areas = snapshot.radioAreas, !areas.isEmpty {
                if areas.count > 1 {
                    statusMessage(
                        "The NWS point matched multiple partial-county SAME "
                            + "areas. ArkFile did not guess which code applies.",
                        systemImage: "questionmark.diamond",
                        color: .orange
                    )
                }
                ForEach(
                    Array(areas.enumerated()),
                    id: \.offset
                ) { _, area in
                    Text("SAME \(area.sameCode) · \(area.displayName)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color.arkTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            "SAME code \(area.sameCode), \(area.displayName)"
                        )
                }
            }

            let transmitters = snapshot.radioTransmitters.value ?? []
            if transmitters.isEmpty {
                if let message = ArkFileSavedWeatherPresentation
                    .radioNoCoverageMessage(
                        component: snapshot.radioTransmitters,
                        areas: snapshot.radioAreas,
                        timeZoneID: locationTimeZoneID
                    ) {
                    Text(message)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    componentMessage(
                        snapshot.radioTransmitters,
                        unavailable: "No county-designated transmitter information is saved for this location."
                    )
                }
            } else {
                ForEach(transmitters, id: \.id) { transmitter in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "\(transmitter.callSign) · "
                                + String(
                                    format: "%.3f MHz",
                                    transmitter.frequencyMegahertz
                                )
                        )
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Color.arkTextPrimary)

                        if let channel = transmitter.channel {
                            Text(channel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.arkPrimary)
                        }
                        Text(transmitter.siteName)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(transmitter.sameCounties, id: \.code) { county in
                            Text("SAME \(county.code) · \(county.displayName)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Color.arkTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let note = transmitter.coverageNote,
                           !note.isEmpty {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Color.arkTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    if transmitter.id != transmitters.last?.id {
                        Divider()
                    }
                }
            }

            Text(
                "ArkFile lists transmitters NOAA designates for the saved "
                    + "SAME area; it does not rank the nearest or clearest signal. "
                    + "Coverage varies with terrain and distance. Test reception before an emergency."
            )
            .font(.footnote)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Preparedness

    @ViewBuilder
    private var relatedGuidanceSection: some View {
        let activeAlerts = ArkFileSavedWeatherPresentation
            .alertsEligibleForGuidance(
                in: snapshot,
                connectivity: connectivity,
                at: now
            )
        let links = ArkFileWeatherPreparednessLinks.links(for: activeAlerts)
        if !links.isEmpty {
            sectionCard(
                title: "Related ArkFile Guidance",
                systemImage: "book.closed.fill"
            ) {
                Text(
                    "Authored offline reference related to saved alert types. "
                        + "It does not replace the official alert instructions above."
                )
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(links) { link in
                    Button {
                        openGuidance(link)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "book.closed")
                                .foregroundStyle(Color.arkPrimary)
                                .frame(width: 28)
                                .frame(minHeight: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.arkTextPrimary)
                                Text(link.copy)
                                    .font(.caption)
                                    .foregroundStyle(Color.arkTextMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.arkTextMuted)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this section in the offline Survival Guide.")
                }
            }
        }
    }

    // MARK: Sources and limitations

    private var sourcesAndLimitationsSection: some View {
        ArkFileSavedWeatherSectionCard {
            DisclosureGroup(isExpanded: $sourcesAreExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        "Hourly forecast",
                        source: "NOAA / National Weather Service",
                        stamp: snapshot.hourly.stamp
                    )
                    sourceRow(
                        "Daily forecast",
                        source: "NOAA / National Weather Service",
                        stamp: snapshot.daily.stamp
                    )
                    sourceRow(
                        "Official alerts",
                        source: "NOAA / National Weather Service",
                        stamp: snapshot.alerts.stamp
                    )
                    sourceRow(
                        "Extended outlook",
                        source: "NOAA Climate Prediction Center",
                        stamp: snapshot.climateOutlooks.stamp
                    )
                    sourceRow(
                        "Weather radio directory",
                        source: "NOAA Weather Radio / SAME catalog",
                        stamp: nil
                    )
                    if let catalogDate =
                        snapshot.radioTransmitters.stamp?.issuedAt {
                        Text(
                            "Catalog source dated "
                                + sourceTimestamp(catalogDate)
                        )
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                    }
                    sourceRow(
                        "Sun & moon",
                        source: "Calculated on this device",
                        stamp: snapshot.astronomy.stamp
                    )

                    Divider()

                    Text(
                        "Saved information may be outdated. ArkFile is not a "
                            + "live warning service. Follow current official "
                            + "alerts, Wireless Emergency Alerts, local "
                            + "authorities, and emergency instructions whenever "
                            + "available."
                    )
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.arkTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Updates send the selected coordinate directly over "
                            + "HTTPS to NOAA/NWS. Automatic refresh is "
                            + "opportunistic and is not guaranteed by iOS."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)

                    if locationTimeZoneID == nil {
                        Text(
                            "The location time zone has not been resolved. "
                                + "Times are shown explicitly in UTC until a "
                                + "successful NWS location lookup supplies it."
                        )
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "Sources & Limitations",
                        systemImage: "info.circle.fill"
                    )
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkTextPrimary)
                    Text(
                        "NOAA sources, saved timestamps, privacy, and offline "
                            + "caveats."
                    )
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .tint(Color.arkPrimary)
        }
    }

    // MARK: Shared presentation

    private var primaryFreshness: ArkFileWeatherFreshness? {
        ArkFileSavedWeatherPresentation.aggregateCoreFreshness(
            in: snapshot,
            at: now
        )
    }

    private var usesCurrentForecastLanguage: Bool {
        guard !ArkFileSavedWeatherPresentation.hasForecastRefreshFailure(
            in: snapshot
        ) else {
            return false
        }
        switch primaryFreshness {
        case .fresh, .aging:
            return true
        case .clockUncertain, .stale, .expired, .historical, nil:
            return false
        }
    }

    private var freshnessTitle: String {
        ArkFileSavedWeatherPresentation.forecastFreshnessTitle(
            snapshot: snapshot,
            connectivity: connectivity,
            at: now
        )
    }

    private var briefingFreshnessMessage: String {
        let base = ArkFileSavedWeatherPresentation.freshnessMessage(
            snapshot: snapshot,
            connectivity: connectivity,
            at: now,
            timeZoneID: locationTimeZoneID
        )
        var failed: [String] = []
        if snapshot.hourly.availability == .failed {
            failed.append("hourly forecast")
        }
        if snapshot.daily.availability == .failed {
            failed.append("daily forecast")
        }
        if snapshot.alerts.availability == .failed {
            failed.append("alerts")
        }
        guard !failed.isEmpty else { return base }
        let components = ListFormatter.localizedString(
            byJoining: failed
        )
        return "The \(components) could not be updated. Earlier saved "
            + "results remain. \(base)"
    }

    private var astronomyDay: ArkFileWeatherAstronomyDay? {
        ArkFileSavedWeatherPresentation.astronomyDay(
            in: snapshot,
            timeZoneID: locationTimeZoneID,
            at: now
        )
    }

    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ArkFileSavedWeatherSectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    private func statusMessage(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func componentMessage<Value>(
        _ component: ArkFileWeatherComponent<Value>,
        unavailable: String
    ) -> some View where Value: Codable & Equatable & Sendable {
        let message: String = switch component.availability {
        case .failed:
            component.value == nil
                ? "This source could not be updated. \(unavailable)"
                : "This source could not be updated. Showing its earlier saved result."
        case .unsupported:
            "This source does not cover the saved location."
        case .unavailable:
            unavailable
        case .successfulEmpty:
            unavailable
        case .available:
            unavailable
        }
        Text(message)
            .font(.subheadline)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func componentSourceTime<Value>(
        _ component: ArkFileWeatherComponent<Value>
    ) -> some View where Value: Codable & Equatable & Sendable {
        if let stamp = component.stamp {
            if let issuedAt = stamp.issuedAt {
                Text("Source issued " + sourceTimestamp(issuedAt))
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if stamp.validFrom != nil || stamp.validUntil != nil {
                Text(sourceValidity(stamp))
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Source last checked "
                    + sourceTimestamp(stamp.fetchedAt)
            )
            .font(.caption)
            .foregroundStyle(Color.arkTextMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func componentFailureNotice<Value>(
        _ component: ArkFileWeatherComponent<Value>,
        message: String
    ) -> some View where Value: Codable & Equatable & Sendable {
        if component.availability == .failed, component.value != nil {
            statusMessage(
                message,
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                color: .orange
            )
        }
    }

    private func astronomyEvent(
        _ title: String,
        date: Date?,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.arkPrimary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                Text(
                    date.map {
                        ArkFileSavedWeatherPresentation.time(
                            $0,
                            timeZoneID: locationTimeZoneID
                        )
                    } ?? "No event on this local date"
                )
                .foregroundStyle(Color.arkTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func astronomyMetric(
        _ title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.arkPrimary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
                Text(value)
                    .foregroundStyle(Color.arkTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceRow(
        _ title: String,
        source: String,
        stamp: ArkFileWeatherComponentStamp?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.arkTextPrimary)
            Text(source)
                .font(.subheadline)
                .foregroundStyle(Color.arkTextMuted)
            if let stamp {
                if let issuedAt = stamp.issuedAt {
                    Text("Issued \(sourceTimestamp(issuedAt))")
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                if stamp.validFrom != nil || stamp.validUntil != nil {
                    Text(sourceValidity(stamp))
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                }
                Text("Checked \(sourceTimestamp(stamp.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceValidity(
        _ stamp: ArkFileWeatherComponentStamp
    ) -> String {
        switch (stamp.validFrom, stamp.validUntil) {
        case let (start?, end?):
            return "Valid \(sourceTimestamp(start)) through \(sourceTimestamp(end))"
        case let (start?, nil):
            return "Valid from \(sourceTimestamp(start))"
        case let (nil, end?):
            return "Valid through \(sourceTimestamp(end))"
        case (nil, nil):
            return "Validity period not supplied"
        }
    }

    private func sourceTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var suffix = ""
        if let locationTimeZoneID,
           let timeZone = TimeZone(identifier: locationTimeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }

    private func dateRange(from start: Date, through end: Date) -> String {
        let startText = ArkFileSavedWeatherPresentation.dayAndDate(
            start,
            timeZoneID: locationTimeZoneID
        )
        let endText = ArkFileSavedWeatherPresentation.dayAndDate(
            ArkFileSavedWeatherPresentation.inclusiveOutlookEnd(
                validFrom: start,
                validUntil: end
            ),
            timeZoneID: locationTimeZoneID
        )
        return "\(startText) – \(endText)"
    }

    private func outlookTitle(
        _ period: ArkFileWeatherOutlookPeriodKind
    ) -> String {
        switch period {
        case .sixToTenDay:
            return "Days 6–10"
        case .eightToFourteenDay:
            return "Days 8–14"
        case .weekThreeToFour:
            return "Weeks 3–4"
        }
    }

    private func moonIlluminationSuffix(
        _ day: ArkFileWeatherAstronomyDay
    ) -> String {
        guard let illumination = ArkFileSavedWeatherPresentation
            .moonIlluminationPercent(day.moonIlluminationFraction) else {
            return ""
        }
        return " · \(illumination)% illuminated"
    }

    private func currentLocationAccuracy(
        _ location: ArkFileWeatherSavedLocation
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

    private var radioCatalogStatusDisclosure: String {
        if let catalogDate = snapshot.radioTransmitters.stamp?.issuedAt {
            return "NOAA catalog source dated "
                + sourceTimestamp(catalogDate)
                + ". Listed transmitter status may have changed."
        }
        return "The NOAA catalog source date is unavailable. Listed "
            + "transmitter status may have changed."
    }
}

private struct ArkFileSavedWeatherAlertCard: View {
    let alert: ArkFileWeatherAlert
    let component: ArkFileWeatherComponent<[ArkFileWeatherAlert]>
    let connectivity: ArkFileWeatherConnectivity
    let timeZoneID: String?
    let now: Date

    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                alertTitle,
                systemImage: presentation.isUrgent
                    ? "exclamationmark.triangle.fill"
                    : "exclamationmark.triangle"
            )
            .font(.headline)
            .foregroundStyle(emphasisColor)
            .fixedSize(horizontal: false, vertical: true)

            if alert.headline != alert.event {
                Text(alert.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.arkTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(issuingAgencyDescription)
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)

            VStack(alignment: .leading, spacing: 3) {
                Text("Sent \(timestamp(alert.sentAt))")
                if let effectiveAt = alert.effectiveAt {
                    Text("Effective \(timestamp(effectiveAt))")
                }
                Text("Expires \(timestamp(alert.expiresAt))")
            }
            .font(.caption)
            .foregroundStyle(Color.arkTextMuted)

            if let notice = presentation.cacheNotice {
                Text(notice)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(
                isExpanded: $isShowingDetails,
                content: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(alert.description)
                            .font(.subheadline)
                            .foregroundStyle(Color.arkTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let instruction = alert.instruction,
                           !instruction.isEmpty {
                            Text("Official instructions")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.arkTextPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text(instruction)
                                .font(.subheadline)
                                .foregroundStyle(Color.arkTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                },
                label: {
                    Text(isShowingDetails ? "Hide Official Details" : "Show Official Details")
                        .frame(minHeight: 44, alignment: .leading)
                }
            )
            .tint(Color.arkPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentation: ArkFileWeatherAlertPresentation {
        ArkFileSavedWeatherPresentation.alertPresentation(
            for: alert,
            component: component,
            connectivity: connectivity,
            at: now
        )
    }

    private var issuingAgencyDescription: String {
        if let issuingAgency = alert.issuingAgency,
           !issuingAgency.isEmpty {
            return "Issued by \(issuingAgency)"
        }
        return "Distributed by the National Weather Service; issuing agency not supplied"
    }

    private var alertTitle: String {
        switch presentation.emphasis {
        case .urgent:
            return alert.event
        case .upcoming:
            return "Upcoming alert: \(alert.event)"
        case .caution:
            return "Saved alert: \(alert.event)"
        case .historical:
            return "Past saved alert: \(alert.event)"
        }
    }

    private var emphasisColor: Color {
        switch presentation.emphasis {
        case .urgent:
            return .red
        case .upcoming:
            return .orange
        case .caution:
            return .orange
        case .historical:
            return Color.arkTextMuted
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var suffix = ""
        if let timeZoneID, let timeZone = TimeZone(identifier: timeZoneID) {
            formatter.timeZone = timeZone
        } else {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            suffix = " UTC"
        }
        return formatter.string(from: date) + suffix
    }
}
#endif
