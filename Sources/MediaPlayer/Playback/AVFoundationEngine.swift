import AppKit
import AVFoundation
import Combine
import CoreImage

/// Wraps AVPlayer for every format AVFoundation can natively demux (mp4, mov, m4v,
/// mp3, m4a, wav, aiff, flac...). This is the original playback path, now behind the
/// PlaybackEngine protocol so PlayerViewModel can swap it out for MPVEngine on formats
/// AVFoundation can't open at all, like MKV.
@MainActor
final class AVFoundationEngine: PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?
    /// No external subtitle loading (AVFoundation has no real support for compositing an
    /// external .srt onto an arbitrary asset) and no delay/scale controls — those aren't
    /// AVFoundation concepts. PlayerViewModel routes those actions through mpv instead.
    /// AirPlay is the one thing this engine has that mpv doesn't.
    let capabilities = EngineCapabilities(airPlay: true)

    let player = AVPlayer()

    /// What `setRate(_:)` was last asked for, reapplied after every `play()` — AVPlayer
    /// resets `rate` to 1.0 as a side effect of `play()`, and `setRate` itself is a no-op
    /// while paused (setting a nonzero rate on a paused player starts it playing), so the
    /// only reliable place to land the requested rate is right after `play()` actually runs.
    private var desiredRate: Float = 1.0

    private var timeObserverToken: Any?
    private var itemStatusObservation: AnyCancellable?
    private var itemDurationObservation: AnyCancellable?
    private var endObserver: AnyCancellable?

    /// Reports subtitle text for translation. One per item: an output can only be attached
    /// to a single AVPlayerItem at a time.
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private let legibleDelegate = LegibleOutputDelegate()
    private var nativeSubtitleRenderingEnabled = true

    init() {
        addPeriodicTimeObserver()
        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.delegate?.engineDidReachEndOfMedia() }
        legibleDelegate.onText = { [weak self] text in
            self?.delegate?.engineDidUpdateSubtitleText(text)
        }
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
    }

    func load(url: URL) {
        resetAssetDetails()
        let playerItem = AVPlayerItem(url: url)
        observe(playerItem: playerItem)
        // Adjustments carry across items once touched (same as volume/rate), so a new
        // item needs the composition too if any axis is non-default — not attached
        // unconditionally, since the custom-compositor path isn't free even at 0 change.
        if hasVideoAdjustments {
            attachVideoComposition(to: playerItem)
        }
        let output = AVPlayerItemLegibleOutput()
        output.setDelegate(legibleDelegate, queue: .main)
        output.suppressesPlayerRendering = !nativeSubtitleRenderingEnabled
        playerItem.add(output)
        legibleOutput = output
        player.replaceCurrentItem(with: playerItem)
    }

    func play() {
        player.play()
        player.rate = desiredRate
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Float, muted: Bool) {
        player.volume = muted ? 0 : volume
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    func stop() {
        resetAssetDetails()
        legibleOutput = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Tracks

    func availableAudioTracks() -> [MediaTrack] {
        tracks(for: .audible, kind: .audio)
    }

    func availableSubtitleTracks() -> [MediaTrack] {
        tracks(for: .legible, kind: .subtitle)
    }

    func availableChapters() -> [Chapter] {
        chapters
    }

    // MARK: Asset details (tracks, chapters)

    /// Loaded once per item, asynchronously, when it becomes ready. The synchronous asset
    /// accessors these replace (`mediaSelectionGroup(forMediaCharacteristic:)`,
    /// `chapterMetadataGroups`, `tracks(withMediaType:)`) block the calling thread until
    /// AVFoundation's own lower-priority loading queue is done. From the main thread,
    /// that's a priority inversion and a hang risk, and the captions menu reads these
    /// every time it redraws.
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var chapters: [Chapter] = []
    private var assetDetailsTask: Task<Void, Never>?

    private func resetAssetDetails() {
        assetDetailsTask?.cancel()
        audioGroup = nil
        legibleGroup = nil
        chapters = []
    }

    /// Reports readiness to the delegate only after everything's cached, so anything it
    /// reads in response (the view model reads chapters right away) sees the real values.
    private func loadAssetDetails(for playerItem: AVPlayerItem) {
        assetDetailsTask?.cancel()
        assetDetailsTask = Task { [weak self] in
            let asset = playerItem.asset
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            let loadedChapters = await Self.loadChapters(from: asset)

            // A different file may have been loaded while this was in flight.
            guard let self, !Task.isCancelled, self.player.currentItem === playerItem else { return }
            self.audioGroup = audio
            self.legibleGroup = legible
            self.chapters = loadedChapters
            self.delegate?.engineDidBecomeReady(hasVideoTrack: !videoTracks.isEmpty)
        }
    }

    private static func loadChapters(from asset: AVAsset) async -> [Chapter] {
        guard let groups = try? await asset.loadChapterMetadataGroups(
            withTitleLocale: .current, containingItemsWithCommonKeys: [.commonKeyTitle]
        ) else { return [] }

        var result: [Chapter] = []
        for group in groups {
            var title: String?
            if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }) {
                title = try? await titleItem.load(.stringValue)
            }
            result.append(Chapter(title: title ?? "Chapter \(result.count + 1)", startTime: group.timeRange.start.seconds))
        }
        return result
    }

    private func selectionGroup(for characteristic: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        characteristic == .audible ? audioGroup : legibleGroup
    }

    func selectAudioTrack(id: String?) {
        selectTrack(id: id, characteristic: .audible, allowsOff: false)
    }

    func selectSubtitleTrack(id: String?) {
        selectTrack(id: id, characteristic: .legible, allowsOff: true)
    }

    func addExternalSubtitle(url: URL) {
        // Unsupported — see `capabilities`.
    }

    func setSubtitleDelay(_ seconds: Double) {
        // Unsupported — see `capabilities`.
    }

    func setSubtitleScale(_ scale: Double) {
        // Unsupported — see `capabilities`.
    }

    // MARK: Video adjustments

    /// Read live, every frame, by the CIFilter chain in `attachVideoComposition` — so
    /// changing these needs no composition rebuild, just an ivar write. `nonisolated(unsafe)`
    /// for the same reason MPVEngine's `handle` is: the filter handler below runs on
    /// AVFoundation's own rendering thread, off the main actor, by design — hopping back
    /// to main per frame for four Doubles isn't worth what it'd cost on the render path.
    nonisolated(unsafe) private var videoBrightness: Double = 0
    nonisolated(unsafe) private var videoContrast: Double = 0
    nonisolated(unsafe) private var videoSaturation: Double = 0
    nonisolated(unsafe) private var videoGamma: Double = 0

    private var hasVideoAdjustments: Bool {
        videoBrightness != 0 || videoContrast != 0 || videoSaturation != 0 || videoGamma != 0
    }

    func setVideoAdjustments(brightness: Double, contrast: Double, saturation: Double, gamma: Double) {
        videoBrightness = brightness
        videoContrast = contrast
        videoSaturation = saturation
        videoGamma = gamma
        if hasVideoAdjustments, let currentItem = player.currentItem, currentItem.videoComposition == nil {
            attachVideoComposition(to: currentItem)
        }
    }

    /// CIColorControls covers brightness/contrast/saturation; gamma isn't one of its
    /// inputs, so a second CIGammaAdjust pass handles that axis. mpv's -100...100 range is
    /// followed here too, mapped onto each filter's own native range.
    ///
    /// The synchronous `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`
    /// initializer is deprecated as of macOS 15 in favor of this async factory — the
    /// filter handler itself still runs synchronously per-frame either way, only
    /// building the composition object up front becomes a completion-handler callback.
    /// The whole `AVMutableVideoComposition` class is itself further deprecated as of
    /// macOS 26 in favor of a new `AVVideoComposition.Configuration` API with no
    /// established usage patterns yet at time of writing — not worth chasing for one
    /// warning until it's had a macOS release or two to mature.
    private func attachVideoComposition(to playerItem: AVPlayerItem) {
        AVMutableVideoComposition.videoComposition(with: playerItem.asset, applyingCIFiltersWithHandler: { [weak self] request in
            guard let self else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            var image = request.sourceImage
            if self.videoBrightness != 0 || self.videoContrast != 0 || self.videoSaturation != 0 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: self.videoBrightness / 100,
                    kCIInputContrastKey: 1.0 + self.videoContrast / 100,
                    kCIInputSaturationKey: 1.0 + self.videoSaturation / 100
                ])
            }
            if self.videoGamma != 0 {
                let power = max(0.1, 1.0 - self.videoGamma / 100)
                image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
            }
            request.finish(with: image, context: nil)
        }, completionHandler: { [weak playerItem] composition, _ in
            guard let composition, let playerItem else { return }
            Task { @MainActor in
                playerItem.videoComposition = composition
            }
        })
    }

    func setSubtitleAppearance(
        fontName: String, textColorHex: String, backgroundColorHex: String, backgroundOpacity: Double, codepage: String
    ) {
        // Unsupported — see `capabilities`.
    }

    func setNativeSubtitleRenderingEnabled(_ enabled: Bool) {
        nativeSubtitleRenderingEnabled = enabled
        legibleOutput?.suppressesPlayerRendering = !enabled
    }

    func setSubtitleBottomInset(_ fraction: Double) {
        // Unsupported — AVPlayerLayer's subtitle position can't be moved, so the app draws
        // subtitles itself for this engine (see `capabilities`).
    }

    private func tracks(for characteristic: AVMediaCharacteristic, kind: MediaTrack.Kind) -> [MediaTrack] {
        guard let item = player.currentItem, let group = selectionGroup(for: characteristic) else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        // AVFoundation pairs each subtitle track with a "Forced" variant that only shows
        // the lines marked forced (usually none), and selects that variant by default when
        // the system's caption preference is off. It isn't a real choice to offer, and
        // counting it as selected made subtitles read as on while nothing was showing.
        // The ids stay indexes into the full `group.options`, which is what selection uses.
        return group.options.enumerated().compactMap { index, option in
            if characteristic == .legible, option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
                return nil
            }
            // macOS can offer a subtitle option it generates by transcribing the audio, in a
            // language it guesses (English when the audio track isn't tagged with one). On
            // audio in any other language that produces phonetic nonsense, so it's labeled as
            // what it is rather than looking like a real subtitle track.
            let isGenerated = option.hasMediaCharacteristic(.machineGenerated)
            return MediaTrack(
                id: String(index),
                kind: kind,
                title: isGenerated ? "Auto-generated from audio" : option.displayName,
                languageCode: option.locale?.language.languageCode?.identifier,
                isSelected: option == selected
            )
        }
    }

    private func selectTrack(id: String?, characteristic: AVMediaCharacteristic, allowsOff: Bool) {
        guard let item = player.currentItem, let group = selectionGroup(for: characteristic) else { return }
        guard let id, let index = Int(id), group.options.indices.contains(index) else {
            item.select(allowsOff ? nil : group.defaultOption, in: group)
            return
        }
        item.select(group.options[index], in: group)
        // The legible output only reports a line when it starts, so a track turned on
        // partway through a line would show nothing until the next one. Seeking in place
        // makes AVFoundation send the line that's on screen now.
        if characteristic == .legible {
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: Frame step, snapshot, info

    func stepFrame(forward: Bool) {
        player.currentItem?.step(byCount: forward ? 1 : -1)
    }

    func saveSnapshot(to url: URL) async throws {
        guard let item = player.currentItem else { throw PlaybackEngineError.noMediaLoaded }

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let result = try await generator.image(at: player.currentTime())
        let bitmap = NSBitmapImageRep(cgImage: result.image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PlaybackEngineError.snapshotEncodingFailed
        }
        try data.write(to: url)
    }

    func generateThumbnail(at seconds: Double) async -> CGImage? {
        guard let asset = player.currentItem?.asset else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        // A loose tolerance lets the generator grab the nearest keyframe instead of
        // decoding to the exact frame — the difference is invisible at this size, and
        // it's the difference between a preview that feels instant and one that doesn't.
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    func mediaInfo() async -> MediaInfo {
        var info = MediaInfo(engineName: "AVFoundation")
        guard let item = player.currentItem else { return info }
        let asset = item.asset

        if let urlAsset = asset as? AVURLAsset {
            info.fileSizeBytes = try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)[.size] as? Int64
            info.containerFormat = urlAsset.url.pathExtension.uppercased()
        }

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await videoTrack.load(.naturalSize) {
                info.videoDimensions = "\(Int(size.width))×\(Int(size.height))"
            }
            if let rate = try? await videoTrack.load(.nominalFrameRate) {
                info.frameRate = Double(rate)
            }
            if let dataRate = try? await videoTrack.load(.estimatedDataRate) {
                info.videoBitrate = Double(dataRate)
            }
            if let descriptions = try? await videoTrack.load(.formatDescriptions), let first = descriptions.first {
                info.videoCodec = Self.friendlyCodecName(CMFormatDescriptionGetMediaSubType(first))
            }
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let dataRate = try? await audioTrack.load(.estimatedDataRate) {
                info.audioBitrate = Double(dataRate)
            }
            if let descriptions = try? await audioTrack.load(.formatDescriptions), let first = descriptions.first {
                info.audioCodec = Self.friendlyCodecName(CMFormatDescriptionGetMediaSubType(first))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
                    info.audioSampleRate = asbd.mSampleRate
                    info.audioChannels = Int(asbd.mChannelsPerFrame)
                }
            }
        }

        return info
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }

    private static func friendlyCodecName(_ code: FourCharCode) -> String {
        switch fourCCString(code).lowercased() {
        case "avc1", "h264": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case "ap4h", "apch", "apcn", "apcs", "ap4x": return "ProRes"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "lpcm", "twos", "sowt", "in24", "in32": return "PCM"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        default: return fourCCString(code).uppercased()
        }
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.seconds.isFinite else { return }
            self.delegate?.engineDidUpdateTime(time.seconds)

            if let item = self.player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                let loaded = item.loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
                self.delegate?.engineDidUpdateBufferedFraction(min(1, loaded / item.duration.seconds))
            }
        }
    }

    private func observe(playerItem: AVPlayerItem) {
        itemStatusObservation = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.loadAssetDetails(for: playerItem)
                case .failed:
                    self.delegate?.engineDidFail(message: playerItem.error?.localizedDescription ?? "Playback failed.")
                default:
                    break
                }
            }

        itemDurationObservation = playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cmTime in
                let seconds = cmTime.seconds
                guard seconds.isFinite, seconds > 0 else { return }
                self?.delegate?.engineDidUpdateDuration(seconds)
            }
    }
}

/// AVPlayerItemLegibleOutput needs an NSObject delegate, which the engine isn't.
private final class LegibleOutputDelegate: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var onText: (@MainActor (String?) -> Void)?

    // Explicitly @objc: this is an *optional* protocol method, which AVFoundation only
    // calls if the object responds to its selector, and Swift doesn't infer @objc for it
    // on a private class. Without this it compiled fine, and it was silently never called.
    @objc func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any],
        forItemTime itemTime: CMTime
    ) {
        let text = strings.map(\.string).joined(separator: "\n")
        // Delivered on the main queue — see setDelegate(_:queue:) in AVFoundationEngine.load.
        MainActor.assumeIsolated {
            onText?(text.isEmpty ? nil : text)
        }
    }
}
