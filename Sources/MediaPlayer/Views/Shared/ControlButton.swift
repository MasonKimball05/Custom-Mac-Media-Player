import SwiftUI

/// A circular icon button used throughout the transport bar. Gives hover/press
/// feedback so the custom chrome feels alive instead of a static row of glyphs.
struct ControlButton: View {
    let systemName: String
    var size: CGFloat = 16
    var padding: CGFloat = 8
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.white.opacity(0.92))
                .frame(width: size + padding * 2, height: size + padding * 2)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.16 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
