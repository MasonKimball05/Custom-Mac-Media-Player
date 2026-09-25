import Foundation

/// Runs the user's Homebrew install of yt-dlp. Like libmpv, yt-dlp isn't bundled: it
/// updates far more often than this app does (sites change constantly), and `brew upgrade`
/// keeps it current. Reaching it from inside the App Sandbox takes a read-only exception
/// for `/opt/homebrew/` (see project.yml); child processes inherit the app's sandbox.
enum YTDLP {
    static let homebrewBin = URL(fileURLWithPath: "/opt/homebrew/bin")
    static let executableURL = homebrewBin.appendingPathComponent("yt-dlp")
    static let ffmpegURL = homebrewBin.appendingPathComponent("ffmpeg")

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executableURL.path) }
    static var isFFmpegInstalled: Bool { FileManager.default.isExecutableFile(atPath: ffmpegURL.path) }

    /// A launch-ready process. PATH is set explicitly: an app started from Finder gets a
    /// minimal PATH, and yt-dlp looks there for ffmpeg and for the JavaScript runtime
    /// (deno) it needs to get past YouTube's player challenges.
    static func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        // --ignore-config: the user's own yt-dlp config (if any) shouldn't change what the
        // options sheet promised. It isn't readable from the sandbox anyway.
        process.arguments = ["--ignore-config", "--no-playlist"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(homebrewBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        return process
    }

    enum FetchError: LocalizedError {
        case notInstalled
        case failed(String)
        case playlist

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "yt-dlp isn't installed. Install it with Homebrew (brew install yt-dlp), then try again."
            case .failed(let message):
                message
            case .playlist:
                "That link is a playlist or channel. Paste the link to a single video instead."
            }
        }
    }

    /// Asks yt-dlp what's at `url` (title, available qualities, subtitles) without
    /// downloading anything.
    static func fetchInfo(for url: String) async throws -> RemoteMediaInfo {
        guard isInstalled else { throw FetchError.notInstalled }
        let process = makeProcess(arguments: ["--flat-playlist", "--no-warnings", "-J", "--", url])
        let (status, output, errorOutput) = try await run(process)
        guard status == 0 else {
            throw FetchError.failed(errorMessage(from: errorOutput) ?? "yt-dlp couldn't read that link.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw FetchError.failed("yt-dlp returned information this app couldn't read.")
        }
        if let type = json["_type"] as? String, type != "video" {
            throw FetchError.playlist
        }
        return RemoteMediaInfo(json: json, sourceURL: url)
    }

    /// Runs `process` to completion, collecting stdout and stderr. Both pipes are drained
    /// as data arrives, since a full pipe would block yt-dlp and never let it exit.
    /// Cancelling the calling task terminates the process.
    private static func run(_ process: Process) async throws -> (Int32, Data, String) {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { collector.appendOutput($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { collector.appendError($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    // Whatever arrived after the last readability callback.
                    collector.appendOutput(stdout.fileHandleForReading.readDataToEndOfFile())
                    collector.appendError(stderr.fileHandleForReading.readDataToEndOfFile())
                    let (output, error) = collector.contents
                    continuation.resume(returning: (process.terminationStatus, output, String(decoding: error, as: UTF8.self)))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: FetchError.failed("Couldn't start yt-dlp: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// The last `ERROR:` line yt-dlp printed, without its prefixes.
    static func errorMessage(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ERROR:") }) else {
            return nil
        }
        var message = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        // "[youtube] abc123: Video unavailable" → "Video unavailable"
        if message.hasPrefix("["), let range = message.range(of: ": ") {
            message = String(message[range.upperBound...])
        }
        return message
    }
}

/// Thread-safe byte buffers for a process's stdout and stderr, whose pipes report on
/// arbitrary threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func appendOutput(_ data: Data) { lock.withLock { output.append(data) } }
    func appendError(_ data: Data) { lock.withLock { error.append(data) } }
    var contents: (Data, Data) { lock.withLock { (output, error) } }
}

/// What yt-dlp reported about a link, trimmed to what the options sheet shows.
struct RemoteMediaInfo {
    struct Subtitle: Identifiable, Hashable {
        let code: String
        let name: String
        /// Generated by the site (YouTube's auto-captions) rather than uploaded.
        let isAutomatic: Bool
        /// An automatic caption in the language actually spoken, as opposed to a machine
        /// translation of it (YouTube marks these "-orig").
        var isOriginalLanguage: Bool { code.hasSuffix("-orig") }
        var id: String { (isAutomatic ? "auto:" : "subs:") + code }
    }

    let sourceURL: String
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnailURL: URL?
    let hasVideo: Bool
    /// Distinct video heights on offer, highest first.
    let videoHeights: [Int]
    /// The same, for H.264 video only: what the MP4 option can deliver.
    let h264Heights: [Int]
    let subtitles: [Subtitle]
    let automaticCaptions: [Subtitle]

    init(json: [String: Any], sourceURL: String) {
        self.sourceURL = (json["webpage_url"] as? String) ?? sourceURL
        title = (json["title"] as? String) ?? "Untitled"
        uploader = (json["uploader"] as? String) ?? (json["channel"] as? String)
        duration = json["duration"] as? Double
        thumbnailURL = (json["thumbnail"] as? String).flatMap(URL.init(string:))

        let formats = (json["formats"] as? [[String: Any]]) ?? [json]
        let videoFormats = formats.filter { format in
            if let vcodec = format["vcodec"] as? String { return vcodec != "none" }
            return format["height"] is Int
        }
        hasVideo = !videoFormats.isEmpty
        videoHeights = Set(videoFormats.compactMap { $0["height"] as? Int }).sorted(by: >)
        h264Heights = Set(videoFormats.filter { ($0["vcodec"] as? String)?.hasPrefix("avc") == true }
            .compactMap { $0["height"] as? Int }).sorted(by: >)

        subtitles = Self.parseSubtitles(json["subtitles"], isAutomatic: false)
        automaticCaptions = Self.parseSubtitles(json["automatic_captions"], isAutomatic: true)
    }

    private static func parseSubtitles(_ value: Any?, isAutomatic: Bool) -> [Subtitle] {
        guard let byLanguage = value as? [String: [[String: Any]]] else { return [] }
        return byLanguage.compactMap { code, tracks in
            // YouTube lists a live stream's chat replay among the subtitles.
            guard code != "live_chat", !tracks.isEmpty else { return nil }
            let isOriginal = code.hasSuffix("-orig")
            let baseCode = isOriginal ? String(code.dropLast("-orig".count)) : code
            // YouTube names original-language tracks "Greek (Original)"; the options sheet
            // says that its own way, so those use the plain language name.
            let siteName = isOriginal ? nil : tracks.first?["name"] as? String
            let name = siteName
                ?? Locale.current.localizedString(forIdentifier: baseCode)
                ?? code
            return Subtitle(code: code, name: name, isAutomatic: isAutomatic)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Everything the options sheet asks, turned into yt-dlp arguments by `arguments`.
struct DownloadOptions {
    enum Kind: String, CaseIterable, Identifiable {
        case video, audio
        var id: String { rawValue }
    }

    enum VideoFormat: String, CaseIterable, Identifiable {
        case mp4, mkv
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mp4: "MP4"
            case .mkv: "MKV"
            }
        }
    }

    enum AudioFormat: String, CaseIterable, Identifiable {
        case m4a, mp3, opus, flac, wav
        var id: String { rawValue }
        var label: String {
            switch self {
            case .m4a: "M4A (AAC)"
            case .mp3: "MP3"
            case .opus: "Opus"
            case .flac: "FLAC"
            case .wav: "WAV"
            }
        }
        /// WAV has nowhere to put cover art.
        var supportsCoverArt: Bool { self != .wav }
    }

    enum SubtitleSaving: String, CaseIterable, Identifiable {
        case separateFiles, embedded, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .separateFiles: "Separate .srt Files"
            case .embedded: "Embedded in the Video"
            case .both: "Both"
            }
        }
    }

    var kind: Kind = .video
    var videoFormat: VideoFormat = .mp4
    /// nil means the best available.
    var maxHeight: Int?
    var audioFormat: AudioFormat = .m4a
    var subtitles: Set<RemoteMediaInfo.Subtitle> = []
    var subtitleSaving: SubtitleSaving = .separateFiles

    /// Whether subtitle files should be left next to the media once yt-dlp is done.
    var keepsSubtitleFiles: Bool { kind == .audio || subtitleSaving != .embedded }

    func arguments(url: String, outputDirectory: URL) -> [String] {
        var arguments = [
            "--newline", "--progress",
            "--progress-template", DownloadProgressLine.template,
            // Modification time = when it was downloaded, not the upload date, so new
            // downloads sort as new in Finder.
            "--no-mtime",
            "--embed-metadata",
            "-P", outputDirectory.path,
            // The "Title [id].ext" naming yt-dlp uses by default, with the title capped so
            // a very long one can't exceed the file system's name limit.
            "-o", "%(title).180B [%(id)s].%(ext)s",
        ]

        switch kind {
        case .video:
            let height = maxHeight.map { "[height<=?\($0)]" } ?? ""
            switch videoFormat {
            case .mp4:
                // H.264 + AAC first: that's what AVFoundation (and so thumbnails, AirPlay,
                // and every other app) can play, even when a higher resolution exists in
                // another codec. Sites without H.264 fall through to the best they have,
                // and `mp4/mkv` then picks MKV for codecs MP4 can't hold.
                arguments += [
                    "-f", "bv*\(height)[vcodec^=avc]+ba[ext=m4a]/bv*\(height)[vcodec^=avc]+ba/b\(height)[ext=mp4]/bv*\(height)+ba/b\(height)/bv*+ba/b",
                    "--merge-output-format", "mp4/mkv",
                ]
            case .mkv:
                arguments += [
                    "-f", "bv*\(height)+ba/b\(height)/bv*+ba/b",
                    "--merge-output-format", "mkv",
                ]
            }
        case .audio:
            arguments += ["-f", "ba/b", "-x", "--audio-format", audioFormat.rawValue, "--audio-quality", "0"]
            if audioFormat.supportsCoverArt {
                arguments.append("--embed-thumbnail")
            }
        }

        if !subtitles.isEmpty {
            if subtitles.contains(where: { !$0.isAutomatic }) { arguments.append("--write-subs") }
            if subtitles.contains(where: \.isAutomatic) { arguments.append("--write-auto-subs") }
            // --sub-langs takes regular expressions, each matched against the whole code.
            let languages = Set(subtitles.map(\.code)).sorted().map(NSRegularExpression.escapedPattern(for:))
            arguments += [
                "--sub-langs", languages.joined(separator: ","),
                "--sub-format", "srt/vtt/best",
                "--convert-subs", "srt",
            ]
            if kind == .video, subtitleSaving != .separateFiles {
                arguments.append("--embed-subs")
            }
        }

        return arguments + ["--", url]
    }
}

/// One line of yt-dlp's progress output, in the format `template` asks for.
struct DownloadProgressLine {
    static let marker = "MPDL|"
    static let template = "download:\(marker)%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(info.vcodec)s|%(info.acodec)s"

    enum Stream { case video, audio, other }

    let fraction: Double?
    let stream: Stream

    init?(_ line: String) {
        guard line.hasPrefix(Self.marker) else { return nil }
        let fields = line.dropFirst(Self.marker.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return nil }
        let downloaded = Double(fields[1])
        let total = Double(fields[2]) ?? Double(fields[3])
        if fields[0] == "finished" {
            fraction = 1
        } else if let downloaded, let total, total > 0 {
            fraction = min(1, downloaded / total)
        } else {
            fraction = nil
        }
        let (vcodec, acodec) = (fields[4], fields[5])
        if vcodec != "none", vcodec != "NA" {
            stream = .video
        } else if acodec != "none", acodec != "NA" {
            stream = .audio
        } else {
            stream = .other
        }
    }

    /// A readable description of a yt-dlp status line that starts with a post-processor
    /// tag ("[Merger] Merging formats into ..."), or nil for lines that aren't one.
    static func stageDescription(for line: String) -> String? {
        let stages = [
            "[Merger]": "Combining video and audio",
            "[ExtractAudio]": "Converting audio",
            "[SubtitlesConvertor]": "Converting subtitles",
            "[EmbedSubtitle]": "Embedding subtitles",
            "[Metadata]": "Adding details",
            "[EmbedThumbnail]": "Adding cover art",
            "[ThumbnailsConvertor]": "Adding cover art",
            "[VideoRemuxer]": "Repackaging video",
            "[FixupM3u8]": "Finishing up",
            "[FixupM4a]": "Finishing up",
        ]
        return stages.first { line.hasPrefix($0.key) }?.value
    }
}
