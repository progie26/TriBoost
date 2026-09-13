import XCTest
@testable import TriBoostCore

private final class RecordingSender: KeySending {
    enum Event: Equatable { case down(autorepeat: Bool), up }
    var events: [Event] = []

    func sendKeyDown(autorepeat: Bool) { events.append(.down(autorepeat: autorepeat)) }
    func sendKeyUp() { events.append(.up) }
}

final class KeyGuardTests: XCTestCase {

    func testPressThenReleaseSendsOneOfEach() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)

        guard_.press()
        XCTAssertTrue(guard_.isDown)
        XCTAssertTrue(guard_.release())

        XCTAssertEqual(sender.events, [.down(autorepeat: false), .up])
        XCTAssertFalse(guard_.isDown)
    }

    func testDoublePressSendsOneKeyDown() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        guard_.press()
        guard_.press()
        XCTAssertEqual(sender.events, [.down(autorepeat: false)])
    }

    /// The safety nets all call release; overlapping calls must not spray key-ups.
    func testDoubleReleaseSendsOneKeyUp() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        guard_.press()
        XCTAssertTrue(guard_.release())
        XCTAssertFalse(guard_.release(), "second release is a no-op")
        XCTAssertFalse(guard_.release())
        XCTAssertEqual(sender.events, [.down(autorepeat: false), .up])
    }

    func testReleaseWithoutPressSendsNothing() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        XCTAssertFalse(guard_.release())
        XCTAssertEqual(sender.events, [])
    }

    /// Tencent Video decides a key is held by counting auto-repeats, so a lone
    /// key-down never engages its speed-up and the release reads as a tap — which
    /// on that site seeks. Measured: 6 s held with one key-down ran at 0.83x and
    /// then jumped forward 7 s; the same hold with repeats ran at 2.66x.
    func testAutorepeatIsOnByDefault() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        guard_.press()
        guard_.repeatKey()
        XCTAssertEqual(sender.events, [.down(autorepeat: false), .down(autorepeat: true)])
    }

    func testAutorepeatCanBeTurnedOff() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender, emitAutorepeat: false)
        guard_.press()
        guard_.repeatKey()
        XCTAssertEqual(sender.events, [.down(autorepeat: false)])
    }

    func testRepeatsOnlyHappenWhileTheKeyIsDown() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        guard_.repeatKey()                     // never pressed
        guard_.press()
        guard_.release()
        guard_.repeatKey()                     // already let go
        XCTAssertEqual(sender.events, [.down(autorepeat: false), .up],
                       "a stray repeat must never resurrect the key")
    }

    func testAutorepeatWhenExplicitlyEnabled() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender, emitAutorepeat: true)
        guard_.press()
        guard_.repeatKey()
        guard_.repeatKey()
        guard_.release()
        XCTAssertEqual(sender.events, [
            .down(autorepeat: false), .down(autorepeat: true), .down(autorepeat: true), .up,
        ])
    }

    func testRepeatDoesNothingWhenKeyIsUp() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender, emitAutorepeat: true)
        guard_.repeatKey()
        XCTAssertEqual(sender.events, [])
    }

    /// The whole point: after any sequence of calls the key must not be left down.
    func testKeyIsNeverLeftDownAfterRelease() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender, emitAutorepeat: true)
        for _ in 0..<5 {
            guard_.press()
            guard_.repeatKey()
        }
        guard_.release()
        XCTAssertFalse(guard_.isDown)
        XCTAssertEqual(sender.events.last, .up)
        XCTAssertEqual(sender.events.filter { $0 == .up }.count, 1)
    }
}
