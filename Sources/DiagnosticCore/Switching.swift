import Foundation

public struct SwitchingWindow: Equatable {
    public let id: String
    public let applicationID: String
    public let pid: Int32

    public init(id: String, applicationID: String, pid: Int32) {
        self.id = id
        self.applicationID = applicationID
        self.pid = pid
    }
}

public enum SwitchingMode { case applications, windows }

public struct SwitchingHistory {
    private var windowRanks: [String: UInt64] = [:]
    private var appRanks: [String: UInt64] = [:]
    private var counter: UInt64 = 0
    private var lastFocusedID: String?

    public init() {}

    public mutating func record(_ window: SwitchingWindow?) {
        guard let window else { lastFocusedID = nil; return }
        guard window.id != lastFocusedID else { return }
        counter &+= 1
        windowRanks[window.id] = counter
        appRanks[window.applicationID] = counter
        lastFocusedID = window.id
    }

    public mutating func order(_ windows: [SwitchingWindow]) -> [SwitchingWindow] {
        let windowIDs = Set(windows.map(\.id))
        let appIDs = Set(windows.map(\.applicationID))
        windowRanks = windowRanks.filter { windowIDs.contains($0.key) }
        appRanks = appRanks.filter { appIDs.contains($0.key) }
        return windows.enumerated().sorted { lhs, rhs in
            let leftApp = appRanks[lhs.element.applicationID, default: 0]
            let rightApp = appRanks[rhs.element.applicationID, default: 0]
            if leftApp != rightApp { return leftApp > rightApp }
            let left = windowRanks[lhs.element.id, default: 0]
            let right = windowRanks[rhs.element.id, default: 0]
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
}

public struct SwitchingSession {
    public let mode: SwitchingMode
    public private(set) var windows: [SwitchingWindow]
    public private(set) var selectedIndex: Int
    public var selected: SwitchingWindow { windows[selectedIndex] }

    public init?(mode: SwitchingMode, windows: [SwitchingWindow], frontmostPID: Int32?, focusedID: String?,
                 reverse: Bool, frontmostApplicationID: String? = nil) {
        self.mode = mode
        var seen = Set<String>()
        let originatingApp = frontmostApplicationID ?? windows.first(where: { $0.pid == frontmostPID })?.applicationID
        switch mode {
        case .applications:
            self.windows = windows.filter { seen.insert($0.applicationID).inserted }
        case .windows:
            guard let application = originatingApp else { return nil }
            self.windows = windows.filter { $0.applicationID == application && seen.insert($0.id).inserted }
        }
        guard !self.windows.isEmpty else { return nil }
        let current: Int?
        switch mode {
        case .applications:
            current = self.windows.firstIndex { $0.applicationID == originatingApp }
        case .windows:
            current = self.windows.firstIndex { $0.id == focusedID }
        }
        let count = self.windows.count
        selectedIndex = current.map { ($0 + (reverse ? count - 1 : 1)) % count } ?? 0
    }

    public mutating func advance(mode: SwitchingMode, reverse: Bool) {
        guard mode == self.mode else { return }
        selectedIndex = (selectedIndex + (reverse ? windows.count - 1 : 1)) % windows.count
    }

    public mutating func removeMissing(_ ids: Set<String>) -> Bool {
        let selectedID = selected.id
        windows = windows.filter { ids.contains($0.id) }
        guard !windows.isEmpty else { return false }
        selectedIndex = windows.firstIndex { $0.id == selectedID } ?? min(selectedIndex, windows.count - 1)
        return true
    }
}

public struct ShortcutInput {
    public enum Kind { case down, up, flags }
    public let kind: Kind
    public let key: UInt16
    public let option: Bool
    public let shift: Bool
    public let otherModifiers: Bool

    public init(_ kind: Kind, key: UInt16 = 0, option: Bool, shift: Bool = false, otherModifiers: Bool = false) {
        self.kind = kind
        self.key = key
        self.option = option
        self.shift = shift
        self.otherModifiers = otherModifiers
    }
}

public struct ShortcutResult {
    public var consumed = false
    public var commitID: String?
}

public struct ShortcutRouter {
    public private(set) var session: SwitchingSession?
    private var swallowedKeys = Set<UInt16>()

    public init() {}

    public mutating func cancel() { session = nil }

    public mutating func removeMissing(_ ids: Set<String>) {
        if session?.removeMissing(ids) == false { session = nil }
    }

    public mutating func handle(_ input: ShortcutInput, windows: [SwitchingWindow],
                                frontmostPID: Int32?, focusedID: String?, frontmostApplicationID: String? = nil) -> ShortcutResult {
        if input.kind == .up { return ShortcutResult(consumed: swallowedKeys.remove(input.key) != nil) }
        if input.otherModifiers { cancel(); return ShortcutResult() }
        if input.kind == .flags {
            guard !input.option else { return ShortcutResult() }
            let target = session.flatMap { $0.windows.count > 1 ? $0.selected.id : nil }
            cancel()
            return ShortcutResult(commitID: target)
        }
        if input.key == 53, session != nil {
            cancel()
            swallowedKeys.insert(input.key)
            return ShortcutResult(consumed: true)
        }
        guard input.option else { cancel(); return ShortcutResult() }
        let mode: SwitchingMode
        switch input.key {
        case 48: mode = .applications
        case 50: mode = .windows
        default: return ShortcutResult()
        }
        if session != nil {
            session?.advance(mode: mode, reverse: input.shift)
        } else {
            session = SwitchingSession(mode: mode, windows: windows, frontmostPID: frontmostPID,
                                       focusedID: focusedID, reverse: input.shift, frontmostApplicationID: frontmostApplicationID)
        }
        guard session != nil else { return ShortcutResult() }
        swallowedKeys.insert(input.key)
        return ShortcutResult(consumed: true)
    }
}
