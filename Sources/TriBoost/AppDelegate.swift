import AppKit
import ApplicationServices
import TriBoostCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SpeedController(keySender: CGKeyEmitter())
    private let domainStore = CustomDomainStore()
    private lazy var chrome = ChromeWatcher(matcher: domainStore.matcher)
    private let touches = TouchMonitor()
    private let suppressor = DragClickSuppressor()

    private var isEnabled = true
    private var siteEligible = false
    private var chromeFrontmost = false
    private var gestureState: GestureState = .idle
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionTimer: Timer?
    private var lastTrusted: Bool?
    private var hasShownPermissionAlert = false

    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enableMenuItem = NSMenuItem(title: "启用", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginMenuItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let hideIconMenuItem = NSMenuItem(title: "隐藏菜单栏图标", action: #selector(hideIcon), keyEquivalent: "")
    private let siteMenuItem = NSMenuItem(title: "", action: #selector(toggleCurrentSite), keyEquivalent: "")
    private let customListMenuItem = NSMenuItem(title: "已添加的网站", action: nil, keyEquivalent: "")

    private static let hideIconKey = "hideMenuBarIcon"
    private static let addWarningShownKey = "customDomainWarningShown"

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        buildMenu()
        installSafetyNets()

        // Captured directly so the background callbacks never touch the delegate
        // off the main actor.
        let controller = controller

        controller.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.gestureState = state
                self?.refreshMenu()
            }
        }
        let suppressor = suppressor
        controller.onBoostActive = { active in
            suppressor.isArmed = active
        }
        // Captured like `controller` above, so the background callback never
        // reaches back into the delegate off the main actor.
        let watcher = chrome
        chrome.onEligibilityChange = { [weak self] eligible in
            // Logged so "the gesture did nothing on site X" can be answered from
            // Console.app: it shows exactly what URL was read and what was decided.
            NSLog("TriBoost: eligible=\(eligible) url=\(watcher.currentURL ?? "nil")")
            controller.setEligible(eligible)
            Task { @MainActor in
                self?.siteEligible = eligible
                self?.refreshMenu()
            }
        }
        chrome.onFrontmostChange = { [weak self] frontmost in
            Task { @MainActor in
                self?.chromeFrontmost = frontmost
                self?.refreshMenu()
            }
        }
        chrome.onChromeLostForeground = { [weak self] in
            controller.chromeLostForeground()
            Task { @MainActor in
                self?.siteEligible = false
                self?.refreshMenu()
            }
        }

        NSLog("TriBoost: launched, accessibility trusted = \(hasAccessibility)")

        if hasAccessibility {
            startMonitoring()
        } else {
            presentFirstRunPermissionExplanation()
        }
        // Granting the permission does not relaunch us, so watch for it instead of
        // checking once and giving up.
        startPermissionWatch()
        refreshMenu()
    }

    /// Polls the trust state so that flipping the switch in System Settings takes
    /// effect immediately, with no restart and no second visit to the menu.
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissionChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        checkPermissionChange()
    }

    private func checkPermissionChange() {
        let trusted = hasAccessibility
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        NSLog("TriBoost: accessibility trusted -> \(trusted)")

        if trusted {
            hasShownPermissionAlert = false
            if isEnabled { startMonitoring() }
        } else {
            stopMonitoring()
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Blocking, so the key-up is really on the wire before we exit.
        controller.shutdownSynchronously()
        touches.stop()
        chrome.stop()
        suppressor.stop()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard isEnabled, hasAccessibility else { return }
        let controller = controller
        touches.start { touches, time in
            controller.submit(touches: touches, at: time)
        }
        chrome.start()
        suppressor.start()
        NSLog("TriBoost: monitoring started (click suppression installed = \(suppressor.isInstalled))")
    }

    private func stopMonitoring() {
        controller.shutdown()
        touches.stop()
        chrome.stop()
        suppressor.stop()
        siteEligible = false
    }

    private var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Every path that could otherwise strand the key in the down position.
    private func installSafetyNets() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,   // fast user switch
        ] {
            workspace.addObserver(self, selector: #selector(releaseEverything),
                                  name: name, object: nil)
        }

        // Screen lock is only broadcast on the distributed centre.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(releaseEverything),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )

        // Signals, via GCD so the handler runs on a normal queue rather than in an
        // async-signal context.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            let controller = controller
            source.setEventHandler {
                controller.shutdownSynchronously()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func releaseEverything() {
        controller.shutdown()
    }

    // MARK: - Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppIcon.menuBarImage()

        let menu = NSMenu()
        // We decide what is greyed out ourselves; AppKit's automatic validation
        // would override the site item's enabled state on every menu open.
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        siteMenuItem.target = self
        menu.addItem(siteMenuItem)
        customListMenuItem.submenu = NSMenu()
        menu.addItem(customListMenuItem)
        menu.addItem(.separator())

        enableMenuItem.target = self
        menu.addItem(enableMenuItem)

        loginMenuItem.target = self
        menu.addItem(loginMenuItem)

        hideIconMenuItem.target = self
        menu.addItem(hideIconMenuItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 TriBoost", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = !isIconHidden
    }

    private func refreshMenu() {
        let status = AppStatus.derive(
            enabled: isEnabled,
            hasAccessibility: hasAccessibility,
            chromeFrontmost: chromeFrontmost,
            siteEligible: siteEligible,
            state: gestureState
        )
        statusMenuItem.title = "状态：\(status.localizedDescription)"
        refreshSiteMenuItems()
        enableMenuItem.title = isEnabled ? "停用" : "启用"
        loginMenuItem.state = LaunchAtLogin.isEnabled ? .on : .off
        statusItem.button?.appearsDisabled = !isEnabled || !hasAccessibility
    }

    /// The built-in list only grows when someone re-measures every site and ships a
    /// build. These two items let the user enable a site the moment they find one
    /// that works, and take it back out when a site changes its mind — which is
    /// exactly what Tencent Video did.
    private func refreshSiteMenuItems() {
        let builtIn = SiteMatcher()
        let url = chrome.currentURL
        let domain = SiteMatcher.domain(toAdd: url)

        if let domain {
            if builtIn.allows(urlString: url) {
                siteMenuItem.title = "\(domain)：内置支持"
                siteMenuItem.isEnabled = false
            } else if domainStore.contains(domain) {
                siteMenuItem.title = "移出名单：\(domain)"
                siteMenuItem.isEnabled = true
            } else {
                siteMenuItem.title = "加入名单：\(domain)"
                siteMenuItem.isEnabled = true
            }
        } else {
            siteMenuItem.title = "读不到当前网址"
            siteMenuItem.isEnabled = false
        }

        let custom = domainStore.domains
        customListMenuItem.isHidden = custom.isEmpty
        let submenu = customListMenuItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        for d in custom {
            let item = NSMenuItem(title: "移除 \(d)", action: #selector(removeCustomDomain(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d
            submenu.addItem(item)
        }
        customListMenuItem.submenu = submenu
    }

    @objc private func toggleCurrentSite() {
        guard let domain = SiteMatcher.domain(toAdd: chrome.currentURL) else { return }
        if domainStore.contains(domain) {
            domainStore.remove(domain)
        } else {
            guard confirmAddingIfNeeded(domain) else { return }
            domainStore.add(domain)
        }
        chrome.updateMatcher(domainStore.matcher)
        refreshMenu()
    }

    @objc private func removeCustomDomain(_ sender: NSMenuItem) {
        guard let domain = sender.representedObject as? String else { return }
        domainStore.remove(domain)
        chrome.updateMatcher(domainStore.matcher)
        refreshMenu()
    }

    /// Shown once. Adding the wrong site is not harmless: on a site that does not
    /// implement hold-to-speed, holding the right arrow seeks the video forward
    /// again and again, which is worse than the gesture doing nothing.
    private func confirmAddingIfNeeded(_ domain: String) -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.addWarningShownKey) else { return true }

        let alert = NSAlert()
        alert.messageText = "把 \(domain) 加入名单？"
        alert.informativeText = """
        TriBoost 本身不控制倍速，它只是按住右方向键——倍速是网站自己的功能。

        如果这个网站没有「长按右方向键 = 倍速」，那么三指静止会变成反复快进，视频会一直往前跳。

        请先手动按住右方向键确认一下：视频是变快，还是在跳进度。确认无误再加入。
        """
        alert.addButton(withTitle: "我已确认，加入")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        UserDefaults.standard.set(true, forKey: Self.addWarningShownKey)
        return true
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled {
            if hasAccessibility {
                startMonitoring()
            } else {
                presentFirstRunPermissionExplanation()
            }
        } else {
            stopMonitoring()
        }
        refreshMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        refreshMenu()
    }

    // MARK: - Hiding the icon

    /// Hides the status item while the app keeps running and boosting. The only way
    /// back is to launch TriBoost again (Spotlight, Launchpad, Finder), which
    /// `applicationShouldHandleReopen` turns into "show the icon and open the menu".
    @objc private func hideIcon() {
        let alert = NSAlert()
        alert.messageText = "隐藏菜单栏图标"
        alert.informativeText = """
        TriBoost 会继续在后台工作，三指倍速照常可用。

        需要重新显示图标时，用 Spotlight（⌘ 空格）搜索「TriBoost」并回车——图标会立刻回来并自动展开菜单，届时可以再次隐藏或退出。
        """
        alert.addButton(withTitle: "隐藏")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setIconHidden(true)
    }

    private func setIconHidden(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: Self.hideIconKey)
        statusItem.isVisible = !hidden
    }

    private var isIconHidden: Bool {
        UserDefaults.standard.bool(forKey: Self.hideIconKey)
    }

    /// Re-launching an already-running LSUIElement app lands here. That is our way
    /// back from a hidden icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        revealIcon()
        return true
    }

    private func revealIcon() {
        setIconHidden(false)
        checkPermissionChange()
        refreshMenu()
        // Pop the menu so the relaunch produces something visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Permissions

    private func presentFirstRunPermissionExplanation() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        let alert = NSAlert()
        alert.messageText = "TriBoost 需要「辅助功能」权限"
        alert.informativeText = """
        用途只有两个：

        • 读取 Chrome 当前标签页的网址，判断是否为支持的视频网站
        • 发送右方向键的按下与松开事件

        TriBoost 不联网，不读取网页内容，也不会修改任何系统手势设置。
        授权后请从菜单栏重新启用。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            // Prompts the system dialog and reveals the pane.
            // The constant itself is a mutable global, so use its documented value.
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Menu freshness

extension AppDelegate: NSMenuDelegate {
    /// Recompute right before the menu is drawn, so the status line is never stale
    /// — in particular after the accessibility switch was flipped.
    func menuWillOpen(_ menu: NSMenu) {
        checkPermissionChange()
        refreshMenu()
    }
}
