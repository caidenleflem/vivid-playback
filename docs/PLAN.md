# Plan: a Mac timecode playback app to replace Reaper

Working name: **Vivid Playback** (rename any time).

## Context

Today Caiden runs show playback in Reaper. Each song has a **master reference** (the stereo mix) and a **timecode reference** (an LTC audio track). An **offset sheet** says where each song sits in timecode. Reaper works, but it's a full DAW: too many ways to break a session, it's slow to rebuild for each tour, and it's not built for "pick a song, hit play, timecode goes out".

The goal is a focused Mac app that:
- imports the offset sheet, the master references and the timecode references,
- checks that they all agree,
- plays a song or a whole setlist, with the master on one output and timecode on another, sample-locked,
- puts a **big timecode clock** front and center,
- looks and feels like Apple Music, finished in the Vivid glass material,
- ships as **one installer you can put on any Mac**, with no accounts, cloud or servers.

## How it's built and shipped (Caiden's direction)

- **Built on the Mac, runs on the Mac.** No Supabase, no web backend, no GitHub required. Everything lives in local files: the app, plus a show package you can carry on a USB stick.
- **Native Swift and SwiftUI app,** audio on AVAudioEngine and Core Audio. Native because timecode must be sample-accurate and never drift from the music, and because macOS 26 has Liquid Glass built in.
- **The installer:** a `.dmg` you open and drag "Vivid Playback" to Applications. That's the normal Mac way, and the app also runs from any folder or a USB stick. A script (`scripts/make-dmg.sh`, using only Apple's own `xcodebuild` and `hdiutil`) builds it with one command. If you'd rather have a classic step-by-step installer, the same script can also produce a `.pkg`.
- **Opening it on other Macs:**
  - **Without** an Apple Developer account, the first launch on each Mac needs right-click, then Open (or Privacy & Security, then "Open Anyway"). After that it opens normally.
  - **With** one ($99 a year), we sign and notarize the app so it opens cleanly anywhere. That's optional, and can come later.
- **Version history** stays in a local git folder on the Mac. Pushing to GitHub is an optional backup only, not part of the workflow.

### Getting me onto your Mac

This cloud session runs on Linux and can't build or run a Mac app, and no folder from your Mac is shared with it yet. Either option works:
1. **Recommended:** open the Claude desktop app on your Mac and start a **local Claude Code session** in a new folder, for example `~/Developer/VividPlayback`. Point it at this plan and it builds, runs and packages right there.
2. Or share that folder with this session from the Claude desktop app (Settings, Claude Code, Remote Control). I'd then build on your Mac from here. This isn't available on every account yet.

**Your Mac needs Xcode** (free from the App Store, about 15 GB). That's the only install.

**Targets:** macOS 26 (Tahoe) or later, Apple silicon and Intel. If the show Mac is on macOS 15, the glass falls back to the older blur material and the minimum drops to 15.

## The feel: simple playback first, timeline only when you ask

Caiden's direction: it should feel turnkey and very Apple. It's **just playback** until you want to add timed things.

- **Default view is Apple Music:** the library, the song list, the big clock and the glass player bar. No timeline, no cue lanes, no tracks, no DAW vocabulary anywhere.
- **The timeline opens on demand.** Click the now-playing song in the player bar, double-click a song, press Cmd+T, or pinch out on the trackpad. A **fluid, continuous morph** carries you there, like Apple Music's Now Playing expanding from the mini player:
  - The song's row or artwork **flies and grows** into the full-window song timeline (SwiftUI `matchedGeometryEffect` with a spring, about 0.5 s, critically damped, no bounce).
  - The big clock **glides up and shrinks** into the glass bar at the top, still counting.
  - The sidebar slides away and the waveform **draws in from the playhead outward**.
  - It's interruptible: reverse it mid-flight and it follows your hand. Esc, a swipe down or a pinch in brings you back along the same path.
  - **Reduce Motion:** a quick crossfade instead.
