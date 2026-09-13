import Foundation

/// Every tunable number in one place.
///
/// Distances are in the trackpad's own normalised coordinate space (0...1 on both
/// axes), which is what `OpenMultitouchSupport` reports. On a 16 cm wide trackpad
/// 0.03 is roughly 5 mm.
public struct Thresholds: Sendable, Equatable {
    /// Exactly this many fingers must be resting to arm the gesture.
    public var requiredFingers: Int

    /// Placing three fingers is not instantaneous — the hardware reports 1, then 2,
    /// then 3 contacts a few milliseconds apart. Finger-count changes inside this
    /// window after the first contact are treated as the hand still landing.
    public var settleGrace: TimeInterval

    /// How long three fingers must rest still before the key goes down.
    public var holdToActivate: TimeInterval

    /// Once the key is down, keep it down at least this long.
    ///
    /// Why: a *short* press of the right arrow is "seek forward" on every site we
    /// target (5 s on Bilibili, 10 s on iQiyi). Releasing too early would skip the
    /// video instead of doing nothing. Sites need roughly 300–400 ms to recognise a
    /// hold, so anything below ~0.45 risks an unwanted jump.
    ///
    /// Set to 0 to release the instant the fingers lift.
    public var minimumKeyHold: TimeInterval

    /// How long after the key goes down the synthetic auto-repeat starts, and how
    /// fast it then repeats.
    ///
    /// Why this exists at all: a physically held key repeats, but a `CGEvent`
    /// key-down does not — it is a single event and nothing follows it. Tencent
    /// Video decides "this is a hold" by counting those repeats, so with one lone
    /// key-down it never engages the speed-up, and the release is read as a short
    /// press — which on that site means seek. Measured: one key-down held 6 s gave
    /// 0.83x and then jumped the video forward 7 s; the same hold with repeats gave
    /// 2.66x and no jump.
    ///
    /// The defaults mirror a typical macOS keyboard (0.25 s, then ~30 Hz).
    public var autorepeatDelay: TimeInterval

    /// Seconds between synthetic auto-repeat key-downs.
    public var autorepeatInterval: TimeInterval

    /// While arming: if any finger wanders further than this from where it landed,
    /// the gesture is the system's three-finger drag, not ours.
    public var armingFingerMove: Double

    /// While arming: same idea, but for the centre of the three contacts. Catches a
    /// whole-hand slide where each finger individually stays under the limit.
    public var armingCentroidMove: Double

    /// After the key is down: how far a finger may drift before we let go. Larger
    /// than the arming limit so that resting-hand jitter does not drop the speed-up.
    public var activeFingerMove: Double

    public init(
        requiredFingers: Int = 3,
        settleGrace: TimeInterval = 0.15,
        holdToActivate: TimeInterval = 0.20,
        minimumKeyHold: TimeInterval = 0.50,
        autorepeatDelay: TimeInterval = 0.25,
        autorepeatInterval: TimeInterval = 0.033,
        armingFingerMove: Double = 0.030,
        armingCentroidMove: Double = 0.020,
        activeFingerMove: Double = 0.045
    ) {
        self.requiredFingers = requiredFingers
        self.settleGrace = settleGrace
        self.holdToActivate = holdToActivate
        self.minimumKeyHold = minimumKeyHold
        self.autorepeatDelay = autorepeatDelay
        self.autorepeatInterval = autorepeatInterval
        self.armingFingerMove = armingFingerMove
        self.armingCentroidMove = armingCentroidMove
        self.activeFingerMove = activeFingerMove
    }

    public static let `default` = Thresholds()
}
