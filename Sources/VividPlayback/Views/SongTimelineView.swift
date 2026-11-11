import SwiftUI
import AppKit
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
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64, height: 1)  // room for the window buttons
            TransportButtons()
            LiveClock(size: 30, weight: .light)
            if let song = model.currentSong { Chip(song.rate.displayName) }
            if transport.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            // Full labels when there's room; icons and keys when the window is narrow.
            ViewThatFits(in: .horizontal) {
                actions(compact: false)
                actions(compact: true)
            }
            Button("Done") { model.go(.library) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .glass(cornerRadius: 16, alpha: 0.76)
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            Button { model.toggleLoop() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "repeat").foregroundStyle(transport.loop != nil ? Brand.gold : Brand.ink)
                    if !compact { Text(transport.loop != nil ? "Looping" : "Loop") }
                    KeyCap(key: "L")
                }
                .fixedSize()
            }
            .buttonStyle(QuietButtonStyle())
            .help("Loop between the markers either side of the playhead, or the whole song (L)")
            Button { model.addMarker() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    if !compact { Text("Marker") }
                    KeyCap(key: "M")
                }
                .fixedSize()
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.locked)
            .help("Drop a marker at the playhead (M)")
            Button { model.addTrigger() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.lanes.isEmpty ? "rectangle.stack.badge.plus" : "bolt.fill")
                        .foregroundStyle(model.selectedLane.map { Brand.lane($0.color) } ?? Brand.ink)
                    if !compact { Text(model.lanes.isEmpty ? "Trigger lane" : "Trigger") }
                    KeyCap(key: "C")
                }
                .fixedSize()
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.locked)
            .help(model.lanes.isEmpty ? "Add a lane that fires an MA3 executor over OSC (C)"
                                      : "Drop a trigger at the playhead on \(model.selectedLane?.title ?? "the chosen lane") (C)")
            Button { model.toggleDeskRecording() } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xE5675A)).frame(width: 8, height: 8)
                        .opacity(model.recordingFromDesk ? 1 : 0.55)
                    if !compact { Text(model.recordingFromDesk ? "Recording desk" : "Record desk") }
                }
                .fixedSize()
            }
            .buttonStyle(QuietButtonStyle())
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(hex: 0xE5675A).opacity(model.recordingFromDesk ? 0.8 : 0), lineWidth: 1))
            .disabled(model.locked && !model.recordingFromDesk)
            .help(model.recordingFromDesk ? "Stop recording GOs from the desk (⇧⌘R)"
                                          : "Record GOs from the desk: each one lands on its executor's lane at the frame you hear (⇧⌘R)")
        }
    }

    private func header(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 28) {
            SongArt(song: song, cornerRadius: 12)
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
            VStack(alignment: .leading, spacing: 8) {
                let q = model.queue
                let index = (q.firstIndex { $0.id == song.id } ?? 0) + 1
                Text("SONG \(index) OF \(q.count)").font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                Text(song.title)
                    .font(.manrope(44, .semibold))
                    .foregroundStyle(Brand.ink)
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
    /// A trigger being dragged along its lane, and how far.
    @State private var dragging: (id: UUID, dx: CGFloat)?
    /// A selection box being dragged across the lanes, in the tracks' coordinates.
    @State private var marquee: (start: CGPoint, end: CGPoint, base: Set<UUID>)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lanes: [TriggerLane] { model.lanes }
    private var plainMarkers: [Marker] { song.markers.filter { $0.laneID == nil } }
    /// Lane names need more room than "MASTER".
    private var labelWidth: CGFloat { lanes.isEmpty ? 92 : 156 }

    var body: some View {
        let length = max(model.playLength(of: song), 0.001)
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
                // Drawn once, not every frame: the lanes, markers, waveform and ruler only change
                // when the song, the zoom or an edit changes them. Only `liveLayer` (playhead,
                // played part of the waveform, pulses) redraws while playing.
                let win = staticWindow(length: length)
                let rows = markerRows(scrubLimit: scrubLimit, laneHeight: laneHeight)
                VStack(alignment: .leading, spacing: 10) {
                    ruler(width: trackWidth, win: win)
                    lane("Master") {
                        WaveformView(data: model.waveforms[song.id], fileOffset: song.fileOffset,
                                     from: win.start, to: win.end, played: false)
                            .equatable()
                            .frame(height: waveHeight)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.02)))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    lane("Timecode") { timecodeLane(win) }
                    if !plain.isEmpty {
                        lane("Markers") { markerLane(plain, width: trackWidth, win: win) }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if !lanes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lanes) { l in
                                triggerLane(l, height: laneHeight, width: trackWidth, win: win)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            addLaneRow
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .overlay(alignment: .topLeading) {
                  // An explicit top-left stack: the overlay's own grouping centres its pieces on each other.
                  ZStack(alignment: .topLeading) {
                    if let loop = transport.loop {
                        let x0 = min(trackWidth, max(0, CGFloat(win.x(loop.lowerBound, width: Double(trackWidth)))))
                        let x1 = min(trackWidth, max(0, CGFloat(win.x(loop.upperBound, width: Double(trackWidth)))))
                        Rectangle().fill(Brand.gold.opacity(0.08))
                            .overlay(alignment: .top) { Rectangle().fill(Brand.gold.opacity(0.6)).frame(height: 2) }
                            .frame(width: max(2, x1 - x0), height: linesBottom - 24)
                            .offset(x: labelWidth + 12 + x0, y: 24)
                            .allowsHitTesting(false)
                    }
                    markerLines(width: trackWidth, win: win, height: linesBottom - 30)
                        .offset(x: labelWidth + 12)
                    liveLayer(length: length, trackWidth: trackWidth, waveHeight: waveHeight,
                              linesBottom: linesBottom, rows: rows)
                        .allowsHitTesting(false)
                    marqueeBox
                  }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
                    // Scrub on the waveform and timecode lanes; the marker and executor lanes keep their clicks.
                    let x = value.location.x - labelWidth - 12
                    guard x >= 0, trackWidth > 0, value.startLocation.y < scrubLimit else { return }
                    transport.locate(win.time(atX: Double(min(x, trackWidth)), width: Double(trackWidth)))
                })
                .simultaneousGesture(marqueeGesture(scrubLimit: scrubLimit, laneHeight: laneHeight, width: trackWidth, win: win))
                .onAppear { reportTrackFrame(geo, trackWidth: trackWidth) }
                .onChange(of: geo.frame(in: .global)) { _ in reportTrackFrame(geo, trackWidth: trackWidth) }
            }
            if model.recordingFromDesk && lanes.isEmpty {
                DeskRecordingLine()
                    .font(.manrope(12.5))
                    .padding(.leading, labelWidth + 12)
            } else if plain.isEmpty && lanes.isEmpty {
                HStack(spacing: 8) {
                    KeyCap(key: "M")
                    Text("drops a marker at the playhead.")
                    KeyCap(key: "C").padding(.leading, 10)
                    Text("starts a trigger lane that fires an MA3 executor. Songs without either stay plain playback.")
                    if !model.songsWithLanes.isEmpty && !model.locked {
                        Menu { copyLanesItems } label: {
                            Text("Copy lanes from another song…").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.gold)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .padding(.leading, 10)
                    }
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
        .overlay(alignment: .bottom) { selectionBar.padding(.bottom, 12) }

        .animation(.vivid(0.3), value: model.selectedMarkerIDs.isEmpty)
        .animation(.vivid(0.4), value: lanes)
        .onAppear {
            model.loadWaveform(for: song)
        }
    }

    private func lane<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title.uppercased()).font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    /// The window the still parts are drawn in: the zoom you set (kept in step with the song's length).
    private func staticWindow(length: Double) -> TimelineWindow {
        let w = model.timelineWindow
        return abs(w.length - length) > 0.0005 ? TimelineWindow(length: length, zoom: w.zoom, start: w.start) : w
    }

    /// Everything that moves while playing, redrawn every frame on its own: the playhead, the
    /// played part of the waveform, and the pulse of each trigger as the playhead (the position
    /// you hear) crosses it, so pulses land with the sound. Paging along when zoomed starts here.
    private func liveLayer(length: Double, trackWidth: CGFloat, waveHeight: CGFloat, linesBottom: CGFloat,
                           rows: [(laneID: UUID?, top: CGFloat, height: CGFloat)]) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !transport.isPlaying)) { _ in
            let position = min(transport.position(at: CACurrentMediaTime()), length)
            let win = livePage(staticWindow(length: length), playhead: position)
            let playheadX = CGFloat(win.x(position, width: Double(trackWidth)))
            ZStack(alignment: .topLeading) {
                // The played part of the waveform: the same bars, lighter, up to the playhead.
                WaveformView(data: model.waveforms[song.id], fileOffset: song.fileOffset,
                             from: win.start, to: win.end, played: true)
                    .equatable()
                    .frame(width: trackWidth, height: waveHeight)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: min(trackWidth, max(0, playheadX)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .offset(x: labelWidth + 12, y: 32)
                if transport.isPlaying {
                    pulses(position: position, win: win, width: trackWidth, rows: rows)
                }
                if playheadX >= -1 && playheadX <= trackWidth + 1 {
                    playhead(position: position, height: linesBottom - 18)
                        .offset(x: labelWidth + 12 + playheadX - 1)
                }
            }
        }
    }

    /// While playing zoomed in, the window pages along with the playhead.
    private func livePage(_ w: TimelineWindow, playhead: Double) -> TimelineWindow {
        guard transport.isPlaying, w.isZoomed else { return w }
        var paged = w
        paged.follow(playhead)
        if paged.start != w.start {
            let start = paged.start
            DispatchQueue.main.async { model.showInTimeline(start: start) }
        }
        return paged
    }

    /// The bloom on each trigger and the glow on its lane's name, from the moment the playhead
    /// crosses it: as fast as the sound, with no trip through the main thread.
    private func pulses(position: Double, win: TimelineWindow, width: CGFloat,
                        rows: [(laneID: UUID?, top: CGFloat, height: CGFloat)]) -> some View {
        let bloomTime = 0.3, glowTime = 0.4
        var blooms: [(id: UUID, x: CGFloat, top: CGFloat, height: CGFloat, p: CGFloat)] = []
        var glows: [(id: UUID, top: CGFloat, height: CGFloat, p: CGFloat, color: Color)] = []
        for row in rows {
            guard let laneID = row.laneID, let lane = lanes.first(where: { $0.id == laneID }), !lane.muted else { continue }
            var strongest: CGFloat = 0
            for m in song.markers where m.laneID == laneID {
                let dt = position - model.seconds(of: m, in: song)
                guard dt >= 0, dt < glowTime else { continue }
                strongest = max(strongest, CGFloat(1 - dt / glowTime))
                if dt < bloomTime {
                    let u = CGFloat(1 - dt / bloomTime)
                    let x = xPos(of: m, width: width, win: win)
                    if x >= -20 && x <= width + 20 {
                        blooms.append((m.id, labelWidth + 12 + x, row.top + 4, max(8, row.height - 8), u * u))
                    }
                }
            }
            if strongest > 0 { glows.append((laneID, row.top, row.height, strongest * strongest, Brand.lane(lane.color))) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(glows, id: \.id) { g in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(g.color.opacity(0.32 * g.p))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(g.color.opacity(0.7 * g.p), lineWidth: 1))
                    .frame(width: labelWidth, height: g.height)
                    .offset(y: g.top)
            }
            ForEach(blooms, id: \.id) { b in
                Capsule()
                    .fill(Brand.gold)
                    .frame(width: reduceMotion ? 3 : 3 + 18 * b.p, height: b.height)
                    .blur(radius: reduceMotion ? 0 : 5 * b.p)
                    .opacity(0.95 * Double(b.p))
                    .offset(x: b.x - (reduceMotion ? 1.5 : (3 + 18 * b.p) / 2), y: b.top)
            }
        }
    }

    private func reportTrackFrame(_ geo: GeometryProxy, trackWidth: CGFloat) {
        let f = geo.frame(in: .global)
        model.timelineTrackFrame = CGRect(x: f.minX + labelWidth + 12, y: f.minY, width: trackWidth, height: f.height)
    }

    /// Timecode labels at a spacing that suits the zoom, with zoom buttons in the label column
    /// and, when zoomed, an overview bar you can drag.
    private func ruler(width: CGFloat, win: TimelineWindow) -> some View {
        let fps = song.rate.framesPerSecond
        let step = win.tickStep(width: Double(width), fps: fps)
        let first = (win.start / step).rounded(.up) * step
        let marks = Array(stride(from: first, through: win.end + 1e-9, by: step).prefix(200))
        let showFrames = step < 1 || win.zoom >= 8
        return HStack(spacing: 12) {
            zoomControls.frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .topLeading) {
                ForEach(marks, id: \.self) { t in
                    let tc = song.start.adding(frames: Int((t * fps + 1e-6).rounded(.down)))
                    Text(showFrames ? tc.description : String(tc.description.prefix(8)))
                        .font(.manrope(11).monospacedDigit())
                        .foregroundStyle(Brand.graphite)
                        .fixedSize()
                        .position(x: CGFloat(win.x(t, width: Double(width))), y: 8)
                }
                if win.isZoomed { overview(width: width, win: win) }
            }
            .frame(width: width, height: 22)
            .clipped()
        }
    }

    private var zoomControls: some View {
        let zoomed = model.timelineWindow.isZoomed
        return HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass", "Zoom out (⌘−)") { model.zoomTimeline(by: 0.5) }.disabled(!zoomed)
            zoomButton("plus.magnifyingglass", "Zoom in (⌘=). Or pinch, or ⌘-scroll, over the timeline.") { model.zoomTimeline(by: 2) }
            if zoomed {
                Button { model.zoomToFit() } label: {
                    Text("Fit").font(.manrope(10.5, .bold)).foregroundStyle(Brand.gold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Brand.gold.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Show the whole song (⌘0)")
                .transition(.opacity)
            }
        }
    }

    private func zoomButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.space)
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Where the window sits in the song; drag it to move along.
    private func overview(width: CGFloat, win: TimelineWindow) -> some View {
        let x0 = width * CGFloat(win.start / win.length)
        let w = max(18, width * CGFloat(win.span / win.length))
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.06)).frame(width: width, height: 3)
            Capsule().fill(Brand.space.opacity(0.7)).frame(width: w, height: 3).offset(x: min(x0, width - w))
        }
        .frame(width: width, height: 8)
        .contentShape(Rectangle())
        .offset(y: 15)
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let t = Double(v.location.x / max(width, 1)) * win.length - win.span / 2
            model.showInTimeline(start: t)
        })
        .help("Drag to move along the song")
    }

    private func timecodeLane(_ win: TimelineWindow) -> some View {
        let fps = song.rate.framesPerSecond
        let from = win.isZoomed ? song.start.adding(frames: Int(win.start * fps)) : song.start
        let to = win.isZoomed ? song.start.adding(frames: Int(win.end * fps)) : song.end
        return HStack {
            Text(song.hasTimecode ? from.description : "No timecode for this song")
            Spacer()
            Text(song.hasTimecode ? (to?.description ?? "") : "")
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

    private func xPos(of marker: Marker, width: CGFloat, win: TimelineWindow) -> CGFloat {
        CGFloat(win.x(Double(marker.time.frames(since: song.start)) / song.rate.framesPerSecond, width: Double(width)))
    }

    private func markerLane(_ markers: [Marker], width: CGFloat, win: TimelineWindow) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Brand.gold.opacity(0.05))
            ForEach(markers) { marker in
                let x = xPos(of: marker, width: width, win: win) + dragOffset(marker.id)
                if x > -200 && x < width + 200 {
                    let flip = x > width * 0.85
                    HStack(spacing: 7) {
                        if flip { markerChip(marker, width: width, win: win) }
                        Capsule().fill(Brand.gold).frame(width: 2, height: 36)
                        if !flip { markerChip(marker, width: width, win: win) }
                    }
                    .fixedSize()
                    .frame(width: 0, alignment: flip ? .trailing : .leading)
                    .offset(x: x - (flip ? 0 : 1), y: 4)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
        }
        .frame(width: width, height: 44)
        .clipped()
    }

    private func markerLabel(_ text: String, selected: Bool) -> some View {
        Text(text).font(.manrope(11.5, .semibold)).foregroundStyle(Brand.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Brand.phantom))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.gold, lineWidth: selected ? 1.5 : 0))
    }

    private func markerChip(_ marker: Marker, width: CGFloat, win: TimelineWindow) -> some View {
        markerLabel(marker.label, selected: model.selectedMarkerIDs.contains(marker.id))
            .contentShape(Rectangle())
            .onTapGesture { click(marker) }
            .gesture(moveGesture(marker, width: width, win: win))
            .contextMenu {
                selectionMenu(marker)
                Button("Go to Marker") { transport.locate(model.seconds(of: marker, in: song)) }
                Button("Rename…") { model.markerEdit = MarkerEdit(marker: marker, song: song) }.disabled(model.locked)
                Button("Move to Playhead") { model.moveToPlayhead(marker, in: song) }.disabled(model.locked)
                Button("One Frame Earlier") { model.nudge(marker, in: song, frames: -1) }.disabled(model.locked)
                Button("One Frame Later") { model.nudge(marker, in: song, frames: 1) }.disabled(model.locked)
                Divider()
                Button("Delete") { model.deleteMarker(marker, in: song) }.disabled(model.locked)
            }
            .help("Click to select and go here; shift-click to add to the selection. Drag to move; ⌥← ⌥→ nudge a frame; Delete removes it.")
    }

    /// Click selects one and goes there; shift- or ⌘-click adds it to (or takes it off) the selection.
    private func click(_ m: Marker) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) || mods.contains(.command) {
            model.toggleSelection(m)
        } else {
            model.selectedMarkerID = m.id
            transport.locate(model.seconds(of: m, in: song))
        }
    }

    /// With several selected, right-click offers to act on all of them.
    @ViewBuilder private func selectionMenu(_ m: Marker) -> some View {
        let n = model.selectedMarkerIDs.count
        if n > 1 && model.selectedMarkerIDs.contains(m.id) {
            Button("Delete \(n) Selected") { model.deleteSelected() }.disabled(model.locked)
            Button("Move \(n) Selected One Frame Earlier") { model.nudgeSelected(frames: -1) }.disabled(model.locked)
            Button("Move \(n) Selected One Frame Later") { model.nudgeSelected(frames: 1) }.disabled(model.locked)
            Divider()
        }
    }

    /// How far a marker is being dragged: dragging a selected one carries the whole selection.
    private func dragOffset(_ id: UUID) -> CGFloat {
        guard let d = dragging else { return 0 }
        if d.id == id { return d.dx }
        let sel = model.selectedMarkerIDs
        return sel.count > 1 && sel.contains(d.id) && sel.contains(id) ? d.dx : 0
    }

    /// Drag a marker or trigger along its lane (with the rest of the selection, if it's in it);
    /// it lands on a whole frame.
    private func moveGesture(_ m: Marker, width: CGFloat, win: TimelineWindow) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard !model.locked else { return }
                if !model.selectedMarkerIDs.contains(m.id) { model.selectedMarkerID = m.id }
                dragging = (m.id, v.translation.width)
            }
            .onEnded { v in
                dragging = nil
                guard !model.locked, width > 0 else { return }
                let seconds = Double(v.translation.width / width) * win.span
                if model.selectedMarkerIDs.count > 1 && model.selectedMarkerIDs.contains(m.id) {
                    model.moveSelected(by: seconds)
                } else {
                    model.move(m, in: song, to: model.seconds(of: m, in: song) + seconds)
                }
            }
    }

    // MARK: Box selection

    /// The rows markers sit on, top to bottom, in the tracks' coordinates: the marker lane
    /// (laneID nil) and each executor lane.
    private func markerRows(scrubLimit: CGFloat, laneHeight: CGFloat) -> [(laneID: UUID?, top: CGFloat, height: CGFloat)] {
        var result: [(laneID: UUID?, top: CGFloat, height: CGFloat)] = []
        var y = scrubLimit + 10
        if !plainMarkers.isEmpty {
            result.append((laneID: nil, top: y, height: 44))
            y += 54
        }
        for l in lanes {
            result.append((laneID: l.id, top: y, height: laneHeight))
            y += laneHeight + 6
        }
        return result
    }

    /// True when a point lands on a marker or its label (that drag moves it instead of drawing a box).
    private func hitsMarker(_ p: CGPoint, rows: [(laneID: UUID?, top: CGFloat, height: CGFloat)], width: CGFloat, win: TimelineWindow) -> Bool {
        guard let row = rows.first(where: { p.y >= $0.top && p.y <= $0.top + $0.height }) else { return false }
        for m in song.markers where m.laneID == row.laneID {
            let x = labelWidth + 12 + xPos(of: m, width: width, win: win)
            let label = CGFloat(m.label.count) * (row.laneID == nil ? 6.8 : 6.4) + 22
            let flip = x - labelWidth - 12 > width * (row.laneID == nil ? 0.85 : 0.88)
            let lo = flip ? x - label : x - 5, hi = flip ? x + 5 : x + label
            if p.x >= lo && p.x <= hi { return true }
        }
        return false
    }

    private func marqueeGesture(scrubLimit: CGFloat, laneHeight: CGFloat, width: CGFloat, win: TimelineWindow) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let rows = markerRows(scrubLimit: scrubLimit, laneHeight: laneHeight)
                if marquee == nil {
                    // Only from empty space on the marker and executor lanes.
                    guard dragging == nil, !rows.isEmpty, v.startLocation.y >= scrubLimit + 4,
                          v.startLocation.x >= labelWidth + 12,
                          !hitsMarker(v.startLocation, rows: rows, width: width, win: win) else { return }
                    let mods = NSEvent.modifierFlags
                    marquee = (start: v.startLocation, end: v.location, base: mods.contains(.shift) || mods.contains(.command) ? model.selectedMarkerIDs : [])
                }
                guard var box = marquee else { return }
                box.end = v.location
                marquee = box
                let rect = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y),
                                  width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
                var picked = box.base
                for row in rows where row.top + row.height >= rect.minY && row.top <= rect.maxY {
                    for m in song.markers where m.laneID == row.laneID {
                        let x = labelWidth + 12 + xPos(of: m, width: width, win: win)
                        if x >= rect.minX && x <= rect.maxX { picked.insert(m.id) }
                    }
                }
                if picked != model.selectedMarkerIDs { model.selectedMarkerIDs = picked }
            }
            .onEnded { _ in marquee = nil }
    }

    @ViewBuilder private var marqueeBox: some View {
        if let box = marquee {
            let rect = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y),
                              width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
            RoundedRectangle(cornerRadius: 3)
                .fill(Brand.gold.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Brand.gold.opacity(0.75), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// What's selected, and what you can do with it, floating over the bottom of the timeline.
    @ViewBuilder private var selectionBar: some View {
        let selected = model.selectedMarkers
        if !selected.isEmpty {
            let triggers = selected.filter { $0.laneID != nil }.count
            let markers = selected.count - triggers
            let what = [triggers > 0 ? "\(triggers) trigger\(triggers == 1 ? "" : "s")" : nil,
                        markers > 0 ? "\(markers) marker\(markers == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
            HStack(spacing: 6) {
                Text(what + " selected").font(.manrope(12.5, .semibold)).foregroundStyle(Brand.ink)
                    .padding(.leading, 6).padding(.trailing, 8)
                barButton("chevron.left", "One frame earlier (⌥←)") { model.nudgeSelected(frames: -1) }
                barButton("chevron.right", "One frame later (⌥→)") { model.nudgeSelected(frames: 1) }
                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 18).padding(.horizontal, 4)
                Button { model.deleteSelected() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash").font(.system(size: 11.5, weight: .semibold))
                        Text("Delete").font(.manrope(12.5, .semibold))
                        KeyCap(key: "⌫")
                    }
                    .foregroundStyle(Color(hex: 0xF0A096))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: 0xE5675A).opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.locked)
                .help("Delete what's selected. ⌘Z brings it back.")
                barButton("xmark", "Clear the selection (Esc)") { model.selectedMarkerIDs = [] }
            }
            .padding(5)
            .background(Capsule().fill(Brand.phantom))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Brand.steel)
                .frame(width: 28, height: 26)
                .background(Circle().fill(.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.locked && symbol != "xmark")
        .help(help)
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

    private func triggerLane(_ lane: TriggerLane, height: CGFloat, width: CGFloat, win: TimelineWindow) -> some View {
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
                ForEach(Array(triggers.enumerated()), id: \.element.id) { i, m in
                    // Room for the label: up to the next trigger (or back to the previous one
                    // when the label sits on the left near the end).
                    let x = xPos(of: m, width: width, win: win)
                    if x > -200 && x < width + 200 {
                    let next = i + 1 < triggers.count ? xPos(of: triggers[i + 1], width: width, win: win) : width
                    let prev = i > 0 ? xPos(of: triggers[i - 1], width: width, win: win) : 0
                    triggerTick(m, lane: lane, color: color, height: height, width: width, win: win,
                                room: x > width * 0.88 ? x - prev - 10 : next - x - 10)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(lane.muted ? 0.4 : 1)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { value in
                model.addTrigger(on: lane, at: win.time(atX: Double(value.location.x), width: Double(width)))
            })
            .simultaneousGesture(TapGesture().onEnded {
                model.selectedLaneID = lane.id
                if !NSEvent.modifierFlags.contains(.shift) { model.selectedMarkerIDs = [] }
            })
            .help("Drag across lanes to select triggers. Double-click to drop one here; C drops one at the playhead.")
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
                if let key = lane.key {
                    KeyCap(key: key.uppercased()).help("Press \(key.uppercased()) to drop a trigger on this lane at the playhead")
                }
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
            .modifier(FirePulse(fired: control.laneFiredAt[lane.id], color: color, style: .glow))
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

    private func triggerTick(_ m: Marker, lane: TriggerLane, color: Color, height: CGFloat, width: CGFloat, win: TimelineWindow,
                             room: CGFloat) -> some View {
        let fired = false
        let dx = dragOffset(m.id)
        let x = xPos(of: m, width: width, win: win) + dx
        let selected = model.selectedMarkerIDs.contains(m.id)
        let flip = x > width * 0.88
        let text = triggerText(m, lane: lane)
        // Labels that would run into the next trigger are left off (hover shows them).
        let showLabel = height >= 24 && (dx != 0 || CGFloat(text.count) * 6.4 + 14 <= room)
        let chip = Text(text)
            .font(.manrope(10.5, .semibold))
            .foregroundStyle(fired ? Color(hex: 0x120D05) : Brand.ink)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fired ? Brand.gold : Brand.phantom))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.gold, lineWidth: selected && !fired ? 1.5 : 0))
        return HStack(spacing: 5) {
            if flip && showLabel { chip }
            Capsule().fill(fired || selected ? Brand.gold : color).frame(width: fired || selected ? 3 : 2, height: max(8, height - 8))
                .background(FireBloom(fired: control.firedAt[m.id], height: max(8, height - 8)))
            if !flip && showLabel { chip }
        }
        .fixedSize()
        .modifier(FirePulse(fired: control.firedAt[m.id]))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedLaneID = lane.id
            click(m)
        }
        .gesture(moveGesture(m, width: width, win: win))
        .contextMenu {
            selectionMenu(m)
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
        .help("\(text) · \(m.time.description) · \(lane.commandLine(for: m) ?? "Fader \(lane.page).\(lane.executor)"). Drag to move, ⌥← ⌥→ nudge a frame, Delete removes it.")
        // A zero-width anchor at the trigger: a label flipped to the left can't widen the lane.
        .frame(width: 0, alignment: flip ? .trailing : .leading)
        .offset(x: x - (flip ? 0 : 1), y: 4)
        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
    }

    private var addLaneLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
            Text("Add lane").font(.manrope(11.5, .semibold))
        }
        .foregroundStyle(Brand.space)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.05)))
        .contentShape(Capsule())
    }

    /// "Copy lanes from": every other song that has lanes.
    @ViewBuilder private var copyLanesItems: some View {
        Section("Copy lanes from") {
            ForEach(model.songsWithLanes) { other in
                let n = other.triggerLanes?.count ?? 0
                Button("\(other.title) · \(n) lane\(n == 1 ? "" : "s")") { model.copyLanes(from: other) }
            }
        }
    }

    private var addLaneRow: some View {
        HStack(spacing: 12) {
            Group {
                if model.songsWithLanes.isEmpty {
                    Button { model.newLane() } label: { addLaneLabel }.buttonStyle(.plain)
                } else {
                    Menu {
                        Button("New Lane…") { model.newLane() }
                        Divider()
                        copyLanesItems
                    } label: { addLaneLabel }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .disabled(model.locked)
            .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 6) {
                if model.recordingFromDesk {
                    DeskRecordingLine()
                } else if lanes.contains(where: { $0.key != nil }) {
                    Image(systemName: "keyboard").foregroundStyle(Brand.space)
                    Text("Press a lane's key while it plays to drop a trigger.")
                    KeyCap(key: "⌫").padding(.leading, 4)
                    Text("takes back the selected one.")
                } else if let lane = model.selectedLane {
                    KeyCap(key: "C")
                    Text("drops a trigger on")
                    Text(lane.title).foregroundStyle(Brand.lane(lane.color))
                    Text("at the playhead. Give a lane a key to drop triggers on it live.")
                }
            }
            .font(.manrope(11.5))
            .foregroundStyle(Brand.graphite)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(model.selectedMarkerIDs.isEmpty || model.recordingFromDesk ? 1 : 0)
            Spacer(minLength: 8)
            Toggle(isOn: $control.settings.keysFire) {
                Text("Keys fire the console").font(.manrope(11.5, .medium)).foregroundStyle(Brand.steel)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("When on, a lane's key also fires its executor as it drops the trigger, so you see the look while you program.")
        }
        .frame(height: 26)
    }

    private func markerLines(width: CGFloat, win: TimelineWindow, height: CGFloat) -> some View {
        let selected = model.selectedLane
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: 1)
            ForEach(song.markers) { marker in
                if marker.laneID == nil {
                    Rectangle().fill(Brand.gold.opacity(0.28)).frame(width: 1, height: max(0, height))
                        .offset(x: xPos(of: marker, width: width, win: win), y: 30)
                } else if let lane = selected, marker.laneID == lane.id {
                    // The chosen lane's triggers, faintly through the waveform, to line them up with the music.
                    Rectangle().fill(Brand.lane(lane.color).opacity(0.22)).frame(width: 1, height: max(0, height))
                        .offset(x: xPos(of: marker, width: width, win: win), y: 30)
                }
            }
        }
        .frame(width: width, height: height + 30, alignment: .topLeading)
        .clipped()
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

/// Peak bars for the stretch of the song on screen, in one colour (the played part is a second
/// copy, masked to the playhead). Equatable, so it's only redrawn when what it shows changes.
struct WaveformView: View, Equatable {
    let data: WaveformData?
    /// Song time 0 is this far into the file.
    let fileOffset: Double
    let from: Double
    let to: Double
    let played: Bool

    static func == (a: WaveformView, b: WaveformView) -> Bool {
        a.data?.token == b.data?.token && a.fileOffset == b.fileOffset && a.from == b.from && a.to == b.to && a.played == b.played
    }

    var body: some View {
        Canvas { ctx, size in
            guard let data, !data.peaks.isEmpty, to > from else {
                if !played {
                    ctx.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)), with: .color(Brand.arsenic))
                }
                return
            }
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let count = Int(size.width / (barWidth + gap))
            let perBar = (to - from) / Double(max(count, 1))
            var path = Path()
            for i in 0..<count {
                let x = CGFloat(i) * (barWidth + gap)
                let t = from + Double(i) * perBar
                let peak = CGFloat(data.peak(from: t + fileOffset, to: t + perBar + fileOffset))
                let h = max(1, peak * size.height * 0.92)
                path.addRoundedRect(in: CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h), cornerSize: CGSize(width: 1, height: 1))
            }
            ctx.fill(path, with: .color(played ? Color(hex: 0xE9E9EE) : Color(hex: 0x3A3C46)))
        }
        .drawingGroup()
    }
}

