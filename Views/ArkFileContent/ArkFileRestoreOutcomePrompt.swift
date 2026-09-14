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

#if os(iOS)
import SwiftUI

struct ArkFileRestoreOutcomePresentation: Equatable {
    let title: String
    let message: String
    let primaryActionTitle: String?
}

enum ArkFileRestoreOutcomeCopy {
    static func presentation(
        outcome: ArkFileContentRestoreOutcome?,
        failureMessage: String?,
        failureAction: ArkFileContentEntitlementOutcomeAction?,
        successActionTitle: String
    ) -> ArkFileRestoreOutcomePresentation {
        if failureAction == .pendingApproval {
            return ArkFileRestoreOutcomePresentation(
                title: "Purchase Pending",
                message: "Apple is waiting for approval. You don’t need to buy again. ArkFile will update after Apple approves it.",
                primaryActionTitle: nil
            )
        }

        if failureMessage != nil,
           let outcome,
           outcome.action == .restored,
           outcome.requestedTier == .complete,
           outcome.tier != .complete {
            return ArkFileRestoreOutcomePresentation(
                title: "Complete Was Not Restored",
                message: "Essentials is still available. Complete remains locked.",
                primaryActionTitle: "Review Upgrade Price"
            )
        }

        if failureMessage != nil, let outcome {
            let packName = ArkFileContentPackDisplayName.name(for: outcome.tier)
            let title = switch outcome.action {
            case .restored:
                "Access Restored"
            case .purchased:
                "Purchase Confirmed"
            case .accessConfirmed:
                "Access Confirmed"
            case .pendingApproval:
                "Purchase Pending"
            }
            return ArkFileRestoreOutcomePresentation(
                title: title,
                message: "\(packName) access is confirmed. Downloads are temporarily unavailable. Try again when ready.",
                primaryActionTitle: successActionTitle
            )
        }

        if let failureMessage {
            let title = failureAction == .restored ? "Restore Didn’t Finish" : "Try Again"
            return ArkFileRestoreOutcomePresentation(
                title: title,
                message: "\(failureMessage) No download started.",
                primaryActionTitle: nil
            )
        }

        guard let outcome else {
            return ArkFileRestoreOutcomePresentation(
                title: "Pack Access Updated",
                message: "Pack access updated.",
                primaryActionTitle: nil
            )
        }
        let packName = ArkFileContentPackDisplayName.name(for: outcome.tier)
        let title = switch outcome.action {
        case .restored:
            "\(packName) Restored"
        case .purchased:
            "\(packName) Purchase Confirmed"
        case .accessConfirmed:
            "\(packName) Access Confirmed"
        case .pendingApproval:
            "Purchase Pending"
        }
        return ArkFileRestoreOutcomePresentation(
            title: title,
            message: "\(outcome.statusMessage) \(successActionTitle) now or later.",
            primaryActionTitle: successActionTitle
        )
    }
}

private struct ArkFileRestoreOutcomePromptModifier: ViewModifier {
    @ObservedObject var installer: ArkFileContentPackInstaller
    @Binding var isAwaitingOutcome: Bool
    let chooseDownloads: (ArkFileContentRestoreOutcome) -> Void
    let successActionTitle: String
    let cancel: () -> Void

    private var presentation: ArkFileRestoreOutcomePresentation {
        ArkFileRestoreOutcomeCopy.presentation(
            outcome: installer.restoreOutcome,
            failureMessage: installer.entitlementFailureMessage,
            failureAction: installer.entitlementFailureAction,
            successActionTitle: successActionTitle
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            presentation.title,
            isPresented: Binding(
                get: {
                    isAwaitingOutcome
                        && (
                            installer.restoreOutcome != nil
                                || installer.entitlementFailureMessage != nil
                        )
                },
                set: { isPresented in
                    if !isPresented {
                        dismiss()
                    }
                }
            )
        ) {
            if let outcome = installer.restoreOutcome {
                Button(presentation.primaryActionTitle ?? successActionTitle) {
                    dismiss()
                    chooseDownloads(outcome)
                }
                .accessibilityIdentifier("arkfile_restore_choose_downloads")
                Button("Not Now", role: .cancel) {
                    dismiss()
                    cancel()
                }
            } else {
                Button("OK", role: .cancel) {
                    dismiss()
                    cancel()
                }
            }
        } message: {
            Text(presentation.message)
        }
        .onChange(of: installer.purchaseHelpMessage) { _, message in
            if message != nil, installer.restoreOutcome == nil {
                isAwaitingOutcome = false
                cancel()
            }
        }
        .onChange(of: installer.downloadFailureMessage) { _, message in
            if message != nil, installer.restoreOutcome == nil {
                isAwaitingOutcome = false
                cancel()
            }
        }
    }

    private func dismiss() {
        isAwaitingOutcome = false
        installer.dismissRestoreOutcome()
        installer.dismissEntitlementFailure()
    }
}

extension View {
    func arkFileRestoreOutcomePrompt(
        installer: ArkFileContentPackInstaller,
        isAwaitingOutcome: Binding<Bool>,
        chooseDownloads: @escaping (ArkFileContentRestoreOutcome) -> Void,
        successActionTitle: String = "Choose Downloads",
        cancel: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            ArkFileRestoreOutcomePromptModifier(
                installer: installer,
                isAwaitingOutcome: isAwaitingOutcome,
                chooseDownloads: chooseDownloads,
                successActionTitle: successActionTitle,
                cancel: cancel
            )
        )
    }
}
#endif
