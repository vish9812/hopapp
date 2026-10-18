import AppKit
import ApplicationServices

final class Session {
    let options: Options
    let inventory: Inventory
    let output: URL
    var captured: Snapshot?
    var busy = true
    var captureNumber = 0
    var focusNumber = 0
    var lastFocusNumber: Int?

    init(options: Options) throws {
        self.options = options
        output = URL(fileURLWithPath: options.output, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw DiagnosticError("Evidence directory already exists: \(output.path). Choose a new --output.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let monitor = ScopeMonitor()
        inventory = Inventory(options: options, monitor: monitor, bridge: WindowIDBridge(enabled: options.privateBridge))
    }

    func start() {
        log("Capturing in \(options.delay)s without activating the harness. Evidence: \(output.path)")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.delay) { self.capture() }
    }

    func capture() {
        busy = true
        captureNumber += 1
        let snapshot = inventory.capture()
        do { try writeJSON(snapshot.json, to: output.appendingPathComponent("inventory-\(captureNumber).json")) }
        catch { log("Cannot save inventory: \(error)"); exit(1) }
        captured = snapshot
        let eligible = snapshot.rows.filter(\.eligible)
        log("Capture \(captureNumber): \(eligible.count) eligible windows; complete=\(snapshot.complete); \(inventory.bridge.status)")
        for row in eligible {
            log("  \(row.selectionID!)  \(row.app?.running.localizedName ?? "unknown app")  \(row.ax?.title ?? "<title unavailable>")")
        }
        if options.interactive {
            busy = false
            if captureNumber == 1 { readCommands() }
            log("Commands: focus PID:WINDOWID | observe TEXT | capture | quit. Focus delay: \(options.focusDelay)s")
        } else if let target = options.focus {
            focus(target)
        } else { exit(snapshot.complete ? 0 : 2) }
    }

    func focus(_ selection: String) {
        guard let snapshot = captured else { return }
        busy = true
        focusNumber += 1
        let number = focusNumber
        log("Focusing captured identity \(selection) in \(options.focusDelay)s. Return to the intended test setup.")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.focusDelay) {
            FocusOperation(inventory: self.inventory).perform(
                selectionID: selection, captured: snapshot,
                evidencePrefix: self.output.appendingPathComponent("focus-\(number)")
            ) { success in
                self.lastFocusNumber = number
                self.busy = false
                if !self.options.interactive { exit(success ? 0 : 2) }
            }
        }
    }

    func readCommands() {
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                DispatchQueue.main.async { self.command(line) }
            }
            DispatchQueue.main.async {
                if !self.busy { exit(0) }
                log("stdin closed during an operation; use Ctrl+C to exit after evidence is written.")
            }
        }
    }

    func command(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        if busy { log("Operation in progress; command ignored."); return }
        switch command {
        case "quit": exit(0)
        case "capture":
            busy = true
            log("New capture in \(options.delay)s; previous identities will be replaced.")
            DispatchQueue.main.asyncAfter(deadline: .now() + options.delay) { self.capture() }
        case "focus":
            guard parts.count == 2 else { log("Usage: focus PID:WINDOWID"); return }
            focus(parts[1])
        case "observe":
            guard parts.count == 2, let lastFocusNumber else { log("Run focus first, then observe TEXT"); return }
            let url = output.appendingPathComponent("observation-\(lastFocusNumber)-\(UUID().uuidString).json")
            do {
                try writeJSON(["focusResult": "focus-\(lastFocusNumber).json", "time": ISO8601DateFormatter().string(from: Date()),
                               "operatorObservation": parts[1]], to: url)
                log("Saved visual observation.")
            } catch { log("Cannot save observation: \(error)") }
        default: log("Unknown command. Use focus PID:WINDOWID, observe TEXT, capture, or quit.")
        }
    }
}

if CommandLine.arguments.contains("--help") {
    print(Options.usage)
    exit(0)
}
do {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let system = AXUIElementCreateSystemWide()
    let timeoutError = AXUIElementSetMessagingTimeout(system, options.timeout)
    guard timeoutError == .success else { throw DiagnosticError("Cannot bound AX timeouts: \(axError(timeoutError))") }
    if options.requestPermission {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("Accessibility trusted: \(trusted). Executable: \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        exit(trusted ? 0 : 2)
    }
    let session = try Session(options: options)
    session.start()
    NSApplication.shared.run()
    withExtendedLifetime(session) {}
} catch {
    log("\(error)\n\n\(Options.usage)")
    exit(1)
}
