import Foundation

/// What the menu bar shows. Derived from the machine plus the environment, so the
/// gesture machine itself stays free of UI concerns.
public enum AppStatus: Sendable, Equatable {
    case disabled
    case missingAccessibility
    case chromeNotFrontmost
    case unsupportedSite
    case waitingForFingers
    case speeding
    case recognisedAsDrag

    public var localizedDescription: String {
        switch self {
        case .disabled:             return "未启用"
        case .missingAccessibility: return "缺少辅助功能权限"
        case .chromeNotFrontmost:   return "Chrome 不在前台"
        case .unsupportedSite:      return "当前网站不支持"
        case .waitingForFingers:    return "等待三指"
        case .speeding:             return "倍速中"
        case .recognisedAsDrag:     return "已识别为拖移"
        }
    }

    /// Priority order matters: a missing permission is worth reporting even when
    /// the current tab happens to be unsupported.
    ///
    /// `chromeFrontmost` is reported separately from `siteEligible` on purpose.
    /// Opening this very menu can take the focus away from Chrome, and collapsing
    /// both conditions into one label made the menu claim "当前网站不支持" on a
    /// site that is in fact supported — which is exactly how a working site gets
    /// mistaken for a broken one.
    public static func derive(
        enabled: Bool,
        hasAccessibility: Bool,
        chromeFrontmost: Bool = true,
        siteEligible: Bool,
        state: GestureState
    ) -> AppStatus {
        guard enabled else { return .disabled }
        guard hasAccessibility else { return .missingAccessibility }
        guard chromeFrontmost else { return .chromeNotFrontmost }
        guard siteEligible else { return .unsupportedSite }
        switch state {
        case .speeding:          return .speeding
        case .cancelledForDrag:  return .recognisedAsDrag
        case .idle, .candidate:  return .waitingForFingers
        }
    }
}
