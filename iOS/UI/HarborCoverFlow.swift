import SwiftUI
import UIKit
import AudioToolbox
import HarborCore

enum HarborLibraryOptions {
    static let coverFlow = "harbor.library.coverflow"
    static let focused = "harbor.library.coverflow.focused"
    static let haptics = "harbor.library.coverflow.haptics"
    static let sound = "harbor.library.coverflow.sound"
}

/// Native scrolling/layout: no timer, display link, web view or per-frame
/// SwiftUI state update. Only crossing into another instance publishes state.
private final class HarborCoverFlowLayout: UICollectionViewLayout {
    var spatialEffects = true
    var geometry: CoverFlowGeometry {
        .init(width: Double(collectionView?.bounds.width ?? 1),
              height: Double(collectionView?.bounds.height ?? 1),
              count: (collectionView?.numberOfItems(inSection: 0) ?? 0) > 1
                  ? (collectionView?.numberOfItems(inSection: 0) ?? 0) / 3
                  : (collectionView?.numberOfItems(inSection: 0) ?? 0))
    }
    override var collectionViewContentSize: CGSize {
        CGSize(width: geometry.contentWidth, height: geometry.height)
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let view = collectionView, let range = geometry.visible(around: view.contentOffset.x) else { return [] }
        return range.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }
    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let view = collectionView, path.item < geometry.slots else { return nil }
        let metrics = geometry
        let pose = metrics.pose(slot: path.item, offset: Double(view.contentOffset.x), continuous: spatialEffects)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
        attributes.size = CGSize(width: metrics.cardWidth, height: metrics.cardHeight)
        attributes.center = CGPoint(x: pose.centerX, y: pose.centerY)
        attributes.zIndex = pose.zIndex
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 920
        transform = CATransform3DTranslate(transform, 0, 0, pose.depth)
        transform = CATransform3DRotate(transform, pose.angle, 0, 1, 0)
        attributes.transform3D = CATransform3DScale(transform, pose.scale, pose.scale, 1)
        attributes.alpha = pose.opacity
        return attributes
    }
    override func targetContentOffset(forProposedContentOffset proposed: CGPoint,
                                      withScrollingVelocity velocity: CGPoint) -> CGPoint {
        CGPoint(x: geometry.offset(geometry.nearest(proposed.x)), y: 0)
    }
}

@MainActor private final class HarborCrownFeedback {
    private let selection = UISelectionFeedbackGenerator()
    private var soundID: SystemSoundID = 0
    private var lastTick: CFAbsoluteTime = 0
    init() {
        if let url = Bundle(for: HarborRootFactory.self).url(forResource: "CrownTick", withExtension: "wav") {
            AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        }
    }
    func prepare() { selection.prepare() }
    func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTick >= 0.065 else { return }
        lastTick = now
        let preferences = UserDefaults.standard
        if preferences.object(forKey: HarborLibraryOptions.haptics) as? Bool ?? true {
            selection.selectionChanged(); selection.prepare()
        }
        // A quiet original mechanical tick. System sound playback preserves
        // the mute switch and never reconfigures the game's audio session.
        if soundID != 0, preferences.object(forKey: HarborLibraryOptions.sound) as? Bool ?? true {
            AudioServicesPlaySystemSound(soundID)
        }
    }
    deinit { if soundID != 0 { AudioServicesDisposeSystemSoundID(soundID) } }
}

private struct CoverFlowArtwork: View {
    let instance: PhoneInstance
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 10) {
            Text(instance.loader.uppercased()).font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.6).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HarborLoaderArtwork(loader: instance.loader)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(12)
            Text(instance.name).font(.subheadline.weight(.medium)).lineLimit(2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.padding(18)
            .background(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.28), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            .harborGlass(radius: 24)
    }
}

