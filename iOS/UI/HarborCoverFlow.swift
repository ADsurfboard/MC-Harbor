import SwiftUI
import UIKit
import AudioToolbox
import HarborCore

enum HarborLibraryOptions {
    static let coverFlow = "harbor.library.coverflow"
    static let focused = "harbor.library.coverflow.focused"
    static let order = "harbor.library.coverflow.order"
    static let haptics = "harbor.library.coverflow.haptics"
    static let sound = "harbor.library.coverflow.sound"
}

/// Native scrolling/layout: no timer, display link, web view or per-frame
/// SwiftUI state update. Only crossing into another instance publishes state.
private final class HarborCoverFlowLayout: UICollectionViewLayout {
    var spatialEffects = true
    var instanceCount = 0
    var liftedSlot: Int?
    var destinationSlot: Int?
    var geometry: CoverFlowGeometry {
        .init(width: Double(collectionView?.bounds.width ?? 1),
              height: Double(collectionView?.bounds.height ?? 1),
              count: instanceCount)
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
        var displayedSlot = path.item
        if let liftedSlot, let destinationSlot {
            if liftedSlot < path.item && path.item <= destinationSlot { displayedSlot -= 1 }
            if destinationSlot <= path.item && path.item < liftedSlot { displayedSlot += 1 }
        }
        let pose = metrics.pose(slot: displayedSlot, offset: Double(view.contentOffset.x), continuous: spatialEffects)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: path)
        attributes.size = CGSize(width: metrics.cardWidth, height: metrics.cardHeight)
        attributes.center = CGPoint(x: pose.centerX, y: pose.centerY)
        attributes.zIndex = pose.zIndex
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 920
        transform = CATransform3DTranslate(transform, 0, 0, pose.depth)
        transform = CATransform3DRotate(transform, pose.angle, 0, 1, 0)
        attributes.transform3D = CATransform3DScale(transform, pose.scale, pose.scale, 1)
        attributes.alpha = path.item == liftedSlot ? 0 : pose.opacity
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }
    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Text(instance.loader.uppercased()).font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                .tracking(1.6).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HarborLoaderArtwork(loader: instance.loader)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(compact ? 2 : 12)
            Text(instance.name).font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium)).lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.padding(compact ? 12 : 18)
            .background(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.28), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 24))
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
    var activate: ((PhoneInstance) -> Void)?
    let move: (String, Int) -> Void
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
        context.coordinator.installReorderGesture(on: view)
        let coordinator = context.coordinator
        view.sizeChanged = { [weak view, weak coordinator] in
            guard let view, let coordinator, !view.isDragging, !coordinator.isReordering, !coordinator.items.isEmpty else { return }
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
        if coordinator.isReordering { return }
        layout.spatialEffects = spatialEffects; layout.invalidateLayout()
        if changed {
            coordinator.items = Array(instances.prefix(10_000))
            layout.instanceCount = coordinator.items.count
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
        coordinator.cleanReorder(in: view)
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
        private let grabFeedback = UIImpactFeedbackGenerator(style: .soft)
        private struct Reorder {
            let snapshot: UIView
            let instance: PhoneInstance
            let firstSlot: Int
            let sourceIndex: Int
            let anchor: CGPoint
            let origin: CGPoint
            var previous: CGPoint
            var previousTime: CFTimeInterval
            var velocity: CGFloat = 0
            var target: Int
        }
        private var reorder: Reorder?
        private var reorderAnimation: UIViewPropertyAnimator?
        var isReordering: Bool { reorder != nil }

        init(_ parent: NativeCoverFlow) { self.parent = parent }
        func installReorderGesture(on view: UICollectionView) {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(reorderGesture))
            gesture.minimumPressDuration = 0.40
            gesture.allowableMovement = 14
            view.addGestureRecognizer(gesture)
        }

        @objc private func reorderGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? UICollectionView, let host = view.superview,
                  let layout = view.collectionViewLayout as? HarborCoverFlowLayout, items.count > 1 else { return }
            let point = gesture.location(in: host)
            switch gesture.state {
            case .began:
                guard !view.isDecelerating, reorder == nil,
                      let path = view.indexPathForItem(at: gesture.location(in: view)),
                      let cell = view.cellForItem(at: path),
                      let floating = cell.snapshotView(afterScreenUpdates: false) else { return }
                let index = layout.geometry.logical(path.item)
                floating.frame = cell.convert(cell.bounds, to: host)
                floating.isUserInteractionEnabled = false
                floating.layer.shadowColor = UIColor.black.cgColor
                floating.layer.shadowOpacity = 0.24
                floating.layer.shadowRadius = 16
                floating.layer.shadowOffset = CGSize(width: 0, height: 8)
                host.addSubview(floating)
                reorder = Reorder(snapshot: floating, instance: items[index], firstSlot: path.item,
                    sourceIndex: index, anchor: point, origin: floating.center, previous: point,
                    previousTime: CACurrentMediaTime(), target: index)
                view.isScrollEnabled = false
                layout.liftedSlot = path.item
                layout.destinationSlot = path.item
                layout.invalidateLayout()
                grabFeedback.impactOccurred(intensity: 0.72)
                feedback.prepare()
                if parent.spatialEffects {
                    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                        floating.transform = CGAffineTransform(scaleX: 1.055, y: 1.055)
                    }
                }
            case .changed:
                guard var transaction = reorder else { return }
                let now = CACurrentMediaTime()
                if now > transaction.previousTime {
                    let speed = (point.x - transaction.previous.x) / (now - transaction.previousTime)
                    transaction.velocity = min(1800, max(-1800, transaction.velocity * 0.5 + speed * 0.5))
                }
                transaction.previous = point
                transaction.previousTime = now
                let displacement = point.x - transaction.anchor.x
                transaction.snapshot.center = CGPoint(x: transaction.origin.x + displacement,
                    y: transaction.origin.y + (point.y - transaction.anchor.y) * 0.18)
                reorder = transaction
                previewReorder(index(for: displacement, drag: transaction, layout: layout), in: view, layout: layout)
            case .ended, .cancelled, .failed:
                guard let transaction = reorder else { return }
                let committed = gesture.state == .ended
                let recentVelocity = CACurrentMediaTime() - transaction.previousTime < 0.16 ? transaction.velocity : 0
                let inertia = parent.spatialEffects ? min(layout.geometry.pitch * 0.28, max(-layout.geometry.pitch * 0.28, recentVelocity * 0.10)) : 0
                let choice = committed
                    ? index(for: point.x - transaction.anchor.x + inertia, drag: transaction, layout: layout)
                    : transaction.sourceIndex
                previewReorder(choice, in: view, layout: layout)
                finishReorder(to: choice, velocity: recentVelocity, committed: committed, in: view, host: host, layout: layout)
            default: break
            }
        }

        private func index(for displacement: CGFloat, drag: Reorder, layout: HarborCoverFlowLayout) -> Int {
            let shift = Int((displacement / layout.geometry.pitch).rounded())
            return max(0, min(items.count - 1, drag.sourceIndex + shift))
        }

        private func previewReorder(_ index: Int, in view: UICollectionView, layout: HarborCoverFlowLayout) {
            guard var transaction = reorder, transaction.target != index else { return }
            transaction.target = index
            reorder = transaction
            layout.destinationSlot = transaction.firstSlot + index - transaction.sourceIndex
            feedback.tick()
            let update = { layout.invalidateLayout(); view.layoutIfNeeded() }
            if parent.spatialEffects {
                UIView.animate(withDuration: 0.20, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
            } else { update() }
        }

        private func finishReorder(to index: Int, velocity: CGFloat, committed: Bool, in view: UICollectionView,
                                   host: UIView, layout: HarborCoverFlowLayout) {
            guard let transaction = reorder else { return }
            let slot = transaction.firstSlot + index - transaction.sourceIndex
            let pose = layout.geometry.pose(slot: slot, offset: view.contentOffset.x, continuous: parent.spatialEffects)
            let center = view.convert(CGPoint(x: pose.centerX, y: pose.centerY), to: host)
            let distance = center.x - transaction.snapshot.center.x
            let relativeVelocity = abs(distance) > 8 ? min(3, max(-3, velocity / distance)) : 0
            let finish = { [weak self, weak view] in
                guard let self, let view, self.reorder?.snapshot === transaction.snapshot else { return }
                if committed {
                    self.parent.move(transaction.instance.id, index)
                    self.grabFeedback.impactOccurred(intensity: 0.52)
                }
                self.cleanReorder(in: view)
            }
            guard parent.spatialEffects else { finish(); return }
            let spring = UISpringTimingParameters(dampingRatio: 0.80, initialVelocity: CGVector(dx: relativeVelocity, dy: 0))
            let animator = UIViewPropertyAnimator(duration: 0.38, timingParameters: spring)
            animator.addAnimations {
                transaction.snapshot.center = center
                transaction.snapshot.transform = .identity
            }
            animator.addCompletion { [weak self] _ in
                self?.reorderAnimation = nil
                finish()
            }
            reorderAnimation = animator
            animator.startAnimation()
        }

        func cleanReorder(in view: UICollectionView) {
            guard let reorder else { return }
            reorderAnimation?.stopAnimation(true)
            reorderAnimation = nil
            reorder.snapshot.layer.removeAllAnimations()
            reorder.snapshot.removeFromSuperview()
            self.reorder = nil
            if let layout = view.collectionViewLayout as? HarborCoverFlowLayout {
                layout.liftedSlot = nil
                layout.destinationSlot = nil
                layout.invalidateLayout()
            }
            view.isScrollEnabled = true
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            (view.collectionViewLayout as? HarborCoverFlowLayout)?.geometry.slots ?? 0
        }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "cover", for: path)
            let index = path.item % items.count
            let instance = items[index]
            cell.contentConfiguration = UIHostingConfiguration { CoverFlowArtwork(instance: instance) }.margins(.all, 0)
            cell.backgroundColor = .clear; cell.contentView.backgroundColor = .clear
            cell.backgroundConfiguration = .clear()
            cell.accessibilityIdentifier = "library.cover." + String(path.item)
            cell.accessibilityLabel = instance.name
            let left = UIAccessibilityCustomAction(name: "向左移动") { [weak self] _ in
                guard let self, index > 0 else { return false }
                self.parent.move(instance.id, index - 1); return true
            }
            let right = UIAccessibilityCustomAction(name: "向右移动") { [weak self] _ in
                guard let self, index + 1 < self.items.count else { return false }
                self.parent.move(instance.id, index + 1); return true
            }
            cell.accessibilityCustomActions = [index > 0 ? left : nil, index + 1 < items.count ? right : nil].compactMap { $0 }
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
            guard !items.isEmpty else { return }
            let selected = items[layout.geometry.logical(path.item)]
            view.deselectItem(at: path, animated: false)
            if path.item == layout.geometry.nearest(view.contentOffset.x), let activate = parent.activate {
                parent.focused = selected.id
                activate(selected)
                return
            }
            if path.item != virtualIndex { feedback.tick() }
            center(path.item, in: view, animated: parent.spatialEffects)
            parent.focused = selected.id
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
            let first = layout.geometry.middle(0)
            if items.count > 1 && (slot < first || slot >= first + items.count) {
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
    var immersive = false
    @State private var actionInstance: PhoneInstance?
    @AppStorage(HarborLibraryOptions.focused) private var focused = ""
    @AppStorage(HarborLibraryOptions.order) private var savedOrder = "[]"
    @State private var direction = 1
    @AppStorage(HarborAppearance.exclusiveOptimizationKey) private var exclusive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var ordered: [PhoneInstance] {
        let available = Dictionary(instances.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = (try? JSONDecoder().decode([String].self, from: Data(savedOrder.utf8))) ?? []
        return CoverFlowOrdering.merge(available: instances.map(\.id), saved: saved).compactMap { available[$0] }
    }
    private var position: Int { ordered.firstIndex { $0.id == focused } ?? 0 }
    var body: some View {
        if immersive {
            landscapeStage
        } else {
            VStack(spacing: 18) {
                carousel.frame(height: 268)
                selectionControls
            }
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }

    private var landscapeStage: some View {
        ZStack {
            VStack(spacing: 0) {
                carousel.frame(maxWidth: .infinity, maxHeight: .infinity)
                positionIndicator
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
            .accessibilityHidden(actionInstance != nil)
            .allowsHitTesting(actionInstance == nil)
            if let instance = actionInstance {
                Color.black.opacity(0.27).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture { actionInstance = nil }
                    .accessibilityHidden(true)
                actionPanel(instance)
                    .padding(.horizontal, 24)
                    .transition(exclusive || reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(exclusive || reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: actionInstance?.id)
    }

    private var carousel: some View {
        NativeCoverFlow(instances: ordered, focused: $focused, spatialEffects: !exclusive && !reduceMotion,
                        requestedDirection: direction, activate: immersive ? { actionInstance = $0 } : nil,
                        move: moveInstance)
    }

    private var positionIndicator: some View {
        Text("\(position + 1) / \(instances.count)").font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary).accessibilityIdentifier("library.coverflow.position")
    }

    private func actionPanel(_ instance: PhoneInstance) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                HarborLoaderArtwork(loader: instance.loader).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(instance.name).font(.headline).lineLimit(2)
                    Text(instance.version + " · " + instance.loader).font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { actionInstance = nil } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .harborGlassButton()
                .accessibilityLabel("关闭实例操作")
                .accessibilityIdentifier("library.coverflow.actions.close")
            }
            HStack(spacing: 10) {
                Button { actionInstance = nil; launch(instance) } label: {
                    Label("启动游戏", systemImage: "play.fill").frame(minHeight: 44).contentShape(Rectangle())
                }.harborGlassButton(prominent: true).accessibilityIdentifier("instance.launch." + instance.id)
                Button("实例管理") { actionInstance = nil; manage(instance) }
                    .frame(minHeight: 44).harborGlassButton()
                Button("触控布局") { actionInstance = nil; controls(instance) }
                    .frame(minHeight: 44).harborGlassButton()
            }.frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .harborGlass(radius: 26)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("library.coverflow.actions")
    }

    @ViewBuilder private var selectionControls: some View {
        if !instances.isEmpty {
            VStack(spacing: verticalSizeClass == .compact ? 8 : 18) {
                let instance = ordered[position]
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("上一个实例").disabled(instances.count < 2)
                    Spacer()
                    positionIndicator
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
    private func moveInstance(_ id: String, to index: Int) {
        let prior = ordered.map(\.id)
        let order = CoverFlowOrdering.move(id, to: index, in: prior)
        if let data = try? JSONEncoder().encode(order) {
            savedOrder = String(decoding: data, as: UTF8.self)
            focused = id
        }
    }

    private func step(_ delta: Int) {
        let ordered = self.ordered
        guard !ordered.isEmpty else { return }
        let next = (position + delta + ordered.count) % ordered.count
        direction = delta
        focused = ordered[next].id
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
                Text("封面流可左右滑动并吸附到当前实例。长按卡片可左右拖动排序。横屏点选中卡片打开实例操作。触觉与音效只在切换实例时触发；音效遵循设备静音。独家优化保留滑动操作，保留静态空间排布，关闭连续三维形变。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
