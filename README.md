# Vivid Playback

A Mac app for show playback: import a timecode offset sheet with its master references and
timecode references, check that they all agree, and play songs or a whole setlist with a big
timecode clock. It's built to replace a Reaper session for this one job.

It looks like Apple Music in the Vivid glass material: simple playback first, and a song's
timeline only when you ask for it.

## Get the app

Every push to `main` is built on a GitHub Mac and published as its own version
(`Vivid Playback 0.2.N.dmg`) on this repo's **Releases** page; the newest is marked Latest.
Open it and drag Vivid Playback to Applications, choosing **Replace** if asked. Shows live in
Documents › Vivid Playback, so updating or deleting the app never touches them. It runs on macOS 13 (Ventura) or later, on Apple silicon and Intel.

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
- **Add audio after importing:** drop files or a folder on the song list and they're matched to
  the songs still missing them (never replacing a file a song already has). Drop one file on a
  song to give it that file: the app listens for LTC in it, so a timecode file is recognised
  whatever it's called (the name only decides when a file can't be read).
  Or right-click a song, or use the file names in the song timeline, to choose, replace or
  remove its master or timecode file. **File › Add Audio Files…** (⇧⌘A) does the same from a
  picker. A timecode file given to a song the sheet left without timecode sets its start from
  the LTC in the file.

Keys: **Space** play or pause · **← →** previous and next song · **⌘←** top of the song ·
**Return** or **⌘T** song timeline · **M** add a marker · **C** add a trigger · **L** loop between markers ·
**⌘G** go to timecode · **⇧⌘F** full-screen clock · **Esc** back to the library ·
**⌥⌘O** audio output · **⇧⌘E** edit setlist · **⇧⌘L** show mode · **⇧⌘I** things to check.

**Timecode:** a song with a timecode file sends that file, exactly as recorded, and the big
clock shows the timecode read from it (what the console receives). Only a song with no
timecode file gets timecode generated from the sheet, and the chip says which. If a timecode
file can't be read, no timecode is sent and a red chip says so; it never substitutes.

**Triggering grandMA3 executors:** in the song timeline press **C** (or Trigger lane) to add a
lane for an executor. Choose its page and executor, what it does (Go+, Go−, Top, On, Off, a
fader level, or any command line) and which consoles it fires. Each lane is a row under the
waveform. Click a lane, then **C** drops a trigger at the playhead; double-click a lane to drop
one anywhere, drag a trigger to move it, right-click for level, nudge, fire now or delete.
**Key it in live:** give each lane a key (new lanes get 1, 2, 3…; change it in Edit Lane).
Play the song and press a lane's key: a trigger lands on that lane at the frame you heard when
you pressed it. With **Keys fire the console** on, the executor also goes as you press, so you
see the look while you program. **Delete** takes back the selected trigger, which is always the
last one you dropped.

**Zoom:** pinch over the timeline, ⌘-scroll, or **⌘=** / **⌘−** (**⌘0** fits the whole song).
Two-finger swipe or the bar under the ruler moves along; while playing it pages with the
playhead. Click a marker or trigger to select it, drag it to move it (it lands on a whole
frame), **⌥← ⌥→** nudge it a frame (**⇧** for ten), **Delete** removes it.

Triggers fire over OSC on time with the music you hear (the same clock as the timecode), and
flash gold as they go. Lanes belong to the show; each song has its own triggers.

Set up the consoles under **Connections › Consoles**: name, IP address, port (8000) and prefix
(gma3). On the grandMA3: Menu › In & Out › OSC, add a line on port 8000 with prefix gma3, and
turn on Receive and Receive Command. **Fire early** sends every trigger up to 200 ms ahead to
cover the console's own delay. Commands go to `/gma3/cmd` (for example `"Go+ Exec 1.201"`);
fader lanes send `/gma3/Page1/Fader201` with a level from 0 to 100.

**Audio output:** pick the interface, the master outputs (a stereo pair, or one output in mono)
and the timecode output. On a two-output Mac, put the master on Output 1 (mono) and timecode on
Output 2. The timecode level is set on its own and never follows the master level.

**Saving:** every change saves itself to `~/Documents/Vivid Playback/<show>.vividshow`, and the
last show reopens on launch, including after installing a new version. **File › Save** (⌘S)
saves once more and says where; **Save a Copy…** (⇧⌘S) makes a backup or a copy for a USB
stick; **Show Show File in Finder** opens the folder.

## What's in this build

| | |
|---|---|
| Timecode math, every rate (23.976, 24, 25, 29.97, 29.97 DF, 30) | Done, tested |
| Offset sheet import with column auto-detection | Done, tested (CSV and tab-separated) |
| Matching masters and timecode files to songs | Done, tested |
| LTC decoding and checking (start, rate, jumps, dropouts, lengths, sample rates) | Done, tested |
| Library, big clock, glass player bar, song timeline with the morph, markers, full-screen clock, first run | Done |
| Audio: master and LTC out of your interface, sample-locked, any output channels, fixed LTC level | Done (the lock is tested in the core; needs a check on your interface) |
| Timecode generated from the sheet when a song has no timecode file | Done, tested |
| Setlists: reorder, skip tonight, duplicate; stop after each song; show mode lock | Done |
| Loop between markers, go to timecode, rename and delete markers | Done |
| Excel (.xlsx) sheets | Done, tested. Numbers files: export as .xlsx or CSV. |
| Interface unplugged mid-show: playback stops with a clear banner | Done |
| MIDI timecode, Art-Net timecode, following incoming timecode, OSC and MIDI remote | Done (needs a check on your rig) |
| grandMA3 executor trigger lanes over OSC, console targets, fire early | Done (needs a check on your console) |
| grandMA3 timecode show export | Later (see docs/IDEAS-CUEPOINTS.md) |

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
