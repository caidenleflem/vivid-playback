import SwiftUI
import PlaybackCore

/// A plain solid sheet: title, a line of help, content, Done.
struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 560
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
            if let subtitle {
                Text(subtitle).font(.manrope(13.5)).foregroundStyle(Brand.steel).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(24)
        .frame(width: width)
        .background(Brand.phantom)
        .preferredColorScheme(.dark)
    }
}

private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label).font(.manrope(13, .semibold)).foregroundStyle(Brand.steel).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: Audio output

struct OutputSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport

    var body: some View {
        let routing = model.show?.routing ?? OutputRouting()
        let device = model.devices.first { $0.uid == routing.deviceUID } ?? model.devices.first { $0.uid == transport.audio.device?.uid }
        let channels = max(2, device?.outputChannels ?? transport.audio.channelCount)
        SheetFrame(title: "Audio output",
                   subtitle: "Where the master plays and where timecode goes out. It's saved with the show, and the timecode level never follows the master level.") {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: "Interface") {
                    Picker("Interface", selection: Binding(
                        get: { routing.deviceUID ?? device?.uid ?? "" },
                        set: { uid in model.updateRouting { $0.deviceUID = uid } })) {
                        ForEach(model.devices) { d in
                            Text("\(d.name)\(d.isDante ? " · Dante" : "") · \(d.outputChannels) outputs · \(Int(d.sampleRate)) Hz").tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                    Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle())
                        .help("Look for interfaces again")
                }
                FormRow(label: "Master") {
                    Picker("Master", selection: Binding(
                        get: { routing.masterChannels.count > 1 ? routing.masterChannels[0] : -(routing.masterChannels.first ?? 1) },
                        set: { tag in model.updateRouting { $0.masterChannels = tag > 0 ? [tag, tag + 1] : [-tag] } })) {
                        ForEach(Array(stride(from: 1, to: channels, by: 2)), id: \.self) { c in
                            Text("Outputs \(c)–\(c + 1) (stereo)").tag(c)
                        }
                        ForEach(1...channels, id: \.self) { c in
                            Text("\(device?.outputLabel(c) ?? "Output \(c)") only (mono)").tag(-c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }
                FormRow(label: "Timecode") {
                    Picker("Timecode", selection: Binding(
                        get: { routing.timecodeChannel ?? 0 },
                        set: { c in model.updateRouting { $0.timecodeChannel = c == 0 ? nil : c } })) {
                        Text("Not sent").tag(0)
                        ForEach(1...channels, id: \.self) { c in
                            let label = device?.outputLabel(c) ?? "Output \(c)"
                            Text(routing.masterChannels.contains(c) ? "\(label) (used by the master)" : label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }
                if let d = device, d.isDante {
                    danteCard(d, routing: routing)
                }
                if let tc = routing.timecodeChannel, routing.masterChannels.contains(tc) {
                    note("Timecode can't share an output with the master. Pick another output, or put the master on one output (mono).", warn: true)
                } else if channels <= 2 && routing.masterChannels.count == 2 {
                    note("This interface has two outputs and the master uses both. For timecode, set the master to Output 1 only (mono) and timecode to Output 2.", warn: true)
                }
                FormRow(label: "Timecode level") {
                    Slider(value: Binding(get: { routing.timecodeGainDB }, set: { v in model.updateRouting { $0.timecodeGainDB = v.rounded() } }),
                           in: -24...0)
                        .frame(width: 260)
                    Text("\(Int(routing.timecodeGainDB)) dB").font(.manrope(13).monospacedDigit()).foregroundStyle(Brand.ink).frame(width: 50, alignment: .trailing)
                }
                FormRow(label: "Master level") {
                    Slider(value: Binding(get: { routing.masterGainDB }, set: { v in model.updateRouting { $0.masterGainDB = v.rounded() } }),
                           in: -40...0)
                        .frame(width: 260)
                    Text("\(Int(routing.masterGainDB)) dB").font(.manrope(13).monospacedDigit()).foregroundStyle(Brand.ink).frame(width: 50, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ChannelMeter(label: "Master", channel: routing.masterChannels.first.map { $0 - 1 })
                    if routing.masterChannels.count > 1 { ChannelMeter(label: "", channel: routing.masterChannels[1] - 1) }
                    ChannelMeter(label: "Timecode", channel: routing.timecodeChannel.map { $0 - 1 })
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.solid))
                HStack {
                    Button {
                        transport.testing ? transport.stopTest() : transport.startTest()
                    } label: {
                        Label(transport.testing ? "Stop test timecode" : "Send test timecode",
                              systemImage: transport.testing ? "stop.fill" : "dot.radiowaves.right")
                    }
                    .buttonStyle(QuietButtonStyle(prominent: transport.testing))
                    .disabled(routing.timecodeChannel == nil || transport.isPlaying || !transport.audio.isRunning)
                    Text("Timecode only, never the music. Also goes out as MTC and Art-Net if they're on.")
                        .font(.manrope(11.5)).foregroundStyle(Brand.space)
                }
                switch transport.status {
                case .playing(let name):
                    note("Running on \(name) at \(Int(transport.audio.sampleRate)) Hz.", warn: false)
                case .clockOnly(let why):
                    note("No audio right now: \(why). The clock still runs.", warn: true)
                case .lost(let why):
                    note(why, warn: true)
                }
            }
        }
        .disabled(model.locked)
        .onAppear { model.refreshDevices() }
    }

    private func danteCard(_ d: AudioDevice, routing: OutputRouting) -> some View {
        let converted = model.issues.filter { $0.kind == .deviceSampleRate }.count
        let latencyMs = transport.audio.device?.uid == d.uid ? transport.audio.latency * 1000 : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("DANTE")
                    .font(.manrope(10.5, .heavy)).tracking(1.2)
                    .foregroundStyle(Color(hex: 0x120D05))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Brand.gold))
                Text("\(d.name) · \(d.outputChannels) transmit channels · \(Int(d.sampleRate)) Hz")
                    .font(.manrope(12.5, .semibold)).foregroundStyle(Brand.ink)
                Spacer()
                let ready = routing.masterChannels == [1, 2] && routing.timecodeChannel == 3
                Button(ready ? "Set up for Dante ✓" : "Set up for Dante") {
                    model.updateRouting { $0.masterChannels = [1, 2]; $0.timecodeChannel = 3 }
                }
                .buttonStyle(QuietButtonStyle(prominent: !ready))
                .disabled(ready || d.outputChannels < 3)
                .help("Master on Dante channels 1–2, timecode on channel 3. Route them in Dante Controller.")
            }
            Text("In Dante Controller, route this Mac's transmit channels: 1–2 (master) to front of house and monitors, \(routing.timecodeChannel.map { "\($0)" } ?? "3") (timecode) to a Dante output that feeds the console's LTC input.")
                .font(.manrope(12)).foregroundStyle(Brand.steel).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Label(converted == 0 ? "Songs match \(Int(d.sampleRate)) Hz" : "\(converted) \(converted == 1 ? "song is" : "songs are") converted to \(Int(d.sampleRate)) Hz",
                      systemImage: converted == 0 ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(converted == 0 ? Brand.ok : Brand.warn)
                if let ms = latencyMs {
                    Label(String(format: "%.1f ms output latency, allowed for", ms), systemImage: "clock")
                        .foregroundStyle(Brand.space)
                        .help("The clock, MTC and Art-Net are offset by this so they match the timecode as it leaves Dante.")
                }
            }
            .font(.manrope(11.5, .medium))
            if converted > 0 {
                Text("Set the Dante network (or Dante Virtual Soundcard) to the songs' sample rate to avoid converting, or leave it: conversion is high quality.")
                    .font(.manrope(11.5)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.solid))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.gold.opacity(0.35), lineWidth: 1))
    }

    private func note(_ text: String, warn: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: warn ? Brand.warn : Brand.ok).padding(.top, 5)
            Text(text).font(.manrope(13)).foregroundStyle(Brand.steel).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.solid))
    }
}

