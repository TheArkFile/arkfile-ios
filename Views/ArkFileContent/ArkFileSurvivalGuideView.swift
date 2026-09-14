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

struct ArkFileSurvivalGuideView: View {
    /// Optional section to expand and scroll to on first appearance, so other
    /// surfaces (emergency card, unified search) can deep-link into the guide.
    var initialSectionID: String?
    /// Optional block to scroll to (more precise than a section); the owning
    /// section is expanded automatically.
    var initialBlockID: String?

    @State private var searchText = ""
    @State private var expandedSectionIDs: Set<String>

    private static let topAnchorID = "arkfile-survival-guide-top"
    private let sections = ArkFileSurvivalGuideContent.sections

    init(initialSectionID: String? = nil, initialBlockID: String? = nil) {
        self.initialSectionID = initialSectionID
        self.initialBlockID = initialBlockID
        var expanded = Set(["intro", "water", "shelter", "medical"])
        // Seed the deep-link target as expanded from the very first layout pass;
        // expanding it in onAppear re-laid-out the list mid-presentation and the
        // one-shot scroll could fire before the target block had geometry.
        if let targetSection = Self.targetSectionID(
            sectionID: initialSectionID,
            blockID: initialBlockID,
            sections: ArkFileSurvivalGuideContent.sections
        ) {
            expanded.insert(targetSection)
        }
        _expandedSectionIDs = State(initialValue: expanded)
    }

