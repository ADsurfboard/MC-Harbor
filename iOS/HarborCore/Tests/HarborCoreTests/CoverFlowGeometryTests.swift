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
            XCTAssertGreaterThanOrEqual(left.centerX - offset, 8, "The neighbor's center should stay inside the phone")
            XCTAssertLessThanOrEqual(right.centerX - offset, width - 8)
            let half = layout.cardWidth * cos(abs(left.angle)) * left.scale / 2
            // The edge may clip part of a neighbor on a narrow phone, but a
            // useful part must remain visible rather than an unreadable sliver.
            let visibleLeft = max(0, min(width, left.centerX - offset + half) - max(0, left.centerX - offset - half))
            XCTAssertGreaterThanOrEqual(visibleLeft, max(24, half * 0.8))
            XCTAssertGreaterThan(right.centerX - offset - half - (width / 2 + layout.cardWidth / 2), 8)
            XCTAssertGreaterThan((width / 2 - layout.cardWidth / 2) - (left.centerX - offset + half), 8)
            XCTAssertEqual(left.angle, -right.angle, accuracy: 0.001)
            XCTAssertLessThan(left.zIndex, middle.zIndex)
        }
    }
    func testFarCoversProgressivelyFaceThePlayerWithoutClosingGaps() {
        let layout = CoverFlowGeometry(width: 1376, height: 300, count: 8)
        let selected = layout.middle(0), offset = layout.offset(selected)
        for direction in [-1, 1] {
            var previousAngle = Double.infinity
            var previousRight = layout.cardWidth / 2
            for step in 1...3 {
                let pose = layout.pose(slot: selected + direction * step, offset: offset, continuous: true)
                XCTAssertLessThan(abs(pose.angle), previousAngle)
                let projectedHalf = layout.cardWidth * cos(pose.angle) * pose.scale / 2
                let distance = abs(pose.centerX - offset - layout.width / 2)
                XCTAssertGreaterThan(distance - projectedHalf - previousRight, 8)
                previousAngle = abs(pose.angle)
                previousRight = distance + projectedHalf
            }
            XCTAssertLessThan(previousAngle, 0.11, "The third cover should be nearly front facing")
        }
    }
    func testTransformsStayContinuousAtCenterAndMaximumTilt() {
        let layout = CoverFlowGeometry(width: 430, height: 268, count: 5)
        let selected = layout.middle(0)
        for distance in [-2.0, -1, 0, 1, 2] {
            let offset = layout.offset(selected) - distance * layout.pitch
            let a = layout.pose(slot: selected, offset: offset - 0.001, continuous: true)
            let b = layout.pose(slot: selected, offset: offset + 0.001, continuous: true)
            XCTAssertEqual(a.angle, b.angle, accuracy: 0.0001)
            XCTAssertEqual(a.scale, b.scale, accuracy: 0.0001)
            XCTAssertEqual(a.depth, b.depth, accuracy: 0.001)
        }
    }
    func testOptimizationKeepsStaticPosesDuringScroll() {
        let layout = CoverFlowGeometry(width: 430, height: 268, count: 5)
        let selected = layout.middle(0)
        for step in -3...3 {
            let a = layout.pose(slot: selected + step, offset: layout.offset(selected), continuous: false)
            let b = layout.pose(slot: selected + step, offset: layout.offset(selected) + layout.pitch * 0.2, continuous: false)
            XCTAssertEqual(a.angle, b.angle)
            XCTAssertEqual(a.depth, b.depth)
            XCTAssertEqual(a.scale, b.scale)
            XCTAssertEqual(a.opacity, b.opacity)
        }
    }
    func testCopiesWrapWithoutAddingLogicalInstances() {
        let layout = CoverFlowGeometry(width: 390, height: 268, count: 2)
        XCTAssertEqual(layout.slots, 10)
        XCTAssertEqual(layout.logical(layout.middle(0) - 1), 1)
        XCTAssertEqual(layout.logical(layout.middle(1) + 1), 0)
        XCTAssertEqual(layout.closestSlot(for: 0, around: layout.middle(1)), 4)
        XCTAssertEqual(layout.closestSlot(for: 0, around: layout.middle(1), direction: 1), 6)
        XCTAssertEqual(layout.closestSlot(for: 0, around: layout.middle(1), direction: -1), 4)
        XCTAssertEqual(layout.nearest(-100), 0)
        XCTAssertEqual(layout.nearest(100_000), 9)
        XCTAssertNil(CoverFlowGeometry(width: 390, height: 268, count: 0).visible(around: 0))
        XCTAssertEqual(CoverFlowGeometry(width: 390, height: 268, count: 1).slots, 1)
    }
    func testEveryLogicalPositionHasThreeSymmetricNeighbors() throws {
        for count in 2...8 {
            let layout = CoverFlowGeometry(width: 1376, height: 268, count: count)
            for logical in 0..<count {
                let selected = layout.middle(logical)
                let range = try XCTUnwrap(layout.visible(around: layout.offset(selected)))
                XCTAssertEqual(range.lowerBound, selected - 3)
                XCTAssertEqual(range.upperBound, selected + 3)
                for step in 1...3 {
                    XCTAssertEqual(layout.logical(selected + step), (logical + step) % count)
                    XCTAssertEqual(layout.logical(selected - step), (logical - step + count * 2) % count)
                }
            }
        }
    }
}
