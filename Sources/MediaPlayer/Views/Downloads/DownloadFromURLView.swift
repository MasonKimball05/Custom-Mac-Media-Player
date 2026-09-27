import SwiftUI

/// File ▸ Download from URL: paste a link yt-dlp understands, then choose what to save.
/// Two steps in one sheet: the link, and (once yt-dlp has described it) the options, for
/// either a single video or the videos of a playlist.
struct DownloadFromURLView: View {
    @ObservedObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var result: YTDLP.FetchResult?
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var fetchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            switch result {
            case .video(let info):
                DownloadOptionsForm(info: info, downloads: downloads, onBack: { result = nil }) {
                    dismiss()
                }
            case .playlist(let playlist):
                PlaylistDownloadForm(playlist: playlist, downloads: downloads, onBack: { result = nil }) {
                    dismiss()
                }
            case nil:
                linkStep
            }
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download from URL")
                .font(.headline)

            Text("Paste a link to a video or playlist on YouTube, or on any other site yt-dlp supports.")
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
                    Text("Getting details\u{2026}")
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
                result = try await YTDLP.fetchInfo(for: link)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                fetchError = error.localizedDescription
            }
        }
    }
}

// MARK: - One video

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
                FormatSection(
                    kind: $kind, videoFormat: $videoFormat, maxHeight: $maxHeight, audioFormat: $audioFormat,
                    hasVideo: info.hasVideo, qualities: .known(all: info.videoHeights, h264: info.h264Heights)
                )
                subtitleSection
                SaveToSection(downloads: downloads, addToPlaylist: $addToPlaylist)
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
            Thumbnail(url: info.thumbnailURL, isVideo: info.hasVideo, width: 144, height: 81)

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
                    SubtitleSavingPicker(selection: $subtitleSaving)
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

// MARK: - A playlist

/// Pick which of a playlist's videos to download, then one set of options for all of them.
/// yt-dlp lists a playlist without fetching each video, so what each one offers (its
/// qualities, its subtitle languages) isn't known here: quality is a maximum, and
/// subtitles are by language, downloaded for whichever videos have them.
private struct PlaylistDownloadForm: View {
    let playlist: RemotePlaylist
    @ObservedObject var downloads: DownloadManager
    let onBack: () -> Void
    let onStarted: () -> Void

