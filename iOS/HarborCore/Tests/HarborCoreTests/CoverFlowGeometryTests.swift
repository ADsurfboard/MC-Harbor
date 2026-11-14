import XCTest
@testable import HarborCore

final class CoverFlowGeometryTests: XCTestCase {
    func testPortraitLandscapeAndTabletKeepRealNeighborsVisible() {
        for (width, height) in [(320.0, 268.0), (430, 268), (360, 190), (500, 190), (1024, 300)] {
            let layout = CoverFlowGeometry(width: width, height: height, count: 5)
            let selected = layout.middle(0), offset = layout.offset(selected)
            let middle = layout.pose(slot: selected, offset: offset, continuous: true)
            let left = layout.pose(slot: selected - 1, offset: offset, continuous: true)
            let right = layout.pose(slot: selected + 1, offset: offset, continuous: true)
            XCTAssertEqual(middle.centerX - offset, width / 2, accuracy: 0.001)
            XCTAssertLessThan(left.centerX - offset, width / 2 - layout.cardWidth / 2)
            XCTAssertGreaterThan(right.centerX - offset, width / 2 + layout.cardWidth / 2)
            let half = layout.cardWidth * cos(abs(left.angle)) * left.scale / 2
            XCTAssertGreaterThanOrEqual(left.centerX - offset - half, 0)
            XCTAssertLessThanOrEqual(right.centerX - offset + half, width)
            XCTAssertEqual(left.angle, -right.angle, accuracy: 0.001)
            XCTAssertLessThan(left.zIndex, middle.zIndex)
        }
    }
    func testCopiesWrapWithoutAddingLogicalInstances() {
        let layout = CoverFlowGeometry(width: 390, height: 268, count: 2)
        XCTAssertEqual(layout.slots, 6)
        XCTAssertEqual(layout.logical(layout.middle(0) - 1), 1)
        XCTAssertEqual(layout.logical(layout.middle(1) + 1), 0)
        XCTAssertEqual(layout.closestSlot(for: 0, around: 3), 2)
        XCTAssertEqual(layout.nearest(-100), 0)
        XCTAssertEqual(layout.nearest(100_000), 5)
        XCTAssertNil(CoverFlowGeometry(width: 390, height: 268, count: 0).visible(around: 0))
        XCTAssertEqual(CoverFlowGeometry(width: 390, height: 268, count: 1).slots, 1)
    }
}
