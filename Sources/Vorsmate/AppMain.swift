// [INPUT]: AppKit 生命周期、PanelView、AppModel、BrandIcon；--inspect / --preview 开发入口。
// [OUTPUT]: 原生菜单栏应用、随内容伸缩并离开自动收起的面板 / 预览、只读 JSON 检查。
// [POS]: 可执行入口，.app 由 scripts/build.sh 打包。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateFan

@main
@MainActor
enum VorsmateMain {
    static func main() {
        if CommandLine.arguments.contains("--inspect") {
            inspect()
            return
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--preview"), CommandLine.arguments.contains("--preview-dark") {
            app.appearance = NSAppearance(named: .darkAqua)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var model: AppModel?
    private var previewWindow: NSWindow?
    private var panelHeight: CGFloat = 360
    private let dismissal = PanelDismissal()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview")
        if !preview, let bundle = Bundle.main.bundleIdentifier,
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count > 1
        {
            NSApp.terminate(nil)
            return
        }
        let model = AppModel(preview: preview)
        model.panelVisible = preview
        self.model = model
        let maximumHeight = min(650, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
        let view = PanelView(model: model, maximumHeight: maximumHeight) { [weak self] height in
            self?.resizePanel(to: height)
        }
        let host = NSHostingController(rootView: view)
        if preview {
            let window = NSWindow(contentViewController: host)
            window.title = "Vorsmate 预览"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 386, height: panelHeight))
            window.center()
            window.makeKeyAndOrderFront(nil)
            // 打开面板时不自动聚焦第一个按钮；Tab 仍可进入正常键盘导航。
            window.makeFirstResponder(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = BrandIcon.template
        item?.button?.setAccessibilityLabel("Vorsmate")
        item?.button?.toolTip = "Vorsmate"
        item?.button?.target = self
        item?.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 386, height: panelHeight)
        popover.contentViewController = host
        if CommandLine.arguments.contains("--show") { showPanel() }
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
    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }
    private func showPanel() {
        guard let button = item?.button else { return }
        model?.refresh()
        model?.panelVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
        dismissal.start(popover: popover, anchor: button)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        dismissal.stop()
        model?.stop()
    }
    func popoverDidClose(_ notification: Notification) {
        dismissal.stop()
        model?.panelVisible = false
    }
}
