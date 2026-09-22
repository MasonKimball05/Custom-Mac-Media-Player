import SwiftUI
import UniformTypeIdentifiers

/// Audio-track and subtitle picker, tucked behind a single "captions" icon rather than
/// eating permanent transport-bar space — this is where VLC puts its Audio/Subtitle menus.
struct TrackMenuButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var isHovering = false
    @State private var subtitleDelay: Double = 0
    @State private var subtitleScale: Double = 1

    var body: some View {
        Menu {
            let audioTracks = viewModel.availableAudioTracks()
            if audioTracks.count > 1 {
                Menu("Audio Track") {
                    ForEach(audioTracks) { track in
                        Button {
                            viewModel.selectAudioTrack(id: track.id)
                        } label: {
                            trackLabel(track)
                        }
                    }
                }
            }

            let subtitleTracks = viewModel.availableSubtitleTracks()
            Menu("Subtitles") {
                Button {
                    viewModel.selectSubtitleTrack(id: nil)
                } label: {
                    if subtitleTracks.contains(where: \.isSelected) {
                        Text("Off")
                    } else {
                        Label("Off", systemImage: "checkmark")
                    }
                }

                if !subtitleTracks.isEmpty {
                    Divider()
                    ForEach(subtitleTracks) { track in
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

                if viewModel.currentEngineCapabilities.subtitleTiming || viewModel.currentEngineCapabilities.subtitleScaling {
                    Divider()
                    if viewModel.currentEngineCapabilities.subtitleTiming {
                        Button("Delay Subtitles +0.5s") { adjustDelay(by: 0.5) }
                        Button("Advance Subtitles \u{2212}0.5s") { adjustDelay(by: -0.5) }
                    }
                    if viewModel.currentEngineCapabilities.subtitleScaling {
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
        .disabled(viewModel.currentItem == nil)
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
