# CLAUDE.md: Vivid Playback

A native Mac app (Swift, SwiftUI, AVFoundation) that replaces Reaper for show playback:
offset sheet + master references + timecode references in, songs and setlists out, with a
big timecode clock. Owner: Caiden Leflem, touring lighting director.

Read `docs/PLAN.md` (the approved plan), then `docs/PROGRESS.md` (what's done and next).

## Rules
- Timecode math, parsing, matching, LTC and checks live in `Sources/PlaybackCore`, pure Swift,
  with tests. The app only calls it. Run `swift test` before every commit.
- Never fix a show silently. Report what doesn't line up and let Caiden decide.
- The audio engine must keep master and LTC on one clock, sample-locked. The LTC level is
  fixed and the master volume never touches it.
- Show-safe: no popups, updates or surprises during playback.
- Look: Apple Music layout in the Vivid glass material (`Design/Glass.swift`). Dark only.
  Off-white text on glass; gold for rolling, the playing song and markers. Lists and editors
  stay solid. At most two glass layers on screen. Respect Reduce Motion, Reduce Transparency
  and Increase Contrast.
- Simple playback first. Timeline vocabulary (lanes, markers) appears only in the song
  timeline, and markers only once one exists.
- Voice: warm and short. Plain words a lighting tech would use.
- No ETC Eos work (Caiden's call).
- Build the installer with `./scripts/make-dmg.sh`. Log each session in `docs/PROGRESS.md`.
