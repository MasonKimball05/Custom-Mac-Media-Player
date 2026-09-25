import SwiftUI

/// Custom timeline scrubber: shows buffered range, a draggable playhead, and a
/// floating time-preview tooltip that follows the cursor on hover — none of
/// which the stock QuickTime slider gives you.
struct ScrubberView: View {
    let currentTime: Double
    let duration: Double
    let bufferedFraction: Double
    let onScrubStart: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    /// Returns `nil` when the active engine doesn't support previews (mpv/MKV today) or
    /// generation just failed — either way the tooltip quietly falls back to text-only.
    let thumbnailProvider: (Double) async -> CGImage?

    @State private var hoverFraction: Double?
    @State private var isDragging = false
    @State private var dragFraction: Double = 0
    @State private var previewImage: CGImage?
    @State private var thumbnailTask: Task<Void, Never>?

    private let trackHeight: CGFloat = 3
    private let expandedTrackHeight: CGFloat = 5
    private let thumbDiameter: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let playedFraction = isDragging ? dragFraction : progressFraction

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: isHoveringOrDragging ? expandedTrackHeight : trackHeight)

                // Buffered range
                Capsule()
                    .fill(Color.white.opacity(0.38))
                    .frame(width: width * bufferedFraction, height: isHoveringOrDragging ? expandedTrackHeight : trackHeight)

                // Played range
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * playedFraction, height: isHoveringOrDragging ? expandedTrackHeight : trackHeight)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: (width * playedFraction) - thumbDiameter / 2)
                    .opacity(isHoveringOrDragging ? 1 : 0)
            }
            .frame(height: barHeight)
            // Hover preview: a thumbnail when the engine can produce one, always with the
            // timestamp underneath. Positioned with alignment guides against its own measured
            // size rather than fixed offsets, since it's ~130pt wide with a thumbnail and
            // ~40pt without — fixed numbers tuned for one put the other off the pointer.
            //
            // Two layout details here were each checked by rendering (both got it wrong
            // before): an overlay aligned .topLeading ignores its content's .top/.leading
            // guides and pins it to the corner, so this uses center guides relative to the
            // bar's midpoint; and guides set *inside* the `if` are swallowed by the
            // conditional, so they're applied to a container around it instead.
            .overlay(alignment: .center) {
                ZStack {
                    if let hoverFraction, !isDragging {
                        hoverPreview(time: hoverFraction * duration)
                            .transition(.opacity)
                    }
                }
                .alignmentGuide(VerticalAlignment.center) { tooltip in
                    // Bottom edge sits just above the bar.
                    tooltip.height + tooltipGap + barHeight / 2
                }
                .alignmentGuide(HorizontalAlignment.center) { tooltip in
                    // Centered on the pointer, but kept within the bar's width at either end
                    // instead of hanging off it.
                    let pointerX = width * (hoverFraction ?? 0)
                    let halfWidth = tooltip.width / 2
                    let centerX = min(max(pointerX, halfWidth), max(halfWidth, width - halfWidth))
                    return halfWidth - (centerX - width / 2)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle().inset(by: -6))
            .animation(.easeOut(duration: 0.12), value: isHoveringOrDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onScrubStart()
                        }
                        let fraction = fraction(for: value.location.x, width: width)
                        dragFraction = fraction
                        onScrub(fraction * duration)
                    }
                    .onEnded { value in
                        let fraction = fraction(for: value.location.x, width: width)
                        isDragging = false
                        onScrubEnd(fraction * duration)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let fraction = fraction(for: location.x, width: width)
                    hoverFraction = fraction
                    scheduleThumbnailFetch(at: fraction * duration)
                case .ended:
                    hoverFraction = nil
                    previewImage = nil
                    thumbnailTask?.cancel()
                }
            }
        }
        .frame(height: 20)
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    private var isHoveringOrDragging: Bool {
        hoverFraction != nil || isDragging
    }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func hoverPreview(time: Double) -> some View {
        VStack(spacing: 4) {
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: previewWidth, height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(TimeFormatter.string(from: time))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .padding(6)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .fixedSize()
    }

    private let previewWidth: CGFloat = 120
    private let previewHeight: CGFloat = 68
    /// Height of the scrubber's hit area; the visible track is centered within it.
    private let barHeight: CGFloat = 20
    /// Space between the preview's bottom edge and the top of the hit area.
    private let tooltipGap: CGFloat = 4

    /// Debounced so dragging the cursor quickly across the whole bar doesn't fire off a
    /// generation request per pixel — only once the cursor settles somewhere briefly.
    private func scheduleThumbnailFetch(at time: Double) {
        thumbnailTask?.cancel()
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let image = await thumbnailProvider(time)
            guard !Task.isCancelled else { return }
            previewImage = image
        }
    }
}
