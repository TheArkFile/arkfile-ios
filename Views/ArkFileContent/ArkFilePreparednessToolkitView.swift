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
import Foundation
import SwiftUI

enum ArkFilePreparednessTabLayoutPolicy {
    static let minimumControlHeight: CGFloat = 44
}

struct ArkFilePreparednessToolkitView: View {
    // Persisted so a household's profile, calculator setup, and supply
    // checkmarks survive between visits — a preparedness plan is useless if
    // the app forgets it.
    @AppStorage("arkfile.toolkit.selected-view.v1") private var selectedView = ToolkitView.plan
    @AppStorage("arkfile.toolkit.people.v1") private var people = 4
    @AppStorage("arkfile.toolkit.days.v1") private var days = 14
    @AppStorage("arkfile.toolkit.pets.v1") private var pets = 1
    @AppStorage("arkfile.toolkit.water-climate.v1") private var waterClimate = WaterClimate.normal
    @AppStorage("arkfile.toolkit.food-activity.v1") private var foodActivity = FoodActivity.light

    @AppStorage("arkfile.toolkit.bleach-batch.v1") private var bleachBatch = BleachBatch.twoGallons
    @AppStorage("arkfile.toolkit.bleach-strength.v1") private var bleachStrength = BleachStrength.sixPercent
    @AppStorage("arkfile.toolkit.water-clarity.v1") private var waterClarity = WaterClarity.clear
    @AppStorage("arkfile.toolkit.roof-area.v1") private var roofAreaSquareFeet = 800
    @AppStorage("arkfile.toolkit.rainfall.v1") private var rainfallInches = 1.0
    @AppStorage("arkfile.toolkit.rain-efficiency.v1") private var rainCollectionEfficiency = 80

    @AppStorage("arkfile.toolkit.phone-charges.v1") private var phoneCharges = 10
    @AppStorage("arkfile.toolkit.radio-hours.v1") private var radioHours = 36
    @AppStorage("arkfile.toolkit.light-hours.v1") private var lightHours = 40
    @AppStorage("arkfile.toolkit.custom-watts.v1") private var customDeviceWatts = 0
    @AppStorage("arkfile.toolkit.custom-hours.v1") private var customDeviceHours = 0
    @AppStorage("arkfile.toolkit.ac-inverter.v1") private var usesACInverter = false

    @AppStorage("arkfile.toolkit.generator-size.v1") private var generatorSize = GeneratorSize.medium
    @AppStorage("arkfile.toolkit.generator-load.v1") private var generatorLoad = GeneratorLoad.half
    @AppStorage("arkfile.toolkit.generator-hours.v1") private var generatorHoursPerDay = 6
    @AppStorage("arkfile.toolkit.generator-days.v1") private var generatorDays = 7

    @AppStorage("arkfile.toolkit.vehicle-tank.v1") private var vehicleTankGallons = 15.0
    @AppStorage("arkfile.toolkit.vehicle-fuel.v1") private var vehicleFuelPercent = 50
    @AppStorage("arkfile.toolkit.vehicle-mpg.v1") private var vehicleMPG = 25
    @AppStorage("arkfile.toolkit.evacuation-miles.v1") private var evacuationMiles = 180
    @AppStorage("arkfile.toolkit.traffic.v1") private var trafficCondition = TrafficCondition.moderate
    @AppStorage("arkfile.toolkit.foot-miles.v1") private var footDistanceMiles = 12
    @AppStorage("arkfile.toolkit.foot-terrain.v1") private var footTerrain = FootTerrain.road
    @AppStorage("arkfile.toolkit.foot-load.v1") private var footLoad = FootLoad.medium
    @AppStorage("arkfile.toolkit.foot-fitness.v1") private var footFitness = FootFitness.average
    @AppStorage("arkfile.toolkit.foot-weather.v1") private var footWeather = FootWeather.mild

    @AppStorage("arkfile.toolkit.outage-hours.v1") private var outageHours = 6
    @AppStorage("arkfile.toolkit.freezer-state.v1") private var freezerState = FreezerState.full
    @AppStorage("arkfile.toolkit.checked-items.v1") private var completedChecklistIDsRaw = ""

    private var completedChecklistIDs: Binding<Set<String>> {
        Binding(
            get: { Set(completedChecklistIDsRaw.split(separator: "\n").map(String.init)) },
            set: { completedChecklistIDsRaw = $0.sorted().joined(separator: "\n") }
        )
    }

    private var waterGallons: Double {
        let household = Double(people * days) * waterClimate.multiplier
        let petReserve = Double(pets * days) * 0.5
        return household + petReserve
    }

    private var waterContainers: Int {
        Int(ceil(waterGallons))
    }

    private var waterWeightPounds: Double {
        waterGallons * 8.34
    }

    private var calories: Int {
        Int((Double(people * days * 2_000) * foodActivity.multiplier).rounded())
    }

    private var freezeDriedFoodPounds: Double {
        Double(calories) / 1_600
    }

