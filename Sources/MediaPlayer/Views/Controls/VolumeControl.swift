import SwiftUI

/// Speaker icon that reflects the current level/mute state, with a slider that
/// slides out on hover instead of permanently eating horizontal space.
struct VolumeControl: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool

    @AppStorage(AppSettingsKeys.volumeBoostEnabled) private var volumeBoostEnabled = AppSettingsDefaults.volumeBoostEnabled
    @State private var isHovering = false

    private var maxVolume: Double { volumeBoostEnabled ? 2.0 : 1.0 }

    private var speakerIcon: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(systemName: speakerIcon, size: 14) {
                isMuted.toggle()
            }

            Slider(value: Binding(
                get: { isMuted ? 0 : Double(volume) },
                set: { newValue in
                    volume = Float(newValue)
                    if newValue > 0 { isMuted = false }
                }
            ), in: 0...maxVolume)
            .controlSize(.mini)
            .frame(width: isHovering ? 80 : 0)
            .opacity(isHovering ? 1 : 0)
            .clipped()
        }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        // Boost turned off mid-session with the level still pushed past unity — snap
        // it back rather than silently keep playing at a level the slider can no
        // longer even show as selected.
        .onChange(of: volumeBoostEnabled) { _, enabled in
            if !enabled, volume > 1 {
                volume = 1
            }
        }
    }
}
