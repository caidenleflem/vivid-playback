import Foundation

public enum SetlistSort: String, CaseIterable, Sendable {
    case setlist, number, title, start, length

    public var displayName: String {
        switch self {
        case .setlist: return "Setlist order"
        case .number: return "Song number"
        case .title: return "Title"
        case .start: return "Timecode start"
        case .length: return "Length"
        }
    }
}

extension Setlist {
    /// The setlist's songs in `sort` order (a view; the setlist itself isn't changed).
    /// Songs without the value sort last; ties keep setlist order.
    public func songIDs(sortedBy sort: SetlistSort, in show: Show) -> [UUID] {
        guard sort != .setlist else { return songIDs }
        let indexed = songIDs.enumerated().compactMap { i, id in show.song(id: id).map { (i, $0) } }
        func before(_ a: (Int, Song), _ b: (Int, Song)) -> Bool {
            switch sort {
            case .setlist: return a.0 < b.0
            case .number:
                switch (a.1.number, b.1.number) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.0 < b.0
                }
            case .title:
                let c = a.1.title.localizedStandardCompare(b.1.title)
                return c == .orderedSame ? a.0 < b.0 : c == .orderedAscending
            case .start:
                switch (a.1.hasTimecode, b.1.hasTimecode) {
                case (true, false): return true
                case (false, true): return false
                case (false, false): return a.0 < b.0
                default: return a.1.start.seconds == b.1.start.seconds ? a.0 < b.0 : a.1.start.seconds < b.1.start.seconds
                }
            case .length:
                switch (a.1.length, b.1.length) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.0 < b.0
                }
            }
        }
        return indexed.sorted(by: before).map(\.1.id)
    }

    /// Moves `ids` (kept in their current order) to sit just before `target`, or to the end
    /// when `target` is nil.
    public mutating func move(_ ids: [UUID], before target: UUID?) {
        let moving = songIDs.filter(ids.contains)
        guard !moving.isEmpty else { return }
        var rest = songIDs.filter { !ids.contains($0) }
        let at = target.flatMap { t in rest.firstIndex(of: t) } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        songIDs = rest
    }

    /// Takes a song out of this setlist (it stays in the show and in other setlists).
    public mutating func remove(_ id: UUID) {
        songIDs.removeAll { $0 == id }
        skipped.remove(id)
    }

    /// Puts a song back at the end of this setlist.
    public mutating func add(_ id: UUID) {
        guard !songIDs.contains(id) else { return }
        songIDs.append(id)
    }

    public mutating func moveUp(_ id: UUID) {
        guard let i = songIDs.firstIndex(of: id), i > 0 else { return }
        songIDs.swapAt(i, i - 1)
    }

    public mutating func moveDown(_ id: UUID) {
        guard let i = songIDs.firstIndex(of: id), i + 1 < songIDs.count else { return }
        songIDs.swapAt(i, i + 1)
    }

    /// Total running time of the songs played tonight.
    public func duration(in show: Show) -> Double {
        songIDs.filter { !skipped.contains($0) }.compactMap { show.song(id: $0)?.length }.reduce(0, +)
    }
}

/// The shows saved on this Mac.
public enum ShowLibrary {
    public struct Entry: Identifiable, Sendable {
        public var id: String { url.path }
        public let url: URL
        public let show: Show

        public init(url: URL, show: Show) {
            self.url = url
            self.show = show
        }
    }

    public static func list(in folder: URL) -> [Entry] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension == ShowStore.fileExtension }
            .compactMap { url in (try? ShowStore.load(from: url)).map { Entry(url: url, show: $0) } }
            .sorted { ($0.show.artist ?? $0.show.name).localizedStandardCompare($1.show.artist ?? $1.show.name) == .orderedAscending }
    }

    /// Where a new show called `name` can be saved in `folder` without replacing one already
    /// there: "Name.vividshow", then "Name 2.vividshow", "Name 3.vividshow"…
    public static func uniquePackageURL(named name: String, in folder: URL,
                                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Show" + base }
        func url(_ n: Int) -> URL {
            folder.appendingPathComponent(n == 1 ? "\(base).\(ShowStore.fileExtension)" : "\(base) \(n).\(ShowStore.fileExtension)")
        }
        var n = 1
        while exists(url(n)) && n < 10_000 { n += 1 }
        return url(n)
    }

    /// Copies an image into the show package as a setlist's cover; returns its path in the package.
    public static func storeArtwork(_ image: URL, for setlist: Setlist, in package: URL) throws -> String {
        let folder = package.appendingPathComponent("Artwork")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = image.pathExtension.isEmpty ? "png" : image.pathExtension.lowercased()
        let name = "\(setlist.id.uuidString).\(ext)"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: image, to: dest)
        return "Artwork/\(name)"
    }
}