    private var cannedFoodPounds: Double {
        Double(calories) / 800
    }

    private var bleachDose: BleachDose {
        bleachBatch.dose(strength: bleachStrength, clarity: waterClarity)
    }

    private var rainwaterGallons: Double {
        0.623 * Double(roofAreaSquareFeet) * rainfallInches * (Double(rainCollectionEfficiency) / 100)
    }

    private var rawPowerWh: Double {
        let phones = Double(phoneCharges) * 15
        let radio = Double(radioHours) * 5
        let light = Double(lightHours) * 10
        let custom = Double(customDeviceWatts * customDeviceHours)
        return phones + radio + light + custom
    }

    private var batteryTargetWh: Double {
        guard rawPowerWh > 0 else { return 0 }
        let efficiency = usesACInverter ? 0.85 : 0.9
        return (rawPowerWh / efficiency) * 1.25
    }

    private var twelveVoltAmpHours: Double {
        batteryTargetWh / 12
    }

    private var powerBankCount: Int {
        guard batteryTargetWh > 0 else { return 0 }
        return Int(ceil(batteryTargetWh / 55))
    }

    private var generatorGallonsPerHour: Double {
        generatorSize.gallonsPerHourAtHalfLoad * (0.6 + generatorLoad.fraction * 0.8)
    }

    private var generatorFuelGallons: Double {
        generatorGallonsPerHour * Double(generatorHoursPerDay * generatorDays) * 1.1
    }

    private var generatorContainers: Int {
        Int(ceil(generatorFuelGallons / 5))
    }

    private var vehicleCurrentFuelGallons: Double {
        vehicleTankGallons * (Double(vehicleFuelPercent) / 100)
    }

    private var vehicleEffectiveMPG: Double {
        Double(vehicleMPG) * trafficCondition.mpgMultiplier
    }

    private var vehicleCurrentRange: Double {
        vehicleCurrentFuelGallons * vehicleEffectiveMPG
    }

    private var evacuationFuelNeeded: Double {
        Double(evacuationMiles) / vehicleEffectiveMPG
    }

    private var evacuationFuelShortage: Double {
        max(0, evacuationFuelNeeded - vehicleCurrentFuelGallons)
    }

    private var evacuationTravelHours: Double {
        Double(evacuationMiles) / trafficCondition.mph
    }

    private var footSpeedMPH: Double {
        max(
            0.5,
            footTerrain.baseMPH * footLoad.multiplier * footFitness.multiplier * footWeather.multiplier
        )
    }

    private var footTravelHours: Double {
        Double(footDistanceMiles) / footSpeedMPH
    }

    private var footTravelDays: Int {
        Int(ceil(footTravelHours / footFitness.walkingHoursPerDay))
    }

    private var footWaterLiters: Double {
        footTravelHours * footWeather.litersPerHour
    }

    private var footCalories: Int {
        Int((footTravelHours * footLoad.caloriesPerHour).rounded())
    }

