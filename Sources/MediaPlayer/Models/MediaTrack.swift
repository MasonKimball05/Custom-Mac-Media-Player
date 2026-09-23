import Foundation

/// A selectable audio or subtitle track, normalized across both playback engines.
/// `id` is engine-native (an AVMediaSelectionOption's persistent ID as a string, or an
/// mpv track id) — engines only need to round-trip it back to themselves, never compare
/// it across engines.
struct MediaTrack: Identifiable, Hashable {
    enum Kind {
        case audio
        case subtitle
    }

    let id: String
    let kind: Kind
    let title: String
    let languageCode: String?
    let isSelected: Bool

    var displayName: String {
        if let languageCode, let localized = Locale.current.localizedString(forLanguageCode: languageCode) {
            return title.isEmpty ? localized : "\(title) (\(localized))"
        }
        return title.isEmpty ? "Track \(id)" : title
    }
}

/// What a given engine can actually do for tracks/subtitles — the UI uses this to show
/// or hide controls instead of offering something that would silently no-op.
struct EngineCapabilities: Equatable {
    var externalSubtitles = false
    var subtitleTiming = false
    var subtitleScaling = false
    var airPlay = false
    /// Font/color/background styling — AVFoundation renders subtitles internally with
    /// no public API to restyle them, the same reason it has no external-subtitle support.
    var subtitleAppearance = false
}

/// One chapter marker, normalized across both engines. Identified by its start time
/// rather than a generated UUID: chapters are re-read from the engine on every redraw,
/// and a fresh UUID each time made every read look like a brand-new set of items.
struct Chapter: Identifiable, Hashable {
    let title: String
    let startTime: Double

    var id: Double { startTime }
}

/// Snapshot of everything the Media Info panel (⌘I) shows.
struct MediaInfo {
    var engineName: String
    var fileSizeBytes: Int64?
    var containerFormat: String?
    var videoCodec: String?
    var videoDimensions: String?
    var frameRate: Double?
    var videoBitrate: Double?
    var audioCodec: String?
    var audioChannels: Int?
    var audioSampleRate: Double?
    var audioBitrate: Double?
}
