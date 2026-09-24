import Foundation
import Translation

/// The subtitle line on screen right now and its translation. Kept off PlayerViewModel for
/// the same reason as PlaybackClock: lines change every few seconds, and only the subtitle
/// overlay needs to redraw when they do — not the whole window and its open menus.
///
/// Translation itself runs in the overlay's `.translationTask`, because that's the only
/// place a TranslationSession able to detect the source language and prompt for language
/// downloads can come from. That task pulls lines from `lines()` and hands each one back
/// to `translate(_:using:)`.
@MainActor
final class SubtitleTranslationState: ObservableObject {
    /// What the overlay shows: the translation of the current line, or nil for no line.
    @Published private(set) var displayedText: String?

    private var sourceText: String?
    private var cache: [String: String] = [:]
    private var continuation: AsyncStream<String?>.Continuation?

    /// Called for every line the engine reports, translating or not, so turning translation
    /// on mid-line picks up the line that's already on screen.
    func update(sourceText: String?) {
        guard sourceText != self.sourceText else { return }
        self.sourceText = sourceText
        continuation?.yield(sourceText)
    }

    /// Clears everything tied to the previous file.
    func reset() {
        sourceText = nil
        displayedText = nil
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
        let result: String
        do {
            result = try await session.translate(text).targetText
            cache[text] = result
        } catch {
            // Unsupported language pair, a declined download, or a line too short to
            // identify: showing the original beats showing nothing.
            result = text
        }
        // The dialogue may have moved on while this was translating.
        if text == sourceText {
            displayedText = result
        }
    }
}
