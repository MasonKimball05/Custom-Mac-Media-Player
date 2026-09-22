import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var showSidebar = true
    @State private var isFullscreen = false
    @State private var window: NSWindow?
    @State private var showingNetworkStreamSheet = false
    @State private var showingMediaInfoSheet = false

    var body: some View {
        HSplitView {
            if showSidebar {
                PlaylistSidebarView(viewModel: viewModel, onOpenFile: openFilePanel)
                    .transition(.move(edge: .leading))
            }

            PlayerContainerView(
                viewModel: viewModel,
                isFullscreen: $isFullscreen,
                onToggleFullscreen: toggleFullscreen
            )
            .frame(minWidth: 480, minHeight: 300)
        }
        .background(WindowAccessor { resolvedWindow in
            window = resolvedWindow
            observeFullscreen(resolvedWindow)
        })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle Playlist")
            }
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            viewModel.skip(by: -5)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            viewModel.skip(by: 5)
            return .handled
        }
        .onOpenFile { url in
            viewModel.addFiles([url])
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMediaFile)) { _ in
            openFilePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNetworkStream)) { _ in
            showingNetworkStreamSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMediaInfo)) { _ in
            showingMediaInfoSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSnapshot)) { _ in
            saveSnapshotPanel()
        }
        .sheet(isPresented: $showingNetworkStreamSheet) {
            OpenNetworkStreamView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingMediaInfoSheet) {
            MediaInfoView(viewModel: viewModel)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .video, .mpeg4Movie, .quickTimeMovie, .mp3, .audiovisualContent]
        panel.begin { response in
            if response == .OK {
                viewModel.addFiles(panel.urls)
            }
        }
    }

    private func saveSnapshotPanel() {
        guard viewModel.currentItem != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(viewModel.currentItem?.title ?? "Snapshot").png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await viewModel.saveSnapshot(to: url) }
        }
    }

    private func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func observeFullscreen(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { _ in isFullscreen = true }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { _ in isFullscreen = false }
    }
}

extension Notification.Name {
    static let openMediaFile = Notification.Name("openMediaFile")
    static let openNetworkStream = Notification.Name("openNetworkStream")
    static let showMediaInfo = Notification.Name("showMediaInfo")
    static let saveSnapshot = Notification.Name("saveSnapshot")
}

private struct OnOpenFileModifier: ViewModifier {
    let action: (URL) -> Void
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .openMediaFileURL)) { note in
            if let url = note.object as? URL {
                action(url)
            }
        }
    }
}

extension Notification.Name {
    static let openMediaFileURL = Notification.Name("openMediaFileURL")
}

extension View {
    func onOpenFile(perform action: @escaping (URL) -> Void) -> some View {
        modifier(OnOpenFileModifier(action: action))
    }
}
