# Progress

## 2026-11-09: core and first app build

**Done**
- Step 0: renders and the morph prototype (approved).
- Step 2: `Timecode` and `FrameRate`: every rate, drop-frame labels both ways, real-time seconds,
  wrap at midnight, JSON as readable strings.
- Step 3: offset sheet import (CSV and tab-separated, quoted fields, BOM). The header row can sit
  under a title row. Columns are guessed from header names and checked against what the values
  look like. An "Offset" column of timecodes is read as the start; one of seconds is read as a
  file offset. Unreadable rows are reported, never guessed.
- Step 4: file matching, by name in the sheet, then song number (only when the file's own title
  agrees), then title. Ambiguous files are reported, not picked. Click, guide and stem files are
  left alone.
- Step 5: an LTC encoder and decoder (biphase mark, sync word, polarity correction, either
  polarity, any level, DC offset), and an analyzer for rate, start, jumps and dropouts. Also a
  validator for start mismatch, rate, length, sample rate, overlaps and missing files, and an
  importer that ties it all together. An example show generator.
- 36 unit tests pass (`swift test`, Swift 6.1).
- The app (step 1 plus the UI for steps 3–5 and 7): library with the glass sidebar and player
  bar, the big clock (Show TC or song time), song list with status, song timeline with
  waveform, timecode lane and markers, the morph between them (matchedGeometryEffect, smooth
  spring; crossfade under Reduce Motion), full-screen clock, first run with drop target and
  checklist, issues sheet, menus and keys. Shows save to ~/Documents/Vivid Playback.
- `scripts/make-dmg.sh` builds a drag-to-Applications disk image.

**Decisions**
- No Xcode project file: the app is a SwiftPM executable wrapped into a .app by
  `make-app.sh`. Fewer moving parts; Xcode still opens `Package.swift`.
- Minimum macOS 14. The glass is the Vivid recipe on `.ultraThinMaterial`, so it looks the same
  on 14, 15 and 26. Native Liquid Glass can be adopted later behind `#available(macOS 26, *)`.
- Fonts load through `ATSApplicationFontsPath` in the app, and from the source tree when run
  from Xcode, which avoids SwiftPM resource bundles breaking the code signature.
- Rate is detected from the LTC itself (speed, highest frame, drop flag) and compared with the
  sheet. A mismatch is an error, because the console would drift.

**Assumptions** (conservative readings; change any of them)
- "Offset" on the sheet means the song's start timecode when it holds timecodes, and pre-roll
  in the audio file when it holds seconds.
- "30 DF" on a sheet means 29.97 drop-frame.
- Song length is the master's length minus the file offset unless the sheet gives one.
- Files with click, guide, cue, stem or vox in the name aren't masters.

**Built and checked on GitHub** (later the same day)
- `.github/workflows/build.yml` builds on a GitHub Mac (macOS 15, Xcode 16.4) on every push to
  main: runs the 36 tests, builds a universal (Apple silicon and Intel) app for macOS 13+, checks
  the signature and resources, launches it on every screen, and publishes the .dmg as the
  "Latest build" release. Screenshots of each screen go to the `ci-screens` branch.
- Minimum macOS lowered to 13 (Caiden's Mac isn't on the newest macOS).
- First screenshots match the renders. Fixed from them: the full-screen clock overflowing, the
  first-run text truncating, and the minimum window size on small screens.

**Next**
1. First build and run on Caiden's Mac; fix anything the compiler finds; screenshots against
   the renders.
2. Step 6: the audio engine. Master and LTC players on one AVAudioEngine clock, channel map to
   the interface, fixed LTC level, device-lost alert. The transport's clock becomes the
   engine's sample time.
3. Output setup: pick the interface and the timecode channel (asked once).

**Needs Caiden**
- A real offset sheet and one song's files, to test against.
- The interface and the channel the timecode goes out on.
- Console (grandMA3?) for later export and OSC work.
