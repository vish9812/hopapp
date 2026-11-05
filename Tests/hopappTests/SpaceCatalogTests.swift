import XCTest
@testable import hopapp

final class SpaceCatalogTests: XCTestCase {
    func testWindowMustBelongToAVisibleSpaceAcrossDisplays() {
        let visible: Set<UInt64> = [11, 22]
        XCTAssertEqual(SpaceCatalog.isOnVisibleSpace(windowSpaces: [11], visibleSpaces: visible), true)
        XCTAssertEqual(SpaceCatalog.isOnVisibleSpace(windowSpaces: [22], visibleSpaces: visible), true)
        XCTAssertEqual(SpaceCatalog.isOnVisibleSpace(windowSpaces: [33], visibleSpaces: visible), false)
        XCTAssertEqual(SpaceCatalog.isOnVisibleSpace(windowSpaces: [22, 33], visibleSpaces: visible), true)
        XCTAssertEqual(SpaceCatalog.isOnVisibleSpace(windowSpaces: [11], visibleSpaces: [33]), false)
    }

    func testMissingSpaceInformationCannotEstablishMembership() {
        for unknown: Set<UInt64>? in [nil, [], [0]] {
            XCTAssertNil(SpaceCatalog.isOnVisibleSpace(windowSpaces: unknown, visibleSpaces: [11]))
            XCTAssertNil(SpaceCatalog.isOnVisibleSpace(windowSpaces: [11], visibleSpaces: unknown))
        }
    }
}