    var body: some View {
        List {
            header
            tabPicker

            switch selectedView {
            case .plan:
                planView
            case .water:
                waterView
            case .power:
                powerView
            case .evacuation:
                evacuationView
            case .lists:
                checklistView
            case .references:
                referenceView
            }
        }
        .accessibilityIdentifier("arkfile_preparedness_root")
        .navigationTitle("Preparedness")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.arkPrimary)
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Preparedness Toolkit", systemImage: "checklist")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Offline calculators for household supplies, safe water, backup power, evacuation range, food safety, and field checklists.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ToolkitInfoLine(
                    systemImage: "exclamationmark.triangle",
                    text: "Use local emergency orders, product labels, and medical guidance first. These are planning estimates for when the internet is not available.",
                    tint: .orange
                )
            }
            .padding(.vertical, 4)
        }
    }

    private var tabPicker: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ToolkitView.allCases) { view in
                        Button {
                            selectedView = view
                        } label: {
                            Label(view.title, systemImage: view.systemImage)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 10)
                                .frame(
                                    minHeight:
                                        ArkFilePreparednessTabLayoutPolicy
                                            .minimumControlHeight
                                )
                                .foregroundStyle(selectedView == view ? Color.white : Color.arkTextPrimary)
                                .background(selectedView == view ? Color.arkPrimary : Color.arkAppSurface)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(Color.arkAppBorder, lineWidth: selectedView == view ? 0 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .hoverEffect(.highlight)
                        .accessibilityLabel(view.accessibilityTitle)
                        .accessibilityAddTraits(
                            selectedView == view ? .isSelected : []
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }

    private var planView: some View {
        Group {
            householdInputs
            Section("Scenario Snapshot") {
                ToolkitResultRow(
                    title: "Stored water target",
                    value: compactNumber(waterGallons),
                    unit: "gal",
                    note: "\(people) people, \(pets) pet\(pets == 1 ? "" : "s"), \(days) days. Includes condition and pet reserve."
                )
                ToolkitResultRow(
                    title: "Food energy target",
                    value: calories.formatted(),
                    unit: "cal",
                    note: "Uses 2,000 calories per person per day as a planning default, adjusted for \(foodActivity.title.lowercased())."
                )
                ToolkitResultRow(
                    title: "Food storage weight",
                    value: "\(compactNumber(freezeDriedFoodPounds))-\(compactNumber(cannedFoodPounds))",
                    unit: "lb",
                    note: "Rough range from dehydrated food at about 100 cal/oz to canned food at about 50 cal/oz."
                )
                ToolkitResultRow(
                    title: "Battery target",
                    value: wholeNumber(batteryTargetWh),
                    unit: "Wh",
                    note: "Current phone, radio, light, and custom-load plan with a 25% reserve."
                )
            }

            Section("Food Safety Clock") {
                Stepper(value: $outageHours, in: 0...96) {
                    Label("\(outageHours) hours without power", systemImage: "clock")
                }
                Picker("Freezer", selection: $freezerState) {
                    ForEach(FreezerState.allCases) { state in
                        Text(state.title).tag(state)
                    }
                }
                .pickerStyle(.menu)
                ToolkitResultRow(
                    title: fridgeStatus.title,
                    value: fridgeStatus.value,
                    unit: "",
                    note: fridgeStatus.note
                )
                ToolkitResultRow(
                    title: freezerStatus.title,
                    value: freezerStatus.value,
                    unit: "",
                    note: freezerStatus.note
                )
            }
        }
    }

    private var householdInputs: some View {
        Section("Household") {
            Stepper(value: $people, in: 1...30) {
                Label("\(people) people", systemImage: "person.2")
            }
            Stepper(value: $pets, in: 0...12) {
                Label("\(pets) small/medium pet\(pets == 1 ? "" : "s")", systemImage: "pawprint")
            }
            Stepper(value: $days, in: 1...60) {
                Label("\(days) days", systemImage: "calendar")
            }
            Picker("Water conditions", selection: $waterClimate) {
                ForEach(WaterClimate.allCases) { climate in
                    Text(climate.title).tag(climate)
                }
            }
            Picker("Food activity", selection: $foodActivity) {
                ForEach(FoodActivity.allCases) { activity in
                    Text(activity.title).tag(activity)
                }
            }
        }
    }

    private var waterView: some View {
        Group {
            householdInputs

            Section("Stored Water") {
                ToolkitResultRow(
                    title: "Minimum plus reserve",
                    value: compactNumber(waterGallons),
                    unit: "gal",
                    note: "\(waterContainers) one-gallon containers. Approximate weight: \(wholeNumber(waterWeightPounds)) lb."
                )
                ToolkitInfoLine(
                    systemImage: "drop",
                    text: "Base guidance is at least 1 gallon per person per day. Store more for hot weather, illness, pregnancy, pets, and medical needs.",
                    tint: .blue
                )
            }

            Section("Disinfect Water With Bleach") {
                Picker("Batch", selection: $bleachBatch) {
                    ForEach(BleachBatch.allCases) { batch in
                        Text(batch.title).tag(batch)
                    }
                }
                Picker("Bleach", selection: $bleachStrength) {
                    ForEach(BleachStrength.allCases) { strength in
                        Text(strength.title).tag(strength)
                    }
                }
                Picker("Water", selection: $waterClarity) {
                    ForEach(WaterClarity.allCases) { clarity in
                        Text(clarity.title).tag(clarity)
                    }
                }
                ToolkitResultRow(
                    title: "Dropper dose",
                    value: wholeNumber(bleachDose.drops),
                    unit: "drops",
                    note: "EPA table basis: \(bleachBatch.title), \(bleachStrength.title), \(waterClarity.title.lowercased()) water."
                )
                ToolkitResultRow(
                    title: "Spoon dose",
                    value: bleachDose.spoonValue,
                    unit: bleachDose.spoonUnit,
                    note: bleachDose.spoonNote
                )
                ToolkitInfoLine(
                    systemImage: "info.circle",
                    text: "If you do not have a clean dropper, make a 2, 4, or 8 gallon batch so you can use the EPA teaspoon table. Tablespoon equivalents are shown, but teaspoons are the practical measure for these small doses.",
                    tint: .blue
                )
                ToolkitInfoLine(
                    systemImage: "timer",
                    text: "Stir well and wait 30 minutes. The water should have a slight chlorine smell; if it does not, repeat the same dose and wait 15 more minutes.",
                    tint: .orange
                )
                ToolkitInfoLine(
                    systemImage: "xmark.octagon",
                    text: "Use only regular unscented liquid bleach suitable for disinfection and sanitization. Do not use scented, splashless, color-safe, or cleaner-added bleach.",
                    tint: .red
                )
            }

            Section("Rain Capture") {
                Stepper(value: $roofAreaSquareFeet, in: 100...5_000, step: 50) {
                    Label("\(roofAreaSquareFeet) sq ft catchment", systemImage: "house")
                }
                Stepper(value: $rainfallInches, in: 0.25...12, step: 0.25) {
                    Label("\(compactNumber(rainfallInches, maxFractionDigits: 2)) in rain", systemImage: "cloud.rain")
                }
                Stepper(value: $rainCollectionEfficiency, in: 50...95, step: 5) {
                    Label("\(rainCollectionEfficiency)% collection efficiency", systemImage: "gauge.with.dots.needle.50percent")
                }
                ToolkitResultRow(
                    title: "Collectable rainwater",
                    value: wholeNumber(rainwaterGallons),
                    unit: "gal",
                    note: "Uses 0.623 gal per sq ft per inch before efficiency losses. Treat before drinking."
                )
            }
        }
    }

    private var powerView: some View {
        Group {
            Section("Battery Loads") {
                Stepper(value: $phoneCharges, in: 0...80) {
                    Label("\(phoneCharges) phone charge\(phoneCharges == 1 ? "" : "s")", systemImage: "iphone")
                }
                Stepper(value: $radioHours, in: 0...240) {
                    Label("\(radioHours) radio hours", systemImage: "radio")
                }
                Stepper(value: $lightHours, in: 0...240) {
                    Label("\(lightHours) LED light hours", systemImage: "lightbulb")
                }
                Stepper(value: $customDeviceWatts, in: 0...1_500, step: 5) {
                    Label("\(customDeviceWatts)W custom load", systemImage: "bolt")
                }
                Stepper(value: $customDeviceHours, in: 0...240) {
                    Label("\(customDeviceHours) custom load hours", systemImage: "timer")
                }
                Toggle("Use AC inverter", isOn: $usesACInverter)
            }

            Section("Battery Target") {
                ToolkitResultRow(
                    title: "Energy need",
                    value: wholeNumber(rawPowerWh),
                    unit: "Wh",
                    note: "Raw load before reserve and conversion losses."
                )
                ToolkitResultRow(
                    title: "Battery target",
                    value: wholeNumber(batteryTargetWh),
                    unit: "Wh",
                    note: "\(wholeNumber(twelveVoltAmpHours)) Ah at 12V, or about \(powerBankCount) 20,000 mAh USB bank\(powerBankCount == 1 ? "" : "s") using a 55 Wh usable estimate."
                )
                ToolkitInfoLine(
                    systemImage: "stethoscope",
                    text: "For oxygen, CPAP, refrigeration for medication, or powered mobility, use the device label/manual and clinician or supplier guidance.",
                    tint: .orange
                )
            }

            Section("Generator Fuel") {
                Picker("Generator", selection: $generatorSize) {
                    ForEach(GeneratorSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("Load", selection: $generatorLoad) {
                    ForEach(GeneratorLoad.allCases) { load in
                        Text(load.title).tag(load)
                    }
                }
                Stepper(value: $generatorHoursPerDay, in: 0...24) {
                    Label("\(generatorHoursPerDay) hours per day", systemImage: "timer")
                }
                Stepper(value: $generatorDays, in: 1...30) {
                    Label("\(generatorDays) days", systemImage: "calendar")
                }
                ToolkitResultRow(
                    title: "Fuel target",
                    value: compactNumber(generatorFuelGallons),
                    unit: "gal",
                    note: "\(generatorContainers) five-gallon container\(generatorContainers == 1 ? "" : "s"). Estimate includes a 10% reserve."
                )
                ToolkitInfoLine(
                    systemImage: "exclamationmark.octagon",
                    text: "Run generators outside at least 20 feet from doors, windows, and vents. Point exhaust away and let equipment cool before refueling.",
                    tint: .red
                )
            }
        }
    }

    private var evacuationView: some View {
        Group {
            Section("Vehicle Range") {
                Stepper(value: $vehicleTankGallons, in: 5...45, step: 0.5) {
                    Label("\(compactNumber(vehicleTankGallons)) gal tank", systemImage: "fuelpump")
                }
                Stepper(value: $vehicleFuelPercent, in: 0...100, step: 5) {
                    Label("\(vehicleFuelPercent)% fuel now", systemImage: "gauge.with.dots.needle.67percent")
                }
                Stepper(value: $vehicleMPG, in: 5...60) {
                    Label("\(vehicleMPG) highway MPG", systemImage: "car")
                }
                Stepper(value: $evacuationMiles, in: 5...1_000, step: 5) {
                    Label("\(evacuationMiles) mile route", systemImage: "map")
                }
                Picker("Traffic", selection: $trafficCondition) {
                    ForEach(TrafficCondition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                ToolkitResultRow(
                    title: "Current range",
                    value: wholeNumber(vehicleCurrentRange),
                    unit: "mi",
                    note: "Effective MPG: \(compactNumber(vehicleEffectiveMPG)). Estimated travel time: \(compactNumber(evacuationTravelHours)) hours."
                )
                ToolkitResultRow(
                    title: evacuationFuelShortage > 0 ? "Fuel shortage" : "Fuel margin",
                    value: evacuationFuelShortage > 0 ? compactNumber(evacuationFuelShortage) : compactNumber(vehicleCurrentFuelGallons - evacuationFuelNeeded),
                    unit: "gal",
                    note: "Evacuation traffic can be worse than planned. Keep the tank above half when evacuation is possible."
                )
            }

            Section("On-Foot Estimate") {
                Stepper(value: $footDistanceMiles, in: 1...100) {
                    Label("\(footDistanceMiles) miles", systemImage: "figure.walk")
                }
                Picker("Terrain", selection: $footTerrain) {
                    ForEach(FootTerrain.allCases) { terrain in
                        Text(terrain.title).tag(terrain)
                    }
                }
                Picker("Pack", selection: $footLoad) {
                    ForEach(FootLoad.allCases) { load in
                        Text(load.title).tag(load)
                    }
                }
                Picker("Fitness", selection: $footFitness) {
                    ForEach(FootFitness.allCases) { fitness in
                        Text(fitness.title).tag(fitness)
                    }
                }
                Picker("Weather", selection: $footWeather) {
                    ForEach(FootWeather.allCases) { weather in
                        Text(weather.title).tag(weather)
                    }
                }
                ToolkitResultRow(
                    title: "Walking time",
                    value: "\(footTravelDays)",
                    unit: footTravelDays == 1 ? "day" : "days",
                    note: "\(compactNumber(footSpeedMPH)) mph pace, about \(wholeNumber(footTravelHours)) moving hours."
                )
                ToolkitResultRow(
                    title: "Carry or resupply",
                    value: compactNumber(footWaterLiters),
                    unit: "L water",
                    note: "\(footCalories.formatted()) extra calories plus normal intake. Heat, injury, children, and rough terrain slow the whole group."
                )
            }
        }
    }

    private var checklistView: some View {
        Group {
            ToolkitChecklistSection(
                title: "First Hour",
                systemImage: "exclamationmark.triangle",
                items: [
                    .init(id: "first-scene", text: "Check fire, smoke, gas smell, floodwater, downed lines, unstable structures, and injuries."),
                    .init(id: "first-official", text: "Follow official alerts and evacuation orders."),
                    .init(id: "first-water", text: "Fill clean containers if water service may fail."),
                    .init(id: "first-fridge", text: "Keep refrigerator and freezer doors closed."),
                    .init(id: "first-contact", text: "Text out-of-area contacts and conserve phone battery.")
                ],
                completedIDs: completedChecklistIDs
            )
            ToolkitChecklistSection(
                title: "72 Hours",
                systemImage: "backpack",
                items: [
                    .init(id: "72-water", text: "Water for every person and pet."),
                    .init(id: "72-food", text: "Shelf-stable food, infant food if needed, and manual can opener."),
                    .init(id: "72-light", text: "Headlamps, flashlights, lanterns, and spare batteries."),
                    .init(id: "72-radio", text: "Radio, battery bank, cables, and written contacts."),
                    .init(id: "72-medical", text: "First aid, prescriptions, glasses, hearing aids, and medical sheets."),
                    .init(id: "72-cash", text: "Cash, IDs, insurance, and critical documents in a waterproof pouch.")
                ],
                completedIDs: completedChecklistIDs
            )
            ToolkitChecklistSection(
                title: "Two Weeks At Home",
                systemImage: "house",
                items: [
                    .init(id: "home-sanitation", text: "Toilet plan, trash bags, gloves, soap, sanitizer, and cleaning supplies."),
                    .init(id: "home-heat", text: "Safe heating or cooling plan with carbon monoxide alarms."),
                    .init(id: "home-cook", text: "No-cook meals and outdoor-only cooking setup."),
                    .init(id: "home-tools", text: "Fire extinguisher, shutoff wrench, duct tape, tarps, and basic repair tools."),
                    .init(id: "home-neighbor", text: "Neighbor check-in plan for older adults, disabled people, and medical-device users.")
                ],
                completedIDs: completedChecklistIDs
            )
            ToolkitChecklistSection(
                title: "Evacuation",
                systemImage: "figure.walk",
                items: [
                    .init(id: "evac-route", text: "Two routes, paper map, and destination contact."),
                    .init(id: "evac-fuel", text: "Vehicle above half tank, tire check, and charging cables."),
                    .init(id: "evac-bag", text: "Go-bag for each person with water, food, medications, clothing, and rain/cold layer."),
                    .init(id: "evac-pets", text: "Pet carriers, leash, food, water, medication, vaccination records, and cleanup bags."),
                    .init(id: "evac-home", text: "Secure home only if there is time and it is safe.")
                ],
                completedIDs: completedChecklistIDs
            )
            Section {
                Button(role: .destructive) {
                    completedChecklistIDsRaw = ""
                } label: {
                    Label("Reset All Checklists", systemImage: "arrow.counterclockwise")
                }
                .disabled(completedChecklistIDsRaw.isEmpty)
            } footer: {
                Text("Checkmarks are saved on this device. Reset after restocking supplies or reviewing your plan.")
            }
        }
    }

    private var referenceView: some View {
        Group {
            ToolkitReferenceCard(
                title: "Official Safety Numbers",
                systemImage: "checkmark.seal",
                lines: [
                    "Water: at least 1 gallon per person per day; try for 2 weeks if possible.",
                    "Bleach: EPA table lists 6% bleach at 8 drops/gal, with 2 gal = 1/4 tsp, 4 gal = 1/3 tsp, and 8 gal = 2/3 tsp.",
                    "Bleach: EPA table lists 8.25% bleach at 6 drops/gal, with 2 gal = 1/8 tsp, 4 gal = 1/4 tsp, and 8 gal = 1/2 tsp. Double for cloudy, colored, or very cold water.",
                    "Boiling: rolling boil for 1 minute; 3 minutes above 6,500 feet.",
                    "Food safety: refrigerator perishables have a 4-hour closed-door window; full freezer about 48 hours, half-full about 24 hours.",
                    "Generator: outside at least 20 feet from doors, windows, and vents."
                ]
            )
            ToolkitReferenceCard(
                title: "How Estimates Are Calculated",
                systemImage: "function",
                lines: [
                    "Food starts from the FDA's 2,000-calorie general guide, then activity adjusts the estimate.",
                    "Rain capture uses gallons = 0.623 x roof sq ft x rainfall inches x efficiency.",
                    "Battery target adds conversion loss plus 25% reserve; actual runtime changes with temperature, battery age, and device surge loads.",
                    "Generator fuel rates are rough averages. Use the manual for your exact model before storing fuel.",
                    "Walking estimates assume the slowest person sets group pace."
                ]
            )
            ToolkitReferenceCard(
                title: "When Calculators Do Not Apply",
                systemImage: "xmark.octagon",
                lines: [
                    "Chemical, fuel, radiological, salt, or heavy-metal water contamination.",
                    "Life-support power needs without manufacturer or clinician guidance.",
                    "Evacuation orders, wildfire smoke, floodwater, downed power lines, and structural damage.",
                    "Food that smells fine but has exceeded safe temperature guidance.",
                    "Carbon monoxide risk from generators, grills, camp stoves, heaters, or pressure washers."
                ]
            )
            ToolkitReferenceCard(
                title: "Sources Checked",
                systemImage: "doc.text.magnifyingglass",
                lines: [
                    "Reviewed May 9, 2026 against CDC emergency water storage, EPA water disinfection, CDC/FEMA generator safety, USDA power-outage food safety, and FDA calorie-label guidance.",
                    "Desktop ArkFile remains the richer long-form reference; this device toolkit focuses on fast offline estimates and decisions."
                ]
            )
        }
    }

    private var fridgeStatus: ToolkitStatus {
        if outageHours <= 4 {
            return ToolkitStatus(
                title: "Refrigerator",
                value: "within 4h",
                note: "Keep the door closed and confirm food is at 40 F or below when power returns."
            )
        }
        return ToolkitStatus(
            title: "Refrigerator",
            value: "discard perishables",
            note: "After 4 hours without power, USDA says to discard refrigerated perishable food such as meat, poultry, fish, eggs, and leftovers."
        )
    }

    private var freezerStatus: ToolkitStatus {
        let safeHours = freezerState.safeHours
        if outageHours <= safeHours {
            return ToolkitStatus(
                title: "Freezer",
                value: "likely cold",
                note: "\(freezerState.title) freezer guidance is about \(safeHours) hours if the door stays closed."
            )
        }
        return ToolkitStatus(
            title: "Freezer",
            value: "verify temp",
            note: "Check temperature and ice crystals. When in doubt, throw it out."
        )
    }
}

private enum ToolkitView: String, CaseIterable, Identifiable {
    case plan
    case water
    case power
    case evacuation
    case lists
    case references

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan:
            "Plan"
        case .water:
            "Water"
        case .power:
            "Power"
        case .evacuation:
            "Evac"
        case .lists:
            "Lists"
        case .references:
            "Refs"
        }
    }

    var systemImage: String {
        switch self {
        case .plan:
            "list.clipboard"
        case .water:
            "drop"
        case .power:
            "bolt.batteryblock"
        case .evacuation:
            "figure.walk"
        case .lists:
            "checklist"
        case .references:
            "book.closed"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .evacuation:
            "Evacuation"
        case .references:
            "References"
        default:
            title
        }
    }
}

private enum WaterClimate: String, CaseIterable, Identifiable {
    case normal
    case hot
    case veryHot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            "Normal"
        case .hot:
            "Hot, illness, or exertion"
        case .veryHot:
            "Very hot or heavy labor"
        }
    }

    var multiplier: Double {
        switch self {
        case .normal:
            1.0
        case .hot:
            1.5
        case .veryHot:
            2.0
        }
    }
}

private enum FoodActivity: String, CaseIterable, Identifiable {
    case resting
    case light
    case cleanup
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resting:
            "Resting"
        case .light:
            "Light activity"
        case .cleanup:
            "Cleanup or walking"
        case .heavy:
            "Heavy labor"
        }
    }

    var multiplier: Double {
        switch self {
        case .resting:
            0.9
        case .light:
            1.0
        case .cleanup:
            1.25
        case .heavy:
            1.5
        }
    }
}

