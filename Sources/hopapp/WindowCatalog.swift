import AppKit
import ApplicationServices
import DiagnosticCore
import Darwin

final class FocusValidity {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func cancel() { lock.lock(); valid = false; lock.unlock() }
}

struct WindowTarget {
    let window: SwitchingWindow
    let number: CGWindowID
    let app: NSRunningApplication
    let launchDate: Date?
    let executableURL: URL?
    let element: AXUIElement
    let title: String
    var appName: String { app.localizedName ?? "Application" }

    func hasSameIdentity(as other: WindowTarget) -> Bool {
        window == other.window && launchDate == other.launchDate && executableURL == other.executableURL
            && CFEqual(element, other.element)
    }
}

struct WindowSnapshot {
    let targets: [WindowTarget]
    let focusedID: String?
    let displays: [String]
    let capturedAt: TimeInterval
    let error: String?
}

private struct CatalogWindow {
    let number: CGWindowID
    let pid: pid_t
    let onScreen: Bool
}

final class WindowCatalog {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let identifyFunction: WindowIDFunction?
    private let timeout: Float = 0.1
    private let spaceCatalog = SpaceCatalog()

    init() {
        // The local switcher needs exact AX/CG identity; title and geometry are not unique.
        identifyFunction = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
            .map { unsafeBitCast($0, to: WindowIDFunction.self) }
    }

    var identityAvailable: Bool { identifyFunction != nil }

    private func identify(_ element: AXUIElement) -> CGWindowID? {
        guard let identifyFunction else { return nil }
        var number: CGWindowID = 0
        return identifyFunction(element, &number) == .success && number != 0 ? number : nil
    }

