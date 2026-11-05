import AppKit
import ServiceManagement
import XCTest
@testable import hopapp

final class LoginItemTests: XCTestCase {
    @MainActor
    func testToggleAndExternalChangesUseSystemStatus() throws {
        _ = NSApplication.shared
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let access = LoginItemAccess(status: { status }, register: {
            registrations += 1
            status = .enabled
        }, unregister: {
            removals += 1
            status = .notRegistered
        }, openSettings: {})
        let delegate = AppDelegate(accessibility: AccessibilityAccess(isTrusted: { false }, request: {}), loginAccess: access)
        let item = try XCTUnwrap(delegate.menu.items.first { $0.action == #selector(AppDelegate.toggleLaunchAtLogin) })
        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(registrations, 0, "Starting the app must not register a login item")

        delegate.toggleLaunchAtLogin()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(item.state, .on)
        delegate.toggleLaunchAtLogin()
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(item.state, .off)

        status = .enabled
        delegate.menuWillOpen(delegate.menu)
        XCTAssertEqual(item.state, .on, "Menu must reflect changes made in System Settings")
    }

    @MainActor
    func testPendingApprovalCanOpenSettingsOrBeDisabled() throws {
        _ = NSApplication.shared
        var status = SMAppService.Status.notRegistered
        var settingsOpened = false
        let access = LoginItemAccess(status: { status }, register: { status = .requiresApproval },
            unregister: { status = .notRegistered }, openSettings: { settingsOpened = true })
        let delegate = AppDelegate(accessibility: AccessibilityAccess(isTrusted: { false }, request: {}), loginAccess: access)
        let item = try XCTUnwrap(delegate.menu.items.first { $0.action == #selector(AppDelegate.toggleLaunchAtLogin) })
        let settings = try XCTUnwrap(delegate.menu.items.first { $0.action == #selector(AppDelegate.openLoginSettings) })
        XCTAssertTrue(settings.isHidden)

        delegate.toggleLaunchAtLogin()
        XCTAssertEqual(item.state, .mixed, "Pending approval must not be presented as enabled")
        XCTAssertTrue(item.title.contains("Approval Required"))
        XCTAssertFalse(settings.isHidden)
        delegate.openLoginSettings()
        XCTAssertTrue(settingsOpened)

        delegate.toggleLaunchAtLogin()
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(settings.isHidden)
    }
}
