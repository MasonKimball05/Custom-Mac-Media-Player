## v1.3.0

This release adds a home screen, downloading from a link, on-device subtitle translation, new audio, video, and subtitle controls, trackpad and menu bar integration, and a number of reliability fixes.

### Home Screen

- **Continue Watching** — files you're partway through, each with a thumbnail of the frame you stopped at (MP4, MOV, and other AVFoundation-backed formats)
- **Saved Playlists** — your saved playlists, one click to load
- Available at any time from the toolbar, over whatever is playing, without stopping playback
- The entry for the file that's currently playing shows its live position
- Remove entries from Continue Watching and delete saved playlists directly from the list
- Shown automatically when the playlist is empty

### Download from URL

- Download a video or its audio from YouTube or any other site yt-dlp supports (File > Download from URL, Shift+Cmd+D)
- Choose MP4 or MKV at a maximum resolution, or audio only as M4A, MP3, Opus, FLAC, or WAV
- Pick subtitles to download with it, including automatic captions and YouTube's translations, saved as separate files, embedded in the video, or both
- Downloads run in the background, with progress and controls in the toolbar, and can be added to the playlist automatically when finished
- Notifies you when a newer yt-dlp is available, with the command to update it, since older versions stop working as sites change

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
- Subtitles move up above the controls bar while it's showing, so they're never hidden behind it

### Interface and macOS Integration

- A redesigned controls bar, inspired by YouTube's player: a full-width scrubber over a gradient that fades up from the bottom, an elapsed / total time readout with the current chapter name (click it to show time remaining), a one-click CC button, and a settings gear that gathers subtitles, audio track, chapters, playback speed, and video adjustments
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
- Fixed a crash when loading an external subtitle file into an MKV/AVI/etc. file
- Loading a subtitle file into an MKV/AVI/etc. file no longer switches playback to audio only
- Fixed a freeze when loading a subtitle file for a video stored in Documents or another protected folder
- YouTube's automatic captions now show one line at a time, instead of the current and previous lines stacked together
- The home screen's list no longer draws over the window's top bar when scrolled
- MKV/AVI/etc. files now reliably resume from where you left off
- Fixed a possible hang when opening the subtitles menu for MP4, MOV, and other AVFoundation-backed files
- Opening a file from Finder no longer adds it to the playlist several times or opens hidden duplicate windows
- Keyboard shortcuts now work right after launch, instead of typing into the playlist filter until something else was clicked
- Subtitles in MP4, MOV, and other AVFoundation-backed files appear as soon as they're turned on, and hidden "forced only" tracks are no longer listed or shown as selected
- Playback time updates no longer redraw the entire interface

### Requirements

- macOS 26 or later, Apple Silicon
- Building from source requires [Homebrew](https://brew.sh) (`brew install mpv xcodegen`); see the README for details
- Download from URL requires yt-dlp (`brew install yt-dlp`)
