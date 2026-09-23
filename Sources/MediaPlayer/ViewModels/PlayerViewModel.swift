import AppKit
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

/// The playback state that changes ~10 times a second — split out of PlayerViewModel so
/// those ticks only redraw views that actually display a clock. Published on the view
/// model itself, every tick re-rendered everything observing it: the whole window, the
/// app's menu-bar commands, and every open menu's ancestors, which made open menus
/// (captions, playback speed) visibly flicker for as long as something was playing.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    @Published fileprivate(set) var bufferedFraction: Double = 0
}

/// Drives playback and exposes everything the custom UI needs as published state.
/// This is the single source of truth views bind to — internally it delegates to
/// whichever PlaybackEngine the current item needs (AVFoundation for everything it can
/// open natively, mpv for MKV/AVI/etc.) and republishes that engine's state, so the
/// view layer never has to know or care which engine is actually running.
@MainActor
final class PlayerViewModel: NSObject, ObservableObject, PlaybackEngineDelegate {

    // MARK: Published UI state

    @Published private(set) var playlist: [MediaItem] = []
    @Published private(set) var currentItemID: MediaItem.ID?

    /// The library of named, user-saved playlists you can switch to — separate from
    /// `playlist` above, which is just "whatever's in the queue right now" and
    /// auto-restores every launch on its own regardless of whether it's saved anywhere.
    @Published private(set) var savedPlaylists: [SavedPlaylist] = []
    @Published private(set) var activeSavedPlaylistID: UUID?

    /// File ▸ Open Recent, most-recently-opened first, capped at 10.
    @Published private(set) var recentFiles: [RecentFile] = []

    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLoading = false

    /// Observe this (not the view model) for anything that needs to redraw as time
    /// passes — see PlaybackClock. The two properties below just forward to it, so
    /// reading the current time from anywhere else is unchanged.
    let clock = PlaybackClock()

    private(set) var currentTime: Double {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }

    private(set) var bufferedFraction: Double {
        get { clock.bufferedFraction }
        set { clock.bufferedFraction = newValue }
    }

    /// Republished only when playback crosses into a different chapter, so the chapter
    /// checkmark in the captions menu stays current without the menu watching the clock.
    @Published private(set) var currentChapterID: Chapter.ID?
    private var chapters: [Chapter] = []
    @Published private(set) var isVideoTrackPresent = true
    @Published private(set) var activeEngineKind: PlaybackEngineKind = .avFoundation
    @Published var errorMessage: String?

