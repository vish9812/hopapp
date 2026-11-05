import DiagnosticCore
import XCTest

final class WindowPolicyTests: XCTestCase {
    private func facts(onScreen: Bool = false, minimized: Bool? = true) -> WindowFacts {
        WindowFacts(onScreen: onScreen, layer: 0, intersectsDisplay: true, isSelf: false,
            hidden: false, role: "AXWindow", subrole: "AXStandardWindow",
            minimized: minimized, exactMatchCount: 1)
    }

    func testSwitcherIncludesMinimizedWindowsAbsentFromOnScreenQuery() {
        XCTAssertNil(facts().switcherExclusion(isOnVisibleSpace: true))
        XCTAssertEqual(facts().exclusion, "window_minimized", "Diagnostics retain their visible-window policy")
    }

    func testSwitcherExcludesMinimizedWindowsOnOtherOrUnknownSpaces() {
        XCTAssertNotNil(facts().switcherExclusion(isOnVisibleSpace: false))
        XCTAssertNotNil(facts().switcherExclusion(isOnVisibleSpace: nil))
    }

    func testSwitcherStillExcludesOrdinaryWindowsOnOtherSpaces() {
        XCTAssertNotNil(facts(minimized: false).switcherExclusion(isOnVisibleSpace: true))
        XCTAssertNil(facts(onScreen: true, minimized: false).switcherExclusion(isOnVisibleSpace: true))
    }

    func testMinimizedWindowsStillRequireSafeExactTargets() {
        var window = facts()
        window.hidden = true
        XCTAssertNotNil(window.switcherExclusion(isOnVisibleSpace: true))
        window = facts()
        window.exactMatchCount = 2
        XCTAssertNotNil(window.switcherExclusion(isOnVisibleSpace: true))
        window = facts()
        window.subrole = "AXDialog"
        XCTAssertNotNil(window.switcherExclusion(isOnVisibleSpace: true))
        window = facts()
        window.isSelf = true
        XCTAssertNotNil(window.switcherExclusion(isOnVisibleSpace: true))
        window = facts()
        window.layer = 1
        XCTAssertNotNil(window.switcherExclusion(isOnVisibleSpace: true))
        XCTAssertNotNil(facts(onScreen: true, minimized: nil).switcherExclusion(isOnVisibleSpace: true))
    }
}