private struct BleachDose {
    let drops: Double
    let spoonValue: String
    let spoonUnit: String
    let spoonNote: String
}

private enum BleachBatch: String, CaseIterable, Identifiable {
    case oneGallon
    case twoGallons
    case fourGallons
    case eightGallons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneGallon:
            "1 gallon"
        case .twoGallons:
            "2 gallons"
        case .fourGallons:
            "4 gallons"
        case .eightGallons:
            "8 gallons"
        }
    }

    var gallons: Double {
        switch self {
        case .oneGallon:
            1
        case .twoGallons:
            2
        case .fourGallons:
            4
        case .eightGallons:
            8
        }
    }

    func dose(strength: BleachStrength, clarity: WaterClarity) -> BleachDose {
        let drops = gallons * strength.dropsPerGallon * Double(clarity.doseMultiplier)

        guard let baseTeaspoonTwentyFourths = baseTeaspoonTwentyFourths(for: strength) else {
            return BleachDose(
                drops: drops,
                spoonValue: "EPA drops only",
                spoonUnit: "",
                spoonNote: "For 1 gallon, EPA publishes drops only. Common kitchen spoons are too coarse for this dose; use a dropper or scale up to 2, 4, or 8 gallons."
            )
        }

        let teaspoonTwentyFourths = baseTeaspoonTwentyFourths * clarity.doseMultiplier
        let teaspoons = fractionText(numerator: teaspoonTwentyFourths, denominator: 24)
        let tablespoons = fractionText(numerator: teaspoonTwentyFourths, denominator: 72)
        return BleachDose(
            drops: drops,
            spoonValue: teaspoons,
            spoonUnit: "tsp",
            spoonNote: "Tablespoon equivalent: \(tablespoons) Tbsp. Use teaspoons when possible; tablespoons are too coarse for these small doses."
        )
    }

    private func baseTeaspoonTwentyFourths(for strength: BleachStrength) -> Int? {
        switch (self, strength) {
        case (.oneGallon, _):
            nil
        case (.twoGallons, .sixPercent):
            6
        case (.fourGallons, .sixPercent):
            8
        case (.eightGallons, .sixPercent):
            16
        case (.twoGallons, .eightPointTwoFivePercent):
            3
        case (.fourGallons, .eightPointTwoFivePercent):
            6
        case (.eightGallons, .eightPointTwoFivePercent):
            12
        }
    }
}

