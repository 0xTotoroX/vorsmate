// [INPUT]: 已确定的单个手势动作、选用的目标应用与 macOS 发送权限。
// [OUTPUT]: 一次快捷键、媒体键、应用激活或 Typeless 听写热键。
// [POS]: 不读取其他键盘输入，不更改前台软件的设置。
import AppKit
import VorsmateCore

@MainActor
enum ActionOutput {
    static func send(_ action: RemoteAction) async throws {
        switch action.kind {
        case .none: return
        case .openApplication:
            guard let id = action.bundleID else { throw RemoteError.message("应用配置缺失") }
            let path = URL(fileURLWithPath: action.path ?? "")
            let url =
                Bundle(url: path)?.bundleIdentifier == id
                ? path : NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            guard let url else { throw RemoteError.message("找不到指定的应用") }
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .typeless:
            guard typelessRunning else { throw RemoteError.message("请先打开 Typeless") }
            // ANSI V, left Control and left Option from the user's existing Typeless shortcut.
            try sendShortcut(
                code: 9, raw: RemoteModifier.flags(RemoteModifier.all.filter { [59, 58].contains($0.code) }))
        case .shortcut:
            guard let code = action.keyCode else { throw RemoteError.message("快捷键缺少键码") }
            try sendShortcut(code: code, raw: action.flags ?? 0)
        case .volumeUp: try media(0)
        case .volumeDown: try media(1)
        case .mute: try media(7)
        case .playPause: try media(16)
        case .previousTrack: try media(18)
        case .nextTrack: try media(17)
        }
    }

    private static func sendShortcut(code: UInt16, raw: UInt64) throws {
        try requirePostAccess()
        let source = CGEventSource(stateID: .privateState)
        let events = try RemoteKeyEvent.sequence(code: code, flags: raw).map { stroke in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.code, keyDown: stroke.down) else {
                throw RemoteError.message("无法创建快捷键事件")
            }
            if stroke.modifier { event.type = .flagsChanged }
            event.flags = CGEventFlags(rawValue: stroke.flags)
            return event
        }
        for event in events { event.post(tap: .cghidEventTap) }
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
