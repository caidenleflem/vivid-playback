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

## 2026-11-09: audio and the rest of v1

**Done**
- Audio: one AVAudioEngine source node renders every output channel through the core
  `Mixer` from a single frame counter, so master and LTC can't drift. Interface picked by
  Core Audio UID, any output channels, master as a stereo pair or one output (summed to mono),
  timecode level fixed and separate from the master level. Files are converted to the
  interface's sample rate on load; the next song is preloaded so auto-advance is instant.
- Timecode generated from the sheet when a song has no timecode file, aligned to the sample
  (tested), and shown as "Timecode out · generated". Missing timecode is now a warning.
- The playhead follows the audio clock, allowing for output latency; the plain clock is only
  used with no audio output.
- Interface unplugged: playback stops and a solid banner says so. If the show's interface is
  missing at open, it plays on the default output and says so.
- Setlists (reorder, skip tonight, duplicate, new, delete), stop after each song, show mode
  lock, loop between markers, go to timecode, marker rename/delete/click-to-locate, relink
  media folder, check files again.
- Excel (.xlsx) offset sheets, with a dependency-free zip/deflate reader (tested).
- App icon.
- 46 tests pass.

**Assumptions**
- Single-key shortcuts are off while a sheet is open, so typing never moves the playhead.
- In show mode, playback controls still work; editing, importing and opening are off.

**Needs Caiden**
- A run on the real interface: confirm the console reads timecode and that it lines up.
- A real offset sheet, to tune the column detection.

## 2026-11-09: the first real tour sheet

Caiden's Fall EU '26 sheet (a Google Sheets "Songs" tab as CSV) failed to import. The sheet
itself parsed (header on row 4, "LTC start" column, durations), but:
- The importer chose the sheet by file name keywords, so in a folder with other CSV exports
  (or a CSV dropped in Downloads) it read the wrong file and found no songs.
- Numbered songs with no LTC (looped beds, the pre-encore) were dropped.

**Fixed**
- A dropped or chosen sheet is always the sheet. Otherwise every sheet in the folder is read
  and the one with the most start timecodes wins.
- A sheet dropped from Downloads, Desktop, Documents or the home folder isn't used to search
  that folder for audio; the show runs on generated timecode until the show folder is dropped.
- Numbered rows with no start become songs that play without timecode (`timecodeOff`); the
  clock shows song time for them. A start that's there but unreadable is still reported and
  left out, never turned into a no-timecode song.
