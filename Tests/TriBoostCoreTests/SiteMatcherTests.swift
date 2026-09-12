import XCTest
@testable import TriBoostCore

final class SiteMatcherTests: XCTestCase {
    private let matcher = SiteMatcher()

    func testVerifiedSitesMatch() {
        XCTAssertTrue(matcher.allows(urlString: "https://www.bilibili.com/video/BV1istR6QEC7"))
        XCTAssertTrue(matcher.allows(urlString: "https://www.iqiyi.com/v_lmzehuqm5w.html"))
        XCTAssertTrue(matcher.allows(urlString: "https://v.qq.com/x/cover/mzc00200tgcz1s0.html"))
        XCTAssertTrue(matcher.allows(urlString: "https://bilibili.com/"), "bare domain")
        XCTAssertTrue(matcher.allows(urlString: "https://m.bilibili.com/video/x"), "subdomain")
    }

    func testUnverifiedSitesDoNotMatch() {
        // Holding the right arrow here seeks repeatedly instead of speeding up —
        // measured, which is why YouTube is deliberately absent.
        XCTAssertFalse(matcher.allows(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertFalse(matcher.allows(urlString: "https://www.youku.com/v_show/id_x.html"))
        XCTAssertFalse(matcher.allows(urlString: "https://news.example.com/"))
    }

    func testCannotBeFooledBySuffixTricks() {
        XCTAssertFalse(matcher.allows(urlString: "https://bilibili.com.evil.net/video/1"))
        XCTAssertFalse(matcher.allows(urlString: "https://notbilibili.com/video/1"))
        XCTAssertFalse(matcher.allows(urlString: "https://evil.net/?x=bilibili.com"))
    }

    func testUnreadableURLStaysDisabled() {
        XCTAssertFalse(matcher.allows(urlString: nil), "requirement: unknown means off")
        XCTAssertFalse(matcher.allows(urlString: ""))
        XCTAssertFalse(matcher.allows(urlString: "   "))
        XCTAssertFalse(matcher.allows(urlString: "新标签页"))
    }

    func testNonWebSchemesNeverMatch() {
        XCTAssertFalse(matcher.allows(urlString: "chrome://settings"))
        XCTAssertFalse(matcher.allows(urlString: "file:///Users/x/bilibili.com.html"))
    }

    /// Chrome's omnibox shows the URL without a scheme; we still have to recognise it.
    func testSchemelessOmniboxTextMatches() {
        XCTAssertTrue(matcher.allows(urlString: "bilibili.com/video/BV1istR6QEC7"))
        XCTAssertTrue(matcher.allows(urlString: "www.iqiyi.com/v_lmzehuqm5w.html"))
        XCTAssertEqual(SiteMatcher.host(of: "bilibili.com/video/x?y=1"), "bilibili.com")
        XCTAssertEqual(SiteMatcher.host(of: "www.bilibili.com:443/v"), "www.bilibili.com")
    }

    func testCustomDomainList() {
        let custom = SiteMatcher(domains: ["example.org"])
        XCTAssertTrue(custom.allows(urlString: "https://example.org/x"))
        XCTAssertFalse(custom.allows(urlString: "https://bilibili.com/x"))
    }
}
