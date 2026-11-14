import SwiftUI
import UIKit
import AudioToolbox

enum HarborLibraryOptions {
    static let coverFlow = "harbor.library.coverflow"
    static let focused = "harbor.library.coverflow.focused"
    static let haptics = "harbor.library.coverflow.haptics"
    static let sound = "harbor.library.coverflow.sound"
}

/// Native scrolling/layout: no timer, display link, web view or per-frame
/// SwiftUI state update. Only crossing into another instance publishes state.
private final class HarborCoverFlowLayout: UICollectionViewFlowLayout {
    var spatialEffects = true
    override init() {
        super.init()
        scrollDirection = .horizontal; minimumLineSpacing = 16
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override func prepare() {
        if let view = collectionView {
            itemSize = CGSize(width: min(340, max(184, view.bounds.width * 0.70)),
                              height: max(140, view.bounds.height - 16))
            let inset = max(0, (view.bounds.width - itemSize.width) / 2)
            sectionInset = UIEdgeInsets(top: 8, left: inset, bottom: 8, right: inset)
        }
        super.prepare()
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView, let original = super.layoutAttributesForElements(in: rect) else { return nil }
        let center = collectionView.contentOffset.x + collectionView.bounds.width / 2
        let pitch = itemSize.width + minimumLineSpacing
        return original.compactMap { value in
            guard let copy = value.copy() as? UICollectionViewLayoutAttributes else { return nil }
            let distance = max(-1.5, min(1.5, (copy.center.x - center) / max(1, pitch)))
            copy.zIndex = 1000 - Int(abs(distance) * 100)
            if spatialEffects {
                var transform = CATransform3DIdentity
                transform.m34 = -1 / 850
                transform = CATransform3DTranslate(transform, 0, 0, -abs(distance) * 65)
                transform = CATransform3DRotate(transform, -distance * 0.58, 0, 1, 0)
                let scale = 1 - min(0.12, abs(distance) * 0.10)
                copy.transform3D = CATransform3DScale(transform, scale, scale, 1)
                copy.alpha = 1 - min(0.3, abs(distance) * 0.18)
            }
            return copy
        }
    }
    override func targetContentOffset(forProposedContentOffset proposed: CGPoint,
                                      withScrollingVelocity velocity: CGPoint) -> CGPoint {
        guard let view = collectionView else { return proposed }
        let pitch = max(1, itemSize.width + minimumLineSpacing)
        let last = max(0, view.numberOfItems(inSection: 0) - 1)
        let page = min(CGFloat(last), max(0, (proposed.x / pitch).rounded()))
        return CGPoint(x: page * pitch, y: proposed.y)
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
    var body: some View {
        VStack(spacing: 14) {
            HarborLoaderArtwork(loader: instance.loader)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            Text(instance.name).font(.headline).lineLimit(2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }.padding(18).harborGlass(radius: 28)
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = HarborCoverFlowLayout()
        let view = HarborCoverFlowCollection(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear; view.showsHorizontalScrollIndicator = false
        view.decelerationRate = .fast; view.alwaysBounceHorizontal = true
        view.contentInsetAdjustmentBehavior = .never
        view.dataSource = context.coordinator; view.delegate = context.coordinator
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cover")
        view.accessibilityIdentifier = "library.coverflow"
        let coordinator = context.coordinator
        view.sizeChanged = { [weak view, weak coordinator] in
            guard let view, let coordinator, !view.isDragging, !coordinator.items.isEmpty else { return }
            let index = coordinator.items.firstIndex { $0.id == coordinator.parent.focused } ?? 0
            coordinator.suppress = true
            view.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
            coordinator.suppress = false
        }
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let changed = coordinator.items != instances
        let layout = view.collectionViewLayout as! HarborCoverFlowLayout
        if layout.spatialEffects != spatialEffects { layout.spatialEffects = spatialEffects; layout.invalidateLayout() }
        if changed {
            coordinator.items = instances
            coordinator.suppress = true; view.reloadData(); view.layoutIfNeeded()
            let position = instances.firstIndex { $0.id == focused } ?? 0
            coordinator.current = position
            if !instances.isEmpty {
                view.scrollToItem(at: IndexPath(item: position, section: 0), at: .centeredHorizontally, animated: false)
            }
            coordinator.suppress = false
        } else if !coordinator.dragging, !view.isDecelerating,
                  let position = instances.firstIndex(where: { $0.id == focused }), position != coordinator.current {
            coordinator.current = position
            coordinator.feedback.tick()
            view.scrollToItem(at: IndexPath(item: position, section: 0), at: .centeredHorizontally,
                              animated: spatialEffects)
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
        var dragging = false
        var suppress = false
        let feedback = HarborCrownFeedback()
        init(_ parent: NativeCoverFlow) { self.parent = parent }
        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "cover", for: indexPath)
            let instance = items[indexPath.item]
            cell.contentConfiguration = UIHostingConfiguration {
                CoverFlowArtwork(instance: instance)
            }.margins(.all, 0)
            cell.backgroundColor = .clear
            return cell
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            parent.focused = items[indexPath.item].id
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            dragging = true; feedback.prepare()
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { dragging = false }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { dragging = false }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !suppress, dragging, let view = scrollView as? UICollectionView,
                  let layout = view.collectionViewLayout as? HarborCoverFlowLayout, !items.isEmpty else { return }
            let pitch = max(1, layout.itemSize.width + layout.minimumLineSpacing)
            let index = max(0, min(items.count - 1, Int((view.contentOffset.x / pitch).rounded())))
            guard index != current else { return }
            current = index; feedback.tick()
            parent.focused = items[index].id
        }
    }
}

struct HarborCoverFlowLibrary: View {
    let instances: [PhoneInstance]
    let launch: (PhoneInstance) -> Void
    let manage: (PhoneInstance) -> Void
    let controls: (PhoneInstance) -> Void
    @AppStorage(HarborLibraryOptions.focused) private var focused = ""
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
                        controls.frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(height: 240)
            } else {
                VStack(spacing: 18) { carousel.frame(height: 268); controls }
            }
        }.padding(.vertical, 10).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
    private var carousel: some View {
        NativeCoverFlow(instances: instances, focused: $focused, spatialEffects: !exclusive && !reduceMotion)
    }
    @ViewBuilder private var controls: some View {
        if !instances.isEmpty {
            VStack(spacing: verticalSizeClass == .compact ? 8 : 18) {
                let instance = instances[position]
                HStack {
                    Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("上一个实例").disabled(position == 0)
                    Spacer()
                    Text("\(position + 1) / \(instances.count)").font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary).accessibilityIdentifier("library.coverflow.position")
                    Spacer()
                    Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("下一个实例").disabled(position == instances.count - 1)
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
        let next = min(instances.count - 1, max(0, position + delta))
        guard instances.indices.contains(next) else { return }
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
                Text("封面流可左右滑动并吸附到当前实例。触觉与音效只在切换实例时触发；音效遵循设备静音。独家优化保留滑动操作，关闭额外三维转动。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
