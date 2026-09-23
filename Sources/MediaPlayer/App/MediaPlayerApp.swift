import AppKit
import SwiftUI

@main
struct MediaPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PlayerViewModel()
    @AppStorage(AppSettingsKeys.skipInterval) private var skipInterval = AppSettingsDefaults.skipInterval

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") {
                    NotificationCenter.default.post(name: .openMediaFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder\u{2026}") {
                    NotificationCenter.default.post(name: .openMediaFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("Open Network Stream\u{2026}") {
                    NotificationCenter.default.post(name: .openNetworkStream, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu("Open Recent") {
                    if viewModel.recentFiles.isEmpty {
                        Text("No Recent Files")
                    }
                    ForEach(viewModel.recentFiles) { recent in
                        Button(recent.title) {
                            viewModel.openRecentFile(recent)
                        }
                    }
                    if !viewModel.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            viewModel.clearRecentFiles()
                        }
                    }
                }
            }

            CommandGroup(after: .toolbar) {
                Button("Media Info") {
                    NotificationCenter.default.post(name: .showMediaInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(viewModel.currentItem == nil)
            }

            CommandMenu("Playback") {
                Button(viewModel.isPlaying ? "Pause" : "Play") {
                    viewModel.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(viewModel.currentItem == nil)

                Divider()

                Button("Next Track") { viewModel.playNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Track") { viewModel.playPrevious() }
                    .keyboardShortcut("[", modifiers: .command)

                Divider()

                Button("Skip Forward \(Int(skipInterval))s") { viewModel.skip(by: skipInterval) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Skip Backward \(Int(skipInterval))s") { viewModel.skip(by: -skipInterval) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("Step Forward One Frame") { viewModel.stepFrame(forward: true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Step Backward One Frame") { viewModel.stepFrame(forward: false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Divider()

                Toggle("Shuffle", isOn: $viewModel.isShuffled)
                Menu("Repeat") {
                    Button {
                        viewModel.repeatMode = .off
                    } label: {
                        if viewModel.repeatMode == .off {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    Button {
                        viewModel.repeatMode = .all
                    } label: {
                        if viewModel.repeatMode == .all {
                            Label("Repeat All", systemImage: "checkmark")
                        } else {
                            Text("Repeat All")
                        }
                    }
                    Button {
                        viewModel.repeatMode = .one
                    } label: {
                        if viewModel.repeatMode == .one {
                            Label("Repeat One", systemImage: "checkmark")
                        } else {
                            Text("Repeat One")
                        }
                    }
                }

                Divider()

                Button(viewModel.isMuted ? "Unmute" : "Mute") { viewModel.isMuted.toggle() }
                    .keyboardShortcut("m", modifiers: .command)

                Divider()

                Button("Take Snapshot\u{2026}") {
                    NotificationCenter.default.post(name: .saveSnapshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(viewModel.currentItem == nil)
            }
        }

        Settings {
            SettingsView()
        }

        // Quick transport + "what's playing" without having to bring the main window
        // forward — handy once it's buried behind other windows. Only meaningful while
        // the app itself is running, same as the rest of it: closing the last window
        // still quits the app (see AppDelegate below), so this disappears along with it.
        MenuBarExtra("Now Playing", systemImage: "play.square.stack") {
            MenuBarNowPlayingView(viewModel: viewModel)
        }
    }
}

private struct MenuBarNowPlayingView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        if let item = viewModel.currentItem {
            Text(item.title)
            Text(viewModel.isPlaying ? "Playing" : "Paused")
        } else {
            Text("Nothing Playing")
        }

        Divider()

        Button(viewModel.isPlaying ? "Pause" : "Play") {
            viewModel.togglePlayPause()
        }
        .disabled(viewModel.currentItem == nil)
        Button("Next Track") { viewModel.playNext() }
            .disabled(viewModel.currentItem == nil)
        Button("Previous Track") { viewModel.playPrevious() }
            .disabled(viewModel.currentItem == nil)

        Divider()

        Button("Show Media Player") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Divider()

        Button("Quit Media Player") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// Handles files opened via Finder ("Open With\u{2026}", double-click, drag-onto-dock-icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .openMediaFileURL, object: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
