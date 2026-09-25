import Foundation

/// Centralizes UserDefaults keys and defaults for @AppStorage so the same value
/// (and fallback) is used consistently everywhere it's read, instead of magic
/// strings/numbers drifting between the Settings window and the views that use them.
enum AppSettingsKeys {
    static let skipInterval = "skipIntervalSeconds"
    static let autoHideControlsDelay = "autoHideControlsDelaySeconds"
    static let autoAdvancePlaylist = "autoAdvancePlaylist"
    static let hardwareDecodingEnabled = "hardwareDecodingEnabled"
    static let lastVolume = "lastVolume"
    static let lastMuted = "lastMuted"
    static let persistedSession = "persistedSession"
    static let savedPlaylistsLibrary = "savedPlaylistsLibrary"
    static let recentFiles = "recentFiles"
    static let floatOnTop = "floatOnTop"
    static let volumeBoostEnabled = "volumeBoostEnabled"
    static let videoBrightness = "videoBrightness"
    static let videoContrast = "videoContrast"
    static let videoSaturation = "videoSaturation"
    static let videoGamma = "videoGamma"
    static let subtitleFontName = "subtitleFontName"
    static let subtitleTextColorHex = "subtitleTextColorHex"
    static let subtitleBackgroundColorHex = "subtitleBackgroundColorHex"
    static let subtitleBackgroundOpacity = "subtitleBackgroundOpacity"
    static let subtitleCodepage = "subtitleCodepage"
    static let translateSubtitles = "translateSubtitles"
    static let subtitleTranslationTarget = "subtitleTranslationTarget"
    static let customKeyBindings = "customKeyBindings"
    static let perFileResumePositions = "perFileResumePositions"
    static let autoDoNotDisturb = "autoDoNotDisturb"
    static let focusOnShortcutName = "focusOnShortcutName"
    static let focusOffShortcutName = "focusOffShortcutName"
    static let showsRemainingTime = "showsRemainingTime"
    static let downloadFolderBookmark = "downloadFolderBookmark"
    static let ytdlpLatestVersion = "ytdlpLatestVersion"
    static let ytdlpLastUpdateCheck = "ytdlpLastUpdateCheck"
    static let downloadKind = "downloadKind"
    static let downloadVideoFormat = "downloadVideoFormat"
    static let downloadAudioFormat = "downloadAudioFormat"
    static let downloadSubtitleSaving = "downloadSubtitleSaving"
    static let downloadAddsToPlaylist = "downloadAddsToPlaylist"
}

enum AppSettingsDefaults {
    static let skipInterval: Double = 10
    static let autoHideControlsDelay: Double = 2.6
    static let autoAdvancePlaylist = true
    static let hardwareDecodingEnabled = true
    static let volume: Float = 0.8
    static let floatOnTop = false
    static let volumeBoostEnabled = false
    /// mpv-style -100...100 range for all four; 0 is "no adjustment" on every axis.
    static let videoAdjustment: Double = 0
    static let subtitleFontName = ""
    static let subtitleTextColorHex = "#FFFFFF"
    static let subtitleBackgroundColorHex = "#000000"
    static let subtitleBackgroundOpacity: Double = 0
    /// Empty means "auto-detect" — mpv's own charset guesser, which is what gets a
    /// legacy-encoded (non-UTF-8) subtitle file wrong often enough to need an override.
    static let subtitleCodepage = ""
    static let translateSubtitles = false
    /// A language identifier ("en", "el", ...), defaulting to the system language.
    static let subtitleTranslationTarget = Locale.current.language.languageCode?.identifier ?? "en"
    static let autoDoNotDisturb = false
    static let focusOnShortcutName = "Focus On"
    static let focusOffShortcutName = "Focus Off"
}
