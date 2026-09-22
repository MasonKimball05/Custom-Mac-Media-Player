import SwiftUI

/// The bottom transport bar: scrubber up top, then transport/volume/speed/fullscreen
/// controls below. Lives on a blurred material so it reads as a floating HUD over video.
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

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(TimeFormatter.string(from: viewModel.currentTime))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .trailing)

                ScrubberView(
                    currentTime: viewModel.currentTime,
                    duration: viewModel.duration,
                    bufferedFraction: viewModel.bufferedFraction,
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

                Text(TimeFormatter.string(from: viewModel.duration))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, alignment: .leading)
            }

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    ControlButton(systemName: "backward.end.fill", size: 13) {
                        viewModel.playPrevious()
                    }
                    ControlButton(systemName: "gobackward.\(skipIconSuffix)", size: 15) {
                        viewModel.skip(by: -skipInterval)
                    }
                    ControlButton(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill", size: 20, padding: 9) {
                        viewModel.togglePlayPause()
                    }
                    ControlButton(systemName: "goforward.\(skipIconSuffix)", size: 15) {
                        viewModel.skip(by: skipInterval)
                    }
                    ControlButton(systemName: "forward.end.fill", size: 13) {
                        viewModel.playNext()
                    }
                }

                Spacer(minLength: 0)

                VolumeControl(volume: $viewModel.volume, isMuted: $viewModel.isMuted)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    ControlButton(systemName: "shuffle", size: 13, isActive: viewModel.isShuffled) {
                        viewModel.isShuffled.toggle()
                    }
                    ControlButton(systemName: repeatIconName, size: 13, isActive: viewModel.repeatMode != .off) {
                        cycleRepeatMode()
                    }
                    TrackMenuButton(viewModel: viewModel)
                    if !viewModel.usesMPVEngine {
                        // AirPlay routes an AVPlayer specifically — mpv (MKV/AVI/etc.)
                        // has no equivalent hook, so this only appears when it'd work.
                        AirPlayButton(player: viewModel.player)
                            .frame(width: 20, height: 20)
                    }
                    PlaybackSpeedMenu(rate: $viewModel.playbackRate)
                    ControlButton(
                        systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        size: 13,
                        action: onToggleFullscreen
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // The rounded-corner clip lives on the background layer only, not the whole
        // bar, so the scrubber's hover time-preview tooltip (which pops up above the
        // bar's own top edge) isn't cut off along with it.
        .background {
            ZStack(alignment: .top) {
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                    .opacity(0.9)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(10)
    }
}
