# Custom-Mac-Media-Player

I don't like QuickTime so I'm making my own.

A native macOS media player (SwiftUI + AVFoundation, with libmpv for anything
AVFoundation can't open) with fully custom playback chrome instead of the
stock QuickTime/AVPlayerView controls: a scrubber with buffered-range and
hover time preview, a slide-out volume control, playback speed menu,
configurable skip interval, shuffle + repeat-all/one, a reorderable playlist
sidebar with a live "now playing" indicator, drag & drop, native fullscreen,
a Settings window (⌘,), and menu/keyboard shortcuts (Space, ⌘O, ⌘←/→, ⌘[/⌘]).

A few VLC-style extras on top: audio/subtitle track selection, loading
external subtitle files, subtitle delay/size adjustment (mpv-backed files),
frame-by-frame stepping (⌥⌘←/→), snapshot-to-PNG (⇧⌘S), a codec/bitrate
Media Info panel (⌘I), and Open Network Stream (⇧⌘O) for direct URLs.

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
