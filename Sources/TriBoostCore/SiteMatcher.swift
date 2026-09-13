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

    /// The shipped list plus whatever the user added themselves.
    public init(verified: [String] = SiteMatcher.verifiedDomains, custom: [String]) {
        self.init(domains: verified + custom)
    }

    /// Domains verified by driving a real Chrome and reading `video.playbackRate`
    /// while the key was held. See README for what each site does.
    public static let verifiedDomains = [
        "bilibili.com",   // hold -> 3x
        "iqiyi.com",      // hold -> 2x
        "youku.com",      // hold -> 3x
        "v.qq.com",       // hold -> 3x, confirmed by hand while signed in
    ]

    /// `nil` in, `false` out: if we cannot read the URL we stay disabled rather
    /// than risk firing on an unrelated page.
    public func allows(urlString: String?) -> Bool {
        guard let urlString, let host = Self.host(of: urlString) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The domain we would store if the user asked to add this page.
    ///
    /// Only a leading `www.` is dropped. Going further and reducing, say,
    /// `v.qq.com` to `qq.com` would silently enable the gesture across an entire
    /// corporate domain the user never tested.
    public static func domain(toAdd urlString: String?) -> String? {
        guard let urlString, let host = host(of: urlString) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The list worth persisting: lower-cased, de-duplicated, order preserved, and
    /// with anything the built-in list already covers dropped. Storing a built-in
    /// domain would otherwise quietly resurrect it in a future build that removed
    /// it on purpose — which is what happened to Tencent Video.
    public static func storableCustomDomains(_ list: [String]) -> [String] {
        var seen = Set<String>()
        let builtIn = SiteMatcher()
        return list.compactMap { raw in
            let d = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty, !seen.contains(d) else { return nil }
            guard !builtIn.allows(urlString: "https://" + d + "/") else { return nil }
            seen.insert(d)
            return d
        }
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
