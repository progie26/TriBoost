import XCTest
@testable import TriBoostCore

/// Helpers to write gesture scripts that read like the thing being described.
private extension GestureMachine {
    mutating func eligible(_ on: Bool = true, at t: TimeInterval = 0) {
        _ = handle(.eligibility(on, time: t))
    }

    mutating func frame(_ touches: [Touch], _ t: TimeInterval) -> [GestureAction] {
        handle(.touches(touches, time: t))
    }

    mutating func lift(_ t: TimeInterval) -> [GestureAction] {
        handle(.touches([], time: t))
    }
}

private func three(x: Double = 0.3, y: Double = 0.5, spread: Double = 0.1) -> [Touch] {
    [Touch(id: 1, x: x, y: y),
     Touch(id: 2, x: x + spread, y: y),
     Touch(id: 3, x: x + 2 * spread, y: y)]
}

private func shifted(_ touches: [Touch], dx: Double, dy: Double = 0) -> [Touch] {
    touches.map { Touch(id: $0.id, x: $0.x + dx, y: $0.y + dy) }
}

/// Ready machine: eligible site, three fingers resting since t=0.
private func armed(_ thresholds: Thresholds = .default) -> GestureMachine {
    var m = GestureMachine(thresholds: thresholds)
    m.eligible()
    _ = m.frame(three(), 0)
    return m
}

final class GestureMachineTests: XCTestCase {

    // MARK: - The happy path

    func testThreeStillFingersPressAfterHoldWindow() {
        var m = armed()
        XCTAssertEqual(m.state, .candidate)

        XCTAssertEqual(m.frame(three(), 0.19), [], "must not fire before the hold window")
        XCTAssertEqual(m.state, .candidate)

        XCTAssertEqual(m.frame(three(), 0.20), [.press])
        XCTAssertEqual(m.state, .speeding)
        XCTAssertTrue(m.isKeyDown)
    }

