import AppKit
import ApplicationServices
import DiagnosticCore

struct CGEntry {
    let id: CGWindowID?
    let pid: pid_t?
    let layer: Int?
    let bounds: CGRect?
    let title: String?
    let ownerName: String?
    let position: Int

    init(_ info: [String: Any], position: Int) {
        id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
        title = info[kCGWindowName as String] as? String
        ownerName = info[kCGWindowOwnerName as String] as? String
        if let dictionary = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: dictionary)
        } else { bounds = nil }
        self.position = position
    }

    var json: [String: Any] {
        ["windowID": nullable(id), "ownerPID": nullable(pid), "layer": nullable(layer),
         "bounds": nullable(bounds.map(rectangle)), "title": nullable(title),
         "titleAvailable": title != nil, "ownerName": nullable(ownerName),
         "frontToBackPosition": position]
    }
}

struct AXWindow {
    let element: AXUIElement
    let id: CGWindowID?
    let role: String?
    let subrole: String?
    let minimized: Bool?
    let title: String?
    let bounds: CGRect?
    let errors: [String: String]
    let bridgeStatus: String

    var json: [String: Any] {
        ["windowID": nullable(id), "role": nullable(role), "subrole": nullable(subrole),
         "minimized": nullable(minimized), "title": nullable(title), "titleAvailable": title != nil,
         "bounds": nullable(bounds.map(rectangle)), "attributeErrors": errors,
         "identityBridgeStatus": bridgeStatus]
    }
}

struct AppInfo {
    let running: NSRunningApplication
    let windows: [AXWindow]
    let windowsStatus: String

    var key: String {
        applicationKey(bundleIdentifier: running.bundleIdentifier, pid: running.processIdentifier,
                       launchDate: running.launchDate)
    }
    var json: [String: Any] {
        let bundle = running.bundleURL.flatMap { Bundle(url: $0) }
        return ["key": key, "pid": running.processIdentifier,
                "bundleIdentifier": nullable(running.bundleIdentifier), "name": nullable(running.localizedName),
                "bundlePath": nullable(running.bundleURL?.path), "executablePath": nullable(running.executableURL?.path),
                "version": nullable(bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
                "build": nullable(bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
                "launchTime": nullable(running.launchDate.map { ISO8601DateFormatter().string(from: $0) }),
                "hidden": running.isHidden, "activationPolicy": running.activationPolicy.rawValue,
                "axWindowsStatus": windowsStatus]
    }
}

struct CapturedWindow {
    let cg: CGEntry?
    let app: AppInfo?
    let ax: AXWindow?
    let matches: Int
    let exclusion: String?
    var eligible: Bool { exclusion == nil }
    var selectionID: String? {
        guard let id = cg?.id, let pid = cg?.pid else { return nil }
        return "\(pid):\(id)"
    }
    var json: [String: Any] {
        ["selectionID": nullable(selectionID), "cg": nullable(cg?.json), "application": nullable(app?.json),
         "ax": nullable(ax?.json), "exactAXTargetResolved": matches == 1,
         "exactAXMatchCount": matches, "eligible": eligible, "exclusionReason": nullable(exclusion)]
    }
}

struct Snapshot {
    let id: String
    let scope: ScopeStamp
    let rows: [CapturedWindow]
    let complete: Bool
    let json: [String: Any]
}

final class Inventory {
    let options: Options
    let monitor: ScopeMonitor
    let bridge: WindowIDBridge

    init(options: Options, monitor: ScopeMonitor, bridge: WindowIDBridge) {
        self.options = options
        self.monitor = monitor
        self.bridge = bridge
    }

    func capture() -> Snapshot {
        let began = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + options.budget
        let id = UUID().uuidString
        let scope = monitor.stamp()
        let displays = connectedDisplays()
        let trusted = AXIsProcessTrusted()
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cgResult = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let cgEntries = (cgResult as? [[String: Any]])?.enumerated().map { CGEntry($0.element, position: $0.offset) } ?? []
        var complete = cgResult != nil && displays != nil && trusted
        var issues: [String] = []
        if cgResult == nil { issues.append("cg_query_failed") }
        if displays == nil { issues.append("display_query_failed") }
        if !trusted { issues.append("accessibility_permission_denied") }
        let owners = Set(cgEntries.compactMap(\.pid))
        var apps: [pid_t: AppInfo] = [:]
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular || owners.contains($0.processIdentifier)
        }.sorted { $0.processIdentifier < $1.processIdentifier }

        for running in candidates {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                complete = false
                issues.append("inventory_budget_exhausted")
                break
            }
            let pid = running.processIdentifier
            if !trusted || pid == getpid() || running.activationPolicy == .prohibited {
                apps[pid] = AppInfo(running: running, windows: [], windowsStatus:
                    !trusted ? "accessibility_permission_denied" : "not_inspected_self_or_system_process")
                continue
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, options.timeout)
            var count: CFIndex = 0
            let countError = AXUIElementGetAttributeValueCount(application, kAXWindowsAttribute as CFString, &count)
            var elements: CFArray?
            let arrayError: AXError
            if countError == .success && count > 0 {
                arrayError = AXUIElementCopyAttributeValues(application, kAXWindowsAttribute as CFString,
                                                          0, min(count, 512), &elements)
            } else { arrayError = countError }
            if count > 512 { complete = false; issues.append("ax_window_limit_exceeded:\(pid)") }
            var windows: [AXWindow] = []
            if arrayError == .success, let elements = elements as? [AXUIElement] {
                for element in elements {
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        complete = false; issues.append("inventory_budget_exhausted:\(pid)"); break
                    }
                    windows.append(inspect(element, deadline: deadline))
                }
            }
            if arrayError != .success {
                // An unresponsive unrelated application is recorded; resolved targets remain usable.
                issues.append("ax_windows:\(pid):\(axError(arrayError))")
            }
            apps[pid] = AppInfo(running: running, windows: windows, windowsStatus: axError(arrayError))
        }

