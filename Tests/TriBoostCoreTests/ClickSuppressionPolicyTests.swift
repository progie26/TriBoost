import XCTest
@testable import TriBoostCore

/// Reproduces the timeline captured on a real machine:
///
///     [37.79s] KEY DOWN                    boost starts, policy armed
///     [38.08s] MOUSE DOWN  (169,747)       three-finger drag starts itself
///     [40.49s] KEY UP                      fingers lift, boost ends, disarmed
///     [40.51s] MOUSE UP    (168,747)       1 px later — the browser sees a click
final class ClickSuppressionPolicyTests: XCTestCase {

    func testDisarmedPolicyTouchesNothing() {
        var policy = ClickSuppressionPolicy()
        XCTAssertFalse(policy.shouldSwallow(.down))
        XCTAssertFalse(policy.shouldSwallow(.up))
    }

    func testTheCapturedTimelineIsFullySwallowed() {
        var policy = ClickSuppressionPolicy()
        policy.setArmed(true)                              // key down
        XCTAssertTrue(policy.shouldSwallow(.down))         // drag starts

        policy.setArmed(false)                             // fingers lift, key up
        XCTAssertTrue(policy.shouldSwallow(.up),
                      "the up arrives after the boost ended and must still be eaten")
        XCTAssertFalse(policy.hasSwallowedDown)
    }

    /// The failure this exists to prevent: an unpaired mouse-up reaching the page.
    func testUpIsNeverSwallowedWithoutItsDown() {
        var policy = ClickSuppressionPolicy()
        policy.setArmed(true)
        XCTAssertFalse(policy.shouldSwallow(.up), "no down was swallowed")
        policy.setArmed(false)
        XCTAssertFalse(policy.shouldSwallow(.up))
    }

    func testRealClicksPassThroughWhenNotBoosting() {
        var policy = ClickSuppressionPolicy()
        // A one-finger click while idle: this is how the user pauses the video.
        XCTAssertFalse(policy.shouldSwallow(.down))
        XCTAssertFalse(policy.shouldSwallow(.up))

        // And after a complete boost cycle, clicking still works.
        policy.setArmed(true)
        _ = policy.shouldSwallow(.down)
        policy.setArmed(false)
        _ = policy.shouldSwallow(.up)

        XCTAssertFalse(policy.shouldSwallow(.down))
        XCTAssertFalse(policy.shouldSwallow(.up))
    }

    func testASecondDownWhileArmedIsAlsoSwallowed() {
        var policy = ClickSuppressionPolicy()
        policy.setArmed(true)
        XCTAssertTrue(policy.shouldSwallow(.down))
        XCTAssertTrue(policy.shouldSwallow(.down))
        XCTAssertTrue(policy.shouldSwallow(.up))
        XCTAssertFalse(policy.shouldSwallow(.up), "only one up is owed")
    }

    func testResetLeavesNoHalfSwallowedPair() {
        var policy = ClickSuppressionPolicy()
        policy.setArmed(true)
        _ = policy.shouldSwallow(.down)
        XCTAssertTrue(policy.hasSwallowedDown)

        policy.reset()
        XCTAssertFalse(policy.isArmed)
        XCTAssertFalse(policy.hasSwallowedDown)
        XCTAssertFalse(policy.shouldSwallow(.up), "after reset, clicks flow normally")
    }

    func testBoostWithoutADragProducesNoSuppression() {
        // The gestures at 30.27s and 35.47s in the capture: no drag, no pause.
        var policy = ClickSuppressionPolicy()
        policy.setArmed(true)
        policy.setArmed(false)
        XCTAssertFalse(policy.hasSwallowedDown)
        XCTAssertFalse(policy.shouldSwallow(.down))
    }
}