    func testLiftingReleasesWithMinimumHold() {
        var m = armed()
        XCTAssertEqual(m.frame(three(), 0.20), [.press])

        // Lifting almost immediately still holds the key until pressedAt + 0.5,
        // otherwise the site reads it as a short press and seeks.
        XCTAssertEqual(m.lift(0.25), [.release(notBefore: 0.70)])
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isKeyDown)
    }

    func testZeroMinimumHoldReleasesImmediately() {
        var t = Thresholds.default
        t.minimumKeyHold = 0
        var m = armed(t)
        XCTAssertEqual(m.frame(three(), 0.20), [.press])
        XCTAssertEqual(m.lift(0.25), [.release(notBefore: nil)])
    }

    // MARK: - Finger-count changes

    func testHandLandingRampsThroughOneAndTwoFingers() {
        var m = GestureMachine()
        m.eligible()
        // Real capture: 1 finger, then 2, then 3 within ~30 ms.
        _ = m.frame([Touch(id: 1, x: 0.7, y: 0.5)], 0)
        XCTAssertEqual(m.state, .idle, "still settling")
        _ = m.frame([Touch(id: 1, x: 0.7, y: 0.5), Touch(id: 2, x: 0.48, y: 0.62)], 0.01)
        XCTAssertEqual(m.state, .idle, "still settling")
        _ = m.frame(three(), 0.03)
        XCTAssertEqual(m.state, .candidate, "arms once the third finger lands")
    }

    func testTwoFingersLingeringPastGraceIsNotOurGesture() {
        var m = GestureMachine()
        m.eligible()
        _ = m.frame([Touch(id: 1, x: 0.3, y: 0.5)], 0)
        _ = m.frame([Touch(id: 1, x: 0.3, y: 0.5)], 0.16)
        XCTAssertEqual(m.state, .cancelledForDrag, "one finger resting is scrolling, not us")
    }

    func testFourFingersNeverArm() {
        var m = GestureMachine()
        m.eligible()
        var four = three()
        four.append(Touch(id: 4, x: 0.9, y: 0.5))
        _ = m.frame(four, 0)
        XCTAssertEqual(m.state, .cancelledForDrag)
    }

    func testLosingAFingerWhileSpeedingReleases() {
        var m = armed()
        XCTAssertEqual(m.frame(three(), 0.20), [.press])
        let actions = m.frame(Array(three().prefix(2)), 0.30)
        XCTAssertEqual(actions, [.release(notBefore: 0.70)])
        XCTAssertEqual(m.state, .cancelledForDrag)
    }

    func testGainingAFingerWhileSpeedingReleases() {
        var m = armed()
        XCTAssertEqual(m.frame(three(), 0.20), [.press])
        var four = three()
        four.append(Touch(id: 9, x: 0.9, y: 0.5))
        XCTAssertEqual(m.frame(four, 0.30), [.release(notBefore: 0.70)])
        XCTAssertEqual(m.state, .cancelledForDrag)
    }

    // MARK: - Movement thresholds

    func testMovingBeforeActivationEmitsNothingAtAll() {
        var m = armed()
        // 40 mm-ish slide well past the arming limit, before the 200 ms mark.
        let actions = m.frame(shifted(three(), dx: 0.05), 0.10)
        XCTAssertEqual(actions, [], "a three-finger drag must produce zero key events")
        XCTAssertEqual(m.state, .cancelledForDrag)
        XCTAssertFalse(m.isKeyDown)
    }

    func testTinyJitterWhileArmingStillActivates() {
        var m = armed()
        _ = m.frame(shifted(three(), dx: 0.004, dy: 0.003), 0.10)
        XCTAssertEqual(m.state, .candidate)
        XCTAssertEqual(m.frame(shifted(three(), dx: 0.004), 0.21), [.press])
    }

    func testWholeHandSlideCaughtByCentroidLimit() {
        var t = Thresholds.default
        t.armingFingerMove = 10        // disable the per-finger rule
        var m = armed(t)
        _ = m.frame(shifted(three(), dx: 0.025), 0.10)
        XCTAssertEqual(m.state, .cancelledForDrag, "centroid rule must still catch it")
    }

    func testMovingAfterActivationReleasesAndLocksOut() {
        var m = armed()
        XCTAssertEqual(m.frame(three(), 0.20), [.press])

        XCTAssertEqual(m.frame(shifted(three(), dx: 0.06), 0.30), [.release(notBefore: 0.70)])
        XCTAssertEqual(m.state, .cancelledForDrag)

        // Going still again must NOT re-engage while fingers are still down.
        XCTAssertEqual(m.frame(shifted(three(), dx: 0.06), 1.50), [])
        XCTAssertEqual(m.state, .cancelledForDrag)
        XCTAssertFalse(m.isKeyDown)
    }

    func testJitterWhileSpeedingKeepsTheKeyDown() {
        var m = armed()
        XCTAssertEqual(m.frame(three(), 0.20), [.press])
        XCTAssertEqual(m.frame(shifted(three(), dx: 0.02, dy: 0.01), 0.40), [])
        XCTAssertTrue(m.isKeyDown)
    }

    // MARK: - One gesture, one recognition

    func testCannotRearmUntilEveryFingerLifts() {
        var m = armed()
        _ = m.frame(shifted(three(), dx: 0.05), 0.10)   // becomes a drag
        XCTAssertEqual(m.state, .cancelledForDrag)

        // Hold still for a long time — still locked out.
        XCTAssertEqual(m.frame(shifted(three(), dx: 0.05), 2.0), [])
        XCTAssertEqual(m.state, .cancelledForDrag)

        // Full lift resets, and the next rest works.
        XCTAssertEqual(m.lift(2.1), [])
        XCTAssertEqual(m.state, .idle)
        _ = m.frame(three(), 2.2)
        XCTAssertEqual(m.state, .candidate)
        XCTAssertEqual(m.frame(three(), 2.41), [.press])
    }

    func testReleaseIsNotEmittedTwice() {
        var m = armed()
        _ = m.frame(three(), 0.20)
        XCTAssertEqual(m.lift(0.30), [.release(notBefore: 0.70)])
        XCTAssertEqual(m.lift(0.40), [], "already released")
        XCTAssertEqual(m.handle(.shutdown), [], "still nothing to release")
    }

    // MARK: - Environment changes must drop the key

    func testChromeLosingFocusReleasesImmediately() {
        var m = armed()
        _ = m.frame(three(), 0.20)
        XCTAssertEqual(m.handle(.foregroundLost(time: 0.25)), [.release(notBefore: nil)],
                       "no minimum hold on the safety paths")
        XCTAssertFalse(m.isKeyDown)
        XCTAssertEqual(m.state, .cancelledForDrag)
    }

    func testNavigatingAwayFromSupportedSiteReleasesImmediately() {
        var m = armed()
        _ = m.frame(three(), 0.20)
        XCTAssertEqual(m.handle(.eligibility(false, time: 0.25)), [.release(notBefore: nil)])
        XCTAssertFalse(m.isKeyDown)
    }

    func testShutdownReleasesImmediately() {
        var m = armed()
        _ = m.frame(three(), 0.20)
        XCTAssertEqual(m.handle(.shutdown), [.release(notBefore: nil)])
        XCTAssertFalse(m.isKeyDown)
        XCTAssertEqual(m.state, .idle)
    }

    func testFingersOnUnsupportedSiteNeverPress() {
        var m = GestureMachine()
        m.eligible(false)
        _ = m.frame(three(), 0)
        XCTAssertEqual(m.frame(three(), 0.5), [])
        XCTAssertFalse(m.isKeyDown)
    }

    func testBecomingEligibleMidGestureDoesNotActivate() {
        var m = GestureMachine()
        m.eligible(false)
        _ = m.frame(three(), 0)            // fingers already down, site unsupported
        m.eligible(true, at: 0.1)          // user switched tab without lifting
        XCTAssertEqual(m.frame(three(), 0.5), [])
        XCTAssertFalse(m.isKeyDown)

        _ = m.lift(0.6)
        _ = m.frame(three(), 0.7)
        XCTAssertEqual(m.frame(three(), 0.91), [.press], "works after a clean lift")
    }
}
