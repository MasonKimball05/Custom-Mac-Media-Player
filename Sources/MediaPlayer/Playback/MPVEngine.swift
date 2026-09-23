import AppKit
import Foundation

/// libmpv-backed playback engine for everything AVFoundation can't open at all —
/// MKV, WebM, AVI, and friends. mpv bundles its own ffmpeg-based demuxer/decoders,
/// so the container format stops mattering.
///
/// mpv's C API is callback-driven from its own internal threads (the wakeup callback
/// for the event queue, the render-update callback for new video frames), which is
/// why the handle and a few flags below are `nonisolated(unsafe)`: they're simple
/// pointer/value types that this file's C trampolines touch off the main thread by
/// design, funnelling everything else back to the main actor before it reaches
/// `delegate` or view state. `@unchecked Sendable` reflects that manual bridging.
@MainActor
final class MPVEngine: NSObject, PlaybackEngine, @unchecked Sendable {
    weak var delegate: PlaybackEngineDelegate?
    let capabilities = EngineCapabilities(
        externalSubtitles: true, subtitleTiming: true, subtitleScaling: true, subtitleAppearance: true
    )

    /// Set by the video view once it has an OpenGL context ready; called on the main
    /// thread whenever mpv has a new frame so the view can mark itself for redraw.
    nonisolated(unsafe) var onRenderUpdate: (() -> Void)?

    nonisolated(unsafe) private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private static let eventQueue = DispatchQueue(label: "com.masonkimball.mediaplayer.mpv-events")

    /// Mirrors of the last time-pos/duration values, kept for the buffered-fraction
    /// calculation below — that runs on the background event-pump thread alongside
    /// `handle`, so like `handle` this is deliberately not actor-isolated.
    nonisolated(unsafe) private var lastKnownTime: Double = 0
    nonisolated(unsafe) private var lastKnownDuration: Double = 0

    override init() {
        super.init()
        setUpHandle()
    }

    private func setUpHandle() {
        guard let handle = mpv_create() else {
            delegate?.engineDidFail(message: "Could not create mpv instance.")
            return
        }

        mpv_set_option_string(handle, "vo", "libmpv")
        // mpv's own default cap is 130 — raised so the app-level volume-boost setting
        // (which is what actually gates whether callers ever send >100 here) isn't
        // silently clamped a second time underneath it.
        mpv_set_option_string(handle, "volume-max", "200")
        mpv_set_option_string(handle, "hwdec", "auto")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "input-cursor", "no")

        let initResult = mpv_initialize(handle)
        guard initResult >= 0 else {
            delegate?.engineDidFail(message: String(cString: mpv_error_string(initResult)))
            // Created but never successfully initialized — every other method's `guard let
            // handle` would otherwise treat this as a live handle if we stored it anyway.
            mpv_terminate_destroy(handle)
            return
        }
        self.handle = handle

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        // Seconds of media cached ahead of the current position — the closest mpv
        // equivalent to AVFoundation's loadedTimeRanges, used to drive the scrubber's
        // buffered-range indicator instead of leaving it pinned at "fully available".
        mpv_observe_property(handle, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)