    @AppStorage(AppSettingsKeys.downloadKind) private var kind = DownloadOptions.Kind.video
    @AppStorage(AppSettingsKeys.downloadVideoFormat) private var videoFormat = DownloadOptions.VideoFormat.mp4
    @AppStorage(AppSettingsKeys.downloadAudioFormat) private var audioFormat = DownloadOptions.AudioFormat.m4a
    @AppStorage(AppSettingsKeys.downloadSubtitleSaving) private var subtitleSaving = DownloadOptions.SubtitleSaving.separateFiles
    @AppStorage(AppSettingsKeys.downloadAddsToPlaylist) private var addToPlaylist = true
    @AppStorage(AppSettingsKeys.downloadPlaylistSubtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(AppSettingsKeys.downloadPlaylistOriginalCaptions) private var includesOriginalCaptions = false

    @State private var maxHeight = 0
    /// Indexes into `playlist.entries`. Everything starts selected.
    @State private var selected: Set<Int>
    @State private var wantsLanguages = false

    init(playlist: RemotePlaylist, downloads: DownloadManager, onBack: @escaping () -> Void, onStarted: @escaping () -> Void) {
        self.playlist = playlist
        self.downloads = downloads
        self.onBack = onBack
        self.onStarted = onStarted
        _selected = State(initialValue: Set(playlist.entries.indices))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([playlist.uploader, "\(playlist.entries.count) video\(playlist.entries.count == 1 ? "" : "s")"]
                    .compactMap(\.self).joined(separator: " \u{00B7} "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Form {
                FormatSection(
                    kind: $kind, videoFormat: $videoFormat, maxHeight: $maxHeight, audioFormat: $audioFormat,
                    hasVideo: true, qualities: .unknown
                )

                Section("Subtitles") {
                    Toggle("Subtitles in these languages", isOn: $wantsLanguages)
                    if wantsLanguages {
                        TextField("Language codes", text: $subtitleLanguages, prompt: Text("en, de"))
                        Text("Uploaded subtitles, or YouTube's translations when there are none, for each video that has them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Auto-generated captions in the spoken language", isOn: $includesOriginalCaptions)
                    if kind == .video, wantsLanguages || includesOriginalCaptions {
                        SubtitleSavingPicker(selection: $subtitleSaving)
                    }
                }

                SaveToSection(downloads: downloads, addToPlaylist: $addToPlaylist)

                // Last, so a long playlist doesn't push the options out of reach.
                Section {
                    ForEach(playlist.entries.indices, id: \.self) { index in
                        videoRow(index)
                    }
                } header: {
                    HStack {
                        Text("Videos")
                        Spacer()
                        Button(selected.count == playlist.entries.count ? "Select None" : "Select All") {
                            selected = selected.count == playlist.entries.count ? [] : Set(playlist.entries.indices)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button("Back", action: onBack)
                Spacer()
                Button("Cancel", action: onStarted)
                    .keyboardShortcut(.cancelAction)
                Button(selected.count == 1 ? "Download 1 Video" : "Download \(selected.count) Videos", action: startDownloads)
                    .keyboardShortcut(.defaultAction)
                    .disabled(downloads.destinationFolder == nil || selected.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
        .onAppear { wantsLanguages = !parsedLanguages.isEmpty }
    }

    private func videoRow(_ index: Int) -> some View {
        let entry = playlist.entries[index]
        return Toggle(isOn: Binding(
            get: { selected.contains(index) },
            set: { isOn in
                if isOn { selected.insert(index) } else { selected.remove(index) }
            }
        )) {
            HStack(spacing: 10) {
                Thumbnail(url: entry.thumbnailURL, isVideo: true, width: 64, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let duration = entry.duration {
                        Text(TimeFormatter.string(from: duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    /// "en, de" (or "en de") to ["en", "de"].
    private var parsedLanguages: [String] {
        subtitleLanguages.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    private func startDownloads() {
        var options = DownloadOptions()
        options.kind = kind
        options.videoFormat = videoFormat
        options.maxHeight = maxHeight == 0 ? nil : maxHeight
        options.audioFormat = audioFormat
        options.subtitleLanguages = wantsLanguages ? parsedLanguages : []
        options.includesOriginalLanguageCaptions = includesOriginalCaptions
        options.subtitleSaving = subtitleSaving
        let videos = playlist.entries.indices.filter(selected.contains).map { playlist.entries[$0] }
        downloads.startDownloads(videos, options: options, addToPlaylist: addToPlaylist)
        onStarted()
    }
}

// MARK: - Shared pieces

/// The resolutions to offer: exactly what a video has, or (for a playlist, where each
/// video's aren't known yet) the common ones, used as a maximum.
private enum QualityChoices {
    case known(all: [Int], h264: [Int])
    case unknown

    static let common = [2160, 1440, 1080, 720, 480, 360]
}

/// Video or audio, and the format and quality of each.
private struct FormatSection: View {
    @Binding var kind: DownloadOptions.Kind
    @Binding var videoFormat: DownloadOptions.VideoFormat
    /// 0 means the best available.
    @Binding var maxHeight: Int
    @Binding var audioFormat: DownloadOptions.AudioFormat
    let hasVideo: Bool
    let qualities: QualityChoices

    var body: some View {
        Section("Download") {
            if hasVideo {
                Picker("Save", selection: $kind) {
                    Text("Video").tag(DownloadOptions.Kind.video)
                    Text("Audio Only").tag(DownloadOptions.Kind.audio)
                }
                .pickerStyle(.segmented)
            }

            if hasVideo && kind == .video {
                videoOptions
            } else {
                audioOptions
            }
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        Picker("Format", selection: $videoFormat) {
            ForEach(DownloadOptions.VideoFormat.allCases) { Text($0.label).tag($0) }
        }
        Picker("Quality", selection: $maxHeight) {
            Text(bestLabel).tag(0)
            ForEach(heightChoices, id: \.self) { height in
                Text(isKnown ? qualityName(height) : "Up to \(qualityName(height))").tag(height)
            }
        }
        .onChange(of: videoFormat) { maxHeight = 0 }
        Text(videoFormatNote)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var isKnown: Bool {
        if case .known = qualities { return true }
        return false
    }

    private var bestLabel: String {
        guard case .known = qualities, let best = availableHeights.first else { return "Best Available" }
        return "Best Available (\(qualityName(best)))"
    }

    /// The choices under "Best Available": the rest of a video's own resolutions, or the
    /// common ones for a playlist.
    private var heightChoices: [Int] {
        isKnown ? Array(availableHeights.dropFirst()) : QualityChoices.common
    }

    /// MP4 means H.264, so its choices are the H.264 resolutions, unless the site has none
    /// (then it falls back to whatever the site has, saved as MKV).
    private var availableHeights: [Int] {
        guard case .known(let all, let h264) = qualities else { return QualityChoices.common }
        return videoFormat == .mp4 && !h264.isEmpty ? h264 : all
    }

    private var videoFormatNote: String {
        switch (videoFormat, qualities) {
        case (.mp4, .known(_, let h264)) where h264.isEmpty:
            return "This site doesn't offer H.264 video, so it will be saved as MKV instead."
        case (.mp4, .known(let all, let h264)):
            if let best = all.first, let bestH264 = h264.first, best > bestH264 {
                return "Saved as H.264 so it plays in any app, with thumbnails and AirPlay here. This video goes up to \(qualityName(best)) in other formats; choose MKV for that."
            }
            return "Saved as H.264 so it plays in any app, with thumbnails and AirPlay here."
        case (.mp4, .unknown):
            return "Saved as H.264 so they play in any app, with thumbnails and AirPlay here. YouTube offers H.264 up to 1080p; choose MKV for higher. Videos without H.264 are saved as MKV."
        case (.mkv, _):
            return "Keeps the highest quality the site offers, including 4K and HDR. Plays here through the MKV engine."
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

    private func qualityName(_ height: Int) -> String {
        switch height {
        case 2160...: height == 2160 ? "4K" : "\(height)p"
        case 1440: "1440p (2K)"
        default: "\(height)p"
        }
    }
}

private struct SubtitleSavingPicker: View {
    @Binding var selection: DownloadOptions.SubtitleSaving

    var body: some View {
        Picker("Save Subtitles As", selection: $selection) {
            ForEach(DownloadOptions.SubtitleSaving.allCases) { Text($0.label).tag($0) }
        }
    }
}

private struct SaveToSection: View {
    @ObservedObject var downloads: DownloadManager
    @Binding var addToPlaylist: Bool

    var body: some View {
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
}

private struct Thumbnail: View {
    let url: URL?
    let isVideo: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: isVideo ? "film" : "music.note").foregroundStyle(.secondary))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