    @Published var volume: Float = AppSettingsDefaults.volume {
        didSet {
            activeEngine.setVolume(volume, muted: isMuted)
            UserDefaults.standard.set(volume, forKey: AppSettingsKeys.lastVolume)
        }
    }
    @Published var isMuted = false {
        didSet {
            activeEngine.setVolume(volume, muted: isMuted)
            UserDefaults.standard.set(isMuted, forKey: AppSettingsKeys.lastMuted)
        }
    }
    @Published var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { activeEngine.setRate(playbackRate) }
        }
    }

    // MARK: Video adjustments (mpv-style -100...100, 0 = no change)

    @Published var videoBrightness: Double = AppSettingsDefaults.videoAdjustment {
        didSet {
            applyVideoAdjustments()
            UserDefaults.standard.set(videoBrightness, forKey: AppSettingsKeys.videoBrightness)
        }
    }
    @Published var videoContrast: Double = AppSettingsDefaults.videoAdjustment {
        didSet {
            applyVideoAdjustments()
            UserDefaults.standard.set(videoContrast, forKey: AppSettingsKeys.videoContrast)
        }
    }
    @Published var videoSaturation: Double = AppSettingsDefaults.videoAdjustment {
        didSet {
            applyVideoAdjustments()
            UserDefaults.standard.set(videoSaturation, forKey: AppSettingsKeys.videoSaturation)
        }
    }
    @Published var videoGamma: Double = AppSettingsDefaults.videoAdjustment {
        didSet {
            applyVideoAdjustments()
            UserDefaults.standard.set(videoGamma, forKey: AppSettingsKeys.videoGamma)
        }
    }

    // MARK: Subtitle appearance (only meaningful when currentEngineCapabilities.subtitleAppearance)

    @Published var subtitleFontName: String = AppSettingsDefaults.subtitleFontName {
        didSet {
            applySubtitleAppearance()
            UserDefaults.standard.set(subtitleFontName, forKey: AppSettingsKeys.subtitleFontName)
        }
    }
    @Published var subtitleTextColorHex: String = AppSettingsDefaults.subtitleTextColorHex {
        didSet {
            applySubtitleAppearance()
            UserDefaults.standard.set(subtitleTextColorHex, forKey: AppSettingsKeys.subtitleTextColorHex)
        }
    }
    @Published var subtitleBackgroundColorHex: String = AppSettingsDefaults.subtitleBackgroundColorHex {
        didSet {
            applySubtitleAppearance()
            UserDefaults.standard.set(subtitleBackgroundColorHex, forKey: AppSettingsKeys.subtitleBackgroundColorHex)
        }
    }
    @Published var subtitleBackgroundOpacity: Double = AppSettingsDefaults.subtitleBackgroundOpacity {
        didSet {
            applySubtitleAppearance()
            UserDefaults.standard.set(subtitleBackgroundOpacity, forKey: AppSettingsKeys.subtitleBackgroundOpacity)
        }
    }
    /// Overrides mpv's charset auto-detection for the loaded subtitle file — empty means
    /// "auto." Fixes a legacy-encoded (non-UTF-8) file the auto-detector guessed wrong on.
    @Published var subtitleCodepage: String = AppSettingsDefaults.subtitleCodepage {
        didSet {
            applySubtitleAppearance()
            UserDefaults.standard.set(subtitleCodepage, forKey: AppSettingsKeys.subtitleCodepage)
        }
    }

    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false {
        didSet { regenerateShuffleOrder() }
    }

    /// True while the user is actively dragging the scrubber — pauses time-label churn
    /// from the engine's periodic updates so the thumb doesn't fight the drag.
    @Published var isScrubbing = false

    var currentItem: MediaItem? {
        playlist.first { $0.id == currentItemID }
    }

    /// True when the current item is playing through mpv rather than AVFoundation —
    /// the view layer uses this to pick which video-rendering surface to show.
    var usesMPVEngine: Bool { activeEngineKind == .mpv }

    /// What the currently active engine can actually do — the UI uses this to show/hide
    /// controls (external subtitles, delay/scale) instead of offering a silent no-op.
    var currentEngineCapabilities: EngineCapabilities { activeEngine.capabilities }

    // MARK: Engines

    /// Exposed for VideoLayerView, which needs the underlying AVPlayer to build its AVPlayerLayer.
    var player: AVPlayer { avEngine.player }
    private let avEngine = AVFoundationEngine()

    /// Created lazily so apps that never open an MKV/AVI/etc. never pay mpv's startup cost.
    /// Exposed for MPVVideoView, which needs it to create/drive its render context.
    private(set) lazy var mpvEngine: MPVEngine = {
        let engine = MPVEngine()
        engine.delegate = self
        return engine
    }()

    private var activeEngine: PlaybackEngine {
        activeEngineKind == .mpv ? mpvEngine : avEngine
    }

    private var lastSessionSaveDate = Date.distantPast

    /// URLs currently holding an active security-scoped bookmark grant — tracked so we
    /// start access at most once per URL (a file can appear in the current queue, a saved
    /// playlist, and Open Recent all at once) and can release it once nothing needs it live.
    private var securityScopedURLs = Set<URL>()

    override init() {
        super.init()
        avEngine.delegate = self

        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettingsKeys.lastVolume) != nil {
            volume = defaults.float(forKey: AppSettingsKeys.lastVolume)
        }
        isMuted = defaults.bool(forKey: AppSettingsKeys.lastMuted)

        if defaults.object(forKey: AppSettingsKeys.videoBrightness) != nil {
            videoBrightness = defaults.double(forKey: AppSettingsKeys.videoBrightness)
        }
        if defaults.object(forKey: AppSettingsKeys.videoContrast) != nil {
            videoContrast = defaults.double(forKey: AppSettingsKeys.videoContrast)
        }
        if defaults.object(forKey: AppSettingsKeys.videoSaturation) != nil {
            videoSaturation = defaults.double(forKey: AppSettingsKeys.videoSaturation)
        }
        if defaults.object(forKey: AppSettingsKeys.videoGamma) != nil {
            videoGamma = defaults.double(forKey: AppSettingsKeys.videoGamma)
        }
        if let storedFontName = defaults.string(forKey: AppSettingsKeys.subtitleFontName) {
            subtitleFontName = storedFontName
        }
        if let storedTextColor = defaults.string(forKey: AppSettingsKeys.subtitleTextColorHex) {
            subtitleTextColorHex = storedTextColor
        }
        if let storedBackgroundColor = defaults.string(forKey: AppSettingsKeys.subtitleBackgroundColorHex) {
            subtitleBackgroundColorHex = storedBackgroundColor
        }
        if defaults.object(forKey: AppSettingsKeys.subtitleBackgroundOpacity) != nil {
            subtitleBackgroundOpacity = defaults.double(forKey: AppSettingsKeys.subtitleBackgroundOpacity)
        }
        if let storedCodepage = defaults.string(forKey: AppSettingsKeys.subtitleCodepage) {
            subtitleCodepage = storedCodepage
        }

        loadSavedPlaylistsLibrary()
        loadRecentFiles()
        restoreSession()
        setUpNowPlayingCommands()

        // Best-effort final save on normal quit, on top of the throttled periodic save
        // in engineDidUpdateTime — catches whatever's happened in the last few seconds
        // before Cmd+Q. Won't fire on a crash/force-quit, same as any app's autosave.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees this runs on the main thread, but the compiler
            // can't see that through NotificationCenter's nonisolated closure type —
            // assumeIsolated tells it what's already true instead of hopping to a
            // Task, which could get cut off by process exit before it runs.
            MainActor.assumeIsolated {
                self?.persistSession()
            }
        }
    }

    // MARK: Playlist management

    /// Adding files always starts playing the first newly-added item immediately —
    /// like every other media player. The rest queue up right after it in the
    /// playlist, reachable via Next Track / the sidebar, rather than playing silently
    /// in the background or (worse) never playing until you dig into the sidebar.
    func addFiles(_ urls: [URL]) {
        let newItems = urls
            .filter { $0.isFileURL }
            .map { MediaItem(url: $0) }
        guard let first = newItems.first else { return }

        playlist.append(contentsOf: newItems)
        play(item: first)
        regenerateShuffleOrder()
        persistSession()
        newItems.forEach(recordRecentFile)
    }

    /// Adds and immediately plays a direct stream URL (http/https/rtsp/etc.) rather than
    /// a local file — VLC's "Open Network Stream". Requires the network client
    /// entitlement, since this app is otherwise sandboxed to user-selected local files.
    func playNetworkStream(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = "That doesn't look like a valid URL."
            return
        }
        let item = MediaItem(url: url)
        playlist.append(item)
        play(item: item)
        regenerateShuffleOrder()
        persistSession()
        recordRecentFile(item)
    }

    func removeItem(_ item: MediaItem) {
        removeItems([item.id])
    }

    func removeItems(_ ids: Set<MediaItem.ID>) {
        guard !ids.isEmpty else { return }
        let removedURLs = playlist.filter { ids.contains($0.id) }.map(\.url)
        playlist.removeAll { ids.contains($0.id) }
        shuffleOrder.removeAll { ids.contains($0) }
        if let currentItemID, ids.contains(currentItemID) {
            resetPlaybackState()
        }
        persistSession()
        releaseSecurityScopedAccessIfUnused(removedURLs)
    }

    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        playlist.move(fromOffsets: source, toOffset: destination)
        persistSession()
    }

    func clearPlaylist() {
        let removedURLs = playlist.map(\.url)
        playlist.removeAll()
        shuffleOrder.removeAll()
        resetPlaybackState()
        persistSession()
        releaseSecurityScopedAccessIfUnused(removedURLs)
    }

    /// Stops the active engine and clears "what's playing" state — shared by every path
    /// that empties or replaces the current queue, so they can't drift out of sync with
    /// each other (one of them missing the Now Playing refresh, say) the way they used to.
    private func resetPlaybackState() {
        activeEngine.stop()
        currentItemID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        chapters = []
        currentChapterID = nil
        updateNowPlayingInfo()
    }

    /// `resumeAt: nil` (the default for every caller except session restore, which already
    /// knows exactly where it left off) looks up a remembered per-file position instead —
    /// see "Per-file resume position" below. Pass `0` explicitly to force starting over.
    func play(item: MediaItem, resumeAt: Double? = nil, autoPlay: Bool = true) {
        // Already loaded — e.g. clicking the currently-playing item again in the sidebar,
        // or its own Continue Watching card while it's the current item. Reloading would
        // restart it from the last periodically-saved resume position, which lags real
        // playback by up to the save throttle's few seconds — that reads as a second copy
        // that jumped backward, not as "still playing the one you already had going."
        if item.id == currentItemID, resumeAt == nil {
            if autoPlay, !isPlaying {
                activeEngine.play()
                isPlaying = true
                updateNowPlayingInfo()
            }
            return
        }

        let startPosition = resumeAt ?? storedResumePosition(for: item.url)
        errorMessage = nil
        isLoading = true
        currentItemID = item.id
        currentTime = startPosition
        duration = 0
        bufferedFraction = 0
        loopPointA = nil
        loopPointB = nil
        chapters = []
        currentChapterID = nil

        let requiredEngineKind = MediaFormat.requiredEngine(for: item.url)
        if requiredEngineKind != activeEngineKind {
            activeEngine.stop()
        }
        activeEngineKind = requiredEngineKind

        activeEngine.load(url: item.url)
        activeEngine.setVolume(volume, muted: isMuted)
        activeEngine.setRate(playbackRate)
        // Re-synced on every play(), not just when they change — switching from an
        // AVFoundation- to an mpv-backed item (or back) lands on a different engine
        // instance, and that instance has never heard these values before.
        applyVideoAdjustments()
        applySubtitleAppearance()
        if startPosition > 0 { activeEngine.seek(to: startPosition) }
        if autoPlay {
            activeEngine.play()
        } else {
            activeEngine.pause()
        }
        isPlaying = autoPlay
        persistSession()
        updateNowPlayingInfo()
    }

    func playNext() {
        if let next = item(after: currentItemID) {
            play(item: next)
        } else if repeatMode == .all, let first = orderedPlaylist.first {
            play(item: first)
        } else {
            isPlaying = false
        }
    }

    func playPrevious() {
        guard currentItemID != nil else { return }
        // Restart current track if we're more than 3s in, like most players.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if let previous = item(before: currentItemID) {
            play(item: previous)
        }
    }

    // MARK: Shuffle

    /// Playback order honoring shuffle — the sidebar's displayed order never changes,
    /// only Next/Previous/repeat-all navigation follows this.
    private var orderedPlaylist: [MediaItem] {
        guard isShuffled else { return playlist }
        return shuffleOrder.compactMap { id in playlist.first { $0.id == id } }
    }

    private var shuffleOrder: [MediaItem.ID] = []

    private func regenerateShuffleOrder() {
        guard isShuffled else { shuffleOrder = []; return }
        var ids = playlist.map(\.id)
        ids.shuffle()
        // Keep whatever's currently playing first, so toggling shuffle on mid-playback
        // doesn't immediately yank you somewhere else.
        if let currentItemID, let idx = ids.firstIndex(of: currentItemID) {
            ids.swapAt(0, idx)
        }
        shuffleOrder = ids
    }

    private func item(after id: MediaItem.ID?) -> MediaItem? {
        let order = orderedPlaylist
        guard let id, let idx = order.firstIndex(where: { $0.id == id }) else { return nil }
        let nextIndex = idx + 1
        return order.indices.contains(nextIndex) ? order[nextIndex] : nil
    }

    private func item(before id: MediaItem.ID?) -> MediaItem? {
        let order = orderedPlaylist
        guard let id, let idx = order.firstIndex(where: { $0.id == id }) else { return nil }
        let previousIndex = idx - 1
        return order.indices.contains(previousIndex) ? order[previousIndex] : nil
    }

    // MARK: Transport controls

    func togglePlayPause() {
        if isPlaying {
            activeEngine.pause()
        } else {
            activeEngine.setRate(playbackRate)
            activeEngine.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        activeEngine.seek(to: clamped)
        currentTime = clamped
        updateNowPlayingInfo()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    // MARK: A–B loop

    @Published private(set) var loopPointA: Double?
    @Published private(set) var loopPointB: Double?

    var isLoopActive: Bool { loopPointA != nil && loopPointB != nil }

    /// Marks the loop start at the current position. Clears B if it's no longer after
    /// the new A, same as scrubbing past your own loop-out point would invalidate it.
    func setLoopPointA() {
        loopPointA = currentTime
        if let b = loopPointB, b <= currentTime {
            loopPointB = nil
        }
    }

    /// Marks the loop end and activates looping — needs an A already set and after it,
    /// otherwise there's nothing sensible to loop.
    func setLoopPointB() {
        guard let a = loopPointA, currentTime > a else { return }
        loopPointB = currentTime
    }

    func clearLoop() {
        loopPointA = nil
        loopPointB = nil
    }

    // MARK: PlaybackEngineDelegate

    func engineDidUpdateTime(_ seconds: Double) {
        guard !isScrubbing else { return }

        if let a = loopPointA, let b = loopPointB, seconds >= b {
            seek(to: a)
            return
        }

        currentTime = seconds
        updateCurrentChapter()

        // Throttled: this fires ~10x/sec, but "where you were" only needs second-ish
        // granularity, and writing to UserDefaults (or resyncing Control Center) that
        // often would be wasteful — Control Center interpolates elapsed time on its own
        // between updates anyway, based on the rate we last gave it.
        let now = Date()
        if now.timeIntervalSince(lastSessionSaveDate) > 5 {
            lastSessionSaveDate = now
            persistSession()
            recordFileResumePosition()
            updateNowPlayingInfo()
        }
    }

    func engineDidUpdateDuration(_ seconds: Double) {
        duration = seconds
        if let idx = playlist.firstIndex(where: { $0.id == currentItemID }) {
            playlist[idx].duration = seconds
        }
        updateNowPlayingInfo()
    }

    func engineDidUpdateBufferedFraction(_ fraction: Double) {
        bufferedFraction = fraction
    }

    func engineDidBecomeReady(hasVideoTrack: Bool) {
        isLoading = false
        isVideoTrackPresent = hasVideoTrack
        // Local files: once the engine reports ready, treat scrubbing as fully available.
        // AVFoundation will immediately refine this via loadedTimeRanges if it's more precise.
        bufferedFraction = 1
        chapters = activeEngine.availableChapters().sorted { $0.startTime < $1.startTime }
        updateCurrentChapter()
    }

    /// Assigns only on an actual change — this runs on every time tick, and publishing
    /// the same value each time would bring back exactly the redraw storm PlaybackClock
    /// exists to avoid.
    private func updateCurrentChapter() {
        let id = chapters.last { $0.startTime <= currentTime }?.id
        if id != currentChapterID {
            currentChapterID = id
        }
    }

    func engineDidReachEndOfMedia() {
        if repeatMode == .one {
            seek(to: 0)
            activeEngine.play()
            return
        }
        let autoAdvance = UserDefaults.standard.object(forKey: AppSettingsKeys.autoAdvancePlaylist) as? Bool
            ?? AppSettingsDefaults.autoAdvancePlaylist
        if autoAdvance {
            playNext() // handles repeatMode == .all wraparound itself
        } else {
            isPlaying = false
        }
    }

    func engineDidFail(message: String) {
        isLoading = false
        errorMessage = message
    }

    // MARK: Tracks & subtitles

    func availableAudioTracks() -> [MediaTrack] {
        activeEngine.availableAudioTracks()
    }

    func availableSubtitleTracks() -> [MediaTrack] {
        activeEngine.availableSubtitleTracks()
    }

    func availableChapters() -> [Chapter] {
        activeEngine.availableChapters()
    }

    func selectAudioTrack(id: String?) {
        activeEngine.selectAudioTrack(id: id)
    }

    func selectSubtitleTrack(id: String?) {
        activeEngine.selectSubtitleTrack(id: id)
    }

    func setSubtitleDelay(_ seconds: Double) {
        activeEngine.setSubtitleDelay(seconds)
    }

    func setSubtitleScale(_ scale: Double) {
        activeEngine.setSubtitleScale(scale)
    }

    func resetVideoAdjustments() {
        videoBrightness = 0
        videoContrast = 0
        videoSaturation = 0
        videoGamma = 0
    }

    private func applyVideoAdjustments() {
        activeEngine.setVideoAdjustments(
            brightness: videoBrightness, contrast: videoContrast, saturation: videoSaturation, gamma: videoGamma
        )
    }

    private func applySubtitleAppearance() {
        activeEngine.setSubtitleAppearance(
            fontName: subtitleFontName, textColorHex: subtitleTextColorHex,
            backgroundColorHex: subtitleBackgroundColorHex, backgroundOpacity: subtitleBackgroundOpacity,
            codepage: subtitleCodepage
        )
    }

    /// AVFoundation has no real way to composite an external .srt onto an arbitrary
    /// asset, so loading one force-switches the current item onto the mpv engine
    /// (which handles it natively) at the same playback position.
    func loadExternalSubtitle(url: URL) {
        guard let item = currentItem else { return }
        if activeEngineKind != .mpv {
            let resumeTime = currentTime
            let wasPlaying = isPlaying
            activeEngine.stop()
            activeEngineKind = .mpv
            errorMessage = nil
            isLoading = true
            duration = 0
            bufferedFraction = 0
            mpvEngine.load(url: item.url)
            mpvEngine.setVolume(volume, muted: isMuted)
            mpvEngine.setRate(playbackRate)
            mpvEngine.seek(to: resumeTime)
            currentTime = resumeTime
            if wasPlaying { mpvEngine.play() } else { mpvEngine.pause() }
            isPlaying = wasPlaying
        }
        mpvEngine.addExternalSubtitle(url: url)
    }

    // MARK: Frame step, snapshot, info

    func stepFrame(forward: Bool) {
        guard currentItem != nil else { return }
        if isPlaying {
            activeEngine.pause()
            isPlaying = false
        }
        activeEngine.stepFrame(forward: forward)
    }

    func saveSnapshot(to url: URL) async {
        do {
            try await activeEngine.saveSnapshot(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchMediaInfo() async -> MediaInfo? {
        guard currentItem != nil else { return nil }
        return await activeEngine.mediaInfo()
    }

    func generateThumbnail(at seconds: Double) async -> CGImage? {
        await activeEngine.generateThumbnail(at: seconds)
    }

    // MARK: Per-file resume position

    /// Separate from session persistence above: that remembers one position for whatever's
    /// currently queued, this remembers one per *file*, keyed by URL, so reopening any
    /// previously-watched file (Open Recent, drag-drop, a different saved playlist) picks
    /// up where you left off even if it's not part of "the current queue" anymore.
    private func loadFileResumePositions() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: AppSettingsKeys.perFileResumePositions),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return decoded
    }

    private func storedResumePosition(for url: URL) -> Double {
        loadFileResumePositions()[url.absoluteString] ?? 0
    }

    private func recordFileResumePosition() {
        guard let item = currentItem else { return }
        var positions = loadFileResumePositions()
        // Within the last few seconds of the file: treat it as finished and forget the
        // position, same as "continue watching" rows drop something you've actually seen.
        // Barely started: not worth remembering either.
        if duration > 0, duration - currentTime < 5 {
            positions.removeValue(forKey: item.url.absoluteString)
        } else if currentTime > 5 {
            positions[item.url.absoluteString] = currentTime
        } else {
            return
        }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.perFileResumePositions)
    }

    /// The raw material for the home screen's "Continue Watching" row: recently-opened
    /// files (so we have a title without re-resolving a bookmark) that still have a
    /// remembered position. Deliberately cross-referenced against `recentFiles` rather
    /// than exposing the position store directly — a file only ever opened by loading a
    /// saved playlist (not through addFiles/openRecentFile) won't have a recent-files
    /// entry to hang a title/thumbnail on, so it's left out rather than shown with no
    /// usable label.
    func continueWatchingEntries() -> [(file: RecentFile, position: Double)] {
        let positions = loadFileResumePositions()
        return recentFiles.compactMap { recent in
            // Whatever's actually loaded right now reports its live position rather than
            // the last throttled save, which lags real playback by up to a few seconds —
            // with Home open over something still playing underneath, a stale row that
            // only updates in visible jumps reads as broken. Same "barely started" /
            // "basically finished" cutoffs recordFileResumePosition uses for the store,
            // so the live row appears and disappears at the same points a saved one would.
            if isCurrentItem(recent) {
                let isNearEnd = duration > 0 && duration - currentTime < 5
                guard currentTime > 5, !isNearEnd else { return nil }
                return (recent, currentTime)
            }
            guard let position = positions[recent.urlString], position > 0 else { return nil }
            return (recent, position)
        }
    }

    /// Matched by URL rather than `MediaItem.id` — a RecentFile resolves to a brand-new
    /// MediaItem with a fresh id every time, so ids never line up with what's in the queue.
    private func isCurrentItem(_ recent: RecentFile) -> Bool {
        currentItem?.url.absoluteString == recent.urlString
    }

    /// Drops just the remembered position for one file — pulls it out of Continue
    /// Watching without touching Open Recent or the file itself; reopening it later just
    /// starts over from the beginning. `objectWillChange` is sent explicitly because
    /// `continueWatchingEntries()` reads UserDefaults directly rather than through a
    /// `@Published` property, so nothing would otherwise tell an already-visible home
    /// screen to refresh.
    func removeFromContinueWatching(_ file: RecentFile) {
        var positions = loadFileResumePositions()
        positions.removeValue(forKey: file.urlString)
        guard let data = try? JSONEncoder().encode(positions) else { return }
        objectWillChange.send()
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.perFileResumePositions)
    }

    /// A Continue Watching card's cover image: the frame at the exact position you left
    /// off, generated independently of whatever's actually loaded right now (the card's
    /// file usually isn't the current item). Resolves its own bookmark and builds a
    /// one-off AVAssetImageGenerator rather than going through `activeEngine`, since the
    /// active engine only knows about the currently-playing item. Same AVFoundation-only
    /// limitation as the live scrubber-hover preview: mpv-only formats (MKV/AVI/etc.)
    /// return nil, and the card just falls back to its placeholder icon.
    func generateHomeScreenThumbnail(for file: RecentFile, at seconds: Double) async -> CGImage? {
        guard let item = resolveEntry(file.entry), MediaFormat.requiredEngine(for: item.url) == .avFoundation else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    // MARK: Session persistence

    /// Saves the playlist (as security-scoped bookmarks, since a plain path/URL from a
    /// past launch isn't actually accessible again in a sandboxed app) plus which item
    /// was playing and how far into it. Cheap enough to call after every playlist edit
    /// and on a throttle during playback — this is UserDefaults, not disk I/O of the media itself.
    private func persistSession() {
        let entries = playlist.compactMap(makeEntry(for:))
        let currentIndex = playlist.firstIndex { $0.id == currentItemID }
        let session = PersistedSession(
            entries: entries, currentIndex: currentIndex, currentTime: currentTime,
            activeSavedPlaylistID: activeSavedPlaylistID
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.persistedSession)
    }

    /// Called once at launch. Resolves each saved bookmark (silently dropping any whose
    /// file has since moved/been deleted — the rest still restore fine) and, if there
    /// was something playing, loads it paused at the saved position rather than
    /// surprising you with sound on launch.
    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: AppSettingsKeys.persistedSession),
              let session = try? JSONDecoder().decode(PersistedSession.self, from: data) else { return }

        var restoredItems: [MediaItem] = []
        var resolvedCurrentIndex: Int?

        for (originalIndex, entry) in session.entries.enumerated() {
            guard let item = resolveEntry(entry) else { continue }
            restoredItems.append(item)
            if originalIndex == session.currentIndex {
                resolvedCurrentIndex = restoredItems.count - 1
            }
        }

        guard !restoredItems.isEmpty else { return }
        playlist = restoredItems
        regenerateShuffleOrder()
        activeSavedPlaylistID = session.activeSavedPlaylistID

        if let resolvedCurrentIndex, restoredItems.indices.contains(resolvedCurrentIndex) {
            play(item: restoredItems[resolvedCurrentIndex], resumeAt: session.currentTime, autoPlay: false)
        }
    }

    /// Builds a portable-ish entry for one playlist item: a security-scoped bookmark for
    /// local files (the only thing that survives a relaunch under App Sandbox), or just
    /// the URL string for network streams (which don't need sandbox access at all).
    private func makeEntry(for item: MediaItem) -> PersistedPlaylistEntry? {
        if item.url.isFileURL {
            guard let bookmark = try? item.url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            ) else { return nil }
            return PersistedPlaylistEntry(bookmarkData: bookmark, remoteURLString: nil)
        } else {
            return PersistedPlaylistEntry(bookmarkData: nil, remoteURLString: item.url.absoluteString)
        }
    }

    /// The inverse of `makeEntry(for:)` — resolves a bookmark (starting security-scoped
    /// access) or parses a stored URL string back into a playable MediaItem.
    private func resolveEntry(_ entry: PersistedPlaylistEntry) -> MediaItem? {
        if let bookmarkData = entry.bookmarkData {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &isStale
            ) else { return nil }
            if !securityScopedURLs.contains(url) {
                guard url.startAccessingSecurityScopedResource() else { return nil }
                securityScopedURLs.insert(url)
            }
            return MediaItem(url: url)
        } else if let remoteURLString = entry.remoteURLString, let url = URL(string: remoteURLString) {
            return MediaItem(url: url)
        }
        return nil
    }

    /// Releases security-scoped access for any of `urls` that isn't (or is no longer,
    /// after whatever mutation the caller just made) referenced by the live queue — the
    /// only place a resolved URL's access needs to stay open. Safe to call with URLs that
    /// were never scoped (network streams) or are still in use elsewhere; both are skipped.
    private func releaseSecurityScopedAccessIfUnused(_ urls: [URL]) {
        for url in urls {
            guard securityScopedURLs.contains(url), !playlist.contains(where: { $0.url == url }) else { continue }
            url.stopAccessingSecurityScopedResource()
            securityScopedURLs.remove(url)
        }
    }

    // MARK: Saved playlist library

    /// The name shown in the sidebar header: the active saved playlist's name, or a
    /// generic label when the current queue hasn't been saved under one.
    var activePlaylistDisplayName: String {
        guard let activeSavedPlaylistID,
              let active = savedPlaylists.first(where: { $0.id == activeSavedPlaylistID }) else {
            return "Playlist"
        }
        return active.name
    }

    private func loadSavedPlaylistsLibrary() {
        guard let data = UserDefaults.standard.data(forKey: AppSettingsKeys.savedPlaylistsLibrary),
              let decoded = try? JSONDecoder().decode([SavedPlaylist].self, from: data) else { return }
        savedPlaylists = decoded
    }

    private func persistSavedPlaylistsLibrary() {
        guard let data = try? JSONEncoder().encode(savedPlaylists) else { return }
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.savedPlaylistsLibrary)
    }

    /// Saves the current queue as a new named entry in the library. Doesn't touch what's
    /// currently playing — this is a snapshot, not a move.
    func saveCurrentPlaylist(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entries = playlist.compactMap(makeEntry(for:))
        let saved = SavedPlaylist(id: UUID(), name: trimmed, entries: entries)
        savedPlaylists.append(saved)
        activeSavedPlaylistID = saved.id
        persistSavedPlaylistsLibrary()
    }

    /// Replaces the current queue with a saved playlist's contents, loaded (but not
    /// playing) so you can look at what's there before picking something.
    func loadSavedPlaylist(id: UUID) {
        guard let saved = savedPlaylists.first(where: { $0.id == id }) else { return }
        let previousURLs = playlist.map(\.url)
        playlist = saved.entries.compactMap(resolveEntry)
        regenerateShuffleOrder()
        resetPlaybackState()
        activeSavedPlaylistID = id
        persistSession()
        releaseSecurityScopedAccessIfUnused(previousURLs)
    }

    func deleteSavedPlaylist(id: UUID) {
        savedPlaylists.removeAll { $0.id == id }
        if activeSavedPlaylistID == id {
            activeSavedPlaylistID = nil
        }
        persistSavedPlaylistsLibrary()
    }

    func renameSavedPlaylist(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedPlaylists.firstIndex(where: { $0.id == id }) else { return }
        savedPlaylists[index].name = trimmed
        persistSavedPlaylistsLibrary()
    }

    // MARK: Open Recent

    private func loadRecentFiles() {
        guard let data = UserDefaults.standard.data(forKey: AppSettingsKeys.recentFiles),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        recentFiles = decoded
    }

    private func persistRecentFiles() {
        guard let data = try? JSONEncoder().encode(recentFiles) else { return }
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.recentFiles)
    }

    private func recordRecentFile(_ item: MediaItem) {
        guard let entry = makeEntry(for: item) else { return }
        recentFiles.removeAll { $0.urlString == item.url.absoluteString }
        recentFiles.insert(RecentFile(id: UUID(), title: item.title, urlString: item.url.absoluteString, entry: entry), at: 0)
        if recentFiles.count > 10 {
            recentFiles.removeLast(recentFiles.count - 10)
        }
        persistRecentFiles()
    }

    /// Adds a recent file back onto the current queue and plays it — reopening it also
    /// bumps it back to the top of the list, like every other app's Open Recent.
    func openRecentFile(_ recent: RecentFile) {
        // Already in the queue (possibly the very thing playing right now): play that
        // entry rather than appending a second copy. For the current item, play(item:)
        // is a no-op that just resumes it if paused — so this reads as "take me back to
        // it," not a reload from the last throttled save.
        if let existing = playlist.first(where: { $0.url.absoluteString == recent.urlString }) {
            play(item: existing)
            recordRecentFile(existing)
            return
        }
        guard let item = resolveEntry(recent.entry) else {
            errorMessage = "\u{201C}\(recent.title)\u{201D} isn't available anymore — it may have moved or been deleted."
            recentFiles.removeAll { $0.id == recent.id }
            persistRecentFiles()
            return
        }
        playlist.append(item)
        play(item: item)
        regenerateShuffleOrder()
        persistSession()
        recordRecentFile(item)
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        persistRecentFiles()
    }

    /// Empties the queue without saving it anywhere first — for starting a fresh list.
    /// (To keep the current one, use "Save Playlist As…" before this.)
    func startNewPlaylist() {
        clearPlaylist()
        activeSavedPlaylistID = nil
    }

    // MARK: M3U export/import

    /// Writes the current queue as a standard M3U8 playlist — plain text, readable by
    /// VLC/iTunes/etc., and the only real way to get a playlist OUT of this app (a saved
    /// playlist in the library above only round-trips within this app, since it's built
    /// on sandbox bookmarks that don't mean anything anywhere else).
    func exportPlaylist(to url: URL) {
        var lines = ["#EXTM3U"]
        for item in playlist {
            let durationSeconds = Int(item.duration ?? -1)
            lines.append("#EXTINF:\(durationSeconds >= 0 ? durationSeconds : -1),\(item.title)")
            lines.append(item.url.isFileURL ? item.url.path : item.url.absoluteString)
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not export the playlist: \(error.localizedDescription)"
        }
    }

    /// Reads an M3U/M3U8 file and appends whatever it can actually still get to onto the
    /// current queue. Entries whose file has moved, or that this sandboxed app was never
    /// granted access to in the first place (a raw path from an M3U carries no access
    /// grant the way a security-scoped bookmark does), are silently skipped rather than
    /// failing the whole import — the count of skipped items is reported once at the end.
    func importPlaylist(from url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "Could not read that playlist file."
            return
        }
        let baseDirectory = url.deletingLastPathComponent()

        var newItems: [MediaItem] = []
        var skippedCount = 0
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let itemURL: URL
            if let parsed = URL(string: line), let scheme = parsed.scheme, scheme != "file" {
                itemURL = parsed
            } else if line.hasPrefix("/") {
                itemURL = URL(fileURLWithPath: line)
            } else {
                itemURL = URL(fileURLWithPath: line, relativeTo: baseDirectory)
            }

            if itemURL.isFileURL, !FileManager.default.isReadableFile(atPath: itemURL.path) {
                skippedCount += 1
                continue
            }
            newItems.append(MediaItem(url: itemURL))
        }

        guard !newItems.isEmpty else {
            errorMessage = "None of that playlist's files are accessible from here."
            return
        }
        playlist.append(contentsOf: newItems)
        if skippedCount > 0 {
            errorMessage = "Added \(newItems.count) item(s) — \(skippedCount) couldn't be added (moved, deleted, or not accessible to this app)."
        }
        persistSession()
    }

    // MARK: Now Playing / media keys

    /// Registers with Control Center's Now Playing widget and the system's media-key
    /// handling (keyboard media keys, AirPods double-tap, etc.) — makes this app a real
    /// participant in macOS's shared playback controls instead of only responding to its
    /// own on-screen buttons. Called once at init; the handlers below close over `self`
    /// weakly and just delegate to the same methods the in-app UI already uses.
    private func setUpNowPlayingCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.currentItem != nil else { return .noSuchContent }
            if !self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentItem != nil else { return .noSuchContent }
            if self.isPlaying { self.togglePlayPause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentItem != nil else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15)
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let currentItem else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: isVideoTrackPresent ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
