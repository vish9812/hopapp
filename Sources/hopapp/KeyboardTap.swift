import AppKit
import ApplicationServices
import DiagnosticCore

private func keyboardCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardTap>.fromOpaque(context).takeUnretainedValue().receive(type, event)
}

final class KeyboardTap {
    var onInput: ((ShortcutInput) -> Bool)?
    var onInterruption: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var needsInputMonitoring = false
    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if let port {
            if isRunning { return true }
            CGEvent.tapEnable(tap: port, enable: true)
            if isRunning { return true }
            stop()
        }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsInputMonitoring = !CGPreflightListenEventAccess()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        self.port = port
        self.source = source
        needsInputMonitoring = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return isRunning
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
        needsInputMonitoring = false
    }

    fileprivate func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onInterruption?()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: ShortcutInput.Kind
        switch type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .flags
        default: return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let input = ShortcutInput(kind, key: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
            otherModifiers: !flags.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty)
        return onInput?(input) == true ? nil : Unmanaged.passUnretained(event)
    }

    deinit { stop() }
}
