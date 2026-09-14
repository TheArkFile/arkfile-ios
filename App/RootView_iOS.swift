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
import CoreData
import SwiftUI

@MainActor
struct RootViewiOS: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @StateObject private var adaptiveNavigation = ArkFileAdaptiveNavigationState()

    var body: some View {
        SplitViewForiPad(adaptiveNavigation: adaptiveNavigation)
            .onReceive(adaptiveDestinationNotifications) { notification in
                guard let intent = ArkFileAdaptiveNotificationRoutePolicy.intent(
                    for: notification,
                    device: Device.current
                ) else {
                    return
                }
                adaptiveNavigation.handle(intent)
            }
            .onReceive(historyNavigationNotifications) { notification in
                handleHistoryNavigation(notification)
            }
            .onReceive(navigation.missingTabsDeleted) { objectIDs in
                adaptiveNavigation.removeDeletedReaders(with: objectIDs)
            }
    }

    private var adaptiveDestinationNotifications: AnyPublisher<Notification, Never> {
        let names: [Notification.Name] = [
            .arkFileGoHome,
            .openURL,
            .arkFileOpenLibraryItem,
            .selectFile,
            .arkFileOpenContentDownloads,
            .arkFileOpenMapLocation,
            .arkFileImportMapGPX,
            .arkFileOpenGuideSection,
            .arkFileOpenToolkitView,
            .navigateToHotspotSettings,
            .arkFileOnboardingDestination
        ]
        return Publishers.MergeMany(
            names
                .filter {
                    ArkFileAdaptiveNotificationRoutePolicy.rootHandles(
                        $0,
                        device: Device.current
                    )
                }
                .map { NotificationCenter.default.publisher(for: $0) }
        )
        .eraseToAnyPublisher()
    }

    private var historyNavigationNotifications: AnyPublisher<Notification, Never> {
        Publishers.MergeMany(
            [
                .goBack,
                .goForward
            ].map { NotificationCenter.default.publisher(for: $0) }
        )
        .eraseToAnyPublisher()
    }

    private func handleHistoryNavigation(_ notification: Notification) {
        guard let browser = activeHistoryBrowser() else {
            return
        }
        switch notification.name {
        case .goBack:
            browser.goBack()
        case .goForward:
            browser.goForward()
        default:
            break
        }
    }

    private func activeHistoryBrowser() -> BrowserViewModel? {
        let currentTabID: NSManagedObjectID?
        if case .tab(let objectID) = navigation.currentItem {
            currentTabID = objectID
        } else {
            currentTabID = nil
        }

        guard let target = ArkFileAdaptiveHistoryTargetPolicy.target(
            device: Device.current,
            route: adaptiveNavigation.route,
            hasCurrentNavigationReader: currentTabID != nil
        ) else {
            return nil
        }

        let tabID: NSManagedObjectID?
        switch target {
        case .currentNavigationReader:
            tabID = currentTabID
        case .adaptiveReader(let identity):
            tabID = Database.shared.viewContext
                .persistentStoreCoordinator?
                .managedObjectID(
                    forURIRepresentation: identity.objectURI
                )
        }

        guard let tabID else {
            return nil
        }
        return BrowserViewModel.getCached(tabID: tabID)
    }
}

#endif
