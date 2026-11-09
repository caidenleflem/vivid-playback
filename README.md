# Vivid Playback

A Mac app for show playback: import a timecode offset sheet with its master references and
timecode references, check that they all agree, and play songs or a whole setlist with a big
timecode clock. It's built to replace a Reaper session for this one job.

It looks like Apple Music in the Vivid glass material: simple playback first, and a song's
timeline only when you ask for it.

## Get the app

Every push to `main` is built on a GitHub Mac. Download the newest installer from this repo's
**Releases** page ("Latest build" → `Vivid Playback x.y.z.dmg`), open it and drag Vivid Playback
to Applications. It runs on macOS 13 (Ventura) or later, on Apple silicon and Intel.

The first time you open it, macOS may block it because it isn't signed with an Apple Developer
ID. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** (on older
macOS, right-click the app and choose **Open**). After that it opens normally. A Developer ID
signature removes that step; it's optional.

## Build it yourself

Needs Apple's Command Line Tools (`xcode-select --install`) or Xcode. In Terminal, in this
folder: `./scripts/make-dmg.sh`. The installer lands in `build/`.

## Use it

- **Drop your show folder** on the window: the offset sheet (CSV, or a CSV export from Numbers
  or Excel), the masters and the timecode files. Sub-folders are fine.
- The app reads the sheet, matches every file to its song, decodes the LTC in every timecode
  file, and tells you about anything that doesn't line up. It never fixes anything silently.
- **Try the example show** to see it work before you have files to hand.

Keys: **Space** play or pause · **← →** previous and next song · **Return** or **⌘T** opens the
song timeline · **M** adds a marker · **⇧⌘F** full-screen clock · **Esc** back to the library ·
**⇧⌘I** things to check.

Shows are saved in `~/Documents/Vivid Playback` as `.vividshow` packages and reopen on launch.

## What's in this build

| | |
|---|---|
| Timecode math, every rate (23.976, 24, 25, 29.97, 29.97 DF, 30) | Done, tested |
| Offset sheet import with column auto-detection | Done, tested (CSV and tab-separated) |
| Matching masters and timecode files to songs | Done, tested |
| LTC decoding and checking (start, rate, jumps, dropouts, lengths, sample rates) | Done, tested |
| Library, big clock, glass player bar, song timeline with the morph, markers, full-screen clock, first run | Built, first run on the Mac pending |
| **Audio:** master and LTC out, sample-locked, with channel routing | **Next.** This build runs the clock and the setlist without sound. |
| Excel (.xlsx) import | Later. Export the sheet as CSV for now. |

## Layout

```
Sources/PlaybackCore     Pure Swift: timecode, sheet import, file matching, LTC, checks. Tested.
Sources/VividPlayback    The SwiftUI app (macOS 13 or later).
Tests/PlaybackCoreTests  `swift test`
scripts/                 make-app.sh, make-dmg.sh
.github/workflows        build.yml: test, build, publish the .dmg
docs/                    PLAN.md, PROGRESS.md, IDEAS-CUEPOINTS.md
```

Manrope is used under the SIL Open Font License (Sources/VividPlayback/Resources/Fonts/OFL.txt).
