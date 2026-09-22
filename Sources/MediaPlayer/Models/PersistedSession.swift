import Foundation

/// One playlist entry as saved to disk. Local files are stored as security-scoped
/// bookmarks — required because this app is sandboxed, so a plain file path/URL from a
/// previous launch is not actually readable next time without one. Network streams have
/// no such restriction, so they're just stored as a URL string.
struct PersistedPlaylistEntry: Codable {
    var bookmarkData: Data?
    var remoteURLString: String?
}

/// The whole "where you left off" snapshot: the playlist, which item was playing, and
/// how far into it you were.
struct PersistedSession: Codable {
    var entries: [PersistedPlaylistEntry]
    var currentIndex: Int?
    var currentTime: Double
    /// Which saved playlist (if any) the current queue was loaded from, purely so the
    /// sidebar header shows its name again after a relaunch instead of reverting to the
    /// generic "Playlist" label. Absent in sessions saved before this field existed —
    /// `decodeIfPresent` via the default `nil` handles that automatically.
    var activeSavedPlaylistID: UUID?
}
