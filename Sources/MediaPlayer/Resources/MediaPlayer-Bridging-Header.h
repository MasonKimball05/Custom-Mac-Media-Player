// Exposes libmpv's C API to Swift. Header/library search paths for this (and the
// -lmpv link flag) are set in project.yml, pointing at Homebrew's `mpv` install —
// `brew install mpv` is a build prerequisite, see README.md.
#import <mpv/client.h>
#import <mpv/render_gl.h>
