import AppKit
import ApplicationServices
import DiagnosticCore
import XCTest
@testable import hopapp

private final class OffscreenPanel: NSPanel {
    override func orderFrontRegardless() {}
    override func orderOut(_ sender: Any?) {}
}

final class SwitcherOverlayTests: XCTestCase {
    @MainActor
    func testRefreshAndSelectionReuseViewsAndIcons() throws {
        _ = NSApplication.shared
        let panel = OffscreenPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var iconLoads = 0
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let overlay = SwitcherOverlay(panel: panel, iconProvider: { _ in iconLoads += 1; return image },
            visibleFrame: { NSRect(x: 0, y: 0, width: 1440, height: 900) })
        let app = NSRunningApplication.current
        let windows = (1...2).map { SwitchingWindow(id: "\($0)", applicationID: "test", pid: app.processIdentifier) }
        let targets = Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
            (window.id, WindowTarget(window: window, number: UInt32(index + 1), app: app,
                launchDate: app.launchDate, executableURL: app.executableURL,
                element: AXUIElementCreateApplication(app.processIdentifier), title: "Window \(index + 1)"))
        })
        var session = try XCTUnwrap(SwitchingSession(mode: .windows, windows: windows,
            frontmostPID: app.processIdentifier, focusedID: windows[0].id, reverse: false))
        overlay.show(session, targets: targets)
        let content = try XCTUnwrap(panel.contentView as? NSStackView)
        let firstRow = content.arrangedSubviews[1]
        let secondRow = content.arrangedSubviews[2]

        overlay.show(session, targets: targets)
        XCTAssertTrue(panel.contentView === content, "Inventory refresh must retain the overlay content")
        XCTAssertEqual(iconLoads, 1, "Windows of one app should share a cached icon")

        session.advance(mode: .windows, reverse: false)
        overlay.show(session, targets: targets)
        let updated = try XCTUnwrap(panel.contentView as? NSStackView)
        XCTAssertTrue(updated.arrangedSubviews[1] === firstRow, "Cycling should update existing rows")
        XCTAssertTrue(updated.arrangedSubviews[2] === secondRow, "Cycling should preserve unselected rows")
        XCTAssertEqual(iconLoads, 1, "Selection changes must not reload app icons")
        XCTAssertEqual(firstRow.layer?.backgroundColor, NSColor.controlAccentColor.cgColor)
        XCTAssertEqual(secondRow.layer?.backgroundColor, NSColor.clear.cgColor)

        overlay.hide()
        overlay.show(session, targets: targets)
        XCTAssertEqual(iconLoads, 2, "A new session should refresh the app icon")
    }

    @MainActor
    func testScrollingAndRemovingCandidatesRetainContentAndSharedIcon() throws {
        _ = NSApplication.shared
        let panel = OffscreenPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var iconLoads = 0
        let overlay = SwitcherOverlay(panel: panel, iconProvider: { _ in iconLoads += 1; return nil },
            visibleFrame: { NSRect(x: 0, y: 0, width: 1440, height: 900) })
        let app = NSRunningApplication.current
        let windows = (1...12).map { SwitchingWindow(id: "\($0)", applicationID: "test", pid: app.processIdentifier) }
        let targets = Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
            (window.id, WindowTarget(window: window, number: UInt32(index + 1), app: app,
                launchDate: app.launchDate, executableURL: app.executableURL,
                element: AXUIElementCreateApplication(app.processIdentifier), title: window.id))
        })
        var session = try XCTUnwrap(SwitchingSession(mode: .windows, windows: windows,
            frontmostPID: app.processIdentifier, focusedID: nil, reverse: false))
        overlay.show(session, targets: targets)
        let content = try XCTUnwrap(panel.contentView as? NSStackView)
        let retainedRow = content.arrangedSubviews[5]
        for _ in 0..<5 { session.advance(mode: .windows, reverse: false) }
        overlay.show(session, targets: targets)
        XCTAssertTrue(panel.contentView === content, "Scrolling must retain the content view")
        XCTAssertTrue(content.arrangedSubviews.contains { $0 === retainedRow }, "Rows still in view must be reused")
        XCTAssertEqual(content.arrangedSubviews.count, 11, "Only nine rows plus header and footer should be visible")
        XCTAssertEqual(iconLoads, 1, "Missing icons must use a cached fallback while scrolling")

        XCTAssertTrue(session.removeMissing(Set(windows.prefix(3).map(\.id))))
        overlay.show(session, targets: targets)
        XCTAssertTrue(panel.contentView === content)
        XCTAssertEqual(content.arrangedSubviews.count, 5, "Closed candidates must be removed")
        XCTAssertEqual(iconLoads, 1)
        let footer = try XCTUnwrap(content.arrangedSubviews.last as? NSTextField)
        XCTAssertTrue(footer.stringValue.hasPrefix("3 of 3"))
    }
}
