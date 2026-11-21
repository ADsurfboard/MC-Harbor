import Foundation

/// Shared layout math, independent of UIKit and screen scale. Bounded copies
/// provide real previous/next covers at the ends without fake instances.
public struct CoverFlowGeometry: Sendable {
    public let width: Double, height: Double, count: Int
    public let cardWidth: Double, cardHeight: Double, pitch: Double
    // Seven visible positions need three neighbors on each side. Two logical
    // instances therefore need five copies; three or more only need three.
    public var copyCount: Int { count > 1 ? (count == 2 ? 5 : 3) : 1 }
    public var slots: Int { count * copyCount }
    public var contentWidth: Double { width + Double(max(0, slots - 1)) * pitch }
    public init(width: Double, height: Double, count: Int) {
        self.width = max(1, width); self.height = max(1, height); self.count = max(0, min(10_000, count))
        cardHeight = max(1, height - 28)
        cardWidth = max(1, min(width * 0.52, height * 0.91, 330))
        // Leave visible air between the focused cover and its tilted neighbors.
        // Phone edges intentionally reveal a partial cover on either side.
        pitch = cardWidth * 0.90
    }
    public func logical(_ slot: Int) -> Int { count > 0 ? ((slot % count) + count) % count : 0 }
    public func middle(_ logical: Int) -> Int { count > 1 ? (copyCount / 2) * count + self.logical(logical) : 0 }
    public func nearest(_ offset: Double) -> Int { max(0, min(slots - 1, Int((offset / pitch).rounded()))) }
    public func offset(_ slot: Int) -> Double { Double(max(0, min(slots - 1, slot))) * pitch }
    public func closestSlot(for logical: Int, around slot: Int, direction: Int = 0) -> Int {
        guard count > 1 else { return 0 }
        return (0..<copyCount).map { self.logical(logical) + $0 * count }.min {
            if abs($0 - slot) != abs($1 - slot) { return abs($0 - slot) < abs($1 - slot) }
            return direction > 0 ? $0 > $1 : $0 < $1
        } ?? middle(logical)
    }
    public func visible(around offset: Double) -> ClosedRange<Int>? {
        guard slots > 0 else { return nil }
        let center = nearest(offset)
        return max(0, center - 3)...min(slots - 1, center + 3)
    }
    public struct Pose: Sendable {
        public let centerX: Double, centerY: Double, angle: Double, depth: Double, scale: Double, opacity: Double
        public let zIndex: Int
    }
    public func pose(slot: Int, offset: Double, continuous: Bool) -> Pose {
        let distance = continuous ? (Double(slot) * pitch - offset) / pitch : Double(slot - nearest(offset))
        let sign = distance < 0 ? -1.0 : 1.0
        let progress = min(1, abs(distance))
        let side = progress * progress * (3 - 2 * progress)
        let extra = max(0, abs(distance) - 1)
        // Relax the far covers without turning them fully front-on. The far
        // shelf retains a 15-degree inclination; the third neighbor is about
        // 19 degrees. Preserve the smooth peak at the nearest cover.
        let turn = side * (0.26 + (1.03 - 0.26) * exp(-0.60 * extra * extra))
        return .init(centerX: Double(slot) * pitch + width / 2, centerY: height / 2 + side * 6,
                     angle: -sign * turn, depth: -side * 44 - min(2, extra) * 20,
                     scale: 1 - side * 0.08, opacity: max(0.32, 1 - side * 0.15 - extra * 0.15),
                     zIndex: 1000 - Int(abs(distance) * 100))
    }
}

/// The saved order is a preference over installed IDs, never over virtual
/// copies. New profiles are appended in their original order.
public enum CoverFlowOrdering {
    public static func merge(available: [String], saved: [String]) -> [String] {
        var remaining = Set(available)
        return (saved + available).filter { remaining.remove($0) != nil }
    }

    public static func move(_ id: String, to index: Int, in order: [String]) -> [String] {
        guard let source = order.firstIndex(of: id), order.indices.contains(index), source != index else { return order }
        var result = order
        result.remove(at: source)
        result.insert(id, at: index)
        return result
    }
}