// MARK: Firing pulse

/// Plays once each time `fired` changes: what just fired swells a touch and glows, then settles.
/// Animated on its own, so it shows whether or not the song is rolling. Reduce Motion: a glow only.
struct FirePulse: ViewModifier {
    enum Style { case bump, glow }
    let fired: Date?
    var color: Color = Brand.gold
    var style: Style = .bump
    /// 1 when settled; 0 at the moment of firing.
    @State private var settle: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let p = 1 - settle
        return Group {
            switch style {
            case .bump:
                content
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.14 * p)
                    .shadow(color: color.opacity(0.85 * p), radius: 10 * p)
            case .glow:
                content
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.32 * p)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(0.7 * p), lineWidth: 1))
            }
        }
        .onChange(of: fired) { _ in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { settle = 0 }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: style == .bump ? 0.275 : 0.4)) { settle = 1 }
            }
        }
    }
}

/// A soft gold bloom behind a trigger's line as it fires.
struct FireBloom: View {
    let fired: Date?
    let height: CGFloat
    @State private var settle: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = 1 - settle
        Capsule()
            .fill(Brand.gold)
            .frame(width: reduceMotion ? 3 : 3 + 18 * p, height: height)
            .blur(radius: reduceMotion ? 0 : 5 * p)
            .opacity(0.9 * Double(p))
            .allowsHitTesting(false)
            .onChange(of: fired) { _ in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { settle = 0 }
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { settle = 1 } }
            }
    }
}

