## v1.3.0

This release adds a home screen, on-device subtitle translation, new audio, video, and subtitle controls, trackpad and menu bar integration, and a number of reliability fixes.

### Home Screen

- **Continue Watching** — files you're partway through, each with a thumbnail of the frame you stopped at (MP4, MOV, and other AVFoundation-backed formats)
- **Saved Playlists** — your saved playlists, one click to load
- Available at any time from the toolbar, over whatever is playing, without stopping playback
- The entry for the file that's currently playing shows its live position
- Remove entries from Continue Watching and delete saved playlists directly from the list
- Shown automatically when the playlist is empty

### Playback and Library

- Every file now remembers its own resume position, independent of the current playlist
- Open Folder (Option+Cmd+O) adds every playable file in a folder and its subfolders
- MKV, WebM, AVI, and the other mpv-backed formats can now be opened from Finder by double-clicking or with Open With
- A–B loop: mark a start and end point to repeat a section
- Reopening a file that's already in the playlist plays the existing entry instead of adding a duplicate

### Audio, Video, and Subtitles

- Optional volume boost up to 200% (Settings > General)
- Brightness, contrast, saturation, and gamma adjustment, for all supported formats
- Subtitle font, text color, and background color and opacity (MKV/AVI/etc.)
- Subtitle text encoding selection, for subtitles that display as garbled characters (MKV/AVI/etc.)
- Subtitle translation into your chosen language, performed on-device with Apple's Translation framework (text-based subtitle tracks)

### Interface and macOS Integration

- A Now Playing item in the menu bar, with play/pause and next/previous track controls
- A filter field for searching the playlist
- Remappable single-key shortcuts (Settings > Shortcuts)
- Float on Top, to keep the window above other windows
- Trackpad gestures over the video: two-finger vertical swipe for volume, pinch to adjust playback speed
- Optional automatic Focus (Do Not Disturb) while in fullscreen, using two Shortcuts you create once (see the README)

### Fixes and Refinements

- Playback speed no longer resets to 1x when resuming MP4, MOV, and other AVFoundation-backed files
- Open menus (captions, playback speed) no longer flicker or ignore clicks during playback, and the controls bar no longer hides while a menu is open
- Clicking a control no longer occasionally also toggles play/pause
- Selecting the item that's already playing no longer reloads it from an earlier position
- Switching saved playlists no longer disables shuffle or leaves outdated information in Control Center
- Network streams now continue playing correctly after an external subtitle file is loaded
- The scrubber's buffered range is now accurate for MKV/AVI/etc. files
- Improved reliability of file access in long sessions that repeatedly switch playlists or reopen recent files
- Fixed a launch failure ("different Team IDs") when loading the mpv library under Hardened Runtime
- Improved stability of the mpv engine's startup and end-of-file handling
- Fixed a possible hang when opening the captions menu for MP4, MOV, and other AVFoundation-backed files
- Playback time updates no longer redraw the entire interface

### Requirements

- macOS 26 or later, Apple Silicon
- Building from source requires [Homebrew](https://brew.sh) (`brew install mpv xcodegen`); see the README for details
