import CoreGraphics
import TriBoostCore

/// Posts right-arrow key events the way a physically held key looks to macOS.
final class CGKeyEmitter: KeySending {
    /// kVK_RightArrow
    private static let rightArrow: CGKeyCode = 124

    private let source = CGEventSource(stateID: .hidSystemState)

    func sendKeyDown(autorepeat: Bool) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: Self.rightArrow,
                                  keyDown: true) else { return }
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    func sendKeyUp() {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: Self.rightArrow,
                                  keyDown: false) else { return }
        event.post(tap: .cghidEventTap)
    }
}
