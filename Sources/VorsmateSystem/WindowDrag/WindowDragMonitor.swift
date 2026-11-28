// [INPUT]: Quartz 会话鼠标事件、系统辅助功能授权和修饰键配置。
// [OUTPUT]: 可启停的窗口拖动监听、权限状态与设置入口。
// [POS]: 由 PluginHost 控制，预览仅模拟就绪状态，停用释放事件端口和观察者。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices
import Combine
import VorsmateCore

@MainActor
public final class WindowDragMonitor: ObservableObject {
    public enum Status: Equatable {
        case inactive, ready, permissionRequired, unavailable

        public var needsAttention: Bool { self == .permissionRequired || self == .unavailable }
    }

    @Published public private(set) var status: Status = .inactive
    @Published public private(set) var modifier: WindowDragModifier
    private let preview: Bool
    private var enabled = false
    private let gesture = WindowDragGesture()
    private var tap: WindowDragEventTap?
    private var tapGeneration = 0
    private var activation: AnyCancellable?

    public init(modifier: WindowDragModifier, preview: Bool) {
        self.modifier = modifier
        self.preview = preview
    }

    public func setModifier(_ value: WindowDragModifier) {
        guard value != modifier else { return }
        gesture.interrupt { $0.post(tap: .cgAnnotatedSessionEventTap) }
        modifier = value
        tap?.setModifier(value)
    }

    public func start() {
        guard !enabled else { return }
        enabled = true
        refresh()
    }

    public func refresh() {
        guard enabled else { return }
        if preview {
            setStatus(.ready)
            return
        }
        guard AXIsProcessTrusted() else {
            detachTap()
            setStatus(.permissionRequired)
            // 用户从系统设置切回任意应用时复查，不在后台轮询授权。
            if activation == nil {
                activation = NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didActivateApplicationNotification
                )
                .sink { [weak self] _ in
                    Task { @MainActor in
                        if self?.status == .permissionRequired { self?.refresh() }
                    }
                }
            }
            return
        }
        activation = nil
        if tap == nil {
            let generation = tapGeneration
            tap = WindowDragEventTap(
                modifier: modifier,
                decide: { [weak self] type, event, trigger in
                    guard let self, self.enabled, self.tapGeneration == generation, self.modifier == trigger else {
                        return WindowDragDecision()
                    }
                    var native: WindowTitleDrag?
                    var replay: [CGEvent] = []
                    let consumed = self.gesture.consumes(
                        type, event: event, modifier: trigger, beginTitleDrag: { native = $0 },
                        forward: { replay.append($0) })
                    return WindowDragDecision(
                        consumed: consumed, tracking: self.gesture.isTracking, replay: replay, native: native)
                },
                recover: { [weak self] in
                    guard let self, self.enabled, self.tapGeneration == generation else { return }
                    self.gesture.reset { $0.post(tap: .cgAnnotatedSessionEventTap) }
                    self.refresh()
                })
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap.port) { CGEvent.tapEnable(tap: tap.port, enable: true) }
        if let tap, CGEvent.tapIsEnabled(tap: tap.port) {
            setStatus(.ready)
        } else {
            detachTap()
            setStatus(.unavailable)
        }
    }

    public func openAccessibilitySettings() {
        guard enabled, !preview, !AXIsProcessTrusted() else {
            refresh()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func stop() {
        enabled = false
        activation = nil
        detachTap()
        setStatus(.inactive)
    }

    private func setStatus(_ value: Status) {
        if status != value { status = value }
    }

    private func detachTap() {
        tapGeneration &+= 1
        tap = nil
        gesture.reset { $0.post(tap: .cgAnnotatedSessionEventTap) }
    }
}
