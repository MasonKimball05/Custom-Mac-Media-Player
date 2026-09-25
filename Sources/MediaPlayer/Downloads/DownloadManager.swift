import AppKit
import Foundation

/// Runs yt-dlp downloads and tracks them for the toolbar's Downloads popover.
///
/// yt-dlp writes into a scratch folder inside the app's container, not straight into the
/// destination. The app's access to the user's chosen folder is a security-scoped grant
/// held by this process, and there's no guarantee a child process shares it. The
/// container is always writable, and moving finished files out of it happens here, in
/// the process that holds the grant. It also means a cancelled or failed download never
/// leaves partial files in the user's folder.
@MainActor
final class DownloadManager: ObservableObject {
    struct Job: Identifiable {
        enum State {
            case running
            case finished(mediaFile: URL?, files: [URL])
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let title: String
        let thumbnailURL: URL?
        var state: State = .running
        var stage = "Starting"
        /// nil while the current stage has no measurable progress.
        var fraction: Double?

        var isRunning: Bool {
            if case .running = state { return true }
            return false
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var destinationFolder: URL?

    /// Called with a finished download's media file when "Add to playlist" was on.
    var onAddToPlaylist: ((URL) -> Void)?

    private var processes: [Job.ID: Process] = [:]
    private var cancelledJobs: Set<Job.ID> = []
    private var accessedFolder: URL?

    var hasRunningJobs: Bool { jobs.contains(where: \.isRunning) }

    /// Average progress across running downloads, for the toolbar icon.
    var overallFraction: Double? {
        let running = jobs.filter(\.isRunning)
        guard !running.isEmpty else { return nil }
        return running.map { $0.fraction ?? 0 }.reduce(0, +) / Double(running.count)
    }

    init() {
        restoreDestinationFolder()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    // MARK: Destination folder

    /// Asks for the folder downloads are saved to. It's remembered (as a security-scoped
    /// bookmark) until changed.
    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where downloads are saved."
        panel.directoryURL = destinationFolder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: AppSettingsKeys.downloadFolderBookmark)
        useFolder(url, alreadyAccessible: true)
    }

