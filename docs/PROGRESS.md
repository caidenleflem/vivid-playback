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

## 2026-11-11: songs play their whole audio

- Bug: a song stopped at the sheet's length even when its audio ran longer (or ran on in silence
  when shorter). Now the sheet's length is only the starting point: each check measures the audio
  (`Song.audioLength`, the longer of master and timecode file) and `Song.playLength` is the audio's
  length from the song's start, falling back to the sheet only before any audio is assigned
  (tested). The transport ends at the loaded audio's end; the song list, timeline, player, Up Next,
  setlist durations, sorting and following incoming timecode all use the same length. The sheet's
  own value is kept as it was (never changed silently). A song with only a timecode file plays
  for as long as that file.
- 101 tests pass.

## 2026-11-11: record from the desk

- Record desk (timeline top bar, or ⇧⌘R): while armed and playing, every GO from the desk lands as a
  trigger on the lane for its executor, at the position you hear. An executor with no lane yet gets
  one. A GO within 8 frames of a trigger the lane already has is ignored (the desk echoing a
  trigger the app just fired, or a double press). The cue number, when sent, names the trigger.
  ⌘Z takes back recorded triggers.
- Inputs (core `DeskGo`, tested): OSC `/vivid/exec` with "1.201", "201", or page and executor as
  numbers, optional cue after (on a grandMA3: `SendOSC 1 "/vivid/exec,s,1.201"`); MIDI Show Control
  GO from MIDI, or from the network on UDP 6004 while armed (the MSC message is found inside any
  header the desk puts in front). The MSC cue list is read as the executor; "a.b" is tried as
  page.executor and executor.page.
- `/vivid/go` stays Play.
- **Needs a check on the desk:** what the grandMA3 puts in the MSC cue list on GO, and its
  MSC-over-network packet.
- Export to the desk (timecode show) is waiting on one exported timecode XML from the desk: the
  file format isn't published, and the pages describing it are blocked from the build session.

## 2026-11-11: instant song switches

- **The whole set stays loaded.** When a show opens, every song loads into memory in the
  background, in set order from the playing song (then the songs before it, then the rest of the
  album). Picking any song, Next, Previous, a desk command or following timecode now switches on
  the next audio block, with no loading. Up to half the Mac's memory is used (about 140 MB for
  four minutes of stereo plus timecode at 48 kHz). If the set doesn't fit, the songs from the
  playing one on are kept and a chip says how many load when cued. While loading, a quiet chip
  shows "Getting the set ready · 6 of 22". Playback is fine meanwhile.
- **Songs run straight into each other.** With auto-advance on, the next song is armed on the
  audio thread and starts on the exact sample after the last one ends, master and timecode
  together. Before, a 50 ms timer noticed the end, stopped, then started the next song, which
  left a gap. The screen, the network timecode (MTC, Art-Net) and the triggers follow the new song
  at once, even in the few milliseconds before the screen catches up. Looping, stop after each,
  and the end of the set still stop as before.
- **Cuts don't click.** Switching song mid-song, or jumping in a song while playing, crossfades
  the master over 8 ms. The two never add up past full level. The timecode never fades: the new
  song's timecode is out on the first sample. Stopping drops any fade that's left.
- **A switch lands whole.** The new song, where it starts and whether it plays go to the audio
  thread together, through a lock that the audio thread only ever tries (never waits on). A
  switch can no longer play one block of the new song at the old position.
- **No stale audio.** A loaded song is used only while its files, start, offset, rate and
  timecode channel still match (core `Song.audioKey`). Change any of them and it reloads.
- Core: `Playhead` and `Mixer.render(&playhead…)` (run-on, crossfade), `SetMemory` (order,
  budget, what fits), `Song.audioKey`. 125 tests pass.
- Checked on Linux: the transport, clock and audio state compile against stubs, and a simulated
  three-song set played through the real transport code ran on with zero gap samples, with the
  timecode switching on the same sample as the master.
- **Needs a check on the Mac:** auto-advance between two real songs, a mid-song switch on a loud
  master (no click), and memory use with a full set loaded (Activity Monitor).

## 2026-11-11: master and timecode on different interfaces

Caiden's aggregate device wasn't working, and he asked to pick separate interfaces for the
master and for LTC.
- Audio output now has **Master interface** and **Timecode interface** ("Same as the master", or
  any other interface), and the timecode output list shows the chosen interface's outputs and
  names.
