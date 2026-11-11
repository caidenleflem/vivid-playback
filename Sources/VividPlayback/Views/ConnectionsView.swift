import SwiftUI
import AppKit
import QuartzCore
import PlaybackCore

// MARK: Building blocks

/// A solid card, the house style for settings: dark surface, hairline edge, a faint top sheen,
/// and a gold hairline across the top when it's live.
struct ConnectionCard<Content: View>: View {
    var active = false
    var minHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x15151A), Brand.solid], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(active ? Brand.gold.opacity(0.45) : .white.opacity(0.06), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if active {
                    LinearGradient(colors: [Brand.gold.opacity(0), Brand.gold.opacity(0.8), Brand.gold.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                        .padding(.horizontal, 30)
                }
            }
            .animation(.vivid(0.35), value: active)
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.manrope(20, .semibold)).foregroundStyle(Brand.ink)
            if let detail { Text(detail).font(.manrope(13)).foregroundStyle(Brand.space) }
        }
    }
}

/// A square icon well; gold when live.
struct IconWell: View {
    let symbol: String
    var active: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(active ? Color(hex: 0x120D05) : Brand.steel)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(active ? Brand.gold : .white.opacity(0.07)))
            .animation(.vivid(0.3), value: active)
    }
}

/// "● Sending  03:00:21:04" or "Idle", live.
struct LiveTimecodeLine: View {
    let timecode: Timecode?
    let live: Bool
    var idleText = "Idle"

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: live ? Brand.ok : Brand.graphite, pulsing: live)
            if live, let timecode {
                ClockText(timecode: timecode, size: 20, weight: .regular, color: Brand.gold)
            } else {
                Text(idleText).font(.manrope(13, .medium)).foregroundStyle(Brand.graphite)
            }
        }
        .frame(height: 24)
    }
}

/// A pill-shaped choice row (like a segmented control, in house style).
struct PillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { withAnimation(.vivid(0.3)) { selection = option } } label: {
                    Text(label(option))
                        .font(.manrope(12.5, .semibold))
                        .foregroundStyle(on ? Color(hex: 0x120D05) : Brand.steel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(on ? Brand.gold : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

/// Keeps single-key shortcuts (Space, L, arrows) out of the way while a field has focus.
struct TypingField: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { model.typingInField = $0 }
            .onDisappear { if focused { model.typingInField = false } }
    }
}

extension View {
    func typingField() -> some View { modifier(TypingField()) }
}

// MARK: The page

/// Which network port something uses: Automatic (macOS chooses) or one of this Mac's ports.
/// With a `target` address, says which port Automatic picks, and warns when the target isn't on
/// the chosen port's network.
struct NetworkPortPicker: View {
    @EnvironmentObject private var control: ControlCenter
    @Binding var selection: String?
    var target: String? = nil
    var prefix = "Network"

