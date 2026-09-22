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

    private let trackHeight: CGFloat = 4
    private let expandedTrackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 12

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

                // Hover preview: a thumbnail when the engine can produce one, always with
                // the timestamp underneath.
                if let hoverFraction, !isDragging {
                    let previewTime = hoverFraction * duration
                    VStack(spacing: 4) {
                        if let previewImage {
                            Image(decorative: previewImage, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: previewWidth, height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text(TimeFormatter.string(from: previewTime))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(6)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .offset(
                        x: clampedTooltipOffset(fraction: hoverFraction, width: width),
                        y: previewImage != nil ? -(previewHeight + 34) : -26
                    )
                    .transition(.opacity)
                }
            }
            .frame(height: 20)
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

    private func clampedTooltipOffset(fraction: Double, width: CGFloat) -> CGFloat {
        let raw = width * fraction - 18
        return min(max(raw, 0), width - 36)
    }

    private let previewWidth: CGFloat = 120
    private let previewHeight: CGFloat = 68

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
