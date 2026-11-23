import Foundation

/// A new edit of a song: lines up the old master with the new one and says what moved. Same
/// music, different arrangement (a bar added, a chorus cut, a longer intro): each stretch of the
/// old master is found in the new one and given its shift, so triggers can follow the music.
/// Nothing is moved here: the report goes to Caiden, who decides.
public enum EditAligner {
    /// A stretch of the old master found in the new one: new time = old time + shift (seconds of file).
    public struct Segment: Equatable, Sendable {
        public var oldStart: Double
        public var oldEnd: Double
        public var shift: Double
    }

    /// What changed between two stretches that line up.
    public struct Change: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// New music in the new edit, this long, at `at`.
            case added(Double)
            /// Old music not in the new edit, this long, from `at`.
            case removed(Double)
            /// Old music that doesn't match anything in the new edit (`old` seconds there,
            /// `new` seconds in its place).
            case changed(old: Double, new: Double)
        }
        /// Old file time where it happens.
        public var at: Double
        public var kind: Kind
    }

    /// Where an old time lands in the new edit (new file time).
    public enum Place: Equatable, Sendable {
        /// Found: the same music.
        case moved(Double)
        /// Its music was cut: the join where the cut is.
        case cut(Double)
        /// Its music changed: a best guess, to check by ear.
        case unsure(Double)

        public var time: Double {
            switch self { case .moved(let t), .cut(let t), .unsure(let t): return t }
        }
    }

    public struct Result: Equatable, Sendable {
        public var segments: [Segment]
        public var oldLength: Double
        public var newLength: Double

        /// The two masters are the same music at the same times (within 2 ms).
        public var isSame: Bool {
            segments.count == 1 && abs(segments[0].shift) < 0.002 && changes.isEmpty
        }

        /// Nothing in the old master was found in the new one.
        public var noMatch: Bool { segments.isEmpty }

        /// Edits, in order. Music added or cut at the very end isn't listed (a longer or shorter
        /// tail moves no triggers) unless triggers sit there; see `place`.
        public var changes: [Change] {
            guard let first = segments.first, let last = segments.last else { return [] }
            var out: [Change] = []
            if first.oldStart > EditAligner.edgeSlack {
                let newGap = first.oldStart + first.shift
                out.append(Change(at: 0, kind: newGap < EditAligner.edgeSlack ? .removed(first.oldStart)
                                                                                : .changed(old: first.oldStart, new: newGap)))
            } else if first.shift > EditAligner.edgeSlack {
                out.append(Change(at: 0, kind: .added(first.shift)))
            }
            for (a, b) in zip(segments, segments.dropFirst()) {
                let oldGap = b.oldStart - a.oldEnd
                let newGap = (b.oldStart + b.shift) - (a.oldEnd + a.shift)
                if oldGap < EditAligner.gapSlack {
                    out.append(Change(at: a.oldEnd, kind: .added(newGap)))
                } else if newGap < EditAligner.gapSlack {
                    out.append(Change(at: a.oldEnd, kind: .removed(oldGap)))
                } else {
                    out.append(Change(at: a.oldEnd, kind: .changed(old: oldGap, new: newGap)))
                }
            }
            if oldLength - last.oldEnd > EditAligner.edgeSlack {
                let newTail = newLength - (last.oldEnd + last.shift)
                out.append(Change(at: last.oldEnd, kind: newTail < EditAligner.edgeSlack
                                  ? .removed(oldLength - last.oldEnd)
                                  : .changed(old: oldLength - last.oldEnd, new: newTail)))
            }
            return out
        }

        /// Where old file time `t` lands in the new edit.
        public func place(_ t: Double) -> Place {
            guard let first = segments.first, let last = segments.last else { return .unsure(t) }
            if t < first.oldStart {
                // Before the first match: the same distance before it, sure only close to it.
                let p = t + first.shift
                return first.oldStart - t <= EditAligner.edgeSlack || first.oldStart <= EditAligner.edgeSlack
                    ? .moved(max(0, p)) : .unsure(max(0, p))
            }
            for (i, s) in segments.enumerated() {
                if t <= s.oldEnd { return .moved(t + s.shift) }
                if i + 1 < segments.count, t < segments[i + 1].oldStart {
                    let b = segments[i + 1]
                    let oldGap = b.oldStart - s.oldEnd
                    let newGap = (b.oldStart + b.shift) - (s.oldEnd + s.shift)
                    let join = s.oldEnd + s.shift
                    if newGap < EditAligner.gapSlack { return .cut(join) }
                    return .unsure(join + (t - s.oldEnd) / oldGap * newGap)
                }
            }
            let p = t + last.shift
            return t - last.oldEnd <= EditAligner.edgeSlack ? .moved(p) : .unsure(p)
        }
    }

    /// Unmatched stretches shorter than this at the start or end aren't worth a word.
    static let edgeSlack = 0.25
    /// A gap this small between two stretches is a clean join (an edit point), not missing music.
    static let gapSlack = 0.06

    // MARK: Lining up

    /// Lines up an old master with a new one (mono, any sample rates).
    public static func align(old: [Float], oldRate: Double, new: [Float], newRate: Double) -> Result {
        let po = blockPower(old, rate: oldRate), pn = blockPower(new, rate: newRate)
        let oldLength = Double(old.count) / oldRate, newLength = Double(new.count) / newRate
        let fine = Envelopes(po), fineNew = Envelopes(pn)
        var segments = coarseRuns(fine, fineNew)
        segments = refineEdges(segments, fine.e100, fineNew.e100)
        segments = refineShifts(segments, fine.e1k, fineNew.e1k)
        return Result(segments: segments, oldLength: oldLength, newLength: newLength)
    }

    /// Mean power in each millisecond.
    static func blockPower(_ x: [Float], rate: Double) -> [Float] {
        let per = rate / 1000
        let n = Int(Double(x.count) / per)
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { b in
            for j in 0..<n {
                let a = Int(Double(j) * per), e = min(x.count, Int(Double(j + 1) * per))
                guard e > a else { continue }
                var s: Float = 0
                for i in a..<e { s += b[i] * b[i] }
                out[j] = s / Float(e - a)
            }
        }
        return out
    }

    /// Loudness (dB) at 1000, 100 and 20 a second.
    struct Envelopes {
        let e1k: [Float], e100: [Float], e20: [Float]
        init(_ p1k: [Float]) {
            e1k = p1k.map(EditAligner.db)
            e100 = EditAligner.pool(p1k, 10).map(EditAligner.db)
            e20 = EditAligner.pool(p1k, 50).map(EditAligner.db)
        }
    }

    static func db(_ p: Float) -> Float { 10 * log10(max(p, 1e-8)) }   // floor at -80 dB

    static func pool(_ p: [Float], _ k: Int) -> [Float] {
        let n = p.count / k
        return (0..<n).map { i in
            var s: Float = 0
            for j in i * k..<(i + 1) * k { s += p[j] }
            return s / Float(k)
        }
    }

    /// Normalised correlation of `a[i..<i+n]` with `b[j..<j+n]`; nil where either is flat.
    static func ncc(_ a: [Float], _ i: Int, _ b: [Float], _ j: Int, _ n: Int) -> Float? {
        guard i >= 0, j >= 0, i + n <= a.count, j + n <= b.count, n > 1 else { return nil }
        var ma: Float = 0, mb: Float = 0
        for k in 0..<n { ma += a[i + k]; mb += b[j + k] }
        ma /= Float(n); mb /= Float(n)
        var sab: Float = 0, saa: Float = 0, sbb: Float = 0
        for k in 0..<n {
            let x = a[i + k] - ma, y = b[j + k] - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        guard saa > Float(n) * 0.25, sbb > Float(n) * 0.25 else { return nil }   // under ~0.5 dB of movement
        return sab / (saa * sbb).squareRoot()
    }

    /// 4-second windows of the old master, 2 seconds apart, each found in the new one (20 a
    /// second), then refined to 10 ms; neighbours with the same shift become one stretch.
    static func coarseRuns(_ o: Envelopes, _ n: Envelopes) -> [Segment] {
        let win = 80, hop = 40
        let a = o.e20, b = n.e20
        guard a.count >= win, b.count >= win else { return [] }
        var starts = Array(stride(from: 0, through: a.count - win, by: hop))
        if let l = starts.last, l < a.count - win { starts.append(a.count - win) }

        enum Found { case at(Int), silent, none }
        var found: [Found] = []
        var lastShift: Int?          // in 100ths of a second
        for i in starts {
            // Flat (silence, a held pad): can't be placed by itself; takes its neighbours' shift.
            guard ncc(a, i, a, i, win) != nil else { found.append(.silent); continue }
            var pick: Int?
            if let s = lastShift {
                // The same shift as before, if the music still matches there: repeated choruses
                // must not pull a window onto the wrong repeat.
                let p0 = Int((Double(i * 5 + s) / 5).rounded())
                var best: (p: Int, c: Float)?
                for p in (p0 - 2)...(p0 + 2) {
                    if let c = ncc(a, i, b, p, win), c > (best?.c ?? -2) { best = (p, c) }
                }
                if let best, best.c >= 0.85 { pick = best.p }
            }
            if pick == nil {
                var scores: [(p: Int, c: Float)] = []
                for p in 0...max(0, b.count - win) {
                    if let c = ncc(a, i, b, p, win) { scores.append((p, c)) }
                }
                // A new edit is the same recording: the true spot matches almost perfectly, and
                // anything under 0.8 is music that only looks alike.
                if let top = scores.max(by: { $0.c < $1.c }), top.c >= 0.8 {
                    // Among near-equal matches (a repeat), the one closest to where it was.
                    let expected = lastShift.map { Double(i) + Double($0) / 5 } ?? Double(i)
                    pick = scores.filter { $0.c >= top.c - 0.02 }
                        .min(by: { abs(Double($0.p) - expected) < abs(Double($1.p) - expected) })?.p
                }
            }
            guard let p = pick else { found.append(.none); continue }
            // To 10 ms: ±8 hundredths around the coarse spot.
            let i100 = i * 5, p100 = p * 5
            var best = (s: p100 - i100, c: Float(-2))
            for d in -8...8 {
                if let c = ncc(o.e100, i100, n.e100, p100 + d, win * 5), c > best.c { best = (p100 + d - i100, c) }
            }
            found.append(.at(best.s))
            lastShift = best.s
        }

        // Silent windows take the shift on either side when both agree (or the only side there is).
        var shifts: [Int?] = found.map { if case .at(let s) = $0 { return s } else { return nil } }
        for k in shifts.indices {
            guard case .silent = found[k] else { continue }
            let before = shifts[..<k].last(where: { $0 != nil }) ?? nil
            let after = shifts[(k + 1)...].first(where: { $0 != nil }) ?? nil
            switch (before, after) {
            case let (x?, y?) where abs(x - y) <= 3: shifts[k] = x
            case let (x?, nil): shifts[k] = x
            case let (nil, y?): shifts[k] = y
            default: break
            }
        }

        // Runs of the same shift (within 30 ms).
        var runs: [(from: Int, to: Int, shifts: [Int])] = []
        for (k, s) in shifts.enumerated() {
            guard let s else { continue }
            if var last = runs.last, last.to == k - 1, let m = last.shifts.last, abs(m - s) <= 3 {
                last.to = k; last.shifts.append(s)
                runs[runs.count - 1] = last
            } else {
                runs.append((k, k, [s]))
            }
        }
        // One window on its own, against the rest, is more likely a look-alike than the music.
        if starts.count >= 3 { runs.removeAll { $0.from == $0.to } }
        return runs.map { r in
            let sorted = r.shifts.sorted()
            return Segment(oldStart: Double(starts[r.from]) / 20, oldEnd: Double(starts[r.to] + win) / 20,
                           shift: Double(sorted[sorted.count / 2]) / 100)
        }
    }

    /// Finds each edit point to 10 ms. Between two stretches (shift a, then b), the music
    /// matches the new edit at a up to some point c1 and at b from some point c2: c1 and c2 are
    /// chosen so as much music as possible matches, with what's between them unmatched.
    static func refineEdges(_ segs: [Segment], _ a: [Float], _ b: [Float]) -> [Segment] {
        guard segs.count > 1 else { return clampEnds(segs, a.count) }
        var out = segs
        let unmatched: Float = 4      // dB: worse than this, the music isn't the same
        func err(_ t: Int, _ s: Int) -> Float {
            let j = t + s
            guard t >= 0, t < a.count, j >= 0, j < b.count else { return 12 }
            return min(12, abs(a[t] - b[j]))
        }
        for k in 0..<(out.count - 1) {
            let sa = Int((out[k].shift * 100).rounded()), sb = Int((out[k + 1].shift * 100).rounded())
            // From 4 s before the first stretch ends to 4 s after the next one starts.
            let lo = max(0, Int((min(out[k].oldEnd, out[k + 1].oldStart) * 100).rounded()) - 400)
            let hi = min(a.count, Int((max(out[k].oldEnd, out[k + 1].oldStart) * 100).rounded()) + 400)
            // Past 40 s of searching (a long changed section), the 2-second windows will do.
            guard hi > lo + 1, hi - lo <= 4000 else { continue }
            let n = hi - lo
            // Running totals: matching at a up to c1, at b from c2.
            var ca = [Float](repeating: 0, count: n + 1), cb = [Float](repeating: 0, count: n + 1)
            for t in 0..<n {
                ca[t + 1] = ca[t] + err(lo + t, sa)
                cb[t + 1] = cb[t] + err(lo + t, sb)
            }
            var best = (c1: 0, c2: 0, cost: Float.infinity)
            for c1 in 0...n {
                // The new edit runs forward: what comes after the join can't land before it.
                let minC2 = max(c1, c1 + sa - sb)
                guard minC2 <= n else { continue }
                for c2 in minC2...n {
                    let cost = ca[c1] + (cb[n] - cb[c2]) + unmatched * Float(c2 - c1 - max(0, sa - sb))
                    if cost < best.cost { best = (c1, c2, cost) }
                }
            }
            out[k].oldEnd = Double(lo + best.c1) / 100
            out[k + 1].oldStart = Double(lo + best.c2) / 100
        }
        return clampEnds(out.filter { $0.oldEnd > $0.oldStart }, a.count)
    }

    /// The first stretch from the very start and the last to the very end, when they reach
    /// within a window of them.
    static func clampEnds(_ segs: [Segment], _ count100: Int) -> [Segment] {
        var out = segs
        if let f = out.first, f.oldStart <= 2.05 { out[0].oldStart = 0 }
        let end = Double(count100) / 100
        if let l = out.last, end - l.oldEnd <= 2.05 { out[out.count - 1].oldEnd = end }
        return out
    }

    /// Each stretch's shift to the millisecond, from the middle of the stretch.
    static func refineShifts(_ segs: [Segment], _ a: [Float], _ b: [Float]) -> [Segment] {
        segs.map { seg in
            var s = seg
            let len = min(4000, Int(((seg.oldEnd - seg.oldStart) * 1000).rounded()) - 40)
            guard len > 200 else { return s }
            let mid = Int(((seg.oldStart + seg.oldEnd) / 2 * 1000).rounded())
            let i = mid - len / 2
            let base = Int((seg.shift * 1000).rounded())
            var best = (d: base, c: Float(-2))
            for d in (base - 12)...(base + 12) {
                if let c = ncc(a, i, b, i + d, len), c > best.c { best = (d, c) }
            }
            if best.c > -2 { s.shift = Double(best.d) / 1000 }
            return s
        }
    }
}

