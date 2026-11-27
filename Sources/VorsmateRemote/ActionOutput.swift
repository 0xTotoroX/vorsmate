// [INPUT]: 已确定的单个手势动作、选用的目标应用与 macOS 发送权限。
// [OUTPUT]: 一次快捷键、媒体键、有界异步应用激活或可中止的 Typeless 听写热键。
// [POS]: 不读取其他键盘输入，不更改前台软件的设置。
import AppKit
import VorsmateCore

@MainActor
enum ActionOutput {
    private static let shortcutSource = CGEventSource(stateID: .privateState)
    private static let modifierSettleTime = Duration.milliseconds(8)
    private static let chordKeyHoldTime = Duration.milliseconds(45)

    static func send(_ action: RemoteAction, shouldAbort: @MainActor () -> Bool = { false }) async throws {
        switch action.kind {
        case .none: return
        case .openApplication:
            guard let id = action.bundleID else { throw RemoteError.message("应用配置缺失") }
            let path = URL(fileURLWithPath: action.path ?? "")
            let url =
                Bundle(url: path)?.bundleIdentifier == id
                ? path : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            guard let url else { throw RemoteError.message("找不到指定的应用") }
            try await openApplicationBounded(at: url)
        case .typeless, .shortcut:
            if action.kind == .typeless && !typelessRunning { throw RemoteError.message("请先打开 Typeless") }
            let shortcut = action.editableAction
            guard let code = shortcut.keyCode else { throw RemoteError.message("快捷键缺少键码") }
            try await sendShortcut(code: code, raw: shortcut.flags ?? 0, shouldAbort: shouldAbort)
        case .volumeUp: try media(0)
        case .volumeDown: try media(1)
        case .mute: try media(7)
        case .playPause: try media(16)
        case .previousTrack: try media(18)
        case .nextTrack: try media(17)
        }
    }

    private static func openApplicationBounded(at url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = OpenResultBox(continuation)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    box.finish(.failure(error))
                } else {
                    box.finish(.success(()))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(800)) {
                // 启动请求已交给 LaunchServices，超时后立即交回队列控制权，避免阻塞后续快捷键。
                box.finish(.success(()))
            }
        }
    }

    private static func sendShortcut(
        code: UInt16, raw: UInt64, shouldAbort: @MainActor () -> Bool
    ) async throws {
        try requirePostAccess()
        try Task.checkCancellation()
        let strokes = RemoteKeyEvent.sequence(code: code, flags: raw)
        let events = try strokes.map { stroke in
            guard
                let event = CGEvent(
                    keyboardEventSource: shortcutSource, virtualKey: stroke.code, keyDown: stroke.down)
            else {
                throw RemoteError.message("无法创建快捷键事件")
            }
            if stroke.modifier { event.type = .flagsChanged }
            event.flags = CGEventFlags(rawValue: stroke.flags)
            return event
        }
        let chord = strokes.contains(where: { $0.modifier }) && strokes.contains(where: { !$0.modifier })
        var heldModifiers: [RemoteKeyEvent] = []
        // 已按下的组合键完整释放；定时等待期间主线程仍可接收 HID 和语音报告。
        for (stroke, event) in zip(strokes, events) {
            if !stroke.modifier && stroke.down && (Task.isCancelled || shouldAbort()) {
                releaseModifiers(heldModifiers)
                throw CancellationError()
            }
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.post(tap: .cghidEventTap)
            if stroke.modifier {
                if stroke.down {
                    heldModifiers.append(stroke)
                } else if let idx = heldModifiers.lastIndex(where: { $0.code == stroke.code }) {
                    heldModifiers.remove(at: idx)
                }
            }
            if chord {
                try? await Task.sleep(for: stroke.down && !stroke.modifier ? chordKeyHoldTime : modifierSettleTime)
            }
        }
    }

    private static func releaseModifiers(_ heldModifiers: [RemoteKeyEvent]) {
        for stroke in heldModifiers.reversed() {
            guard
                let up = CGEvent(
                    keyboardEventSource: shortcutSource, virtualKey: stroke.code, keyDown: false)
            else { continue }
            up.type = .flagsChanged
            up.flags = []
            up.timestamp = DispatchTime.now().uptimeNanoseconds
            up.post(tap: .cghidEventTap)
        }
    }

    private static var typelessRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop").isEmpty
    }
    private static func requirePostAccess() throws {
        if !CGPreflightPostEventAccess() { throw RemoteError.message("发送快捷键需要辅助功能权限") }
    }
    private static func media(_ type: Int) throws {
        try requirePostAccess()
        for state in [0xA, 0xB] {
            guard
                let event = NSEvent.otherEvent(
                    with: .systemDefined, location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, subtype: 8, data1: (type << 16) | (state << 8), data2: -1)?.cgEvent
            else {
                throw RemoteError.message("无法创建媒体按键事件")
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

private final class OpenResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let saved = continuation
            continuation = nil
            return saved
        }
        pending?.resume(with: result)
    }
}
