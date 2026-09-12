import AppKit
import CoreGraphics
import TriBoostCore

/// Swallows the stray click that macOS's three-finger drag produces during a boost.
///
/// Measured behaviour: about 300 ms after three fingers land, macOS starts a
/// three-finger drag from the unavoidable micro-movement of a resting hand. It
/// emits a left-mouse-down, and a left-mouse-up once the fingers leave — one pixel
/// apart. The browser reads that pair as a click on the video and pauses it.
///
/// This is the one place TriBoost is not purely passive. The tap is *only* allowed
/// to drop events while a boost is actually running, so three-finger drag behaves
/// completely normally at every other moment. A down that gets swallowed remembers
/// to swallow its matching up, otherwise the page would see an unpaired mouse-up.
final class DragClickSuppressor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The decision logic lives in TriBoostCore so it can be unit-tested; this class
    /// is only the plumbing that attaches it to a CGEventTap.
    private var policy = ClickSuppressionPolicy()
    private let lock = NSLock()

    /// Set while a boost is running. Only then may events be dropped.
    var isArmed: Bool {
        get { lock.withLock { policy.isArmed } }
        set { lock.withLock { policy.setArmed(newValue) } }
    }

    /// True once the tap exists; if this stays false the app still works, the stray
    /// click just is not filtered.
    private(set) var isInstalled = false

    func start() {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DragClickSuppressor>.fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("TriBoost: could not create the click-suppression tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.isInstalled = true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isInstalled = false
        lock.withLock { policy.reset() }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a slow tap; put it straight back or we silently stop working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let kind: MouseEventKind
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseUp:   kind = .up
        default:             return Unmanaged.passUnretained(event)
        }

        let swallow = lock.withLock { policy.shouldSwallow(kind) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
