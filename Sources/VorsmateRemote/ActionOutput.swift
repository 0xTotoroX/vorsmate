// [INPUT]: 已确定的单个手势动作、选用的目标应用与 macOS 发送权限。
// [OUTPUT]: 一次快捷键、媒体键、应用激活或 Typeless 桥请求。
// [POS]: 不读取其他键盘输入，不更改前台软件的设置。
import AppKit
import IOKit.hidsystem
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
            try await bridge(0x76)
        case .shortcut:
            guard let code = action.keyCode else { throw RemoteError.message("快捷键缺少键码") }
            let flags = CGEventFlags(rawValue: action.flags ?? 0)
            if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == [
                .maskControl, .maskAlternate,
            ],
                code == 12 || code == 17, flags.rawValue & UInt64(NX_DEVICERCTLKEYMASK | NX_DEVICERALTKEYMASK) == 0,
                !flags.contains(.maskSecondaryFn),
                typelessRunning
            {
                try await bridge(code == 12 ? 0x71 : 0x74)
                return
            }
            try requirePostAccess()
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            else { throw RemoteError.message("无法创建快捷键事件") }
            var outputFlags = flags
            if [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 123, 124, 125, 126].contains(
                code)
            {
                outputFlags.insert(.maskNumericPad)
            }
            for event in [down, up] {
                event.flags = outputFlags
                event.post(tap: .cghidEventTap)
            }
        case .volumeUp: try media(0)
        case .volumeDown: try media(1)
        case .mute: try media(7)
        case .playPause: try media(16)
        case .previousTrack: try media(18)
        case .nextTrack: try media(17)
        }
    }

    private static var typelessRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop").isEmpty
    }
    private static func bridge(_ command: UInt8) async throws {
        guard typelessRunning else { throw RemoteError.message("请先打开 Typeless") }
        let posted = await Task.detached { TypelessBridge.post(command) }.value
        guard posted else { throw RemoteError.message("虚拟键盘桥未确认发送") }
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
