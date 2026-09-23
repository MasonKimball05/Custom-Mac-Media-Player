import SwiftUI

/// Three-tap cycle: mark the loop start, mark the loop end (which activates looping),
/// tap again to clear. The label itself carries the state instead of an icon, since
/// "A", "A…", and "A→B" read clearer at a glance here than any single glyph would.
struct ABLoopButton: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var isHovering = false

    private var label: String {
        if viewModel.isLoopActive { return "A→B" }
        if viewModel.loopPointA != nil { return "A…" }
        return "A–B"
    }

    private var helpText: String {
        if viewModel.isLoopActive { return "Looping — click to clear" }
        if viewModel.loopPointA != nil { return "Set Loop End (B)" }
        return "Set Loop Start (A)"
    }

    var body: some View {
        Button(action: handleTap) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(viewModel.isLoopActive ? Color.accentColor : Color.white.opacity(0.92))
                .frame(minWidth: 28, minHeight: 26)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isHovering ? 0.16 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            if viewModel.loopPointA != nil {
                Button("Clear Loop", role: .destructive) {
                    viewModel.clearLoop()
                }
            }
        }
    }

    private func handleTap() {
        if viewModel.isLoopActive {
            viewModel.clearLoop()
        } else if viewModel.loopPointA != nil {
            viewModel.setLoopPointB()
        } else {
            viewModel.setLoopPointA()
        }
    }
}
