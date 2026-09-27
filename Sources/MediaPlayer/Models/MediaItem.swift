import Foundation

enum RepeatMode {
    case off
    case one
    case all
}

/// A single piece of media (audio or video) loaded into the player's playlist.
struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    var duration: Double?
    var isVideo: Bool

    /// What makes two entries the same file, regardless of how each URL was spelled (a
    /// path from Finder versus one resolved from a saved bookmark). Streams use the URL.
    var fileIdentity: String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.duration = nil
        self.isVideo = true
    }
}