- With two interfaces, the app joins them into one private device of its own (Core Audio's
  aggregate, built the same way every time): the master's interface is the clock, the timecode
  interface is kept in step by drift correction, and both run at the master's sample rate. Only
  this app sees it, and it goes away when the app quits. The engine still renders the master and
  timecode from one frame counter; the sheet says that a word clock (or Dante on both) gives a
  perfect lock.
- Core: `OutputRouting.timecodeDeviceUID` (older shows load with timecode on the master's
  interface), `OutputMap(routing:slots:)`. A timecode channel the other interface doesn't have,
  or a timecode interface that isn't connected, sends no timecode: it's never moved onto the
  master's interface. 7 tests; 132 pass.
- Unplugging either interface stops playback and says which one. One that comes back mid-song is
  used once playback stops (the audio never restarts mid-song).
- Meters, the Outputs box and the LTC card follow the real outputs and name the timecode interface.
- **Needs a check on the Mac:** both interfaces show up and play; timecode on the second one reads
  on the desk across a full song with no drift; latency between the two (loop the LTC back, or
  compare with the clock). If Core Audio won't join them, the sheet says so and no timecode goes out.
- Caiden's own aggregate gave no sound. Likely causes, now shown in the app: an aggregate numbers
  its outputs straight across its interfaces (outputs 1–2 are whichever interface is first in
  Audio MIDI Setup), and interfaces at different sample rates can leave it silent. Aggregate
  outputs are now labelled with their interface ("Output 3 · MOTU M4 out 1"), the sheet lists
  which outputs belong to which interface, and warns when their rates differ.
- New rule (Caiden's call): always merge to `main` after pushing.

## 2026-11-11: timecode interface fix

- Caiden picked the Scarlett as the timecode interface: the app joined it with the MacBook's
  speakers, but sent no timecode (yellow, "Choose a timecode output"). The audio engine reported
  the output layout of the device it started on (the MacBook's 2 outputs), so the Scarlett's
  outputs looked missing and timecode was dropped. The engine now takes the outputs and sample
  rate from Core Audio's own description of the device (then the output unit's, then the
  engine's), which may also be why his own aggregate stayed silent.
- When a timecode output is chosen but the running audio can't reach it, the LTC card and the
  Audio output sheet now say so, instead of "Choose a timecode output".

## 2026-11-11: steadier meters, louder master

- Meters flickered on the joined MacBook + Scarlett device: it delivers audio in bigger, uneven
  blocks, so some meter reads saw no new audio and dipped, then jumped back. Meters now read 60
  times a second, hold still between audio blocks, rise at once, fall at 24 dB a second and hold
  the peak for 1.5 s (core `MeterBallistics`, tested).
- Master level goes to +12 dB (was 0). Above 0 dB a limiter on the master bends anything over
  -1 dBFS smoothly so it never clips; at 0 dB or below it isn't in the path. Timecode is never
  touched (core `Mixer.limit`, tested). 138 tests pass.

## 2026-11-11: network port per protocol

Caiden: sending wasn't working, and he wants to pick which network port (NIC) each protocol
uses. Until now macOS chose for every packet: with Wi-Fi and a wired show network, Art-Net to
2.255.255.255 and OSC to the console could leave on the wrong port.
- Every console card, Art-Net out, OSC in (remote), Art-Net in (follow) and MIDI Show Control
  in (record from the desk) has a **Network** choice: Automatic (macOS chooses; the picker says
  which port that is for the target) or one of the Mac's ports by the name macOS gives it
  ("USB 10/100/1G LAN · 10.0.0.12"). Saved per Mac, by the port's system name (en7).
- Sockets are tied to the chosen port (IP_BOUND_IF): what's sent goes out that port and
  listeners only hear that port. A port that's unplugged says so; sending makes a fresh socket
  when it fails, and listeners start again within 3 seconds when the port comes back.
- Warnings when a console's address or the Art-Net broadcast isn't on the chosen port's network
  ("2.255.255.255 isn't on USB LAN's network (10.0.0.0/8)"). Art-Net's Send to menu offers the
  chosen port's own broadcast and 255.255.255.255. Nothing is changed for him.
- OSC in shows the chosen port's address to send to.
- Core: `NetworkPort` and `IPv4` (networks, broadcast, which port reaches a host, mismatch
  wording), `ConsoleTarget.networkPort` (older settings load on Automatic). 143 tests pass.
- **Needs a check on the Mac:** Art-Net and OSC leave on the chosen port with Wi-Fi on; listening
  on a chosen port hears the desk.

## 2026-11-11: grandMA3 executors addressed by page

- Caiden: MA3 executors are addressed "Go+ Page 3.201", not "Exec 3.201". Go+, Go-, Top, On and
  Off triggers now send `<action> Page <page>.<exec>`, Import labels to console defaults to
  `Label Page {page}.{exec} "{name}"` (a Mac still on the old built-in default moves to the new
  one; a template Caiden wrote is left alone), and the examples on screen match. Custom commands
  are his own text and aren't changed.

## 2026-11-11: build on Caiden's Mac

- GitHub's queue for a free Mac ran past 7 minutes, so Caiden builds on his own Mac:
  `scripts/build-here.sh` (run it straight from GitHub with curl) pulls the newest `main` into
  `~/Library/Caches/VividPlayback-build`, builds for this Mac's chip only (`UNIVERSAL=0` in
  `make-app.sh`), replaces the app in Applications and opens it. Only Apple's Command Line Tools
  are needed (it offers to install them). Later builds only compile what changed.
- This cloud session can't reach his Mac: the VividPlayback folder is in his Remote Control list
  but isn't offered to cloud sessions.

## 2026-11-11: beat grid

- **Find the beat** (timeline top bar › Beat grid): listens to the song's master in the
  background and draws bars and beats behind the waveform and lanes, with bar numbers. Nothing on
  the timeline moves. It says how well it fits: the whole song, up to where the music moves off it
  (a tempo change, a live section), or only part of it ("check it by ear").
- Detection (core `BeatDetector`): onsets at 100 Hz from three bands (kick, hats/snare, all),
  tempo by autocorrelation leaning to 80–160 BPM, related tempos (×2, ÷2, ×1.5, ×⅔) compared,
  then folded to a hundredth of a BPM so the grid doesn't drift over four minutes. Bar 1 is the
  song's start when a beat is there (the sheet's start is usually the downbeat), otherwise the
  beat the kick hits hardest. A steady pad or silence finds nothing. On a 4-minute 48 kHz song it
  takes about 0.06 s; 92–153 BPM came out exact, beats within 5 ms; very slow or very fast songs
  can come out at double or half, hence ×2 / ÷2.