- **Timed things appear only once you use them.** In the timeline you get one quiet "Add marker" button (or press M). The first marker reveals the marker lane. Songs with no markers never show one. Nothing in the simple view changes until you've added something, and then a small gold tick on the song row is the only hint.
- **Turnkey first run:**
  - One screen: "Drop your show folder here."
  - The app finds the offset sheet, the master references and the timecode references, matches them, validates them and is ready to play.
  - It asks a question only when something doesn't line up, such as a sheet column it can't identify or a file with no match.
  - Audio output is set up the same way: it picks your interface and asks once which channel the timecode goes out on.

## What it does (v1)

### 1. The big timecode clock (main screen centerpiece)
- A **huge HH:MM:SS:FF readout** across the top of the main window, under the glass player bar. It uses fixed-width digits so nothing jiggles as it counts.
- **State shown with it:**
  - STOPPED, PRE-ROLL or ROLLING. Gold digits while rolling, off-white when stopped.
  - The frame rate badge (for example 29.97 DF).
  - The current song name and the countdown to the next song's start.
  - An LTC "signal out" indicator that pulses green when timecode is actually leaving the interface.
- A toggle between **show TC** (the absolute timecode the console sees) and **song time** (elapsed in the song).
- **Clock-only full-screen mode** (Cmd+Shift+F) for a second monitor at front of house, readable from across the room.

### 2. Import
- **Offset sheet:** CSV, Excel (.xlsx) or a Numbers export. A **column-mapping step** on first import (Song, Title, TC start, TC end or length, frame rate, offset, file names), remembered per show, so any sheet layout works.
- **Master and timecode references:** drag in a folder or files (WAV, AIFF, plus MP3 and M4A for masters). The app **auto-matches files to sheet rows** by song number or title and lists anything it can't match so you can pair it by hand.
- **Validation:** the app **decodes the LTC** in each timecode reference and checks:
  - the start TC matches the sheet,
  - the frame rate matches (23.976, 24, 25, 29.97 DF and NDF, 30),
  - there are no dropouts or jumps,
  - the master and TC files are the same length,
  - the sample rates match the output device.
  Each problem shows as a row-level warning, never a silent fix.

### 3. Library (the Apple Music part)
- **Glass sidebar:** Shows, Setlists, All Songs, and Issues with a count.
- **Songs list:** number, title, TC start, length, frame rate and a status dot. Searchable and sortable.
- **Setlists:** drag to reorder, duplicate per city, mark songs to skip tonight.
- **Song timeline** (the expanded view, see above): the master waveform with a thin LTC lane under it, TC start and end, offset and notes. Scroll to move, pinch to zoom, click to locate.

### 4. Playback
- **Glass player bar** (Apple Music on macOS 26 style): transport, song, elapsed and remaining, and what's next.
- **Up Next** glass panel showing the setlist queue.
- **Routing:**
  - Master goes to one output pair and LTC to a dedicated channel, on the same device and clock, so they can't drift.
  - Each output has its own level and mute.
  - The LTC level is fixed and isn't touched by the master volume.
- **Modes:**
  - Play a song.
  - Play a setlist with auto-advance or stop-after-each.
  - Locate to a TC or a song.
  - Loop a section for programming.
  - Pre-roll before the song's TC start.
- **Show-safe:**
  - A "Show mode" lock that turns off editing.
  - Keyboard control: Space to play or stop, arrows for previous and next, Return to go.
  - A loud alert if the audio device disappears.
  - No popups or auto-updates during playback.

### 5. Shows on disk
- A show is a **package** (`.vividshow`): the sheet, setlists and file references (relative paths, optionally copied in). It moves to another Mac on a USB stick.
- **Relink missing files** in one step when a drive or folder changes.

## Notes: what we could take from CuePoints V2