private enum BleachStrength: String, CaseIterable, Identifiable {
    case sixPercent
    case eightPointTwoFivePercent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sixPercent:
            "6% unscented"
        case .eightPointTwoFivePercent:
            "8.25% unscented"
        }
    }

    var dropsPerGallon: Double {
        switch self {
        case .sixPercent:
            8
        case .eightPointTwoFivePercent:
            6
        }
    }

}

private enum WaterClarity: String, CaseIterable, Identifiable {
    case clear
    case cloudyColoredCold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear:
            "Clear"
        case .cloudyColoredCold:
            "Cloudy, colored, or very cold"
        }
    }

    var doseMultiplier: Int {
        switch self {
        case .clear:
            1
        case .cloudyColoredCold:
            2
        }
    }
}

private enum GeneratorSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            "2,000W portable"
        case .medium:
            "3,500W portable"
        case .large:
            "7,500W home backup"
        }
    }

    var gallonsPerHourAtHalfLoad: Double {
        switch self {
        case .small:
            0.3
        case .medium:
            0.5
        case .large:
            0.8
        }
    }
}

private enum GeneratorLoad: String, CaseIterable, Identifiable {
    case quarter
    case half
    case threeQuarter
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quarter:
            "25% load"
        case .half:
            "50% load"
        case .threeQuarter:
            "75% load"
        case .full:
            "100% load"
        }
    }

    var fraction: Double {
        switch self {
        case .quarter:
            0.25
        case .half:
            0.5
        case .threeQuarter:
            0.75
        case .full:
            1.0
        }
    }
}