- Fixing it: type a tempo, ÷2 / ×2, Bar 1 starts at the playhead, move bars a beat either way,
  line up by 5 ms, beats in a bar, remove (⌘Z-style Undo in the notice).
- **Snap**: with it on, a dragged marker or trigger lands on the grid (bar, beat, ½ or ¼ beat; a
  dragged selection keeps its spacing). Recording (keys, desk GOs) is never snapped.
- **Selected onto the grid** (Q, or the selection bar): moves what's selected onto the nearest
  grid point and says how many moved and by how much; ⌘Z puts them back.
- Core: `BeatGrid` (bars/beats, snapping to whole frames, fixes), `Song.beatGrid` (older shows
  load without one). 156 tests pass.
- **Needs a check on the Mac:** detection on real masters (and how often it's double/half), the
  lines' look at different zooms.

## Open: timeline glitchy while a song plays

- Caiden (2026-11-11): the song timeline is "super glitchy" while a track is running. Not looked
  at yet. Suspects to check first: the meters now publish up to 120 changes a second (60 Hz, level
  and hold separately) and every view watching them redraws; the beat grid lines redraw with the
  static layer whenever the zoomed window pages along; and the transport's 20 ms tick.
- Caiden: the meters are still glitchy after the 60 Hz / hold-between-blocks change. Likely the
  same root as the timeline (the main thread busy redrawing, so meter reads and redraws come late
  and uneven), or the peak reset racing the audio thread. Look at both together.

## 2026-11-11: Vivid Recorder plugin for grandMA3, songs from desk macros

- **Vivid Recorder** (Timeline › Save grandMA3 Plugin…, or Connections › Record from the desk):
  writes `VividRecorder.xml` and `.lua` for the desk (made for 2.3.2.0). Run it once to start
  and again to stop. Every 20 ms it looks at the executors with a sequence on the fader page the
  desk is on (only that page; a page change only learns where things are) and, when one changes
  cue or goes on/off, sends `/vivid/seq "3.201" "on" "5" "4" "3" "on" "Chorus"` with SendOSC on
  OSC line 1 (OSC_LINE at the top of the .lua). `Plugin "Vivid Recorder" "test"` prints what it
  sees on the command line, to check it against the desk.
- The app records what the sequence did, so playback puts it back the same way: next cue Go+,
  previous Go-, first cue Top, back on where it was On, off Off, anything else Goto that cue
  (`Goto Cue 5 Page 3.201`). Triggers carry their own action when it isn't their lane's, and the
  timeline shows it ("Go− · Verse", "Goto Cue 5"). Cue names become the triggers' names.
- Recording stays on the selected song: while recording, the song stops at its end instead of
  running on into the next.
- **Song macros:** `/vivid/song` already selected a song by number or title; each song's menu
  now has Copy Desk Command (`SendOSC 1 "/vivid/song,i,12"`) to paste into its macro.
- Core: `DeskSequenceEvent` (reading the plugin, deciding the action), `Marker.action`,
  `LaneAction.gotoCue`, `DeskPlugin` (the files). The plugin was run against a mock desk (Lua
  5.5 here): Go+, Go-, Goto 5, Top, Off, On and a second sequence each sent one message, a page
  change sent nothing, a second run stopped it. 163 tests pass.
- **Needs a check on the desk (2.3.2.0):** the plugin imports (XML shape), `CurrentExecPage`,
  executor `Object`, `seq:CurrentChild()` and cue `No` read as expected (run the "test"
  argument), SendOSC arrives, and `Goto Cue 5 Page 3.201` is the right Goto.
- Install scripts gave the app one second to quit; when it took longer, the new build was copied
  in under the old one still running, and opening it brought back the old window (Caiden saw no
  plugin button after a good build). Both scripts now wait for it to quit, and stop with a note if
  it won't.

## 2026-11-11: OSC in from the desk

- Caiden: OSC from the desk isn't arriving properly. Likely cause: a desk OSC line with a prefix
  (the setup steps say gma3) puts it in front of what SendOSC sends ("/gma3/vivid/go"), and the
  app only took addresses starting "/vivid/". Remote commands, desk GOs and the plugin's
  /vivid/seq now accept "/vivid/<command>" behind any prefix (core `OSCMessage.vividCommand`,
  tested; 164 tests pass).
- The OSC card has a **Heard** list: the last 8 messages that arrived, who sent them, and what
  the app made of each ("not a Vivid command" in amber), so a wrong address, port or network
  shows at once.

## 2026-11-11: Vivid Labels plugin

- Caiden wanted the desk's names on the lanes. **Vivid Labels** (saved with Vivid Recorder by
  Playback › Save grandMA3 Plugins…): run it on a fader page and it sends
  `/vivid/label "3.201" "Verse wash"` for each executor with a named sequence (quotes, commas and
  semicolons dropped). The app names every lane that fires that page and executor, in every song,
  and gathers the page into one notice with one Undo ("Named 6 lanes after the desk's sequences, in
  12 songs. No lane fires 3.207 yet."). Run against a mock desk: only real, named sequences are sent.
- Core: `DeskLabel` (reading it, naming the lanes), `DeskPlugin.Labels`. 166 tests pass.
- **Needs a check on the desk:** the sequence's `Name` reads as expected.
- GitHub's backup builds kept waiting 15 minutes for a Mac and being cancelled (never a compile
  failure; Caiden's own builds compile). The workflow now builds only the newest push (older
  waiting ones are dropped) and skips pushes that only change notes (docs, .md).

