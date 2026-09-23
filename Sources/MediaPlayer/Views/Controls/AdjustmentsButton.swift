import AppKit
import SwiftUI

/// Video color adjustments + (when the active engine supports it) subtitle appearance,
/// tucked behind one toolbar icon and a popover rather than a permanent bank of sliders —
/// same reasoning as TrackMenuButton keeping the audio/subtitle picker off the main bar.
struct AdjustmentsButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var isHovering = false
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 29, height: 29)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(viewModel.currentItem == nil)
        .help("Video \u{0026} Subtitle Adjustments")
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            AdjustmentsPopoverContent(viewModel: viewModel)
        }
    }
}

private struct AdjustmentsPopoverContent: View {
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
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
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
