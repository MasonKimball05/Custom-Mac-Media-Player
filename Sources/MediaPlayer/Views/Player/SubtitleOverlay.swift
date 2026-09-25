import SwiftUI
import Translation

/// Subtitles drawn by the app rather than the engine: always while translating, and for an
/// engine that can't move its own subtitles clear of the controls bar (AVFoundation). The
/// engine's own rendering is turned off meanwhile (PlayerViewModel.drawsSubtitlesInApp), so
/// this is the only subtitle on screen.
///
/// While translating, this also hosts the translation session. `.translationTask` is what
/// provides it: the variant that can detect the source language by itself and ask macOS to
/// download a language pair the first time it's needed. The session lives only while
/// translation is on, so turning it off or changing the target language (a different
/// configuration) ends the task cleanly and starts a fresh one.
struct SubtitleOverlay: View {
    @ObservedObject var state: SubtitleTranslationState
    let isTranslating: Bool
    let targetLanguage: String
    /// Distance from the bottom of the video to the subtitle — larger while the controls bar
    /// is showing, so the line sits above it instead of underneath.
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                Spacer()
                if let statusHint {
                    Text(statusHint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                if let text = isTranslating ? state.displayedText : state.sourceText {
                    Text(text)
                        .font(.system(size: max(16, geometry.size.height * 0.042), weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: bottomInset)
        .translationTask(translationConfiguration) { @MainActor session in
            for await line in state.lines() {
                await state.translate(line, using: session)
            }
        }
    }

    /// nil while not translating, which keeps the translation task from running at all.
    private var translationConfiguration: TranslationSession.Configuration? {
        isTranslating ? TranslationSession.Configuration(target: Locale.Language(identifier: targetLanguage)) : nil
    }

    /// Only while translating, and only for states where the reason nothing (or only the
    /// original) is on screen isn't otherwise visible.
    private var statusHint: String? {
        guard isTranslating else { return nil }
        switch state.status {
        case .waitingForSubtitles:
            return "Translation is on, waiting for subtitles. Make sure a text subtitle track is selected."
        case .failed(let reason):
            return "Couldn't translate: \(reason)"
        case .translating, .translated:
            return nil
        }
    }
}
