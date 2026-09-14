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
import Combine
import Foundation

@MainActor
final class ArkFileOfflineReadinessCoordinator: ObservableObject {
    struct PresentationRequest: Identifiable, Equatable {
        let id = UUID()
        let autoRunQuickCheck: Bool
    }

    static let shared = ArkFileOfflineReadinessCoordinator()

    @Published private(set) var presentationRequest: PresentationRequest?

    func requestFromReminderNotification() {
        presentationRequest = PresentationRequest(
            autoRunQuickCheck: true
        )
    }

    func consume(_ id: UUID) {
        guard presentationRequest?.id == id else { return }
        presentationRequest = nil
    }
}
#endif
