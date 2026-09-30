import AppKit
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

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(2)

            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "externaldrive.connected.to.line.below") }
                .tag(3)
        }
        .frame(width: 420)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval
    @AppStorage(AppSettingsKeys.autoHideControlsDelay) private var autoHideDelay = AppSettingsDefaults.autoHideControlsDelay
    @AppStorage(AppSettingsKeys.autoAdvancePlaylist) private var autoAdvance = AppSettingsDefaults.autoAdvancePlaylist
    @AppStorage(AppSettingsKeys.volumeBoostEnabled) private var volumeBoostEnabled = AppSettingsDefaults.volumeBoostEnabled
    @AppStorage(AppSettingsKeys.autoDoNotDisturb) private var autoDoNotDisturb = AppSettingsDefaults.autoDoNotDisturb
    @AppStorage(AppSettingsKeys.focusOnShortcutName) private var focusOnShortcutName = AppSettingsDefaults.focusOnShortcutName
    @AppStorage(AppSettingsKeys.focusOffShortcutName) private var focusOffShortcutName = AppSettingsDefaults.focusOffShortcutName

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

            Section {
                Toggle("Allow volume boost up to 200%", isOn: $volumeBoostEnabled)
                Text("Lets the volume slider go past the normal ceiling, for files that are just quiet. Audio can distort at very high boost, same as any other volume-boost feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically enable Focus while fullscreen", isOn: $autoDoNotDisturb)

                if autoDoNotDisturb {
                    TextField("Focus-on shortcut name:", text: $focusOnShortcutName)
                    TextField("Focus-off shortcut name:", text: $focusOffShortcutName)

                    HStack {
                        Text("macOS doesn't let apps toggle Focus directly, so this runs two Shortcuts.app shortcuts by name \u{2014} one with a “Set Focus” action turning a Focus (e.g. Do Not Disturb) on, one turning it off. Create them once in Shortcuts with these exact names.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    Button("Open Shortcuts App\u{2026}") {
                        NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                    }
                }
            } header: {
                Text("Focus / Do Not Disturb")
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

/// Connection to the shelf media server on the desktop.
private struct LibrarySettingsView: View {
    @AppStorage(AppSettingsKeys.shelfServerURL) private var serverURL = ""
    @State private var token = ""
    @State private var hasSavedToken = Keychain.read(account: ShelfClient.keychainAccount) != nil
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Server:", text: $serverURL, prompt: Text("http://arkans-pc1:8095"))
                SecureField("Access token:", text: $token, prompt: Text(hasSavedToken ? "Saved in Keychain" : "SHELF_TOKEN from the desktop"))
                HStack {
                    Button("Save & Test") { Task { await saveAndTest() } }
                        .disabled(testing || serverURL.isEmpty || (token.isEmpty && !hasSavedToken))
                    if hasSavedToken {
                        Button("Forget Token") {
                            Keychain.delete(account: ShelfClient.keychainAccount)
                            hasSavedToken = false
                            status = nil
                        }
                    }
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Streams your desktop's media over Tailscale. The token is stored in your Keychain, never in plain settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveAndTest() async {
        testing = true
        defer { testing = false }
        if !token.isEmpty {
            hasSavedToken = Keychain.save(token, account: ShelfClient.keychainAccount)
            token = ""
            if !hasSavedToken {
                status = "Couldn\u{2019}t save the token to your Keychain."
                return
            }
        }
        do {
            let roots = try await ShelfClient.shared.roots()
            status = "Connected: \(roots.roots.count) libraries, \(roots.files.formatted()) files."
        } catch {
            status = error.localizedDescription
        }
    }
}
