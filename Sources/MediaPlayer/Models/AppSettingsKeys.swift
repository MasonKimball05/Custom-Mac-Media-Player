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
}

enum AppSettingsDefaults {
    static let skipInterval: Double = 10
    static let autoHideControlsDelay: Double = 2.6
    static let autoAdvancePlaylist = true
    static let hardwareDecodingEnabled = true
    static let volume: Float = 0.8
}
