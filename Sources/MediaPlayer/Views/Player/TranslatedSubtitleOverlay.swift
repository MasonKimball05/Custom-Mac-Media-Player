import SwiftUI
import Translation

/// Draws translated subtitle lines over the video while translation is on, and hosts the
/// translation session. The engine's own subtitle rendering is turned off meanwhile (see
/// PlayerViewModel.translateSubtitles), so this is the only subtitle on screen.
///
/// `.translationTask` is what provides the session: it's the variant that can detect the
/// source language by itself and ask macOS to download a language pair the first time
/// it's needed. The session only lives as long as this view, which only exists while
/// translation is on — so turning it off, or changing the target language (a different
/// configuration), ends the task cleanly and starts a fresh one.
struct TranslatedSubtitleOverlay: View {
    @ObservedObject var state: SubtitleTranslationState
    let targetLanguage: String
    /// Lifts the line above the transport bar while that's showing, so they don't overlap.
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                if let text = state.displayedText {
                    Text(text)
                        .font(.system(size: max(16, geometry.size.height * 0.042), weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 40)
                        .padding(.bottom, controlsVisible ? 120 : 36)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .translationTask(TranslationSession.Configuration(target: Locale.Language(identifier: targetLanguage))) { @MainActor session in
            for await line in state.lines() {
                await state.translate(line, using: session)
            }
        }
    }
}
