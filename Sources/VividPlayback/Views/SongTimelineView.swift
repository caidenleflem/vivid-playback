import SwiftUI
import QuartzCore
import PlaybackCore

/// The expanded view of one song: waveform, timecode lane, and markers and executor lanes once there are any.
struct SongTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    let morph: Namespace.ID
    @State private var showIssues = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
            if let song = model.currentSong {
                header(song)
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                TimelinePanel(song: song)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64, height: 1)  // room for the window buttons
            TransportButtons()
            LiveClock(size: 30, weight: .light)
                .matchedGeometryEffect(id: "clock", in: morph)
            if let song = model.currentSong { Chip(song.rate.displayName) }
            if transport.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.toggleLoop() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "repeat").foregroundStyle(transport.loop != nil ? Brand.gold : Brand.ink)
                    Text(transport.loop != nil ? "Looping" : "Loop")
                    KeyCap(key: "L")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help("Loop between the markers either side of the playhead, or the whole song")
            Button { model.addMarker() } label: {
                HStack(spacing: 8) { Image(systemName: "plus"); Text("Marker"); KeyCap(key: "M") }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.locked)
            .help("Drop a marker at the playhead")
            Button { model.addTrigger() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.lanes.isEmpty ? "rectangle.stack.badge.plus" : "bolt.fill")
                        .foregroundStyle(model.selectedLane.map { Brand.lane($0.color) } ?? Brand.ink)
                    Text(model.lanes.isEmpty ? "Trigger lane" : "Trigger")
                    KeyCap(key: "C")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.locked)
            .help(model.lanes.isEmpty ? "Add a lane that fires an MA3 executor over OSC"
                                      : "Drop a trigger at the playhead on \(model.selectedLane?.title ?? "the chosen lane")")
            Button("Done") { model.go(.library) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .glass(cornerRadius: 16, alpha: 0.76)
        .matchedGeometryEffect(id: "bar", in: morph)
    }

    private func header(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 28) {
            SongArt(song: song, cornerRadius: 12)
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
                .matchedGeometryEffect(id: "art", in: morph)
            VStack(alignment: .leading, spacing: 8) {
                let q = model.queue
                let index = (q.firstIndex { $0.id == song.id } ?? 0) + 1
                Text("SONG \(index) OF \(q.count)").font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                Text(song.title)
                    .font(.manrope(44, .semibold))
                    .foregroundStyle(Brand.ink)
                    .matchedGeometryEffect(id: "title", in: morph)
                HStack(spacing: 8) {
                    if song.hasTimecode {
                        Chip(song.end.map { "\(song.start) → \($0)" } ?? song.start.description).monospacedDigit()
                        Chip(song.rate.displayName)
                    } else {
                        Chip("No timecode · plays audio only") { StatusDot(color: Brand.graphite) }
                    }
                    if song.fileOffset != 0 { Chip(String(format: "Offset %+.3f s", song.fileOffset)) }
                    let issues = model.issues(for: song).filter { $0.kind != .missingTimecode }
                    switch transport.source {
                    case .generated:
                        Chip("Timecode generated from the sheet") { StatusDot(color: Brand.gold) }
                    case .file(let name):
                        if transport.trackFound, let first = transport.firstFileTimecode {
                            Chip("From \(name) · \(first)") { StatusDot(color: Brand.ok) }
                                .help("Timecode comes from this file. Its first frame reads \(first.description).")
                        } else if !transport.isLoading {
                            Chip("No timecode found in \(name)") { StatusDot(color: Color(hex: 0xE5675A)) }
                        }
                    case .unreadable(let why):
                        Chip("Timecode file can't be read") { StatusDot(color: Color(hex: 0xE5675A)) }.help(why)
                    case .none:
                        EmptyView()
                    }
                    // One button that never leaves the screen while its popover is open (removing a
                    // popover's anchor can crash on macOS); only its label changes.
                    let hidden = model.hiddenIssues(for: song)
                    if !issues.isEmpty || !hidden.isEmpty || showIssues || (!transport.timecodeGenerated && song.hasTimecode) {
                        Button { if !issues.isEmpty || !hidden.isEmpty { showIssues = true } } label: {
                            if issues.isEmpty {
                                Chip(song.hasTimecode && !transport.timecodeGenerated ? "Timecode verified" : "Nothing to check") { StatusDot(color: Brand.ok) }
                            } else {
                                Chip(issues.count == 1 ? issues[0].title : "\(issues.count) things to check") { StatusDot(color: Brand.warn) }
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showIssues, arrowEdge: .bottom) { SongIssuesPopover(song: song).environmentObject(model) }
                    }
                }
                HStack(spacing: 22) {
                    fileMenu("Master", song.masterPath, role: .master, song: song)
                    fileMenu("Timecode", song.timecodePath, role: .timecode, song: song)
                }
                .font(.manrope(12.5))
            }
            Spacer(minLength: 0)
        }
    }

    /// "Master  03 Night Drive.wav": click the name to choose or replace the file; right-click to remove it.
    private func fileMenu(_ label: String, _ path: String?, role: AudioRole, song: Song) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.semibold).foregroundStyle(Brand.steel)
            Button { model.choose(role, for: song) } label: {
                Text(path.map { ($0 as NSString).lastPathComponent } ?? "Choose a file…")
                    .foregroundStyle(path == nil ? Brand.gold : Brand.space)
                    .underline(path == nil, color: Brand.gold.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(model.locked)
            .contextMenu {
                Button(path == nil ? "Choose \(label) File…" : "Replace \(label) File…") { model.choose(role, for: song) }
                if path != nil { Button("Remove \(label) File") { model.removeFile(role, from: song) } }
            }
            .help("Click to choose or replace this song's \(label.lowercased()) file. Right-click to remove it. You can also drop a file on the song in the library.")
        }
    }
}