    var body: some View {
        let chosen = control.port(selection)
        let auto = target.flatMap { NetworkPort.port(for: $0, among: control.networkPorts) }
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Picker("", selection: $selection) {
                    Text(auto.map { "Automatic · \($0.label) now" } ?? "Automatic").tag(String?.none)
                    ForEach(control.networkPorts) { p in
                        Text("\(p.label) · \(p.address)").tag(Optional(p.name))
                    }
                    if let s = selection, chosen == nil {
                        Text("\(control.portLabel(s)) · not connected").tag(Optional(s))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network").font(.system(size: 11, weight: .semibold))
                    Text("\(prefix) · \(selection == nil ? "Automatic" : control.portLabel(selection))")
                        .font(.manrope(12.5, .semibold)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which of this Mac's network ports this uses. Automatic lets macOS choose, which can pick Wi-Fi.")
            if let s = selection, chosen == nil {
                Text("\(control.portLabel(s)) isn't connected.").font(.manrope(11.5)).foregroundStyle(Brand.warn)
            } else if let target, let why = NetworkPort.mismatch(host: target, port: chosen) {
                Text(why).font(.manrope(11.5)).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @EnvironmentObject private var control: ControlCenter

    var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        header
                        timecodeOut
                        consolesSection.id("consoles")
                        follow
                        remote
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 64)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                .onAppear {
                    guard let anchor = model.connectionsAnchor else { return }
                    model.connectionsAnchor = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
        .onAppear { control.refreshDevices(); control.refreshNetworkPorts() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connections").font(.manrope(34, .bold)).foregroundStyle(Brand.ink)
                Text("Where timecode goes, what the show follows, and what can drive it.")
                    .font(.manrope(14)).foregroundStyle(Brand.space)
            }
            Spacer()
            if let last = control.lastRemote, Date().timeIntervalSince(last.at) < 30 {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Brand.gold)
                    Text(last.text).lineLimit(1)
                }
                .font(.manrope(12, .medium))
                .foregroundStyle(Brand.steel)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.06)))
                .transition(.opacity)
            }
        }
    }

    // MARK: Timecode out

    private var timecodeOut: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Timecode out", detail: "All three carry the same timecode: the song's timecode file, as it plays.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], spacing: 16) {
                ltcTile
                mtcTile
                artNetTile
            }
        }
    }

    private func liveOut(_ enabled: Bool) -> (Timecode?, Bool) {
        let s = control.sender.status
        let live = enabled && (transport.isPlaying || transport.testing) && CACurrentMediaTime() - s.at < 0.3
        return (s.timecode, live)
    }

    private var ltcTile: some View {
        let routed = transport.timecodeRouted && transport.audio.isRunning
        let channel = model.show?.routing.timecodeChannel
        return ConnectionCard(active: routed, minHeight: 268) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconWell(symbol: "waveform", active: routed)
                    Spacer()
                    Button("Audio output…") { model.outputShown = true }.buttonStyle(QuietButtonStyle())
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("LTC").font(.manrope(17, .semibold)).foregroundStyle(Brand.ink)
                    Text(routed ? "\(transport.timecodeInterface?.name ?? transport.deviceName ?? "Audio") · \(transport.timecodeInterface?.outputLabel(channel ?? 0) ?? "Output \(channel ?? 0)")" : (transport.timecodeMissing ? "Timecode output not reachable · check Audio output" : "Choose a timecode output"))
                        .font(.manrope(12.5)).foregroundStyle(routed ? Brand.space : Brand.warn).lineLimit(1)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(transport.isPlaying || transport.testing))) { _ in
                    let now = transport.clock.now()
                    LiveTimecodeLine(timecode: now.timecode, live: routed && (transport.isPlaying || transport.testing) && now.timecode != nil)
                }
                ChannelMeter(label: "Level", channel: channel.map { $0 - 1 })
                Button {
                    transport.testing ? transport.stopTest() : transport.startTest()
                } label: {
                    Label(transport.testing ? "Stop test timecode" : "Send test timecode",
                          systemImage: transport.testing ? "stop.fill" : "dot.radiowaves.right")
                }
                .buttonStyle(QuietButtonStyle(prominent: transport.testing))
                .disabled(!routed || transport.isPlaying)
                .help("Sends timecode only (never the music) on every timecode output, for a line check.")
            }
        }
    }

    private var mtcTile: some View {
        let on = control.settings.mtcOut
        let dest = control.midiDestinations.first { $0.id == control.settings.mtcDestination }
        return ConnectionCard(active: on, minHeight: 268) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconWell(symbol: "pianokeys", active: on)
                    Spacer()
                    Toggle("", isOn: $control.settings.mtcOut).toggleStyle(.switch).tint(Brand.gold).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("MIDI timecode").font(.manrope(17, .semibold)).foregroundStyle(Brand.ink)
                    Text(dest.map { "\($0.name) and the Vivid Playback port" } ?? "The Vivid Playback MIDI port")
                        .font(.manrope(12.5)).foregroundStyle(Brand.space).lineLimit(2)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(transport.isPlaying || transport.testing) || !on)) { _ in
                    let (tc, live) = liveOut(on)
                    LiveTimecodeLine(timecode: tc, live: live, idleText: on ? "Ready" : "Off")
                }
                Menu {
                    Button("Vivid Playback port only") { control.settings.mtcDestination = nil }
                    if !control.midiDestinations.isEmpty { Divider() }
                    ForEach(control.midiDestinations) { d in
                        Button(d.name) { control.settings.mtcDestination = d.id }
                    }
                } label: {
                    Label(dest?.name ?? "Vivid Playback port only", systemImage: "cable.connector")
                        .font(.manrope(12.5, .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The Vivid Playback port always carries MTC for other apps. Also send it to an interface:")
            }
        }
    }

    @State private var customTarget = ""

    private var artNetTile: some View {
        let on = control.settings.artNetOut
        let target = control.settings.artNetTarget
        return ConnectionCard(active: on, minHeight: 268) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconWell(symbol: "network", active: on)
                    Spacer()
                    Toggle("", isOn: $control.settings.artNetOut).toggleStyle(.switch).tint(Brand.gold).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Art-Net timecode").font(.manrope(17, .semibold)).foregroundStyle(Brand.ink)
                    Text(target.hasSuffix(".255") ? "Broadcast to \(target)" : "To \(target)")
                        .font(.manrope(12.5)).foregroundStyle(control.sender.status.artNetError && on ? Brand.warn : Brand.space)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(transport.isPlaying || transport.testing) || !on)) { _ in
                    let (tc, live) = liveOut(on)
                    LiveTimecodeLine(timecode: tc, live: live, idleText: on ? "Ready" : "Off")
                }
                NetworkPortPicker(selection: $control.settings.artNetOutPort, target: target, prefix: "Out")
                HStack(spacing: 8) {
                    Menu {
                        if let b = control.port(control.settings.artNetOutPort)?.broadcast {
                            Button("This port's network · \(b)") { control.settings.artNetTarget = b }
                            Divider()
                        }
                        Button("Broadcast · 2.255.255.255") { control.settings.artNetTarget = "2.255.255.255" }
                        Button("Broadcast · 10.255.255.255") { control.settings.artNetTarget = "10.255.255.255" }
                        Button("Broadcast · 192.168.1.255") { control.settings.artNetTarget = "192.168.1.255" }
                        Button("Everything on the port · 255.255.255.255") { control.settings.artNetTarget = "255.255.255.255" }
                    } label: {
                        Label("Send to", systemImage: "antenna.radiowaves.left.and.right").font(.manrope(12.5, .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    TextField("Console IP", text: $customTarget)
                        .typingField()
                        .textFieldStyle(.roundedBorder)
                        .font(.manrope(12.5).monospacedDigit())
                        .frame(width: 130)
                        .onSubmit { if !customTarget.isEmpty { control.settings.artNetTarget = customTarget } }
                }
                if control.sender.status.artNetError && on {
                    Text("Art-Net isn't getting out. Check the network, and allow Vivid Playback in System Settings › Privacy & Security › Local Network.")
                        .font(.manrope(11.5)).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { customTarget = target.hasSuffix(".255") ? "" : target }
    }

    // MARK: Consoles (executor triggers)

    private func console(_ id: UUID) -> Binding<ConsoleTarget> {
        Binding(get: { control.settings.consoles.first { $0.id == id } ?? ConsoleTarget(id: id) },
                set: { new in
                    if let i = control.settings.consoles.firstIndex(where: { $0.id == id }) { control.settings.consoles[i] = new }
                })
    }

    private var consolesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Consoles",
                              detail: "Trigger lanes in the timeline fire executors on these over OSC, on time with the music.")
                Spacer()
                Button { model.labelsShown = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "tag").font(.system(size: 12, weight: .semibold))
                        Text("Import labels to console")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(control.settings.consoles.isEmpty || model.show == nil)
                .help("Name each lane's executor on the console after the lane")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if let last = control.lastTrigger, Date().timeIntervalSince(last.at) < 120 {
                    HStack(spacing: 8) {
                        StatusDot(color: last.ok ? Brand.ok : Brand.warn)
                        Text(last.text).lineLimit(1)
                    }
                    .font(.manrope(12, .medium))
                    .foregroundStyle(Brand.steel)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .help(last.ok ? "Sent." : "Couldn't send. Check the address, the network, and Local Network access in System Settings › Privacy & Security.")
                }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(control.settings.consoles) { c in consoleCard(c.id) }
                addConsoleCard
            }
            ConnectionCard {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("On the grandMA3").font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                        VStack(alignment: .leading, spacing: 6) {
                            step(1, "Menu › In & Out › OSC.")
                            step(2, "Add a line: this Mac's address, port 8000, prefix gma3.")
                            step(3, "Turn on Receive and Receive Command, and enable OSC.")
                            step(4, "Back here, Edit Lane › Fire now. The executor should go.")
                        }
                        Text("Record from the desk").font(.manrope(14, .semibold)).foregroundStyle(Brand.ink).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("★").font(.manrope(11, .bold)).foregroundStyle(Brand.gold)
                                    .frame(width: 18, height: 18).background(Circle().fill(Brand.gold.opacity(0.12)))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Best: the Vivid Recorder plugin. It watches the sequences on the fader page you're on and sends what each one does (Go+, Go-, Goto, Top, On, Off). OSC in must be on here, and the desk's OSC line needs Send on.")
                                        .font(.manrope(12.5)).foregroundStyle(Brand.steel).fixedSize(horizontal: false, vertical: true)
                                    Button("Save grandMA3 Plugin…") { model.saveDeskPlugin() }.buttonStyle(QuietButtonStyle())
                                }
                            }
                            step(1, "Timeline › Record desk (⇧⌘R), then play the song. It stays on that song.")
                            step(2, "Each change lands on the lane for its executor. A new executor gets a new lane.")
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("3").font(.manrope(11, .bold).monospacedDigit()).foregroundStyle(Brand.gold)
                                    .frame(width: 18, height: 18).background(Circle().fill(Brand.gold.opacity(0.12)))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("From the desk, either:").font(.manrope(12.5)).foregroundStyle(Brand.steel)
                                    Text("SendOSC 1 \"/vivid/exec,s,1.201\"")
                                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Brand.champagne)
                                        .textSelection(.enabled)
                                    Text("in a macro or a cue's command (OSC in must be on), or MIDI Show Control out to this Mac (MIDI, or the network on port \(control.settings.mscPort)).")
                                        .font(.manrope(12)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
                                    NetworkPortPicker(selection: $control.settings.mscInPort, prefix: "MIDI Show Control on")
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Fire early").font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                            Spacer()
                            Text("\(Int(control.settings.fireEarlyMs)) ms").font(.manrope(13, .semibold).monospacedDigit()).foregroundStyle(Brand.gold)
                        }
                        Slider(value: $control.settings.fireEarlyMs, in: 0...200, step: 5).tint(Brand.gold)
                        Text("Sends every trigger this much ahead of the music, to cover the network and the console's own delay.")
                            .font(.manrope(12)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 320)
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.manrope(11, .bold).monospacedDigit()).foregroundStyle(Brand.gold)
                .frame(width: 18, height: 18).background(Circle().fill(Brand.gold.opacity(0.12)))
            Text(text).font(.manrope(12.5)).foregroundStyle(Brand.steel)
        }
    }

    private func consoleCard(_ id: UUID) -> some View {
        let c = console(id)
        let on = c.wrappedValue.enabled && !c.wrappedValue.host.isEmpty
        let lanesUsing = model.allLanes.filter { $0.consoleIDs.isEmpty || $0.consoleIDs.contains(id) }.count
        return ConnectionCard(active: on) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    IconWell(symbol: "slider.vertical.3", active: on)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Console name", text: c.name)
                        .typingField()
                            .textFieldStyle(.plain)
                            .font(.manrope(17, .semibold))
                            .foregroundStyle(Brand.ink)
                        Text(c.wrappedValue.host.isEmpty ? "Needs an address" : (lanesUsing == 0 ? "No lanes send here" : "\(lanesUsing) lane\(lanesUsing == 1 ? "" : "s") in this show send here"))
                            .font(.manrope(12.5)).foregroundStyle(c.wrappedValue.host.isEmpty ? Brand.warn : Brand.space)
                    }
                    Spacer()
                    Toggle("", isOn: c.enabled).toggleStyle(.switch).tint(Brand.gold).labelsHidden()
                }
                HStack(spacing: 10) {
                    labelled("IP address") {
                        TextField("10.0.0.20", text: c.host)
                        .typingField()
                            .textFieldStyle(.roundedBorder).font(.manrope(13).monospacedDigit())
                    }
                    labelled("Port") {
                        TextField("8000", value: c.port, format: IntegerFormatStyle<UInt16>().grouping(.never))
                        .typingField()
                            .textFieldStyle(.roundedBorder).font(.manrope(13).monospacedDigit()).frame(width: 64)
                    }
                    labelled("Prefix") {
                        TextField("gma3", text: c.prefix)
                        .typingField()
                            .textFieldStyle(.roundedBorder).font(.manrope(13)).frame(width: 70)
                    }
                }
                NetworkPortPicker(selection: c.networkPort, target: c.wrappedValue.host.isEmpty ? nil : c.wrappedValue.host)
                HStack(spacing: 6) {
                    Text("Sends").font(.manrope(11.5, .semibold)).foregroundStyle(Brand.graphite)
                    Text("\(c.wrappedValue.prefix.isEmpty ? "" : "/" + c.wrappedValue.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))/cmd \"Go+ Page 1.201\"")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Brand.champagne).lineLimit(1)
                    Spacer()
                    Button {
                        control.settings.consoles.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.graphite)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this console")
                }
            }
        }
        .contextMenu {
            Button("Remove Console") { control.settings.consoles.removeAll { $0.id == id } }
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.manrope(10, .bold)).tracking(0.9).foregroundStyle(Brand.graphite)
            content()
        }
    }

    private var addConsoleCard: some View {
        Button {
            let n = control.settings.consoles.count
            withAnimation(.vivid(0.35)) {
                control.settings.consoles.append(ConsoleTarget(name: n == 0 ? "grandMA3" : "grandMA3 \(n + 1)"))
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.gold)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Brand.gold.opacity(0.12)))
                Text("Add a console").font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                Text("grandMA3 over OSC").font(.manrope(12)).foregroundStyle(Brand.space)
            }
            .frame(maxWidth: .infinity, minHeight: 186)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .foregroundStyle(.white.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Follow

    private var follow: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Follow timecode",
                          detail: "Let another machine lead: the song that timecode belongs to is cued and plays in step with it.")
            ConnectionCard(active: control.isFollowing) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        PillPicker(options: FollowSource.allCases, selection: $control.settings.follow) { $0.label }
                        switch control.settings.follow {
                        case .off:
                            Text("The app runs its own timecode.").font(.manrope(13)).foregroundStyle(Brand.space)
                        case .ltc:
                            HStack(spacing: 10) {
                                Picker("Input", selection: Binding(
                                    get: { control.settings.ltcInputUID ?? control.inputDevices.first?.uid ?? "" },
                                    set: { control.settings.ltcInputUID = $0 })) {
                                    ForEach(control.inputDevices) { d in Text(d.name).tag(d.uid) }
                                }
                                .frame(width: 240)
                                Stepper("Input \(control.settings.ltcInputChannel)",
                                        value: $control.settings.ltcInputChannel, in: 1...max(1, inputChannels))
                                    .font(.manrope(12.5, .semibold))
                            }
                        case .mtc:
                            Text("Listens on every MIDI input.").font(.manrope(13)).foregroundStyle(Brand.space)
                        case .artNet:
                            Text("Listens for Art-Net timecode on port 6454.").font(.manrope(13)).foregroundStyle(Brand.space)
                            NetworkPortPicker(selection: $control.settings.artNetInPort, prefix: "Listen on")
                        }
                        if let problem = control.followProblem {
                            Text(problem).font(.manrope(12)).foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !control.isFollowing)) { _ in
                            let fresh = CACurrentMediaTime() - control.incomingAt < 0.5
                            VStack(alignment: .trailing, spacing: 8) {
                                ClockText(timecode: control.isFollowing ? control.incoming : nil, size: 40, weight: .light,
                                          color: fresh ? Brand.gold : Brand.graphite)
                                HStack(spacing: 8) {
                                    StatusDot(color: !control.isFollowing ? Brand.graphite : (fresh ? Brand.ok : Brand.warn), pulsing: fresh)
                                    Text(control.followStatus).font(.manrope(13, .medium)).foregroundStyle(Brand.steel)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var inputChannels: Int {
        control.inputDevices.first { $0.uid == control.settings.ltcInputUID }?.inputChannels ?? control.inputDevices.first?.inputChannels ?? 2
    }

    // MARK: Remote

    @State private var portText = ""

    private var remote: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Remote control", detail: "Drive the show from the console, a Stream Deck or a footswitch. Playback controls still work in show mode.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                oscCard
                midiCard
            }
        }
    }

    private var oscCard: some View {
        let on = control.settings.oscIn
        return ConnectionCard(active: on) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconWell(symbol: "dot.radiowaves.left.and.right", active: on)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OSC").font(.manrope(17, .semibold)).foregroundStyle(Brand.ink)
                        Text(on ? control.oscStatus : "Off").font(.manrope(12.5)).foregroundStyle(Brand.space)
                    }
                    Spacer()
                    Toggle("", isOn: $control.settings.oscIn).toggleStyle(.switch).tint(Brand.gold).labelsHidden()
                }
                NetworkPortPicker(selection: $control.settings.oscInPort, prefix: "Listen on")
                HStack(spacing: 10) {
                    Text("Send to").font(.manrope(12, .semibold)).foregroundStyle(Brand.space)
                    ForEach(control.port(control.settings.oscInPort).map { [$0.address] } ?? Array(control.addresses.prefix(2)), id: \.self) { ip in
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string) } label: {
                            Text(ip).font(.manrope(12.5, .semibold).monospacedDigit()).foregroundStyle(Brand.ink)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy")
                    }
                    Text("port").font(.manrope(12, .semibold)).foregroundStyle(Brand.space)
                    TextField("8000", text: $portText)
                        .typingField()
                        .textFieldStyle(.roundedBorder).font(.manrope(12.5).monospacedDigit()).frame(width: 64)
                        .onSubmit { if let p = UInt16(portText), p > 1023 { control.settings.oscPort = p } }
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([("/vivid/go", "Play"), ("/vivid/stop", "Stop"), ("/vivid/next", "Next song"), ("/vivid/prev", "Previous song"),
                             ("/vivid/top", "Top of the song"), ("/vivid/song 12", "Cue song 12 (or a title)"),
                             ("/vivid/locate 01:00:00:00", "Go to a timecode"), ("/vivid/marker", "Add a marker")], id: \.0) { cmd in
                        HStack {
                            Text(cmd.0).font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.champagne)
                            Spacer()
                            Text(cmd.1).font(.manrope(12)).foregroundStyle(Brand.space)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
                if on { oscHeardBox }
            }
        }
        .onAppear { portText = String(control.settings.oscPort) }
    }

    /// Everything that arrived lately, and what the app made of it.
    private var oscHeardBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HEARD").font(.manrope(10, .bold)).tracking(0.9).foregroundStyle(Brand.graphite)
            if control.oscHeard.isEmpty {
                Text("Nothing has arrived on port \(control.settings.oscPort) yet. Send something from the desk and it shows here.")
                    .font(.manrope(12)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(control.oscHeard) { h in
                    HStack(spacing: 8) {
                        StatusDot(color: h.meaning == nil ? Brand.warn : Brand.ok)
                        Text(h.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Brand.champagne).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(h.meaning ?? "not a Vivid command").font(.manrope(11.5)).foregroundStyle(h.meaning == nil ? Brand.warn : Brand.space).lineLimit(1)
                        Text(h.from).font(.manrope(11).monospacedDigit()).foregroundStyle(Brand.graphite)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
    }

    private var midiCard: some View {
        let on = control.settings.midiRemote
        return ConnectionCard(active: on) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconWell(symbol: "slider.horizontal.3", active: on)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MIDI").font(.manrope(17, .semibold)).foregroundStyle(Brand.ink)
                        Text(on ? "Listening on every MIDI input" : "Off").font(.manrope(12.5)).foregroundStyle(Brand.space)
                    }
                    Spacer()
                    Toggle("", isOn: $control.settings.midiRemote).toggleStyle(.switch).tint(Brand.gold).labelsHidden()
                }
                Toggle(isOn: $control.settings.mmc) {
                    Text("MIDI Machine Control (play, stop, locate)").font(.manrope(12.5, .medium)).foregroundStyle(Brand.steel)
                }
                .toggleStyle(.checkbox)
                .disabled(!on)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(RemoteAction.allCases) { action in learnButton(action) }
                }
                .disabled(!on)
            }
        }
    }

    private func learnButton(_ action: RemoteAction) -> some View {
        let trigger = control.settings.midiMap[action.rawValue]
        let listening = control.learning == action
        return Button {
            control.learning = listening ? nil : action
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(listening ? Color(hex: 0x120D05) : Brand.gold)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(listening ? Brand.gold : Brand.gold.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label).font(.manrope(12.5, .semibold)).foregroundStyle(Brand.ink)
                    Text(listening ? "Press a button or pad…" : (trigger?.displayName ?? "Click to learn"))
                        .font(.manrope(11)).foregroundStyle(listening ? Brand.gold : Brand.space).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(listening ? 0.09 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.gold.opacity(listening ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if trigger != nil { Button("Forget \(action.label)") { control.settings.midiMap[action.rawValue] = nil } }
        }
        .help(listening ? "Press the button on your controller. Click again to cancel." : "Click, then press a button on your controller.")
    }
}
