import XCTest
@testable import PlaybackCore

final class SetMemoryTests: XCTestCase {
    let ids = (0..<6).map { _ in UUID() }

    func testThePlayingSongThenTheRestOfTheSetThenWhatCameBefore() {
        let queue = [ids[0], ids[1], ids[2], ids[3]]
        let order = SetMemory.order(queue: queue, all: ids, current: ids[2])
        XCTAssertEqual(order, [ids[2], ids[3], ids[1], ids[0], ids[4], ids[5]])
    }

    func testNothingCuedStartsFromTheTop() {
        let order = SetMemory.order(queue: [ids[3], ids[1]], all: ids, current: nil)
        XCTAssertEqual(order, [ids[3], ids[1], ids[0], ids[2], ids[4], ids[5]])
    }

    func testASongOutsideTheSetStillComesFirstWhenItsPlaying() {
        let order = SetMemory.order(queue: [ids[0], ids[1]], all: ids, current: ids[5])
        XCTAssertEqual(order.prefix(3), [ids[5], ids[0], ids[1]])
        XCTAssertEqual(Set(order).count, order.count, "each song once")
    }

    func testFitsARunFromThePlayingSong() {
        let sizes = [ids[0]: 40, ids[1]: 40, ids[2]: 40, ids[3]: 10]
        let kept = SetMemory.fitting([ids[0], ids[1], ids[2], ids[3]], bytes: { sizes[$0]! }, budget: 100)
        XCTAssertEqual(kept, [ids[0], ids[1]], "stops at the first that doesn't fit, so there are no holes")
    }

    func testThePlayingSongIsAlwaysKept() {
        let kept = SetMemory.fitting([ids[0], ids[1]], bytes: { _ in 500 }, budget: 100)
        XCTAssertEqual(kept, [ids[0]])
    }

    func testEstimates() {
        // Four minutes of stereo with timecode at 48 kHz: about 138 MB.
        XCTAssertEqual(SetMemory.estimatedBytes(seconds: 240, sampleRate: 48_000), 240 * 48_000 * 3 * 4)
        XCTAssertEqual(SetMemory.estimatedBytes(seconds: 1, sampleRate: 48_000, masterChannels: 1, timecode: false), 48_000 * 4)
        XCTAssertEqual(SetMemory.budget(physicalMemory: 16 << 30), 8 << 30)
        let b = PlaybackBuffers(sampleRate: 48_000, master: [[Float](repeating: 0, count: 100), [Float](repeating: 0, count: 100)],
                                timecode: [Float](repeating: 0, count: 100))
        XCTAssertEqual(b.byteCount, SetMemory.estimatedBytes(seconds: 100.0 / 48_000, sampleRate: 48_000))
    }
}

final class AudioKeyTests: XCTestCase {
    func testChangesWhenWhatPlaysChanges() {
        var s = Song(title: "Night Drive", start: Timecode("01:00:00:00", rate: .fps30)!, fileOffset: 2)
        s.masterPath = "a.wav"
        let key = s.audioKey
        var marked = s
        marked.markers.append(Marker(time: s.start, label: "Hit"))
        marked.notes = "louder"
        XCTAssertEqual(marked.audioKey, key, "markers and notes don't touch the audio")
        var moved = s; moved.fileOffset = 2.5
        XCTAssertNotEqual(moved.audioKey, key)
        var newFile = s; newFile.masterPath = "b.wav"
        XCTAssertNotEqual(newFile.audioKey, key)
        var newStart = s; newStart.start = Timecode("02:00:00:00", rate: .fps30)!
        XCTAssertNotEqual(newStart.audioKey, key, "generated timecode follows the start")
        var newRate = s; newRate.start = Timecode("01:00:00:00", rate: .fps25)!
        XCTAssertNotEqual(newRate.audioKey, key)
        var off = s; off.timecodeOff = true
        XCTAssertNotEqual(off.audioKey, key)
        var channel = s; channel.timecodeFileChannel = 1
        XCTAssertNotEqual(channel.audioKey, key)
        var longer = s; longer.length = 300
        XCTAssertEqual(longer.audioKey, key, "with a master, the audio sets the length")
    }
}
