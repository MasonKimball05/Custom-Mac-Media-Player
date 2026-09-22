import SwiftUI

/// Backs the standard macOS Settings window (⌘,). Two tabs: everyday playback
/// behavior, and the one mpv-specific knob worth exposing (hardware decoding).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
                .tag(1)
        }
        .frame(width: 420)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval
    @AppStorage(AppSettingsKeys.autoHideControlsDelay) private var autoHideDelay = AppSettingsDefaults.autoHideControlsDelay
    @AppStorage(AppSettingsKeys.autoAdvancePlaylist) private var autoAdvance = AppSettingsDefaults.autoAdvancePlaylist

    var body: some View {
        Form {
            Section {
                Picker("Skip interval:", selection: $skipInterval) {
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $autoHideDelay, in: 1...6, step: 0.5) {
                        Text("Controls auto-hide delay:")
                    }
                    Text("Transport bar disappears \(autoHideDelay, specifier: "%.1f")s after you stop moving the mouse during playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Automatically play the next item in the playlist", isOn: $autoAdvance)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettingsView: View {
    @AppStorage(AppSettingsKeys.hardwareDecodingEnabled) private var hardwareDecoding = AppSettingsDefaults.hardwareDecodingEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Use hardware-accelerated decoding", isOn: $hardwareDecoding)
                Text("Applies to MKV/AVI/WebM and other formats played through mpv. Turning this off forces software decoding — slower, but useful if a specific file glitches with hardware decode. Takes effect the next time you open a file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("mpv engine")
            }
        }
        .formStyle(.grouped)
    }
}