    private static func targetSectionID(
        sectionID: String?,
        blockID: String?,
        sections: [ArkFileSurvivalGuideSection]
    ) -> String? {
        if let sectionID {
            return sectionID
        }
        guard let blockID else {
            return nil
        }
        return sections.first { $0.blocks.contains { $0.id == blockID } }?.id
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSections: [ArkFileSurvivalGuideSection] {
        let query = trimmedQuery
        guard !query.isEmpty else { return sections }
        return sections.filter { $0.matches(query) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .id(Self.topAnchorID)
                    toolbar(proxy: proxy)
                    quickJump(proxy: proxy)

                    if filteredSections.isEmpty {
                        ContentUnavailableView(
                            "No matching sections",
                            systemImage: "magnifyingglass",
                            description: Text("Try water, shelter, fire, medical, vehicle, or recovery.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(filteredSections) { section in
                            ArkFileSurvivalGuideSectionCard(
                                section: section,
                                isExpanded: searchText.isEmpty ? expandedSectionIDs.contains(section.id) : true,
                                highlightQuery: trimmedQuery,
                                toggle: { toggle(section.id) }
                            )
                            .id(section.id)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 42)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .accessibilityIdentifier("arkfile_survival_guide_root")
            }
            .background(Color.arkSand.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                backToTopButton(proxy: proxy)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scrollToTop(proxy: proxy)
                    } label: {
                        Label("Top", systemImage: "arrow.up.to.line")
                    }
                    .accessibilityLabel("Back to top")
                }
            }
            .task(id: initialBlockID ?? initialSectionID) {
                await scrollToInitialTarget(proxy: proxy)
            }
        }
        .navigationTitle("Survival Guide")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.arkTeal)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Survival Guide", systemImage: "book.closed")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Color.arkInk)
            Text("A mobile-first field reference adapted from the desktop ArkFile guide. Search, jump by topic, and expand only what you need in the moment.")
                .font(.subheadline)
                .foregroundStyle(Color.arkTaupe)
                .fixedSize(horizontal: false, vertical: true)
            Label("Use official local instructions first during active emergencies.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.arkAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkBorder, lineWidth: 1)
        }
    }

    private func scrollToInitialTarget(proxy: ScrollViewProxy) async {
        guard let sectionID = Self.targetSectionID(
            sectionID: initialSectionID,
            blockID: initialBlockID,
            sections: sections
        ) else { return }
        expandedSectionIDs.insert(sectionID)
        let anchorID = initialBlockID ?? sectionID
        let retryDelays: [UInt64] = [50_000_000, 170_000_000, 320_000_000]
        for delay in retryDelays {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        withAnimation(.easeInOut) {
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
        }
    }

    private func backToTopButton(proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button {
                scrollToTop(proxy: proxy)
            } label: {
                Label("Top", systemImage: "arrow.up.to.line")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.arkSurface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.arkTeal)
                    .clipShape(Capsule())
                    .shadow(color: Color.arkInk.opacity(0.18), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to top")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.arkTaupe)
                TextField("Search water, fire, evacuation, first aid...", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.arkTaupe)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.arkSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.arkBorder, lineWidth: 1)
            }

            HStack(spacing: 8) {
                Button {
                    expandedSectionIDs = Set(sections.map(\.id))
                } label: {
                    Label("Expand all", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    expandedSectionIDs.removeAll()
                    if let firstID = sections.first?.id {
                        withAnimation(.easeInOut) {
                            proxy.scrollTo(firstID, anchor: .top)
                        }
                    }
                } label: {
                    Label("Collapse", systemImage: "minus.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
        }
    }

    private func quickJump(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    Button {
                        expandedSectionIDs.insert(section.id)
                        searchText = ""
                        withAnimation(.easeInOut) {
                            proxy.scrollTo(section.id, anchor: .top)
                        }
                    } label: {
                        Label(section.shortTitle, systemImage: section.systemImage)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.arkSurface)
                            .clipShape(Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color.arkBorder, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toggle(_ sectionID: String) {
        if expandedSectionIDs.contains(sectionID) {
            expandedSectionIDs.remove(sectionID)
        } else {
            expandedSectionIDs.insert(sectionID)
        }
    }
}

private struct ArkFileSurvivalGuideSectionCard: View {
    let section: ArkFileSurvivalGuideSection
    let isExpanded: Bool
    let highlightQuery: String
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: section.systemImage)
                        .font(.headline)
                        .foregroundStyle(section.accent)
                        .frame(width: 34, height: 34)
                        .background(section.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.arkInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(section.lede)
                            .font(.caption)
                            .foregroundStyle(Color.arkTaupe)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTaupe)
                        .padding(.top, 8)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(section.blocks) { block in
                        ArkFileSurvivalGuideBlockView(
                            block: block,
                            accent: section.accent,
                            highlightQuery: highlightQuery
                        )
                        .id(block.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color.arkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkBorder, lineWidth: 1)
        }
    }
}

private struct ArkFileSurvivalGuideBlockView: View {
    let block: ArkFileSurvivalGuideBlock
    let accent: Color
    var highlightQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = block.title {
                Label(title, systemImage: block.style.systemImage)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(block.style.titleColor(accent: accent))
            }
            if let body = block.body {
                Text(highlighted(body))
                    .font(.subheadline)
                    .foregroundStyle(Color.arkInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !block.lines.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(block.lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            if block.style == .steps {
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.arkSurface)
                                    .frame(width: 22, height: 22)
                                    .background(accent)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: block.style.bulletImage)
                                    .font(.caption)
                                    .foregroundStyle(block.style.titleColor(accent: accent))
                                    .frame(width: 18)
                                    .padding(.top, 3)
                            }
                            Text(highlighted(line))
                                .font(.subheadline)
                                .foregroundStyle(Color.arkInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(block.style.backgroundColor(accent: accent))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(block.style.borderColor(accent: accent), lineWidth: 1)
        }
    }

    /// Marks every occurrence of the active search query so users under stress can
    /// spot the exact matching phrase instead of rereading a whole section.
    private func highlighted(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        let query = highlightQuery
        guard !query.isEmpty else {
            return attributed
        }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
              ) {
            attributed[range].backgroundColor = Color.arkAmber.opacity(0.35)
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }
}

private struct ArkFileSurvivalGuideSection: Identifiable {
    let id: String
    let title: String
    let shortTitle: String
    let lede: String
    let systemImage: String
    let accent: Color
    let blocks: [ArkFileSurvivalGuideBlock]

    func matches(_ query: String) -> Bool {
        searchableText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private var searchableText: String {
        ([title, shortTitle, lede] + blocks.flatMap(\.searchableText)).joined(separator: " ")
    }
}

private struct ArkFileSurvivalGuideBlock: Identifiable {
    enum Style: Equatable {
        case plain
        case info
        case warning
        case danger
        case steps
        case checklist

        var systemImage: String {
            switch self {
            case .plain:
                "text.alignleft"
            case .info:
                "info.circle"
            case .warning:
                "exclamationmark.triangle"
            case .danger:
                "exclamationmark.octagon"
            case .steps:
                "list.number"
            case .checklist:
                "checklist"
            }
        }

        var bulletImage: String {
            switch self {
            case .danger, .warning:
                "exclamationmark.triangle.fill"
            case .info:
                "info.circle.fill"
            case .steps:
                "circle"
            case .plain, .checklist:
                "checkmark.circle.fill"
            }
        }

        func titleColor(accent: Color) -> Color {
            switch self {
            case .danger:
                .red
            case .warning:
                Color.arkAmber
            case .info:
                Color.arkTeal
            case .plain, .steps, .checklist:
                accent
            }
        }

        func backgroundColor(accent: Color) -> Color {
            switch self {
            case .danger:
                Color.red.opacity(0.08)
            case .warning:
                Color.arkAmber.opacity(0.10)
            case .info:
                Color.arkTeal.opacity(0.08)
            case .steps:
                accent.opacity(0.08)
            case .plain, .checklist:
                Color.arkSand.opacity(0.35)
            }
        }

        func borderColor(accent: Color) -> Color {
            switch self {
            case .danger:
                Color.red.opacity(0.35)
            case .warning:
                Color.arkAmber.opacity(0.35)
            case .info:
                Color.arkTeal.opacity(0.30)
            case .steps:
                accent.opacity(0.30)
            case .plain, .checklist:
                Color.arkBorder
            }
        }
    }

    let id: String
    let title: String?
    let body: String?
    let lines: [String]
    let style: Style

    var searchableText: [String] {
        [title, body].compactMap { $0 } + lines
    }

    static func plain(_ id: String, _ title: String, body: String? = nil, lines: [String] = []) -> Self {
        Self(id: id, title: title, body: body, lines: lines, style: .plain)
    }

    static func info(_ id: String, _ title: String, body: String? = nil, lines: [String] = []) -> Self {
        Self(id: id, title: title, body: body, lines: lines, style: .info)
    }

    static func warning(_ id: String, _ title: String, body: String? = nil, lines: [String] = []) -> Self {
        Self(id: id, title: title, body: body, lines: lines, style: .warning)
    }

    static func danger(_ id: String, _ title: String, body: String? = nil, lines: [String] = []) -> Self {
        Self(id: id, title: title, body: body, lines: lines, style: .danger)
    }

    static func steps(_ id: String, _ title: String, lines: [String]) -> Self {
        Self(id: id, title: title, body: nil, lines: lines, style: .steps)
    }

    static func checklist(_ id: String, _ title: String, lines: [String]) -> Self {
        Self(id: id, title: title, body: nil, lines: lines, style: .checklist)
    }
}

/// Lightweight description of a guide section, exposed so unified search can
/// surface guide sections without accessing the private content model.
struct ArkFileGuideSearchMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
}

enum ArkFileSurvivalGuideSearch {
    static func matches(for query: String, limit: Int = 3) -> [ArkFileGuideSearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        return ArkFileSurvivalGuideContent.sections
            .filter { $0.matches(trimmed) }
            .prefix(limit)
            .map { ArkFileGuideSearchMatch(id: $0.id, title: $0.title, systemImage: $0.systemImage) }
    }
}

private enum ArkFileSurvivalGuideContent {
    static let sections: [ArkFileSurvivalGuideSection] = [
        .init(
            id: "intro",
            title: "Start Here: Emergency Survival 101",
            shortTitle: "Start",
            lede: "Fix the problem that can kill first: air and bleeding, exposure, water, then food and morale.",
            systemImage: "list.clipboard",
            accent: Color.arkTeal,
            blocks: [
                .danger(
                    "intro-official",
                    "Use Official Instructions First",
                    lines: [
                        "Call emergency services for life-threatening danger, severe injury, fire, suspected stroke or heart attack, trouble breathing, or carbon monoxide symptoms.",
                        "Follow local emergency management, health department, utility, and National Weather Service instructions during active events.",
                        "If official guidance conflicts with this guide, use the official guidance for your location and event."
                    ]
                ),
                .plain(
                    "intro-threes",
                    "Rule of Threes",
                    lines: [
                        "3 minutes: airway, breathing, severe bleeding, icy water, or immediate violence.",
                        "3 hours: exposure to extreme heat, cold, wind, or wet conditions.",
                        "3 days: water, hydration, sanitation, and safe drinking-water treatment.",
                        "3 weeks: food, calories, morale, repair, and resupply."
                    ]
                ),
                .steps(
                    "intro-first-ten",
                    "First 10 Minutes",
                    lines: [
                        "Stop and assess fire, smoke, floodwater, structural damage, downed lines, weather, and injuries.",
                        "Move away from the immediate hazard before organizing supplies.",
                        "Account for people and pets, then check neighbors only if it is safe.",
                        "Text out-of-area contacts, monitor alerts, and conserve phone battery.",
                        "Protect water, temperature, medications, and critical documents."
                    ]
                ),
                .checklist(
                    "intro-timeframes",
                    "Planning Timeframes",
                    lines: [
                        "72 hours: go-bags, water, food, light, radio, medications, documents, and evacuation basics.",
                        "2 weeks: shelter-in-place water and food, sanitation, heat/cooling, backup power, fuel, and neighbor plan.",
                        "30+ days: replenishment, repair supplies, deep pantry, redundant communication, cash, skills, and recovery records."
                    ]
                )
            ]
        ),
        .init(
            id: "water",
            title: "Water: Storage, Sourcing, and Purification",
            shortTitle: "Water",
            lede: "Store first, source second, treat third. Dehydration and unsafe water can turn a manageable disruption into a medical emergency.",
            systemImage: "drop",
            accent: Color.arkTeal,
            blocks: [
                .danger(
                    "water-chemicals",
                    "Chemical Contamination Warning",
                    body: "Boiling, bleach, iodine, and most camping filters do not remove heavy metals, salts, fuel, pesticides, solvents, many industrial chemicals, or radiological contamination. Avoid floodwater and water with chemical odor or sheen unless authorities say it is safe."
                ),
                .checklist(
                    "water-store",
                    "How Much to Store",
                    lines: [
                        "Minimum: 1 gallon per person per day, plus pets and medical needs.",
                        "3-day target: 3 gallons per person.",
                        "2-week target: 14 gallons per person.",
                        "Store more for heat, pregnancy, nursing, illness, heavy work, infants, and animals."
                    ]
                ),
                .steps(
                    "water-storage",
                    "Safe Storage",
                    lines: [
                        "Use unopened commercial bottled water or FDA-approved food-grade containers.",
                        "Sanitize home-filled containers, label the date, and keep them cool, dark, and away from fuel or chemicals.",
                        "Replace home-filled water every 6 to 12 months.",
                        "Keep containers off bare concrete and use a clean spout or utensil."
                    ]
                ),
                .plain(
                    "water-hidden",
                    "Hidden Water at Home",
                    lines: [
                        "Water heater tank, if the system is not contaminated.",
                        "Toilet tank water, not the bowl, if no chemical tablets are present.",
                        "Water trapped in pipes, collected by opening the highest faucet and draining from the lowest.",
                        "Ice cubes and liquid from safe canned goods."
                    ]
                ),
                .checklist(
                    "water-treatment",
                    "Treatment Choices",
                    lines: [
                        "Boiling treats bacteria, viruses, and protozoa; use a rolling boil for 1 minute, or 3 minutes above 6,500 feet.",
                        "Unscented household bleach can disinfect many clear-water emergencies when used at label or public-health dosage.",
                        "Hollow-fiber filters handle sediment, protozoa, and bacteria, but usually not viruses or chemicals.",
                        "Chlorine dioxide, UV, and gravity filters are useful backups when you know their limits."
                    ]
                ),
                .checklist(
                    "water-boil-advisory",
                    "During a Boil-Water Advisory",
                    lines: [
                        "Use bottled or boiled water for drinking, brushing teeth, ice, food prep, baby formula, pet water, and rinsing produce.",
                        "Showering is generally fine for healthy adults if no water is swallowed; sponge-bathe infants and people with open wounds.",
                        "Wash dishes with a sanitizing dishwasher cycle, or rinse hand-washed dishes in water with a small measured amount of unscented bleach.",
                        "Throw out ice, drinks, and uncooked food made with tap water during the advisory.",
                        "After the all-clear, flush faucets and appliance water lines following your utility's instructions."
                    ]
                ),
                .info(
                    "water-dehydration",
                    "Dehydration Signs",
                    lines: [
                        "Mild: thirst, dry mouth, dark urine, headache, fatigue.",
                        "Moderate: dizziness, rapid heartbeat, very dark or scant urine, irritability.",
                        "Severe: confusion, fainting, rapid breathing, sunken eyes, or no urine for 12 hours."
                    ]
                )
            ]
        ),
        .init(
            id: "shelter",
            title: "Shelter, Warmth, and Cooling",
            shortTitle: "Shelter",
            lede: "Exposure can kill faster than thirst. Shelter means any barrier between people and heat, cold, wind, rain, smoke, or debris.",
            systemImage: "house",
            accent: Color.arkWood,
            blocks: [
                .checklist(
                    "shelter-hazards",
                    "Match Shelter to Hazard",
                    lines: [
                        "Tornado or high wind: basement or small interior room on the lowest floor; protect head and neck.",
                        "Flooding: evacuate early or move to higher ground; avoid basements and flooded roads.",
                        "Wildfire or smoke: leave early when ordered; close windows and vents while preparing to go.",
                        "Earthquake: Drop, Cover, Hold On under sturdy furniture, away from glass.",
                        "Chemical or air hazard: follow official shelter-in-place instructions."
                    ]
                ),
                .steps(
                    "shelter-warm-room",
                    "Build a Warm Room",
                    lines: [
                        "Choose a small interior room with few windows and enough sleeping space.",
                        "Close unused rooms, block drafts, and hang blankets over windows or doorways.",
                        "Put insulation under people before adding blankets over them.",
                        "Move water, medications, light, radio, chargers, first aid, and fire extinguisher into the room.",
                        "Keep required ventilation if using any approved fuel-burning appliance."
                    ]
                ),
                .danger(
                    "shelter-carbon-monoxide",
                    "Carbon Monoxide Safety",
                    body: "Never bring outdoor-only fuel sources indoors: charcoal grills, propane camp stoves, gas generators, and outdoor heaters can kill in minutes. Use only appliances rated for indoor use, exactly as labeled, with required ventilation and working carbon monoxide alarms."
                ),
                .checklist(
                    "shelter-cooling",
                    "Staying Cool Without Power",
                    lines: [
                        "Block sun early, especially on the sunny side of the home.",
                        "Sleep low in the building and ventilate only when outside air is cooler and safe.",
                        "Use wet cloth on skin and airflow in dry climates; drink steadily.",
                        "Move vulnerable people to a cooling center before confusion, fainting, or altered mental status appears."
                    ]
                ),
                .plain(
                    "shelter-field",
                    "Field Shelter Basics",
                    lines: [
                        "Get off the ground, out of wind, and dry before nightfall.",
                        "Avoid dry washes, ridge tops, dead branches, falling trees, and water-flow paths.",
                        "Reliable setups include tarp A-frame, lean-to, debris hut, snow cave, vehicle shelter, and contractor-bag emergency bivy."
                    ]
                )
            ]
        ),
        .init(
            id: "fire",
            title: "Fire: Starting, Building, and Safety",
            shortTitle: "Fire",
            lede: "Fire warms, dries, purifies, cooks, signals, and steadies morale. Most failed fires fail at tinder, not ignition.",
            systemImage: "flame",
            accent: Color.arkAmber,
            blocks: [
                .danger(
                    "fire-do-not",
                    "Do Not Light a Fire If",
                    lines: [
                        "There is a burn ban, high wind, drought, dry grass, overhead branches, or no way to extinguish it.",
                        "You are inside a tent, vehicle, garage, home, enclosed shelter, or any space without a properly vented appliance.",
                        "Smoke, sparks, or embers would increase wildfire risk.",
                        "You are tempted to use gasoline, aerosol sprays, plastics, treated wood, or trash."
                    ]
                ),
                .plain(
                    "fire-triangle",
                    "Fire Triangle",
                    lines: [
                        "Heat: lighter, match, spark, ember, or sun lens.",
                        "Fuel: tinder catches, kindling grows, larger fuel sustains.",
                        "Oxygen: loose structure lets air flow; tight piles smother flame."
                    ]
                ),
                .steps(
                    "fire-one-match",
                    "One-Match Method",
                    lines: [
                        "Clear the site to bare mineral soil or a nonflammable surface and keep water, dirt, or a shovel ready.",
                        "Build a dry base of bark, split sticks, flat rock, or green wood if the ground is wet.",
                        "Make a loose tinder nest and place matchstick-size kindling nearby before lighting.",
                        "Shield from wind while keeping airflow.",
                        "Add larger fuel only after the first kindling burns well.",
                        "Keep the fire small enough to control and extinguish."
                    ]
                ),
                .checklist(
                    "fire-fuel",
                    "Fuel Sizes",
                    lines: [
                        "Tinder: fine, fluffy, dry fibers such as cotton, dry grass, shredded bark, paper, or wood shavings.",
                        "Fine kindling: matchstick to pencil size.",
                        "Kindling: pencil to thumb size.",
                        "Fuel wood: thumb to wrist size for small survival fires."
                    ]
                ),
                .steps(
                    "fire-extinguish",
                    "Extinguish Until Cold",
                    lines: [
                        "Drown with water if available.",
                        "Stir to expose hot material underneath.",
                        "Add more water and stir again.",
                        "Feel near ashes with the back of your hand before touching.",
                        "Leave only when everything is cold; buried coals can reignite."
                    ]
                )
            ]
        ),
        .init(
            id: "medical",
            title: "Medical and First Aid",
            shortTitle: "Medical",
            lede: "Handle minor injuries, stabilize serious ones, and know which problems justify risking travel for professional help.",
            systemImage: "cross.case",
            accent: Color.arkReef,
            blocks: [
                .warning(
                    "medical-training",
                    "Training Matters",
                    body: "Keep a first-aid manual in the kit, but take hands-on First Aid, CPR, AED, and Stop the Bleed training before you need it. Reading is not a substitute for practice."
                ),
                .danger(
                    "medical-call",
                    "Call Emergency Services Immediately For",
                    lines: [
                        "Trouble breathing, chest pain, stroke signs, severe allergic reaction, seizure, major trauma, suspected poisoning, or unresponsiveness.",
                        "Severe bleeding that does not stop with firm pressure, blood spurting, amputation, or blood pooling rapidly.",
                        "Heat stroke signs: confusion, fainting, seizure, very high body temperature, or altered mental status.",
                        "Hypothermia signs: confusion, exhaustion, slurred speech, loss of coordination, weak pulse, or stopped shivering."
                    ]
                ),
                .steps(
                    "medical-cpr",
                    "Hands-Only CPR (Adults and Teens)",
                    lines: [
                        "For a teen or adult who collapses and is not breathing normally, call 911 or have someone call while you start.",
                        "Place the heel of one hand on the center of the chest, other hand on top, arms straight.",
                        "Push hard and fast: at least 2 inches deep, 100 to 120 compressions per minute, letting the chest fully recoil.",
                        "Do not stop until help arrives, an AED is ready, or the person starts breathing.",
                        "If trained in full CPR, give 30 compressions then 2 rescue breaths; hands-only is recommended for untrained helpers.",
                        "Send someone for the nearest AED and follow its voice prompts as soon as it arrives."
                    ]
                ),
                .steps(
                    "medical-stroke",
                    "Stroke: Think FAST",
                    lines: [
                        "Face: ask the person to smile; look for one side drooping.",
                        "Arms: ask them to raise both arms; watch for one drifting down.",
                        "Speech: ask them to repeat a simple sentence; listen for slurring or confusion.",
                        "Time: any one sign means call 911 immediately and note the exact time symptoms started.",
                        "Also call 911 for sudden trouble seeing, sudden trouble walking or balance, sudden numbness or weakness on one side, sudden confusion, or a sudden severe headache.",
                        "Do not give food, drink, or medication, and do not drive them yourself if help can come to you.",
                        "Lay them on their side if unconscious but breathing."
                    ]
                ),
                .steps(
                    "medical-heart-attack",
                    "Heart Attack",
                    lines: [
                        "Warning signs: chest pressure or squeezing lasting more than a few minutes, pain spreading to the arm, jaw, neck, or back, shortness of breath, nausea, or a cold sweat. Women often feel fatigue, nausea, and back or jaw pain more than chest pain.",
                        "Call 911 first; do not wait to see if it passes and do not drive yourself.",
                        "Stop all activity and sit or lie down with the head and shoulders raised.",
                        "After calling 911, follow dispatcher or clinician guidance about aspirin; do not take it if allergic, at risk of bleeding, or told by a doctor to avoid aspirin.",
                        "Loosen tight clothing and stay with them.",
                        "If they become unresponsive and stop breathing normally, start CPR."
                    ]
                ),
                .steps(
                    "medical-scene",
                    "Life Threats First",
                    lines: [
                        "Check scene safety: fire, traffic, electricity, gas, floodwater, violence, unstable debris.",
                        "Check responsiveness and breathing; call 911 and start CPR if trained.",
                        "Control severe bleeding with direct pressure, packing, then tourniquet if trained.",
                        "Look for trouble breathing, chest injury, smoke inhalation, or allergic reaction.",
                        "Treat shock and exposure by keeping the person still, warm, dry, and reassured."
                    ]
                ),
                .steps(
                    "medical-bleeding",
                    "Bleeding Control",
                    lines: [
                        "Apply direct pressure with both hands and body weight for 5 to 10 minutes without peeking.",
                        "Pack deep wounds with gauze or clean cloth while pressing firmly.",
                        "Use a tourniquet for life-threatening limb bleeding when pressure and packing fail or bleeding is immediately catastrophic.",
                        "Record tourniquet time and get professional care as soon as possible."
                    ]
                ),
                .steps(
                    "medical-burns",
                    "Burns",
                    lines: [
                        "Stop the burning: remove the person from the source and smother flames.",
                        "Cool the burn under cool running water for at least 10 minutes. Never use ice, butter, or ointments on serious burns.",
                        "Remove rings, watches, and tight clothing near the burn before swelling starts; do not pull off stuck fabric.",
                        "Cover loosely with a sterile non-stick dressing or clean cloth.",
                        "Get professional care for burns larger than the person's palm, on the face, hands, feet, or genitals, from chemicals or electricity, or with any breathing trouble."
                    ]
                ),
                .steps(
                    "medical-choking",
                    "Choking",
                    lines: [
                        "If the person can cough or speak, encourage forceful coughing and stay with them.",
                        "If they cannot breathe, give 5 firm back blows between the shoulder blades with the heel of your hand.",
                        "If not relieved, give 5 abdominal thrusts just above the navel; alternate 5 and 5.",
                        "Use chest thrusts instead of abdominal thrusts for pregnant or larger-bodied people.",
                        "For infants under 1 year: 5 back blows, then 5 chest thrusts with two fingers; never abdominal thrusts.",
                        "If the person becomes unresponsive, call 911 and start CPR if trained."
                    ]
                ),
                .steps(
                    "medical-anaphylaxis",
                    "Severe Allergic Reaction",
                    lines: [
                        "Watch for trouble breathing, swelling of the face or tongue, widespread hives with dizziness, or vomiting after an exposure.",
                        "Use an epinephrine auto-injector immediately in the outer mid-thigh; it can go through clothing.",
                        "Call 911 even if symptoms improve; reactions can return hours later.",
                        "If symptoms do not improve in 5 to 15 minutes and a second injector is available, give a second dose.",
                        "Lay the person flat with legs raised; let them sit up if breathing is hard. Antihistamines do not replace epinephrine."
                    ]
                ),
                .steps(
                    "medical-splint",
                    "Splinting a Suspected Break",
                    lines: [
                        "Check feeling, warmth, and color beyond the injury before and after splinting.",
                        "Splint the limb in the position found; do not try to straighten it.",
                        "Immobilize the joint above and the joint below the injury with a rigid item and padding.",
                        "Tie snugly away from the injury itself, but never tight enough to cut off circulation.",
                        "Recheck fingers or toes for numbness or color change every 15 minutes and loosen if needed."
                    ]
                ),
                .steps(
                    "medical-hypothermia",
                    "Rewarming Hypothermia",
                    lines: [
                        "Move the person to warm, dry shelter and handle them gently.",
                        "Remove wet clothing and wrap in dry layers, covering the head and neck.",
                        "Warm the center of the body first: chest, neck, and groin, using dry warm compresses or skin-to-skin contact under blankets.",
                        "Give warm, sweet, non-alcoholic drinks only if the person is fully alert and can swallow.",
                        "Do not rub arms or legs or use direct high heat. If the person is confused, has stopped shivering, or is unresponsive, call 911."
                    ]
                ),
                .steps(
                    "medical-heat-stroke",
                    "Cooling Heat Stroke",
                    lines: [
                        "Heat stroke is an emergency: confusion, fainting, or very high body temperature means call 911 first.",
                        "Move the person to shade or the coolest space available and remove extra clothing.",
                        "Cool aggressively: immerse in cool water if possible, or soak skin and fan constantly, with cold packs at neck, armpits, and groin.",
                        "Do not give fluids to anyone confused or unresponsive.",
                        "For heat exhaustion without confusion: cool place, sips of water, loose clothing; get help if symptoms worsen or last more than an hour."
                    ]
                ),
                .danger(
                    "medical-poisoning",
                    "Poisoning",
                    lines: [
                        "US Poison Control: 1-800-222-1222, available 24 hours. Write this number on paper in your kit.",
                        "Do not induce vomiting or give food, drink, or activated charcoal unless Poison Control or 911 tells you to.",
                        "Chemical on skin: remove contaminated clothing and rinse skin with running water for 15 to 20 minutes.",
                        "Chemical in eye: rinse the open eye with lukewarm water for at least 15 minutes.",
                        "Suspected carbon monoxide: get everyone to fresh air immediately and call 911."
                    ]
                ),
                .checklist(
                    "medical-continuity",
                    "Medication Continuity",
                    lines: [
                        "Keep at least a 7-day buffer of critical prescriptions; 30 days is better where refill rules allow.",
                        "Photograph every prescription label and keep a paper medication list with doses and prescriber contacts.",
                        "Refrigerated medications: move to a cooler with ice packs, avoid direct contact with ice, and do not let them freeze.",
                        "Most insulin can be used at room temperature for up to 28 days when refrigeration fails; check the maker's guidance and replace as soon as possible.",
                        "Many states allow emergency pharmacy refills during declared disasters; ask the pharmacist.",
                        "Never share prescription medication between people, even in an emergency."
                    ]
                ),
                .checklist(
                    "medical-kit",
                    "First Aid Kit Core",
                    lines: [
                        "Gloves, absorbent dressings, sterile gauze, roller gauze, tape, elastic wrap, pressure bandage.",
                        "Tourniquet and hemostatic gauze if trained.",
                        "Acetaminophen, ibuprofen, aspirin, diphenhydramine, loperamide, oral rehydration salts, and prescription buffer.",
                        "Trauma shears, tweezers, thermometer, CPR mask, splints, triangular bandages, headlamp, marker, and first-aid booklet."
                    ]
                )
            ]
        ),
        .init(
            id: "sanitation",
            title: "Sanitation, Hygiene, and Waste",
            shortTitle: "Sanitation",
            lede: "Bad sanitation can turn an outage into a disease problem. Keep clean water, food, wounds, and sleeping areas separated from waste.",
            systemImage: "sparkles",
            accent: Color.arkTeal,
            blocks: [
                .steps(
                    "sanitation-priorities",
                    "Sanitation Priorities",
                    lines: [
                        "Separate clean and dirty zones.",
                        "Wash hands with safe water and soap after toilet use, cleanup, animal contact, and before food or wound care.",
                        "Control toilet waste with bucket toilet, portable toilet, or lined household toilet only if sewer guidance allows.",
                        "Double-bag contaminated trash and keep animals and insects out.",
                        "Clean dirt and organic matter first, then disinfect."
                    ]
                ),
                .steps(
                    "sanitation-toilet",
                    "Emergency Toilet Setup",
                    lines: [
                        "Use a sturdy 5-gallon bucket or portable toilet with tight lid.",
                        "Line with heavy trash bags; double-bag if thin.",
                        "Cover each use with absorbent material such as cat litter, sawdust, shredded paper, soil, or commercial toilet media.",
                        "When partly full, tie securely and store in a sealed outdoor container until local disposal guidance is available."
                    ]
                ),
                .warning(
                    "sanitation-bleach",
                    "Bleach Safety",
                    lines: [
                        "Never mix bleach with ammonia, vinegar, acids, toilet cleaners, or other chemicals.",
                        "Use ventilation, gloves, and eye protection.",
                        "Label mixed solutions and keep them away from children, pets, food, and drinking-water containers."
                    ]
                ),
                .danger(
                    "sanitation-flood",
                    "Floodwater and Sewage",
                    body: "Assume floodwater contains sewage, chemicals, sharp debris, fuel, and electrical hazards. Wash skin with safe water and soap after contact, clean and cover wounds, and seek care for infection, punctures, fever, or tetanus concerns."
                )
            ]
        ),
        .init(
            id: "food",
            title: "Food: Storage, Cooking, and Finding Calories",
            shortTitle: "Food",
            lede: "Food can wait longer than water, but weak thinking, cold stress, and low morale arrive early. Build food in layers.",
            systemImage: "takeoutbag.and.cup.and.straw",
            accent: Color.arkAmber,
            blocks: [
                .checklist(
                    "food-store",
                    "What to Store",
                    lines: [
                        "Ready-to-eat food for go-bags and evacuation.",
                        "Two weeks of shelf-stable meals your household already eats.",
                        "Low-water staples: rice, oats, pasta, dry beans, lentils, peanut butter, canned meat, soup, vegetables, and fruit.",
                        "Special-diet food for allergies, diabetes, infants, hypertension, pets, and prescription supplements.",
                        "Manual can openers, seasonings, coffee/tea, and morale foods."
                    ]
                ),
                .steps(
                    "food-rotation",
                    "Storage and Rotation",
                    lines: [
                        "Store cool, dry, dark, and pest-protected.",
                        "Use first-in-first-out rotation and mark dates.",
                        "Discard bulging, leaking, deeply dented, badly rusted, or foul cans.",
                        "Do not use food containers that contacted floodwater unless official guidance says they can be cleaned."
                    ]
                ),
                .danger(
                    "food-cooking",
                    "Cooking Without Power",
                    body: "Charcoal, propane, gas, and kerosene combustion is for outdoors only, well away from windows and intake vents. Carbon monoxide is odorless and can kill."
                ),
                .checklist(
                    "food-safety",
                    "Power-Outage Food Safety",
                    lines: [
                        "Keep refrigerator and freezer doors closed.",
                        "A closed refrigerator stays safe about 4 hours; a full freezer about 48 hours; a half-full freezer about 24 hours.",
                        "Never taste food to judge safety.",
                        "Discard perishables held above 40 degrees F for more than 2 hours."
                    ]
                ),
                .warning(
                    "food-wild",
                    "Finding Food Outside Storage",
                    lines: [
                        "Foraging requires confident identification; if you are not 100 percent sure, do not eat it.",
                        "Fishing often yields the most calories for the least equipment when safe water is available.",
                        "Trapping and hunting are regulated; follow local law outside true survival emergencies.",
                        "Preserve meat and produce quickly with safe drying, smoking, salting, fermenting, root cellaring, or tested canning methods."
                    ]
                )
            ]
        ),
        .init(
            id: "power",
            title: "Power, Light, and Communication",
            shortTitle: "Power",
            lede: "Prioritize life-sustaining equipment, information, safe light, refrigerated medication, and temperature safety before comfort loads.",
            systemImage: "bolt",
            accent: Color.arkTeal,
            blocks: [
                .steps(
                    "power-priority",
                    "Power Priority Order",
                    lines: [
                        "Medical devices and refrigerated medication.",
                        "Communication: phone, radio, chargers, backup battery, written contacts.",
                        "Safety: LED light, carbon monoxide alarms, smoke alarms, sump or well pump when relevant.",
                        "Food and medication preservation.",
                        "Heat or cooling only when indoor temperature becomes hazardous."
                    ]
                ),
                .checklist(
                    "power-lighting",
                    "Lighting",
                    lines: [
                        "Use LED flashlights, headlamps, battery lanterns, chemical lights, and solar or hand-crank lights.",
                        "Store lights where people can reach them in the dark: bedrooms, kitchen, exits, vehicle, and go-bags.",
                        "Avoid candles when possible; if used, keep them away from children, pets, curtains, and anything that can tip."
                    ]
                ),
                .danger(
                    "power-generator",
                    "Generator Safety",
                    lines: [
                        "Run generators outdoors only, at least 20 feet from doors, windows, vents, garages, and crawlspaces.",
                        "Point exhaust away from buildings and neighbors.",
                        "Never run a generator in a home, basement, garage, shed, porch, carport, or near an open window.",
                        "Use battery-powered carbon monoxide alarms on every level and near sleeping areas.",
                        "Never backfeed through a wall outlet."
                    ]
                ),
                .checklist(
                    "power-triage",
                    "Limited Power Triage",
                    lines: [
                        "Write every device on paper with watts and hours needed.",
                        "Separate must-run from nice-to-run.",
                        "Run loads in shifts instead of everything at once.",
                        "Keep one battery bank reserved for emergency communication."
                    ]
                )
            ]
        ),
        .init(
            id: "communications",
            title: "Alerts, Communication, and Information",
            shortTitle: "Comms",
            lede: "Good information changes survival decisions. Plan for alerts, check-ins, local broadcasts, and rumor control before networks fail.",
            systemImage: "radio",
            accent: Color.arkReef,
            blocks: [
                .checklist(
                    "comms-alerts",
                    "Redundant Alert Sources",
                    lines: [
                        "Wireless Emergency Alerts on compatible phones.",
                        "NOAA Weather Radio with batteries and correct station setup.",
                        "County or city emergency alerts registered before hazard season.",
                        "AM/FM radio for broad local information.",
                        "Trusted neighbors for observed local conditions."
                    ]
                ),
                .steps(
                    "comms-plan",
                    "Household Communication Plan",
                    lines: [
                        "Choose one out-of-area contact.",
                        "Write critical numbers on paper: household, neighbors, doctors, pharmacy, school/work, vet, insurance, utilities, shelters.",
                        "Text first and keep messages short: location, status, next action.",
                        "Choose meeting places near home, outside the neighborhood, and outside town.",
                        "Keep paper copies in wallets, go-bags, vehicles, and with caregivers or schools."
                    ]
                ),
                .info(
                    "comms-noaa",
                    "NOAA Weather Radio Frequencies",
                    lines: [
                        "All seven US channels: 162.400, 162.425, 162.450, 162.475, 162.500, 162.525, and 162.550 MHz.",
                        "Program your local station and county SAME alert code before hazard season; keep the list on paper with the radio.",
                        "Scan the seven frequencies in order if you do not know the local channel; most areas receive at least one.",
                        "Keep spare batteries with the radio, and test it monthly."
                    ]
                ),
                .info(
                    "comms-rumors",
                    "Rumor Control",
                    lines: [
                        "Trust official alerts for evacuation, water safety, shelter locations, road closures, and all-clear notices.",
                        "Label information as confirmed, observed, reported, or unknown.",
                        "Do not repost screenshots or secondhand warnings without source, date, and location.",
                        "If instructions conflict, use the most local official source for your exact hazard and location."
                    ]
                )
            ]
        ),
        .init(
            id: "navigation",
            title: "Navigation and Signaling",
            shortTitle: "Nav",
            lede: "GPS can fail. Practice paper maps, compass, sun, stars, terrain, route cards, and simple distress signals before you need them.",
            systemImage: "location.north",
            accent: Color.arkTeal,
            blocks: [
                .steps(
                    "nav-stop",
                    "If Lost: STOP",
                    lines: [
                        "Stop moving as soon as you realize you are unsure.",
                        "Think back to the last certain location and direction of travel.",
                        "Observe terrain, sun, water flow, signs of habitation, and safe vantage points.",
                        "Plan whether to stay put for rescue or move by a clear terrain rule."
                    ]
                ),
                .checklist(
                    "nav-carry",
                    "Carry and Prepare",
                    lines: [
                        "Paper map, compass, pencil, whistle, headlamp, spare batteries, bright cloth, signal mirror, and power bank.",
                        "Offline maps downloaded before travel.",
                        "Route, destination, vehicle location, and return time shared with someone reliable.",
                        "Local magnetic declination known if precision matters."
                    ]
                ),
                .plain(
                    "nav-direction",
                    "Finding Direction",
                    lines: [
                        "Shadow stick: mark the first shadow tip, wait 15 to 30 minutes, mark the second; the line runs west to east.",
                        "Northern hemisphere: use the Big Dipper pointer stars to find Polaris, the North Star.",
                        "Map orientation: turn the map until terrain features match the ground."
                    ]
                ),
                .info(
                    "nav-signals",
                    "Distress Signals",
                    lines: [
                        "Three of anything is a distress signal: three fires, three whistle blasts, three flashes, or three repeated sounds.",
                        "SOS in Morse is three short, three long, three short.",
                        "Ground-to-air markers should be large, high contrast, and visible from above.",
                        "A whistle carries farther than shouting and uses less energy."
                    ]
                )
            ]
        ),
        .init(
            id: "hazards",
            title: "Regional Hazard Profiles",
            shortTitle: "Hazards",
            lede: "Know your local top hazards, alert systems, evacuation zones, and shelter locations. One generic kit is not enough.",
            systemImage: "exclamationmark.triangle",
            accent: Color.arkAmber,
            blocks: [
                .info(
                    "hazards-watch-warning",
                    "Watch vs Warning",
                    body: "Watch means conditions are favorable: prepare and stay alert. Warning means the hazard is occurring or imminent: take protective action now."
                ),
                .checklist(
                    "hazards-actions",
                    "Protective Actions",
                    lines: [
                        "Hurricane: know evacuation zone, leave if ordered, secure loose outdoor items, protect windows, and store water early.",
                        "Tornado: lowest interior room, away from windows, head and neck protected.",
                        "Earthquake: Drop, Cover, Hold On; secure furniture and water heaters before hazard season.",
                        "Flood: move to higher ground and never walk or drive through floodwater.",
                        "Wildfire: create defensible space and evacuate early.",
                        "Winter storm: safe heat only, protect pipes, clear exhaust vents, and stay off roads if possible.",
                        "Extreme heat: cooling centers, hydration, activity reduction, and check-ins for vulnerable people."
                    ]
                ),
                .steps(
                    "hazards-homework",
                    "Local Hazard Homework",
                    lines: [
                        "Sign up for county and city emergency alerts.",
                        "Know evacuation zones for hurricane, wildfire, flood, tsunami, or dam failure if applicable.",
                        "Learn water, electricity, and gas shutoffs.",
                        "Keep printed maps because apps may fail when power or data networks are overloaded."
                    ]
                )
            ]
        ),
        .init(
            id: "vehicle",
            title: "Vehicle Preparedness",
            shortTitle: "Vehicle",
            lede: "A vehicle can be transport, shelter, charging source, and supply cache. It can also become a trap in flood, fire, tornado, or winter conditions.",
            systemImage: "car",
            accent: Color.arkWood,
            blocks: [
                .checklist(
                    "vehicle-kit",
                    "Vehicle Kit",
                    lines: [
                        "Jumper cables or jump starter, spare tire, jack, lug wrench, inflator, pressure gauge, reflective triangles, and basic tools.",
                        "Water, shelf-stable snacks, blanket, first aid kit, flashlight, phone charger, power bank, paper maps, and cash.",
                        "Rain poncho, warm layers, gloves, hat, ice scraper, small shovel, traction sand, and sun protection for hot climates."
                    ]
                ),
                .steps(
                    "vehicle-load",
                    "Load Order When Minutes Matter",
                    lines: [
                        "People, pets/service animals, mobility equipment, critical medical devices, oxygen, and medications.",
                        "Go-bags, water, food, phone/radio chargers, cash, maps, and IDs.",
                        "Insurance documents, pet records, comfort items, spare clothing, and sanitation supplies.",
                        "Only then consider extra valuables; do not delay departure for replaceable property."
                    ]
                ),
                .warning(
                    "vehicle-hazards",
                    "Vehicle Hazard Rules",
                    lines: [
                        "Flood: never drive through flooded roads.",
                        "Tornado: vehicles and overpasses are unsafe; get to sturdy shelter if possible.",
                        "Wildfire: leave before smoke and fire block routes.",
                        "Winter: stay with the vehicle unless a safe building is close and visible; clear the exhaust before running the engine.",
                        "Heat: never leave children, pets, or vulnerable adults in a parked vehicle."
                    ]
                )
            ]
        ),
        .init(
            id: "special-care",
            title: "Special Populations Care",
            shortTitle: "Care",
            lede: "Preparedness is personal. Infants, older adults, disabled people, chronically ill people, and pets need plans generic kits miss.",
            systemImage: "person.2",
            accent: Color.arkReef,
            blocks: [
                .checklist(
                    "care-sheet",
                    "Care Sheet for Each Person",
                    lines: [
                        "Name, date of birth, emergency contacts, doctor, pharmacy, insurance, diagnoses, and allergies.",
                        "Medication name, dose, schedule, refill information, and what happens if a dose is missed.",
                        "Equipment needs: oxygen, CPAP, ventilator, dialysis, powered wheelchair, communication device, or refrigeration.",
                        "Evacuation needs: transport type, mobility limits, service animal or pet plan, sensory and communication needs."
                    ]
                ),
                .checklist(
                    "care-module",
                    "72-Hour Care Module",
                    lines: [
                        "Current medications, dosing list, copies of labels, and pharmacy contact.",
                        "Mobility repair items, chargers, transfer aids, gloves, and equipment instructions.",
                        "Written cards, picture boards, hearing-aid batteries, interpreter notes, comfort items, and routine cards.",
                        "Allergy-safe, diabetic, renal, texture-safe, formula, feeding, and pet supplies."
                    ]
                ),
                .steps(
                    "care-infant-feeding",
                    "Infant Feeding in Emergencies",
                    lines: [
                        "Breastfeeding stays safe during most emergencies; give the nursing parent extra water and food.",
                        "Ready-to-feed formula is the safest option when clean water is limited; store some even if you normally use powder.",
                        "Mix powdered formula only with bottled water or water that was boiled and cooled; wash hands first.",
                        "Use prepared formula within 2 hours at room temperature, and within 1 hour after a feeding starts; discard leftovers.",
                        "Wash bottles and nipples with safe water and soap, and boil them when possible.",
                        "Do not water down formula to stretch supply, and do not substitute other milks for infants under 1 year."
                    ]
                ),
                .steps(
                    "care-power",
                    "Powered Medical Equipment Plan",
                    lines: [
                        "Write the device name, power draw, battery runtime, charger type, and inverter requirements.",
                        "Ask the supplier or clinician what backup power and travel setup is approved.",
                        "Set a relocation trigger before batteries run low.",
                        "Register with utility and local emergency programs, but treat registration as backup, not a guarantee.",
                        "Keep paper instructions so another caregiver can operate equipment under stress."
                    ]
                )
            ]
        ),
        .init(
            id: "security",
            title: "Security and Situational Awareness",
            shortTitle: "Security",
            lede: "Avoid trouble through awareness, preparation, neighbor cooperation, and a low profile. Confrontation is the last option.",
            systemImage: "shield",
            accent: Color.arkTeal,
            blocks: [
                .plain(
                    "security-awareness",
                    "Awareness States",
                    lines: [
                        "White: oblivious. Avoid outside the home.",
                        "Yellow: relaxed but aware. Sustainable default.",
                        "Orange: a specific person, vehicle, or situation has attention.",
                        "Red: active threat and action plan in motion."
                    ]
                ),
                .checklist(
                    "security-home",
                    "Home Hardening",
                    lines: [
                        "Solid-core or metal doors, reinforced strike plates with long screws, deadbolts, and peephole or camera.",
                        "Secondary window locks, dowels in sliding tracks, and maintained sight lines near windows.",
                        "Motion lights, dusk-to-dawn lighting, and charged headlamps.",
                        "Generator or extension-cord routing that does not leave doors or windows open."
                    ]
                ),
                .info(
                    "security-community",
                    "Community Is the Multiplier",
                    lines: [
                        "Know neighbor names and phone numbers before the emergency.",
                        "Identify useful skills, tools, and people who need checking.",
                        "Set simple check-in protocols.",
                        "Coordinate without advertising every supply publicly."
                    ]
                ),
                .warning(
                    "security-deescalate",
                    "Conflict Reduction",
                    lines: [
                        "Keep tone calm and give clear choices.",
                        "Avoid public arguments over scarce resources.",
                        "Do not pursue people; document suspicious damage only if safe.",
                        "Use distance, time, barriers, and a closed door whenever possible."
                    ]
                )
            ]
        ),
        .init(
            id: "psychology",
            title: "Mindset and Survival Psychology",
            shortTitle: "Mindset",
            lede: "Mental state shapes outcomes. Calm people make better choices, conserve energy, and keep groups functional.",
            systemImage: "brain.head.profile",
            accent: Color.arkReef,
            blocks: [
                .steps(
                    "mindset-stop",
                    "Control Panic with STOP",
                    lines: [
                        "Stop moving.",
                        "Think: what is the actual threat?",
                        "Observe: what do I have, where am I, what is the weather?",
                        "Plan: choose the next single action."
                    ]
                ),
                .steps(
                    "mindset-box",
                    "Box Breathing",
                    lines: [
                        "Inhale through the nose for 4 seconds.",
                        "Hold for 4 seconds.",
                        "Exhale through the mouth for 4 seconds.",
                        "Hold empty for 4 seconds.",
                        "Repeat 4 to 8 cycles."
                    ]
                ),
                .warning(
                    "mindset-traps",
                    "Common Traps",
                    lines: [
                        "Normalcy bias: refusing to accept that an emergency is happening.",
                        "Sunk-cost thinking: refusing to abandon a path, vehicle, or shelter that is no longer working.",
                        "Get-there-itis: pushing through worsening conditions to reach a goal that can wait.",
                        "Hero fatigue: trying to handle everything alone and burning out."
                    ]
                ),
                .checklist(
                    "mindset-team",
                    "Run the Group Like a Team",
                    lines: [
                        "Name the leader for the next hour.",
                        "Assign one short task at a time.",
                        "Keep a status board: people, pets, water, food, power, sanitation, medical, security, next update.",
                        "Schedule information checks instead of constant news.",
                        "Pair people for risky tasks."
                    ]
                )
            ]
        ),
        .init(
            id: "planning",
            title: "Planning and Practice",
            shortTitle: "Plan",
            lede: "Supplies only help when people know where they are, how to use them, and when to leave.",
            systemImage: "square.and.pencil",
            accent: Color.arkAmber,
            blocks: [
                .steps(
                    "planning-household",
                    "Household Emergency Plan",
                    lines: [
                        "Choose an out-of-area contact and write phone numbers on paper.",
                        "Pick meeting places near home, outside the neighborhood, and outside town.",
                        "Assign roles for go-bags, medications, pets, documents, water shutoff, and chargers.",
                        "Map at least two evacuation routes and one backup destination in each direction.",
                        "Plan for mobility, medical equipment, refrigerated meds, infants, pets, and communication needs."
                    ]
                ),
                .checklist(
                    "planning-kits",
                    "Kit Types",
                    lines: [
                        "Go-bag: leave quickly for 72 hours.",
                        "Home shelter kit: 2 weeks of water, food, sanitation, heat/cooling, tools, and backup power.",
                        "Vehicle kit: breakdown, winter stranding, evacuation traffic, and roadside safety.",
                        "Bedside kit: shoes, light, whistle, glasses, gloves, and local hazard items."
                    ]
                ),
                .warning(
                    "planning-triggers",
                    "Evacuation Triggers",
                    lines: [
                        "Official evacuation order.",
                        "Water over the road or rising floodwater.",
                        "Smoke or fire moving toward route.",
                        "Unsafe indoor heat or cold.",
                        "Medical power or medication limit reached.",
                        "Gas smell, structural damage, or fire."
                    ]
                ),
                .checklist(
                    "planning-maintenance",
                    "Maintenance Schedule",
                    lines: [
                        "Monthly: charge power banks and check radios, lights, pet, and infant supplies.",
                        "Every 6 months: rotate home-filled water, update contacts and medical sheets, change seasonal clothing.",
                        "Yearly: review insurance, documents, food, extinguishers, smoke alarms, carbon monoxide alarms, and generator service.",
                        "Before hazard season: fuel, vehicle maintenance, route review, and hazard-specific supplies."
                    ]
                )
            ]
        ),
        .init(
            id: "recovery",
            title: "Post-Disaster Recovery",
            shortTitle: "Recovery",
            lede: "After immediate danger, hazards change: unstable structures, gas leaks, floodwater, mold, paperwork, scams, and exhaustion.",
            systemImage: "arrow.triangle.2.circlepath",
            accent: Color.arkWood,
            blocks: [
                .checklist(
                    "recovery-return",
                    "Return Home Safely",
                    lines: [
                        "Wait for official clearance if evacuated.",
                        "Stay away from downed lines, damaged gas lines, floodwater, unstable structures, and damaged trees.",
                        "If you smell gas, hear hissing, or suspect a leak, leave immediately and call from a safe distance.",
                        "Use flashlights, not candles, when inspecting.",
                        "Wear boots, gloves, eye protection, and respiratory protection for debris, mold, ash, or flood cleanup."
                    ]
                ),
                .steps(
                    "recovery-first-hour",
                    "First Hour Back",
                    lines: [
                        "Walk the outside first if safe, checking walls, foundation, roof, utilities, downed lines, gas smell, and floodwater.",
                        "Do not enter if the structure looks unsafe, smells like gas, has standing water near electricity, or has not been cleared.",
                        "Turn around if you feel dizziness, headache, nausea, burning eyes or throat, or trouble breathing.",
                        "Photograph damage before moving items, then protect openings only if safe.",
                        "Keep children, pets, and unnecessary helpers away until hazards are controlled."
                    ]
                ),
                .steps(
                    "recovery-document",
                    "Document Before Cleanup",
                    lines: [
                        "Photograph or video all damage before moving items if safe.",
                        "Make an inventory of damaged or lost items.",
                        "Save receipts for lodging, food, repairs, fuel, supplies, and cleanup.",
                        "Keep damaged items until insurer or local officials give instructions unless unsafe.",
                        "Track calls, claim numbers, names, dates, and promises in one notebook."
                    ]
                ),
                .warning(
                    "recovery-scams",
                    "Scam Resistance",
                    lines: [
                        "Be cautious with door-to-door repair offers, pressure tactics, blank contracts, and large upfront payments.",
                        "Verify licenses, insurance, references, and written estimates.",
                        "Do not share personal or financial information with unexpected callers claiming to be aid staff.",
                        "Government disaster assistance workers should not charge a fee to apply."
                    ]
                )
            ]
        ),
        .init(
            id: "sources",
            title: "Sources and Further Reading",
            shortTitle: "Sources",
            lede: "Source names are useful offline for auditability. Links from the desktop guide require internet access.",
            systemImage: "books.vertical",
            accent: Color.arkTeal,
            blocks: [
                .plain(
                    "sources-agencies",
                    "Primary Agency References",
                    lines: [
                        "CDC emergency water, disaster health, heat, cold, sanitation, cleanup, and carbon monoxide guidance.",
                        "EPA emergency drinking-water disinfection guidance.",
                        "Ready.gov and FEMA Build a Kit, Make a Plan, alerts, hazard pages, and CERT materials.",
                        "NOAA and National Weather Service flood, tornado, hurricane, heat, winter, and weather-radio guidance.",
                        "American Red Cross first aid, CPR, AED, heart attack care, and disaster recovery resources.",
                        "USDA FSIS power-outage food safety guidance.",
                        "National Center for Home Food Preservation tested preservation guidance."
                    ]
                ),
                .checklist(
                    "sources-printed",
                    "Printed References Worth Keeping",
                    lines: [
                        "US Army Survival Manual.",
                        "NOLS Wilderness Medicine.",
                        "Where There Is No Doctor and Where There Is No Dentist.",
                        "Regional edible plant field guides taught alongside in-person foraging instruction.",
                        "Deep Survival for psychology and decision-making."
                    ]
                ),
                .info(
                    "sources-training",
                    "Skills to Take in Person",
                    lines: [
                        "Red Cross First Aid plus CPR/AED.",
                        "Stop the Bleed.",
                        "CERT through local emergency management.",
                        "Wilderness First Aid or Wilderness First Responder.",
                        "Amateur radio Technician class.",
                        "Local hazard, foraging, navigation, and equipment practice."
                    ]
                )
            ]
        )
    ]
}
#endif