private enum TrafficCondition: String, CaseIterable, Identifiable {
    case clear
    case moderate
    case heavy
    case gridlock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear:
            "Clear"
        case .moderate:
            "Moderate"
        case .heavy:
            "Heavy"
        case .gridlock:
            "Gridlock"
        }
    }

    var mpgMultiplier: Double {
        switch self {
        case .clear:
            1.0
        case .moderate:
            0.75
        case .heavy:
            0.5
        case .gridlock:
            0.25
        }
    }

    var mph: Double {
        switch self {
        case .clear:
            65
        case .moderate:
            45
        case .heavy:
            25
        case .gridlock:
            10
        }
    }
}

private enum FootTerrain: String, CaseIterable, Identifiable {
    case road
    case trail
    case rough
    case mountain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .road:
            "Road or sidewalk"
        case .trail:
            "Trail"
        case .rough:
            "Rough ground"
        case .mountain:
            "Mountainous"
        }
    }

    var baseMPH: Double {
        switch self {
        case .road:
            3.0
        case .trail:
            2.5
        case .rough:
            1.5
        case .mountain:
            1.0
        }
    }
}

private enum FootLoad: String, CaseIterable, Identifiable {
    case light
    case medium
    case heavy
    case veryHeavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            "Light"
        case .medium:
            "15-30 lb"
        case .heavy:
            "30-50 lb"
        case .veryHeavy:
            "50+ lb"
        }
    }

    var multiplier: Double {
        switch self {
        case .light:
            1.0
        case .medium:
            0.85
        case .heavy:
            0.7
        case .veryHeavy:
            0.55
        }
    }

    var caloriesPerHour: Double {
        switch self {
        case .light, .medium:
            350
        case .heavy, .veryHeavy:
            450
        }
    }
}