## 2026-11-11: lots of lanes, smoother recording

- **Scrolling lanes:** lanes share the room down to 22 points each; past that the whole timeline
  scrolls up and down (lanes 26 points, the waveform 100–200), so the playhead, beat grid, marker
  lines and selection boxes stay lined up. Up/down on the trackpad or wheel scrolls the lanes when
  they overflow; sideways pans when zoomed; ⌘/⌥ zooms, as before.
- **Choppy while recording**, causes found and fixed:
  - Every change wrote the whole show to disk on the main thread, then refreshed the Albums
    list and the Saved line; recording did that per trigger and per new lane. Saves now gather:
    written once, half a second after the last change, off the main thread. Opening another show
    and quitting write at once; a show whose file went to the Trash drops what's waiting.
  - While recording: new triggers and lanes don't animate, and the selection and chosen lane
    don't jump to each new trigger.
  - The OSC Heard list is its own object, so incoming OSC only redraws that list, not the
    timeline.
  - The lane glow and trigger bloom checked every trigger against every lane 60 times a second;
    now one pass over the triggers.

## 2026-11-11: OSC out stopped (being looked at)

- Caiden: the app receives OSC but doesn't seem to send any more. Lead suspect: macOS Local
  Network privacy. Each build on his Mac is signed differently, so macOS can treat it as a new
  app and block its sends to the show network until allowed again. Not confirmed.
