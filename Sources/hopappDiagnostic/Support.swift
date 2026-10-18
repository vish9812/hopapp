import AppKit
import ApplicationServices
import DiagnosticCore
import Darwin

func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func rectangle(_ rect: CGRect) -> [String: Any] {
    ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
}

func axError(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .apiDisabled: return "api_disabled_or_permission_denied"
    case .cannotComplete: return "cannot_complete_or_timeout"
    case .actionUnsupported: return "action_unsupported"
    case .attributeUnsupported: return "attribute_unsupported"
    case .invalidUIElement: return "invalid_ui_element"
    case .noValue: return "no_value"
    default: return "ax_error_\(error.rawValue)"
    }
}

struct AXRead {
    let value: CFTypeRef?
    let error: AXError
    var text: String? { value as? String }
    var bool: Bool? { (value as? NSNumber)?.boolValue }
    var element: AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

func readAX(_ element: AXUIElement, _ attribute: String) -> AXRead {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return AXRead(value: error == .success ? value : nil, error: error)
}

// This opt-in bridge is undocumented. Never substitute title/bounds matching if it fails.
final class WindowIDBridge {
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let function: Function?
    let status: String

    init(enabled: Bool) {
        if enabled, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") {
            function = unsafeBitCast(symbol, to: Function.self)
            status = "experimental_private__AXUIElementGetWindow"
        } else {
            function = nil
            status = enabled ? "private_symbol_unavailable" : "public_only_no_exact_id_bridge"
        }
    }

    func identify(_ element: AXUIElement) -> (CGWindowID?, String) {
        guard let function else { return (nil, status) }
        var id: CGWindowID = 0
        let error = function(element, &id)
        return (error == .success && id != 0 ? id : nil, axError(error))
    }
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let bounds: CGRect
    var signature: String { "\(id):\(bounds.origin.x):\(bounds.origin.y):\(bounds.width):\(bounds.height)" }
    var json: [String: Any] {
        ["id": id, "bounds": rectangle(bounds), "isMain": CGDisplayIsMain(id) != 0,
         "isBuiltin": CGDisplayIsBuiltin(id) != 0, "mirrorsDisplayID": CGDisplayMirrorsDisplay(id)]
    }
}

func connectedDisplays() -> [DisplayInfo]? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.prefix(Int(count)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }.sorted { $0.id < $1.id }
}

final class ScopeMonitor {
    private(set) var spaceGeneration: UInt64 = 0
    private(set) var displayGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceGeneration &+= 1 })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.displayGeneration &+= 1 })
    }

    func stamp() -> ScopeStamp {
        ScopeStamp(spaceGeneration: spaceGeneration, displayGeneration: displayGeneration,
                   displays: (connectedDisplays()?.map(\.signature) ?? ["unavailable"])
                    + ["separateSpaces:\(NSScreen.screensHaveSeparateSpaces)"])
    }
}

func scopeJSON(_ scope: ScopeStamp) -> [String: Any] {
    ["spaceGeneration": scope.spaceGeneration, "displayGeneration": scope.displayGeneration,
     "displaySignatures": scope.displays,
     "activeSpaceIDs": NSNull(), "method": "same_process_notifications_and_display_bounds"]
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data([10])).write(to: url, options: .atomic)
}

struct Options {
    var output = "diagnostics/\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))"
    var delay: Double = 5
    var focusDelay: Double = 5
    var timeout: Float = 0.3
    var budget: Double = 20
    var setup = "unknown; not supplied by operator"
    var privateBridge = false
    var interactive = false
    var focus: String?
    var requestPermission = false

    static let usage = """
    hopappDiagnostic [options]
      --delay SECONDS             Delay capture (default 5)
      --output DIRECTORY          New evidence directory (must not exist)
      --setup TEXT                Manually recorded displays, Spaces, Mission Control settings
      --allow-private-window-id   Opt into undocumented _AXUIElementGetWindow
      --interactive              Keep captured AX identities; accept focus/observe/capture/quit
      --focus PID:WINDOWID        Focus this captured identity after --focus-delay (default 5)
      --focus-delay SECONDS       Also used for interactive focus commands
      --ax-timeout SECONDS        Per-message timeout, 0.05...2 (default 0.3)
      --budget SECONDS            Inventory budget, 1...120 (default 20)
      --request-accessibility    Explicitly request Accessibility access, then exit
      --help                     Show this text
    Public-only mode records metadata but refuses exact-window focus.
    No Screen Recording or Input Monitoring permission is requested.
    """

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw DiagnosticError("Missing value for \(flag)") }
                return arguments[index]
            }
            func number(_ range: ClosedRange<Double>) throws -> Double {
                let text = try value()
                guard let number = Double(text), number.isFinite, range.contains(number) else {
                    throw DiagnosticError("Invalid value for \(flag): \(text)")
                }
                return number
            }
            switch flag {
            case "--output": output = try value()
            case "--setup": setup = try value()
            case "--delay": delay = try number(0...3600)
            case "--focus-delay": focusDelay = try number(0...3600)
            case "--ax-timeout": timeout = Float(try number(0.05...2))
            case "--budget": budget = try number(1...120)
            case "--focus": focus = try value()
            case "--allow-private-window-id": privateBridge = true
            case "--interactive": interactive = true
            case "--request-accessibility": requestPermission = true
            default: throw DiagnosticError("Unknown option: \(flag)")
            }
            index += 1
        }
        if interactive && focus != nil { throw DiagnosticError("Choose --interactive or --focus") }
    }
}

struct DiagnosticError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
