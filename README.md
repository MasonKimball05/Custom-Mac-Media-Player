# Custom-Mac-Media-Player

I don't like QuickTime so I'm making my own.

A native macOS media player (SwiftUI + AVFoundation, with libmpv for anything
AVFoundation can't open) with fully custom playback chrome instead of the
stock QuickTime/AVPlayerView controls, laid out like YouTube's player: a
full-width scrubber with buffered-range and hover time preview over a
gradient that fades up from the bottom, an elapsed / total time readout
with the current chapter (click it for time remaining), a one-click CC
toggle, a settings gear for subtitles, audio track, chapters, playback
speed, and video adjustments, a slide-out volume control,
configurable skip interval, shuffle + repeat-all/one, a reorderable
multi-select playlist sidebar (click to select, ⌘-click to toggle, ⇧-click
for a range, Select All, Delete/Backspace or right-click to remove, drag any
selected row to reorder the whole block, a filter field to narrow a long
list) with a live "now playing" indicator, drag & drop, Open ▸ Open Folder…
to recursively add everything playable in a directory at once, native
fullscreen, a Float on Top toolbar toggle, a Settings window (⌘,) with
remappable keyboard shortcuts, and menu/keyboard shortcuts (Space, ⌘O,
⌘←/→, ⌘[/⌘]).

A few VLC-style extras on top: audio/subtitle track selection, loading
external subtitle files, subtitle delay/size/appearance adjustment (font,
text color, background — mpv-backed files), frame-by-frame stepping
(⌥⌘←/→), snapshot-to-PNG (⇧⌘S), a codec/bitrate Media Info panel (⌘I), Open
Network Stream (⇧⌘O) for direct URLs, an A–B loop button, video
brightness/contrast/saturation/gamma adjustment, and a volume-boost toggle
for pushing the slider past 100%. The video and subtitle-appearance controls
live behind the sliders button in the transport bar.

That same popover has a subtitle **Text Encoding** picker (mpv-backed
files). If a subtitle track shows up as garbled Latin-looking characters,
the file is almost certainly in a legacy, non-UTF-8 encoding that mpv's
charset auto-detection guessed wrong (Greek Windows-1253 subtitles are a
common case). Picking the right encoding re-decodes the current track in
place. This works for tracks embedded in the container too: rather than
mpv's `sub-reload` command, which only applies to external subtitle files,
it re-selects the current track — see `setSubtitleAppearance` in
[MPVEngine.swift](Sources/MediaPlayer/Playback/MPVEngine.swift).

### Subtitle translation

Turn it on from the settings gear (Subtitles ▸ Translate Subtitles) or the
gear's Video & Subtitle Adjustments panel, which also sets the target language (defaults to your
system language). It works with both engines and translates on-device, using
Apple's Translation framework:

- Each engine reports the plain text of the current subtitle line: mpv
  through its `sub-text` property, AVFoundation through an
  `AVPlayerItemLegibleOutput`. While translation is on, the engine's own
  subtitle rendering is turned off (`sub-visibility`,
  `suppressesPlayerRendering`) and
  [SubtitleOverlay.swift](Sources/MediaPlayer/Views/Player/SubtitleOverlay.swift)
  draws the translated line instead.
- The legible output's delegate method has to be marked `@objc` explicitly.
  It's an *optional* protocol method, and Swift doesn't infer `@objc` for one
  on a `private` class, so without the attribute AVFoundation never finds it
  and no subtitle text ever arrives. Nothing fails loudly; the overlay just
  stays empty.
- The session comes from SwiftUI's `.translationTask`, the variant that
  detects the source language on its own and asks macOS to download a
  language pair the first time it's needed. If a line can't be translated (an
  unsupported pair, a declined download, a line too short to identify), the
  original line is shown.
- Lines and translations live on `SubtitleTranslationState`, separate from
  the view model, for the same reason as `PlaybackClock` below: lines change
  every few seconds and only the overlay needs to redraw.
