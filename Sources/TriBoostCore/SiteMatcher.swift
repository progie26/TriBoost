import Foundation

/// Decides whether a URL belongs to a site where holding the right arrow key is
/// known — by measurement, not assumption — to engage the player's own speed-up.
public struct SiteMatcher: Sendable {
    /// Registrable domains. A host matches if it equals one of these or is a
    /// subdomain of it, so `www.bilibili.com` matches but `bilibili.com.evil.net`
    /// does not.
    public let domains: [String]

    public init(domains: [String] = SiteMatcher.verifiedDomains) {
        self.domains = domains.map { $0.lowercased() }
    }

    /// Domains verified by driving a real Chrome and reading `video.playbackRate`
    /// while the key was held. See README for what each site does.
    public static let verifiedDomains = [
        "bilibili.com",   // hold -> 3x
        "iqiyi.com",      // hold -> 2x
        "v.qq.com",       // hold -> 3x
    ]

    /// `nil` in, `false` out: if we cannot read the URL we stay disabled rather
    /// than risk firing on an unrelated page.
    public func allows(urlString: String?) -> Bool {
        guard let urlString, let host = Self.host(of: urlString) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Chrome's omnibox drops the scheme (`bilibili.com/video/...`), so fall back to
    /// parsing the leading authority by hand when `URL` cannot.
    static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, url.scheme != nil {
            // Only http(s) pages count; chrome://, file:// and friends never match.
            guard url.scheme == "http" || url.scheme == "https" else { return nil }
            return host.lowercased()
        }

        guard !trimmed.contains("://") else { return nil }
        let authority = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let hostPart = authority.split(separator: "?").first.map(String.init) ?? authority
        let noPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard noPort.contains("."), !noPort.contains(" ") else { return nil }
        return noPort.lowercased()
    }
}
