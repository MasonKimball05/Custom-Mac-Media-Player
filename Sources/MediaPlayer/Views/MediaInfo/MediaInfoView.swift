import SwiftUI

/// The ⌘I panel — codec/resolution/bitrate details pulled fresh from whichever engine
/// is currently playing. VLC calls this "Codec Information".
struct MediaInfoView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var info: MediaInfo?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.currentItem?.title ?? "Media Info")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else if let info {
                Form {
                    Section("General") {
                        row("Engine", info.engineName)
                        row("Container", info.containerFormat)
                        row("File Size", info.fileSizeBytes.map(Self.byteFormatter.string(fromByteCount:)))
                        row("Duration", TimeFormatter.string(from: viewModel.duration))
                    }
                    Section("Video") {
                        row("Codec", info.videoCodec)
                        row("Dimensions", info.videoDimensions)
                        row("Frame Rate", info.frameRate.map { String(format: "%.2f fps", $0) })
                        row("Bitrate", info.videoBitrate.map(Self.bitrateString))
                    }
                    Section("Audio") {
                        row("Codec", info.audioCodec)
                        row("Channels", info.audioChannels.map(String.init))
                        row("Sample Rate", info.audioSampleRate.map { String(format: "%.0f Hz", $0) })
                        row("Bitrate", info.audioBitrate.map(Self.bitrateString))
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Nothing is playing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 380, height: 440)
        .task { await load() }
        .onChange(of: viewModel.currentItemID) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        info = await viewModel.fetchMediaInfo()
        isLoading = false
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label, value: value ?? "\u{2014}")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func bitrateString(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 0 else { return "\u{2014}" }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }
}
