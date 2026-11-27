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
    private var tap: MouseTap?
    private var activation: AnyCancellable?

    public init(modifier: WindowDragModifier, preview: Bool) {
        self.modifier = modifier
        self.preview = preview
    }

    public func setModifier(_ value: WindowDragModifier) {
        guard value != modifier else { return }
        gesture.interrupt { $0.post(tap: .cgAnnotatedSessionEventTap) }
        modifier = value
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
        if tap == nil { tap = MouseTap(owner: self) }
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
        tap = nil
        gesture.reset { $0.post(tap: .cgAnnotatedSessionEventTap) }
    }

    private func consumes(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gesture.reset { $0.tapPostEvent(proxy) }
            refresh()
            return false
        }
        return gesture.consumes(type, event: event, modifier: modifier) { $0.tapPostEvent(proxy) }
    }

    private final class MouseTap {
        let port: CFMachPort
        let source: CFRunLoopSource

        @MainActor init?(owner: WindowDragMonitor) {
            let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard
                let port = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                    callback: { proxy, type, event, context in
                        guard let context else { return Unmanaged.passUnretained(event) }
                        let owner = Unmanaged<WindowDragMonitor>.fromOpaque(context).takeUnretainedValue()
                        let consumed = MainActor.assumeIsolated {
                            owner.consumes(proxy: proxy, type: type, event: event)
                        }
                        return consumed ? nil : Unmanaged.passUnretained(event)
                    }, userInfo: Unmanaged.passUnretained(owner).toOpaque())
            else { return nil }
            guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
                CFMachPortInvalidate(port)
                return nil
            }
            self.port = port
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }

        deinit {
            CFMachPortInvalidate(port)
            CFRunLoopSourceInvalidate(source)
        }
    }
}
