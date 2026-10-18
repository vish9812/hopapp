import Foundation

public struct WindowFacts {
    public var onScreen: Bool
    public var layer: Int?
    public var intersectsDisplay: Bool?
    public var isSelf: Bool
    public var hidden: Bool?
    public var role: String?
    public var subrole: String?
    public var minimized: Bool?
    public var exactMatchCount: Int

    public init(onScreen: Bool, layer: Int?, intersectsDisplay: Bool?, isSelf: Bool,
                hidden: Bool?, role: String?, subrole: String?, minimized: Bool?, exactMatchCount: Int) {
        self.onScreen = onScreen
        self.layer = layer
        self.intersectsDisplay = intersectsDisplay
        self.isSelf = isSelf
        self.hidden = hidden
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
        self.exactMatchCount = exactMatchCount
    }

    public func switcherExclusion(isOnVisibleSpace: Bool?) -> String? {
        var facts = self
        if minimized == true {
            guard let isOnVisibleSpace else { return "window_space_unavailable" }
            guard isOnVisibleSpace else { return "window_on_other_space" }
            // Space membership replaces on-screen presence only for minimized windows.
            facts.onScreen = true
            facts.minimized = false
        }
        return facts.exclusion
    }

    public var exclusion: String? {
        if isSelf { return "diagnostic_itself" }
        if hidden == true { return "application_hidden" }
        if minimized == true { return "window_minimized" }
        if !onScreen { return "absent_from_on_screen_query" }
        guard let layer else { return "layer_unavailable" }
        if layer != 0 { return "non_normal_layer" }
        guard let intersectsDisplay else { return "bounds_or_displays_unavailable" }
        if !intersectsDisplay { return "outside_connected_displays" }
        if exactMatchCount == 0 { return "exact_ax_target_unresolved" }
        if exactMatchCount != 1 { return "exact_ax_target_ambiguous" }
        guard hidden != nil else { return "application_state_unavailable" }
        guard role == "AXWindow", subrole == "AXStandardWindow" else {
            return role == nil || subrole == nil ? "ax_role_unavailable" : "non_standard_window"
        }
        guard let minimized else { return "minimized_state_unavailable" }
        return minimized ? "window_minimized" : nil
    }
}

public func applicationKey(bundleIdentifier: String?, pid: Int32, launchDate: Date?) -> String {
    if let bundleIdentifier, !bundleIdentifier.isEmpty { return "bundle:\(bundleIdentifier)" }
    return "process:\(pid):\(launchDate.map { String($0.timeIntervalSince1970) } ?? "launch-unknown")"
}

public struct ScopeStamp: Equatable {
    public var spaceGeneration: UInt64
    public var displayGeneration: UInt64
    public var displays: [String]

    public init(spaceGeneration: UInt64, displayGeneration: UInt64, displays: [String]) {
        self.spaceGeneration = spaceGeneration
        self.displayGeneration = displayGeneration
        self.displays = displays.sorted()
    }
}

public struct FocusGuard {
    public static func refusal(capturedScope: ScopeStamp, currentScope: ScopeStamp,
                               trusted: Bool, wasEligible: Bool, isEligible: Bool,
                               sameProcess: Bool, sameAXElement: Bool,
                               sameWindowID: Bool, captureComplete: Bool) -> String? {
        if !trusted { return "accessibility_permission_denied" }
        if capturedScope != currentScope { return "display_or_space_changed" }
        if !captureComplete { return "inventory_incomplete" }
        if !wasEligible { return "captured_target_ineligible_or_unresolved" }
        if !isEligible { return "target_closed_or_became_ineligible" }
        if !sameProcess { return "owner_process_changed" }
        if !sameAXElement || !sameWindowID { return "exact_target_identity_changed" }
        return nil
    }
}