private final class HarborCoverFlowCollection: UICollectionView {
    var sizeChanged: (() -> Void)?
    private var previousSize: CGSize = .zero
    override func layoutSubviews() {
        let changed = bounds.size != previousSize
        previousSize = bounds.size
        super.layoutSubviews()
        if changed { sizeChanged?() }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            // A vertical swipe belongs to the outer library scroll view.
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private struct NativeCoverFlow: UIViewRepresentable {
    let instances: [PhoneInstance]
    @Binding var focused: String
    let spatialEffects: Bool
    let requestedDirection: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = HarborCoverFlowLayout()
        let view = HarborCoverFlowCollection(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear; view.showsHorizontalScrollIndicator = false
        view.decelerationRate = .fast; view.alwaysBounceHorizontal = instances.count > 1
        view.contentInsetAdjustmentBehavior = .never
        view.dataSource = context.coordinator; view.delegate = context.coordinator
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cover")
        view.accessibilityIdentifier = "library.coverflow"
        let coordinator = context.coordinator
        view.sizeChanged = { [weak view, weak coordinator] in
            guard let view, let coordinator, !view.isDragging, !coordinator.items.isEmpty else { return }
            let index = coordinator.items.firstIndex { $0.id == coordinator.parent.focused } ?? 0
            coordinator.center(layout.geometry.middle(index), in: view, animated: false)
        }
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let changed = coordinator.items != instances
        let layout = view.collectionViewLayout as! HarborCoverFlowLayout
        layout.spatialEffects = spatialEffects; layout.invalidateLayout()
        if changed {
            coordinator.items = Array(instances.prefix(10_000))
            coordinator.suppress = true; view.reloadData(); view.layoutIfNeeded()
            let position = coordinator.items.firstIndex { $0.id == focused } ?? 0
            coordinator.center(layout.geometry.middle(position), in: view, animated: false)
            coordinator.suppress = false
        } else if !coordinator.dragging, !view.isDecelerating,
                  let position = coordinator.items.firstIndex(where: { $0.id == focused }), position != coordinator.current {
            let target = layout.geometry.closestSlot(for: position, around: coordinator.virtualIndex, direction: requestedDirection)
            coordinator.feedback.tick()
            coordinator.center(target, in: view, animated: spatialEffects)
        }
    }
    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        (view as? HarborCoverFlowCollection)?.sizeChanged = nil
        view.delegate = nil; view.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: NativeCoverFlow
        var items: [PhoneInstance] = []
        var current = 0
        var virtualIndex = 0
        var dragging = false
        var suppress = false
        let feedback = HarborCrownFeedback()
        init(_ parent: NativeCoverFlow) { self.parent = parent }
        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count > 1 ? items.count * 3 : items.count
        }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "cover", for: path)
            let index = path.item % items.count
            let instance = items[index]
            cell.contentConfiguration = UIHostingConfiguration { CoverFlowArtwork(instance: instance) }.margins(.all, 0)
            cell.backgroundColor = .clear
            cell.accessibilityIdentifier = "library.cover." + String(path.item)
            cell.accessibilityLabel = instance.name
            return cell
        }
        func center(_ slot: Int, in view: UICollectionView, animated: Bool) {
            guard let layout = view.collectionViewLayout as? HarborCoverFlowLayout, !items.isEmpty else { return }
            virtualIndex = slot; current = layout.geometry.logical(slot)
            suppress = true
            view.setContentOffset(CGPoint(x: layout.geometry.offset(slot), y: 0), animated: animated)
            suppress = false
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            guard let layout = view.collectionViewLayout as? HarborCoverFlowLayout else { return }
            if path.item != virtualIndex { feedback.tick() }
            center(path.item, in: view, animated: parent.spatialEffects)
            parent.focused = items[layout.geometry.logical(path.item)].id
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { dragging = true; feedback.prepare() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(scrollView) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle(scrollView) }
        private func settle(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UICollectionView,
                  let layout = view.collectionViewLayout as? HarborCoverFlowLayout, !items.isEmpty else { return }
            dragging = false
            let slot = layout.geometry.nearest(view.contentOffset.x)
            virtualIndex = slot; current = layout.geometry.logical(slot)
            parent.focused = items[current].id
            // Rebase an equivalent copy only after motion stops; no visible jump.
            if items.count > 1 && (slot < items.count || slot >= 2 * items.count) {
                center(layout.geometry.middle(current), in: view, animated: false)
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !suppress, dragging, let view = scrollView as? UICollectionView,
                  let layout = view.collectionViewLayout as? HarborCoverFlowLayout, !items.isEmpty else { return }
            let slot = layout.geometry.nearest(view.contentOffset.x)
            guard slot != virtualIndex else { return }
            virtualIndex = slot; current = layout.geometry.logical(slot); feedback.tick()
            parent.focused = items[current].id
        }
    }
}

