import AVFoundation
import Combine
import SwiftUI

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

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedFraction: Double = 0
    @Published private(set) var isLoading = false
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

    override init() {
        super.init()
        avEngine.delegate = self

        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettingsKeys.lastVolume) != nil {
            volume = defaults.float(forKey: AppSettingsKeys.lastVolume)
        }
        isMuted = defaults.bool(forKey: AppSettingsKeys.lastMuted)
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
    }

    func removeItem(_ item: MediaItem) {
        playlist.removeAll { $0.id == item.id }
        shuffleOrder.removeAll { $0 == item.id }
        if currentItemID == item.id {
            activeEngine.stop()
            currentItemID = nil
            isPlaying = false
            currentTime = 0
            duration = 0
        }
    }

    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        playlist.move(fromOffsets: source, toOffset: destination)
    }

    func play(item: MediaItem, resumeAt: Double = 0) {
        errorMessage = nil
        isLoading = true
        currentItemID = item.id
        currentTime = resumeAt
        duration = 0
        bufferedFraction = 0

        let requiredEngineKind = MediaFormat.requiredEngine(for: item.url)
        if requiredEngineKind != activeEngineKind {
            activeEngine.stop()
        }
        activeEngineKind = requiredEngineKind

        activeEngine.load(url: item.url)
        activeEngine.setVolume(volume, muted: isMuted)
        activeEngine.setRate(playbackRate)
        if resumeAt > 0 { activeEngine.seek(to: resumeAt) }
        activeEngine.play()
        isPlaying = true
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
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        activeEngine.seek(to: clamped)
        currentTime = clamped
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    // MARK: PlaybackEngineDelegate

    func engineDidUpdateTime(_ seconds: Double) {
        guard !isScrubbing else { return }
        currentTime = seconds
    }

    func engineDidUpdateDuration(_ seconds: Double) {
        duration = seconds
        if let idx = playlist.firstIndex(where: { $0.id == currentItemID }) {
            playlist[idx].duration = seconds
        }
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
}
