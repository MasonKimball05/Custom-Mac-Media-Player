import AppKit
import AVFoundation
import Combine

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
    let capabilities = EngineCapabilities()

    let player = AVPlayer()

    private var timeObserverToken: Any?
    private var itemStatusObservation: AnyCancellable?
    private var itemDurationObservation: AnyCancellable?
    private var endObserver: AnyCancellable?

    init() {
        addPeriodicTimeObserver()
        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in self?.delegate?.engineDidReachEndOfMedia() }
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
    }

    func load(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        observe(playerItem: playerItem)
        player.replaceCurrentItem(with: playerItem)
    }

    func play() {
        player.play()
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
        if player.timeControlStatus != .paused {
            player.rate = rate
        }
    }

    func stop() {
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

    private func tracks(for characteristic: AVMediaCharacteristic, kind: MediaTrack.Kind) -> [MediaTrack] {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            MediaTrack(
                id: String(index),
                kind: kind,
                title: option.displayName,
                languageCode: option.locale?.language.languageCode?.identifier,
                isSelected: option == selected
            )
        }
    }

    private func selectTrack(id: String?, characteristic: AVMediaCharacteristic, allowsOff: Bool) {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return }
        guard let id, let index = Int(id), group.options.indices.contains(index) else {
            item.select(allowsOff ? nil : group.defaultOption, in: group)
            return
        }
        item.select(group.options[index], in: group)
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
                    let hasVideo = !playerItem.asset.tracks(withMediaType: .video).isEmpty
                    self.delegate?.engineDidBecomeReady(hasVideoTrack: hasVideo)
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
