# Custom-Mac-Media-Player

I don't like QuickTime so I'm making my own.

A native macOS media player (SwiftUI + AVFoundation, with libmpv for anything
AVFoundation can't open) with fully custom playback chrome instead of the
stock QuickTime/AVPlayerView controls: a scrubber with buffered-range and
hover time preview, a slide-out volume control, playback speed menu,
configurable skip interval, shuffle + repeat-all/one, a reorderable
multi-select playlist sidebar (click to select, ⌘-click to toggle, ⇧-click
for a range, Select All, Delete/Backspace or right-click to remove, drag any
selected row to reorder the whole block) with a live "now playing" indicator,
drag & drop, native fullscreen, a Settings window (⌘,), and menu/keyboard
shortcuts (Space, ⌘O, ⌘←/→, ⌘[/⌘]).

A few VLC-style extras on top: audio/subtitle track selection, loading
external subtitle files, subtitle delay/size adjustment (mpv-backed files),
frame-by-frame stepping (⌥⌘←/→), snapshot-to-PNG (⇧⌘S), a codec/bitrate
Media Info panel (⌘I), and Open Network Stream (⇧⌘O) for direct URLs.

The playlist and playback position are remembered across launches — quit
mid-movie and reopening the app resumes right where you left off, paused.
Local files are saved as security-scoped bookmarks (required for a sandboxed
app to still have file access on a future launch — see `persistSession()`/
`restoreSession()` in [PlayerViewModel.swift](Sources/MediaPlayer/ViewModels/PlayerViewModel.swift));
if a file's moved or deleted since, it's silently dropped from the restored
list rather than breaking the rest.

### Keyboard shortcuts

Menu-bar shortcuts (shown in the Playback menu): Space play/pause, ⌘O open,
⇧⌘O open network stream, ⌘←/→ skip, ⌥⌘←/→ frame step, ⌘M mute, ⌘I media info,
⇧⌘S snapshot, ⌘]/[ next/previous track.

Plus a YouTube-style set that isn't shown in any menu (same idea as the
plain-arrow-key 5s nudge already being unlisted) — see
`handleGlobalKeyEvent(_:)` in [ContentView.swift](Sources/MediaPlayer/Views/ContentView.swift).
This is implemented as an `NSEvent` local monitor rather than SwiftUI's
`onKeyPress`: the latter only fires on a focused view, and reliably keeping
something focused across sheets, the video surface, etc. didn't work out in
practice — the handlers just silently never fired. The monitor sees every key
event in the app regardless of SwiftUI's focus state, and explicitly ignores
anything while a text field has focus (so it doesn't steal keystrokes from,
say, "Save Playlist As…" or Settings).

| Key | Action |
| --- | --- |
| `K` | Play/pause |
| `J` / `L` | Skip back/forward (configurable interval, same as ⌘←/→) |
| `←` / `→` | Nudge back/forward 5s |
| `↑` / `↓` | Volume up/down 5% |
| `M` | Toggle mute |
| `F` | Toggle fullscreen |
| `C` | Toggle subtitles on/off |
| `,` / `.` | Step one frame back/forward |
| `⇧,` / `⇧.` (`<` `>`) | Decrease/increase playback speed |
| `0`–`9` | Seek to 0%–90% of the video |
| `Home` / `End` | Seek to start/end |

### Multiple playlists / export

The menu at the top of the sidebar (click the playlist name) covers two
different ways to reuse a playlist later, which solve different problems:

- **Saved playlists** — "Save Playlist As…" snapshots the current queue into
  a named library entry you can switch back to later ("New Playlist" starts a
  fresh empty queue). These round-trip reliably across launches because they
  use the same security-scoped-bookmark mechanism as the auto-restored
  "current" queue — see `SavedPlaylist` and the "Saved playlist library"
  section of [PlayerViewModel.swift](Sources/MediaPlayer/ViewModels/PlayerViewModel.swift).
  They only work *within this app*, though — the bookmark data means nothing
  to any other program or machine.
- **Export to M3U** — writes the queue out as a standard `.m3u8` file:
  plain text, readable by VLC, iTunes, and pretty much anything else. This is
  the way to actually get a playlist *out* of the app — back it up, hand it
  to someone, open it elsewhere.
- **Import M3U** — reads one back in. Worth knowing: App Sandbox means a
  plain file path carries no access grant on its own, unlike a bookmark — so
  an M3U referencing files this app was never granted access to (most
  imports from outside the app, or from a different Mac) will have those
  entries silently skipped, with a summary of how many didn't make it. It's
  not a bug so much as a sandboxing reality; there's no way around it short
  of much broader file-access entitlements.

## Getting started

Requires Xcode 15+ and macOS 14 (Sonoma) or later, plus [Homebrew](https://brew.sh).

```bash
brew install mpv   # provides libmpv — see "MKV/AVI/etc. playback" below
open MediaPlayer.xcodeproj
```

Then hit Run (⌘R).

### Regenerating the project

The `.xcodeproj` is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) rather than committed by
hand. If you add/remove/rename source files, or need to change build
settings, edit `project.yml` and regenerate:

```bash
brew install xcodegen   # once
xcodegen generate
```

### Debug builds share state with the installed app

Every build — Debug from Xcode/DerivedData, Release, whatever's in
`~/Applications` — uses the same bundle identifier
(`com.masonkimball.MediaPlayer`), so they all share **the same sandbox
container**: the same `UserDefaults`, the same saved-playlist library, the
same auto-restored "current" queue. There's only one of each, not one per
build. Concretely: opening a test file in a Debug build appends it to
whatever playlist is currently saved — including a real one from the
installed app — and playing something in Debug moves the shared "resume
position" too. Worth keeping in mind before scripting anything against a
Debug build for testing; a `SIGKILL` (not a normal quit) is the reliable way
to throw away in-memory session changes a test run made without letting them
get written back.

### MKV/AVI/etc. playback

AVFoundation (Apple's media framework) can't open MKV, WebM, AVI, FLV, WMV, TS,
or a handful of other containers at all — not a codec-support issue, it just
doesn't know how to demux them. Rather than reject those files, the app has a
second playback engine backed by [libmpv](https://mpv.io) (bundles its own
ffmpeg-based demuxer/decoders) for exactly that set of extensions — see
`MediaFormat.requiredEngine(for:)` in
[PlaybackEngine.swift](Sources/MediaPlayer/Playback/PlaybackEngine.swift).
Everything else keeps using AVFoundation. This is why `brew install mpv` is a
build prerequisite: `project.yml` links against Homebrew's install of libmpv
directly (see the `HEADER_SEARCH_PATHS`/`LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS`
under the target's settings) rather than vendoring the library, so builds
happen on a machine that has it installed. A built `.app` is self-contained
regardless, since those paths get baked in as absolute linker paths.

## Project layout

```
Sources/MediaPlayer/
├── App/            App entry point, menu commands, Finder "Open With" handling
├── Models/         MediaItem
├── Playback/        PlaybackEngine protocol + the AVFoundation and mpv implementations
├── ViewModels/      PlayerViewModel — facade over the active engine, single source of truth
├── Views/
│   ├── Player/      Video surfaces (AVPlayerLayer, and an mpv-driven OpenGL view) + auto-hiding overlay chrome
│   ├── Controls/    Scrubber, volume, playback speed, transport bar
│   ├── Sidebar/     Playlist
│   └── Shared/      Small reusable pieces (buttons, blur material, window bridge)
└── Resources/       Info.plist, entitlements, asset catalog (app icon, accent color), mpv bridging header
```
