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

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.duration = nil
        self.isVideo = true
    }
}
