import XCTest
@testable import TriBoostCore

final class AppStatusTests: XCTestCase {

    func testDisabledBeatsEverythingElse() {
        let status = AppStatus.derive(enabled: false, hasAccessibility: false,
                                      siteEligible: true, state: .speeding)
        XCTAssertEqual(status, .disabled)
    }

    func testMissingPermissionIsReportedEvenOnAnUnsupportedSite() {
        let status = AppStatus.derive(enabled: true, hasAccessibility: false,
                                      siteEligible: false, state: .idle)
        XCTAssertEqual(status, .missingAccessibility)
    }

    func testUnsupportedSite() {
        let status = AppStatus.derive(enabled: true, hasAccessibility: true,
                                      siteEligible: false, state: .idle)
        XCTAssertEqual(status, .unsupportedSite)
    }

    func testEachGestureStateMapsToItsLabel() {
        func status(_ state: GestureState) -> AppStatus {
            AppStatus.derive(enabled: true, hasAccessibility: true,
                             siteEligible: true, state: state)
        }
        XCTAssertEqual(status(.idle), .waitingForFingers)
        XCTAssertEqual(status(.candidate), .waitingForFingers)
        XCTAssertEqual(status(.speeding), .speeding)
        XCTAssertEqual(status(.cancelledForDrag), .recognisedAsDrag)
    }

    /// The six labels the menu is specified to show.
    func testAllRequiredLabelsExist() {
        let labels: [AppStatus] = [
            .disabled, .waitingForFingers, .speeding,
            .recognisedAsDrag, .unsupportedSite, .missingAccessibility,
        ]
        XCTAssertEqual(Set(labels.map(\.localizedDescription)).count, 6,
                       "each status needs a distinct label")
        XCTAssertEqual(AppStatus.disabled.localizedDescription, "未启用")
        XCTAssertEqual(AppStatus.waitingForFingers.localizedDescription, "等待三指")
        XCTAssertEqual(AppStatus.speeding.localizedDescription, "倍速中")
        XCTAssertEqual(AppStatus.recognisedAsDrag.localizedDescription, "已识别为拖移")
        XCTAssertEqual(AppStatus.unsupportedSite.localizedDescription, "当前网站不支持")
        XCTAssertEqual(AppStatus.missingAccessibility.localizedDescription, "缺少辅助功能权限")
    }
}
