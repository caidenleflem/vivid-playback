import SwiftUI
import PlaybackCore

/// One screen: drop the show folder. Everything else is found and checked for you.
struct FirstRunView: View {
    @EnvironmentObject private var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Emblem(width: 54)
            switch model.importState {
            case .idle, .failed:
                dropPrompt
            case .running(let step):
                progress(step)
            case .finished(let report):
                results(report)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 40)
        .padding(.bottom, 36)
        .frame(width: 640)
        .glass(cornerRadius: 24, alpha: 0.64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.importFolder(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var dropPrompt: some View {
        VStack(spacing: 18) {
            Text("Drop your show folder here")
                .font(.manrope(32, .semibold))
                .foregroundStyle(Brand.ink)
            Text("Put the offset sheet, the masters and the timecode files in one folder. Vivid Playback matches them up and checks every song.")
                .font(.manrope(14.5))
                .foregroundStyle(Brand.steel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.champagne)
                Text("Folder, sheet or audio files").font(.manrope(13)).foregroundStyle(Brand.space)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Brand.champagne.opacity(targeted ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(targeted ? 0.05 : 0)))
            )
            .animation(.smooth(duration: 0.2), value: targeted)
            if case .failed(let message) = model.importState {
                Text(message)
                    .font(.manrope(13))
                    .foregroundStyle(Brand.warn)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                Button("Choose folder…") { model.chooseFolder() }
                    .buttonStyle(QuietButtonStyle())
                Button("Try the example show") { model.tryExampleShow() }
                    .buttonStyle(QuietButtonStyle(prominent: true))
            }
        }
    }

    private func progress(_ step: ImportStep) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text(stepText(step)).font(.manrope(14)).foregroundStyle(Brand.steel)
        }
        .frame(height: 220)
    }

    private func stepText(_ step: ImportStep) -> String {
        switch step {
        case .scanning: return "Looking through the folder…"
        case .readingSheet(let name): return "Reading \(name)…"
        case .matching: return "Matching masters and timecode files…"
        case .checking(let song, let i, let n): return "Checking \(song) (\(i) of \(n))…"
        case .done: return "Done."
        }
    }

    private func results(_ report: ImportReport) -> some View {
        let n = report.show.songs.count
        let findings = report.issues.sorted { $0.severity > $1.severity }
        return VStack(spacing: 14) {
            Text(report.show.name).font(.manrope(32, .semibold)).foregroundStyle(Brand.ink)
            ScrollView {
                VStack(spacing: 8) {
                    checkRow(ok: report.sheetProblems.isEmpty, title: "Offset sheet",
                             detail: "\(report.sheetURL?.lastPathComponent ?? "") · \(n) songs, \(report.show.defaultRate.displayName)")
                    ForEach(report.sheetProblems, id: \.self) { checkRow(ok: false, title: "In the sheet", detail: $0) }
                    checkRow(ok: report.masterCount == n, title: "Masters", detail: "\(report.masterCount) of \(n) matched")
                    checkRow(ok: report.timecodeCount == n, title: "Timecode", detail: "\(report.timecodeCount) of \(n) matched and read")
                    ForEach(report.ambiguities, id: \.self) { checkRow(ok: false, title: "Pick a file", detail: $0) }
                    ForEach(findings) { checkRow(ok: false, title: $0.title, detail: $0.message) }
                    if !report.unmatchedFiles.isEmpty {
                        checkRow(ok: true, neutral: true, title: "Not used",
                                 detail: report.unmatchedFiles.prefix(6).joined(separator: ", ") + (report.unmatchedFiles.count > 6 ? "…" : ""))
                    }
                }
            }
            .frame(maxHeight: 360)
            Text(summary(report)).font(.manrope(14)).foregroundStyle(Brand.steel)
            HStack(spacing: 10) {
                Button("Start over") { model.importState = .idle }
                    .buttonStyle(QuietButtonStyle())
                Button("Open show") { model.openImported(report) }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ report: ImportReport) -> String {
        let n = report.show.songs.count
        let ready = report.readyCount
        if ready == n { return n == 1 ? "1 song ready." : "All \(n) songs ready." }
        let review = n - ready
        return "\(ready) \(ready == 1 ? "song" : "songs") ready. \(review) to review."
    }

    private func checkRow(ok: Bool, neutral: Bool = false, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill((neutral ? Brand.graphite : ok ? Brand.ok : Brand.warn).opacity(0.18))
                Text(neutral ? "–" : ok ? "✓" : "!").font(.manrope(12, .heavy))
                    .foregroundStyle(neutral ? Brand.steel : ok ? Brand.ok : Brand.warn)
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                Text(detail).font(.manrope(12.5)).foregroundStyle(Brand.space).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.28)))
    }
}

struct IssuesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Things to check").font(.manrope(22, .semibold)).foregroundStyle(Brand.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.defaultAction)
            }
            if model.issues.isEmpty {
                Text("Everything lines up. Every song has its master and timecode, and the timecode matches the sheet.")
                    .font(.manrope(14)).foregroundStyle(Brand.steel)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.issues.sorted { $0.severity > $1.severity }) { issue in
                            HStack(alignment: .top, spacing: 12) {
                                StatusDot(color: issue.severity == .error ? Color(hex: 0xE5675A) : Brand.warn).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.title).font(.manrope(14, .semibold)).foregroundStyle(Brand.ink)
                                    Text(issue.message).font(.manrope(13)).foregroundStyle(Brand.steel)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.solid))
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(Brand.phantom)
    }
}