- Totals and note rows (no number, no start) are ignored.
- Repeated findings are grouped on the import screen ("39 songs use timecode generated from
  the sheet").
- Tests built on the real sheet's layout (made-up song names). 51 tests pass.

**Noticed on the sheet (reported by the app as warnings, not changed)**
- Intros share their song's address (00:20:00:00, 01:50:00:00).
- 04:30:00:00 is a cue row ("NOT A SONG").

## 2026-11-09: adding audio after import

Caiden asked whether masters and LTC files can be added once a sheet is imported. Now:
- Drop files or folders on the song list: matched like an import, filling only what's missing.
- Drop a file on a song row: LTC/TC/timecode in the name sets the timecode file, else the master.
- Right-click a song, or the file names in the song timeline: choose, replace, remove.
- File › Add Audio Files… (⇧⌘A).
- A timecode file on a no-timecode song reads the LTC and sets the song's start from it
  (and says so); a file with no LTC is refused and nothing changes.
- Files outside the show folder keep their full path. Nothing reloads mid-song.
- 54 tests pass.

## 2026-11-09: the clock and output follow the timecode file

Caiden suspected generated timecode was still showing and going out with an LTC file in place.
Found and fixed:
- **The clock never read the file.** It showed the sheet's start plus the playhead. It now shows
  the LTC decoded from the loaded timecode track at the playing sample (`LTCTrack`), so a file
  whose timecode differs from the sheet shows its own timecode, and silence shows dashes.
- **A timecode file that failed to load fell back to generated timecode** (`try?` in the
  loader). Now a song with a timecode file sends that file or nothing, with a red chip and the
  reason. Master read failures are shown too, instead of silence without a word.
- **Single-file drops chose the role by name.** Files are now told apart by listening for LTC
  (first 20 s); the name only decides when nothing is heard. Same for folder drops and imports.
- **A stale preload could re-cache old audio** after files changed. Loads now carry a
  generation number and are discarded if files changed meanwhile.
- Chips say where timecode comes from: "from file", "generated from the sheet", "no timecode
  found in <file>", "can't be read". The timeline header shows the file's first timecode.
- 58 tests pass, including a file whose LTC differs from the sheet and an unreadable file.

## 2026-11-09: findings per song, and hiding minor ones

- Click a song's status in the list (or the warning chip in its timeline) for a popover with
  everything wrong with that song, in full. The status shows "+N" when there's more than one.
- Warnings can be hidden (Hide); errors (missing master, unreadable file) can't. Hidden ones are
  saved with the show (`Show.dismissedIssues`, keyed by song, kind and exact wording), so a
  problem that changes comes back. The Issues list groups by song, has "Hide all warnings" per
  song and a Hidden section with "Show again". The sidebar badge counts only what's showing.
- Hiding is allowed in show mode (it doesn't touch playback).
- Builds are versioned (0.2.<build>) and each is its own release; File › Save, Save a Copy,
  Show in Finder.
- 62 tests pass.

## 2026-11-09: Hide crashed the app

Caiden hit a crash clicking Hide. Likely causes, all fixed (not reproducible here):
- The song popover resized itself while open (AppKit can crash on popover constraint loops).
  It's now a fixed 440×360 and scrolls.
- In the song timeline, hiding the last warning swapped the popover's anchor button for a
  different chip while the popover was open. The button now stays and only its label changes.
- Hide/Show again now apply on the next run-loop turn, without animation, so the clicked
  button finishes before its row disappears.
Builds: GitHub's macOS runners stopped picking up jobs (macos-14 is retired; macos-15 and
macos-latest jobs sit queued). Caiden builds locally with `./scripts/make-dmg.sh` meanwhile.

## 2026-11-09: one-click fixes on findings

Caiden asked for ways to fix a finding, e.g. updating a song's stored start when its timecode
file reads something else. Findings now carry `fixes` (core `IssueFix`), most likely first:
- Timecode starts elsewhere: **Use the file's timecode** (song start = what the file reads at the
  file offset; markers move with it) and, when the file contains the sheet's start, **Start where
  the file reads <sheet start>** (file offset = where it does; the audio doesn't move).
- Frame rate differs: **Use <rate>, like the file** (start and markers converted).
- Missing/unreadable files, no LTC found: **Choose master… / Choose timecode file…**
- Timecode jumps or drops out: **Go there** (cues the song at the problem).
- Converted for the interface: **Audio output…**
Show-changing fixes are off in show mode, apply only on click, reload the song (unless it's
playing), re-check, and can be undone (Playback › Undo Fix, ⌥⌘Z, or Undo in the notice).
`ShowFixer` (core) applies and undoes them; 67 tests pass, including each fix clearing its finding.

## 2026-11-09: setlist order and Albums

- Song list: **drag a song onto another to move it there** (setlist order), and Move Up / Down /
  to Top / to Bottom in the right-click menu. A **Sort** menu (setlist order, song number, title,
  timecode start, length) changes only the view; **Save This Order** makes it the setlist's
  order. Playback always follows the setlist order, and says so while sorted.
- The sheet's **Part** column (Act 1, Act 2, Encore…) comes in as `Song.part` and shows as
  section headers in setlist order. "Part/Act/Set/Section" match whole headers only ("Offset"
  contains "set").
- **Albums** (⌘1 or the sidebar): every saved show in Documents › Vivid Playback, grouped by
  artist, one album per setlist with its cover, show name, song count and running time. Click to
  open (loads that show unless something's playing). Drop an image on a cover, or Choose Cover…,
  to set artwork (copied into the show package).
- **Artist and show name** come from the sheet's title line ("ARTIST · SHOW · LEG · SETLIST");
  editable in Show Info… (⌘I, or double-click the show name in the sidebar).
- Shows imported before this keep working; re-import to pick up acts, or set the artist in Show Info.
- 70 tests pass.
- Hiding songs: Sort menu › **Hide Skipped Songs** leaves skipped songs out of the list (kept
  per Mac). Right-click › **Remove from Setlist** takes a song out of that setlist only (not while
  it's playing); Edit Setlist lists "Not in this setlist" songs with **Add**. 71 tests pass.

## 2026-11-09: Connections (MTC and Art-Net out, remote control, following), meters, test timecode

- **Connections** page (⌘3, sidebar): three timecode-out tiles (LTC, MIDI timecode, Art-Net),
  each live with the timecode it's sending; Follow timecode (Off / LTC in / MTC / Art-Net) with a
  big incoming readout and status; Remote control (OSC with this Mac's addresses and the command
  list; MIDI with MIDI Machine Control and MIDI Learn for Go, Stop, Go/Stop, Next, Previous, Top
  of song, Add marker). Settings are per Mac (UserDefaults), not per show.
- MTC and Art-Net follow `OutputClock`, the same timecode as the LTC (read from the song's file),
  on a high-priority queue: quarter frames while running, full frames on stop and jumps;
  Art-Net once per frame. MTC also goes out a virtual "Vivid Playback" MIDI port.
- Following: `ChaseEngine` (core, tested) cues the song whose range holds the incoming timecode,
  follows a parked/scrubbing source, plays once it counts up, relocates past 2 frames of drift,
  stops 0.4 s after timecode stops. LTC in uses a streaming decoder (core, tested) on an input
  channel of any interface.
- Meters with peak hold (audio thread peaks, 30 Hz) in Audio Output, the LTC tile and the
  sidebar. **Send test timecode**: timecode only, never the music, looping, while stopped; it
  goes out as MTC/Art-Net too.
- Info.plist: Local Network and Microphone usage text (Art-Net/OSC, LTC input).
- 84 tests pass. Not yet run on hardware: MIDI ports, Art-Net to a console, LTC input.

## 2026-11-09: Dante-ready

Native Dante needs Audinate's licensed SDK, so Dante goes through Dante Virtual Soundcard or a
Dante interface, which macOS sees as an ordinary audio device. To make that smooth:
- Dante devices are recognised (name or manufacturer Audinate): "Dante" in the interface list
  and a Dante card in Audio Output.
- Channel names from macOS are shown in the master and timecode pickers ("Output 3 · FOH LTC").
- **Set up for Dante**: master on transmit channels 1–2, timecode on 3, with Dante Controller
  routing guidance.
- Sample rate: the card says whether songs match the Dante rate or how many are converted; the
  checks re-run when the interface changes.
- Latency: output latency now includes the device latency, safety offset, stream latency and the
  IO buffer (for every interface), so the clock, MTC and Art-Net line up with the timecode as
  it's heard. The Dante card shows the figure.

## 2026-11-09: grandMA3 trigger lanes

- Core (`Triggers.swift`, tested): `ConsoleTarget` (name, IP, port, prefix, on/off),
  `TriggerLane` (page, executor, action: Go+, Go−, Top, On, Off, fader level or a custom command
  line with {page} {exec} {label} {value}; which consoles; colour; mute), and
  `TriggerScheduler`, which fires what the playhead crosses while playing forward and re-arms
  without firing after a locate, loop or song change.
- Triggers are markers with a `laneID` (and a `value` for fader levels), so they save with the
  song and survive everything markers already survive. Lanes are show-wide; plain markers are
  unchanged and loops still use plain markers only.
- `TriggerService`: a 2 ms high-priority timer reads the heard position from `OutputClock`
  (latency included), moved earlier by Fire early, and sends OSC over UDP. The UI only shows the
  gold flash afterwards, so a busy screen can't make a cue late.
- Timeline: a row per lane (title, executor, console, warnings when no console is reachable,
  mute), coloured trigger ticks with labels, **C** at the playhead on the chosen lane,
  double-click to place, drag to move, right-click for level, nudge a frame, move to playhead,
  fire now, delete. The chosen lane's triggers show faintly through the waveform.
- Lane editor with a live preview of the exact OSC going to each console, and Fire now.
- Connections › Consoles: console cards, the MA3 setup steps, Fire early (0–200 ms), and the
  last trigger sent (with a warning if it couldn't leave the Mac).
- Single-key shortcuts now stand aside while a text field on the Connections page has focus.
- grandMA3 OSC: `/gma3/cmd` with a command string needs Receive Command on; fader lanes use
  `/gma3/Page{p}/Fader{e}` with 0–100. **Needs a check on a real console** (or onPC).
- 88 tests pass.

## 2026-11-10: lane keys, zoom, selection

- Each lane can have a key (core: `TriggerLane.key`, `normalizedKey`, `freeKey`; Space, M, L and
  C are reserved). New lanes get the next free key from 1 2 3… Pressing it in the timeline drops
  a trigger at the position heard when the key went down (the event's timestamp, not when it was
  handled). Key repeat is ignored. "Keys fire the console" (per Mac, on by default) also fires
  the executor as you press it. Lane editor has a key recorder (Esc cancels, Delete clears); a
  key moves from another lane if reused.
- Zoom (core: `TimelineWindow`, tested): up to 200×, pinch or ⌘/⌥-scroll around the pointer,
  ⌘= ⌘− ⌘0, swipe or the overview bar to pan, paging with the playhead while playing. Ruler
  spacing adapts down to frames. Waveform peaks are now 100 per second, drawn for the visible
  stretch, and placed in song time (the file offset is taken into account; before, the whole
  file was stretched across the lane).
- Selection: click a marker or trigger to select it (gold outline); drag to move (snaps to a
  frame); ⌥← ⌥→ nudge 1 frame (⇧ 10); Delete removes it. New markers and triggers are selected,
  so Delete undoes the last one keyed in. Plain markers can now be dragged and nudged too.
- Settings saved by older versions now load (missing fields take defaults). The previous build
  could reset this Mac's Connections settings once on upgrade.
- 92 tests pass.

## 2026-11-10: box select, multi-delete, marker undo

- Selection is now a set. Drag from empty space on the marker/executor lanes draws a box and
  selects what's inside, live (⇧ adds to the selection). ⇧/⌘-click toggles one; ⌘A all; Esc clears.
  Starting a drag on a marker or its label moves it instead (hit test on the row and label width).
- A floating selection bar (solid, not glass) shows the count with nudge, Delete and clear.
  Right-click on a selected item offers Delete N Selected. Delete shows a notice with Undo.
- Dragging a selected item moves the whole selection by whole frames, spacing kept.
- ⌘Z / ⇧⌘Z: snapshot undo of a song's markers for every marker edit (add, key-in, rename,
  move, nudge, level, delete), up to 100 steps; handled in the timeline only, so text fields and
  other screens keep the system Undo.

## 2026-11-10: lanes per song

- Lanes moved from the show to each song (`Song.triggerLanes`). Shows saved with show-wide lanes
  are moved on load (`Show.moveLanesToSongs`, tested): each song gets the lanes it has triggers on,
  with the same ids, and songs with no triggers get none. Nothing is lost.
- Copy lanes from another song (Add lane menu, the empty-timeline hint, Playback menu): copies the
  lanes as new lanes, skipping any executor/action the song already has; keys already used on the
  song are left off the copy.
- Consoles page counts lanes across the whole show. 94 tests pass.

## 2026-11-10: add and delete albums, cleaner transitions

- Add album: a sheet with the new-show import (shared `ImportFlow` with the first-run screen):
  drop/choose a folder, open a show file (copied into the library), try the example. Results offer
  Add to Albums (saved, not opened, so playback carries on) and Add and open (disabled while
  playing). The import screen now has Cancel when a show is open, and takes drops anywhere.
- Imports never overwrite an existing show of the same name (`ShowLibrary.uniquePackageURL`,
  tested); before, re-importing a folder replaced the saved show and its markers.
- Delete album (confirmation dialog): removes the setlist when the show has others; a show's last
  album moves the show file to the Trash. Undo restores either (moves it back from the Trash).
  Deleting the open show opens the next saved show, or the import screen if there's none. Blocked
  while that album is playing.
- Transitions: one persistent sidebar for Albums / Now playing / Connections; only the page beside
  it changes (fade with a 10 pt rise, 0.32 s critically damped). Timeline and clock morphs keep
  0.55 s; first run 0.45 s with a slight scale; Reduce Motion is a 0.18 s crossfade with no
  movement. Moving to the screen you're on does nothing (no re-animation).
- 95 tests pass.

## 2026-11-10: artists, album search, screen transitions

- Import results (first run and Add album) have Artist (type or pick from the library's artists)
  and Show name fields, applied before the show is saved. Show Info… on any album edits artist and
  name for the open show or any saved one.
- Albums search (⌘F): every word must appear in the artist, show or setlist name, case and accent
  insensitive (`ShowLibrary.matches`, tested); empty result state with Clear.
- Transitions between Now playing, Timeline and Clock: no more matched-geometry flights (title,
  clock, artwork and bar flew across the other screen's contents). Screens now swap whole: the
  old one fades out in 0.16 s, the new one fades in with a 3% zoom (from larger going deeper, from
  smaller coming back), critically damped 0.42 s after a 0.05 s beat. The sidebar shell is one
  unit, so nothing reflows mid-transition. The timeline's draw-in wipe is gone. Reduce Motion: a
  0.18 s crossfade.
- 97 tests pass.

## 2026-11-10: double-click plays, triple-click opens the timeline

- Song list: one click selects, a double-click plays the song from its top (the song already
  playing carries on), a third click opens the timeline. Read from the click's own count, so the
  double-click acts at once instead of waiting out a possible third click.

## 2026-11-10: firing pulse, import labels to console

- Firing pulse: a trigger swells 14% with a gold glow and a bloom behind its line, and its lane's
  name lights up in the lane colour, then settles (0.275–0.4 s ease-out, halved from 0.55–0.8 s). Driven by its own
  animation from `firedAt` / `laneFiredAt`, so it plays when stopped too (Fire Now, lane keys).
  Reduce Motion: glow only, no scale.
- Import labels to console: `ExecutorLabel.plan` (tested) makes one label per executor from the
  album's named lanes, most-used name first, consoles merged (empty = all). The sheet lists every
  executor with an editable name, a picker where songs disagree, and the consoles it goes to;
  untick to skip. Sent as `/gma3/cmd` command lines, 15 ms apart. Default command
  `Label Exec {page}.{exec} "{name}"` (editable, saved per Mac); double quotes in names become
  single quotes. **Needs a check on the console** that labelling the executor names its sequence.
- 99 tests pass.

## 2026-11-10: smooth UI, pulses on the sound

- The ambient background was two window-sized shapes under a 120 pt blur, redone by the GPU every
  frame. Now radial gradients in a drawing group: the same look, next to no cost.
- The timeline rebuilt every lane, trigger and the waveform 30 times a second while playing. Now
  the still parts are drawn once (on song, zoom or edit changes) and only a live layer redraws per
  frame: the playhead, the played part of the waveform (an equatable waveform masked to the
  playhead) and the trigger pulses. The waveform is one path per draw.
- Trigger pulses during playback are drawn from the playhead itself (the position you hear,
  latency included), at 60 fps, instead of travelling audio queue → main thread → re-render →
  animation. Manual fires (Fire Now, lane keys) still use the animated pulse.
- Values that changed every frame no longer publish to every view: incoming timecode while
  following, the last trigger sent; the follow status only publishes when it changes. The
  Connections page reads those on its own timer.
- CI records CPU for the app and the window server on each screen while playing.
- Big clocks are equatable (redrawn only when the frame shown changes); progress lines and
  "starts in" update 10 times a second. CI, playing, app CPU before → after: Now playing 45 → 35%
  (first pass), Timeline 44 → 31%, Connections 78 → 56%, Labels sheet 71 → 37%; window server
  roughly halved. (CI Macs have no GPU, so real Macs use less.)

## 2026-11-11: full-screen player

- A Now Playing screen in the Apple Music style, with no timeline: large artwork (the album cover
  when the setlist has one, else the song's art; it eases back a touch when paused), title,
  artist · album · song n of m, a draggable scrubber (thicker on hover; locates on release),
  large transport with a gold play button, the live timecode and rate, Loop / Stop after each,
  the state chips, and Up Next (solid list; double-click plays, right-click to cue). Up Next hides
  on narrow windows. Open it by clicking the song in the player bar or ⇧⌘P; chevron or Esc goes
  back; Timeline and Clock are a click away. Same screen transition as the timeline.
- Up Next starts collapsed to just the next song ("Next · +n more"), as a card that hugs its
  content; click the header or chevron to show the rest of the set (full-height list), and again
  to collapse. Opens collapsed each time.
- With Up Next folded, the player is centred in the whole window and the Next card floats in the
  corner; unfolding gives the queue a column and the player glides over (0.4 s, crossfade under
  Reduce Motion).
