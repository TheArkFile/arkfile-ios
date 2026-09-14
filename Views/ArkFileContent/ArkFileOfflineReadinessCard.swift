// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#if os(iOS)
import SwiftUI
import UIKit

struct ArkFileOfflineReadinessCard: View {
    @ObservedObject private var checker = ArkFileOfflineReadinessChecker.shared
    @ObservedObject private var reminder = ArkFileOfflineReadinessReminder.shared
    let openDetails: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.arkTextPrimary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.arkTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let checkedAt = checker.result.checkedAt {
                Label("Last offline check: \(Self.dateFormatter.string(from: checkedAt))", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.arkTextMuted)
            }

            Label(reminderSummary, systemImage: reminderIcon)
                .font(.caption)
                .foregroundStyle(Color.arkTextMuted)

            Button(action: openDetails) {
                Label(primaryButtonTitle, systemImage: "shield.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.arkPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.arkAppSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.arkAppBorder, lineWidth: 1)
        }
        .task {
            await reminder.refreshStatus()
        }
    }

    private var title: String {
        switch checker.result.status {
        case .ready where checker.hasRecentPassingCheck:
            "Offline Check Passed"
        case .needsAttention:
            "Offline Readiness Needs Attention"
        case .checking:
            "Checking Offline Readiness"
        default:
            "Check Your Offline Library"
        }
    }

    private var message: String {
        switch checker.result.status {
        case .ready where checker.hasRecentPassingCheck:
            "ArkFile verified your selected content on this device. Check again after downloads, repairs, iOS updates, or device migration."
        case .needsAttention:
            "ArkFile found something that could keep saved content from opening offline. Review the details before relying on it."
        case .checking:
            "ArkFile is checking locally saved content without using the internet."
        default:
            "Open ArkFile and make sure your saved content opens offline before you need it."
        }
    }

    private var iconName: String {
        if checker.hasRecentPassingCheck { return "checkmark.shield.fill" }
        if checker.result.status == .needsAttention { return "exclamationmark.shield.fill" }
        return "shield.lefthalf.filled"
    }

    private var iconColor: Color {
        if checker.hasRecentPassingCheck { return Color.arkPrimaryHover }
        if checker.result.status == .needsAttention { return Color.arkAccentSecondary }
        return Color.arkPrimary
    }

    private var primaryButtonTitle: String {
        checker.hasRecentPassingCheck ? "View Readiness Details" : "Run Offline Check"
    }

    private var reminderSummary: String {
        switch reminder.deliveryState {
        case .active:
            "21-day readiness reminder scheduled"
        case .limited:
            "Reminder scheduled with quiet or delayed delivery"
        case .denied:
            "Reminder permission is off"
        case .schedulingFailed:
            "Reminder needs attention"
        case .off:
            "Readiness reminder is off"
        }
    }

    private var reminderIcon: String {
        switch reminder.deliveryState {
        case .active: "bell.fill"
        case .limited: "bell.badge"
        case .denied, .schedulingFailed: "bell.slash"
        case .off: "bell"
        }
    }
}

struct ArkFileOfflineReadinessView: View {
    @ObservedObject private var checker = ArkFileOfflineReadinessChecker.shared
    @ObservedObject private var reminder = ArkFileOfflineReadinessReminder.shared
    @Environment(\.openURL) private var openURL

    let autoRunQuickCheck: Bool
    let presentationRequestID: UUID?
    @State private var showFullCheckConfirmation = false
    @State private var didHandleAutoRun = false

