# Ideas from CuePoints V2

A living list of ideas inspired by CuePoints V2, not a copy of it.

Sources: [cuepoints.com](https://cuepoints.com/), [the CuePoints docs](https://cuepoints.com/docs/getting-started) and [TPi's launch piece](https://www.tpimagazine.com/introducing-cuepoints-a-smart-way-to-share-timings-and-ideas-with-others/).

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
