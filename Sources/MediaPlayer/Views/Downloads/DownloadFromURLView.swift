import SwiftUI

/// File ▸ Download from URL: paste a link yt-dlp understands, then choose what to save.
/// Two steps in one sheet: the link, and (once yt-dlp has described it) the options.
struct DownloadFromURLView: View {
    @ObservedObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var info: RemoteMediaInfo?
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var fetchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            if let info {
                DownloadOptionsForm(info: info, downloads: downloads, onBack: { self.info = nil }) {
                    dismiss()
                }
            } else {
                linkStep
            }
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from URL")
                .font(.headline)

            Text("Paste a link to a video on YouTube or any other site yt-dlp supports.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("https://www.youtube.com/watch?v=\u{2026}", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .disabled(isFetching)
                .onSubmit(fetch)

            YTDLPUpdateNotice(updates: downloads.updates)

            if !YTDLP.isInstalled {
                Label {
                    Text("yt-dlp isn't installed. Install it with Homebrew: ") + Text("brew install yt-dlp").font(.callout.monospaced())
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.callout)
            } else if let fetchError {
                Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if isFetching {
                    ProgressView().controlSize(.small)
                    Text("Getting video details\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { fetch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedURL.isEmpty || isFetching || !YTDLP.isInstalled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { isFieldFocused = true }
        // Picks up an update run in Terminal since the last check.
        .task { await downloads.updates.refresh() }
    }

    private var trimmedURL: String { urlString.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func fetch() {
        guard !trimmedURL.isEmpty, !isFetching else { return }
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            fetchError = "Enter a full web link, starting with https://."
            return
        }
        isFetching = true
        fetchError = nil
        let link = trimmedURL
        fetchTask = Task {
            defer { isFetching = false }
            do {
                info = try await YTDLP.fetchInfo(for: link)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                fetchError = error.localizedDescription
            }
        }
    }
}

private struct DownloadOptionsForm: View {
    let info: RemoteMediaInfo
    @ObservedObject var downloads: DownloadManager
    let onBack: () -> Void
    let onStarted: () -> Void

    @AppStorage(AppSettingsKeys.downloadKind) private var kind = DownloadOptions.Kind.video
    @AppStorage(AppSettingsKeys.downloadVideoFormat) private var videoFormat = DownloadOptions.VideoFormat.mp4
    @AppStorage(AppSettingsKeys.downloadAudioFormat) private var audioFormat = DownloadOptions.AudioFormat.m4a
    @AppStorage(AppSettingsKeys.downloadSubtitleSaving) private var subtitleSaving = DownloadOptions.SubtitleSaving.separateFiles
    @AppStorage(AppSettingsKeys.downloadAddsToPlaylist) private var addToPlaylist = true

    /// 0 means the best available.
    @State private var maxHeight = 0
    @State private var selectedSubtitles: Set<RemoteMediaInfo.Subtitle> = []
    @State private var translationFilter = ""

    private var effectiveKind: DownloadOptions.Kind { info.hasVideo ? kind : .audio }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)

            Form {
                Section("Download") {
                    if info.hasVideo {
                        Picker("Save", selection: $kind) {
                            Text("Video").tag(DownloadOptions.Kind.video)
                            Text("Audio Only").tag(DownloadOptions.Kind.audio)
                        }
                        .pickerStyle(.segmented)
                    }

                    if effectiveKind == .video {
                        videoOptions
                    } else {
                        audioOptions
                    }
                }

                subtitleSection

                Section("Save To") {
                    LabeledContent("Folder") {
                        HStack {
                            if let folder = downloads.destinationFolder {
                                Label(folder.lastPathComponent, systemImage: "folder")
                                    .help(folder.path)
                            } else {
                                Text("None chosen").foregroundStyle(.secondary)
                            }
                            Button(downloads.destinationFolder == nil ? "Choose\u{2026}" : "Change\u{2026}") {
                                downloads.chooseDestinationFolder()
                            }
                        }
                    }
                    Toggle("Add to playlist when finished", isOn: $addToPlaylist)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Back", action: onBack)
                Spacer()
                Button("Cancel", action: onStarted)
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(downloads.destinationFolder == nil)
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: info.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: info.hasVideo ? "film" : "music.note").foregroundStyle(.secondary))
            }
            .frame(width: 144, height: 81)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(3)
                Text([info.uploader, info.duration.map { TimeFormatter.string(from: $0) }].compactMap(\.self).joined(separator: " \u{00B7} "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        Picker("Format", selection: $videoFormat) {
            ForEach(DownloadOptions.VideoFormat.allCases) { Text($0.label).tag($0) }
        }
        Picker("Quality", selection: $maxHeight) {
            Text(availableHeights.first.map { "Best Available (\(qualityName($0)))" } ?? "Best Available").tag(0)
            ForEach(availableHeights.dropFirst(), id: \.self) { Text(qualityName($0)).tag($0) }
        }
        .onChange(of: videoFormat) { maxHeight = 0 }
        Text(videoFormatNote)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// MP4 means H.264, so its choices are the H.264 resolutions, unless the site has none
    /// (then it falls back to whatever the site has, saved as MKV).
    private var availableHeights: [Int] {
        videoFormat == .mp4 && !info.h264Heights.isEmpty ? info.h264Heights : info.videoHeights
    }

    private var videoFormatNote: String {
        switch videoFormat {
        case .mp4 where info.h264Heights.isEmpty:
            "This site doesn't offer H.264 video, so it will be saved as MKV instead."
        case .mp4:
            if let best = info.videoHeights.first, let bestH264 = info.h264Heights.first, best > bestH264 {
                "Saved as H.264 so it plays in any app, with thumbnails and AirPlay here. This video goes up to \(qualityName(best)) in other formats; choose MKV for that."
            } else {
                "Saved as H.264 so it plays in any app, with thumbnails and AirPlay here."
            }
        case .mkv:
            "Keeps the highest quality the site offers, including 4K and HDR. Plays here through the MKV engine."
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        Picker("Format", selection: $audioFormat) {
            ForEach(DownloadOptions.AudioFormat.allCases) { Text($0.label).tag($0) }
        }
        if audioFormat == .flac || audioFormat == .wav {
            Text("Online audio is already compressed, so a lossless format keeps it exactly as downloaded but won't improve it, only make the file larger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var subtitleSection: some View {
        let original = info.automaticCaptions.filter(\.isOriginalLanguage)
        let translated = info.automaticCaptions.filter { !$0.isOriginalLanguage }
        Section("Subtitles") {
            if info.subtitles.isEmpty && info.automaticCaptions.isEmpty {
                Text("This video has no subtitles.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(info.subtitles) { subtitleToggle($0, label: $0.name) }
                ForEach(original) { subtitleToggle($0, label: "\($0.name) (auto-generated, original language)") }
                // With no "-orig" track marked, a site's automatic captions are all there is.
                if original.isEmpty, translated.count <= 3 {
                    ForEach(translated) { subtitleToggle($0, label: "\($0.name) (auto-generated)") }
                } else if !translated.isEmpty {
                    DisclosureGroup("Auto-translated (\(translated.count) languages)") {
                        TextField("Filter languages", text: $translationFilter)
                        ForEach(translated.filter(matchesFilter)) { subtitleToggle($0, label: $0.name) }
                    }
                }

                if effectiveKind == .video, !selectedSubtitles.isEmpty {
                    Picker("Save Subtitles As", selection: $subtitleSaving) {
                        ForEach(DownloadOptions.SubtitleSaving.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
        }
    }

    private func subtitleToggle(_ subtitle: RemoteMediaInfo.Subtitle, label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { selectedSubtitles.contains(subtitle) },
            set: { isOn in
                if isOn { selectedSubtitles.insert(subtitle) } else { selectedSubtitles.remove(subtitle) }
            }
        ))
    }

    private func matchesFilter(_ subtitle: RemoteMediaInfo.Subtitle) -> Bool {
        let filter = translationFilter.trimmingCharacters(in: .whitespaces)
        return filter.isEmpty
            || subtitle.name.localizedCaseInsensitiveContains(filter)
            || subtitle.code.localizedCaseInsensitiveContains(filter)
            || selectedSubtitles.contains(subtitle)
    }

    private func qualityName(_ height: Int) -> String {
        switch height {
        case 2160...: height == 2160 ? "4K" : "\(height)p"
        case 1440: "1440p (2K)"
        default: "\(height)p"
        }
    }

    private func startDownload() {
        var options = DownloadOptions()
        options.kind = effectiveKind
        options.videoFormat = videoFormat
        options.maxHeight = maxHeight == 0 ? nil : maxHeight
        options.audioFormat = audioFormat
        options.subtitles = selectedSubtitles
        options.subtitleSaving = subtitleSaving
        downloads.startDownload(info: info, options: options, addToPlaylist: addToPlaylist)
        onStarted()
    }
}
