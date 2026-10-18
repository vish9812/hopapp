import AppKit
import ApplicationServices
import DiagnosticCore

final class SwitcherController {
    var onStatusChange: (() -> Void)?
    private let catalog = WindowCatalog()
    private let tap = KeyboardTap()
    private let overlay = SwitcherOverlay()
    private let worker = DispatchQueue(label: "local.switchapps.windows", qos: .userInteractive)
    private var router = ShortcutRouter()
    private var history = SwitchingHistory()
    private var sessionTargets: [String: WindowTarget] = [:]
    private var sessionDisplays: [String] = []
    private var snapshot: WindowSnapshot?
    private var timer: Timer?
    private var observing: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation: UInt64 = 0
    private var captureInFlight = false
    private var active = false
    private var suspended = false
    private var renderScheduled = false
    private var focusValidity: FocusValidity?
    private(set) var status = "Keyboard: Stopped"
    private(set) var lastError: String?
    var isRunning: Bool { tap.isRunning }
    var needsInputMonitoring: Bool { tap.needsInputMonitoring }

    init() {
        tap.onInput = { [weak self] input in self?.handle(input) ?? false }
        tap.onInterruption = { [weak self] in self?.cancelSession(resetKeys: true) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.invalidateScope() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.invalidateScope() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self else { return }
            self.cancelSession()
            self.refreshInventory()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.suspended = true
            self.invalidateScope()
            self.tap.stop()
            self.cancelSession(resetKeys: true)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.invalidateScope()
            self.setEnabled(self.active)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            guard active else { return }
            active = false
            generation &+= 1
            focusValidity?.cancel()
            snapshot = nil
            cancelSession(resetKeys: true)
            tap.stop()
            timer?.invalidate()
            timer = nil
            setStatus("Keyboard: Stopped")
            return
        }
        active = true
        guard !suspended else { return }
        guard catalog.identityAvailable else { setStatus("Exact window identity unavailable on this macOS version"); return }
        guard tap.start() else {
            cancelSession(resetKeys: true)
            setStatus(needsInputMonitoring ? "Keyboard: Input Monitoring required" : "Keyboard: Access unavailable; check Accessibility and relaunch")
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.refreshInventory() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if snapshot == nil { setStatus("Keyboard: Loading windows…") }
        refreshInventory()
    }

    func stop() {
        setEnabled(false)
        for (center, observer) in observing { center.removeObserver(observer) }
        observing.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observing.append((center, observer))
    }

    private func setStatus(_ value: String) {
        guard value != status else { return }
        status = value
        onStatusChange?()
    }

    private func invalidateScope() {
        generation &+= 1
        snapshot = nil
        focusValidity?.cancel()
        cancelSession()
        refreshInventory()
    }

    private func cancelSession(resetKeys: Bool = false) {
        if resetKeys { router = ShortcutRouter() } else { router.cancel() }
        sessionTargets.removeAll()
        sessionDisplays.removeAll()
        scheduleRender()
    }

    private func refreshInventory() {
        guard active, !suspended, tap.isRunning, !captureInFlight else { return }
        captureInFlight = true
        let stamp = generation
        worker.async { [weak self] in
            guard let self else { return }
            let captured = self.catalog.capture()
            DispatchQueue.main.async {
                self.captureInFlight = false
                guard self.active, !self.suspended else { return }
                guard self.generation == stamp else { self.refreshInventory(); return }
                self.snapshot = captured
                if let error = captured.error {
                    self.cancelSession()
                    self.setStatus("Keyboard: \(error)")
                    return
                }
                let windows = captured.targets.map(\.window)
                self.history.record(windows.first { $0.id == captured.focusedID })
                let surviving = captured.targets.filter { target in
                    self.sessionTargets[target.window.id]?.hasSameIdentity(as: target) == true
                }
                self.router.removeMissing(Set(surviving.map { $0.window.id }))
                if self.router.session == nil {
                    self.sessionTargets.removeAll()
                    self.sessionDisplays.removeAll()
                }
                self.scheduleRender()
                self.setStatus("Keyboard: Ready · \(windows.count) windows")
            }
        }
    }

    private func handle(_ input: ShortcutInput) -> Bool {
        let usable = snapshot.flatMap { $0.error == nil && ProcessInfo.processInfo.systemUptime - $0.capturedAt < 2.5 ? $0 : nil }
        if usable == nil { cancelSession() }
        let windows = history.order(usable?.targets.map(\.window) ?? [])
        let wasSwitching = router.session != nil
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appID = frontmost.map { applicationKey(bundleIdentifier: $0.bundleIdentifier, pid: $0.processIdentifier, launchDate: $0.launchDate) }
        let result = router.handle(input, windows: windows, frontmostPID: frontmost?.processIdentifier,
            focusedID: usable?.focusedID, frontmostApplicationID: appID)
        if !wasSwitching, router.session != nil, let usable {
            focusValidity?.cancel()
            sessionTargets = Dictionary(uniqueKeysWithValues: usable.targets.map { ($0.window.id, $0) })
            sessionDisplays = usable.displays
        }
        let selectedTarget = result.commitID.flatMap { sessionTargets[$0] }
        let displays = sessionDisplays
        if router.session == nil {
            sessionTargets.removeAll()
            sessionDisplays.removeAll()
        }
        scheduleRender()
        if let target = selectedTarget {
            let validity = FocusValidity()
            focusValidity?.cancel()
            focusValidity = validity
            let stamp = generation
            worker.async { [weak self] in
                guard let self, validity.isValid else { return }
                let error = self.catalog.focus(target, displays: displays, validity: validity)
                DispatchQueue.main.async {
                    guard validity.isValid, self.active, self.generation == stamp else { return }
                    self.lastError = error
                    if error == nil { self.history.record(target.window) }
                    self.onStatusChange?()
                    self.refreshInventory()
                }
            }
        }
        return result.consumed
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        // Event taps must return promptly; layout and AppKit drawing run after the callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard let session = self.router.session else { self.overlay.hide(); return }
            self.overlay.show(session, targets: self.sessionTargets)
        }
    }
}
