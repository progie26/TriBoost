import Foundation

// MARK: - Inputs

/// One contact reported by the trackpad, in normalised 0...1 coordinates.
public struct Touch: Sendable, Equatable {
    public let id: Int32
    public let x: Double
    public let y: Double

    public init(id: Int32, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public enum GestureInput: Sendable, Equatable {
    /// A frame from the trackpad. `time` is a monotonic timestamp in seconds.
    case touches([Touch], time: TimeInterval)
    /// Chrome moved to or away from a page whose domain we support.
    case eligibility(Bool, time: TimeInterval)
    /// Chrome stopped being the frontmost application.
    case foregroundLost(time: TimeInterval)
    /// Quitting, sleeping, locking, switching user, or the user disabled us.
    /// Always releases the key, with no minimum-hold delay.
    case shutdown
}

// MARK: - Outputs

public enum GestureAction: Sendable, Equatable {
    /// Send a key-down for the right arrow.
    case press
    /// Send a key-up. `notBefore` is an absolute timestamp the caller must wait for
    /// (it enforces `minimumKeyHold`); `nil` means release right now.
    case release(notBefore: TimeInterval?)
}

// MARK: - State

public enum GestureState: String, Sendable, Equatable {
    /// Nothing held, or a hand is still landing. Ready to recognise.
    case idle
    /// Three fingers are down and still; the activation timer is running.
    case candidate
    /// The key is down.
    case speeding
    /// This gesture belongs to the system's three-finger drag. Stays here until
    /// every finger leaves, so one gesture can never be recognised twice.
    case cancelledForDrag
}

// MARK: - Machine

/// Pure, synchronous, deterministic. No clock of its own, no I/O — every decision
/// comes from the inputs it is handed, which is what makes it testable.
public struct GestureMachine: Sendable {
    public private(set) var state: GestureState = .idle
    public var thresholds: Thresholds

    /// Whether the frontmost tab is on a supported domain.
    public private(set) var isEligible: Bool = false

    /// True between a `.press` and its `.release`. The driver uses this to make
    /// sure a key is never left down.
    public private(set) var isKeyDown: Bool = false

    private var anchors: [Int32: (x: Double, y: Double)] = [:]
    private var anchorCentroid: (x: Double, y: Double) = (0, 0)
    private var candidateSince: TimeInterval = 0
    private var firstContactAt: TimeInterval?
    private var pressedAt: TimeInterval = 0

    public init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    public mutating func handle(_ input: GestureInput) -> [GestureAction] {
        switch input {
        case .shutdown:
            return releaseIfNeeded(honouringMinimumHold: false, next: .idle)

        case .foregroundLost(let time):
            // Requirement: Chrome losing focus releases the key immediately.
            _ = time
            isEligible = false
            return releaseIfNeeded(honouringMinimumHold: false, next: parkState())

        case .eligibility(let eligible, _):
            guard eligible != isEligible else { return [] }
            isEligible = eligible
            if !eligible {
                return releaseIfNeeded(honouringMinimumHold: false, next: parkState())
            }
            // Becoming eligible never activates mid-gesture: the user must lift first.
            if state != .idle { state = .cancelledForDrag }
            return []

        case .touches(let touches, let time):
            return handleTouches(touches, at: time)
        }
    }

    // MARK: - Touch handling

    private mutating func handleTouches(_ touches: [Touch], at time: TimeInterval) -> [GestureAction] {
        let count = touches.count

        // Every finger gone: this is the only way back to a recognisable state.
        if count == 0 {
            firstContactAt = nil
            anchors = [:]
            return releaseIfNeeded(honouringMinimumHold: true, next: .idle)
        }

        // A drag already claimed this gesture; wait it out.
        if state == .cancelledForDrag { return [] }

        if !isEligible {
            state = .cancelledForDrag
            return releaseIfNeeded(honouringMinimumHold: false, next: .cancelledForDrag)
        }

        switch state {
        case .idle:
            return armIfSettled(touches, at: time)

        case .candidate:
            guard count == thresholds.requiredFingers, sameFingers(touches) else {
                state = .cancelledForDrag
                return []
            }
            let (fingerDrift, centroidDrift) = drift(touches)
            // Moved while arming => this is a three-finger drag. Emit nothing at all.
            if fingerDrift > thresholds.armingFingerMove || centroidDrift > thresholds.armingCentroidMove {
                state = .cancelledForDrag
                return []
            }
            if time - candidateSince >= thresholds.holdToActivate {
                state = .speeding
                isKeyDown = true
                pressedAt = time
                return [.press]
            }
            return []

        case .speeding:
            guard count == thresholds.requiredFingers, sameFingers(touches) else {
                return releaseIfNeeded(honouringMinimumHold: true, next: .cancelledForDrag)
            }
            let (fingerDrift, _) = drift(touches)
            if fingerDrift > thresholds.activeFingerMove {
                // Started dragging after the boost engaged: let go and stay out until
                // the hand lifts completely.
                return releaseIfNeeded(honouringMinimumHold: true, next: .cancelledForDrag)
            }
            return []

        case .cancelledForDrag:
            return []
        }
    }

    /// From `idle`, wait for the hand to finish landing before judging the count.
    private mutating func armIfSettled(_ touches: [Touch], at time: TimeInterval) -> [GestureAction] {
        let landed = firstContactAt ?? time
        firstContactAt = landed

        if touches.count == thresholds.requiredFingers {
            state = .candidate
            candidateSince = time
            anchors = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, ($0.x, $0.y)) })
            anchorCentroid = centroid(touches)
            return []
        }

        if touches.count > thresholds.requiredFingers || time - landed > thresholds.settleGrace {
            state = .cancelledForDrag
        }
        return []
    }

    // MARK: - Helpers

    private mutating func releaseIfNeeded(
        honouringMinimumHold: Bool,
        next: GestureState
    ) -> [GestureAction] {
        state = next
        guard isKeyDown else { return [] }
        isKeyDown = false
        let notBefore = honouringMinimumHold && thresholds.minimumKeyHold > 0
            ? pressedAt + thresholds.minimumKeyHold
            : nil
        return [.release(notBefore: notBefore)]
    }

    /// Where to sit when the key is dropped for an external reason: if fingers may
    /// still be down we must not re-arm until they lift.
    private func parkState() -> GestureState {
        state == .idle ? .idle : .cancelledForDrag
    }

    private func sameFingers(_ touches: [Touch]) -> Bool {
        touches.allSatisfy { anchors[$0.id] != nil }
    }

    private func centroid(_ touches: [Touch]) -> (x: Double, y: Double) {
        let n = Double(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / n, touches.reduce(0) { $0 + $1.y } / n)
    }

    /// Largest single-finger displacement from its anchor, and the centroid's.
    private func drift(_ touches: [Touch]) -> (finger: Double, centroid: Double) {
        var maxFinger = 0.0
        for t in touches {
            guard let a = anchors[t.id] else { continue }
            maxFinger = max(maxFinger, hypot(t.x - a.x, t.y - a.y))
        }
        let c = centroid(touches)
        return (maxFinger, hypot(c.x - anchorCentroid.x, c.y - anchorCentroid.y))
    }
}
