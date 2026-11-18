// [INPUT]: 宿主继承的控制管道，或显式的本地预览 / 验收入口。
// [OUTPUT]: 可选插件进程，宿主管道断开后释放遥控器。
// [POS]: 不注册登录项，不更改第三方偏好；裸开仅看预览。
import AppKit
import Combine
import SwiftUI
import VorsmateCore

@main
@MainActor
final class RemoteApp: NSObject, NSApplicationDelegate {
    private lazy var monitor = RemoteMonitor(preview: preview)
    private var observation: AnyCancellable?
    private var lastState: RemoteEditorState?
    private let embeddedEditor = CommandLine.arguments.contains("--editor-v1")
    private var window: NSWindow?
    private let hosted = CommandLine.arguments.contains("--host-v1")
    private let verify = CommandLine.arguments.contains("--verify")
    private var preview: Bool { CommandLine.arguments.contains("--preview") || (!hosted && !verify) }

    static func main() {
        let app = NSApplication.shared
        let delegate = RemoteApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
        if hosted || verify {
            monitor.report = { message in try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
            }
        }
        if hosted {
            guard HostIdentity.acceptsParent() else {
                NSApp.terminate(nil)
                return
            }
            if preview { monitor.report("预览") }
            // The write end belongs exclusively to the host. EOF also covers a host crash.
            Task {
                do {
                    for try await command in FileHandle.standardInput.bytes.lines {
                        if embeddedEditor {
                            if let request = try? JSONDecoder().decode(
                                RemoteEditorCommand.self, from: Data(command.utf8))
                            {
                                handle(request)
                            }
                        } else if command == "open" {
                            show()
                        }
                    }
                } catch {}
                NSApp.terminate(nil)
            }
        }
        monitor.observeFrontmost()
        if !preview { monitor.start() }
        if !hosted { show() }
    }

    private func reply(_ message: RemoteEditorReply) {
        if let data = try? JSONEncoder().encode(message) {
            monitor.report(String(decoding: data, as: UTF8.self))
        }
    }

    private func publishState() {
        guard observation != nil else { return }
        let state = monitor.editorState
        if state != lastState {
            lastState = state
            reply(.state(state))
        }
    }

    private func handle(_ request: RemoteEditorCommand) {
        switch request {
        case .observe:
            monitor.reloadProfile()
            observation = monitor.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.publishState() }
            }
            lastState = nil
            publishState()
        case .stopObserving:
            observation = nil
            lastState = nil
        case .inputPermission:
            monitor.requestAccess()
            publishState()
        case .postPermission:
            monitor.requestPostAccess()
            publishState()
        case .configure(let id, let revision, let edit):
            let error = monitor.configure(edit, revision: revision)
            let state = monitor.editorState
            lastState = state
            reply(.saved(id, state: state, error: error))
        case .change(let id, let button, let gesture, let previous, let action):
            let error = monitor.edit(button, gesture: gesture, action: action, previous: previous)
            let state = monitor.editorState
            lastState = state
            reply(.saved(id, state: state, error: error))
        }
    }

    private func show() {
        if window == nil {
            let view = RemoteWindow(monitor: monitor, preview: preview, verify: verify)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "遥控器按键"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !hosted }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
}
