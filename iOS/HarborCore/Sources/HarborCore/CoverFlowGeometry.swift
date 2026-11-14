import Foundation

/// Shared layout math, independent of UIKit and screen scale. Three bounded
/// copies provide real previous/next covers at the ends without fake instances.
public struct CoverFlowGeometry: Sendable {
    public let width: Double, height: Double, count: Int
    public let cardWidth: Double, cardHeight: Double, pitch: Double
    public var slots: Int { count > 1 ? count * 3 : count }
    public var contentWidth: Double { width + Double(max(0, slots - 1)) * pitch }
    public init(width: Double, height: Double, count: Int) {
        self.width = max(1, width); self.height = max(1, height); self.count = max(0, min(10_000, count))
        cardHeight = max(1, height - 28)
        cardWidth = max(1, min(width * 0.58, height * 0.91, 330))
        pitch = cardWidth * 0.56
    }
    public func logical(_ slot: Int) -> Int { count > 0 ? ((slot % count) + count) % count : 0 }
    public func middle(_ logical: Int) -> Int { count > 1 ? count + self.logical(logical) : 0 }
    public func nearest(_ offset: Double) -> Int { max(0, min(slots - 1, Int((offset / pitch).rounded()))) }
    public func offset(_ slot: Int) -> Double { Double(max(0, min(slots - 1, slot))) * pitch }
    public func closestSlot(for logical: Int, around slot: Int) -> Int {
        guard count > 1 else { return 0 }
        return [logical, logical + count, logical + 2 * count].min { abs($0 - slot) < abs($1 - slot) } ?? middle(logical)
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
        let distance = (Double(slot) * pitch - offset) / pitch
        let sign = distance < 0 ? -1.0 : 1.0
        let side = continuous ? min(1, abs(distance)) : (slot == nearest(offset) ? 0.0 : 1.0)
        let extra = max(0, abs(distance) - 1)
        return .init(centerX: Double(slot) * pitch + width / 2, centerY: height / 2 + side * 6,
                     angle: -sign * side * 1.03, depth: -side * 44 - min(2, extra) * 20,
                     scale: 1 - side * 0.08, opacity: max(0.32, 1 - side * 0.15 - extra * 0.15),
                     zIndex: 1000 - Int(abs(distance) * 100))
    }
}
