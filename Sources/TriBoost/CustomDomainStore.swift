import Foundation
import TriBoostCore

/// Domains the user added from the menu, on top of the measured built-in list.
///
/// The built-in list can only grow when someone re-tests every site and ships a
/// new build. This is the escape hatch: if you find a site where holding the right
/// arrow really does speed the video up, you can enable it yourself, immediately.
final class CustomDomainStore {
    private static let key = "customDomains"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var domains: [String] {
        SiteMatcher.storableCustomDomains((defaults.array(forKey: Self.key) as? [String]) ?? [])
    }

    func add(_ domain: String) {
        defaults.set(SiteMatcher.storableCustomDomains(domains + [domain]), forKey: Self.key)
    }

    func remove(_ domain: String) {
        let d = domain.lowercased()
        defaults.set(domains.filter { $0 != d }, forKey: Self.key)
    }

    func contains(_ domain: String) -> Bool {
        domains.contains(domain.lowercased())
    }

    var matcher: SiteMatcher {
        SiteMatcher(custom: domains)
    }
}
