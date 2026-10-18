import AppKit
import ApplicationServices
import DiagnosticCore

final class FocusOperation {
    let inventory: Inventory

    init(inventory: Inventory) { self.inventory = inventory }

    func perform(selectionID: String, captured: Snapshot, evidencePrefix: URL,
                 completion: @escaping (Bool) -> Void) {
        let began = Date()
        var result: [String: Any] = [
            "schemaVersion": 1, "captureSnapshotID": captured.id, "selectionID": selectionID,
            "startedTime": ISO8601DateFormatter().string(from: began),
            "identityMethod": inventory.bridge.status, "capturedScope": scopeJSON(captured.scope),
            "frontmostPIDBefore": nullable(NSWorkspace.shared.frontmostApplication?.processIdentifier),
            "visualObservation": NSNull(), "status": "pending", "apiSteps": []
        ]
        var steps: [[String: Any]] = []
        func finish(_ status: String, _ reason: String?) {
            result["status"] = status
            result["reason"] = nullable(reason)
            result["apiSteps"] = steps
            result["finishedTime"] = ISO8601DateFormatter().string(from: Date())
            result["finalScope"] = scopeJSON(inventory.monitor.stamp())
            result["frontmostPIDAfter"] = nullable(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            do { try writeJSON(result, to: evidencePrefix.appendingPathExtension("json")) }
            catch { log("Cannot save focus result: \(error)"); completion(false); return }
            log("Focus \(selectionID): \(status)\(reason.map { " (\($0))" } ?? ""). Visual confirmation must be recorded separately.")
            completion(status == "api_verified_visual_confirmation_required")
        }
        guard AXIsProcessTrusted() else { finish("cancelled", "accessibility_permission_denied"); return }
        guard captured.scope == inventory.monitor.stamp() else { finish("cancelled", "display_or_space_changed"); return }
        guard let original = captured.rows.first(where: { $0.selectionID == selectionID }) else {
            finish("cancelled", "identity_not_in_this_capture"); return
        }
        guard original.eligible else { finish("cancelled", "captured_target_ineligible_or_unresolved"); return }
        let current = inventory.capture()
        do { try writeJSON(current.json, to: URL(fileURLWithPath: evidencePrefix.path + "-before.json")) }
        catch { finish("cancelled", "cannot_save_revalidation_inventory:\(error)"); return }
        result["revalidationSnapshotID"] = current.id
        let refreshed = current.rows.first { $0.selectionID == selectionID }
        result["revalidationExclusionReason"] = nullable(refreshed?.exclusion)
        let owner = (current.json["applications"] as? [[String: Any]])?.first {
            ($0["pid"] as? pid_t) == original.cg?.pid
        }
        result["targetAXWindowsStatus"] = nullable(owner?["axWindowsStatus"])
        let refusal = FocusGuard.refusal(
            capturedScope: captured.scope, currentScope: inventory.monitor.stamp(), trusted: AXIsProcessTrusted(),
            wasEligible: original.eligible, isEligible: refreshed?.eligible == true,
            sameProcess: original.app?.running.launchDate == refreshed?.app?.running.launchDate
                && original.app?.running.executableURL == refreshed?.app?.running.executableURL
                && original.app?.running.isTerminated == false,
            sameAXElement: original.ax.flatMap { old in refreshed?.ax.map { CFEqual(old.element, $0.element) } } == true,
            sameWindowID: original.ax?.id != nil && original.ax?.id == refreshed?.ax?.id,
            captureComplete: captured.complete && current.complete
        )
        if let refusal {
            let status = owner?["axWindowsStatus"] as? String
            if refusal == "target_closed_or_became_ineligible", let status, status != "success" {
                finish("cancelled", "target_ax_unavailable:\(status)")
            } else { finish("cancelled", refusal) }
            return
        }
        guard let target = refreshed?.ax, let app = refreshed?.app?.running, let id = refreshed?.cg?.id else {
            finish("cancelled", "exact_ax_target_unresolved"); return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, inventory.options.timeout)
        AXUIElementSetMessagingTimeout(target.element, inventory.options.timeout)

        func immediateRefusal() -> String? {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            if !AXIsProcessTrusted() { return "accessibility_permission_denied" }
            if captured.scope != inventory.monitor.stamp() { return "display_or_space_changed" }
            if app.isTerminated || app.isHidden { return "owner_terminated_or_hidden" }
            let latestID = inventory.bridge.identify(target.element).0
            if latestID != id { return "exact_target_identity_changed" }
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]],
                  let cg = list.enumerated().map({ CGEntry($0.element, position: $0.offset) }).first(where: {
                      $0.id == id && $0.pid == app.processIdentifier
                  }), cg.layer == 0, let bounds = cg.bounds,
                  connectedDisplays()?.contains(where: { !bounds.intersection($0.bounds).isEmpty }) == true else {
                return "target_no_longer_in_active_display_scope"
            }
            guard readAX(target.element, kAXMinimizedAttribute).bool == false,
                  readAX(target.element, kAXRoleAttribute).text == kAXWindowRole,
                  readAX(target.element, kAXSubroleAttribute).text == kAXStandardWindowSubrole else {
                return "target_became_ineligible_or_unresponsive"
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            if !AXIsProcessTrusted() { return "accessibility_permission_denied" }
            if captured.scope != inventory.monitor.stamp() { return "display_or_space_changed" }
            if app.isTerminated || app.isHidden { return "owner_terminated_or_hidden" }
            return nil
        }

        var actionNames: CFArray?
        let actionsError = AXUIElementCopyActionNames(target.element, &actionNames)
        guard actionsError == .success, (actionNames as? [String])?.contains(kAXRaiseAction) == true else {
            finish("cancelled", "raise_unavailable:\(axError(actionsError))"); return
        }
        if let reason = immediateRefusal() { finish("cancelled", reason); return }
        let raised = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        steps.append(["operation": "AXRaise_before_activation", "result": axError(raised)])
        guard raised == .success else { finish("failed", axError(raised)); return }

        for attribute in [kAXMainAttribute, kAXFocusedAttribute] {
            if let reason = immediateRefusal() { finish("failed", reason); return }
            let error = AXUIElementSetAttributeValue(target.element, attribute as CFString, kCFBooleanTrue)
            steps.append(["operation": "set_\(attribute)", "result": axError(error)])
            if error != .success && error != .attributeUnsupported && error != .notImplemented {
                finish("failed", axError(error)); return
            }
        }
        if let reason = immediateRefusal() { finish("failed", reason); return }
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        steps.append(["operation": "activate_owner_without_all_windows", "result": activated])
        guard activated else { finish("failed", "application_activation_rejected"); return }
        if let reason = immediateRefusal() { finish("failed", reason); return }
        let raisedAgain = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        steps.append(["operation": "AXRaise_after_activation", "result": axError(raisedAgain)])
        guard raisedAgain == .success else { finish("failed", axError(raisedAgain)); return }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, inventory.options.timeout)
        let verifyBegan = ProcessInfo.processInfo.systemUptime
        var matchedSince: TimeInterval?
        var lastObservation: [String: Any] = [:]
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let elapsed = ProcessInfo.processInfo.systemUptime - verifyBegan
            if captured.scope != self.inventory.monitor.stamp() || !AXIsProcessTrusted() {
                timer.invalidate(); finish("failed", "scope_changed_or_permission_revoked_during_focus"); return
            }
            let focusedApp = readAX(system, kAXFocusedApplicationAttribute)
            var focusedPID: pid_t = 0
            let pidError = focusedApp.element.map { AXUIElementGetPid($0, &focusedPID) }
            let focusedWindow = focusedApp.element.map { readAX($0, kAXFocusedWindowAttribute) }
            let focusedID = focusedWindow?.element.flatMap { self.inventory.bridge.identify($0).0 }
            let sameElement = focusedWindow?.element.map { CFEqual($0, target.element) } == true
            let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let matched = focusedApp.error == .success && pidError == .success
                && focusedWindow?.error == .success && sameElement && focusedID == id
                && focusedPID == app.processIdentifier && workspacePID == app.processIdentifier
                && !app.isHidden && !app.isTerminated
                && readAX(target.element, kAXMinimizedAttribute).bool == false
            lastObservation = ["frontmostPID": nullable(workspacePID), "axFocusedPID": nullable(pidError == .success ? focusedPID : nil),
                               "axFocusedWindowID": nullable(focusedID), "sameCapturedAXElement": sameElement,
                               "focusedAppRead": axError(focusedApp.error),
                               "focusedWindowRead": nullable(focusedWindow.map { axError($0.error) })]
            result["verification"] = lastObservation
            if matched {
                if matchedSince == nil { matchedSince = ProcessInfo.processInfo.systemUptime }
                if ProcessInfo.processInfo.systemUptime - matchedSince! >= 0.5 {
                    timer.invalidate(); finish("api_verified_visual_confirmation_required", nil); return
                }
            } else { matchedSince = nil }
            if elapsed >= 3 {
                timer.invalidate(); finish("failed", "focused_owner_and_exact_window_not_verified"); return
            }
        }
    }
}