/// "● Recording from the desk · OSC GO 1.201 → Main cues at 03:00:12:04", while armed: one line
/// in place of the lane hint, so nothing moves.
struct DeskRecordingLine: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @EnvironmentObject private var control: ControlCenter

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: Color(hex: 0xE5675A), pulsing: transport.isPlaying)
            Text(transport.isPlaying ? "Recording from the desk" : "Armed · play to record")
                .fontWeight(.bold).foregroundStyle(Brand.ink)
            if let last = model.lastDeskGo, Date().timeIntervalSince(last.at) < 20 {
                Text("· " + last.text).foregroundStyle(Brand.steel).monospacedDigit()
            } else if control.deskStatus.hasPrefix("Port") {
                Text("· " + control.deskStatus).foregroundStyle(Brand.warn)
            } else {
                Text("· each GO lands on its executor's lane").foregroundStyle(Brand.space)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .help("GOs arrive as OSC /vivid/exec (\"1.201\") or MIDI Show Control. ⌘Z takes back what was recorded.")
    }
}

// MARK: Firing pulse

/// Plays once each time `fired` changes: what just fired swells a touch and glows, then settles.
/// Animated on its own, so it shows whether or not the song is rolling. Reduce Motion: a glow only.
struct FirePulse: ViewModifier {
    enum Style { case bump, glow }
    let fired: Date?
    var color: Color = Brand.gold
    var style: Style = .bump
    /// 1 when settled; 0 at the moment of firing.
    @State private var settle: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let p = 1 - settle
        return Group {
            switch style {
            case .bump:
                content
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.14 * p)
                    .shadow(color: color.opacity(0.85 * p), radius: 10 * p)
            case .glow:
                content
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.32 * p)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color.opacity(0.7 * p), lineWidth: 1))
            }
        }
        .onChange(of: fired) { _ in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { settle = 0 }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: style == .bump ? 0.275 : 0.4)) { settle = 1 }
            }
        }
    }
}

