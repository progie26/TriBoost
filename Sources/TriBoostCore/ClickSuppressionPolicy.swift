import Foundation

public enum MouseEventKind: Sendable, Equatable {
    case down
    case up
}

/// Decides whether a synthesized mouse event should be dropped.
///
/// macOS's three-finger drag starts itself ~300 ms into a resting three-finger
/// hold and emits a mouse-down; the matching mouse-up arrives just *after* the
/// fingers leave, when the boost has already ended. So the up is keyed off having
/// swallowed the down, not off the armed flag — otherwise the page would receive
/// an unpaired mouse-up.
///
/// Pure and synchronous so the event-tap callback stays trivial.
public struct ClickSuppressionPolicy: Sendable {
    public private(set) var isArmed = false
    public private(set) var hasSwallowedDown = false

    public init() {}

    /// Armed exactly while a boost is running.
    public mutating func setArmed(_ armed: Bool) {
        isArmed = armed
    }

    /// `true` means: drop this event, do not let it reach the app underneath.
    public mutating func shouldSwallow(_ kind: MouseEventKind) -> Bool {
        switch kind {
        case .down:
            guard isArmed else { return false }
            hasSwallowedDown = true
            return true

        case .up:
            guard hasSwallowedDown else { return false }
            hasSwallowedDown = false
            return true
        }
    }

    /// Stopping the monitor must not leave a half-swallowed pair behind.
    public mutating func reset() {
        isArmed = false
        hasSwallowedDown = false
    }
}
