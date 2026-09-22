import AVFoundation
import SwiftUI

/// Raw NSView backed by an AVPlayerLayer. We render video ourselves instead of
/// using AVPlayerView so the on-screen controls are entirely our own SwiftUI overlay.
final class VideoLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoLayerNSView {
        let view = VideoLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: VideoLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}
