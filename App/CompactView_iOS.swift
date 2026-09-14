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
import CoreData

struct CompactView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @Environment(\.dismissSearch) private var dismissSearch
    @ObservedObject private var searchViewModel = SearchViewModel.shared
    @State private var showsGlobalSearch = true
    private let openURL = NotificationCenter.default.publisher(for: .openURL)
    
    var body: some View {
        if case .loading = navigation.currentItem {
            LoadingDataView()
                .task { [weak navigation] in
                    navigation?.observeOpeningFiles()
                }
        } else if case let .tab(tabID) = navigation.currentItem {
            NavigationStack {
                SearchableContent(tabID: tabID)
                    .environmentObject(searchViewModel)
                    .modifier(GlobalSearchModifier(
                        isVisible: showsGlobalSearch,
                        searchText: $searchViewModel.searchText
                    ))
                    .onPreferenceChange(GlobalSearchVisibilityPreferenceKey.self) { isVisible in
                        showsGlobalSearch = isVisible
                        if !isVisible {
                            searchViewModel.searchText = ""
                            dismissSearch()
                        }
                    }
            }
            .onReceive(openURL) { _ in
                dismissSearch()
            }
        }
    }
}

private struct SearchableContent: View {
    @EnvironmentObject private var searchViewModel: SearchViewModel
    @Environment(\.isSearching) private var isSearching
    let tabID: NSManagedObjectID
    
    var body: some View {
        CompactTabView(tabID: tabID)
            .overlay {
                if isSearching {
                    SearchResults()
                        .environmentObject(searchViewModel)
                }
            }
    }
}

struct GlobalSearchVisibilityPreferenceKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

private struct GlobalSearchModifier: ViewModifier {
    let isVisible: Bool
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if isVisible {
            content.searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: LocalString.common_search
            )
        } else {
            content
        }
    }
}

#endif
