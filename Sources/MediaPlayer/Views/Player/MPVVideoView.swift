import AppKit
import SwiftUI

/// Renders mpv's video output via mpv's OpenGL render API. AVPlayerLayer can't be used
/// here — it only knows how to display AVFoundation's own decode output — so mpv gets
/// its own NSOpenGLView that hands mpv a framebuffer to draw into each frame.
final class MPVOpenGLView: NSOpenGLView {
    weak var engine: MPVEngine? {
        didSet {
            engine?.onRenderUpdate = { [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    /// NSOpenGLView's actual designated initializer is `init?(frame:pixelFormat:)` — not
    /// `init(frame:)`. Overriding only `init(frame:)` (as an earlier version of this file
    /// did) makes Swift synthesize a broken bridging thunk between the two and crashes on
    /// construction. So: don't override any designated initializer, just add a convenience
    /// one that delegates to the real one, which Swift inherits automatically since `engine`
    /// (our only stored property) already has a default value.
    convenience init() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), UInt32(32),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0
        ]
        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attributes) else {
            fatalError("No supported OpenGL pixel format found — required for mpv video rendering.")
        }
        self.init(frame: .zero, pixelFormat: pixelFormat)!
        wantsBestResolutionOpenGLSurface = true
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let engine, let context = openGLContext else { return }
        context.makeCurrentContext()
        engine.createRenderContextIfNeeded()

        let backingBounds = convertToBacking(bounds)
        engine.render(fboWidth: Int32(backingBounds.width), fboHeight: Int32(backingBounds.height))
        context.flushBuffer()
    }

    override var isOpaque: Bool { true }
}

struct MPVVideoView: NSViewRepresentable {
    let engine: MPVEngine

    func makeNSView(context: Context) -> MPVOpenGLView {
        let view = MPVOpenGLView()
        view.engine = engine
        return view
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {
        if nsView.engine !== engine {
            nsView.engine = engine
        }
    }
}
