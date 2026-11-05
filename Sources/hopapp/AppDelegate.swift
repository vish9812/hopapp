import AppKit
import ApplicationServices
import ServiceManagement

struct AccessibilityAccess {
    var isTrusted: () -> Bool
    var request: () -> Void

    static let system = AccessibilityAccess(
        isTrusted: { AXIsProcessTrusted() },
        request: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let menu = NSMenu()
    private let defaults: UserDefaults
    private let accessibility: AccessibilityAccess
    private let loginAccess: LoginItemAccess
    private let stateItem = NSMenuItem()
    private let enableItem = NSMenuItem(title: "Enable hopapp", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginSettingsItem = NSMenuItem(title: "Open Login Items Settings…", action: #selector(openLoginSettings), keyEquivalent: "")
    private let permissionItem = NSMenuItem()
    private let keyboardItem = NSMenuItem()
    private let lastSwitchItem = NSMenuItem()
    private let inputRequestItem = NSMenuItem(title: "Grant Input Monitoring Access…", action: #selector(requestInputMonitoring), keyEquivalent: "")
    private let inputSettingsItem = NSMenuItem(title: "Open Input Monitoring Settings…", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
    private let requestItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var switcher: SwitcherController?
    private(set) var accessibilityTrusted = false

    var requestedEnabled: Bool { defaults.bool(forKey: "enabled") }
    var isEnabled: Bool { requestedEnabled && accessibilityTrusted && (switcher?.isRunning ?? true) }

    init(defaults: UserDefaults = .standard, accessibility: AccessibilityAccess = .system,
         loginAccess: LoginItemAccess = .system) {
        self.defaults = defaults
        self.accessibility = accessibility
        self.loginAccess = loginAccess
        super.init()
        defaults.register(defaults: ["enabled": true])
        menu.autoenablesItems = false
        menu.delegate = self
        addInfo("hopapp")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        addInfo("Option+Tab: switch apps")
        addInfo("Option+`: switch windows")
        keyboardItem.isEnabled = false
        menu.addItem(keyboardItem)
        lastSwitchItem.isEnabled = false
        menu.addItem(lastSwitchItem)
        menu.addItem(.separator())
        enableItem.target = self
        menu.addItem(enableItem)
        loginItem.target = self
        menu.addItem(loginItem)
        loginSettingsItem.target = self
        menu.addItem(loginSettingsItem)
        menu.addItem(.separator())
        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        requestItem.target = self
        menu.addItem(requestItem)
        addAction("Open Accessibility Settings…", #selector(openAccessibilitySettings))
        addAction("Refresh Permission Status", #selector(refreshPermissionStatus))
        inputRequestItem.target = self
        menu.addItem(inputRequestItem)
        inputSettingsItem.target = self
        menu.addItem(inputSettingsItem)
        menu.addItem(.separator())
        addAction("Quit hopapp", #selector(quit), key: "q")
        refreshPermissionStatus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let switcher = SwitcherController()
        self.switcher = switcher
        switcher.onStatusChange = { [weak self] in self?.updateStatus() }
        item.menu = menu
        item.button?.setAccessibilityLabel("hopapp")
        refreshPermissionStatus()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        switcher?.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionStatus()
    }

    @objc func toggleEnabled() {
        defaults.set(!requestedEnabled, forKey: "enabled")
        refreshPermissionStatus()
    }

    @objc func toggleLaunchAtLogin() {
        do {
            switch loginAccess.status() {
            case .enabled, .requiresApproval: try loginAccess.unregister()
            default: try loginAccess.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLoginStatus()
    }

    @objc func openLoginSettings() {
        loginAccess.openSettings()
    }

    private func updateLoginStatus() {
        let status = loginAccess.status()
        loginItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginItem.title = status == .requiresApproval ? "Launch at Login (Approval Required)" : "Launch at Login"
        loginSettingsItem.isHidden = status != .requiresApproval
    }

    @objc func requestAccessibility() {
        accessibility.request()
        refreshPermissionStatus()
    }

    @objc func refreshPermissionStatus() {
        accessibilityTrusted = accessibility.isTrusted()
        switcher?.setEnabled(requestedEnabled && accessibilityTrusted)
        updateStatus()
    }

    private func updateStatus() {
        updateLoginStatus()
        keyboardItem.title = switcher?.status ?? "Keyboard: Stopped"
        lastSwitchItem.isHidden = switcher?.lastError == nil
        lastSwitchItem.title = switcher?.lastError.map { "Last switch: \($0)" } ?? ""
        inputRequestItem.isHidden = switcher?.needsInputMonitoring != true
        inputSettingsItem.isHidden = switcher?.needsInputMonitoring != true
        enableItem.state = requestedEnabled ? .on : .off
        permissionItem.title = "Accessibility: \(accessibilityTrusted ? "Allowed" : "Not allowed")"
        requestItem.isHidden = accessibilityTrusted

        let status: String
        let symbol: String
        if !requestedEnabled {
            status = "Disabled"
            symbol = "pause.circle"
        } else if !accessibilityTrusted {
            status = "Accessibility required"
            symbol = "exclamationmark.circle"
        } else if switcher?.needsInputMonitoring == true {
            status = "Input Monitoring required"
            symbol = "exclamationmark.circle"
        } else if switcher?.isRunning == false {
            status = "Keyboard unavailable"
            symbol = "exclamationmark.circle"
        } else {
            status = "Enabled"
            symbol = "rectangle.on.rectangle"
        }
        stateItem.title = "Status: \(status)"
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "hopapp")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "SA" : ""
            button.toolTip = "hopapp — \(status). \(keyboardItem.title)"
        }
    }

    @objc private func openAccessibilitySettings() {
        openPrivacySettings(pane: "Accessibility", name: "Accessibility")
    }

    @objc private func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refreshPermissionStatus()
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacySettings(pane: "ListenEvent", name: "Input Monitoring")
    }

    private func openPrivacySettings(pane: String, name: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!
        guard !NSWorkspace.shared.open(url) else { return }
        let alert = NSAlert()
        alert.messageText = "Open \(name) settings"
        alert.informativeText = "Open System Settings → Privacy & Security → \(name) and add hopapp with the + button."
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}
