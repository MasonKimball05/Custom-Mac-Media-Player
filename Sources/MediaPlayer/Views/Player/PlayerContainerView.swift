import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main stage: video surface + auto-hiding custom chrome on top of it.
/// Handles drag & drop of media files, click-to-toggle-play, and hover-driven
/// visibility of the transport bar so video can breathe full-bleed.
struct PlayerContainerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isDropTargeted = false

    @AppStorage(AppSettingsKeys.autoHideControlsDelay) private var autoHideDelay = AppSettingsDefaults.autoHideControlsDelay

    var body: some View {
        ZStack {
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
            } else {
                EmptyStateView()
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
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onToggleFullscreen()
        }
        .onTapGesture(count: 1) {
            if viewModel.currentItem == nil {
                NotificationCenter.default.post(name: .openMediaFile, object: nil)
            } else {
                viewModel.togglePlayPause()
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
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
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
                controlsVisible = false
            }
        }
    }
}

private struct EmptyStateView: View {
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(isHovering ? 0.5 : 0.35))
            Text("Drop a video or audio file here")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(isHovering ? 0.75 : 0.55))
            Text("or click here, or press \u{2318}O, to open")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
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
