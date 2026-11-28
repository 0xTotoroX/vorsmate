// [INPUT]: 更新状态、进度及当前阶段允许的操作。
// [OUTPUT]: 紧凑的原生更新窗口，所有阶段复用同一位置与控件。
// [POS]: 更新专用视图与一次性动作状态；不执行下载或安装。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI

@MainActor
final class UpdatePanelModel: ObservableObject {
    @Published var title = "检查更新"
    @Published var detail = ""
    @Published var progress: Double?
    @Published var busy = false
    @Published private(set) var primary: String?
    @Published private(set) var secondary: String?
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    var canClose: Bool { primaryAction != nil || secondaryAction != nil }

    func present(
        _ title: String, detail: String, busy: Bool = false, primary: String? = nil, action: (() -> Void)? = nil,
        secondary: String? = nil, cancel: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.busy = busy
        self.progress = nil
        self.primary = primary
        self.secondary = secondary
        primaryAction = action
        secondaryAction = cancel
    }

    func performPrimary() { perform(primaryAction) }
    func performSecondary() { perform(secondaryAction) }
    func close() { perform(secondaryAction ?? primaryAction) }
    private func perform(_ action: (() -> Void)?) {
        guard let action else { return }
        primaryAction = nil
        secondaryAction = nil
        primary = nil
        secondary = nil
        action()
    }
}

struct UpdatePanelView: View {
    @ObservedObject var model: UpdatePanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vorsmate").font(.headline)
                    Text(model.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.detail.isEmpty {
                Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            if model.busy {
                if let progress = model.progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                if let secondary = model.secondary {
                    Button(secondary) { model.performSecondary() }.keyboardShortcut(.cancelAction)
                }
                if let primary = model.primary {
                    Button(primary) { model.performPrimary() }.buttonStyle(.borderedProminent).keyboardShortcut(
                        .defaultAction)
                }
            }
        }
        .padding(24).padding(.top, 8)
        .frame(width: 340, alignment: .leading)
    }
}

@MainActor
final class UpdatePanelController: NSObject, NSWindowDelegate {
    let model = UpdatePanelModel()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let host = NSHostingController(rootView: UpdatePanelView(model: model))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.title = "软件更新"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { window?.orderOut(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.canClose else { return false }
        model.close()
        return true
    }
}
