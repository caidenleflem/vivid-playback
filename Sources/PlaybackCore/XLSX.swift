import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Raw DEFLATE (RFC 1951) decoding, enough to open .xlsx files without a dependency.
/// A straightforward port of zlib's reference decoder, "puff".
enum Inflate {
    struct Failure: Error {}

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            count[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = sym
                offs[l] += 1
            }
        }
    }

    private struct Reader {
        let input: [UInt8]
        var pos = 0
        var bitBuffer = 0
        var bitCount = 0

        mutating func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < input.count else { throw Failure() }
                bitBuffer |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            let v = bitBuffer & ((1 << n) - 1)
            bitBuffer >>= n
            bitCount -= n
            return v
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure()
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let fixedLength = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
    private static let fixedDistance = Huffman(lengths: [Int](repeating: 5, count: 30))

    static func decompress(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        var r = Reader(input: input)
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize)
        var last = 0
        repeat {
            last = try r.bits(1)
            switch try r.bits(2) {
            case 0:
                r.bitBuffer = 0
                r.bitCount = 0
                guard r.pos + 4 <= input.count else { throw Failure() }
                let len = Int(input[r.pos]) | Int(input[r.pos + 1]) << 8
                r.pos += 4
                guard r.pos + len <= input.count else { throw Failure() }
                out.append(contentsOf: input[r.pos..<r.pos + len])
                r.pos += len
            case 1:
                try codes(&r, &out, fixedLength, fixedDistance)
            case 2:
                let nlen = try r.bits(5) + 257, ndist = try r.bits(5) + 1, ncode = try r.bits(4) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var lengths = [Int](repeating: 0, count: 19)
                for i in 0..<ncode { lengths[order[i]] = try r.bits(3) }
                let lencode = Huffman(lengths: lengths)
                var all: [Int] = []
                while all.count < nlen + ndist {
                    let sym = try r.decode(lencode)
                    if sym < 16 { all.append(sym); continue }
                    var value = 0, repeatCount = 0
                    switch sym {
                    case 16:
                        guard let prev = all.last else { throw Failure() }
                        value = prev; repeatCount = 3 + (try r.bits(2))
                    case 17: repeatCount = 3 + (try r.bits(3))
                    default: repeatCount = 11 + (try r.bits(7))
                    }
                    all += [Int](repeating: value, count: repeatCount)
                }
                guard all.count == nlen + ndist else { throw Failure() }
                try codes(&r, &out, Huffman(lengths: Array(all[0..<nlen])), Huffman(lengths: Array(all[nlen...])))
            default:
                throw Failure()
            }
        } while last == 0
        return out
    }

    private static func codes(_ r: inout Reader, _ out: inout [UInt8], _ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            var sym = try r.decode(lencode)
            if sym < 256 { out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            sym -= 257
            guard sym < 29 else { throw Failure() }
            let len = lengthBase[sym] + (try r.bits(lengthExtra[sym]))
            let dsym = try r.decode(distcode)
            guard dsym < 30 else { throw Failure() }
            let dist = distBase[dsym] + (try r.bits(distExtra[dsym]))
            guard dist <= out.count else { throw Failure() }
            let start = out.count - dist
            for i in 0..<len { out.append(out[start + i]) }
        }
    }
}

/// Reads the files in a .zip archive (stored or deflated; no ZIP64).
struct ZipArchive {
    let data: [UInt8]
    private(set) var entries: [String: (method: Int, compressed: Int, size: Int, localOffset: Int)] = [:]

    init(_ data: Data) throws {
        self.data = [UInt8](data)
        let d = self.data
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard d.count >= 22 else { throw Inflate.Failure() }
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 65_557) {
            if u32(i) == 0x06054B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Inflate.Failure() }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(p) == 0x02014B50 else { throw Inflate.Failure() }
            let nameLen = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32)
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = (u16(p + 10), u32(p + 20), u32(p + 24), u32(p + 42))
            p += 46 + nameLen + extra + comment
        }
    }

    func file(_ name: String) throws -> [UInt8]? {
        guard let e = entries[name] else { return nil }
        let d = data
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        let start = e.localOffset + 30 + u16(e.localOffset + 26) + u16(e.localOffset + 28)
        guard start + e.compressed <= d.count else { throw Inflate.Failure() }
        let raw = Array(d[start..<(start + e.compressed)])
        switch e.method {
        case 0: return raw
        case 8: return try Inflate.decompress(raw, expectedSize: e.size)
        default: throw Inflate.Failure()
        }
    }
}

/// Reads the first worksheet of an Excel .xlsx file into rows of text.
public enum XLSXReader {
    public static func table(from data: Data) throws -> [[String]] {
        let zip = try ZipArchive(data)
        let shared = try zip.file("xl/sharedStrings.xml").map { SharedStrings.parse(Data($0)) } ?? []
        var sheetPath = "xl/worksheets/sheet1.xml"
        if let wb = try zip.file("xl/workbook.xml"), let rels = try zip.file("xl/_rels/workbook.xml.rels"),
           let id = FirstSheet.parse(Data(wb)), let target = Relationships.parse(Data(rels))[id] {
            sheetPath = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }
        guard let sheet = try zip.file(sheetPath) else { throw Inflate.Failure() }
        return SheetCells.parse(Data(sheet), shared: shared)
    }

    /// "B" → 1, "AA" → 26.
    static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inText = false
        static func parse(_ data: Data) -> [String] {
            let d = SharedStrings()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.strings
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current) }
        }
    }

    private final class FirstSheet: NSObject, XMLParserDelegate {
        var id: String?
        static func parse(_ data: Data) -> String? {
            let d = FirstSheet()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.id
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "sheet", id == nil { id = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value }
        }
    }

    private final class Relationships: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        static func parse(_ data: Data) -> [String: String] {
            let d = Relationships()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.map
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { map[id] = target }
        }
    }

    private final class SheetCells: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [Int: [Int: String]] = [:]
        var row = 0
        var column = 0
        var type = ""
        var value = ""
        var collecting = false
        var nextColumn = 0

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let d = SheetCells(shared: shared)
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            guard let last = d.rows.keys.max() else { return [] }
            return (0...last).map { r in
                let cells = d.rows[r] ?? [:]
                guard let width = cells.keys.max() else { return [] }
                return (0...width).map { cells[$0] ?? "" }
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                row = (attributes["r"].flatMap(Int.init) ?? row + 1) - 1
                nextColumn = 0
            case "c":
                column = attributes["r"].map(XLSXReader.columnIndex) ?? nextColumn
                nextColumn = column + 1
                type = attributes["t"] ?? ""
                value = ""
            case "v", "t":
                collecting = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { value += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t":
                collecting = false
            case "c":
                var text = value
                if type == "s", let i = Int(value), i < shared.count { text = shared[i] }
                if type == "b" { text = value == "1" ? "TRUE" : "FALSE" }
                if type.isEmpty || type == "n", let d = Double(value), d == d.rounded(), abs(d) < 1e15 { text = String(Int(d)) }
                if !text.isEmpty { rows[row, default: [:]][column] = text }
            default:
                break
            }
        }
    }
}