struct HarborCoverFlowLibrary: View {
    let instances: [PhoneInstance]
    let launch: (PhoneInstance) -> Void
    let manage: (PhoneInstance) -> Void
    let controls: (PhoneInstance) -> Void
    @AppStorage(HarborLibraryOptions.focused) private var focused = ""
    @State private var direction = 1
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var position: Int { instances.firstIndex { $0.id == focused } ?? 0 }
    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                GeometryReader { geometry in
                    HStack(alignment: .center, spacing: 20) {
                        carousel.frame(width: geometry.size.width * 0.45, height: 190)
                        selectionControls.frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 240)
            } else {
                VStack(spacing: 18) { carousel.frame(height: 268); selectionControls }
            }
        }.padding(.vertical, 10).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    private var carousel: some View {
        NativeCoverFlow(instances: instances, focused: $focused, spatialEffects: !exclusive && !reduceMotion, requestedDirection: direction)
    }
    @ViewBuilder private var selectionControls: some View {
        if !instances.isEmpty {
            VStack(spacing: verticalSizeClass == .compact ? 8 : 18) {
                let instance = instances[position]
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("上一个实例").disabled(instances.count < 2)
                    Spacer()
                    Text("\(position + 1) / \(instances.count)").font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary).accessibilityIdentifier("library.coverflow.position")
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("下一个实例").disabled(instances.count < 2)
                }.buttonStyle(.plain)
                VStack(spacing: 12) {
                    Text(instance.name).font(verticalSizeClass == .compact ? .headline : .title3.bold()).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("library.coverflow.name")
                    Text(instance.version + " · " + instance.loader).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button { launch(instance) } label: {
                            Label("启动游戏", systemImage: "play.fill").font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
                        }.harborGlassButton(prominent: true).accessibilityIdentifier("instance.launch." + instance.id)
                        Menu {
                            Button("实例管理") { manage(instance) }
                            Button("触控布局") { controls(instance) }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 46, height: 46)
                        }.harborGlassButton().accessibilityLabel("当前实例的更多操作")
                    }
                }.padding(.horizontal, 16)
            }
        }
    }
    private func step(_ delta: Int) {
        guard !instances.isEmpty else { return }
        let next = (position + delta + instances.count) % instances.count
        guard instances.indices.contains(next) else { return }
        direction = delta
        focused = instances[next].id
    }
}

struct HarborLibraryPresentationSettings: View {
    @AppStorage(HarborLibraryOptions.coverFlow) private var coverFlow = false
    @AppStorage(HarborLibraryOptions.haptics) private var haptics = true
    @AppStorage(HarborLibraryOptions.sound) private var sound = true
    var body: some View {
        Section("实例选择 · iOS 专属") {
            HarborGlassPanel {
                Picker("选择方式", selection: $coverFlow) {
                    Text("列表").tag(false)
                    Text("封面流").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.library.mode")
                HarborSettingsToggle("切换触觉反馈", isOn: $haptics).frame(minHeight: 44)
                HarborSettingsToggle("机械切换音效", isOn: $sound).frame(minHeight: 44)
                Text("封面流可左右滑动并吸附到当前实例。触觉与音效只在切换实例时触发；音效遵循设备静音。独家优化保留滑动操作，保留静态空间排布，关闭连续三维形变。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
