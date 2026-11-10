import SwiftUI
import AppKit
import PlaybackCore

@main
struct VividPlaybackApp: App {
    @StateObject private var model = AppModel()

    init() {
        Fonts.register()
        // Run from Xcode or Terminal as a plain executable, still be a normal app with a Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Vivid Playback") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.transport)
                .environmentObject(model.control)
                .environmentObject(model.meters)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { PlaybackCommands(model: model) }
    }
}

@MainActor
struct PlaybackCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        let typing = model.sheetOpen
        CommandGroup(replacing: .newItem) {
            Button("New Show…") { model.newShow() }
                .keyboardShortcut("n")
                .disabled(model.locked)
            Button("Add Album…") { model.go(.albums); model.addAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.locked || model.show == nil)
            Button("Open Show…") { model.openShowPanel() }
                .keyboardShortcut("o")
                .disabled(model.locked)
            Button("Import Show Folder…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.locked)
            Divider()
            Button("Save") { model.saveNow() }
                .keyboardShortcut("s")
                .disabled(model.show == nil)
            Button("Save a Copy…") { model.saveCopy() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.show == nil)
            Button("Show Show File in Finder") { model.revealShowFile() }
                .disabled(model.show == nil)
            Divider()
            Button("Add Audio Files…") { model.chooseAudio() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.locked || model.show == nil)
            Button("Relink Media Folder…") { model.relink() }
                .disabled(model.locked || model.show == nil)
            Button("Check Files Again") { model.recheck() }
                .disabled(model.show == nil)
        }
        CommandMenu("Playback") {
            Button("Play or Pause") { model.transport.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(typing)
            Button("Next Song") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(typing)
            Button("Previous Song") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(typing)
            Button("Back to the Top of the Song") { model.transport.locate(model.transport.lowerBound) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(typing)
            Button("Go to Timecode…") { model.goToShown = true }
                .keyboardShortcut("g")
                .disabled(model.show == nil)
            Divider()
            Button(model.transport.loop == nil ? "Loop Between Markers" : "Stop Looping") { model.toggleLoop() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(typing || model.show == nil)
            Button("Undo Fix") { model.undoFix() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.lastFix == nil || model.locked)
            Button("Add Marker") { model.addMarker() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(typing || model.locked || model.screen != .timeline)
            Button("Add Trigger") { model.addTrigger() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(typing || model.locked || model.screen != .timeline)
            Button("New Trigger Lane…") { model.newLane() }
                .disabled(model.locked || model.show == nil)
            Menu("Copy Trigger Lanes From") {
                ForEach(model.songsWithLanes) { song in
                    Button(song.title) { model.copyLanes(from: song) }
                }
            }
            .disabled(model.locked || model.songsWithLanes.isEmpty)
            Divider()
            Toggle("Stop After Each Song", isOn: $model.stopAfterEach)
            Toggle("Show Mode (Lock Editing)", isOn: $model.locked)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Audio Output…") { model.outputShown = true }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(model.show == nil)
            Button("Show Info…") { model.showInfoShown = true }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(model.locked || model.show == nil)
            Button("Edit Setlist…") { model.setlistEditorShown = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.locked || model.show == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Song Timeline") { model.toggleTimeline() }
                .keyboardShortcut("t")
            Button("Open or Close Song Timeline") { model.toggleTimeline() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(typing)
            Button("Zoom In") { model.zoomTimeline(by: 2) }
                .keyboardShortcut("=", modifiers: [.command])
                .disabled(model.screen != .timeline)
            Button("Zoom Out") { model.zoomTimeline(by: 0.5) }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(model.screen != .timeline || !model.timelineWindow.isZoomed)
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(model.screen != .timeline || !model.timelineWindow.isZoomed)
            Divider()
            Button("Clock") { model.toggleClock() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Albums") { model.go(.albums) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Now Playing") { model.go(.library) }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Connections") { model.go(.connections) }
                .keyboardShortcut("3", modifiers: [.command])
            Button("Library") { model.go(.library) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(typing)
            Button("Show Issues") { model.issuesShown = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var transport: Transport
    @Namespace private var morph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Screens swap whole, never piece by piece: the one leaving fades out quickly, then the one
    /// arriving settles in with a slight zoom. Going deeper (library → timeline → clock) it comes
    /// from a touch larger, as if you'd stepped in; coming back, from a touch smaller. Nothing
    /// slides across anything else. Reduce Motion: a plain crossfade.
    private static let leave = AnyTransition.opacity.animation(.easeOut(duration: 0.16))

    private func depth(_ screen: Screen) -> Int {
        switch screen {
        case .firstRun: return -1
        case .library, .albums, .connections: return 0
        case .timeline: return 1
        case .clock: return 2
        }
    }

    private var screenTransition: AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeInOut(duration: 0.18)) }
        let deeper = depth(model.screen) >= depth(model.previousScreen)
        let enter = AnyTransition.opacity.combined(with: .scale(scale: deeper ? 1.03 : 0.97))
            .animation(.vivid(0.42).delay(0.05))
        return .asymmetric(insertion: enter, removal: Self.leave)
    }

    /// Pages beside the sidebar: the new page rises a few points as it fades in.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity.animation(.easeInOut(duration: 0.18)) }
        let enter = AnyTransition.opacity.combined(with: .offset(y: 10)).animation(.vivid(0.34).delay(0.03))
        return .asymmetric(insertion: enter, removal: Self.leave)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if model.screen == .clock {
                    Color.black.ignoresSafeArea()
                } else {
                    Ambient(song: model.screen == .firstRun ? nil : model.currentSong)
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            switch model.screen {
            case .firstRun:
                FirstRunView().transition(screenTransition)
            case .clock:
                ClockScreen(morph: morph).transition(screenTransition)
            case .timeline:
                SongTimelineView(morph: morph).transition(screenTransition)
            default:
                // One sidebar for Albums, Now playing and Connections: it stays put while the page
                // beside it changes. The timeline and the clock replace the whole window.
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 224)
                        .padding(10)
                    ZStack {
                        switch model.screen {
                        case .library: LibraryView(morph: morph).transition(pageTransition)
                        case .albums: AlbumsView().transition(pageTransition)
                        case .connections: ConnectionsView().transition(pageTransition)
                        default: EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .transition(screenTransition)
            }
            if let notice = model.notice, model.screen != .firstRun {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Text(notice)
                            .font(.manrope(13.5, .medium))
                            .foregroundStyle(Brand.ink)
                            .multilineTextAlignment(.center)
                        if model.noticeOffersUndo && model.lastFix != nil {
                            Button("Undo") { model.undoFix() }.buttonStyle(QuietButtonStyle())
                        } else if model.noticeOffersMarkerUndo && model.canUndoMarkers {
                            Button("Undo") { model.undoMarkers() }.buttonStyle(QuietButtonStyle())
                        } else if model.noticeUndoAction != nil {
                            Button("Undo") { model.runNoticeUndo() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 620)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.phantom))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                        .padding(.bottom, 28)
                        .onTapGesture { model.notice = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if case .lost(let message) = transport.status, model.screen != .firstRun {
                LostOutputBanner(message: message)
                    .padding(.top, 78)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Brand.window)
        .ignoresSafeArea()
        .animation(.vivid(0.4), value: transport.status)
        .sheet(isPresented: $model.issuesShown) { IssuesSheet().environmentObject(model) }
        .sheet(isPresented: $model.outputShown) {
            OutputSheet().environmentObject(model).environmentObject(transport).environmentObject(model.meters)
        }
        .sheet(isPresented: $model.setlistEditorShown) { SetlistEditor().environmentObject(model) }
        .sheet(isPresented: $model.goToShown) { GoToSheet().environmentObject(model) }
        .sheet(isPresented: $model.showInfoShown) { ShowInfoSheet().environmentObject(model) }
        .sheet(isPresented: $model.addAlbumShown) { AddAlbumSheet().environmentObject(model) }
        .sheet(item: $model.showInfoEntry) { entry in ShowInfoSheet(entry: entry).environmentObject(model) }
        .sheet(item: $model.markerEdit) { edit in RenameMarkerSheet(marker: edit.marker, song: edit.song).environmentObject(model) }
        .sheet(item: $model.laneEdit) { lane in LaneEditor(lane: lane).environmentObject(model).environmentObject(model.control) }
    }
}

/// Alerts are solid, never glass.
struct LostOutputBanner: View {
    @EnvironmentObject private var model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFB4A8))
            Text(message).font(.manrope(13.5, .semibold)).foregroundStyle(Brand.ink)
            Button("Audio output…") { model.outputShown = true }.buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x5A1E1E)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xC4574A), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
