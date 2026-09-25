import Foundation

/// Fixes SRT files made from YouTube's automatic captions. Those captions scroll: each line
/// stays up until the line after next begins, so every cue overlaps the next one and a
/// player that follows the timing shows two stacked lines, the current one and the one
/// before it. Ending each cue where the next one starts shows one line at a time.
///
/// Only files where most cues overlap the next are changed. Ordinary subtitles overlap now
/// and then on purpose (two people talking at once), and those are left as they are.
enum RollUpCaptions {
    /// The fixed file's text, or nil if `srt` isn't roll-up captions (or can't be parsed,
    /// in which case it's better played as-is than rewritten).
    static func fixed(_ srt: String) -> String? {
        let normalized = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines))
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let cue = Cue(block: block) else { return nil }
            cues.append(cue)
        }
        guard cues.count >= 4 else { return nil }

        let overlapping = zip(cues, cues.dropFirst()).filter { $0.end > $1.start }.count
        guard overlapping * 2 >= cues.count - 1 else { return nil }

        for index in cues.indices.dropLast() where cues[index + 1].start > cues[index].start {
            cues[index].end = min(cues[index].end, cues[index + 1].start)
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\(cue.timingSuffix)\n\(cue.text)"
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// For playback: a fixed copy in the app's temporary folder if `url` is a roll-up SRT,
    /// otherwise `url` unchanged. Files that aren't UTF-8 are left alone, since rewriting
    /// them could garble a legacy encoding the Text Encoding setting would otherwise fix.
    static func playableURL(for url: URL) -> URL {
        guard url.pathExtension.lowercased() == "srt",
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let fixedText = fixed(text) else { return url }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fixedText.write(to: copy, atomically: true, encoding: .utf8)
            return copy
        } catch {
            return url
        }
    }

    /// Rewrites `url` in place if it's a roll-up SRT. For files the app itself just wrote
    /// (downloads), never for the user's own files.
    static func fixInPlace(_ url: URL) {
        guard url.pathExtension.lowercased() == "srt",
              let text = try? String(contentsOf: url, encoding: .utf8),
              let fixedText = fixed(text) else { return }
        try? fixedText.write(to: url, atomically: true, encoding: .utf8)
    }

    private struct Cue {
        var start: Int
        var end: Int
        /// Anything after the end time on the timing line (position hints), kept as-is.
        let timingSuffix: String
        let text: String

        init?(block: String) {
            var lines = block.components(separatedBy: "\n")
            // The index line is optional in practice; the timing line is what matters.
            if let first = lines.first, !first.contains("-->") {
                lines.removeFirst()
            }
            guard let timing = lines.first, let arrow = timing.range(of: "-->") else { return nil }
            let startText = timing[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = timing[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let endText = String(rest.prefix { !$0.isWhitespace })
            guard let start = RollUpCaptions.milliseconds(startText),
                  let end = RollUpCaptions.milliseconds(endText) else { return nil }
            self.start = start
            self.end = end
            timingSuffix = String(rest.dropFirst(endText.count))
            text = lines.dropFirst().joined(separator: "\n")
        }
    }

    /// "HH:MM:SS,mmm" (or with a period) to milliseconds.
    private static func milliseconds(_ text: String) -> Int? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "." }).map { Int($0) }
        guard parts.count == 4, let h = parts[0], let m = parts[1], let s = parts[2], let ms = parts[3] else { return nil }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d",
               milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