private enum FootFitness: String, CaseIterable, Identifiable {
    case low
    case average
    case good
    case athletic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            "Low"
        case .average:
            "Average"
        case .good:
            "Good"
        case .athletic:
            "Athletic"
        }
    }

    var multiplier: Double {
        switch self {
        case .low:
            0.7
        case .average:
            1.0
        case .good:
            1.15
        case .athletic:
            1.3
        }
    }

    var walkingHoursPerDay: Double {
        switch self {
        case .low:
            4
        case .average:
            6
        case .good:
            8
        case .athletic:
            10
        }
    }
}

private enum FootWeather: String, CaseIterable, Identifiable {
    case mild
    case hot
    case cold
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mild:
            "Mild"
        case .hot:
            "Hot"
        case .cold:
            "Cold"
        case .extreme:
            "Extreme"
        }
    }

    var multiplier: Double {
        switch self {
        case .mild:
            1.0
        case .hot:
            0.75
        case .cold:
            0.85
        case .extreme:
            0.6
        }
    }

    var litersPerHour: Double {
        switch self {
        case .mild, .cold:
            0.5
        case .hot:
            0.75
        case .extreme:
            1.0
        }
    }
}

private enum FreezerState: String, CaseIterable, Identifiable {
    case full
    case halfFull

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full:
            "Full"
        case .halfFull:
            "Half-full"
        }
    }

    var safeHours: Int {
        switch self {
        case .full:
            48
        case .halfFull:
            24
        }
    }
}

