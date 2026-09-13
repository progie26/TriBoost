import XCTest
@testable import TriBoostCore

final class SiteMatcherTests: XCTestCase {
    private let matcher = SiteMatcher()

    func testVerifiedSitesMatch() {
        XCTAssertTrue(matcher.allows(urlString: "https://www.bilibili.com/video/BV1istR6QEC7"))
        XCTAssertTrue(matcher.allows(urlString: "https://www.iqiyi.com/v_lmzehuqm5w.html"))
        XCTAssertTrue(matcher.allows(urlString: "https://v.youku.com/v_show/id_XNjU2MDI1ODQxMg==.html"))
        XCTAssertTrue(matcher.allows(urlString: "https://v.qq.com/x/cover/mzc00200tgcz1s0.html"))
        XCTAssertTrue(matcher.allows(urlString: "https://bilibili.com/"), "bare domain")
        XCTAssertTrue(matcher.allows(urlString: "https://m.bilibili.com/video/x"), "subdomain")
    }

    func testUnverifiedSitesDoNotMatch() {
        // Holding the right arrow here seeks repeatedly instead of speeding up —
        // measured, which is why YouTube is deliberately absent.
        XCTAssertFalse(matcher.allows(urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        // Measured and rejected: hold does nothing at all on these.
        XCTAssertFalse(matcher.allows(urlString: "https://www.mgtv.com/b/900162/24594067.html"))
        XCTAssertFalse(matcher.allows(urlString: "https://tv.sohu.com/v/abc.html"))
        XCTAssertFalse(matcher.allows(urlString: "https://www.acfun.cn/v/ac48819443"))
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

    func testUserAddedDomainsExtendTheBuiltInList() {
        let merged = SiteMatcher(custom: ["v.qq.com"])
        XCTAssertTrue(merged.allows(urlString: "https://v.qq.com/x/cover/a.html"),
                      "a site the user vouched for themselves")
        XCTAssertTrue(merged.allows(urlString: "https://www.bilibili.com/video/x"),
                      "built-ins still apply")
    }

    func testDomainToAddDropsOnlyTheWWWPrefix() {
        XCTAssertEqual(SiteMatcher.domain(toAdd: "https://www.example.com/x"), "example.com")
        XCTAssertEqual(SiteMatcher.domain(toAdd: "https://v.qq.com/x/cover/a.html"), "v.qq.com",
                       "must not be flattened to qq.com: that enables untested sibling sites")
        XCTAssertEqual(SiteMatcher.domain(toAdd: "example.com/path"), "example.com")
        XCTAssertNil(SiteMatcher.domain(toAdd: "chrome://settings"))
        XCTAssertNil(SiteMatcher.domain(toAdd: nil))
    }

    func testStorableCustomDomainsCleansTheList() {
        let cleaned = SiteMatcher.storableCustomDomains(
            ["Example.COM", "example.com", " mgtv.com ", "", "bilibili.com", "m.bilibili.com"]
        )
        XCTAssertEqual(cleaned, ["example.com", "mgtv.com"])
        XCTAssertFalse(cleaned.contains("bilibili.com"), "built-in: nothing to store")
        XCTAssertFalse(cleaned.contains("m.bilibili.com"), "already covered as a subdomain")
    }
}
