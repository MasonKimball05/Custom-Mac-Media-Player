import SwiftUI

/// The bottom transport bar, laid out the way YouTube's player is: no card, just a dark
/// gradient rising from the bottom edge, a full-width scrubber, and one row of controls
/// under it (transport, volume, and time on the left; toggles and settings on the right).
struct PlaybackControlsBar: View {
    @ObservedObject var viewModel: PlayerViewModel
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval

    private var skipIconSuffix: String {
        [5, 10, 15, 30].contains(Int(skipInterval)) ? "\(Int(skipInterval))" : "10"
    }

    private var repeatIconName: String {
        viewModel.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func cycleRepeatMode() {
        switch viewModel.repeatMode {
        case .off: viewModel.repeatMode = .all
        case .all: viewModel.repeatMode = .one
        case .one: viewModel.repeatMode = .off
        }
    }

    private var currentChapterTitle: String? {
        guard let id = viewModel.currentChapterID else { return nil }
        return viewModel.availableChapters().first { $0.id == id }?.title
    }

    var body: some View {
        VStack(spacing: 2) {
            ScrubberRow(clock: viewModel.clock, viewModel: viewModel, duration: viewModel.duration)

            HStack(spacing: 2) {
                ControlButton(systemName: "backward.end.fill", size: 14) {
                    viewModel.playPrevious()
                }
                .help("Previous Track")
                ControlButton(systemName: "gobackward.\(skipIconSuffix)", size: 16) {
                    viewModel.skip(by: -skipInterval)
                }
                .help("Back \(Int(skipInterval)) Seconds")
                ControlButton(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill", size: 22, padding: 8) {
                    viewModel.togglePlayPause()
                }
                .help(viewModel.isPlaying ? "Pause" : "Play")
                ControlButton(systemName: "goforward.\(skipIconSuffix)", size: 16) {
                    viewModel.skip(by: skipInterval)
                }
                .help("Forward \(Int(skipInterval)) Seconds")
                ControlButton(systemName: "forward.end.fill", size: 14) {
                    viewModel.playNext()
                }
                .help("Next Track")

                VolumeControl(volume: $viewModel.volume, isMuted: $viewModel.isMuted)
                    .padding(.leading, 4)

                TimeReadout(clock: viewModel.clock, duration: viewModel.duration, chapterTitle: currentChapterTitle)
                    .padding(.leading, 6)

                Spacer(minLength: 12)

                HStack(spacing: 2) {
                    ControlButton(systemName: "shuffle", size: 14, isActive: viewModel.isShuffled) {
                        viewModel.isShuffled.toggle()
                    }
                    .help("Shuffle")
                    ControlButton(systemName: repeatIconName, size: 14, isActive: viewModel.repeatMode != .off) {
                        cycleRepeatMode()
                    }
                    .help("Repeat")
                    ABLoopButton(viewModel: viewModel)
                        .disabled(viewModel.currentItem == nil)
                    CaptionsButton(viewModel: viewModel)
                    SettingsMenuButton(viewModel: viewModel)
                    if viewModel.currentEngineCapabilities.airPlay {
                        // AirPlay routes an AVPlayer specifically — mpv (MKV/AVI/etc.)
                        // has no equivalent hook, so this only appears when it'd work.
                        AirPlayButton(player: viewModel.player)
                            .frame(width: 22, height: 22)
                            .padding(.horizontal, 5)
                    }
                    ControlButton(
                        systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        size: 15,
                        action: onToggleFullscreen
                    )
                    .help(isFullscreen ? "Exit Full Screen" : "Full Screen")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        // The gradient reaches well above the controls so white icons and the scrubber
        // stay legible over bright video, but that extra height is only drawn, not laid
        // out: the bar's measured height (what subtitles move above) is the controls
        // alone, and clicks on the faded area still reach the video underneath.
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.4),
                    .init(color: .black.opacity(0.75), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -80)
            .allowsHitTesting(false)
        }
    }
}

/// The one part of the bar that changes every playback tick besides the time readout. It
/// observes the clock directly, so each tick redraws only this row — not the rest of the
/// bar, and in particular not the settings menu next to it.
private struct ScrubberRow: View {
    @ObservedObject var clock: PlaybackClock
    /// Not observed — only used to send scrub actions.
    let viewModel: PlayerViewModel
    let duration: Double

    var body: some View {
        ScrubberView(
            currentTime: clock.currentTime,
            duration: duration,
            bufferedFraction: clock.bufferedFraction,
            onScrubStart: { viewModel.isScrubbing = true },
            onScrub: { viewModel.seek(to: $0) },
            onScrubEnd: { time in
                viewModel.seek(to: time)
                viewModel.isScrubbing = false
            },
            thumbnailProvider: { time in
                await viewModel.generateThumbnail(at: time)
            }
        )
    }
}

/// "1:23 / 4:56 · Chapter", YouTube's readout. Clicking it switches between elapsed and
/// remaining time. Observes the clock for the same reason as ScrubberRow.
private struct TimeReadout: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let chapterTitle: String?

    @AppStorage(AppSettingsKeys.showsRemainingTime) private var showsRemaining = false

    var body: some View {
        Button {
            showsRemaining.toggle()
        } label: {
            HStack(spacing: 0) {
                Text(timeText)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                if let chapterTitle {
                    Text("  \u{00B7}  \(chapterTitle)")
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsRemaining ? "Show Elapsed Time" : "Show Remaining Time")
    }

    private var timeText: String {
        let total = TimeFormatter.string(from: duration)
        if showsRemaining {
            return "\u{2212}\(TimeFormatter.string(from: max(0, duration - clock.currentTime))) / \(total)"
        }
        return "\(TimeFormatter.string(from: clock.currentTime)) / \(total)"
    }
}

/// One-click subtitles on/off, marked with an accent underline while on (YouTube's red
/// CC underline). Picking a specific track or loading a file is in the settings gear.
private struct CaptionsButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var isHovering = false

    var body: some View {
        let tracks = viewModel.availableSubtitleTracks()
        let isOn = tracks.contains(where: \.isSelected)
        Button {
            viewModel.toggleSubtitles()
        } label: {
            Image(systemName: isOn ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0)))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 2.5)
                        .offset(y: -3)
                        .opacity(isOn ? 1 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.4 : 1)
        .help(tracks.isEmpty ? "No Subtitles" : isOn ? "Turn Off Subtitles" : "Turn On Subtitles")
    }
}
