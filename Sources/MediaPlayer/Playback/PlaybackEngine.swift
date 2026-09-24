import CoreGraphics
import Foundation

/// Which engine is driving playback right now. AVFoundation can't open MKV/AVI/etc.
/// containers at all (regardless of the codec inside), so those route to mpv instead.
enum PlaybackEngineKind {
    case avFoundation
    case mpv
}

enum PlaybackEngineError: Error, LocalizedError {
    case noMediaLoaded
    case snapshotEncodingFailed
    case snapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMediaLoaded: return "No media is currently loaded."
        case .snapshotEncodingFailed: return "Could not encode the snapshot as an image."
        case .snapshotFailed(let reason): return "Could not save the snapshot: \(reason)"
        }
    }
}

enum MediaFormat {
    /// Extensions AVFoundation cannot demux, so we need mpv (which bundles its own
    /// ffmpeg-based demuxer) for these regardless of the codec inside the container.
    private static let mpvOnlyExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts", "mts", "vob", "ogv", "rm", "rmvb", "asf"
    ]

    /// Formats AVFoundation opens natively. Only used alongside `mpvOnlyExtensions` to
    /// recognize playable files while scanning a folder (Open Folder) — NSOpenPanel's own
    /// UTI-based filtering handles the single-file picker case and doesn't need this list.
    private static let avFoundationExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mp3", "m4a", "wav", "aiff", "aif", "flac", "3gp", "3g2"
    ]

    static func requiredEngine(for url: URL) -> PlaybackEngineKind {
        mpvOnlyExtensions.contains(url.pathExtension.lowercased()) ? .mpv : .avFoundation
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return mpvOnlyExtensions.contains(ext) || avFoundationExtensions.contains(ext)
    }
}

/// Everything the UI needs to hear about from whichever engine is currently playing.
/// Delivered on the main thread — conformers are responsible for hopping off their
/// own background threads before calling these.
@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engineDidUpdateTime(_ seconds: Double)
    func engineDidUpdateDuration(_ seconds: Double)
    /// Only meaningful for engines that can report it (AVFoundation, via loadedTimeRanges).
    /// Engines that don't track this simply never call it.
    func engineDidUpdateBufferedFraction(_ fraction: Double)
    func engineDidBecomeReady(hasVideoTrack: Bool)
    func engineDidReachEndOfMedia()
    func engineDidFail(message: String)
    /// The plain text of the subtitle line currently showing, or nil when none is. Reported
    /// whether or not the engine is drawing subtitles itself. Image-based subtitle tracks
    /// (DVD/Blu-ray style) have no text to report.
    func engineDidUpdateSubtitleText(_ text: String?)
}

/// Common playback surface both engines implement. Rendering is deliberately out of
/// scope here — it's too engine-specific (AVPlayerLayer vs. an OpenGL-backed NSView) —
/// so PlayerViewModel exposes each engine's native handle separately for the view layer.
@MainActor
protocol PlaybackEngine: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }
    /// What this engine can actually do beyond the baseline — the UI uses this to show
    /// or hide controls (e.g. subtitle delay/scale) instead of offering a silent no-op.
    var capabilities: EngineCapabilities { get }

    func load(url: URL)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setVolume(_ volume: Float, muted: Bool)
    func setRate(_ rate: Float)
    /// Stop and release any loaded media without tearing down the engine itself,
    /// so switching back to this engine later doesn't need to re-initialize it.
    func stop()

    /// Advances exactly one frame while paused. Callers are responsible for pausing first.
    func stepFrame(forward: Bool)
    func saveSnapshot(to url: URL) async throws
    func mediaInfo() async -> MediaInfo
    /// A small, fast, low-fidelity frame for the scrubber's hover preview — not the same
    /// as `saveSnapshot`, which is a deliberate full-quality capture. `nil` means "not
    /// supported" (the mpv engine doesn't implement this) or "couldn't generate one",
    /// and the caller just falls back to a text-only time tooltip either way.
    func generateThumbnail(at seconds: Double) async -> CGImage?

    func availableAudioTracks() -> [MediaTrack]
    func availableSubtitleTracks() -> [MediaTrack]
    func availableChapters() -> [Chapter]
    /// `nil` selects the engine's default/auto audio track.
    func selectAudioTrack(id: String?)
    /// `nil` turns subtitles off.
    func selectSubtitleTrack(id: String?)
    /// Only meaningful when `capabilities.externalSubtitles` is true.
    func addExternalSubtitle(url: URL)
    /// Only meaningful when `capabilities.subtitleTiming` is true.
    func setSubtitleDelay(_ seconds: Double)
    /// Only meaningful when `capabilities.subtitleScaling` is true.
    func setSubtitleScale(_ scale: Double)

    /// Color-adjusts the decoded video. Each axis is -100...100, mpv's own convention,
    /// with 0 meaning "no change" on all four — both engines support this one.
    func setVideoAdjustments(brightness: Double, contrast: Double, saturation: Double, gamma: Double)

    /// Only meaningful when `capabilities.subtitleAppearance` is true. `fontName` empty
    /// means "engine default". Colors are "#RRGGBB". `codepage` empty means "auto-detect
    /// the subtitle file's character encoding" — set explicitly to fix a legacy-encoded
    /// (non-UTF-8) file the auto-detector guessed wrong on, e.g. "cp1253" for Greek.
    func setSubtitleAppearance(
        fontName: String, textColorHex: String, backgroundColorHex: String, backgroundOpacity: Double, codepage: String
    )

    /// Turned off while the app draws translated subtitles itself, so the original line
    /// isn't drawn underneath the translation. Subtitle text keeps being reported either way.
    func setNativeSubtitleRenderingEnabled(_ enabled: Bool)
}