/// What a new edit does to one song: where its start, triggers, markers and beat grid go.
/// Worked out, shown, and only applied when Caiden says so.
public struct NewEditPlan: Equatable, Sendable {
    /// Where the song's start falls in the new master.
    public var fileOffset: Double
    public var oldFileOffset: Double
    /// Each marker's new place, in frames from the song's start.
    public var frames: [UUID: Int]
    /// Markers whose time changes, ones that stay, ones whose music was cut (moved to the
    /// join), and ones in music that changed (a best guess).
    public var moved: [UUID] = [], unchanged: [UUID] = [], cut: [UUID] = [], unsure: [UUID] = []
    public var beatGrid: BeatGrid?
    /// The edits, in song time (seconds from the song's start in the old master).
    public var changes: [EditAligner.Change]
    public var noMatch: Bool

    /// Nothing to do: same music, same times.
    public var isSame: Bool { !noMatch && changes.isEmpty && moved.isEmpty && abs(fileOffset - oldFileOffset) < 0.002 }

    public init(song: Song, result r: EditAligner.Result) {
        let fps = song.rate.framesPerSecond
        oldFileOffset = song.fileOffset
        noMatch = r.noMatch
        let startPlace = r.place(song.fileOffset)
        let offset = noMatch ? song.fileOffset : startPlace.time
        fileOffset = offset
        frames = [:]
        for m in song.markers {
            let old = m.time.frames(since: song.start)
            let place = r.place(Double(old) / fps + song.fileOffset)
            let f = Int(((place.time - offset) * fps).rounded())
            frames[m.id] = f
            switch place {
            case .cut: cut.append(m.id)
            case .unsure: unsure.append(m.id)
            case .moved: if f == old { unchanged.append(m.id) } else { moved.append(m.id) }
            }
        }
        if var g = song.beatGrid {
            g.downbeat = r.place(g.downbeat + song.fileOffset).time - offset
            g.driftsAt = g.driftsAt.map { r.place($0 + song.fileOffset).time - offset }
            beatGrid = g
        }
        // In song time; the lead-in before the start is the start moving, said on its own.
        changes = r.changes.compactMap { c in
            var c = c
            c.at -= song.fileOffset
            if c.at < -EditAligner.gapSlack { return nil }
            if c.at < EditAligner.gapSlack, case .added = c.kind, abs(offset - song.fileOffset) > 0.002 { return nil }
            return c
        }
    }

