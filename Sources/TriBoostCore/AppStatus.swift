import Foundation

/// What the menu bar shows. Derived from the machine plus the environment, so the
/// gesture machine itself stays free of UI concerns.
public enum AppStatus: Sendable, Equatable {
    case disabled
    case missingAccessibility
    case unsupportedSite
    case waitingForFingers
    case speeding
    case recognisedAsDrag

    public var localizedDescription: String {
        switch self {
        case .disabled:             return "未启用"
        case .missingAccessibility: return "缺少辅助功能权限"
        case .unsupportedSite:      return "当前网站不支持"
        case .waitingForFingers:    return "等待三指"
        case .speeding:             return "倍速中"
        case .recognisedAsDrag:     return "已识别为拖移"
        }
    }

    /// Priority order matters: a missing permission is worth reporting even when
    /// the current tab happens to be unsupported.
    public static func derive(
        enabled: Bool,
        hasAccessibility: Bool,
        siteEligible: Bool,
        state: GestureState
    ) -> AppStatus {
        guard enabled else { return .disabled }
        guard hasAccessibility else { return .missingAccessibility }
        guard siteEligible else { return .unsupportedSite }
        switch state {
        case .speeding:          return .speeding
        case .cancelledForDrag:  return .recognisedAsDrag
        case .idle, .candidate:  return .waitingForFingers
        }
    }
}
