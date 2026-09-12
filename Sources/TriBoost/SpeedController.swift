import Foundation
import TriBoostCore

/// Turns gesture-machine actions into real key events, on one serial queue.
///
/// Everything that can drop the key — a finger lifting, Chrome going away, sleep,
/// quit — ends up calling into here, and `KeyGuard` makes double releases harmless.
/// `@unchecked Sendable`: every mutable field is touched only from `queue`.
final class SpeedController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.triboost.gesture")
    private let keyGuard: KeyGuard
    private var machine: GestureMachine

    /// Invalidates a scheduled release if the key was pressed again in the meantime.
    private var pressGeneration = 0

    /// Called on the main queue whenever the displayed state could have changed.
    var onStateChange: (@Sendable (GestureState) -> Void)?

    /// Called synchronously on the gesture queue the moment the boost starts and
    /// ends. Used to arm click suppression without waiting for a main-queue hop —
    /// the stray three-finger-drag mouse-down arrives ~290 ms after the key goes
    /// down, and we must be armed before it.
    var onBoostActive: (@Sendable (Bool) -> Void)?

    init(keySender: any KeySending, thresholds: Thresholds = .default) {
        self.keyGuard = KeyGuard(sender: keySender)
        self.machine = GestureMachine(thresholds: thresholds)
    }

    var thresholds: Thresholds {
        get { queue.sync { machine.thresholds } }
        set { queue.async { self.machine.thresholds = newValue } }
    }

    // MARK: - Inputs

    func submit(touches: [Touch], at time: TimeInterval) {
        queue.async { self.apply(.touches(touches, time: time)) }
    }

    func setEligible(_ eligible: Bool) {
        queue.async { self.apply(.eligibility(eligible, time: now())) }
    }

    func chromeLostForeground() {
        queue.async { self.apply(.foregroundLost(time: now())) }
    }

    /// Quit, sleep, lock, user switch, disable. Never leaves the key down.
    func shutdown() {
        queue.async { self.apply(.shutdown) }
    }

    /// Same as `shutdown`, but blocks until the key-up has actually been posted —
    /// used on the termination path where the process is about to disappear.
    func shutdownSynchronously() {
        queue.sync { self.apply(.shutdown) }
    }

    // MARK: - Plumbing

    private func apply(_ input: GestureInput) {
        let before = machine.state
        for action in machine.handle(input) {
            perform(action)
        }
        let after = machine.state
        if before != after, let onStateChange {
            DispatchQueue.main.async { onStateChange(after) }
        }
    }

    private func perform(_ action: GestureAction) {
        switch action {
        case .press:
            pressGeneration &+= 1
            onBoostActive?(true)
            keyGuard.press()

        case .release(let notBefore):
            // Disarm as soon as the gesture ends, not when the delayed key-up
            // fires; the suppressor keeps its own memory of a swallowed press so
            // the trailing mouse-up is still matched.
            onBoostActive?(false)
            guard let notBefore else {
                keyGuard.release()
                return
            }
            let delay = notBefore - now()
            guard delay > 0 else {
                keyGuard.release()
                return
            }
            // Hold the key the rest of the minimum window so the site reads it as a
            // hold rather than a short press (which would seek).
            let generation = pressGeneration
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pressGeneration == generation else { return }
                self.keyGuard.release()
            }
        }
    }
}

/// Monotonic seconds. Does not run while the machine is asleep, which is exactly
/// what we want for gesture timing.
func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
