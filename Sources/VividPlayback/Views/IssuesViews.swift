import SwiftUI
import PlaybackCore

/// One finding: what's wrong, in full, and Hide (warnings only) or Show again.
struct IssueRow: View {
    @EnvironmentObject private var model: AppModel
    let issue: ShowIssue
    var hidden = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(color: hidden ? Brand.graphite : (issue.severity == .error ? Color(hex: 0xE5675A) : Brand.warn))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.manrope(14, .semibold)).foregroundStyle(hidden ? Brand.space : Brand.ink)
                Text(issue.message).font(.manrope(13)).foregroundStyle(Brand.steel)
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.canDismiss && !hidden {
                    Text("Needs fixing before the show; it can't be hidden.")
                        .font(.manrope(11.5)).foregroundStyle(Brand.graphite)
                }
            }
            Spacer(minLength: 8)
            if hidden {
                Button("Show again") { model.restore(issue) }.buttonStyle(QuietButtonStyle())
            } else if issue.canDismiss {
                Button("Hide") { model.dismiss(issue) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Hide this warning. It comes back if the problem changes.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.solid))
    }
}

/// What's wrong with one song: shown from its status in the list or its timeline.
struct SongIssuesPopover: View {
    @EnvironmentObject private var model: AppModel
    let song: Song
    @State private var showHidden = false

    var body: some View {
        let active = model.issues(for: song)
        let hidden = model.hiddenIssues(for: song)
        VStack(alignment: .leading, spacing: 10) {
            Text(song.title).font(.manrope(16, .semibold)).foregroundStyle(Brand.ink)
            if active.isEmpty {
                Text(hidden.isEmpty ? "Nothing to check on this song." : "Nothing to check. Hidden warnings are below.")
                    .font(.manrope(13)).foregroundStyle(Brand.steel)
            }
            ForEach(active.sorted { $0.severity > $1.severity }) { IssueRow(issue: $0) }
            if !hidden.isEmpty {
                Button(showHidden ? "Hide the hidden warnings" : "\(hidden.count) hidden \(hidden.count == 1 ? "warning" : "warnings")") {
                    withAnimation(.vivid(0.3)) { showHidden.toggle() }
                }
                .buttonStyle(.plain)
                .font(.manrope(12.5, .medium))
                .foregroundStyle(Brand.space)
                if showHidden { ForEach(hidden) { IssueRow(issue: $0, hidden: true) } }
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Brand.phantom)
        .preferredColorScheme(.dark)
    }
}

/// Every finding in the show, song by song, with the hidden ones at the end.
struct IssuesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let active = model.activeIssues
        let hidden = model.hiddenIssues
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Things to check").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.defaultAction)
            }
            if active.isEmpty {
                Text(hidden.isEmpty
                     ? "Everything lines up. Every song has its master and timecode, and the timecode matches the sheet."
                     : "Nothing left to check. \(hidden.count) hidden \(hidden.count == 1 ? "warning is" : "warnings are") below.")
                    .font(.manrope(14)).foregroundStyle(Brand.steel)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(groups(active).enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title).font(.manrope(13, .bold)).foregroundStyle(Brand.ink)
                                Spacer()
                                if group.issues.filter(\.canDismiss).count > 1 {
                                    Button("Hide all warnings") { group.issues.filter(\.canDismiss).forEach(model.dismiss) }
                                        .buttonStyle(.plain).font(.manrope(12)).foregroundStyle(Brand.space)
                                }
                            }
                            ForEach(group.issues) { IssueRow(issue: $0) }
                        }
                    }
                    if !hidden.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HIDDEN").font(.manrope(11, .bold)).tracking(1.1).foregroundStyle(Brand.graphite)
                            ForEach(hidden) { IssueRow(issue: $0, hidden: true) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
        .background(Brand.phantom)
    }

    /// By song, in setlist order; findings about the whole show last.
    private func groups(_ issues: [ShowIssue]) -> [(title: String, issues: [ShowIssue])] {
        var out: [(title: String, issues: [ShowIssue])] = []
        for song in model.setlistSongs {
            let mine = issues.filter { $0.songID == song.id }.sorted { $0.severity > $1.severity }
            if !mine.isEmpty { out.append((song.title, mine)) }
        }
        let listed = Set(model.setlistSongs.map(\.id))
        let rest = issues.filter { $0.songID == nil || !listed.contains($0.songID!) }
        if !rest.isEmpty { out.append(("Other", rest)) }
        return out
    }
}
