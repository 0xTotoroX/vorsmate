// [INPUT]: 单个输入源的名称、就绪状态、真实选中项与目标位置。
// [OUTPUT]: 原生行内容、轻微抬起与可中断的弹簧落位、辅助功能选择和排序。
// [POS]: SourceListView 的纯展示单元，不保存配置、不访问系统设备。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import QuartzCore
import VorsmateCore

@MainActor
final class SourceRow: NSView {
    private let name = NSTextField(wrappingLabelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let tick = NSImageView()
    private let remove = NSButton()
    private var lifted = false
    var onRemove: (() -> Void)?
    var onChoose: (() -> Void)?
    var onMove: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var visibleFrame: NSRect {
        guard let presentation = layer?.presentation() else { return frame }
        return presentation.frame
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        name.font = .systemFont(ofSize: 13)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "当前使用")
        tick.contentTintColor = .controlAccentColor
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除离线项目")
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeSource)
        let stack = NSStackView(views: [name, state, tick, remove])
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tick.widthAnchor.constraint(equalToConstant: 16),
            remove.widthAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(source: Source, index: Int, online: Bool, snapshot: Snapshot, lockedID: String?) {
        name.stringValue = source.name
        name.textColor = online ? .labelColor : .secondaryLabelColor
        state.stringValue = online ? snapshot.availability[source.id]?.label ?? "" : "离线"
        tick.isHidden = snapshot.selectedID != source.id
        remove.isHidden = online || lockedID == source.id
        setAccessibilityLabel("\(source.name)，优先级 \(index + 1)")
        setAccessibilityValue(tick.isHidden ? state.stringValue : "当前使用")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "选择并锁定") { [weak self] in
                guard online else { return false }
                self?.onChoose?()
                return true
            },
            NSAccessibilityCustomAction(name: "提高优先级") { [weak self] in
                self?.onMove?(-1)
                return true
            },
            NSAccessibilityCustomAction(name: "降低优先级") { [weak self] in
                self?.onMove?(1)
                return true
            },
        ])
    }

    func move(to y: CGFloat, animated: Bool, velocity: CGFloat = 0) {
        guard let layer else {
            setFrameOrigin(NSPoint(x: 3, y: y))
            return
        }
        if animated, abs(frame.minY - y) < 0.01 { return }
        let previous = layer.presentation()?.position ?? layer.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "source-position")
        setFrameOrigin(NSPoint(x: 3, y: y))
        CATransaction.commit()
        guard animated, !reduceMotion, abs(previous.y - layer.position.y) > 0.01 else { return }
        let animation = spring("position.y", from: previous.y, to: layer.position.y)
        animation.initialVelocity = velocity / (layer.position.y - previous.y)
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "source-position")
    }

    func setLifted(_ value: Bool) {
        guard let layer else { return }
        lifted = value
        let previous = layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        let scale: CGFloat = value && !reduceMotion ? 1.018 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = value ? 2 : 0
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.removeAnimation(forKey: "source-lift")
        CATransaction.commit()
        if !reduceMotion {
            let animation = spring("transform.scale", from: previous, to: scale)
            layer.add(animation, forKey: "source-lift")
        }
        needsDisplay = true
    }

    private func spring(_ key: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: key)
        animation.mass = 1
        animation.stiffness = 676
        animation.damping = 37.44
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if lifted {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    @objc private func removeSource() { onRemove?() }
    override func accessibilityPerformPress() -> Bool {
        onChoose?()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // 动画中显示位置与 NSView 的最终 frame 不同，避免误点另一行的删除按钮。
        guard layer?.animationKeys()?.isEmpty != false else { return nil }
        if !remove.isHidden, remove.bounds.contains(remove.convert(local, from: self)) { return remove }
        return nil
    }
}
