import SwiftUI
import UniformTypeIdentifiers

/// Audio-track and subtitle picker, tucked behind a single "captions" icon rather than
/// eating permanent transport-bar space — this is where VLC puts its Audio/Subtitle menus.
///
/// Split in two: this wrapper observes the view model to compute a value-type snapshot of
/// what the menu should show, and the menu itself is `.equatable()` on that snapshot, so
/// an open menu is only rebuilt when what it displays actually changes. Nothing here
/// reads the playback clock — see PlaybackClock for why that matters for open menus.
struct TrackMenuButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        TrackMenu(
            viewModel: viewModel,
            contents: TrackMenuContents(
                chapters: viewModel.availableChapters(),
                currentChapterID: viewModel.currentChapterID,
                audioTracks: viewModel.availableAudioTracks(),
                subtitleTracks: viewModel.availableSubtitleTracks(),
                capabilities: viewModel.currentEngineCapabilities,
                isEnabled: viewModel.currentItem != nil
            )
        )
        .equatable()
    }
}

private struct TrackMenuContents: Equatable {
    let chapters: [Chapter]
    let currentChapterID: Chapter.ID?
    let audioTracks: [MediaTrack]
    let subtitleTracks: [MediaTrack]
    let capabilities: EngineCapabilities
    let isEnabled: Bool
}

private struct TrackMenu: View, Equatable {
    /// Deliberately not observed — only used to send actions. Everything the menu
    /// displays comes from `contents`, which is what equality is judged on.
    let viewModel: PlayerViewModel
    let contents: TrackMenuContents

    @State private var isHovering = false
    @State private var subtitleDelay: Double = 0
    @State private var subtitleScale: Double = 1

    nonisolated static func == (lhs: TrackMenu, rhs: TrackMenu) -> Bool {
        lhs.contents == rhs.contents
    }

    var body: some View {
        Menu {
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
                Divider()
            }

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
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 29, height: 29)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .disabled(!contents.isEnabled)
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
