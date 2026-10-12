import CoreVideo
import XCTest
@testable import LidFoldKit

/// The identity rules that keep a stopped capture from resurrecting frames, and
/// that report "first frame" / "frame lost" exactly once so the owner is not spammed.
final class FrameStoreTests: XCTestCase {
    private func makeBuffer() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &made),
                       kCVReturnSuccess)
        return try XCTUnwrap(made)
    }

    func testStartsEmpty() {
        let store = FrameStore()
        XCTAssertFalse(store.hasFrame)
        XCTAssertNil(store.get().0)
    }

    func testNothingIsAcceptedBeforeAStreamIsAccepted() throws {
        let store = FrameStore()
        let stream = NSObject()
        XCTAssertNil(store.put(try makeBuffer(), from: ObjectIdentifier(stream)))
        XCTAssertFalse(store.hasFrame)
    }

    func testClearingTwiceReportsTheLossOnlyOnce() throws {
        let store = FrameStore(), stream = NSObject()
        let id = ObjectIdentifier(stream)
        store.acceptStream(id)
        XCTAssertEqual(store.put(try makeBuffer(), from: id), true)
        XCTAssertTrue(store.clear(from: id), "the first clear loses a frame")
        XCTAssertFalse(store.clear(from: id), "a stream stuck on blank frames must not re-notify")
        XCTAssertFalse(store.clear(from: id))
        XCTAssertFalse(store.hasFrame)
    }

    func testFirstFrameIsReportedAgainAfterAClear() throws {
        let store = FrameStore(), stream = NSObject()
        let id = ObjectIdentifier(stream)
        store.acceptStream(id)
        XCTAssertEqual(store.put(try makeBuffer(), from: id), true)
        XCTAssertEqual(store.put(try makeBuffer(), from: id), false)
        XCTAssertTrue(store.clear(from: id))
        XCTAssertEqual(store.put(try makeBuffer(), from: id), true, "a recovered stream announces itself once")
        XCTAssertEqual(store.put(try makeBuffer(), from: id), false)
    }

    func testAcceptingANewStreamDropsTheOldFrame() throws {
        let store = FrameStore(), first = NSObject(), second = NSObject()
        store.acceptStream(ObjectIdentifier(first))
        _ = store.put(try makeBuffer(), from: ObjectIdentifier(first))
        XCTAssertTrue(store.hasFrame)
        store.acceptStream(ObjectIdentifier(second))
        XCTAssertFalse(store.hasFrame, "the new stream starts without the old picture")
    }

    func testEveryChangeBumpsTheRevision() throws {
        let store = FrameStore(), stream = NSObject()
        let id = ObjectIdentifier(stream)
        var seen = Set<UInt64>([store.get().1])
        store.acceptStream(id); seen.insert(store.get().1)
        _ = store.put(try makeBuffer(), from: id); seen.insert(store.get().1)
        _ = store.put(try makeBuffer(), from: id); seen.insert(store.get().1)
        _ = store.clear(from: id); seen.insert(store.get().1)
        store.invalidateStream(); seen.insert(store.get().1)
        XCTAssertEqual(seen.count, 6, "the renderer re-imports only when the revision moves, so it must always move")
    }

    func testARejectedFrameChangesNothing() throws {
        let store = FrameStore(), current = NSObject(), stale = NSObject()
        store.acceptStream(ObjectIdentifier(current))
        let before = store.get().1
        XCTAssertNil(store.put(try makeBuffer(), from: ObjectIdentifier(stale)))
        XCTAssertFalse(store.clear(from: ObjectIdentifier(stale)))
        XCTAssertEqual(store.get().1, before)
        XCTAssertFalse(store.hasFrame)
    }

    func testInvalidateStreamRejectsEveryone() throws {
        let store = FrameStore(), stream = NSObject()
        let id = ObjectIdentifier(stream)
        store.acceptStream(id)
        _ = store.put(try makeBuffer(), from: id)
        store.invalidateStream()
        XCTAssertFalse(store.hasFrame)
        XCTAssertNil(store.put(try makeBuffer(), from: id), "after stop() the old callback cannot come back")
        XCTAssertFalse(store.hasFrame)
    }

    /// Frames arrive on the capture queue while stop() runs on the main thread: after
    /// the invalidation nothing may leave a frame behind.
    func testStopRacingWithFramesNeverLeavesAFrameBehind() throws {
        let buffer = try makeBuffer()
        for _ in 0..<200 {
            let store = FrameStore(), stream = NSObject()
            let id = ObjectIdentifier(stream)
            store.acceptStream(id)
            DispatchQueue.concurrentPerform(iterations: 8) { worker in
                if worker == 0 {
                    store.invalidateStream()
                } else {
                    for _ in 0..<20 { _ = store.put(buffer, from: id) }
                }
            }
            // Whatever the interleaving, once the invalidation has run, no frame may stay.
            store.invalidateStream()
            XCTAssertFalse(store.hasFrame)
            XCTAssertNil(store.put(buffer, from: id))
        }
    }

    func testConcurrentReadersAndWritersStayConsistent() throws {
        let buffer = try makeBuffer()
        let store = FrameStore(), stream = NSObject()
        let id = ObjectIdentifier(stream)
        store.acceptStream(id)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            switch index % 4 {
            case 0: _ = store.put(buffer, from: id)
            case 1: _ = store.clear(from: id)
            case 2: _ = store.get()
            default: _ = store.hasFrame
            }
        }
        // The store is still usable and its revision strictly moves.
        let before = store.get().1
        _ = store.put(buffer, from: id)
        XCTAssertGreaterThan(store.get().1, before)
    }
}
