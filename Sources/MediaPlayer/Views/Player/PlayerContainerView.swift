import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main stage: video surface + auto-hiding custom chrome on top of it.
/// Handles drag & drop of media files, click-to-toggle-play, and hover-driven
/// visibility of the transport bar so video can breathe full-bleed.
struct PlayerContainerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isFullscreen: Bool
    /// Owned by ContentView so it can also hide the window toolbar (sidebar button)
    /// in fullscreen when this goes false, not just our own overlay controls.
    @Binding var controlsVisible: Bool
    /// Owned by ContentView so its toolbar Home button can open this screen on top of
    /// whatever's playing, not just when the queue happens to be empty.
    @Binding var showingHomeScreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isDropTargeted = false

    @AppStorage(AppSettingsKeys.autoHideControlsDelay) private var autoHideDelay = AppSettingsDefaults.autoHideControlsDelay

    var body: some View {
        ZStack {
            // Click-to-play and double-click-to-fullscreen are scoped to just this
            // background/video group, not the whole stage — PlaybackControlsBar (added
            // below, as a separate sibling) is deliberately NOT a descendant of these
            // gestures, so a click landing on one of its buttons or a menu item can never
            // race with "toggle play/pause" for the same click the way it could when both
            // lived under one shared .onTapGesture on the entire ZStack.
            Group {
                Color.black

                if viewModel.currentItem != nil {
                    if viewModel.usesMPVEngine {
                        MPVVideoView(engine: viewModel.mpvEngine)
                            .opacity(viewModel.isVideoTrackPresent ? 1 : 0)
                    } else {
                        VideoLayerView(player: viewModel.player)
                            .opacity(viewModel.isVideoTrackPresent ? 1 : 0)
                    }

                    if !viewModel.isVideoTrackPresent {
                        AudioOnlyBackdrop(title: viewModel.currentItem?.title ?? "")
                    }

                    TrackpadGestureCatcher(onVolumeSwipe: handleVolumeSwipe, onSpeedPinch: handleSpeedPinch)
                } else {
                    HomeScreenView(viewModel: viewModel)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !showingHomeScreen else { return }
                onToggleFullscreen()
            }
            .onTapGesture(count: 1) {
                guard !showingHomeScreen else { return }
                if viewModel.currentItem == nil {
                    // Only the bare drop-zone case, not the home screen with actual
                    // Continue Watching/Saved Playlist cards in it — those have their own
                    // click targets, and "click anywhere opens a file picker" both doesn't
                    // make sense once there's a more specific action available and risks
                    // fighting a card's own tap for the same click.
                    guard !hasHomeScreenContent else { return }
                    NotificationCenter.default.post(name: .openMediaFile, object: nil)
                } else {
                    viewModel.togglePlayPause()
                }
            }

            if viewModel.translateSubtitles, viewModel.currentItem != nil {
                TranslatedSubtitleOverlay(
                    state: viewModel.subtitleTranslation,
                    targetLanguage: viewModel.subtitleTranslationTarget,
                    controlsVisible: controlsVisible
                )
            }

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }

            VStack {
                Spacer()
                if controlsVisible, viewModel.currentItem != nil {
                    PlaybackControlsBar(
                        viewModel: viewModel,
                        isFullscreen: isFullscreen,
                        onToggleFullscreen: onToggleFullscreen
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if isDropTargeted {
                DropOverlay()
            }

            // Manually opened via the toolbar Home button, on top of whatever's playing —
            // distinct from HomeScreenView showing up above as the natural "nothing
            // queued" state. Playback keeps running underneath (this only covers it
            // visually); closing just dismisses back to it.
            if showingHomeScreen, viewModel.currentItem != nil {
                HomeScreenView(viewModel: viewModel, isOverlay: true) {
                    showingHomeScreen = false
                }
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showControlsThenScheduleHide()
            case .ended:
                break
            }
        }
        .onChange(of: viewModel.isPlaying) { _, _ in
            scheduleAutoHide()
        }
        // General safety net alongside the sidebar's explicit dismiss: covers every other
        // way to resume/switch playback while Home is open (Next/Previous Track, Open
        // Recent, keyboard shortcuts, a Continue Watching card for a *different* file) —
        // any of them changing what's playing or its play/pause state means "show me the
        // player," the same intent a sidebar click has.
        .onChange(of: viewModel.currentItemID) { _, _ in
            showingHomeScreen = false
        }
        .onChange(of: viewModel.isPlaying) { _, _ in
            showingHomeScreen = false
        }
        // The mouse leaves this view's own hover tracking the instant it moves into a
        // native NSMenu popup (Subtitles, Audio Track, the playback-speed/repeat menus,
        // etc.) — SwiftUI has no idea the menu is still "yours." Without this, the
        // already-scheduled auto-hide timer from your last real mouse movement fires
        // right underneath an open menu, and PlaybackControlsBar (which is what the menu
        // button lives in) disappears mid-interaction, breaking the menu. NSMenu posts
        // these notifications for every menu it tracks, SwiftUI's included, so this
        // covers all of them generically rather than special-casing subtitles.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            hideControlsTask?.cancel()
            controlsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            scheduleAutoHide()
        }
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var hasHomeScreenContent: Bool {
        !viewModel.continueWatchingEntries().isEmpty || !viewModel.savedPlaylists.isEmpty
    }

    private func showControlsThenScheduleHide() {
        if !controlsVisible {
            controlsVisible = true
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard viewModel.isPlaying else { return }
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(autoHideDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // The main run loop only sits in event-tracking mode while a menu is open.
                // The NSMenu begin/end notifications above aren't enough on their own: a
                // submenu (e.g. Subtitles) closing posts "end" while its parent menu is
                // still open, which would schedule a hide right underneath it.
                if RunLoop.current.currentMode == .eventTracking {
                    scheduleAutoHide()
                } else {
                    controlsVisible = false
                }
            }
        }
    }

    /// Sensitivity tuned so a full trackpad-height swipe moves roughly the full 0...1
    /// range rather than either barely nudging it or blowing past it in an inch of
    /// travel. Follows the system's Natural Scrolling direction, same as any other
    /// scrollable content — swipe up raises the level when that's turned on (the default).
    private func handleVolumeSwipe(_ scrollingDeltaY: Double) {
        viewModel.volume = min(1, max(0, viewModel.volume + Float(scrollingDeltaY) * 0.003))
        if viewModel.volume > 0 {
            viewModel.isMuted = false
        }
    }

    /// Continuous rather than snapped to PlaybackSpeedMenu's presets — a physical pinch
    /// reads as a smooth, self-limiting gesture (each callback multiplies the current
    /// rate by a small factor) rather than discrete steps, and both engines already
    /// accept an arbitrary rate, not just the menu's curated list.
    private func handleSpeedPinch(_ magnification: Double) {
        guard viewModel.currentItem != nil else { return }
        let newRate = Double(viewModel.playbackRate) * (1 + magnification)
        viewModel.playbackRate = Float(min(4.0, max(0.25, newRate)))
    }
}

/// Shown whenever nothing's queued — first launch, or after Clear Playlist. Blank apart
/// from the drop-zone hint until there's something to resume or reopen, at which point it
/// becomes a small streaming-service-style home screen instead of just an empty stage.
/// Shown two ways: as the natural "nothing queued" stage (isOverlay false — first
/// launch, or after Clear Playlist), and manually via the toolbar Home button on top of
/// whatever's currently playing (isOverlay true, with a close button, playback continuing
/// underneath). Vertical lists rather than a horizontal scroller — a `ScrollView(.horizontal,
/// showsIndicators: false)` gives no visual hint that a second card exists just off-screen,
/// which is genuinely indistinguishable from "there's only one," so a plain top-to-bottom
/// list that never hides how many rows there are is the more honest layout here.
private struct HomeScreenView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// Observed separately so the Continue Watching row for whatever's playing underneath
    /// counts up live — the view model no longer publishes time ticks itself.
    @ObservedObject private var clock: PlaybackClock
    let isOverlay: Bool
    let onDismiss: (() -> Void)?

    init(viewModel: PlayerViewModel, isOverlay: Bool = false, onDismiss: (() -> Void)? = nil) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _clock = ObservedObject(wrappedValue: viewModel.clock)
        self.isOverlay = isOverlay
        self.onDismiss = onDismiss
    }

    var body: some View {
        let continueWatching = viewModel.continueWatchingEntries()
        let savedPlaylists = viewModel.savedPlaylists
        let isEmpty = continueWatching.isEmpty && savedPlaylists.isEmpty

        if isEmpty, !isOverlay {
            DropZoneHint()
        } else {
            ZStack {
                if isOverlay {
                    Color.black.opacity(0.97)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if isOverlay {
                            HStack {
                                Text("Home")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Spacer()
                                Button {
                                    onDismiss?()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .buttonStyle(.plain)
                                .help("Close")
                            }
                            .padding(.top, 22)
                        } else {
                            Spacer(minLength: 24)
                        }

                        if !continueWatching.isEmpty {
                            HomeScreenSection(title: "Continue Watching") {
                                ForEach(continueWatching, id: \.file.id) { entry in
                                    ContinueWatchingRow(
                                        file: entry.file,
                                        position: entry.position,
                                        thumbnailProvider: {
                                            await viewModel.generateHomeScreenThumbnail(for: entry.file, at: entry.position)
                                        },
                                        action: {
                                            viewModel.openRecentFile(entry.file)
                                            onDismiss?()
                                        },
                                        onRemove: {
                                            viewModel.removeFromContinueWatching(entry.file)
                                        }
                                    )
                                }
                            }
                        }

                        if !savedPlaylists.isEmpty {
                            HomeScreenSection(title: "Saved Playlists") {
                                ForEach(savedPlaylists) { saved in
                                    SavedPlaylistRow(
                                        playlist: saved,
                                        action: {
                                            viewModel.loadSavedPlaylist(id: saved.id)
                                            onDismiss?()
                                        },
                                        onDelete: {
                                            viewModel.deleteSavedPlaylist(id: saved.id)
                                        }
                                    )
                                }
                            }
                        }

                        if isEmpty {
                            Text("Nothing to show here yet — files you're partway through, or playlists you've saved, will show up here.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                        } else if !isOverlay {
                            // Still the actual click/drop target underneath all of this —
                            // shown smaller here since it's no longer the only thing on screen.
                            DropZoneHint(compact: true)
                                .frame(maxWidth: .infinity)
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                }
                // Without an explicit frame, ScrollView sizes itself to its content and
                // ZStack centers that small island in the middle of the black stage
                // instead of filling it top-to-bottom.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct HomeScreenSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            VStack(spacing: 6) {
                content()
            }
        }
    }
}

private struct ContinueWatchingRow: View {
    let file: RecentFile
    let position: Double
    let thumbnailProvider: () async -> CGImage?
    let action: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            // Placeholder until the thumbnail loads, and the permanent
                            // state for mpv-only formats (MKV/AVI/etc.), which can't
                            // generate one — see generateHomeScreenThumbnail's doc comment.
                            Image(systemName: "play.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipped()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Text("Resume at \(TimeFormatter.string(from: position))")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(isHovering ? 0.6 : 0.22))
            }
            .buttonStyle(.plain)
            .help("Remove from Continue Watching")
        }
        .padding(8)
        .background(Color.white.opacity(isHovering ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .task {
            thumbnail = await thumbnailProvider()
        }
    }
}

private struct SavedPlaylistRow: View {
    let playlist: SavedPlaylist
    let action: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                        Image(systemName: "music.note.list")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: 96, height: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Text("\(playlist.entries.count) item\(playlist.entries.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(isHovering ? 0.6 : 0.22))
            }
            .buttonStyle(.plain)
            .help("Delete Saved Playlist")
        }
        .padding(8)
        .background(Color.white.opacity(isHovering ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
    }
}

private struct DropZoneHint: View {
    var compact: Bool = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: compact ? 6 : 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: compact ? 26 : 44, weight: .light))
                .foregroundStyle(.white.opacity(isHovering ? 0.5 : (compact ? 0.3 : 0.35)))
            Text("Drop a video or audio file here")
                .font(.system(size: compact ? 12 : 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(isHovering ? 0.75 : (compact ? 0.4 : 0.55)))
            Text("or click here, or press \u{2318}O, to open")
                .font(.system(size: compact ? 10.5 : 12))
                .foregroundStyle(.white.opacity(compact ? 0.28 : 0.35))
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        // Purely a visual/cursor affordance — the actual click is handled by
        // PlayerContainerView's tap gesture on the whole stage, so this view has
        // no gesture of its own and nothing to conflict with double-click-to-fullscreen.
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct AudioOnlyBackdrop: View {
    let title: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.12))
            .padding(20)
            .overlay {
                Label("Drop to add to playlist", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .allowsHitTesting(false)
    }
}

private struct ErrorBanner: View {
    let message: String
    var body: some View {
        VStack {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 16)
            Spacer()
        }
    }
}