struct TimelinePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @EnvironmentObject private var control: ControlCenter
    let song: Song
    @State private var reveal: CGFloat = 0
    /// A trigger being dragged along its lane, and how far.
    @State private var dragging: (id: UUID, dx: CGFloat)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lanes: [TriggerLane] { model.lanes }
    private var plainMarkers: [Marker] { song.markers.filter { $0.laneID == nil } }
    /// Lane names need more room than "MASTER".
    private var labelWidth: CGFloat { lanes.isEmpty ? 92 : 156 }

    var body: some View {
        let length = max(song.length ?? 0, 0.001)
        let plain = plainMarkers
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let trackWidth = geo.size.width - labelWidth - 12
                // Rows: ruler 22, waveform (fills what's left), timecode 26, markers 44, then one
                // row per executor lane and an "Add lane" row. Gaps 10 (6 between lanes).
                let n = CGFloat(lanes.count)
                let markerSpace: CGFloat = plain.isEmpty ? 0 : 54
                let base: CGFloat = 22 + 10 + 10 + 26 + markerSpace + 4
                let laneChrome: CGFloat = lanes.isEmpty ? 0 : 10 + 6 * max(0, n - 1) + 6 + 26
                let laneHeight: CGFloat = lanes.isEmpty ? 0 : min(34, max(22, (geo.size.height - base - laneChrome - 80) / max(n, 1)))
                let laneSpace = lanes.isEmpty ? 0 : laneChrome + n * laneHeight
                let waveHeight = max(80, geo.size.height - base - laneSpace)
                let lanesHeight = 22 + 10 + waveHeight + 10 + 26 + markerSpace + laneSpace
                let scrubLimit = 22 + 10 + waveHeight + 10 + 26
                let linesBottom = lanesHeight - (lanes.isEmpty ? 0 : 32)
                SongProgress { position, _ in
                    let p = CGFloat(min(1, max(0, position / length)))
                    let playheadX = trackWidth * p
                    VStack(alignment: .leading, spacing: 10) {
                        ruler(width: trackWidth, length: length)
                        lane("Master") {
                            WaveformView(peaks: model.waveforms[song.id] ?? [], progress: p)
                                .frame(height: waveHeight)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.02)))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        lane("Timecode") { timecodeLane }
                        if !plain.isEmpty {
                            lane("Markers") { markerLane(plain, width: trackWidth, length: length) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if !lanes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(lanes) { l in
                                    triggerLane(l, height: laneHeight, width: trackWidth, length: length)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                                addLaneRow
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .mask(alignment: .leading) {
                        // The lanes draw in from the playhead outward when the timeline opens.
                        let span = max(playheadX, trackWidth - playheadX) * reveal
                        HStack(spacing: 0) {
                            Rectangle().frame(width: labelWidth + 12)
                            Rectangle().frame(width: max(0, 2 * span)).offset(x: playheadX - span)
                            Spacer(minLength: 0)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let loop = transport.loop {
                            let x0 = trackWidth * CGFloat(max(0, loop.lowerBound) / length)
                            let x1 = trackWidth * CGFloat(min(length, loop.upperBound) / length)
                            Rectangle().fill(Brand.gold.opacity(0.08))
                                .overlay(alignment: .top) { Rectangle().fill(Brand.gold.opacity(0.6)).frame(height: 2) }
                                .frame(width: max(2, x1 - x0), height: linesBottom - 24)
                                .offset(x: labelWidth + 12 + x0, y: 24)
                                .allowsHitTesting(false)
                        }
                        markerLines(width: trackWidth, length: length, height: linesBottom - 30)
                            .offset(x: labelWidth + 12)
                        playhead(position: position, height: linesBottom - 18)
                            .offset(x: labelWidth + 12 + playheadX - 1)
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
                        // Scrub on the waveform and timecode lanes; the marker and executor lanes keep their clicks.
                        let x = value.location.x - labelWidth - 12
                        guard x >= 0, trackWidth > 0, value.startLocation.y < scrubLimit else { return }
                        transport.locate(Double(x / trackWidth) * length)
                    })
                }
            }
            if plain.isEmpty && lanes.isEmpty {
                HStack(spacing: 8) {
                    KeyCap(key: "M")
                    Text("drops a marker at the playhead.")
                    KeyCap(key: "C").padding(.leading, 10)
                    Text("starts a trigger lane that fires an MA3 executor. Songs without either stay plain playback.")
                }
                .font(.manrope(12.5))
                .foregroundStyle(Brand.graphite)
                .padding(.leading, labelWidth + 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .solidPanel()
        .animation(.vivid(0.4), value: lanes)
        .onAppear {
            model.loadWaveform(for: song)
            if reduceMotion { reveal = 1 } else { withAnimation(.vivid(0.7).delay(0.12)) { reveal = 1 } }
        }
    }

    private func lane<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title.uppercased()).font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private func ruler(width: CGFloat, length: Double) -> some View {
        // A label every 15, 30 or 60 seconds, whichever keeps them about 90 pt apart.
        let step = [15.0, 30, 60, 120].first { width * CGFloat($0 / length) >= 90 } ?? 120
        let marks = Array(stride(from: 0.0, through: length, by: step))
        return HStack(spacing: 12) {
            Color.clear.frame(width: labelWidth, height: 1)
            ZStack(alignment: .topLeading) {
                ForEach(marks, id: \.self) { t in
                    Text(String(song.start.adding(frames: Int(t * song.rate.framesPerSecond)).description.prefix(8)))
                        .font(.manrope(11).monospacedDigit())
                        .foregroundStyle(Brand.graphite)
                        .fixedSize()
                        .position(x: width * CGFloat(t / length), y: 10)
                }
            }
            .frame(width: width, height: 22)
        }
    }

    private var timecodeLane: some View {
        HStack {
            Text(song.hasTimecode ? song.start.description : "No timecode for this song")
            Spacer()
            Text(song.hasTimecode ? (song.end?.description ?? "") : "")
        }
        .font(.manrope(10.5, .semibold).monospacedDigit())
        .foregroundStyle(Brand.ink)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            Canvas { ctx, size in
                var x: CGFloat = 0
                var i = 0
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(Brand.space.opacity(i % 2 == 0 ? 0.55 : 0.35)))
                    x += i % 2 == 0 ? 3 : 4
                    i += 1
                }
            }
            .opacity(0.7)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        )
    }

    private func xPos(of marker: Marker, width: CGFloat, length: Double) -> CGFloat {
        width * CGFloat(Double(marker.time.frames(since: song.start)) / song.rate.framesPerSecond / length)
    }

    private func markerLane(_ markers: [Marker], width: CGFloat, length: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Brand.gold.opacity(0.05))
            ForEach(markers) { marker in
                let x = xPos(of: marker, width: width, length: length)
                let flip = x > width * 0.85
                HStack(spacing: 7) {
                    if flip { markerChip(marker) }
                    Capsule().fill(Brand.gold).frame(width: 2, height: 36)
                    if !flip { markerChip(marker) }
                }
                .fixedSize()
                .alignmentGuide(.leading) { d in flip ? d.width : 0 }
                .offset(x: x - (flip ? 0 : 1), y: 4)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(width: width, height: 44)
    }

    private func markerLabel(_ text: String) -> some View {
        Text(text).font(.manrope(11.5, .semibold)).foregroundStyle(Brand.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Brand.phantom))
    }

    private func markerChip(_ marker: Marker) -> some View {
        markerLabel(marker.label)
            .contentShape(Rectangle())
            .onTapGesture { transport.locate(model.seconds(of: marker, in: song)) }
            .contextMenu {
                Button("Go to Marker") { transport.locate(model.seconds(of: marker, in: song)) }
                Button("Rename…") { model.markerEdit = MarkerEdit(marker: marker, song: song) }.disabled(model.locked)
                Button("Delete") { model.deleteMarker(marker, in: song) }.disabled(model.locked)
            }
            .help("Click to go here. Right-click to rename or delete.")
    }

    // MARK: Executor lanes

    private func isSelected(_ lane: TriggerLane) -> Bool { model.selectedLane?.id == lane.id }

    /// "MA3 FOH", "All consoles", or what's missing.
    private func targetText(_ lane: TriggerLane) -> (String, Bool) {
        let consoles = control.settings.consoles
        let targets = lane.targets(in: consoles)
        if consoles.isEmpty { return ("No console set up", false) }
        if targets.isEmpty { return (lane.consoleIDs.isEmpty ? "No console switched on" : "Its console is off", false) }
        if lane.consoleIDs.isEmpty && consoles.count > 1 { return ("All consoles", true) }
        return (targets.map(\.name).joined(separator: ", "), true)
    }

    private func triggerLane(_ lane: TriggerLane, height: CGFloat, width: CGFloat, length: Double) -> some View {
        let color = Brand.lane(lane.color)
        let selected = isSelected(lane)
        let triggers = song.markers.filter { $0.laneID == lane.id }
        return HStack(spacing: 12) {
            laneLabel(lane, color: color, selected: selected, height: height)
                .frame(width: labelWidth, height: height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(selected ? 0.10 : 0.045))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(color.opacity(selected ? 0.5 : 0), lineWidth: 1))
                ForEach(triggers) { m in
                    triggerTick(m, lane: lane, color: color, height: height, width: width, length: length)
                }
            }
            .frame(width: width, height: height)
            .opacity(lane.muted ? 0.4 : 1)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                model.addTrigger(on: lane, at: Double(value.location.x / max(width, 1)) * length)
            })
            .simultaneousGesture(TapGesture().onEnded { model.selectedLaneID = lane.id })
            .help("Double-click to drop a trigger here. Press C to drop one at the playhead.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.title) lane, \(triggers.count) triggers")
    }

    private func laneLabel(_ lane: TriggerLane, color: Color, selected: Bool, height: CGFloat) -> some View {
        let (target, reachable) = targetText(lane)
        let hasName = !lane.name.trimmingCharacters(in: .whitespaces).isEmpty
        let detail = hasName ? "\(lane.page).\(lane.executor) · \(lane.action == .custom ? "Custom" : lane.action.label) · \(target)" : target
        return Button { model.selectedLaneID = lane.id } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: max(10, height - 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.title)
                        .font(.manrope(11.5, .semibold))
                        .foregroundStyle(lane.muted ? Brand.graphite : Brand.ink)
                        .lineLimit(1)
                    if height >= 28 {
                        Text(detail)
                            .font(.manrope(10, .medium))
                            .foregroundStyle(reachable ? Brand.graphite : Brand.warn)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if lane.muted {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.graphite)
                } else if !reachable {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Brand.warn)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(selected ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !model.locked { model.laneEdit = lane } })
        .contextMenu {
            Button("Edit Lane…") { model.laneEdit = lane }.disabled(model.locked)
            Button("Fire Now") { model.fireLane(lane) }
            Divider()
            Button(lane.muted ? "Unmute" : "Mute") { model.toggleMute(lane) }.disabled(model.locked)
            Button("Delete Lane") { model.deleteLane(lane) }.disabled(model.locked)
        }
        .help("\(lane.commandLine() ?? "Fader \(lane.page).\(lane.executor)") → \(target). Click to choose this lane for C; double-click to edit.")
    }

    private func triggerText(_ m: Marker, lane: TriggerLane) -> String {
        guard lane.action == .fader, let v = m.value else { return m.label }
        return m.label == "Level" ? "\(Int(v))%" : "\(m.label) · \(Int(v))%"
    }

    private func triggerTick(_ m: Marker, lane: TriggerLane, color: Color, height: CGFloat, width: CGFloat, length: Double) -> some View {
        let fired = control.firedAt[m.id].map { Date().timeIntervalSince($0) < 0.35 } ?? false
        let dx = dragging?.id == m.id ? dragging?.dx ?? 0 : 0
        let x = min(width, max(0, xPos(of: m, width: width, length: length) + dx))
        let flip = x > width * 0.88
        let chip = Text(triggerText(m, lane: lane))
            .font(.manrope(10.5, .semibold))
            .foregroundStyle(fired ? Color(hex: 0x120D05) : Brand.ink)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fired ? Brand.gold : Brand.phantom))
        return HStack(spacing: 5) {
            if flip && height >= 24 { chip }
            Capsule().fill(fired ? Brand.gold : color).frame(width: fired ? 3 : 2, height: max(8, height - 8))
            if !flip && height >= 24 { chip }
        }
        .fixedSize()
        .shadow(color: fired ? Brand.gold.opacity(0.6) : .clear, radius: 6)
        .alignmentGuide(.leading) { d in flip ? d.width : 0 }
        .offset(x: x - (flip ? 0 : 1), y: 4)
        .animation(.easeOut(duration: 0.25), value: fired)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedLaneID = lane.id
            transport.locate(model.seconds(of: m, in: song))
        }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in if !model.locked { dragging = (m.id, v.translation.width) } }
            .onEnded { v in
                dragging = nil
                guard !model.locked, width > 0 else { return }
                model.move(m, in: song, to: model.seconds(of: m, in: song) + Double(v.translation.width / width) * length)
            })
        .contextMenu {
            Button("Go to Trigger") { transport.locate(model.seconds(of: m, in: song)) }
            Button("Fire Now") { model.fire(m) }
            Divider()
            Button("Rename…") { model.markerEdit = MarkerEdit(marker: m, song: song) }.disabled(model.locked)
            if lane.action == .fader || lane.action == .custom {
                Menu(lane.action == .fader ? "Level" : "Value") {
                    ForEach([100.0, 75, 50, 25, 0], id: \.self) { v in
                        Button(lane.action == .fader ? "\(Int(v))%" : "\(Int(v))") { model.setLevel(m, in: song, to: v) }
                    }
                    Divider()
                    Button("Other…") { model.markerEdit = MarkerEdit(marker: m, song: song) }
                }
                .disabled(model.locked)
            }
            Button("Move to Playhead") { model.moveToPlayhead(m, in: song) }.disabled(model.locked)
            Button("One Frame Earlier") { model.nudge(m, in: song, frames: -1) }.disabled(model.locked)
            Button("One Frame Later") { model.nudge(m, in: song, frames: 1) }.disabled(model.locked)
            Divider()
            Button("Delete") { model.deleteMarker(m, in: song) }.disabled(model.locked)
        }
        .help("\(m.time.description) · \(lane.commandLine(for: m) ?? triggerText(m, lane: lane)). Drag to move, right-click for more.")
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
    }

    private var addLaneRow: some View {
        HStack(spacing: 12) {
            Button { model.newLane() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Add lane").font(.manrope(11.5, .semibold))
                }
                .foregroundStyle(Brand.space)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.05)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.locked)
            .frame(width: labelWidth, alignment: .leading)
            if let lane = model.selectedLane {
                HStack(spacing: 6) {
                    KeyCap(key: "C")
                    Text("drops a trigger on")
                    Text(lane.title).foregroundStyle(Brand.lane(lane.color))
                    Text("at the playhead. Double-click a lane to place one; drag to move.")
                }
                .font(.manrope(11.5))
                .foregroundStyle(Brand.graphite)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    private func markerLines(width: CGFloat, length: Double, height: CGFloat) -> some View {
        let selected = model.selectedLane
        return ZStack(alignment: .topLeading) {
            ForEach(song.markers) { marker in
                if marker.laneID == nil {
                    Rectangle().fill(Brand.gold.opacity(0.28)).frame(width: 1, height: max(0, height))
                        .offset(x: xPos(of: marker, width: width, length: length), y: 30)
                } else if let lane = selected, marker.laneID == lane.id {
                    // The chosen lane's triggers, faintly through the waveform, to line them up with the music.
                    Rectangle().fill(Brand.lane(lane.color).opacity(0.22)).frame(width: 1, height: max(0, height))
                        .offset(x: xPos(of: marker, width: width, length: length), y: 30)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func playhead(position: Double, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text((transport.outputTimecode(for: song) ?? (song.hasTimecode ? nil : Timecode(frameCount: Int(max(0, position) * song.rate.framesPerSecond), rate: song.rate)))?.description ?? "--:--:--:--")
                .font(.manrope(11, .bold).monospacedDigit())
                .foregroundStyle(Color(hex: 0x120D05))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Brand.gold))
                .fixedSize()
                .offset(x: 1)
            Rectangle().fill(Brand.gold).frame(width: 2, height: max(0, height))
        }
        .frame(width: 2)
        .allowsHitTesting(false)
    }
}

/// Peak bars: played part off-white, the rest graphite.
struct WaveformView: View {
    let peaks: [Float]
    let progress: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else {
                ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)), with: .color(Brand.arsenic))
                return
            }
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let count = Int(size.width / (barWidth + gap))
            let playedX = size.width * progress
            for i in 0..<count {
                let x = CGFloat(i) * (barWidth + gap)
                let peak = CGFloat(peaks[min(peaks.count - 1, i * peaks.count / max(count, 1))])
                let h = max(1, peak * size.height * 0.92)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(x < playedX ? Color(hex: 0xE9E9EE) : Color(hex: 0x3A3C46)))
            }
        }
    }
}
