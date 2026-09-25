import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showSidebar = true
    @State private var isFullscreen = false
    @State private var window: NSWindow?
    @State private var showingNetworkStreamSheet = false
    @State private var showingMediaInfoSheet = false
    @State private var showingDownloadSheet = false
    /// Owned here (not by PlayerContainerView) because hiding the window's toolbar —
    /// which is where the sidebar toggle lives — needs to react to it too.
    @State private var controlsVisible = true
    @State private var showingHomeScreen = false

    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval
    @AppStorage(AppSettingsKeys.floatOnTop) private var floatOnTop = AppSettingsDefaults.floatOnTop
    @AppStorage(AppSettingsKeys.autoDoNotDisturb) private var autoDoNotDisturb = AppSettingsDefaults.autoDoNotDisturb
    @AppStorage(AppSettingsKeys.focusOnShortcutName) private var focusOnShortcutName = AppSettingsDefaults.focusOnShortcutName
    @AppStorage(AppSettingsKeys.focusOffShortcutName) private var focusOffShortcutName = AppSettingsDefaults.focusOffShortcutName
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
                PlaylistSidebarView(viewModel: viewModel, showingHomeScreen: $showingHomeScreen, onOpenFile: openFilePanel)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                SidebarResizeHandle(width: $sidebarWidth, range: sidebarWidthRange)
            }

            PlayerContainerView(
                viewModel: viewModel,
                isFullscreen: $isFullscreen,
                controlsVisible: $controlsVisible,
                showingHomeScreen: $showingHomeScreen,
                onToggleFullscreen: toggleFullscreen
            )
            .frame(minWidth: 480, minHeight: 300)
            .layoutPriority(1)
        }
        .background(WindowAccessor { resolvedWindow in
            window = resolvedWindow
            resolvedWindow.level = floatOnTop ? .floating : .normal
            // AppKit gives a new window's first text field (the playlist filter) keyboard
            // focus, which swallowed Space, C, and the other single-key shortcuts until
            // something else was clicked. Nothing should have focus until it's clicked.
            DispatchQueue.main.async {
                resolvedWindow.makeFirstResponder(nil)
            }
            observeFullscreen(resolvedWindow)
        })
        .onChange(of: floatOnTop) { _, newValue in
            window?.level = newValue ? .floating : .normal
        }
        .onChange(of: isFullscreen) { _, enteredFullscreen in
            guard autoDoNotDisturb else { return }
            runFocusShortcut(named: enteredFullscreen ? focusOnShortcutName : focusOffShortcutName)
        }
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
            ToolbarItem(placement: .navigation) {
                Button {
                    showingHomeScreen = true
                } label: {
                    Image(systemName: "house")
                }
                .help("Home")
                .disabled(viewModel.currentItem == nil)
            }
            if !downloads.jobs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    DownloadsButton(downloads: downloads, onPlay: viewModel.playFile)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    floatOnTop.toggle()
                } label: {
                    Image(systemName: floatOnTop ? "pin.fill" : "pin")
                }
                .help(floatOnTop ? "Turn Off Float on Top" : "Float on Top")
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
        .onReceive(NotificationCenter.default.publisher(for: .openMediaFolder)) { _ in
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNetworkStream)) { _ in
            showingNetworkStreamSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadFromURL)) { _ in
            showingDownloadSheet = true
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
        .sheet(isPresented: $showingDownloadSheet) {
            DownloadFromURLView(downloads: downloads)
        }
        .frame(minWidth: 720, minHeight: 420)
        // SwiftUI's .onKeyPress only fires on a *focused* view, and getting a plain
        // container view reliably focused (and staying that way across sheets, the video
        // surface, etc.) turned out not to work here in practice — the handlers just never
        // fired. An NSEvent local monitor is the standard fallback for exactly this: it
        // sees every key event in the app regardless of SwiftUI's focus state, so it isn't
        // subject to the same problem.
        .onAppear {
            downloads.onAddToPlaylist = { viewModel.enqueueFiles([$0]) }
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleGlobalKeyEvent(event) ? nil : event
            }
            // Best-effort: if the app quits while still fullscreen (Cmd+Q rather than
            // leaving fullscreen first), there's no isFullscreen transition to turn
            // Focus back off on — this catches that instead of leaving it stuck on.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                if autoDoNotDisturb, isFullscreen {
                    runFocusShortcut(named: focusOffShortcutName)
                }
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

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK else { return }
            let files = panel.urls.flatMap(playableFiles(in:))
            if !files.isEmpty {
                viewModel.addFiles(files)
            }
        }
    }

    /// Recursively walks a folder for anything `MediaFormat` recognizes, in a stable
    /// (filename-sorted) order — folders can come back from the OS in an arbitrary order,
    /// and "the order I added them" matters for a playlist.
    private func playableFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator where MediaFormat.isSupportedFile(url) {
            results.append(url)
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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

    /// macOS gives apps no public API to toggle system Focus/Do Not Disturb directly —
    /// this is the standard workaround, running a user-created Shortcuts.app shortcut
    /// (containing a "Set Focus" action) by name via its URL scheme. Fire-and-forget:
    /// there's no completion callback, and a missing/misnamed shortcut just does nothing
    /// rather than erroring, since Shortcuts itself handles the "no such shortcut" case.
    private func runFocusShortcut(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
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

        let bindings = KeyBindingStore.currentBindings()
        let key = characters.lowercased()

        guard viewModel.currentItem != nil else {
            if key == bindings[.toggleFullscreen] {
                toggleFullscreen()
                return true
            }
            return false
        }

        if key == bindings[.playPause] { viewModel.togglePlayPause(); return true }
        if key == bindings[.skipBackward] { viewModel.skip(by: -skipInterval); return true }
        if key == bindings[.skipForward] { viewModel.skip(by: skipInterval); return true }
        if key == bindings[.mute] { viewModel.isMuted.toggle(); return true }
        if key == bindings[.toggleFullscreen] { toggleFullscreen(); return true }
        if key == bindings[.toggleCaptions] { viewModel.toggleSubtitles(); return true }
        if key == bindings[.frameBack] { viewModel.stepFrame(forward: false); return true }
        if key == bindings[.frameForward] { viewModel.stepFrame(forward: true); return true }

        switch key {
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
        let speeds = PlaybackSpeed.presets
        let currentIndex = speeds.firstIndex(of: viewModel.playbackRate) ?? speeds.firstIndex(of: 1.0) ?? 0
        let newIndex = min(max(currentIndex + steps, 0), speeds.count - 1)
        viewModel.playbackRate = speeds[newIndex]
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
    static let openMediaFolder = Notification.Name("openMediaFolder")
    static let openNetworkStream = Notification.Name("openNetworkStream")
    static let downloadFromURL = Notification.Name("downloadFromURL")
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
