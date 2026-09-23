import AppKit
import SwiftUI

/// Bridges trackpad-specific gestures AppKit doesn't expose to SwiftUI at all — two-finger
/// scroll for volume, pinch for playback speed — onto the video surface. Only overrides
/// `scrollWheel`/`magnify`, deliberately leaving every mouse-click method untouched, so it
/// sits over the video without taking over the click-to-play/double-click-to-fullscreen
/// gestures PlayerContainerView already owns for that same area.
struct TrackpadGestureCatcher: NSViewRepresentable {
    let onVolumeSwipe: (Double) -> Void
    let onSpeedPinch: (Double) -> Void

    func makeNSView(context: Context) -> GestureCatcherView {
        let view = GestureCatcherView()
        view.onVolumeSwipe = onVolumeSwipe
        view.onSpeedPinch = onSpeedPinch
        return view
    }

    func updateNSView(_ nsView: GestureCatcherView, context: Context) {
        nsView.onVolumeSwipe = onVolumeSwipe
        nsView.onSpeedPinch = onSpeedPinch
    }
}

final class GestureCatcherView: NSView {
    var onVolumeSwipe: ((Double) -> Void)?
    var onSpeedPinch: ((Double) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // hasPreciseScrollingDeltas is what actually distinguishes a trackpad/Magic Mouse
        // gesture from a physical scroll wheel's coarse, line-based deltas — without this
        // check, a plain mouse wheel would drive volume too, which isn't the ask.
        guard event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        onVolumeSwipe?(Double(event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        onSpeedPinch?(event.magnification)
    }
}
