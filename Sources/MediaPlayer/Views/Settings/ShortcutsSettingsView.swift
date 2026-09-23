import AppKit
import SwiftUI

/// Settings > Shortcuts — lets each `RemappableAction` be rebound to a different key.
struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(RemappableAction.allCases, id: \.self) { action in
                    LabeledContent(action.displayName) {
                        KeyRecorderButton(action: action)
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("These are the plain single-key shortcuts (no \u{2318}/\u{2303}/\u{2325}) that work while a file is playing. Click a key, then press its replacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A button showing the currently-bound key; clicking it captures the next keystroke
/// (via a scoped local NSEvent monitor, the same mechanism ContentView's global shortcut
/// handling itself relies on) as the new binding instead of opening a text field, so
/// there's no ambiguity about how to "type" a key like Space or an arrow.
private struct KeyRecorderButton: View {
    let action: RemappableAction

    @State private var currentKey: String
    @State private var isRecording = false
    @State private var monitor: Any?

    init(action: RemappableAction) {
        self.action = action
        _currentKey = State(initialValue: KeyBindingStore.currentBindings()[action] ?? action.defaultKey)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press a key\u{2026}" : displayKey(currentKey))
                    .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)

            if currentKey != action.defaultKey {
                Button {
                    KeyBindingStore.resetBinding(for: action)
                    currentKey = action.defaultKey
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help("Reset to \u{201C}\(displayKey(action.defaultKey))\u{201D}")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func displayKey(_ key: String) -> String {
        key == " " ? "Space" : key.uppercased()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let first = event.charactersIgnoringModifiers?.lowercased().first else {
                return nil
            }
            let key = String(first)
            KeyBindingStore.setBinding(key, for: action)
            currentKey = key
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
