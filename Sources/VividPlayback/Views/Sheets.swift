import SwiftUI
import AppKit
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
        let device = model.devices.first { $0.uid == routing.deviceUID }
            ?? model.devices.first { $0.uid == (transport.interfaces.first?.uid ?? transport.audio.device?.uid) }
        let channels = max(2, device?.outputChannels ?? transport.audio.channelCount)
        let split = routing.splitsInterfaces && routing.timecodeDeviceUID != device?.uid
        let tcDevice = split ? model.devices.first { $0.uid == routing.timecodeDeviceUID } : device
        let tcChannels = split ? max(1, tcDevice?.outputChannels ?? 2) : channels
        SheetFrame(title: "Audio output",
                   subtitle: "Where the master plays and where timecode goes out. It's saved with the show, and the timecode level never follows the master level.") {
            VStack(alignment: .leading, spacing: 14) {
                FormRow(label: "Master interface") {
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
                            Text("Outputs \(c)–\(c + 1) (stereo)\(device?.part(for: c).map { device?.isAggregate == true ? " · \($0.part.name)" : "" } ?? "")").tag(c)
                        }
                        ForEach(1...channels, id: \.self) { c in
                            Text("\(device?.outputLabel(c) ?? "Output \(c)") only (mono)").tag(-c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }
                FormRow(label: "Timecode interface") {
                    Picker("Timecode interface", selection: Binding(
                        get: { split ? (routing.timecodeDeviceUID ?? "") : "" },
                        set: { uid in
                            model.updateRouting { r in
                                if uid.isEmpty || uid == r.deviceUID {
                                    r.timecodeDeviceUID = nil
                                    if let c = r.timecodeChannel, r.masterChannels.contains(c) { r.timecodeChannel = nil }
                                } else {
                                    r.timecodeDeviceUID = uid
                                    let outputs = model.devices.first { $0.uid == uid }?.outputChannels ?? 1
                                    r.timecodeChannel = min(max(1, r.timecodeChannel ?? 1), max(1, outputs))
                                }
                            }
                        })) {
                        Text("Same as the master").tag("")
                        ForEach(model.devices.filter { $0.uid != device?.uid }) { d in
                            Text("\(d.name)\(d.isDante ? " · Dante" : "") · \(d.outputChannels) outputs · \(Int(d.sampleRate)) Hz").tag(d.uid)
                        }
                        if split, tcDevice == nil, let uid = routing.timecodeDeviceUID {
                            Text("The show's timecode interface (not connected)").tag(uid)
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
                        ForEach(1...tcChannels, id: \.self) { c in
                            let label = tcDevice?.outputLabel(c) ?? "Output \(c)"
                            Text(!split && routing.masterChannels.contains(c) ? "\(label) (used by the master)" : label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 340)
                }
                if let d = device, d.isAggregate, !split {
                    aggregateNote(d)
                }
                if let d = device, d.isDante, !split {
                    danteCard(d, routing: routing)
                }
                if transport.timecodeMissing {
                    note("Timecode is set to \(tcDevice?.outputLabel(routing.timecodeChannel ?? 0) ?? "an output") but the audio running now can't reach it, so no timecode is going out. Pick the interface and output again, or press the refresh button by the interface.", warn: true)
                }
                if split {
                    if let m = device, let t = tcDevice {
                        note("The master plays on \(m.name) and timecode on \(t.name), as one device: \(m.name) is the clock and \(t.name) is kept in step with it. For a perfect lock, clock both from the same word clock, or put both on Dante.", warn: false)
                        if m.sampleRate > 0, t.sampleRate > 0, m.sampleRate != t.sampleRate {
                            note("\(t.name) is set to \(Int(t.sampleRate)) Hz and \(m.name) to \(Int(m.sampleRate)) Hz. The app asks \(t.name) to run at \(Int(m.sampleRate)) Hz; if it won't, set both to the same rate in Audio MIDI Setup.", warn: true)
                        }
                    } else {
                        note("The show's timecode interface isn't connected, so no timecode is going out. Plug it in, or pick another.", warn: true)
                    }
                } else if let tc = routing.timecodeChannel, routing.masterChannels.contains(tc) {
                    note("Timecode can't share an output with the master. Pick another output, or put the master on one output (mono).", warn: true)
                } else if channels <= 2 && routing.masterChannels.count == 2 {
                    note("This interface has two outputs and the master uses both. For timecode, set the master to Output 1 only (mono) and timecode to Output 2, or pick another interface for timecode.", warn: true)
                }
                FormRow(label: "Timecode level") {
                    Slider(value: Binding(get: { routing.timecodeGainDB }, set: { v in model.updateRouting { $0.timecodeGainDB = v.rounded() } }),
                           in: -24...0)
                        .frame(width: 260)
                    Text("\(Int(routing.timecodeGainDB)) dB").font(.manrope(13).monospacedDigit()).foregroundStyle(Brand.ink).frame(width: 50, alignment: .trailing)
                }
                FormRow(label: "Master level") {
                    Slider(value: Binding(get: { routing.masterGainDB }, set: { v in model.updateRouting { $0.masterGainDB = v.rounded() } }),
                           in: -40...12)
                        .frame(width: 260)
                    Text("\(routing.masterGainDB > 0 ? "+" : "")\(Int(routing.masterGainDB)) dB").font(.manrope(13).monospacedDigit()).foregroundStyle(Brand.ink).frame(width: 50, alignment: .trailing)
                }
                if routing.masterGainDB > 0 {
                    Text("Above 0 dB a limiter on the master keeps it from clipping. Timecode is never touched.")
                        .font(.manrope(11.5)).foregroundStyle(Brand.space)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ChannelMeter(label: "Master", channel: transport.masterOutput)
                    if routing.masterChannels.count > 1 { ChannelMeter(label: "", channel: transport.masterRightOutput) }
                    ChannelMeter(label: "Timecode", channel: transport.timecodeOutput)
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
                    model.updateRouting { $0.masterChannels = [1, 2]; $0.timecodeChannel = 3; $0.timecodeDeviceUID = nil }
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

    /// An aggregate numbers its outputs straight across the interfaces inside it, so outputs 1–2
    /// are whichever interface is first in Audio MIDI Setup. Say which is which.
    @ViewBuilder private func aggregateNote(_ d: AudioDevice) -> some View {
        note("\(d.name) is an aggregate device: \(Self.ranges(of: d)). Make sure the master and timecode outputs are on the interfaces you mean. Or skip the aggregate: choose the master's interface above and the timecode interface below, and the app joins them for you.", warn: false)
        if d.partsDisagreeOnRate {
            note("The interfaces in \(d.name) run at different sample rates (\(Self.rates(of: d))). That can leave an aggregate silent. Set them the same in Audio MIDI Setup, or choose the interfaces here instead.", warn: true)
        }
    }

    /// "outputs 1–2 are MOTU M4, outputs 3–10 are RME".
    private static func ranges(of d: AudioDevice) -> String {
        var first = 1
        var out: [String] = []
        for p in d.parts {
            out.append(p.outputs == 1 ? "output \(first) is \(p.name)" : "outputs \(first)–\(first + p.outputs - 1) are \(p.name)")
            first += p.outputs
        }
        return out.joined(separator: ", ")
    }

    private static func rates(of d: AudioDevice) -> String {
        d.parts.map { "\($0.name) \(Int($0.sampleRate)) Hz" }.joined(separator: ", ")
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
    @State private var level: Double = 100

    private var lane: TriggerLane? { model.lanes.first { $0.id == marker.laneID } }
    private var hasValue: Bool { lane?.action == .fader || lane?.action == .custom }

    var body: some View {
        SheetFrame(title: lane == nil ? "Rename marker" : "Trigger", subtitle: lane.map { "On \($0.title), at \(marker.time.description)." }, width: 440) {
            TextField(lane == nil ? "Marker name" : "Trigger name", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(15))
                .onSubmit(save)
            if hasValue, let lane {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(lane.action == .fader ? "Fader level" : "Value for {value}")
                            .font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                        Spacer()
                        Text(lane.action == .fader ? "\(Int(level))%" : "\(Int(level))")
                            .font(.manrope(13, .semibold).monospacedDigit()).foregroundStyle(Brand.ink)
                    }
                    Slider(value: $level, in: 0...100, step: 1).tint(Brand.gold)
                }
            }
            HStack {
                Button(lane == nil ? "Delete marker" : "Delete trigger") { model.deleteMarker(marker, in: song); dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Save", action: save).buttonStyle(QuietButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            text = marker.label
            level = marker.value ?? 100
        }
    }

    private func save() {
        model.renameMarker(marker, in: song, to: text)
        if hasValue { model.setLevel(marker, in: song, to: level) }
        dismiss()
    }
}

/// One executor lane: what it fires, and on which consoles.
struct LaneEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var control: ControlCenter
    @Environment(\.dismiss) private var dismiss
    @State var lane: TriggerLane

    private var isNew: Bool { !model.lanes.contains { $0.id == lane.id } }
    private var consoles: [ConsoleTarget] { control.settings.consoles }

    private static let actions: [LaneAction] = [.goPlus, .goMinus, .top, .on, .off, .fader, .custom]
    private static func short(_ a: LaneAction) -> String {
        switch a {
        case .fader: return "Fader"
        case .custom: return "Custom"
        default: return a.label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 3).fill(Brand.lane(lane.color)).frame(width: 6, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "New trigger lane" : "Edit lane").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                    Text("Each trigger on this lane fires an executor on your grandMA3 over OSC.")
                        .font(.manrope(13)).foregroundStyle(Brand.steel)
                }
                Spacer()
            }

            field("Name") {
                TextField("\(lane.page).\(lane.executor) · \(lane.action.label)", text: $lane.name)
                    .textFieldStyle(.roundedBorder).font(.manrope(14))
            }

            field("Executor") {
                HStack(spacing: 10) {
                    numberBox("Page", value: $lane.page)
                    Text(".").font(.manrope(18, .semibold)).foregroundStyle(Brand.graphite)
                    numberBox("Exec", value: $lane.executor)
                    Text("Page \(lane.page), executor \(lane.executor)").font(.manrope(12)).foregroundStyle(Brand.graphite)
                        .padding(.leading, 6)
                }
            }

            field("Key") {
                KeyRecorder(key: $lane.key, others: model.lanes.filter { $0.id != lane.id })
            }

            field("Action") {
                VStack(alignment: .leading, spacing: 10) {
                    PillPicker(options: Self.actions, selection: $lane.action) { Self.short($0) }
                    switch lane.action {
                    case .fader:
                        Text("Each trigger sets the fader to its level. New triggers start at 100%; right-click one to change it.")
                            .font(.manrope(12)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
                    case .custom:
                        TextField("Go+ Exec {page}.{exec}", text: Binding(get: { lane.command ?? "" }, set: { lane.command = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                        Text("Any command line. {page} and {exec} are this lane's executor, {label} the trigger's name, {value} its value.")
                            .font(.manrope(12)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
                    default:
                        EmptyView()
                    }
                }
            }

            field("Consoles") {
                if consoles.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                        Text("No consoles yet.").font(.manrope(13)).foregroundStyle(Brand.steel)
                        Button("Set up in Connections…") {
                            model.saveLane(clean)
                            dismiss()
                            model.go(.connections)
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { lane.consoleIDs.isEmpty },
                                             set: { lane.consoleIDs = $0 ? [] : consoles.map(\.id) })) {
                            Text("Every console").font(.manrope(13, .medium)).foregroundStyle(Brand.ink)
                        }
                        .toggleStyle(.checkbox)
                        ForEach(consoles) { c in
                            Toggle(isOn: Binding(
                                get: { lane.consoleIDs.isEmpty || lane.consoleIDs.contains(c.id) },
                                set: { on in
                                    var ids = lane.consoleIDs.isEmpty ? consoles.map(\.id) : lane.consoleIDs
                                    if on { if !ids.contains(c.id) { ids.append(c.id) } } else { ids.removeAll { $0 == c.id } }
                                    lane.consoleIDs = Set(ids) == Set(consoles.map(\.id)) ? [] : ids
                                })) {
                                HStack(spacing: 8) {
                                    Text(c.name.isEmpty ? "Console" : c.name).font(.manrope(13, .medium)).foregroundStyle(Brand.ink)
                                    Text(c.host.isEmpty ? "no address" : "\(c.host):\(c.port)")
                                        .font(.manrope(12).monospacedDigit()).foregroundStyle(c.host.isEmpty ? Brand.warn : Brand.graphite)
                                    if !c.enabled { Text("off").font(.manrope(11, .semibold)).foregroundStyle(Brand.warn) }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(lane.consoleIDs.isEmpty)
                        }
                    }
                }
            }

            field("Colour") {
                HStack(spacing: 10) {
                    ForEach(0..<Brand.laneColors.count, id: \.self) { i in
                        Button { lane.color = i } label: {
                            Circle().fill(Brand.lane(i)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Brand.ink, lineWidth: lane.color == i ? 2 : 0).padding(-4))
                                .padding(4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(i + 1)")
                    }
                }
            }

            preview

            HStack(spacing: 10) {
                if !isNew {
                    Button("Delete lane") { model.deleteLane(lane); dismiss() }.buttonStyle(QuietButtonStyle())
                }
                Button { model.fireLane(clean) } label: { Label("Fire now", systemImage: "bolt.fill") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(clean.targets(in: consoles).isEmpty)
                    .help("Sends this lane's command once, to check the console responds.")
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add lane" : "Save") { model.saveLane(clean); dismiss() }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Brand.phantom)
        .preferredColorScheme(.dark)
        .tint(Brand.gold)
    }

    /// The lane as it will be saved: numbers in range, an empty command dropped.
    private var clean: TriggerLane {
        var l = lane
        l.page = max(1, min(9999, l.page))
        l.executor = max(1, min(9999, l.executor))
        l.name = l.name.trimmingCharacters(in: .whitespaces)
        if l.action != .custom { l.command = nil }
        return l
    }

    /// Exactly what goes out on the wire, per console.
    private var preview: some View {
        let l = clean
        let sample = Marker(time: Timecode(frameCount: 0, rate: .fps30), label: "Trigger", laneID: l.id, value: 100)
        let targets = l.targets(in: consoles)
        let shown = targets.isEmpty ? [ConsoleTarget(name: "Console", host: "")] : targets
        return VStack(alignment: .leading, spacing: 6) {
            Text("SENDS").font(.manrope(10.5, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
            ForEach(shown) { c in
                ForEach(Array(l.messages(for: sample, console: c).enumerated()), id: \.offset) { _, msg in
                    HStack(spacing: 10) {
                        Text(c.host.isEmpty ? "—" : "\(c.host):\(c.port)")
                            .foregroundStyle(Brand.graphite)
                            .frame(width: 140, alignment: .leading)
                        Text(msg.address).foregroundStyle(Brand.champagne)
                        Text(msg.arguments.map(Self.describe).joined(separator: " ")).foregroundStyle(Brand.ink)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                }
            }
            if l.messages(for: sample, console: shown[0]).isEmpty {
                Text("Type a command to send.").font(.manrope(12)).foregroundStyle(Brand.warn)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))
    }

    private static func describe(_ v: OSCValue) -> String {
        switch v {
        case .int(let i): return "\(i)"
        case .float(let f): return String(format: "%.2f", f)
        case .string(let s): return "\"\(s)\""
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel).frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func numberBox(_ placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(.manrope(14, .semibold).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 70)
    }
}

/// Click, then press a key: that key drops a trigger on the lane at the playhead.
struct KeyRecorder: View {
    @Binding var key: String?
    let others: [TriggerLane]
    @State private var listening = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 10) {
            Button { listening ? stop() : start() } label: {
                HStack(spacing: 8) {
                    Text(listening ? "Press a key…" : (key?.uppercased() ?? "None"))
                        .font(.manrope(listening ? 13 : 15, .semibold).monospacedDigit())
                        .foregroundStyle(listening ? Brand.gold : (key == nil ? Brand.graphite : Brand.ink))
                        .frame(minWidth: 90)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(listening ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.gold.opacity(listening ? 0.8 : 0), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click, then press the key that drops triggers on this lane. Esc cancels, Delete clears it.")
            if key != nil && !listening {
                Button("Clear") { key = nil; problem = nil }.buttonStyle(QuietButtonStyle())
            }
            VStack(alignment: .leading, spacing: 2) {
                if let problem {
                    Text(problem).foregroundStyle(Brand.warn)
                } else if let key, let other = others.first(where: { $0.key == key }) {
                    Text("Also on \(other.title). Saving moves it here.").foregroundStyle(Brand.warn)
                } else {
                    Text("Press it while the song plays to drop a trigger here.").foregroundStyle(Brand.graphite)
                }
            }
            .font(.manrope(12))
            .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()                                   // Esc
            case 51, 117: key = nil; stop()                   // Delete
            default:
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard mods.isEmpty, let chars = event.charactersIgnoringModifiers else { return nil }
                if let k = TriggerLane.normalizedKey(chars) {
                    key = k
                    stop()
                } else {
                    problem = TriggerLane.reservedKeys.contains(chars.lowercased())
                        ? "Space, M, L and C are already used in the timeline. Pick another."
                        : "That key can't be used. Pick a letter, number or symbol."
                }
            }
            return nil
        }
    }

    private func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Import Labels to Console: names each executor's sequence after the album's lanes. Shows
/// every command first; nothing is sent until you press Send.
struct LabelsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var control: ControlCenter
    @Environment(\.dismiss) private var dismiss
    @State private var labels: [ExecutorLabel] = []
    @State private var skipped: Set<String> = []
    @State private var sending = false
    @State private var result: (sent: Int, failed: Int)?
    @State private var showCommand = false

    private var consoles: [ConsoleTarget] { control.settings.consoles }
    private var chosen: [ExecutorLabel] { labels.filter { !skipped.contains($0.id) && !$0.targets(in: consoles).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import labels to console").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                    Text("Names the sequence on each lane's executor after the lane, for every song in \(model.setlist?.name ?? "this album").")
                        .font(.manrope(13)).foregroundStyle(Brand.steel).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if labels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.graphite)
                    Text("No named lanes in this album").font(.manrope(15, .semibold)).foregroundStyle(Brand.ink)
                    Text("Give lanes a name in Edit Lane, then come back.").font(.manrope(13)).foregroundStyle(Brand.space)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($labels) { $label in row($label) }
                    }
                }
                .frame(maxHeight: 340)

                DisclosureGroup(isExpanded: $showCommand) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(ExecutorLabel.defaultTemplate, text: $control.settings.labelTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                        HStack {
                            Text("{page}, {exec} and {name} are filled in for each executor.")
                                .font(.manrope(11.5)).foregroundStyle(Brand.space)
                            Spacer()
                            if control.settings.labelTemplate != ExecutorLabel.defaultTemplate {
                                Button("Reset") { control.settings.labelTemplate = ExecutorLabel.defaultTemplate }
                                    .buttonStyle(QuietButtonStyle())
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Text("Command").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.steel)
                        if let first = chosen.first {
                            Text(first.command(template: control.settings.labelTemplate))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.champagne).lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                if let result {
                    StatusDot(color: result.failed == 0 ? Brand.ok : Brand.warn)
                    Text(result.failed == 0 ? "Sent. Check the executor names on the console."
                                            : "\(result.failed) couldn't leave this Mac. Check the network.")
                        .font(.manrope(12.5)).foregroundStyle(Brand.steel)
                } else if consoles.filter({ $0.enabled && !$0.host.isEmpty }).isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                    Text("No console to send to. Add one in Connections › Consoles.").font(.manrope(12.5)).foregroundStyle(Brand.steel)
                }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send \(chosen.count) label\(chosen.count == 1 ? "" : "s")") {
                    sending = true
                    model.sendLabels(chosen) { sent, failed in
                        sending = false
                        result = (sent, failed)
                    }
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || sending)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(Brand.phantom)
        .preferredColorScheme(.dark)
        .tint(Brand.gold)
        .onAppear { labels = ExecutorLabel.plan(lanes: model.albumLanes) }
    }

    private func row(_ label: Binding<ExecutorLabel>) -> some View {
        let l = label.wrappedValue
        let targets = l.targets(in: consoles)
        let on = !skipped.contains(l.id)
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { on }, set: { if $0 { skipped.remove(l.id) } else { skipped.insert(l.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(l.id).font(.manrope(13, .bold).monospacedDigit()).foregroundStyle(Brand.gold).frame(width: 64, alignment: .leading)
            TextField("Name", text: label.name)
                .textFieldStyle(.roundedBorder)
                .font(.manrope(13.5))
            if l.hasConflict {
                Menu {
                    Section("Lanes on \(l.id) are called") {
                        ForEach(l.names, id: \.self) { n in Button(n) { label.wrappedValue.name = n } }
                    }
                } label: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.warn)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Songs name this executor differently: \(l.names.joined(separator: ", ")). Pick one.")
            }
            Text(targets.isEmpty ? "No console" : targets.map(\.name).joined(separator: ", "))
                .font(.manrope(12)).foregroundStyle(targets.isEmpty ? Brand.warn : Brand.space)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(on ? 0.05 : 0.02)))
        .opacity(on ? 1 : 0.5)
    }
}
