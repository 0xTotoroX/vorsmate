// [INPUT]: AppKit 生命周期、PanelView、AppModel、BrandIcon、PanelAutomation。
// [OUTPUT]: 原生菜单栏（含一键关机倒计时与无人值守授权状态及右键操作）、开发实例交接、自动化交互保护、独立预览与只读 JSON 检查。
// [POS]: 可执行入口，.app 由 scripts/build.sh 打包。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Combine
import SwiftUI
import VorsmateCore
import VorsmateFan

@main
@MainActor
enum VorsmateMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--development-fan-helper" {
            DevelopmentFanHelper.run()
        }
        if CommandLine.arguments.dropFirst().first == "--development-stop" {
            exit(DevelopmentBuild.stopForReload())
        }
        if CommandLine.arguments.dropFirst().first == "--computer-use-panel" {
            PanelAutomation.send(CommandLine.arguments.dropFirst(2))
            return
        }
        if CommandLine.arguments.contains("--inspect") {
            inspect()
            return
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--preview") {
            if CommandLine.arguments.contains("--preview-dark") {
                app.appearance = NSAppearance(named: .darkAqua)
            } else if CommandLine.arguments.contains("--preview-light") {
                app.appearance = NSAppearance(named: .aqua)
            }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func inspect() {
        struct Report: Encodable {
            let channels: [String: Snapshot]
            let fans: FanSnapshot?
            let errors: [String: String]
        }
        var channels: [String: Snapshot] = [:]
        var errors: [String: String] = [:]
        for channel in Channel.allCases {
            do { channels[channel.rawValue] = try AppModel.driver(for: channel).read() } catch {
                errors[channel.rawValue] = error.localizedDescription
            }
        }
        var fans: FanSnapshot?
        do { fans = try SMCFanDriver().read() } catch { errors["fans"] = error.localizedDescription }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Report(channels: channels, fans: fans, errors: errors)) {
            print(String(decoding: data, as: UTF8.self))
        }
        if !errors.isEmpty { exit(1) }
    }
}

