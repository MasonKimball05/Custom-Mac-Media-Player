import SwiftUI

/// The sidebar: the local playlist, or the desktop media library.
struct SidebarContainerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var showingHomeScreen: Bool
    let onOpenFile: () -> Void

    private enum Tab: String { case playlist, library }
    @AppStorage("sidebarTab") private var tab: Tab = .playlist

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                Text("Playlist").tag(Tab.playlist)
                Text("Library").tag(Tab.library)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)

            switch tab {
            case .playlist:
                PlaylistSidebarView(viewModel: viewModel, showingHomeScreen: $showingHomeScreen, onOpenFile: onOpenFile)
            case .library:
                LibrarySidebarView(viewModel: viewModel, showingHomeScreen: $showingHomeScreen)
            }
        }
    }
}
