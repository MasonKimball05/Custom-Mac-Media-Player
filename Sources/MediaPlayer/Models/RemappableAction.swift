import Foundation

/// The plain single-key shortcuts handled in ContentView's `handleGlobalKeyEvent` that
/// can be remapped from Settings > Shortcuts. Deliberately scoped to just these — the
/// arrow keys, digit-seek, and Shift+,/. speed keys stay fixed, since they're
/// positional/mnemonic in a way a named action and a text field don't add much to.
enum RemappableAction: String, CaseIterable, Codable {
    case playPause
    case skipBackward
    case skipForward
    case mute
    case toggleFullscreen
    case toggleCaptions
    case frameBack
    case frameForward

    var displayName: String {
        switch self {
        case .playPause: return "Play/Pause"
        case .skipBackward: return "Skip Backward"
        case .skipForward: return "Skip Forward"
        case .mute: return "Mute"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .toggleCaptions: return "Toggle Captions"
        case .frameBack: return "Step Back One Frame"
        case .frameForward: return "Step Forward One Frame"
        }
    }

    var defaultKey: String {
        switch self {
        case .playPause: return "k"
        case .skipBackward: return "j"
        case .skipForward: return "l"
        case .mute: return "m"
        case .toggleFullscreen: return "f"
        case .toggleCaptions: return "c"
        case .frameBack: return ","
        case .frameForward: return "."
        }
    }
}

/// Loads/saves the user's key remappings as a `[action.rawValue: key]` dictionary in
/// UserDefaults — only the overrides are stored, so anything not explicitly remapped
/// keeps tracking `defaultKey` even if that default ever changes later.
enum KeyBindingStore {
    static func currentBindings() -> [RemappableAction: String] {
        var bindings = Dictionary(uniqueKeysWithValues: RemappableAction.allCases.map { ($0, $0.defaultKey) })
        for (action, key) in storedOverrides() {
            bindings[action] = key
        }
        return bindings
    }

    static func setBinding(_ key: String, for action: RemappableAction) {
        var raw = rawStoredOverrides()
        raw[action.rawValue] = key
        persist(raw)
    }

    static func resetBinding(for action: RemappableAction) {
        var raw = rawStoredOverrides()
        raw.removeValue(forKey: action.rawValue)
        persist(raw)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.customKeyBindings)
    }

    private static func storedOverrides() -> [RemappableAction: String] {
        var result: [RemappableAction: String] = [:]
        for (rawAction, key) in rawStoredOverrides() {
            if let action = RemappableAction(rawValue: rawAction) {
                result[action] = key
            }
        }
        return result
    }

    private static func rawStoredOverrides() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: AppSettingsKeys.customKeyBindings),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return stored
    }

    private static func persist(_ overrides: [String: String]) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: AppSettingsKeys.customKeyBindings)
    }
}