        var rows: [CapturedWindow] = []
        var seen = Set<String>()
        for cg in cgEntries {
            let key = "\(cg.pid ?? -1):\(cg.id ?? 0)"
            if cg.id != nil && !seen.insert(key).inserted { continue }
            let app = cg.pid.flatMap { apps[$0] }
            let matches = app?.windows.filter { $0.id != nil && $0.id == cg.id } ?? []
            let ax = matches.count == 1 ? matches.first : nil
            let intersects: Bool? = cg.bounds.flatMap { bounds in
                displays.map { $0.contains { !bounds.intersection($0.bounds).isEmpty } }
            }
            let facts = WindowFacts(onScreen: true, layer: cg.layer, intersectsDisplay: intersects,
                                    isSelf: cg.pid == getpid(), hidden: app?.running.isHidden,
                                    role: ax?.role, subrole: ax?.subrole, minimized: ax?.minimized,
                                    exactMatchCount: matches.count)
            rows.append(CapturedWindow(cg: cg, app: app, ax: ax, matches: matches.count, exclusion: facts.exclusion))
        }
        for app in apps.values.sorted(by: { $0.running.processIdentifier < $1.running.processIdentifier }) {
            for ax in app.windows {
                if let id = ax.id, seen.contains("\(app.running.processIdentifier):\(id)") { continue }
                let reason: String
                if app.running.isHidden { reason = "application_hidden" }
                else if ax.minimized == true { reason = "window_minimized" }
                else { reason = ax.id == nil ? "ax_window_unresolved_no_scope_identity" : "absent_from_on_screen_query" }
                rows.append(CapturedWindow(cg: nil, app: app, ax: ax, matches: 0, exclusion: reason))
            }
        }
        // Drain notifications queued while synchronous AX requests were in flight.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        if scope != monitor.stamp() { complete = false; issues.append("scope_changed_during_capture") }
        if ProcessInfo.processInfo.systemUptime >= deadline { complete = false }
        let eligible = rows.filter(\.eligible)
        let grouped = Dictionary(grouping: eligible, by: { $0.app!.key }).map { key, windows -> [String: Any] in
            ["key": key, "ownerPIDs": Array(Set(windows.compactMap { $0.cg?.pid })).sorted(),
             "selectionIDs": windows.compactMap(\.selectionID)]
        }.sorted { ($0["key"] as! String) < ($1["key"] as! String) }
        let json: [String: Any] = [
            "schemaVersion": 1, "snapshotID": id,
            "captureTime": ISO8601DateFormatter().string(from: began),
            "finishedTime": ISO8601DateFormatter().string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "executablePath": Bundle.main.executablePath ?? CommandLine.arguments[0],
            "bundleIdentifier": nullable(Bundle.main.bundleIdentifier), "pid": getpid(),
            "permissions": ["accessibilityTrusted": trusted, "screenRecordingPreflight": CGPreflightScreenCaptureAccess(),
                            "inputMonitoring": "not_requested_or_tested"],
            "manualDisplaySpaceConfiguration": options.setup,
            "screensHaveSeparateSpaces": NSScreen.screensHaveSeparateSpaces,
            "displays": nullable(displays?.map(\.json)), "scope": scopeJSON(scope),
            "identityMethod": bridge.status, "complete": complete, "issues": issues,
            "axTimeoutSeconds": options.timeout, "inventoryBudgetSeconds": options.budget,
            "frontmostPIDBefore": nullable(frontmostBefore),
            "frontmostPIDAfter": nullable(NSWorkspace.shared.frontmostApplication?.processIdentifier),
            "windows": rows.map(\.json), "eligibleApplications": grouped,
            "applications": apps.values.sorted { $0.running.processIdentifier < $1.running.processIdentifier }.map(\.json),
            "scopeQualification": "CG on-screen query is a hypothesis; confirm against visual observations"
        ]
        return Snapshot(id: id, scope: scope, rows: rows, complete: complete, json: json)
    }

    private func inspect(_ element: AXUIElement, deadline: TimeInterval) -> AXWindow {
        AXUIElementSetMessagingTimeout(element, options.timeout)
        var errors: [String: String] = [:]
        func read(_ attribute: String) -> AXRead {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                errors[attribute] = "inventory_budget_exhausted"
                return AXRead(value: nil, error: .cannotComplete)
            }
            let result = readAX(element, attribute)
            if result.error != .success { errors[attribute] = axError(result.error) }
            return result
        }
        let role = read(kAXRoleAttribute).text
        let subrole = read(kAXSubroleAttribute).text
        let minimized = read(kAXMinimizedAttribute).bool
        let title = read(kAXTitleAttribute).text
        let position = read(kAXPositionAttribute).value
        let size = read(kAXSizeAttribute).value
        var bounds: CGRect?
        if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &point),
               AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                bounds = CGRect(origin: point, size: dimensions)
            }
        }
        let identity = ProcessInfo.processInfo.systemUptime < deadline
            ? bridge.identify(element) : (nil, "inventory_budget_exhausted")
        return AXWindow(element: element, id: identity.0, role: role, subrole: subrole,
                        minimized: minimized, title: title, bounds: bounds, errors: errors, bridgeStatus: identity.1)
    }
}
