import SwiftUI

struct PlaybackSpeedMenu: View {
    @Binding var rate: Float
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        Menu {
            ForEach(speeds, id: \.self) { speed in
                Button {
                    rate = speed
                } label: {
                    if speed == rate {
                        Label(label(for: speed), systemImage: "checkmark")
                    } else {
                        Text(label(for: speed))
                    }
                }
            }
        } label: {
            Text(label(for: rate))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func label(for speed: Float) -> String {
        speed == 1.0 ? "1x" : String(format: "%gx", speed)
    }
}