    private func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func displayFingerprint() -> [String]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).map {
            let bounds = CGDisplayBounds($0)
            return "\($0):\(bounds.origin.x):\(bounds.origin.y):\(bounds.width):\(bounds.height)"
        }.sorted()
    }

    private func inventory(includeOffscreen: Bool = false) -> [CatalogWindow]? {
        guard let list = CGWindowListCopyWindowInfo([includeOffscreen ? .optionAll : .optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        let bounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
        var seen = Set<CGWindowID>()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != getpid(),
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary), rect.width > 0, rect.height > 0,
                  bounds.contains(where: { !rect.intersection($0).isEmpty }), seen.insert(number).inserted else { return nil }
            return CatalogWindow(number: number, pid: pid,
                onScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true)
        }
    }

    private func windows(_ application: AXUIElement) -> [AXUIElement]? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(application, kAXWindowsAttribute as CFString, &count) == .success,
              count <= 512 else { return nil }
        if count == 0 { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(application, kAXWindowsAttribute as CFString, 0, count, &values) == .success else { return nil }
        return values as? [AXUIElement]
    }

    func capture() -> WindowSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let displays = displayFingerprint() ?? []
        func snapshot(_ targets: [WindowTarget] = [], focusedID: String? = nil, error: String? = nil) -> WindowSnapshot {
            WindowSnapshot(targets: targets, focusedID: focusedID, displays: displays, capturedAt: started, error: error)
        }
        guard AXIsProcessTrusted() else { return snapshot(error: "Accessibility required") }
        guard identityAvailable else { return snapshot(error: "Exact window identity is unavailable on this macOS version") }
        guard !displays.isEmpty, let entries = inventory(includeOffscreen: true) else { return snapshot(error: "Window inventory unavailable") }
        let visibleSpaces = spaceCatalog.visibleSpaces()
        let deadline = started + 1.2
        var targets: [CGWindowID: WindowTarget] = [:]
        var seenPIDs = Set<pid_t>()
        for entry in entries where seenPIDs.insert(entry.pid).inserted {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return snapshot(error: "Window inventory timed out") }
            guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isHidden, !app.isTerminated,
                  app.activationPolicy != .prohibited else { continue }
            let application = AXUIElementCreateApplication(entry.pid)
            AXUIElementSetMessagingTimeout(application, timeout)
            guard let elements = windows(application) else { continue }
            var mappings: [CGWindowID: [AXUIElement]] = [:]
            for element in elements {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return snapshot(error: "Window inventory timed out") }
                AXUIElementSetMessagingTimeout(element, timeout)
                if let number = identify(element) { mappings[number, default: []].append(element) }
            }
            let appKey = applicationKey(bundleIdentifier: app.bundleIdentifier, pid: entry.pid, launchDate: app.launchDate)
            for candidate in entries where candidate.pid == entry.pid {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return snapshot(error: "Window inventory timed out") }
                guard let matches = mappings[candidate.number], matches.count == 1, let element = matches.first else { continue }
                let facts = WindowFacts(onScreen: candidate.onScreen, layer: 0, intersectsDisplay: true, isSelf: false,
                    hidden: app.isHidden, role: read(element, kAXRoleAttribute) as? String,
                    subrole: read(element, kAXSubroleAttribute) as? String,
                    minimized: (read(element, kAXMinimizedAttribute) as? NSNumber)?.boolValue, exactMatchCount: matches.count)
                guard facts.switcherExclusion(isOnVisibleSpace:
                    spaceCatalog.isOnVisibleSpace(candidate.number, visibleSpaces: visibleSpaces)) == nil else { continue }
                let identity = "\(entry.pid):\(candidate.number):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
                let window = SwitchingWindow(id: identity, applicationID: appKey, pid: entry.pid)
                targets[candidate.number] = WindowTarget(window: window, number: candidate.number, app: app,
                    launchDate: app.launchDate, executableURL: app.executableURL, element: element,
                    title: (read(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Window \(candidate.number)")
            }
        }
        guard displayFingerprint() == displays, spaceCatalog.visibleSpaces() == visibleSpaces, ProcessInfo.processInfo.systemUptime < deadline else {
            return snapshot(error: "Display or Space changed, or window inventory timed out")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var focusedID: String?
        if let app = element(read(system, kAXFocusedApplicationAttribute)) {
            AXUIElementSetMessagingTimeout(app, timeout)
            if let focused = element(read(app, kAXFocusedWindowAttribute)) {
                AXUIElementSetMessagingTimeout(focused, timeout)
                if let number = identify(focused), let target = targets[number], CFEqual(focused, target.element) {
                    focusedID = target.window.id
                }
            }
        }
        let ordered = entries.filter(\.onScreen) + entries.filter { !$0.onScreen }
        return snapshot(ordered.compactMap { targets[$0.number] }, focusedID: focusedID)
    }

    func focus(_ target: WindowTarget, displays: [String], validity: FocusValidity) -> String? {
        let app = target.app
        let application = AXUIElementCreateApplication(target.window.pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        AXUIElementSetMessagingTimeout(target.element, timeout)

        let visibleSpaces = spaceCatalog.visibleSpaces()
        func allowed(restoring: Bool = false) -> Bool {
            guard validity.isValid, AXIsProcessTrusted(), displayFingerprint() == displays,
                  !app.isTerminated, !app.isHidden,
                  let current = NSRunningApplication(processIdentifier: target.window.pid),
                  current.launchDate == target.launchDate, current.executableURL == target.executableURL,
                  identify(target.element) == target.number,
                  let minimized = (read(target.element, kAXMinimizedAttribute) as? NSNumber)?.boolValue,
                  read(target.element, kAXRoleAttribute) as? String == kAXWindowRole,
                  read(target.element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  inventory(includeOffscreen: minimized || restoring)?.contains(where: {
                      guard $0.number == target.number && $0.pid == target.window.pid else { return false }
                      if minimized || restoring {
                          return spaceCatalog.visibleSpaces() == visibleSpaces
                              && spaceCatalog.isOnVisibleSpace(target.number, visibleSpaces: visibleSpaces) == true
                      }
                      return $0.onScreen
                  }) == true else { return false }
            return validity.isValid
        }

        guard allowed(), let currentWindows = windows(application) else { return "Selected window is no longer available" }
        let matches = currentWindows.filter { identify($0) == target.number }
        guard matches.count == 1, CFEqual(matches[0], target.element), allowed() else {
            return "Selected window changed before switching"
        }
        if (read(target.element, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true {
            guard allowed() else { return "Switch cancelled because the window or desktop changed" }
            guard AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                return "Could not restore selected window"
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.0
            while true {
                guard allowed(restoring: true) else { return "Switch cancelled because the window or desktop changed" }
                if (read(target.element, kAXMinimizedAttribute) as? NSNumber)?.boolValue == false, allowed() { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return "Could not restore selected window" }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        guard allowed() else { return "Selected window is no longer available" }
        guard AXUIElementPerformAction(target.element, kAXRaiseAction as CFString) == .success else { return "Could not raise selected window" }
        for attribute in [kAXMainAttribute, kAXFocusedAttribute] {
            guard allowed() else { return "Switch cancelled because the window or desktop changed" }
            let error = AXUIElementSetAttributeValue(target.element, attribute as CFString, kCFBooleanTrue)
            guard error == .success || error == .attributeUnsupported || error == .notImplemented else { return "Window did not accept focus" }
        }
        guard allowed() else { return "Switch cancelled because the window or desktop changed" }
        let activated = DispatchQueue.main.sync { validity.isValid && !app.isHidden && !app.isTerminated && app.activate(options: [.activateIgnoringOtherApps]) }
        guard activated, allowed(), AXUIElementPerformAction(target.element, kAXRaiseAction as CFString) == .success else {
            return "Could not activate selected window"
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var matchedSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard validity.isValid, AXIsProcessTrusted(), displayFingerprint() == displays else { return "Switch cancelled because the desktop changed" }
            var matched = false
            if let focusedApp = element(read(system, kAXFocusedApplicationAttribute)) {
                AXUIElementSetMessagingTimeout(focusedApp, timeout)
                var pid: pid_t = 0
                if AXUIElementGetPid(focusedApp, &pid) == .success, pid == target.window.pid,
                   let focused = element(read(focusedApp, kAXFocusedWindowAttribute)) {
                    AXUIElementSetMessagingTimeout(focused, timeout)
                    matched = identify(focused) == target.number && CFEqual(focused, target.element)
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                }
            }
            if matched {
                if matchedSince == nil { matchedSince = ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime - matchedSince! >= 0.1 { return nil }
            } else { matchedSince = nil }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return "Selected window focus could not be confirmed"
    }
}
