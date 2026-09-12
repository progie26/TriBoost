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

    func testAutorepeatIsOffByDefault() {
        let sender = RecordingSender()
        let guard_ = KeyGuard(sender: sender)
        guard_.press()
        guard_.repeatKey()
        XCTAssertEqual(sender.events, [.down(autorepeat: false)],
                       "measured: Bilibili/iQiyi/Tencent need no auto-repeat")
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