- A subtitle track has to be on, and it has to be text-based. Image-based
  subtitles (common on Blu-ray and DVD rips) have no text to translate. Text
  that's already garbled from a wrong encoding won't translate either, so fix
  the Text Encoding first.

And a round of "feels like a real Mac app" polish: Control Center/media-key
integration (play/pause from the keyboard, AirPods, or the Now Playing
widget — see `setUpNowPlayingCommands()`/`updateNowPlayingInfo()` in
[PlayerViewModel.swift](Sources/MediaPlayer/ViewModels/PlayerViewModel.swift)),
a menu-bar "Now Playing" item with its own quick transport controls for when
the main window's buried behind other windows, an AirPlay button
(AVFoundation-backed files only — mpv has no equivalent hook), a chapters
menu for files that have them, thumbnail previews on scrubber hover (also
AVFoundation-only, for the same reason — see the `generateThumbnail` doc
comment on `PlaybackEngine`), File ▸ Open Recent, and renaming saved
playlists.

The playlist and playback position are remembered across launches — quit
mid-movie and reopening the app resumes right where you left off, paused.
Local files are saved as security-scoped bookmarks (required for a sandboxed
app to still have file access on a future launch — see `persistSession()`/
`restoreSession()` in [PlayerViewModel.swift](Sources/MediaPlayer/ViewModels/PlayerViewModel.swift));
if a file's moved or deleted since, it's silently dropped from the restored
list rather than breaking the rest.

Separately, every file you've watched more than a few seconds of remembers
its *own* resume position too — keyed by URL, not tied to "the current
queue" — so reopening something via Open Recent, a different saved
playlist, or a fresh drag-and-drop picks up where you left off even if it's
long since scrolled out of the queue that was active when you last watched
it. See "Per-file resume position" in
[PlayerViewModel.swift](Sources/MediaPlayer/ViewModels/PlayerViewModel.swift).

### Home screen

A "Continue Watching" list (built from the per-file resume positions above)
and a "Saved Playlists" list, reachable two ways: automatically whenever
nothing's queued (first launch, or after Clear Playlist), and at any time
from the house button in the toolbar, which opens it over whatever's playing
without stopping it. See `HomeScreenView` in
[PlayerContainerView.swift](Sources/MediaPlayer/Views/Player/PlayerContainerView.swift).

- Each Continue Watching row shows a thumbnail of the exact frame you left
  off at. This is generated independently of what's loaded (the row's file
  usually isn't the current item), so it has the same AVFoundation-only
  limitation as scrubber previews; MKV/AVI/etc. rows show a placeholder icon.
- The row for whatever's currently playing shows its live position, updating
  as it plays, rather than the last periodically saved one.
- Clicking a row for a file that's already in the queue plays that existing
  entry instead of adding a duplicate. For the file that's already playing,
  it just takes you back to it. `openRecentFile(_:)` handles this, so File ▸
  Open Recent and the menu-bar item behave the same way.
- ✕ on a Continue Watching row forgets that file's resume position (the file
  and its Open Recent entry are untouched). The trash button on a saved
  playlist deletes it.
- Clicking anything in the playlist sidebar, or anything else that changes
  what's playing, closes the overlay.

These are vertical lists rather than horizontal rows of cards on purpose: a
horizontal scroller with hidden indicators gives no hint that a second item
exists just off-screen, which looks identical to "there's only one."

### Trackpad gestures

