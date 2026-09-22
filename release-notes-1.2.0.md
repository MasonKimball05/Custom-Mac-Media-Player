## v1.2.0

This release adds a second playback engine, full playlist management, and a set of macOS system integrations (Control Center, AirPlay, media keys).

### MKV / AVI / WebM Playback

AVFoundation cannot open these containers at all, regardless of the codec inside. This release adds a second playback engine backed by [libmpv](https://mpv.io) to handle them instead. The app automatically routes each file to whichever engine it requires.

- Native support for MKV, WebM, AVI, FLV, WMV, TS, M2TS, VOB, and OGV
- Hardware-accelerated decoding, with a Settings toggle to force software decoding if needed

### Playlists

- **Multi-select** — click to select, Command-click to toggle, Shift-click for a range, Select All, Delete/Backspace or right-click to remove, drag any selected row to reorder the whole block
- **Multiple named playlists** — save the current queue under a name, switch between saved playlists, rename or delete them
- **Export / import as `.m3u8`** — a standard playlist format readable by VLC, iTunes, and other players
- **Session restore** — quitting mid-playback and reopening the app resumes at the same position, paused
- **File > Open Recent** — the last 10 opened files, one click to reopen

### Keyboard Shortcuts

A full shortcut set modeled on YouTube's conventions: `K` play/pause, `J`/`L` skip, arrow keys nudge/adjust volume, `M` mute, `F` fullscreen, `C` captions, `,`/`.` frame step, `<`/`>` speed, `0`–`9` seek to 0–90%, `Home`/`End` seek to start/end — in addition to the existing menu shortcuts (Cmd+O, Cmd+Left/Right, Cmd+M, etc.).

### Additional Playback Features

- Audio and subtitle track selection for files with multiple language tracks
- External subtitle file loading (`.srt`, `.ass`, `.ssa`, `.vtt`)
- Subtitle delay and size adjustment
- Frame-by-frame stepping (Option+Cmd+Left/Right)
- Snapshot to PNG (Shift+Cmd+S)
- Media Info panel showing codec, resolution, frame rate, and bitrate (Cmd+I)
- Open Network Stream for playing a direct URL (Shift+Cmd+O)
- Shuffle and repeat-all/repeat-one
- Configurable skip interval (Settings)

### macOS Integration

- Control Center and media key support: play/pause/skip from the keyboard's media keys, AirPods, or Control Center's Now Playing widget
- AirPlay support via a native route picker button (AVFoundation-backed files)
- A chapters menu for files that include chapter markers
- Thumbnail previews on scrubber hover, in place of a timestamp only (AVFoundation-backed files)

### Fixes and Refinements

- Keyboard shortcuts now function correctly (previously non-functional due to a SwiftUI focus issue; rebuilt on an `NSEvent` monitor instead)
- The sidebar no longer expands to an excessive width in fullscreen; it now has a fixed, draggable width that persists across launches
- Fixed the scrubber's hover time tooltip being clipped
- Fixed a duplicate menu-indicator arrow on the playlist menu
- The window toolbar, including the sidebar toggle, now hides along with the rest of the controls in fullscreen
- Added a Settings window (General and Playback panes)
- Added a Clear Playlist action, with confirmation

### Requirements

- macOS 26 or later, Apple Silicon
- Building from source requires [Homebrew](https://brew.sh) (`brew install mpv xcodegen`); see the README for details
