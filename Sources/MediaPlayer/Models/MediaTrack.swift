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
struct EngineCapabilities {
    var externalSubtitles = false
    var subtitleTiming = false
    var subtitleScaling = false
}

/// One chapter marker, normalized across both engines.
struct Chapter: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let startTime: Double
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
