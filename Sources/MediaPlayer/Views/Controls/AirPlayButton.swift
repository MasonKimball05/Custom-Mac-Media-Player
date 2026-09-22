import AVKit
import SwiftUI

/// Native AirPlay picker button (AVKit's own control — same one QuickTime/Safari show).
/// Only meaningful for the AVFoundation engine: it routes an AVPlayer's output, and mpv
/// has no equivalent hook, so this is hidden entirely for MKV/AVI/etc. playback rather
/// than shown greyed-out and confusing.
struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
