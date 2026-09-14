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

enum ArkFileLockedContentPromptPresentation {
    static func showsRestoreAction(
        presentationShowsRestore: Bool
    ) -> Bool {
        presentationShowsRestore
    }
}

struct ArkFileLockedContentPromptModifier: ViewModifier {
    @Binding var item: ArkFileLibraryContentItem?
    let resolutionInput: () -> ArkFileLockedContentResolutionInput
    let primaryAction: (ArkFileLibraryContentItem, ArkFileContentTier) -> Void
    let restoreAction: (ArkFileLockedContentRestoreRoute) -> Void
    let downloadOnlyAction: (ArkFileLibraryContentItem, ArkFileContentTier) -> Void

    func body(content: Content) -> some View {
        content.alert(
            alertTitle,
            isPresented: Binding(
                get: { item != nil },
                set: { if !$0 { item = nil } }
            )
        ) {
            if let item {
                let input = resolutionInput()
                let presentation = ArkFileLockedContentPresentation.resolve(
                    item: item,
                    input: input
                )
                if presentation.canDownloadOnlyThisTitle {
                    Button("Download This Title") {
                        downloadOnlyAction(item, presentation.resolvedTier)
                    }
                } else {
                    Button(presentation.primaryActionTitle) {
                        if let restoreRoute = presentation.primaryRestoreRoute {
                            restoreAction(restoreRoute)
                        } else {
                            primaryAction(item, presentation.resolvedTier)
                        }
                    }
                    .disabled(!presentation.isPrimaryActionEnabled)
                    if ArkFileLockedContentPromptPresentation.showsRestoreAction(
                        presentationShowsRestore: presentation.isRestoreAvailable
                    ) {
                        Button(presentation.restoreActionTitle) {
                            restoreAction(.restore(presentation.resolvedTier))
                        }
                        .disabled(!presentation.isRestoreActionEnabled)
                    }
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var alertTitle: String {
        guard let item else { return "Essentials Content" }
        let presentation = ArkFileLockedContentPresentation.resolve(
            item: item,
            input: resolutionInput()
        )
        return "\(presentation.packName) Content"
    }

    private var alertMessage: String {
        guard let item else { return "" }
        let presentation = ArkFileLockedContentPresentation.resolve(
            item: item,
            input: resolutionInput()
        )
        return presentation.message
    }
}

extension View {
    func arkFileLockedContentPrompt(
        item: Binding<ArkFileLibraryContentItem?>,
        resolutionInput: @escaping () -> ArkFileLockedContentResolutionInput,
        primaryAction: @escaping (ArkFileLibraryContentItem, ArkFileContentTier) -> Void,
        restoreAction: @escaping (ArkFileLockedContentRestoreRoute) -> Void,
        downloadOnlyAction: @escaping (ArkFileLibraryContentItem, ArkFileContentTier) -> Void
    ) -> some View {
        modifier(ArkFileLockedContentPromptModifier(
            item: item,
            resolutionInput: resolutionInput,
            primaryAction: primaryAction,
            restoreAction: restoreAction,
            downloadOnlyAction: downloadOnlyAction
        ))
    }
}
#endif
