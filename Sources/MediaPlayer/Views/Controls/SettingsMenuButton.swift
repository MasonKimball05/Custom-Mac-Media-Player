import SwiftUI
import UniformTypeIdentifiers

/// The playback presets, shared by the settings gear and the < / > speed-step shortcuts.
enum PlaybackSpeed {
    static let presets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func label(for speed: Float) -> String {
        speed == 1.0 ? "Normal" : String(format: "%gx", speed)
    }
}

/// The gear menu, YouTube-style: subtitles, audio track, chapters, playback speed, and the
/// video & subtitle adjustments panel, all behind one button instead of a row of them.
///
/// Split in two: this wrapper observes the view model to compute a value-type snapshot of
/// what the menu should show, and the menu itself is `.equatable()` on that snapshot, so
/// an open menu is only rebuilt when what it displays actually changes. Nothing here
/// reads the playback clock — see PlaybackClock for why that matters for open menus.
struct SettingsMenuButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var showingAdjustments = false

    var body: some View {
        SettingsMenu(
            viewModel: viewModel,
            contents: SettingsMenuContents(
                chapters: viewModel.availableChapters(),
                currentChapterID: viewModel.currentChapterID,
                audioTracks: viewModel.availableAudioTracks(),
                subtitleTracks: viewModel.availableSubtitleTracks(),
                capabilities: viewModel.currentEngineCapabilities,
                isTranslating: viewModel.translateSubtitles,
                playbackRate: viewModel.playbackRate,
                isEnabled: viewModel.currentItem != nil
            ),
            onShowAdjustments: { showingAdjustments = true }
        )
        .equatable()
        .popover(isPresented: $showingAdjustments, arrowEdge: .top) {
            AdjustmentsPanel(viewModel: viewModel)
        }
    }
}

private struct SettingsMenuContents: Equatable {
    let chapters: [Chapter]
    let currentChapterID: Chapter.ID?
    let audioTracks: [MediaTrack]
    let subtitleTracks: [MediaTrack]
    let capabilities: EngineCapabilities
    let isTranslating: Bool
    let playbackRate: Float
    let isEnabled: Bool
}

private struct SettingsMenu: View, Equatable {
    /// Deliberately not observed — only used to send actions. Everything the menu
    /// displays comes from `contents`, which is what equality is judged on.
    let viewModel: PlayerViewModel
    let contents: SettingsMenuContents
    let onShowAdjustments: () -> Void

    @State private var isHovering = false
    @State private var subtitleDelay: Double = 0
    @State private var subtitleScale: Double = 1

    nonisolated static func == (lhs: SettingsMenu, rhs: SettingsMenu) -> Bool {
        lhs.contents == rhs.contents
    }

    var body: some View {
        Menu {
            subtitlesMenu

            if contents.audioTracks.count > 1 {
                Menu("Audio Track") {
                    ForEach(contents.audioTracks) { track in
                        Button {
                            viewModel.selectAudioTrack(id: track.id)
                        } label: {
                            trackLabel(track)
                        }
                    }
                }
            }

            if !contents.chapters.isEmpty {
                Menu("Chapters") {
                    ForEach(contents.chapters) { chapter in
                        Button {
                            viewModel.seek(to: chapter.startTime)
                        } label: {
                            let label = "\(TimeFormatter.string(from: chapter.startTime))  \u{2014}  \(chapter.title)"
                            if chapter.id == contents.currentChapterID {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                }
            }

            Menu("Playback Speed: \(PlaybackSpeed.label(for: contents.playbackRate))") {
                ForEach(PlaybackSpeed.presets, id: \.self) { speed in
                    Button {
                        viewModel.playbackRate = speed
                    } label: {
                        if speed == contents.playbackRate {
                            Label(PlaybackSpeed.label(for: speed), systemImage: "checkmark")
                        } else {
                            Text(PlaybackSpeed.label(for: speed))
                        }
                    }
                }
            }

            Divider()

            Button("Video \u{0026} Subtitle Adjustments\u{2026}", action: onShowAdjustments)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0)))
                .overlay(alignment: .topTrailing) {
                    // Like YouTube's HD badge on its gear: the one setting worth seeing
                    // without opening the menu, shown only when it's not the default.
                    if contents.playbackRate != 1 {
                        Text(String(format: "%gx", contents.playbackRate))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: 4, y: 1)
                    }
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .disabled(!contents.isEnabled)
        .help("Settings")
    }

    private var subtitlesMenu: some View {
        Menu("Subtitles") {
            Button {
                viewModel.selectSubtitleTrack(id: nil)
            } label: {
                if contents.subtitleTracks.contains(where: \.isSelected) {
                    Text("Off")
                } else {
                    Label("Off", systemImage: "checkmark")
                }
            }

            if !contents.subtitleTracks.isEmpty {
                Divider()
                ForEach(contents.subtitleTracks) { track in
                    Button {
                        viewModel.selectSubtitleTrack(id: track.id)
                    } label: {
                        trackLabel(track)
                    }
                }
            }

            Divider()
            Button("Load Subtitle File\u{2026}") {
                openSubtitlePanel()
            }
            Button {
                viewModel.translateSubtitles.toggle()
            } label: {
                if contents.isTranslating {
                    Label("Translate Subtitles", systemImage: "checkmark")
                } else {
                    Text("Translate Subtitles")
                }
            }

            if contents.capabilities.subtitleTiming || contents.capabilities.subtitleScaling {
                Divider()
                if contents.capabilities.subtitleTiming {
                    Button("Delay Subtitles +0.5s") { adjustDelay(by: 0.5) }
                    Button("Advance Subtitles \u{2212}0.5s") { adjustDelay(by: -0.5) }
                }
                if contents.capabilities.subtitleScaling {
                    Button("Larger Subtitle Text") { adjustScale(by: 0.1) }
                    Button("Smaller Subtitle Text") { adjustScale(by: -0.1) }
                }
            }
        }
    }

    @ViewBuilder
    private func trackLabel(_ track: MediaTrack) -> some View {
        if track.isSelected {
            Label(track.displayName, systemImage: "checkmark")
        } else {
            Text(track.displayName)
        }
    }

    private func adjustDelay(by delta: Double) {
        subtitleDelay += delta
        viewModel.setSubtitleDelay(subtitleDelay)
    }

    private func adjustScale(by delta: Double) {
        subtitleScale = max(0.3, subtitleScale + delta)
        viewModel.setSubtitleScale(subtitleScale)
    }

    private func openSubtitlePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadExternalSubtitle(url: url)
            }
        }
    }
}
