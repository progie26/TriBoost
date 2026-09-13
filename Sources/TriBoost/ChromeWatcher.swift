import AppKit
import ApplicationServices
import TriBoostCore

/// Reads the frontmost Chrome window's URL through the Accessibility API.
///
/// Why not AppleScript: that needs the Automation ("control Google Chrome")
/// permission and counts as scripting the browser. Chrome publishes `AXURL` on its
/// window tree, which is a passive read and works while a video is fullscreen.
///
/// `AXManualAccessibility`, which older guides recommend, is unsupported in current
/// Chrome (it returns `kAXErrorAttributeUnsupported`) and is not needed: the URL
/// lives in the native window tree, not the web content tree.
/// `@unchecked Sendable`: mutable fields are confined to `queue`, and the callbacks
/// are required to be safe to invoke from it.
final class ChromeWatcher: @unchecked Sendable {
    static let chromeBundleID = "com.google.Chrome"

    private var matcher: SiteMatcher
    private let queue = DispatchQueue(label: "app.triboost.chrome")
    private var timer: DispatchSourceTimer?
    private var lastEligible: Bool?
    private var lastFrontmost: Bool?

    /// Called whenever the answer to "is the front tab a site we support?" changes.
    /// Invoked off the main thread.
    var onEligibilityChange: (@Sendable (Bool) -> Void)?
    /// Called when Chrome stops being frontmost.
    var onChromeLostForeground: (@Sendable () -> Void)?
    /// Called whenever Chrome moves in or out of the foreground. Reported apart
    /// from eligibility so the menu can tell "not a supported site" from "Chrome
    /// simply is not in front right now".
    var onFrontmostChange: (@Sendable (Bool) -> Void)?

    init(matcher: SiteMatcher = SiteMatcher()) {
        self.matcher = matcher
    }

    /// Swap the domain list in after the user edits it, without a restart.
    func updateMatcher(_ new: SiteMatcher) {
        queue.async {
            self.matcher = new
            self.lastEligible = nil      // force a re-publish under the new rules
            self.refresh()
        }
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // AX reads are synchronous IPC into Chrome, so they stay off the main
        // thread. Once a second is plenty to notice a tab or navigation change.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(700))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeAppChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier != Self.chromeBundleID {
            lastEligible = false
            lastFrontmost = false
            onFrontmostChange?(false)
            onChromeLostForeground?()
        } else {
            queue.async { [weak self] in self?.refresh() }
        }
    }

    // Written on `queue`, read from the main thread when the menu is built, so
    // both fields go through one small lock rather than being racy.
    private let stateLock = NSLock()
    private var _currentURL: String?
    private var _frontmost = false

    /// Latest known answer, for the menu.
    var currentURL: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentURL
    }

    /// Whether the last poll saw Chrome in front. A one-poll-stale answer is fine
    /// for a label.
    var isChromeFrontmost: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _frontmost
    }

    private func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == Self.chromeBundleID,
              let pid = front?.processIdentifier else {
            // Keep the last known URL: the menu wants to name the site even while
            // Chrome sits behind it, which is the usual case while reading a menu.
            publish(false, frontmost: false, url: currentURL)  // keep the last URL
            return
        }
        let url = Self.frontTabURL(pid: pid)
        publish(matcher.allows(urlString: url), frontmost: true, url: url)
    }

    private func publish(_ eligible: Bool, frontmost: Bool, url: String?) {
        stateLock.lock()
        _currentURL = url
        _frontmost = frontmost
        stateLock.unlock()

        if frontmost != lastFrontmost {
            lastFrontmost = frontmost
            onFrontmostChange?(frontmost)
        }
        guard eligible != lastEligible else { return }
        lastEligible = eligible
        onEligibilityChange?(eligible)
    }


    // MARK: - Accessibility reading

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Walks the focused window looking for `AXURL`, falling back to the omnibox's
    /// text (which Chrome renders without a scheme, e.g. `bilibili.com/video/...`).
    static func frontTabURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = attribute(app, kAXFocusedWindowAttribute as String) else { return nil }
        let window = focused as! AXUIElement

        var url: String?
        var omnibox: String?
        var budget = 400

        func walk(_ element: AXUIElement, _ depth: Int) {
            if depth > 8 || budget <= 0 || url != nil { return }
            budget -= 1

            if let raw = attribute(element, kAXURLAttribute as String) {
                if let asURL = raw as? NSURL, let string = asURL.absoluteString {
                    url = string
                    return
                }
                url = "\(raw)"
                return
            }
            if omnibox == nil,
               (attribute(element, kAXRoleAttribute as String) as? String) == "AXTextField",
               let value = attribute(element, kAXValueAttribute as String) as? String,
               !value.isEmpty {
                omnibox = value
            }
            guard let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
            for child in children { walk(child, depth + 1) }
        }
        walk(window, 0)

        return url ?? omnibox
    }
}
