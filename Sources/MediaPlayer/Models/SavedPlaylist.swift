import Foundation

/// A named, user-saved playlist, kept in a small on-disk library separate from the
/// single "current" playlist that auto-restores every launch (see PersistedSession).
/// Entries reuse the same security-scoped-bookmark mechanism, since that's the only
/// way a sandboxed app keeps file access across launches — see PlayerViewModel's
/// `resolveEntry(_:)` / `makeEntry(for:)`.
struct SavedPlaylist: Codable, Identifiable {
    let id: UUID
    var name: String
    var entries: [PersistedPlaylistEntry]
}