- A failed send now says why, from the system, in plain words: under Consoles on Connections
  (and in the pill's tooltip), e.g. "macOS blocked it … allow Vivid Playback in Privacy &
  Security › Local Network", "No way to reach 10.0.0.69", "The network port picked for grandMA3
  isn't connected", "… isn't an IP address".
- Not the signing: the GitHub build (0.2.72) doesn't send either, and nothing shows in the desk's
  command line. Next suspect: onPC on the same Mac listening on 8000, the port OSC in also took
  (shared, so the two split the messages silently). OSC in and MIDI Show Control in now take
  their port alone: another app on it shows "Port 8000 is in use by another app (grandMA3 onPC…)".
  A console target that's this Mac on the OSC-in port gets a warning and a one-click "Listen on
  8001 instead". Art-Net in stays shared.

## 2026-11-11: desk hits land at the right time, even in a burst

- Caiden: lots of OSC at once while recording messed up the timing. Three causes, all fixed:
  - Hits were timed when the main thread got to them, not when they arrived. They're now timed
    the moment they arrive, on the network thread (OSC, MIDI Show Control over the network), and
    the playhead is counted back to that moment (`Transport.position(at:)` now goes up to 2 s
    into the past).
  - Each hit was its own edit and its own redraw. A burst now lands in one edit, one redraw and
    one ⌘Z.
  - The desk sends one command per change, so later hits in a burst left later. The Vivid
    Recorder plugin now stamps every change with the desk's clock (`Time()`), looks every 10 ms
    (was 20), and Vivid puts the stamps on its own clock (core `DeskClock`: the fastest recent
    message shows the true offset; drift and a restarted plugin are followed; no stamp or a
    whole-second clock falls back to arrival time). Tested with 20 hits arriving over 400 ms:
    all land on the instant they happened. 171 tests pass.
- **Re-save the plugins** (Save grandMA3 Plugins…) to get the stamped recorder; the old one still
  works, timed on arrival. **Needs a check on the desk:** `Plugin "Vivid Recorder" "test"` prints
  the desk clock; it should read with decimals.

## 2026-11-11: record presses only

- Caiden: recording must only take real button presses, not every time a sequence moves. The
  plugin can't see the button itself, so everything that isn't a press is filtered out:
  - **Vivid's own triggers coming back:** the trigger service remembers what it fired; the desk
    moving that page.executor within 0.75 s after is the echo and isn't recorded (core
    `DeskEcho`, tested). Applies to plugin changes and OSC/MSC GOs. Shown as "Vivid fired that,
    not recorded".
  - **Cues that run by themselves:** the plugin skips a change into a cue whose trigger is
    Follow, Time, Sound, BPM or Timecode (read from the cue's Trig, or its first part's). The
    next real press is still read from where that cue left the sequence. `Plugin "Vivid Recorder"
    "test"` shows each current cue's trig.
  - **The desk's own timecode show** moving sequences can't be told apart from a press: switch it
    off (or its timecode input) while recording.
- 172 tests pass; the plugin was run against a mock desk with a Follow cue.
- **Needs a check on the desk:** the cue's trig reads (the "test" line shows it).

## 2026-11-11: record-arm, with the desk's timecode show running

- Caiden needs the desk's timecode show running while recording, and the plugin can't tell its
  moves from a press. **Record-arm** (like a DAW): while recording (or once anything is armed),
  each lane shows a record dot; right-click a lane for Arm / Arm All / Disarm All. While any
  executor is armed, only armed executors record (plugin changes, OSC and MSC GOs); others say
  "not armed". Nothing armed records everything, as before. Arming is per executor (page.exec),
  for this session.
- Toward filtering the timecode show's own moves on armed executors: the plugin's test mode now
  also lists the desk's timecode shows (tracks, targets, first events with their times and
  tokens), to learn how 2.3.2.0 stores them. Next: read that and skip changes that line up with
  the show's own events.

## 2026-11-11: grandMA3 timecode import

