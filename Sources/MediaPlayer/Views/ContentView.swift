import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var showSidebar = true
    @State private var isFullscreen = false
    @State private var window: NSWindow?
    @State private var showingNetworkStreamSheet = false
    @State private var showingMediaInfoSheet = false
    /// Owned here (not by PlayerContainerView) because hiding the window's toolbar —
    /// which is where the sidebar toggle lives — needs to react to it too.
    @State private var controlsVisible = true

    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval
    // A fixed-width sidebar + our own drag handle, rather than HSplitView: NSSplitView
    // grows panes proportionally when the window resizes, so entering fullscreen (a huge
    // width jump) blew the sidebar up along with it. A fixed width sidesteps that
    // entirely, and — as a bound @AppStorage value — persists across resizes and launches
    // the same way playback position already does.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 240
    private let sidebarWidthRange: ClosedRange<CGFloat> = 180...420

    @State private var keyEventMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                PlaylistSidebarView(viewModel: viewModel, onOpenFile: openFilePanel)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                SidebarResizeHandle(width: $sidebarWidth, range: sidebarWidthRange)
            }

            PlayerContainerView(
                viewModel: viewModel,
                isFullscreen: $isFullscreen,
                controlsVisible: $controlsVisible,
                onToggleFullscreen: toggleFullscreen
            )
            .frame(minWidth: 480, minHeight: 300)
            .layoutPriority(1)
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
        // In fullscreen, the toolbar (and the sidebar button in it) floats over the
        // video like our own controls do, so it should hide alongside them. In a
        // normal window it always stays visible — that's the only way to reach it.
        .toolbar(isFullscreen && !controlsVisible ? .hidden : .visible, for: .windowToolbar)
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
        // SwiftUI's .onKeyPress only fires on a *focused* view, and getting a plain
        // container view reliably focused (and staying that way across sheets, the video
        // surface, etc.) turned out not to work here in practice — the handlers just never
        // fired. An NSEvent local monitor is the standard fallback for exactly this: it
        // sees every key event in the app regardless of SwiftUI's focus state, so it isn't
        // subject to the same problem.
        .onAppear {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleGlobalKeyEvent(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyEventMonitor {
                NSEvent.removeMonitor(keyEventMonitor)
            }
        }
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

    /// YouTube-style single-key shortcuts, handled at the AppKit level (see the comment
    /// on the NSEvent monitor setup above for why). Not shown in any menu — like the
    /// arrow-key nudge, these are just a known convention, not something to advertise in
    /// a menu bar. Returns whether the event was consumed.
    private func handleGlobalKeyEvent(_ event: NSEvent) -> Bool {
        // Don't hijack typing in text fields — Save Playlist As, Open Network Stream,
        // Settings, etc. SwiftUI TextFields on macOS are backed by an NSTextView while
        // being edited, so this is a reliable way to detect "something is expecting text".
        if event.window?.firstResponder is NSTextView {
            return false
        }

        let modifiers = event.modifierFlags
        let characters = event.charactersIgnoringModifiers ?? ""

        // Shift+,/Shift+. produce "<"/">" directly, so no separate modifier check needed.
        switch characters {
        case "<": adjustPlaybackSpeed(by: -1); return true
        case ">": adjustPlaybackSpeed(by: 1); return true
        default: break
        }

        // Everything below is plain-key-only — deliberately excludes Cmd/Ctrl/Option so
        // this never shadows a system or app menu shortcut that happens to share a letter.
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }

        switch event.keyCode {
        case 123: viewModel.skip(by: -5); return true // left arrow
        case 124: viewModel.skip(by: 5); return true // right arrow
        case 126: viewModel.volume = min(1, viewModel.volume + 0.05); return true // up arrow
        case 125: viewModel.volume = max(0, viewModel.volume - 0.05); return true // down arrow
        case 115: viewModel.seek(to: 0); return true // Home
        case 119: viewModel.seek(to: viewModel.duration); return true // End
        default: break
        }

        guard viewModel.currentItem != nil else {
            if characters.lowercased() == "f" {
                toggleFullscreen()
                return true
            }
            return false
        }

        switch characters.lowercased() {
        case "k": viewModel.togglePlayPause(); return true
        case "j": viewModel.skip(by: -skipInterval); return true
        case "l": viewModel.skip(by: skipInterval); return true
        case "m": viewModel.isMuted.toggle(); return true
        case "f": toggleFullscreen(); return true
        case "c": toggleCaptions(); return true
        case ",": viewModel.stepFrame(forward: false); return true
        case ".": viewModel.stepFrame(forward: true); return true
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let tenth = Int(characters), viewModel.duration > 0 {
                viewModel.seek(to: Double(tenth) / 10 * viewModel.duration)
            }
            return true
        default:
            return false
        }
    }

    private func adjustPlaybackSpeed(by steps: Int) {
        guard viewModel.currentItem != nil else { return }
        let speeds = PlaybackSpeedMenu.speeds
        let currentIndex = speeds.firstIndex(of: viewModel.playbackRate) ?? speeds.firstIndex(of: 1.0) ?? 0
        let newIndex = min(max(currentIndex + steps, 0), speeds.count - 1)
        viewModel.playbackRate = speeds[newIndex]
    }

    private func toggleCaptions() {
        let tracks = viewModel.availableSubtitleTracks()
        if tracks.contains(where: \.isSelected) {
            viewModel.selectSubtitleTrack(id: nil)
        } else if let first = tracks.first {
            viewModel.selectSubtitleTrack(id: first.id)
        }
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

/// A thin draggable strip between the sidebar and the video area. Standing in for
/// HSplitView's divider since we dropped it (see the comment on `sidebarWidth`) —
/// this one only ever changes `width`, so proportional resize-on-window-grow can't happen.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<CGFloat>

    @State private var isHovering = false
    @State private var widthAtDragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isHovering ? 0.15 : 0.0001)) // ~invisible but still hit-testable at rest
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = widthAtDragStart ?? width
                        widthAtDragStart = base
                        width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                    }
            )
    }
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