// MARK: Setlists

struct SetlistEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: Setlist?

    var body: some View {
        SheetFrame(title: "Edit setlist", subtitle: "Drag to reorder. Untick a song to skip it tonight. Songs taken out of this setlist are listed at the bottom to add back.") {
            if let show = model.show, let binding = Binding($draft) {
                TextField("Setlist name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.manrope(14))
                List {
                    ForEach(binding.wrappedValue.songIDs, id: \.self) { id in
                        if let song = show.song(id: id) {
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { !(draft?.skipped.contains(id) ?? false) },
                                    set: { on in if on { draft?.skipped.remove(id) } else { draft?.skipped.insert(id) } }))
                                    .labelsHidden()
                                SongArt(song: song).frame(width: 26, height: 26)
                                Text(song.title).font(.manrope(13.5, .semibold))
                                    .foregroundStyle((draft?.skipped.contains(id) ?? false) ? Brand.graphite : Brand.ink)
                                Spacer()
                                Text(song.hasTimecode ? song.start.description : "No timecode").font(.manrope(12).monospacedDigit()).foregroundStyle(Brand.space)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onMove { from, to in draft?.songIDs.move(fromOffsets: from, toOffset: to) }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { draft?.songIDs[$0] }
                        ids.forEach { draft?.remove($0) }
                    }
                    let missing = show.songs.filter { !(draft?.songIDs.contains($0.id) ?? true) }
                    if !missing.isEmpty {
                        Section("Not in this setlist") {
                            ForEach(missing) { song in
                                HStack(spacing: 12) {
                                    SongArt(song: song).frame(width: 26, height: 26)
                                    Text(song.title).font(.manrope(13.5, .semibold)).foregroundStyle(Brand.space)
                                    Spacer()
                                    Button("Add") { draft?.add(song.id) }.buttonStyle(QuietButtonStyle())
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .frame(height: 360)
                HStack {
                    Button("Duplicate") { save(); if let d = draft { model.duplicateSetlist(d) }; draft = model.setlist }
                    Button("New from all songs") { save(); model.newSetlist(); draft = model.setlist }
                    Button("Delete") { if let d = draft { model.deleteSetlist(d) }; draft = model.setlist }
                        .disabled(show.setlists.count < 2)
                    Spacer()
                    Button("Save") { save() }.buttonStyle(QuietButtonStyle(prominent: true))
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .onAppear { draft = model.setlist }
        .onDisappear { save() }
    }

    private func save() {
        if let draft, draft != model.show?.setlists.first(where: { $0.id == draft.id }) { model.updateSetlist(draft) }
    }
}

// MARK: Go to timecode

struct GoToSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Go to timecode", subtitle: "Type a timecode. The song that plays there is cued at that frame.", width: 440) {
            TextField("03:01:12:00", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(18).monospacedDigit())
                .focused($focused)
                .onSubmit(go)
            if let message {
                Text(message).font(.manrope(13)).foregroundStyle(Brand.warn)
            }
            HStack {
                Spacer()
                Button("Go", action: go).buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let song = model.currentSong { text = model.timecode(for: song, at: model.transport.position()).description }
            focused = true
        }
    }

    private func go() {
        if let error = model.goTo(timecode: text) { message = error } else { dismiss() }
    }
}

// MARK: Markers

struct RenameMarkerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let marker: Marker
    let song: Song
    @State private var text = ""

    var body: some View {
        SheetFrame(title: "Rename marker", width: 420) {
            TextField("Marker name", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(15))
                .onSubmit(save)
            HStack {
                Button("Delete marker") { model.deleteMarker(marker, in: song); dismiss() }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Save", action: save).buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { text = marker.label }
    }

    private func save() {
        model.renameMarker(marker, in: song, to: text)
        dismiss()
    }
}