These work over the video itself: two-finger vertical swipe for
volume, pinch to smoothly adjust playback speed (not snapped to the speed
menu's presets — an arbitrary rate, same as either engine already accepts).
These are bridged in from AppKit specifically because SwiftUI has no
gesture API for either one — see
[TrackpadGestureCatcher.swift](Sources/MediaPlayer/Views/Player/TrackpadGestureCatcher.swift).

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
| `K`\* | Play/pause |
| `J`\* / `L`\* | Skip back/forward (configurable interval, same as ⌘←/→) |
| `←` / `→` | Nudge back/forward 5s |
| `↑` / `↓` | Volume up/down 5% |
| `M`\* | Toggle mute |
| `F`\* | Toggle fullscreen |
| `C`\* | Toggle subtitles on/off |
| `,`\* / `.`\* | Step one frame back/forward |
| `⇧,` / `⇧.` (`<` `>`) | Decrease/increase playback speed |
| `0`–`9` | Seek to 0%–90% of the video |
| `Home` / `End` | Seek to start/end |

\* Remappable from Settings ▸ Shortcuts — click a key, then press its
replacement. The rest (arrows, digits, Home/End, speed) stay fixed; see
[RemappableAction.swift](Sources/MediaPlayer/Models/RemappableAction.swift)
for the full rationale and `KeyBindingStore` for how overrides are stored.

### Focus / Do Not Disturb while fullscreen

An opt-in Settings ▸ General toggle. macOS gives apps no public API to flip
system Focus modes directly, so this works around that the same way
automation tools like Keyboard Maestro do: it runs a Shortcuts.app shortcut
by name via `shortcuts://run-shortcut?name=…`, opened through
`NSWorkspace` — see `runFocusShortcut(named:)` in
[ContentView.swift](Sources/MediaPlayer/Views/ContentView.swift). That means
it needs one-time setup outside the app: create two shortcuts in
Shortcuts.app (default names "Focus On" / "Focus Off", configurable in
Settings), each with a single "Set Focus" action turning a Focus mode on or
off. Without those shortcuts existing, the toggle just quietly does nothing.

### Download from URL (yt-dlp)

File ▸ Download from URL (Shift-Command-D) saves a video or its audio from
any site [yt-dlp](https://github.com/yt-dlp/yt-dlp) supports. Paste a link,
and the next step shows the video's details and asks:

- **Video or audio only.** Video comes as MP4 (H.264, which plays in any
  app and gets thumbnails and AirPlay here) or MKV (the highest quality the
  site has, including 4K and HDR), at a chosen maximum resolution. MP4
  resolutions are limited to what the site offers in H.264 (1080p on
  YouTube); a site with no H.264 at all falls back to MKV. Audio comes as
  M4A, MP3, Opus, FLAC, or WAV, with cover art where the format holds it.
- **Subtitles.** Uploaded tracks, the automatic captions in the spoken
  language, and (collapsed, with a filter) YouTube's machine translations.
  They're saved as `.srt` files, embedded in the video, or both.
- **Where to save.** Chosen once and remembered (security-scoped bookmark),
  optionally adding each finished file to the playlist without interrupting
  what's playing.

Downloads run in the background. A toolbar button with a progress ring
opens the list, with cancel, play, and Show in Finder.

How it's put together
([Downloads/](Sources/MediaPlayer/Downloads)):

- yt-dlp isn't bundled. The app runs Homebrew's copy
  (`brew install yt-dlp`), which stays current with `brew upgrade`. That
  matters because sites change often enough that an old yt-dlp stops working.
  It needs ffmpeg for merging and conversion, which Homebrew's mpv already
  installs.
- The app checks whether a newer yt-dlp is out: at launch, every few hours
  while it's open, and when the Download from URL sheet opens. It compares
  the installed version (`yt-dlp --version`) with the one Homebrew offers
  ([formulae.brew.sh](https://formulae.brew.sh/api/formula/yt-dlp.json),
  fetched at most daily), not yt-dlp's GitHub releases, since
  `brew upgrade` can only install what Homebrew has. When it's behind, the
  download sheet and the downloads list show the update command. The app
  can't run the update itself: the sandbox lets it read `/opt/homebrew` but
  not write there. See
  [YTDLPUpdateChecker.swift](Sources/MediaPlayer/Downloads/YTDLPUpdateChecker.swift).
- A child process inherits the app's sandbox, and `/opt/homebrew` doesn't
  exist inside it. The
  `com.apple.security.temporary-exception.files.absolute-path.read-only`
  entitlement for `/opt/homebrew/` (in `project.yml`) makes it readable
  and executable. PATH is set explicitly, because an app launched from Finder
  doesn't have Homebrew on it, and yt-dlp finds ffmpeg and deno (for
  YouTube's player challenges) through it.
- yt-dlp writes into a scratch folder in the app's container, and the app
  moves the finished files into the chosen folder itself. The grant for
  that folder belongs to the app's process, and cancelled or failed
  downloads never leave partial files behind. On a name clash, the video and
  its subtitles are renamed together so they still pair up.
- Progress comes from `--progress-template`, parsed line by line
  (`DownloadProgressLine`). The user's own yt-dlp config is ignored
  (`--ignore-config`) so the sheet's choices are what actually happens.
- Licensing: yt-dlp is released under the Unlicense (public domain), and
  it runs as a separate program rather than being linked in, so it places no
  conditions on this app. The usual caveat applies to what's downloaded:
  respect the site's terms and the content's copyright.

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

Requires Xcode 26+ and macOS 26 or later (Homebrew's libmpv bottle is built
requiring it), plus [Homebrew](https://brew.sh).

```bash
brew install mpv   # provides libmpv — see "MKV/AVI/etc. playback" below
brew install yt-dlp   # optional, for Download from URL
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

### Updating the installed copy

Xcode's Run builds into DerivedData and launches from there; it never
touches `~/Applications/Media Player.app`. So anything that launches the
installed copy (a Desktop alias, the Dock, Finder "Open With") keeps running
whatever build was last copied in, however many times you've built since.
After building, replace it:

```bash
ditto ~/Library/Developer/Xcode/DerivedData/MediaPlayer-*/Build/Products/Debug/"Media Player.app" ~/Applications/"Media Player.app"
```

Quit the installed copy first, or the new one won't be picked up until it's
relaunched. Your playlists and settings aren't affected by this, since they're
tied to the bundle identifier and not the copy on disk (see above).

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

Loading Homebrew's `libmpv.2.dylib` also needs the
`com.apple.security.cs.disable-library-validation` entitlement (set in
`project.yml`). Hardened Runtime's Library Validation, on by default, only
allows loading libraries signed with the app's own Team ID, and Homebrew's
build is signed under a different one. Without that entitlement the app fails
at launch with a dyld "different Team IDs" error for that library.

mpv's built-in Lua scripts (stats overlay, console, and so on) run on LuaJIT,
which needs `com.apple.security.cs.allow-jit` under Hardened Runtime.
Without it, the first time a script's JIT compiles code (loading a
subtitle file was enough to trigger it), the kernel kills the app with
"Code Signature Invalid". The entitlement is set in `project.yml`, and the
scripts the app doesn't use are also switched off in `MPVEngine`'s setup
(the `load-*` options and `ytdl`).

`loadfile` in mpv is asynchronous, which matters for anything done right
after opening a file. `sub-add` and `seek` both fail until mpv reports
`FILE_LOADED`, and if the file is loaded before the video view's render
context exists, mpv decides there's no video output and plays the file as
audio-only for good. `MPVEngine.load(url:)` therefore waits for the render
context, and queues seeks (resume positions) and external subtitle files
until the file has loaded (`handleFileLoaded()`).

mpv's automatic search for subtitle, audio, and cover-art files next to the
video (`sub-auto`, `audio-file-auto`, `cover-art-auto`) is turned off. In the
sandbox the app can read only the files it was given, not their neighbors, and
listing a folder in `~/Documents` made macOS ask for access to Documents while
mpv's core thread waited on the answer. The app's calls into mpv from the UI
also use mpv's asynchronous API (`mpv_set_property_async`), so a busy core
thread can't freeze the app. Moving the subtitles whenever the controls bar
showed or hid was what turned that wait into a hang.

### Subtitles stay above the controls

While the controls bar is showing, subtitles move up so the bar doesn't cover
them. `PlayerContainerView` measures the bar and the video area and passes
the covered fraction to the engine. mpv moves its own subtitles with
`sub-pos`. AVFoundation has no equivalent, so for those files the app draws
the subtitle itself: the player's rendering is suppressed and `SubtitleOverlay`
draws the line reported by the legible output, the same path translation
uses (see `PlayerViewModel.drawsSubtitlesInApp`).

These formats are also registered as custom Uniform Type Identifiers in
`project.yml`'s `CFBundleDocumentTypes`/`UTExportedTypeDeclarations` (macOS
doesn't ship system UTIs for most of them), so double-clicking or right-click
▸ Open With ▸ Media Player works from Finder the same as it does for
mp4/mov — not just opening them from inside the app.

### One window

The main scene is a single `Window`, not a `WindowGroup`. A `WindowGroup`
opens a new window whenever a file launches the app from Finder (Open With,
double-click), and macOS restores every one of them on later launches. They
all shared the one `PlayerViewModel`, stacked exactly on top of each other,
so it looked like a single window. But each one reacted to the "open this
file" notification, so one open added the file once per window, and mpv drew
into whichever window's view it happened to pick (a black video).

### YouTube's automatic captions

YouTube's automatic captions scroll: each line stays up until the line after
next begins, so as SRT files (which is how yt-dlp saves them) every cue
overlaps the next, and players show two stacked lines, the current one and
the one before it. [RollUpCaptions.swift](Sources/MediaPlayer/Models/RollUpCaptions.swift)
ends each cue where the next one starts. It only does this when most cues
overlap, so ordinary subtitles that briefly overlap on purpose (two people
talking at once) are untouched. Loading a subtitle file plays a fixed copy
from the app's temporary folder, leaving your file as it is. The downloader
fixes the files it saves, so they also play properly in other players.

### Forced subtitles and the legible output

Two AVFoundation behaviors matter for the CC button and the subtitle overlay:

- Each subtitle track comes with a "Forced" variant that only shows lines
  marked forced (usually none), and AVFoundation selects it by default when
  the system caption preference is off. `AVFoundationEngine` hides those
  variants, so subtitles read as off, not as a selected track that shows
  nothing.
- `AVPlayerItemLegibleOutput` reports a line only when it starts, so a track
  turned on partway through a line stayed blank until the next one.
  Selecting a subtitle track now seeks in place, which makes AVFoundation
  send the current line right away.

### Playback time is published separately

`currentTime` and `bufferedFraction` change about 10 times a second during
playback, so they live on a small `PlaybackClock` object rather than being
`@Published` on `PlayerViewModel` itself; the view model's properties just
forward to it. Only views that actually display time observe the clock: the
transport bar's time readout and scrubber, and the home screen's live
Continue Watching row. When those ticks were published on the view model,
every observer redrew at that rate, including the app's menu-bar commands and
every ancestor of the settings menu. The result was that any open
menu flickered and dropped hovers and clicks for as long as something was
playing. If a new view needs live time, observe `viewModel.clock` in that
view (or a small subview), not the view model.

## Project layout

```
Sources/MediaPlayer/
├── App/            App entry point, menu commands, menu-bar item, Finder "Open With" handling
├── Downloads/      yt-dlp runner, download options, and the download manager
├── Models/         MediaItem, tracks/chapters, saved playlists, settings keys, remappable shortcuts
├── Playback/       PlaybackEngine protocol + the AVFoundation and mpv implementations
├── ViewModels/     PlayerViewModel (facade over the active engine) and PlaybackClock
├── Views/
│   ├── Player/     Video surfaces, home screen, trackpad gestures, auto-hiding overlay chrome
│   ├── Controls/   Scrubber, volume, settings gear menu, adjustments panel, A–B loop, transport bar
│   ├── Sidebar/    Playlist
│   ├── Downloads/  Download from URL sheet and the toolbar's downloads list
│   ├── Settings/   Settings window, including the Shortcuts pane
│   └── Shared/     Small reusable pieces (buttons, blur material, window bridge)
└── Resources/      Info.plist, entitlements, asset catalog (app icon, accent color), mpv bridging header
```
