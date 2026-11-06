import ApplicationServices
import DiagnosticCore
import XCTest

final class FocusStepTests: XCTestCase {
    func testRaiseOrFocusRejectedAsUnsupportedIsNotFatal() {
        XCTAssertTrue(FocusStep.accepts(.success))
        XCTAssertTrue(FocusStep.accepts(.attributeUnsupported), "System Settings answers AXRaise with attributeUnsupported yet still activates")
        XCTAssertTrue(FocusStep.accepts(.actionUnsupported))
        XCTAssertTrue(FocusStep.accepts(.notImplemented))
    }

    func testRealFailuresStillAbortTheSwitch() {
        for error: AXError in [.failure, .cannotComplete, .invalidUIElement, .illegalArgument, .apiDisabled] {
            XCTAssertFalse(FocusStep.accepts(error), "\(error.rawValue) means the target cannot be trusted to receive focus")
        }
    }
}