- Caiden: what's really needed is importing a grandMA3 timecode show into a song's markers. He
  sent a 2.3.2.0 export (DIVA). **Playback › Import grandMA3 Timecode…** (or the link on an empty
  timeline): pick one or more XML exports. Each show goes onto its song: by name, else the song
  its start timecode falls in, else the selected song (and says which). One lane per track,
  named after it, **firing its sequence directly** (`Go+ Sequence "DIVA DROP KICK"`,
  `Go+ Sequence 82`), as the desk's timecode show does: no executors needed. One trigger per
  event at offset + time (nearest frame), named after its cue; the lane does what most of the
  track does and the rest carry their own action (Off on a Go+ lane). Re-importing reuses lanes
  and skips triggers already there. Reported, never fixed: events outside the song, events Vivid
  can't send (Flash, Temp…), tracks that fire something other than a sequence, and a desk show
  that starts at a different timecode than the song. One notice, one Undo.
- Lanes can target a sequence (`TriggerLane.sequence`); the lane editor shows it, with "Fire an
  executor instead". Sequence lanes stay out of Import Labels to Console.
- Core: `MA3Timecode` (XML reader), `MA3TimecodeImport` (song matching, applying). The real
  DIVA export: 9 lanes, 247 triggers, nothing outside or unsupported. 179 tests pass.
- Caiden didn't ask for the record-arm and timecode-listing work just before this; it stays (it's
  harmless) but isn't the direction. He mentioned needing "a new one" (likely a re-saved plugin).

## 2026-11-11: every trigger type, per-trigger actions, re-import only new

- **Every grandMA3 executor function** as a trigger: Go+, Go−, Top, Goto cue, On, Off, Toggle,
  Flash, Temp, Swap, Select, Pause, Kill, Learn, Load, Black, Rate1, Speed1, DoubleSpeed,
  HalfSpeed, DoubleRate, HalfRate, plus **Desk command** (any word before the target, e.g.
  "Flash Off") and Custom (a whole line; `{target}` added alongside {page} {exec} {value} {label}).
  The lane editor offers the rest under More.
- **Each trigger can do its own thing:** right-click a trigger › Trigger (applies to the whole
  selection when it's in it): As the lane, any function, Goto Cue…, Desk Command…, Custom
  Command…. Edit Trigger… shows what it does, its cue or command, and exactly what it'll send.
  The timeline names a trigger's own action ("Toggle · HITS", "Flash Off").
- **Import keeps every desk word:** known ones by name, anything else as a Desk command with the
  desk's word; a Flash/Temp/Swap release (Status Off) as "<word> Off". Only events with no word at
  all are left out (and counted).
- **Re-importing brings only new data:** each song remembers the desk events it imported
  (sequence, timecode to the millisecond, word). Importing again adds only events new on the
  desk, even after imported triggers were moved or deleted here; a deleted lane isn't brought back
  unless its track has something new. The real DIVA file: 247 then 0.
- Core: new `LaneAction` cases and `keyword`, `Marker.command`, `Song.importedDeskEvents`. 182
  tests pass.
- **Needs a check on the desk:** the one-word functions and "Flash Off" as command lines.

## 2026-11-14: the recorder plugin broke song macros on the desk

- Caiden: with the plugin in, song macros triggered from a cue command no longer ran properly
  (tapping them by hand did). Cause: while Vivid Recorder runs it sends a SendOSC on the desk's
  command line the instant a sequence changes cue; a cue whose command starts a macro had its
  macro cut into at that same moment. And the plugin kept running after recording stopped (it
  only stopped when run again).
- Fixed in the plugin: changes wait a quarter of a second, then go through the command queue
  (`CmdIndirect`, falling back to `Cmd`), never the live command line at the moment a cue fires
  (the desk-clock stamp keeps the timing). It takes "start" / "stop" arguments, ignores a second
  start, sends anything still waiting when stopped, and stops by itself after three hours. Checked
  on a mock desk.
- Fixed in Vivid: Record desk sends `Plugin "Vivid Recorder" "start"` to the enabled consoles, and
  stopping sends "stop" (also when Vivid quits mid-recording), so it only runs while recording.
  A toggle under Record from the desk turns this off.
- Caiden's immediate fix: run the plugin once more to stop it (or reload the show / restart).
- **Needs a check on the desk:** `Plugin "Vivid Recorder" "start"` passes its argument, and
  CmdIndirect exists on 2.3.2.0.