    /// The song as the new edit has it (the master path is set by the caller).
    public func apply(to song: Song) -> Song {
        var s = song
        guard !noMatch else { return s }
        s.fileOffset = max(0, fileOffset)
        for i in s.markers.indices {
            if let f = frames[s.markers[i].id] { s.markers[i].time = song.start.adding(frames: f) }
        }
        if let g = beatGrid { s.beatGrid = g }
        return s
    }

    /// Plain lines for Caiden: what changed, then what happens to the triggers.
    public func summary() -> [String] {
        if noMatch { return ["The new master doesn't sound like the old one anywhere. Nothing would move."] }
        var lines: [String] = []
        let lead = fileOffset - oldFileOffset
        if abs(lead) >= 0.002 {
            lines.append("The song starts \(Self.secs(abs(lead))) \(lead > 0 ? "later" : "earlier") in the new file "
                         + "(\(lead > 0 ? "a longer" : "a shorter") lead-in). The start follows it.")
        }
        for c in changes {
            let at = HitSheet.songTime(c.at)
            switch c.kind {
            case .added(let d):
                lines.append("\(Self.secs(d)) added at \(at): everything after is \(Self.secs(d)) later.")
            case .removed(let d):
                lines.append("\(Self.secs(d)) cut at \(at): everything after is \(Self.secs(d)) earlier.")
            case .changed(let o, let n):
                lines.append("\(at) to \(HitSheet.songTime(c.at + o)) is different music (\(Self.secs(o)) became \(Self.secs(n))).")
            }
        }
        if lines.isEmpty { lines.append("Same music at the same times. Nothing moves.") }
        var t = (moved.count == 1 ? "1 trigger or marker moves" : "\(moved.count) triggers and markers move")
            + ", " + (unchanged.count == 1 ? "1 stays put." : "\(unchanged.count) stay put.")
        if moved.isEmpty && unchanged.isEmpty { t = "" }
        if !cut.isEmpty { t += " \(cut.count) \(cut.count == 1 ? "was" : "were") in music that was cut: \(cut.count == 1 ? "it goes" : "they go") to the join." }
        if !unsure.isEmpty { t += " \(unsure.count) \(unsure.count == 1 ? "is" : "are") in music that changed: placed by guess, check by ear." }
        if !t.isEmpty { lines.append(t.trimmingCharacters(in: .whitespaces)) }
        return lines
    }

    /// "4.00 s"
    static func secs(_ s: Double) -> String { String(format: "%.2f s", s) }
}
