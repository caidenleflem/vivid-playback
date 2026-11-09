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
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { PlaybackCommands(model: model) }
    }
}

struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Show…") { model.newShow() }
                .keyboardShortcut("n")
            Button("Open Show…") { model.openShowPanel() }
                .keyboardShortcut("o")
            Button("Import Show Folder…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Playback") {
            Button("Play or Pause") { model.transport.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Song") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Song") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Back to the Top of the Song") { model.transport.locate(0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Divider()
            Button("Add Marker") { model.addMarker() }
                .keyboardShortcut("m", modifiers: [])
        }
        CommandGroup(before: .toolbar) {
            Button("Song Timeline") { model.toggleTimeline() }
                .keyboardShortcut("t")
            Button("Open or Close Song Timeline") { model.toggleTimeline() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Clock") { model.toggleClock() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Library") { model.go(.library) }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Show Issues") { model.issuesShown = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var morph

    var body: some View {
        ZStack {
            if model.screen == .clock {
                Color.black.ignoresSafeArea()
            } else {
                Ambient(song: model.screen == .firstRun ? nil : model.currentSong)
            }
            switch model.screen {
            case .firstRun:
                FirstRunView().transition(.opacity)
            case .library:
                LibraryView(morph: morph)
            case .timeline:
                SongTimelineView(morph: morph)
            case .clock:
                ClockScreen(morph: morph).transition(.opacity)
            }
        }
        .background(Brand.window)
        .ignoresSafeArea()
        .sheet(isPresented: $model.issuesShown) { IssuesSheet().environmentObject(model) }
    }
}
