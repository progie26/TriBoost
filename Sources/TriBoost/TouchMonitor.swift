import Foundation
import OpenMultitouchSupport
import TriBoostCore

/// Passive reader of raw trackpad contacts.
///
/// `OpenMultitouchSupport` only observes — it does not install an event tap and
/// cannot swallow or alter a gesture, so macOS's own three-finger drag keeps
/// working exactly as configured.
final class TouchMonitor: @unchecked Sendable {
    private let manager = OMSManager.shared
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// `onFrame` is delivered on a background task; timestamps are monotonic seconds.
    func start(onFrame: @escaping @Sendable ([Touch], TimeInterval) -> Void) {
        guard task == nil else { return }
        let stream = manager.touchDataStream
        task = Task.detached {
            for await frame in stream {
                // `.touching` and `.making` are the states where a finger is really
                // resting on the surface; hovering and lifting ones are ignored.
                let touches = frame.compactMap { data -> Touch? in
                    guard data.state == .touching || data.state == .making else { return nil }
                    return Touch(id: data.id, x: Double(data.position.x), y: Double(data.position.y))
                }
                onFrame(touches, now())
            }
        }
        _ = manager.startListening()
    }

    func stop() {
        _ = manager.stopListening()
        task?.cancel()
        task = nil
    }
}