/// A soft gold bloom behind a trigger's line as it fires.
struct FireBloom: View {
    let fired: Date?
    let height: CGFloat
    @State private var settle: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = 1 - settle
        Capsule()
            .fill(Brand.gold)
            .frame(width: reduceMotion ? 3 : 3 + 18 * p, height: height)
            .blur(radius: reduceMotion ? 0 : 5 * p)
            .opacity(0.9 * Double(p))
            .allowsHitTesting(false)
            .onChange(of: fired) { _ in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { settle = 0 }
                DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { settle = 1 } }
            }
    }
}

/// "● Recording from the desk · OSC GO 1.201 → Main cues at 03:00:12:04", while armed.
struct DeskRecordingBadge: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @EnvironmentObject private var control: ControlCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusDot(color: Color(hex: 0xE5675A), pulsing: transport.isPlaying)
                Text(transport.isPlaying ? "Recording from the desk" : "Armed · play to record")
                    .font(.manrope(12, .bold)).foregroundStyle(Brand.ink)
            }
            if let last = model.lastDeskGo, Date().timeIntervalSince(last.at) < 20 {
                Text(last.text).font(.manrope(11.5, .medium).monospacedDigit()).foregroundStyle(Brand.steel).lineLimit(2)
            } else if control.deskStatus.hasPrefix("Port") {
                Text(control.deskStatus).font(.manrope(11.5)).foregroundStyle(Brand.warn).lineLimit(2)
            } else {
                Text("Each GO lands on its executor's lane.").font(.manrope(11.5)).foregroundStyle(Brand.space)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.phantom))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xE5675A).opacity(0.5), lineWidth: 1))
        .help("GOs arrive as OSC /vivid/exec (\"1.201\") or MIDI Show Control. ⌘Z takes back what was recorded.")
    }
}