    init(autoRunQuickCheck: Bool, presentationRequestID: UUID? = nil) {
        self.autoRunQuickCheck = autoRunQuickCheck
        self.presentationRequestID = presentationRequestID
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section {
                statusHeader
                if checker.isRunning {
                    checkProgress
                }
                checkActions
            } header: {
                Text("This device")
            } footer: {
                Text("Quick and full checks use only files already on this device. They do not contact ArkFile or require internet access.")
            }

            if !checker.result.issues.isEmpty {
                Section("Findings") {
                    ForEach(checker.result.issues) { issue in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.title).fontWeight(.semibold)
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: issue.severity == .failure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(issue.severity == .failure ? Color.orange : Color.arkPrimary)
                        }
                    }
                }
            }

            Section {
                if let available = checker.result.availableStorageBytes {
                    LabeledContent(
                        "Available on this device",
                        value: ArkFileOfflineReadinessChecker.formattedBytes(available)
                    )
                } else {
                    Text("Run an offline check to refresh available storage.")
                        .foregroundStyle(.secondary)
                }
                if let headroom = checker.result.recommendedHeadroomBytes {
                    LabeledContent(
                        "ArkFile guideline",
                        value: ArkFileOfflineReadinessChecker.formattedBytes(headroom)
                    )
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Low storage increases offload pressure. Apple does not publish a free-space amount that guarantees an app will remain installed.")
            }

            Section {
                Label(reminderStatusTitle, systemImage: reminderStatusIcon)
                    .foregroundStyle(reminderStatusColor)
                if let nextReminderAt = reminder.nextReminderAt {
                    LabeledContent(
                        "Next reminder (approx.)",
                        value: Self.dateFormatter.string(from: nextReminderAt)
                    )
                }
                if let message = reminder.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if reminder.intentEnabled {
                    Button("Turn Off Reminder", role: .destructive) {
                        reminder.turnOffReminder()
                    }
                } else {
                    Button("Enable Readiness Reminder") {
                        Task { await reminder.enableReminder() }
                    }
                }
                if reminder.deliveryState == .denied || reminder.deliveryState == .schedulingFailed {
                    Button("Open ArkFile Notification Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
            } header: {
                Text("21-Day Reminder")
            } footer: {
                Text("Reminders reduce the chance of forgetting to check ArkFile, but cannot prevent the system from offloading apps. Focus and Notification Summary may delay delivery.")
            }

            Section("Highest Reliability") {
                guidanceRow(
                    number: 1,
                    title: "Turn off automatic app offloading",
                    detail: "On current iOS and iPadOS versions: Settings → Apps → App Store → Offload Unused Apps. On older versions, look in Settings → App Store or \(ArkFileDeviceCopy.currentStorageSettingsPath). This affects every app, and ArkFile cannot verify the setting."
                )
                guidanceRow(
                    number: 2,
                    title: "Avoid accidental deletion",
                    detail: "For maximum protection, Screen Time → Content & Privacy Restrictions → iTunes & App Store Purchases can restrict deleting apps. This affects every app."
                )
                guidanceRow(
                    number: 3,
                    title: "Check after major changes",
                    detail: "Run this check after a system update, ArkFile content change, device migration, or restore. Downloaded packs are intentionally excluded from device backups and may need to be downloaded again on a new device."
                )
                Link(
                    "Read Apple's device storage guidance",
                    destination: URL(
                        string: "https://support.apple.com/108429"
                    )!
                )
            }
        }
        .navigationTitle("Offline Readiness")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let presentationRequestID {
                ArkFileOfflineReadinessCoordinator.shared.consume(presentationRequestID)
            }
            await checker.refreshCachedState()
            await reminder.refreshStatus()
            guard autoRunQuickCheck, !didHandleAutoRun else { return }
            didHandleAutoRun = true
            checker.startQuickCheck()
        }
        .onChange(of: checker.isRunning) { _, isRunning in
            UIApplication.shared.isIdleTimerDisabled = isRunning && checker.runningLevel == .full
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .confirmationDialog(
            "Run a full integrity check?",
            isPresented: $showFullCheckConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Full Check") {
                checker.startFullCheck()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ArkFile will read and verify every selected file. Large Complete libraries can take a long time; keep ArkFile open and the device powered. Locking the device may pause the check.")
        }
    }

    private var statusHeader: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let checkedAt = checker.result.checkedAt {
                    Text("Checked \(Self.dateFormatter.string(from: checkedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
        }
    }

    private var checkProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: checker.progressFraction)
            if !checker.currentFile.isEmpty {
                Text(checker.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button("Cancel Check", role: .destructive) {
                checker.cancelCurrentCheck()
            }
        }
    }

    private var checkActions: some View {
        VStack(spacing: 10) {
            Button {
                checker.startQuickCheck()
            } label: {
                Label("Run Quick Offline Check", systemImage: "bolt.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checker.isRunning)

            Button {
                showFullCheckConfirmation = true
            } label: {
                Label("Full Integrity Check", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(checker.isRunning)
        }
        .padding(.vertical, 4)
    }

    private func guidanceRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.arkPrimary.opacity(0.14))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusTitle: String {
        switch checker.result.status {
        case .ready: "Saved Content Opens Offline"
        case .needsAttention: "Offline Readiness Needs Attention"
        case .checking: "Checking Saved Content"
        case .noManagedContent: "No Managed Offline Content"
        case .unavailable: "Verification Is Unavailable"
        case .cancelled: "Check Cancelled"
        case .checkDue: "Offline Check Due"
        }
    }

    private var statusDetail: String {
        switch checker.result.status {
        case .ready:
            "ArkFile found every selected file at the expected size and opened a representative offline library."
        case .needsAttention:
            "Review the findings and repair content before relying on this device during an outage."
        case .checking:
            "This check is local and does not use the internet."
        case .noManagedContent:
            "Install selected ArkFile content before running readiness checks."
        case .unavailable:
            "Repair or reinstall older content to restore its verification manifest."
        case .cancelled:
            "The prior passing result was not replaced."
        case .checkDue:
            "Run a quick check to confirm your saved content still opens offline."
        }
    }

    private var statusIcon: String {
        switch checker.result.status {
        case .ready: "checkmark.shield.fill"
        case .needsAttention: "exclamationmark.shield.fill"
        case .checking: "shield.lefthalf.filled"
        case .noManagedContent, .unavailable, .cancelled, .checkDue: "shield"
        }
    }

    private var statusColor: Color {
        checker.result.status == .ready ? Color.arkPrimaryHover
            : checker.result.status == .needsAttention ? .orange
            : Color.arkPrimary
    }

    private var reminderStatusTitle: String {
        switch reminder.deliveryState {
        case .active: "Reminder scheduled"
        case .limited: "Reminder may be quiet or delayed"
        case .denied: "Notification permission is off"
        case .schedulingFailed: "Reminder could not be scheduled"
        case .off: "Reminder is off"
        }
    }

    private var reminderStatusIcon: String {
        switch reminder.deliveryState {
        case .active: "bell.fill"
        case .limited: "bell.badge"
        case .denied, .schedulingFailed: "bell.slash.fill"
        case .off: "bell"
        }
    }

    private var reminderStatusColor: Color {
        switch reminder.deliveryState {
        case .active: Color.arkPrimaryHover
        case .limited: Color.arkPrimary
        case .denied, .schedulingFailed: .orange
        case .off: .secondary
        }
    }
}
#endif
