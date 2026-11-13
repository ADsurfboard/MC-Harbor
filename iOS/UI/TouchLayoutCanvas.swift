import SwiftUI
import HarborCore

/// Kept separate from the form so drag callbacks have a small, predictable type
/// checking surface and never force the settings form to be rebuilt per finger.
struct TouchLayoutCanvas: View {
    @Binding var layout: TouchLayout
    @Binding var selected: UUID?
    @State private var dragOrigins: [UUID: NormalizedPoint] = [:]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [Color(red: 0.07, green: 0.17, blue: 0.14), Color(red: 0.16, green: 0.25, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "plus").font(.title2).foregroundStyle(.white.opacity(0.4))
                joystick(size: geometry.size)
                ForEach(layout.buttons.filter(\.visible)) { button in
                    control(button: button, size: geometry.size)
                }
            }.coordinateSpace(name: "touchCanvas")
        }
    }
    private func joystick(size: CGSize) -> some View {
        Circle().fill(.white.opacity(0.12))
            .frame(width: CGFloat(layout.settings.joystickDiameter * 0.6), height: CGFloat(layout.settings.joystickDiameter * 0.6))
            .overlay(Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundStyle(.white))
            .position(x: CGFloat(layout.settings.joystickCenter.x) * size.width, y: CGFloat(layout.settings.joystickCenter.y) * size.height)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("touchCanvas")).onChanged { value in
                moveJoystick(value.location, size: size)
            })
    }
    private func control(button: TouchButton, size: CGSize) -> some View {
        let diameter = CGFloat(max(32.0, button.diameter * 0.6))
        let opacity: Double = button.id == selected ? 0.42 : button.opacity * 0.35
        return Text(button.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            .frame(width: diameter, height: diameter)
            .background(.white.opacity(opacity), in: Circle())
            .frame(minWidth: 44, minHeight: 44).contentShape(Circle())
            .position(x: CGFloat(button.center.x) * size.width, y: CGFloat(button.center.y) * size.height)
            .onTapGesture { selected = button.id }
            .gesture(DragGesture().onChanged { value in move(button, value: value, size: size) }
                .onEnded { _ in dragOrigins.removeValue(forKey: button.id) })
            .accessibilityLabel(button.displayName)
    }
    private func moveJoystick(_ location: CGPoint, size: CGSize) {
        let x = Double(location.x) / max(1.0, Double(size.width))
        let y = Double(location.y) / max(1.0, Double(size.height))
        layout.settings.joystickCenter = NormalizedPoint(x: x, y: y)
    }
    private func move(_ button: TouchButton, value: DragGesture.Value, size: CGSize) {
        selected = button.id
        if dragOrigins[button.id] == nil { dragOrigins[button.id] = button.center }
        guard let original: NormalizedPoint = dragOrigins[button.id] else { return }
        guard let index: Int = layout.buttons.firstIndex(where: { candidate in candidate.id == button.id }) else { return }
        let dx: Double = Double(value.translation.width) / max(1.0, Double(size.width))
        let dy: Double = Double(value.translation.height) / max(1.0, Double(size.height))
        layout.buttons[index].center = NormalizedPoint(x: original.x + dx, y: original.y + dy)
    }
}