    private func restoreDestinationFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: AppSettingsKeys.downloadFolderBookmark) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return }
        useFolder(url, alreadyAccessible: false)
        if isStale, let refreshed = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: AppSettingsKeys.downloadFolderBookmark)
        }
    }

    /// Access to the folder stays open for the life of the app. Files moved into it are
    /// played and bookmarked into the playlist through that access.
    private func useFolder(_ url: URL, alreadyAccessible: Bool) {
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
        // A folder the open panel just returned is accessible without this call, but
        // starting access anyway keeps it open once the panel's own grant lapses.
        if url.startAccessingSecurityScopedResource() {
            accessedFolder = url
        } else if !alreadyAccessible {
            return
        }
        destinationFolder = url
    }

    // MARK: Jobs

    func startDownload(info: RemoteMediaInfo, options: DownloadOptions, addToPlaylist: Bool) {
        guard let destination = destinationFolder else { return }
        let job = Job(title: info.title, thumbnailURL: info.thumbnailURL)
        jobs.insert(job, at: 0)

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            update(job.id) { $0.state = .failed("Couldn't create a working folder: \(error.localizedDescription)") }
            return
        }

        let process = YTDLP.makeProcess(arguments: options.arguments(url: info.sourceURL, outputDirectory: workDirectory))
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = LineSplitter()
        let jobID = job.id
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let newLines = lines.append(handle.availableData)
            guard !newLines.isEmpty else { return }
            Task { @MainActor in self?.handleOutput(newLines, for: jobID) }
        }
        let errorOutput = OutputCollector()
        stderr.fileHandleForReading.readabilityHandler = { errorOutput.appendError($0.availableData) }

        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            errorOutput.appendError(stderr.fileHandleForReading.readDataToEndOfFile())
            let status = process.terminationStatus
            let message = YTDLP.errorMessage(from: String(decoding: errorOutput.contents.1, as: UTF8.self))
            Task { @MainActor in
                self?.finish(jobID, status: status, errorMessage: message, workDirectory: workDirectory,
                             destination: destination, options: options, addToPlaylist: addToPlaylist)
            }
        }

        do {
            try process.run()
            processes[jobID] = process
        } catch {
            update(jobID) { $0.state = .failed("Couldn't start yt-dlp: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    func cancel(_ id: Job.ID) {
        guard let process = processes[id], process.isRunning else { return }
        cancelledJobs.insert(id)
        update(id) { $0.stage = "Cancelling" }
        // SIGINT lets yt-dlp stop its own ffmpeg children and clean up; SIGTERM if it
        // hasn't exited shortly after.
        process.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { process.terminate() }
        }
    }

    func remove(_ id: Job.ID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.isRunning else { return }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }

    private func terminateAll() {
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    private func handleOutput(_ lines: [String], for id: Job.ID) {
        guard !cancelledJobs.contains(id) else { return }
        for line in lines {
            if let progress = DownloadProgressLine(line) {
                update(id) { job in
                    job.fraction = progress.fraction
                    switch progress.stream {
                    case .video: job.stage = "Downloading video"
                    case .audio: job.stage = "Downloading audio"
                    // Subtitle files, which the "Downloading subtitles" stage already covers.
                    case .other: break
                    }
                }
            } else if let stage = DownloadProgressLine.stageDescription(for: line) {
                update(id) { job in
                    job.stage = stage
                    job.fraction = nil
                }
            } else if line.hasPrefix("[info]"), line.contains("Downloading subtitles") {
                update(id) { $0.stage = "Downloading subtitles" }
            }
        }
    }

    private func finish(_ id: Job.ID, status: Int32, errorMessage: String?, workDirectory: URL,
                        destination: URL, options: DownloadOptions, addToPlaylist: Bool) {
        processes[id] = nil
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        if cancelledJobs.remove(id) != nil {
            update(id) { $0.state = .cancelled }
            return
        }
        guard status == 0 else {
            update(id) { $0.state = .failed(errorMessage ?? "yt-dlp stopped with an error (exit code \(status)).") }
            return
        }

        do {
            let files = try moveResults(from: workDirectory, to: destination, keepSubtitleFiles: options.keepsSubtitleFiles)
            let mediaFile = files.first(where: MediaFormat.isSupportedFile)
            update(id) { job in
                job.state = .finished(mediaFile: mediaFile, files: files)
                job.fraction = 1
            }
            if addToPlaylist, let mediaFile {
                onAddToPlaylist?(mediaFile)
            }
        } catch {
            update(id) { $0.state = .failed("Downloaded, but couldn't save to \u{201C}\(destination.lastPathComponent)\u{201D}: \(error.localizedDescription)") }
        }
    }

    /// Moves everything yt-dlp left in `source` into `destination` and returns the moved
    /// files' new locations. On a name clash, the whole set is renamed together ("Title
    /// [id] 2.mp4" with "Title [id] 2.en.srt") rather than just the clashing file, so the
    /// subtitles still pair up with their video by name.
    private func moveResults(from source: URL, to destination: URL, keepSubtitleFiles: Bool) throws -> [URL] {
        let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "ttml", "srv1", "srv2", "srv3", "json3"]
        let leftovers: Set<String> = ["part", "ytdl", "temp", "tmp"]
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { file in
                let ext = file.pathExtension.lowercased()
                return !leftovers.contains(ext) && (keepSubtitleFiles || !subtitleExtensions.contains(ext))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "yt-dlp finished without producing a file."])
        }

        // Every file yt-dlp writes for one video starts with the media file's name.
        let stem = (files.first(where: MediaFormat.isSupportedFile) ?? files[0]).deletingPathExtension().lastPathComponent
        func name(for file: URL, counter: Int) -> String {
            let fileName = file.lastPathComponent
            guard counter > 1, fileName.hasPrefix(stem) else { return fileName }
            return "\(stem) \(counter)" + fileName.dropFirst(stem.count)
        }
        var counter = 1
        while files.contains(where: { FileManager.default.fileExists(atPath: destination.appendingPathComponent(name(for: $0, counter: counter)).path) }) {
            counter += 1
        }

        return try files.map { file in
            // YouTube's automatic captions come out of yt-dlp as stacked, scrolling pairs
            // of lines; fixed here so the saved files play properly in any player.
            RollUpCaptions.fixInPlace(file)
            let target = destination.appendingPathComponent(name(for: file, counter: counter))
            try FileManager.default.moveItem(at: file, to: target)
            return target
        }
    }

    private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
}

/// Splits a pipe's output into lines as chunks arrive, holding back a trailing partial
/// line until the rest of it shows up. Called from the pipe's reading thread.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            guard let lastNewline = pending.lastIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) else {
                return []
            }
            let complete = pending[..<lastNewline]
            pending = Data(pending[pending.index(after: lastNewline)...])
            return String(decoding: complete, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        }
    }
}