        mpv_set_wakeup_callback(handle, mpvWakeupTrampoline, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: PlaybackEngine

    func load(url: URL) {
        guard let handle else { return }

        // Read fresh each time rather than just at setup, so flipping the setting in
        // Settings applies the next time you open a file, without needing to observe
        // UserDefaults changes live.
        let hardwareDecodingEnabled = UserDefaults.standard.object(forKey: AppSettingsKeys.hardwareDecodingEnabled) as? Bool
            ?? AppSettingsDefaults.hardwareDecodingEnabled
        mpv_set_option_string(handle, "hwdec", hardwareDecodingEnabled ? "auto" : "no")

        // A local file needs its filesystem path; anything else (http/https/rtsp/etc.,
        // reachable when an external-subtitle load force-switches a network stream onto
        // this engine) needs the full URL string, or mpv tries to open the bare path as
        // a nonexistent local file. Same distinction the M3U export code already makes.
        let target = url.isFileURL ? url.path : url.absoluteString
        target.withCString { pathPtr in
            "loadfile".withCString { cmdPtr in
                "replace".withCString { modePtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, pathPtr, modePtr, nil]
                    mpv_command(handle, &args)
                }
            }
        }
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func seek(to seconds: Double) {
        guard let handle else { return }
        String(format: "%.3f", seconds).withCString { valuePtr in
            "seek".withCString { cmdPtr in
                "absolute".withCString { modePtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, valuePtr, modePtr, nil]
                    mpv_command(handle, &args)
                }
            }
        }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        guard let handle else { return }
        var value = muted ? 0.0 : Double(volume) * 100.0
        mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &value)
    }

    func setRate(_ rate: Float) {
        guard let handle else { return }
        var value = Double(rate)
        mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func stop() {
        guard let handle else { return }
        "stop".withCString { cmdPtr in
            var args: [UnsafePointer<CChar>?] = [cmdPtr, nil]
            mpv_command(handle, &args)
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    // MARK: Tracks

    func availableAudioTracks() -> [MediaTrack] {
        tracks(ofMpvType: "audio", kind: .audio)
    }

    func availableSubtitleTracks() -> [MediaTrack] {
        tracks(ofMpvType: "sub", kind: .subtitle)
    }

    func availableChapters() -> [Chapter] {
        guard let count = getInt64Property("chapter-list/count") else { return [] }
        var result: [Chapter] = []
        for index in 0..<count {
            guard let time = getRawDoubleProperty("chapter-list/\(index)/time") else { continue }
            let title = getStringProperty("chapter-list/\(index)/title") ?? "Chapter \(index + 1)"
            result.append(Chapter(title: title, startTime: time))
        }
        return result
    }

    func selectAudioTrack(id: String?) {
        guard let handle else { return }
        mpv_set_property_string(handle, "aid", id ?? "auto")
    }

    func selectSubtitleTrack(id: String?) {
        guard let handle else { return }
        mpv_set_property_string(handle, "sid", id ?? "no")
    }

    func addExternalSubtitle(url: URL) {
        guard let handle else { return }
        url.path.withCString { pathPtr in
            "sub-add".withCString { cmdPtr in
                "select".withCString { modePtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, pathPtr, modePtr, nil]
                    mpv_command(handle, &args)
                }
            }
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        setDoubleProperty("sub-delay", seconds)
    }

    func setSubtitleScale(_ scale: Double) {
        setDoubleProperty("sub-scale", scale)
    }

    func setVideoAdjustments(brightness: Double, contrast: Double, saturation: Double, gamma: Double) {
        setDoubleProperty("brightness", brightness)
        setDoubleProperty("contrast", contrast)
        setDoubleProperty("saturation", saturation)
        setDoubleProperty("gamma", gamma)
    }

    func setSubtitleAppearance(
        fontName: String, textColorHex: String, backgroundColorHex: String, backgroundOpacity: Double, codepage: String
    ) {
        guard let handle else { return }
        mpv_set_property_string(handle, "sub-font", fontName.isEmpty ? "" : fontName)
        mpv_set_property_string(handle, "sub-color", mpvColorString(hex: textColorHex, opacity: 1))
        // Fully transparent background reads as "no box" — mpv still wants a color, just
        // with alpha 0, rather than a way to omit the back-color box entirely.
        mpv_set_property_string(handle, "sub-back-color", mpvColorString(hex: backgroundColorHex, opacity: backgroundOpacity))

        mpv_set_property_string(handle, "sub-codepage", codepage.isEmpty ? "auto" : codepage)
        // Setting the property alone doesn't retroactively re-decode subtitles mpv already
        // parsed with the old (wrong) charset guess. The obvious fix — the "sub-reload"
        // command — turns out to only work for external subtitle *files*; its own docs say
        // so, and it's silently a no-op for a track embedded in the container. Toggling the
        // current track off and back on forces mpv to re-initialize its subtitle decoder
        // either way, which does pick up a codepage change on an already-loaded file,
        // embedded or external.
        if let currentSid = getStringProperty("sid"), currentSid != "no" {
            mpv_set_property_string(handle, "sid", "no")
            mpv_set_property_string(handle, "sid", currentSid)
        }
    }

    /// mpv color options take "#RRGGBB" or "#AARRGGBB" — folds a separate 0...1 opacity
    /// into the alpha channel so callers don't have to hand-build the hex themselves.
    private func mpvColorString(hex: String, opacity: Double) -> String {
        let alpha = Int((max(0, min(1, opacity)) * 255).rounded())
        let rgb = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return String(format: "#%02X%@", alpha, rgb)
    }

    private func tracks(ofMpvType mpvType: String, kind: MediaTrack.Kind) -> [MediaTrack] {
        guard let count = getInt64Property("track-list/count") else { return [] }
        var result: [MediaTrack] = []
        for index in 0..<count {
            guard getStringProperty("track-list/\(index)/type") == mpvType,
                  let id = getInt64Property("track-list/\(index)/id") else { continue }
            result.append(MediaTrack(
                id: String(id),
                kind: kind,
                title: getStringProperty("track-list/\(index)/title") ?? "",
                languageCode: getStringProperty("track-list/\(index)/lang"),
                isSelected: getFlagProperty("track-list/\(index)/selected") ?? false
            ))
        }
        return result
    }

    // MARK: Frame step, snapshot, info

    func stepFrame(forward: Bool) {
        guard let handle else { return }
        (forward ? "frame-step" : "frame-back-step").withCString { cmdPtr in
            var args: [UnsafePointer<CChar>?] = [cmdPtr, nil]
            mpv_command(handle, &args)
        }
    }

    func saveSnapshot(to url: URL) async throws {
        guard let handle else { throw PlaybackEngineError.noMediaLoaded }
        let result = url.path.withCString { pathPtr -> Int32 in
            "screenshot-to-file".withCString { cmdPtr in
                "video".withCString { flagPtr in
                    var args: [UnsafePointer<CChar>?] = [cmdPtr, pathPtr, flagPtr, nil]
                    return mpv_command(handle, &args)
                }
            }
        }
        guard result >= 0 else {
            throw PlaybackEngineError.snapshotFailed(String(cString: mpv_error_string(result)))
        }
    }

    /// Not implemented: generating a frame at an arbitrary time without disrupting the
    /// live render context isn't something the single mpv instance we embed can do —
    /// it would need a second, offscreen mpv instance seeking independently. Scrubber
    /// hover just falls back to a text-only time tooltip for MKV/AVI/etc.
    func generateThumbnail(at seconds: Double) async -> CGImage? {
        nil
    }

    func mediaInfo() async -> MediaInfo {
        var info = MediaInfo(engineName: "mpv")
        info.containerFormat = getStringProperty("file-format")?.uppercased()
        info.fileSizeBytes = getInt64Property("file-size")
        info.videoCodec = getStringProperty("video-codec")
        if let width = getInt64Property("width"), let height = getInt64Property("height") {
            info.videoDimensions = "\(width)×\(height)"
        }
        info.frameRate = getDoubleProperty("estimated-vf-fps") ?? getDoubleProperty("container-fps")
        info.videoBitrate = getDoubleProperty("video-bitrate")
        info.audioCodec = getStringProperty("audio-codec-name") ?? getStringProperty("audio-codec")
        if let channels = getInt64Property("audio-params/channel-count") {
            info.audioChannels = Int(channels)
        }
        info.audioSampleRate = getDoubleProperty("audio-params/samplerate")
        info.audioBitrate = getDoubleProperty("audio-bitrate")
        return info
    }

    // MARK: Property read/write helpers

    private func getStringProperty(_ name: String) -> String? {
        guard let handle else { return nil }
        var ptr: UnsafeMutablePointer<CChar>?
        guard mpv_get_property(handle, name, MPV_FORMAT_STRING, &ptr) >= 0, let ptr else { return nil }
        defer { mpv_free(ptr) }
        return String(cString: ptr)
    }

    /// Treats 0 as "unavailable" — right for the media-info fields this backs (bitrate,
    /// sample rate: 0 there really does mean unknown), wrong for anything where 0 is a
    /// legitimate value (a chapter starting at time 0). Use `getRawDoubleProperty` for those.
    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value != 0 else { return nil }
        return value
    }

    private func getRawDoubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private func getInt64Property(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }

    private func getFlagProperty(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        guard let handle else { return }
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    // MARK: Rendering (called from MPVVideoView, always on the main thread)

    func createRenderContextIfNeeded() {
        guard renderContext == nil, let handle else { return }

        var initParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddressTrampoline, get_proc_address_ctx: nil)

        withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
            "opengl".withCString { apiTypePtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiTypePtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initParamsPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                var newContext: OpaquePointer?
                let result = mpv_render_context_create(&newContext, handle, &params)
                guard result >= 0, let newContext else {
                    delegate?.engineDidFail(message: "Could not create video render context: \(String(cString: mpv_error_string(result)))")
                    return
                }
                renderContext = newContext
                mpv_render_context_set_update_callback(newContext, mpvRenderUpdateTrampoline, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    func render(fboWidth: Int32, fboHeight: Int32) {
        guard let renderContext else { return }
        var fbo = mpv_opengl_fbo(fbo: 0, w: fboWidth, h: fboHeight, internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
    }

    // MARK: mpv event pump (background thread, hops back to main for anything actor-isolated)

    nonisolated func scheduleEventDrain() {
        let handle = handle
        MPVEngine.eventQueue.async { [weak self] in
            guard let handle else { return }
            while true {
                guard let eventPtr = mpv_wait_event(handle, 0) else { break }
                let event = eventPtr.pointee
                if event.event_id == MPV_EVENT_NONE { break }
                self?.process(event: event)
            }
        }
    }

    nonisolated private func process(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let dataPtr = event.data else { return }
            let property = dataPtr.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard property.format == MPV_FORMAT_DOUBLE, let namePtr = property.name, let valuePtr = property.data else { return }
            let name = String(cString: namePtr)
            let value = valuePtr.assumingMemoryBound(to: Double.self).pointee
            guard value.isFinite else { return }

            if name == "time-pos" {
                lastKnownTime = value
                notifyTimeUpdate(value)
            } else if name == "duration", value > 0 {
                lastKnownDuration = value
                notifyDurationUpdate(value)
            } else if name == "demuxer-cache-time" {
                notifyBufferedFractionUpdate(cachedAheadSeconds: value)
            }

        case MPV_EVENT_FILE_LOADED:
            notifyFileLoaded()

        case MPV_EVENT_END_FILE:
            guard let dataPtr = event.data else { return }
            let endFile = dataPtr.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if endFile.reason == MPV_END_FILE_REASON_EOF {
                notifyEndOfMedia()
            } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                notifyFailure(String(cString: mpv_error_string(endFile.error)))
            }

        default:
            break
        }
    }

    nonisolated private func notifyTimeUpdate(_ value: Double) {
        Task { @MainActor [weak self] in self?.delegate?.engineDidUpdateTime(value) }
    }

    nonisolated private func notifyDurationUpdate(_ value: Double) {
        Task { @MainActor [weak self] in self?.delegate?.engineDidUpdateDuration(value) }
    }

    nonisolated private func notifyBufferedFractionUpdate(cachedAheadSeconds: Double) {
        guard lastKnownDuration > 0 else { return }
        let fraction = min(1, max(0, (lastKnownTime + cachedAheadSeconds) / lastKnownDuration))
        Task { @MainActor [weak self] in self?.delegate?.engineDidUpdateBufferedFraction(fraction) }
    }

    nonisolated private func notifyEndOfMedia() {
        Task { @MainActor [weak self] in self?.delegate?.engineDidReachEndOfMedia() }
    }

    nonisolated private func notifyFailure(_ message: String) {
        Task { @MainActor [weak self] in self?.delegate?.engineDidFail(message: message) }
    }

    nonisolated private func notifyFileLoaded() {
        Task { @MainActor [weak self] in self?.handleFileLoaded() }
    }

    private func handleFileLoaded() {
        guard let handle else { return }

        var duration: Double = 0
        if mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0, duration > 0 {
            delegate?.engineDidUpdateDuration(duration)
        }

        var videoFormatPtr: UnsafeMutablePointer<CChar>?
        var hasVideo = false
        if mpv_get_property(handle, "video-format", MPV_FORMAT_STRING, &videoFormatPtr) >= 0, let videoFormatPtr {
            hasVideo = !String(cString: videoFormatPtr).isEmpty
            mpv_free(videoFormatPtr)
        }

        delegate?.engineDidBecomeReady(hasVideoTrack: hasVideo)
    }

    nonisolated func notifyRenderUpdate() {
        Task { @MainActor [weak self] in self?.onRenderUpdate?() }
    }
}

// MARK: - C trampolines
// libmpv calls these from its own threads; they must be plain top-level functions so
// they're convertible to the `@convention(c)` function pointers the C API expects.

private func mpvWakeupTrampoline(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue().scheduleEventDrain()
}

private func mpvRenderUpdateTrampoline(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue().notifyRenderUpdate()
}

/// Modern macOS SDKs no longer expose CGLGetProcAddress in headers (OpenGL is fully
/// deprecated), but the framework binary itself still exports every gl* symbol
/// directly — so we resolve them the way GLFW/SDL do, via dlsym against the loaded image.
private let openGLFrameworkHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

private func mpvGetProcAddressTrampoline(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    return dlsym(openGLFrameworkHandle, name)
}