@MainActor
private enum DevelopmentBuild {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "VorsmateDevelopmentBuild") as? Bool == true

    static func stopForReload() -> Int32 {
        guard enabled, CommandLine.arguments.count == 2, let bundleID = Bundle.main.bundleIdentifier else {
            fputs("此命令只用于重载 Vorsmate 开发版。\n", stderr)
            return 2
        }
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.processIdentifier != ownPID
        }
        guard running.allSatisfy({ $0.bundleURL?.resolvingSymlinksInPath().path == bundlePath }) else {
            fputs("请先通过菜单退出正在运行的其他 Vorsmate，再启动开发版。\n", stderr)
            return 1
        }
        guard let instance = running.first else { return 0 }
        guard running.count == 1 else {
            fputs("发现多个开发实例，请先退出后再运行重载。\n", stderr)
            return 1
        }
        _ = instance.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !instance.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard instance.isTerminated else {
            fputs("开发版尚未退出，已保留当前构建。\n", stderr)
            return 1
        }
        return 0
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var model: AppModel?
    private var previewWindow: NSWindow?
    private var panelHeight: CGFloat = 360
    private let dismissal = PanelDismissal()
    private var panelEditing = false
    private var defaultStatusFont: NSFont?
    private var statusItemActivity: AnyCancellable?
    private lazy var panelAutomation = PanelAutomation { [weak self] in
        self?.automationDidChange()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        if !preview, let bundle = Bundle.main.bundleIdentifier,
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count > 1
        {
            NSApp.terminate(nil)
            return
        }
        installStandardMenus()
        let model = AppModel(preview: preview, development: DevelopmentBuild.enabled)
        model.panelVisible = preview
        model.translation.onPrepareScreenshot = { [weak self] in
            self?.popover.performClose(nil)
        }
        self.model = model
        let maximumHeight = min(760, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 72))
        let view = PanelView(
            model: model, maximumHeight: maximumHeight,
            protectInteraction: { [weak self] active in
                self?.panelEditing = active
                self?.updateDismissalBehavior()
            },
            onHeightChange: { [weak self] height in self?.resizePanel(to: height) })
        let host = NSHostingController(rootView: view)
        if preview && !CommandLine.arguments.contains("--preview-popover") {
            let window = NSWindow(contentViewController: host)
            window.title = "Vorsmate 预览"
            window.delegate = self
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 386, height: panelHeight))
            window.center()
            window.makeKeyAndOrderFront(nil)
            // 打开面板时不自动聚焦第一个按钮；Tab 仍可进入正常键盘导航。
            window.makeFirstResponder(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--preview-translate-window") {
                model.translation.openPreviewSampleSticker()
            }
            return
        }
        let badge = preview ? "预览" : nil
        item = NSStatusBar.system.statusItem(
            withLength: badge != nil ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        item?.button?.image = BrandIcon.template
        item?.button?.target = self
        item?.button?.action = #selector(statusItemClicked(_:))
        item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        defaultStatusFont = item?.button?.font
        statusItemActivity = Publishers.CombineLatest(
            Publishers.CombineLatest3(
                model.unattendedAuth.$isEnabled,
                model.unattendedAuth.$deadline,
                model.unattendedAuth.$now
            ),
            Publishers.CombineLatest4(
                model.shutdown.$countdown,
                model.shutdown.$pendingAction,
                model.shutdown.$executing,
                model.shutdown.$submitting
            )
        )
        .sink { [weak self] unattended, shutdown in
            self?.updateStatusItem(
                unattendedEnabled: unattended.0,
                unattendedDeadline: unattended.1,
                unattendedNow: unattended.2,
                shutdownCountdown: shutdown.0,
                shutdownAction: shutdown.1,
                shutdownExecuting: shutdown.2,
                shutdownSubmitting: shutdown.3
            )
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 386, height: panelHeight)
        popover.contentViewController = host
        panelAutomation.start()
        if CommandLine.arguments.contains("--show") { showPanel() }
    }
    private func installStandardMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Vorsmate")
        appMenu.addItem(withTitle: "退出 Vorsmate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appItem)
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(windowItem)
        windowItem.submenu = windowMenu
        NSApp.mainMenu = mainMenu
    }
    private func updateDismissalBehavior() {
        let protected = panelEditing || panelAutomation.isActive
        popover.behavior = protected ? .applicationDefined : .transient
        dismissal.suspended = protected
    }
    private func automationDidChange() {
        updateDismissalBehavior()
        if panelAutomation.isActive {
            if !popover.isShown { showPanel(makeKey: false) }
        } else {
            dismissal.resumeOutsideDismissal()
        }
    }
    private func resizePanel(to height: CGFloat) {
        guard abs(panelHeight - height) > 0.5 else { return }
        panelHeight = height
        let size = NSSize(width: 386, height: height)
        popover.contentSize = size
        if let window = previewWindow {
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
    private func updateStatusItem(
        unattendedEnabled: Bool,
        unattendedDeadline: Date?,
        unattendedNow: Date,
        shutdownCountdown: Int?,
        shutdownAction: ShutdownAction?,
        shutdownExecuting: Bool,
        shutdownSubmitting: Bool
    ) {
        guard let item, let button = item.button, let model else { return }
        let badge = model.preview ? "预览" : nil
        let monospacedFont = NSFont.monospacedDigitSystemFont(
            ofSize: defaultStatusFont?.pointSize ?? NSFont.systemFontSize,
            weight: .regular
        )
        if let shutdownTitle = ShutdownStatusFormatter.menuBarTitle(
            countdown: shutdownCountdown,
            action: shutdownAction,
            executing: shutdownExecuting,
            submitting: shutdownSubmitting
        ) {
            let title = badge.map { "\($0) · \(shutdownTitle)" } ?? shutdownTitle
            let tooltip =
                ShutdownStatusFormatter.menuBarTooltip(
                    countdown: shutdownCountdown,
                    action: shutdownAction,
                    executing: shutdownExecuting,
                    submitting: shutdownSubmitting
                ) ?? title
            if item.length != NSStatusItem.variableLength { item.length = NSStatusItem.variableLength }
            if button.font != monospacedFont { button.font = monospacedFont }
            if button.title != title { button.title = title }
            if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading }
            if button.toolTip != tooltip { button.toolTip = tooltip }
            if button.accessibilityLabel() != tooltip { button.setAccessibilityLabel(tooltip) }
        } else if let activeTitle = UnattendedAuthStatusFormatter.menuBarTitle(
            isEnabled: unattendedEnabled, deadline: unattendedDeadline, now: unattendedNow)
        {
            let title = badge.map { "\($0) · \(activeTitle)" } ?? activeTitle
            let fullStatus = UnattendedAuthStatusFormatter.fullStatus(
                isEnabled: unattendedEnabled, deadline: unattendedDeadline, now: unattendedNow)
            if item.length != NSStatusItem.variableLength { item.length = NSStatusItem.variableLength }
            if button.font != monospacedFont { button.font = monospacedFont }
            if button.title != title { button.title = title }
            if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading }
            if button.toolTip != fullStatus { button.toolTip = fullStatus }
            if button.accessibilityLabel() != fullStatus { button.setAccessibilityLabel(fullStatus) }
        } else {
            let length = badge != nil ? NSStatusItem.variableLength : NSStatusItem.squareLength
            let title = badge ?? ""
            let imagePosition: NSControl.ImagePosition = badge != nil ? .imageLeading : .imageOnly
            let itemName = model.preview ? "Vorsmate 预览" : (model.development ? "Vorsmate 开发版" : "Vorsmate")
            if item.length != length { item.length = length }
            if let defaultStatusFont, button.font != defaultStatusFont { button.font = defaultStatusFont }
            if button.title != title { button.title = title }
            if button.imagePosition != imagePosition { button.imagePosition = imagePosition }
            if button.toolTip != itemName { button.toolTip = itemName }
            if button.accessibilityLabel() != itemName { button.setAccessibilityLabel(itemName) }
        }
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick =
            event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            if model?.shutdown.canCancel == true || model?.unattendedAuth.isEnabled == true {
                showStatusMenu(from: sender)
            }
            return
        }
        togglePanel()
    }
    private func showStatusMenu(from button: NSStatusBarButton) {
        guard let model else { return }
        let hasShutdown = model.shutdown.canCancel
        let hasUnattended = model.unattendedAuth.isEnabled
        guard hasShutdown || hasUnattended else { return }
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if hasShutdown, let action = model.shutdown.pendingAction {
            let statusItem = NSMenuItem(
                title: model.shutdown.menuBarTitle ?? model.shutdown.status, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            menu.addItem(.separator())
            let cancelItem = NSMenuItem(
                title: "取消\(action.title)",
                action: #selector(cancelShutdownFromMenu),
                keyEquivalent: ""
            )
            cancelItem.target = self
            cancelItem.isEnabled = true
            menu.addItem(cancelItem)
            if hasUnattended { menu.addItem(.separator()) }
        }
        if hasUnattended {
            let statusItem = NSMenuItem(title: model.unattendedAuth.fullStatusText, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            if !hasShutdown { menu.addItem(.separator()) }
            let disableItem = NSMenuItem(
                title: "关闭无人值守授权",
                action: #selector(disableUnattendedAuthFromMenu),
                keyEquivalent: ""
            )
            disableItem.target = self
            disableItem.isEnabled = true
            menu.addItem(disableItem)
        }
        let openItem = NSMenuItem(
            title: "打开面板",
            action: #selector(openPanelFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.isEnabled = true
        menu.addItem(openItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
    @objc private func cancelShutdownFromMenu() {
        model?.shutdown.cancel()
    }
    @objc private func disableUnattendedAuthFromMenu() {
        model?.unattendedAuth.disable(reason: .manual)
    }
    @objc private func openPanelFromMenu() {
        if !popover.isShown { showPanel() }
    }
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }
    private func showPanel(makeKey: Bool = true) {
        guard let button = item?.button else { return }
        model?.refresh()
        model?.panelVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if makeKey { popover.contentViewController?.view.window?.makeKey() }
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        dismissal.start(popover: popover, anchor: button)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        panelAutomation.stop()
        dismissal.stop()
        model?.stop()
    }
    func windowWillClose(_ notification: Notification) { model?.panelVisible = false }
    func popoverDidClose(_ notification: Notification) {
        dismissal.stop()
        panelAutomation.reset()
        model?.panelVisible = false
    }
}
