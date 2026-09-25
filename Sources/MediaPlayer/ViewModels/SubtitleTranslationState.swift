import Foundation
import Translation

/// The subtitle line on screen right now and, when translating, its translation. Kept off PlayerViewModel for
/// the same reason as PlaybackClock: lines change every few seconds, and only the subtitle
/// overlay needs to redraw when they do — not the whole window and its open menus.
///
/// Translation itself runs in the overlay's `.translationTask`, because that's the only
/// place a TranslationSession able to detect the source language and prompt for language
/// downloads can come from. That task pulls lines from `lines()` and hands each one back
/// to `translate(_:using:)`.
@MainActor
final class SubtitleTranslationState: ObservableObject {
    enum Status: Equatable {
        /// No subtitle text has arrived since translation started or the file loaded —
        /// usually no subtitle track is on, or the track is image-based.
        case waitingForSubtitles
        case translating
        /// Carries the detected source language's display name.
        case translated(from: String)
        case failed(String)
    }

    /// What the overlay shows while translating: the translated line, the original while a
    /// slow translation is pending or after one fails, or nil between lines.
    @Published private(set) var displayedText: String?
    @Published private(set) var status: Status = .waitingForSubtitles

    /// The line as the engine reported it — what the overlay shows when it's drawing
    /// subtitles without translating them (engines that can't reposition their own).
    @Published private(set) var sourceText: String?
    private var cache: [String: String] = [:]
    private var continuation: AsyncStream<String?>.Continuation?

    /// How long a translation can take before the original line is shown in its place, so a
    /// slow translation (or one waiting on a language download) never leaves a blank gap.
    private let originalTextFallbackDelay: Duration = .milliseconds(400)

    /// Called for every line the engine reports, translating or not, so turning translation
    /// on mid-line picks up the line that's already on screen.
    func update(sourceText: String?) {
        guard sourceText != self.sourceText else { return }
        self.sourceText = sourceText
        // No line means nothing to show, right now — not after whatever translation is
        // still in flight for the previous line finishes.
        if sourceText == nil {
            displayedText = nil
        }
        continuation?.yield(sourceText)
    }

    /// Clears everything tied to the previous file.
    func reset() {
        sourceText = nil
        displayedText = nil
        status = .waitingForSubtitles
        cache.removeAll()
    }

    /// Previous translations were into the old target language.
    func clearCache() {
        cache.removeAll()
        displayedText = nil
    }

    /// One stream per translation task run, starting with the current line. Keeps only the
    /// newest pending line: if a translation is slower than the dialogue, skipping straight to
    /// the line being spoken now beats working through a backlog that's already stale.
    func lines() -> AsyncStream<String?> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        continuation.yield(sourceText)
        return stream
    }

    func translate(_ text: String?, using session: TranslationSession) async {
        guard let text, !text.isEmpty else {
            displayedText = nil
            return
        }
        if let cached = cache[text] {
            displayedText = cached
            return
        }

        status = .translating
        let fallback = Task { [weak self, originalTextFallbackDelay] in
            try? await Task.sleep(for: originalTextFallbackDelay)
            guard let self, !Task.isCancelled, self.sourceText == text else { return }
            self.displayedText = text
        }
        defer { fallback.cancel() }

        do {
            let response = try await session.translate(text)
            cache[text] = response.targetText
            let sourceName = Locale.current.localizedString(forIdentifier: response.sourceLanguage.minimalIdentifier)
            status = .translated(from: sourceName ?? response.sourceLanguage.minimalIdentifier)
            // The dialogue may have moved on while this was translating.
            if text == sourceText {
                displayedText = response.targetText
            }
        } catch is CancellationError {
            // Translation was turned off or the target language changed mid-line.
        } catch {
            // Unsupported language pair, a declined download, or a line too short to
            // identify: showing the original beats showing nothing.
            status = .failed(error.localizedDescription)
            if text == sourceText {
                displayedText = text
            }
        }
    }
}