private struct ToolkitStatus {
    let title: String
    let value: String
    let note: String
}

private struct ToolkitCheckItem: Identifiable, Hashable {
    let id: String
    let text: String
}

private struct ToolkitResultRow: View {
    let title: String
    let value: String
    let unit: String
    let note: String

    private var formattedValue: String {
        unit.isEmpty ? value : "\(value) \(unit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(formattedValue). \(note)")
    }
}

private struct ToolkitInfoLine: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ToolkitChecklistSection: View {
    let title: String
    let systemImage: String
    let items: [ToolkitCheckItem]
    @Binding var completedIDs: Set<String>

    var body: some View {
        Section {
            ForEach(items) { item in
                Button {
                    toggle(item)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: completedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completedIDs.contains(item.id) ? Color.green : Color.secondary)
                            .padding(.top, 2)
                        Text(item.text)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Label(title, systemImage: systemImage)
        }
    }

    private func toggle(_ item: ToolkitCheckItem) {
        if completedIDs.contains(item.id) {
            completedIDs.remove(item.id)
        } else {
            completedIDs.insert(item.id)
        }
    }
}

private struct ToolkitReferenceCard: View {
    let title: String
    let systemImage: String
    let lines: [String]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.top, 3)
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private func compactNumber(_ value: Double, maxFractionDigits: Int = 1) -> String {
    value.formatted(.number.precision(.fractionLength(0...maxFractionDigits)))
}

private func wholeNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)))
}

private func fractionText(numerator: Int, denominator: Int) -> String {
    guard numerator > 0 else { return "0" }

    let whole = numerator / denominator
    let remainder = numerator % denominator
    guard remainder != 0 else { return "\(whole)" }

    let divisor = greatestCommonDivisor(remainder, denominator)
    let fraction = "\(remainder / divisor)/\(denominator / divisor)"
    return whole > 0 ? "\(whole) \(fraction)" : fraction
}

private func greatestCommonDivisor(_ left: Int, _ right: Int) -> Int {
    var a = abs(left)
    var b = abs(right)

    while b != 0 {
        let remainder = a % b
        a = b
        b = remainder
    }

    return max(a, 1)
}
#endif
