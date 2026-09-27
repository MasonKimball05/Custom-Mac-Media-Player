import CoreGraphics
import Foundation

/// Still frames from mpv-backed files (MKV, WebM, AVI, ...) for the scrubber's hover preview
/// and the home screen's Continue Watching thumbnails, which AVAssetImageGenerator can't
/// read. A second, hidden mpv instance with no video output (`vo=null`) seeks to the time
/// and hands back the decoded frame (`screenshot-raw video`), in a few hundredths of a second
/// for a local file. It's separate from the player's own instance, so previews never move
/// playback.
///
/// All mpv calls here block, so they run on one serial queue, off the main thread.
final class MPVThumbnailer: @unchecked Sendable {
    static let shared = MPVThumbnailer()

    private let queue = DispatchQueue(label: "MPVThumbnailer", qos: .userInitiated)
    // Touched only on `queue`.
    private var handle: OpaquePointer?
    private var loadedPath: String?

    private let lock = NSLock()
    private var latestPreviewRequest = 0

    /// The frame at `seconds`, at most `maxWidth` wide. Seeks are exact: even on 1080p video
    /// that takes about 0.05s, and a keyframe seek could land several seconds away. For
    /// `isPreview` requests (the scrubber), a newer one replaces any still waiting, since
    /// only the frame under the pointer now matters. Other requests all run.
    func thumbnail(for url: URL, at seconds: Double, maxWidth: Int, isPreview: Bool) async -> CGImage? {
        guard url.isFileURL else { return nil }
        let request = isPreview ? lock.withLock { latestPreviewRequest += 1; return latestPreviewRequest } : 0
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if isPreview, lock.withLock({ request != latestPreviewRequest }) {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: frame(path: url.path, at: seconds, maxWidth: maxWidth))
            }
        }
    }

    // MARK: On `queue`

    private func frame(path: String, at seconds: Double, maxWidth: Int) -> CGImage? {
        guard let handle = handleIfReady() else { return nil }
        // An event from a request that gave up waiting (a slow seek) would otherwise be
        // taken as this request's.
        while let pending = mpv_wait_event(handle, 0)?.pointee, pending.event_id != MPV_EVENT_NONE {
            if pending.event_id == MPV_EVENT_END_FILE { loadedPath = nil }
        }
        let target = String(format: "%.3f", max(0, seconds))
        if loadedPath != path {
            loadedPath = nil
            mpv_set_property_string(handle, "start", target)
            guard command(handle, ["loadfile", path]) >= 0, waitFor(MPV_EVENT_PLAYBACK_RESTART, handle) else { return nil }
            loadedPath = path
        } else {
            guard command(handle, ["seek", target, "absolute+exact"]) >= 0,
                  waitFor(MPV_EVENT_PLAYBACK_RESTART, handle) else { return nil }
        }
        return screenshot(handle, maxWidth: maxWidth)
    }

    private func handleIfReady() -> OpaquePointer? {
        if let handle { return handle }
        guard let created = mpv_create() else { return nil }
        let options = [
            ("vo", "null"), ("ao", "null"), ("aid", "no"), ("sid", "no"), ("pause", "yes"),
            ("hr-seek", "yes"), ("hwdec", "no"), ("config", "no"), ("terminal", "no"),
            ("input-default-bindings", "no"), ("osc", "no"), ("ytdl", "no"),
            // The same reasons as the player's own instance (see MPVEngine): no Lua scripts,
            // and no looking through the file's folder, which the sandbox can't read.
            ("load-scripts", "no"), ("load-stats-overlay", "no"), ("load-console", "no"),
            ("load-osd-console", "no"), ("load-auto-profiles", "no"), ("load-select", "no"),
            ("load-positioning", "no"), ("load-commands", "no"), ("load-context-menu", "no"),
            ("sub-auto", "no"), ("audio-file-auto", "no"), ("cover-art-auto", "no"),
        ]
        for (name, value) in options {
            mpv_set_option_string(created, name, value)
        }
        guard mpv_initialize(created) >= 0 else {
            mpv_terminate_destroy(created)
            return nil
        }
        handle = created
        return created
    }

    /// Waits for `event`, giving up after a few seconds or if the file fails to load.
    private func waitFor(_ event: mpv_event_id, _ handle: OpaquePointer) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            guard let next = mpv_wait_event(handle, deadline.timeIntervalSinceNow)?.pointee else { return false }
            if next.event_id == event { return true }
            if next.event_id == MPV_EVENT_END_FILE {
                loadedPath = nil
                return false
            }
        }
        return false
    }

    private func command(_ handle: OpaquePointer, _ args: [String]) -> Int32 {
        var cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) } + [nil]
        return mpv_command(handle, &pointers)
    }

    /// The current decoded frame (before any scaling for display), converted to a CGImage
    /// and scaled down to `maxWidth`.
    private func screenshot(_ handle: OpaquePointer, maxWidth: Int) -> CGImage? {
        let names = ["screenshot-raw", "video"]
        var cStrings = names.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) } + [nil]
        var result = mpv_node()
        guard mpv_command_ret(handle, &pointers, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let map = result.u.list?.pointee else { return nil }

        var width = 0, height = 0, stride = 0
        var format = ""
        var bytes: UnsafeMutableRawPointer?
        var byteCount = 0
        for index in 0..<Int(map.num) {
            guard let key = map.keys?[index].map({ String(cString: $0) }), let value = map.values?[index] else { continue }
            switch key {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "format": format = value.u.string.map { String(cString: $0) } ?? ""
            case "data":
                if let array = value.u.ba?.pointee {
                    bytes = array.data
                    byteCount = array.size
                }
            default: break
            }
        }
        // "bgr0" is what mpv hands back for video frames: 4 bytes a pixel, B G R and unused.
        guard format == "bgr0", width > 0, height > 0, stride >= width * 4, let bytes, byteCount >= stride * height,
              let provider = CGDataProvider(data: Data(bytes: bytes, count: stride * height) as CFData),
              let full = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return scaled(full, maxWidth: maxWidth)
    }

    private func scaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let size = (width: maxWidth, height: max(1, Int((Double(image.height) * scale).rounded())))
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage() ?? image
    }
}
