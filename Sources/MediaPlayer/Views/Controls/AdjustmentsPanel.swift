import AppKit
import SwiftUI
import Translation

/// Video color adjustments, subtitle appearance (when the active engine supports it), and
/// subtitle translation. Shown in a popover from the settings gear's "Video & Subtitle
/// Adjustments" item rather than as a permanent bank of sliders.
struct AdjustmentsPanel: View {
    @ObservedObject var viewModel: PlayerViewModel

    /// A representative set, not exhaustive — mpv accepts any iconv-recognized charset
    /// name in this field, these are just the common ones worth a menu item.
    static let subtitleEncodings: [(label: String, codepage: String)] = [
        ("Auto-Detect", ""),
        ("UTF-8", "UTF-8"),
        ("Greek (Windows-1253)", "cp1253"),
        ("Greek (ISO-8859-7)", "iso-8859-7"),
        ("Western European (Windows-1252)", "cp1252"),
        ("Cyrillic (Windows-1251)", "cp1251"),
        ("Turkish (Windows-1254)", "cp1254"),
        ("Japanese (Shift-JIS)", "shift-jis")
    ]

    var body: some View {
        Form {
            Section {
                adjustmentSlider("Brightness", value: $viewModel.videoBrightness)
                adjustmentSlider("Contrast", value: $viewModel.videoContrast)
                adjustmentSlider("Saturation", value: $viewModel.videoSaturation)
                adjustmentSlider("Gamma", value: $viewModel.videoGamma)
                Button("Reset Video Adjustments") {
                    viewModel.resetVideoAdjustments()
                }
            } header: {
                Text("Video")
            }

            if viewModel.currentEngineCapabilities.subtitleAppearance {
                Section {
                    TextField("Font", text: $viewModel.subtitleFontName, prompt: Text("System Default"))
                    ColorPicker("Text Color", selection: Binding(
                        get: { Color(hex: viewModel.subtitleTextColorHex) },
                        set: { viewModel.subtitleTextColorHex = $0.hexString }
                    ))
                    ColorPicker("Background Color", selection: Binding(
                        get: { Color(hex: viewModel.subtitleBackgroundColorHex) },
                        set: { viewModel.subtitleBackgroundColorHex = $0.hexString }
                    ))
                    VStack(alignment: .leading, spacing: 2) {
                        Slider(value: $viewModel.subtitleBackgroundOpacity, in: 0...1) {
                            Text("Background Opacity")
                        }
                        Text("0% is text with no background box.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Text Encoding", selection: $viewModel.subtitleCodepage) {
                            ForEach(Self.subtitleEncodings, id: \.codepage) { encoding in
                                Text(encoding.label).tag(encoding.codepage)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("If subtitles show up garbled, the file's character encoding was likely guessed wrong \u{2014} pick the right one here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Subtitle Appearance")
                }
            }

            Section {
                Toggle("Translate subtitles", isOn: $viewModel.translateSubtitles)
                if viewModel.translateSubtitles {
                    TranslationStatusLabel(state: viewModel.subtitleTranslation)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Translate to", selection: $viewModel.subtitleTranslationTarget) {
                        ForEach(targetLanguageOptions, id: \.identifier) { option in
                            Text(option.name).tag(option.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Uses Apple's on-device translation; macOS may ask to download a language the first time. Needs a text-based subtitle track, so image-based ones (common on Blu-ray and DVD rips) can't be translated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Subtitle Translation")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .task {
            supportedLanguages = await LanguageAvailability().supportedLanguages
        }
    }

    @State private var supportedLanguages: [Locale.Language] = []

    /// Supported languages by display name, always including the current selection even
    /// if it isn't in the list verbatim (e.g. the default "en" versus a listed "en-US"),
    /// so the picker never shows a blank selection.
    private var targetLanguageOptions: [(identifier: String, name: String)] {
        var identifiers = supportedLanguages.map(\.minimalIdentifier)
        if !identifiers.contains(viewModel.subtitleTranslationTarget) {
            identifiers.append(viewModel.subtitleTranslationTarget)
        }
        return Set(identifiers)
            .map { (identifier: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func adjustmentSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: value, in: -100...100, step: 1) {
                Text(title)
            }
            Text("\(Int(value.wrappedValue))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Observes the translation state directly — the popover's own view model observation
/// doesn't see it, since translation state lives on its own object.
private struct TranslationStatusLabel: View {
    @ObservedObject var state: SubtitleTranslationState

    var body: some View {
        Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var description: String {
        switch state.status {
        case .waitingForSubtitles: return "Status: waiting for subtitle text"
        case .translating: return "Status: translating\u{2026}"
        case .translated(let source): return "Status: translating from \(source)"
        case .failed(let reason): return "Status: couldn't translate \u{2014} \(reason)"
        }
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return "#FFFFFF" }
        let r = Int((components.redComponent * 255).rounded())
        let g = Int((components.greenComponent * 255).rounded())
        let b = Int((components.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
