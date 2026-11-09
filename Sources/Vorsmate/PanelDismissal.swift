// [INPUT]: NSPopover、菜单栏按钮、鼠标位置与本应用的原生菜单跟踪通知。
// [OUTPUT]: 离开操作区域后的延迟收起；菜单、拖动与键盘操作期间不误关。
// [POS]: 只管理面板显隐，不停止设备管理或风扇续期；关闭后移除全部观察者。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import OSLog

@MainActor
final class PanelDismissal: NSObject {
    private weak var popover: NSPopover?
    private weak var anchor: NSView?
    private var timer: Timer?
    private var keyboardMonitor: Any?
    private var menus: [NSMenu] = []
    private var outsideSince: TimeInterval?
    private var lastPointer = NSPoint.zero
    private var keyboardActive = false
    private var pointerEntered = false
    private let logger = Logger(subsystem: "app.vorsmate.mac", category: "Panel")

    func start(popover: NSPopover, anchor: NSView) {
        stop()
        self.popover = popover
        self.anchor = anchor
        lastPointer = NSEvent.mouseLocation
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(
            self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.keyboardActive = true
                self?.lastPointer = NSEvent.mouseLocation
                self?.outsideSince = nil
            }
            return event
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        // 原生菜单跟踪和拖动使用不同模式，也要继续检查退出区域。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkPointer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        menus.removeAll()
        outsideSince = nil
        keyboardActive = false
        pointerEntered = false
        popover = nil
        anchor = nil
    }

    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.append(menu)
        outsideSince = nil
    }

    @objc private func menuEnded(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        menus.removeAll { $0 === menu }
        outsideSince = nil
    }

    private func checkPointer() {
        guard let popover, popover.isShown, let window = popover.contentViewController?.view.window else { return }
        let pointer = NSEvent.mouseLocation
        if hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) > 2 {
            keyboardActive = false
            lastPointer = pointer
        }
        var regions = [window.frame]
        if let anchor, let anchorWindow = anchor.window {
            regions.append(anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
        }
        // 读取本应用 NSMenu 的公开辅助功能几何，不需要额外辅助功能权限。
        let menuFrames = menus.map { $0.accessibilityFrame() }.filter { !$0.isEmpty }
        regions.append(contentsOf: menuFrames)
        let inside = regions.contains { $0.insetBy(dx: -6, dy: -6).contains(pointer) }
        if inside { pointerEntered = true }
        // 键盘或开发入口打开时，鼠标可能从未进入面板；不要抢走键盘操作。
        guard pointerEntered else { return }
        guard !inside, !keyboardActive, NSEvent.pressedMouseButtons == 0 else {
            outsideSince = nil
            return
        }
        // 菜单刚开始布局、几何尚未可读时保留操作，不按未知范围误关。
        guard menus.isEmpty || !menuFrames.isEmpty else {
            outsideSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if outsideSince == nil { outsideSince = now }
        guard now - (outsideSince ?? now) >= 0.5 else { return }
        let activeMenus = menus
        logger.info("Pointer left the panel; dismissing with \(activeMenus.count) active menus")
        stop()
        for menu in activeMenus { menu.cancelTracking() }
        popover.performClose(nil)
    }
}
