import Foundation

/// Anything that can put the right arrow key down and up.
public protocol KeySending: AnyObject {
    func sendKeyDown(autorepeat: Bool)
    func sendKeyUp()
}

/// Owns the "is the key currently down?" truth and makes release idempotent.
///
/// The whole safety story of this app is that a key-down is never left dangling,
/// so every path that could drop the key funnels through `release()`, and calling
/// it twice (quit handler *and* sleep notification, say) is harmless.
///
/// Not thread-safe by design — drive it from one serial queue.
public final class KeyGuard {
    private let sender: any KeySending
    public private(set) var isDown = false

    /// Some players decide a key is being *held* by counting auto-repeat events
    /// rather than by timing a single press — Tencent Video is one, measured. A
    /// real keyboard always repeats, so emitting repeats is the faithful thing to
    /// do and is on by default; sites that only time the press ignore them.
    public var emitAutorepeat: Bool

    public init(sender: any KeySending, emitAutorepeat: Bool = true) {
        self.sender = sender
        self.emitAutorepeat = emitAutorepeat
    }

    public func press() {
        guard !isDown else { return }
        isDown = true
        sender.sendKeyDown(autorepeat: false)
    }

    /// Only meaningful while held; sends an extra auto-repeat key-down.
    public func repeatKey() {
        guard isDown, emitAutorepeat else { return }
        sender.sendKeyDown(autorepeat: true)
    }

    @discardableResult
    public func release() -> Bool {
        guard isDown else { return false }
        isDown = false
        sender.sendKeyUp()
        return true
    }
}