These will be kept in the project as `docs/IDEAS-CUEPOINTS.md`, a living list of ideas inspired by CuePoints, not a copy of it. Sources: [cuepoints.com](https://cuepoints.com/), [the CuePoints docs](https://cuepoints.com/docs/getting-started) and [TPi's launch piece](https://www.tpimagazine.com/introducing-cuepoints-a-smart-way-to-share-timings-and-ideas-with-others/).

**What CuePoints V2 does (from its site and docs):**
- **Timecode in and out:** LTC, MIDI timecode and Art-Net timecode. It reads timecode striped on the media, or **generates LTC from the track's offset** when there's none.
- **Follows show timecode:** it listens to incoming TC, and the timeline follows and changes tracks automatically.
- **Per-track offset and frame rate** (Cmd+E), with a manual plus or minus nudge.
- **Typed cues on the timeline** (Lighting, Sound, Video, Standby). Each type can be shown, hidden, synced or exported on its own.
- **Cue import** from CSV or TAB spreadsheets and grandMA2/grandMA3 XML. Only cues inside the track's TC range land.
- **Console export:**
  - grandMA2 and grandMA3 (one macro file carrying sequences, timecode objects and pages). It also does ETC Eos, which is out of scope for us.
  - A choice of how the offset is applied.
  - A global latency adjustment for a desk that fires early or late.
- **Live from the desk:** the grandMA3 drives CuePoints over OSC, so pressing GO drops a cue on the timeline while you tech.
- **OSC both ways:** volume, timecode and playback status, with text placeholders like `{PositionHHMMSSFF}`.
- **Rehearsal video:**
  - Record onto the timeline from NDI, a capture card or an iPhone, auto-aligned.
  - Export with cue names and TC burned in.
- **Sharing timings** with the rest of the crew.

**My suggested picks for Vivid Playback, in order:**
1. **Generate LTC from the offset sheet** (TC files become optional, and the decoded files are kept as a cross-check). Then **MTC and Art-Net TC out.**
2. **Markers on the song timeline** (hidden until the first one is added), with optional types, plus **live OSC from the grandMA3** to drop a marker on GO.
3. **Export markers to grandMA3** as a timecode show, with a latency trim.
4. **Chase incoming timecode** (follow the band's playback rig).
5. **Rehearsal video recording with a TC and cue burn-in**, for programming in the hotel.
6. **An OSC remote** (Stream Deck, a footswitch or a console macro).
7. Later: grandMA2 export and sharing with the crew. **No ETC Eos** (Caiden's call).

## Design: Apple Music layout, Vivid glass

Port the Vivid material (`.glass` in `vivid-lifestyle/src/app/globals.css`, rules in `docs/design/glass/README.md`) to one SwiftUI `GlassSurface` modifier:
- **Colors:** a surface of `rgb(16 16 20)` at 0.64 opacity or more (0.76 for bars that content scrolls under), a 6% top sheen, and a 1 px edge that's brightest top-left, fading to champagne `#DBD1C5`.
- **Brand:** black and Phantom `#1E1E24` backgrounds, off-white `#F7F7F7` text, and gold `#C39C67` for the rolling clock, the playing song and the active item.
- **Rules kept from Vivid:**
  - Text on glass is off-white only.
  - At most two glass layers on screen.
  - **Lists and editors stay solid.**
- **Accessibility:** Increase Contrast and Reduce Transparency switch to solid `#0C0C0E` with a `#6E7180` border. Reduce Motion is respected.
- **Font:** Manrope, bundled. The clock uses monospaced digits.

## Architecture

```
VividPlayback/                       (local folder on the Mac, git for history)
  Package.swift                      PlaybackCore: pure Swift, no UI, unit-tested
  Sources/PlaybackCore/
    Timecode/      Timecode.swift (frames ↔ HH:MM:SS:FF, DF/NDF, all rates), FrameRate.swift
    LTC/           LTCDecoder.swift, LTCEncoder.swift (phase 2)
    Import/        OffsetSheetParser.swift (CSV, XLSX), ColumnMapping.swift, FileMatcher.swift
    Validation/    ShowValidator.swift → [Issue]
    Model/         Show, Song, Setlist, OutputRouting (Codable, stored in the .vividshow package)
    Scheduling/    PlaybackPlan.swift (song → sample positions, pre-roll, offsets)
  App/  (Xcode project, SwiftUI)
    Audio/         AudioEngine.swift (master and LTC players on one clock, channel map), DeviceMonitor.swift
    Design/        Tokens.swift, GlassSurface.swift, Manrope fonts
    Views/         TimecodeClock, ClockFullScreen, Sidebar, SongList, SetlistView, SongDetail,
                   PlayerBar, UpNext, ImportWizard, IssuesView
  Tests/PlaybackCoreTests/
  scripts/make-dmg.sh               xcodebuild archive → .app → .dmg (optional .pkg)
  docs/IDEAS-CUEPOINTS.md           the notes above, kept up to date
  docs/PROGRESS.md                  dated log, the same habit as Vivid
```

As in Vivid, **all timecode math, parsing, matching and validation live in `PlaybackCore`** with unit tests, and the UI only calls it. Dependencies stay lean: CoreXLSX for Excel is the only planned third-party package.

## Build order (each step a commit)

0. **Renders first, before any app code.** Caiden reviews the look and the motion before anything is built. **Approving this plan only starts step 0.** I make the renders, send them, and stop. Nothing else is built until Caiden has seen them and his laptop is set up.
   - **Still renders:**
     - the simple library with the big clock,
     - the clock-only full screen,
     - the drop-your-show first run,
     - the expanded song timeline, with and without markers.
   - **An animated prototype of the expand morph,** library to timeline and back: a private web page you can click through on your phone or Mac, plus a short screen recording.
   - These are built in HTML with the Vivid glass recipe and Playwright screenshots, so I can make them right here without the Mac. Once you approve them, they become the reference for the SwiftUI build.
1. **Skeleton:**
   - the Xcode project and package, brand tokens, Manrope,
   - the Apple Music three-pane glass window,
   - the **big clock view**, driven by a test ticker,
   - `make-dmg.sh` producing an installable `.dmg` from day one.
2. **Timecode core:** `Timecode` and `FrameRate` with full drop-frame handling, plus exhaustive tests.
3. **Offset sheet import:** CSV and XLSX, the column-mapping UI, the songs list.
4. **File import and matching:** drag-in, auto-match, manual pairing, the show package and relinking.
5. **LTC decoder and validator:** the Issues view and status dots.
6. **Audio engine:** routing, sample-locked master and LTC playback, the transport, the player bar, and the clock driven by real playback.
7. **Setlists and show mode:** Up Next, auto-advance, locate, loop, pre-roll, shortcuts, show lock, device-lost alert, full-screen clock.
8. **Polish:** waveforms, accessibility fallbacks, and an app icon from the Vivid emblem.
9. **Release:** a versioned `.dmg`, plus signing and notarization if you get a Developer account.
10. **Then the CuePoints-inspired picks,** in the order above, starting with built-in LTC generation.

## Questions for Caiden (defaults if unanswered)

1. **Offset sheet:** share a real one? Default: column mapping handles any layout, and "offset" means where in the audio file the song's TC start falls.
2. **Frame rate:** per tour or per song? Default: per song, with a show default.
3. **Interface and channels** for master and LTC? Default: master on 1–2, LTC on a channel you pick.
4. **Console:** grandMA3? This decides the first export and OSC target. Default: grandMA3.
5. **Show Mac macOS version.** Default: macOS 26.
6. **Name.** Default: "Vivid Playback".

## Verification

- **`swift test` on PlaybackCore:**
  - timecode round-trips at every rate and drop-frame boundaries (00:00:59;29 → 00:01:00;02),
  - CSV and XLSX fixtures,
  - file matching,
  - every validator issue,
  - LTC decoding of generated fixtures.
- **Sync test:**
  - Route LTC out and loop it back into an input (or into the console or a TC reader).
  - Confirm it matches the big clock frame-for-frame across a full song, with no drift.
- **Installer test:**
  - Run `make-dmg.sh`, copy the `.dmg` to a second Mac (or a fresh user account) and install by dragging to Applications.
  - Open a show package from a USB stick and play.
- **Rehearsal:** import a past tour's sheet and files, then run the setlist next to the Reaper session and compare TC at each song start.
- **UI check:**
  - the clock is readable from across a room in full-screen mode,
  - the expand morph runs at 120 fps on a ProMotion Mac, can be reversed mid-flight, and falls back to a crossfade with Reduce Motion on,
  - a show with no markers never shows a timeline lane or cue vocabulary in the simple view,
  - Increase Contrast and Reduce Transparency on,
  - keyboard-only show mode.
