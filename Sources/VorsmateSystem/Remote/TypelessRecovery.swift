// [INPUT]: 系统按键状态、Typeless 进程和 RC003 的已确认映射。
// [OUTPUT]: 只读诊断快照、私有本地记录和固定应用的正常退出／打开操作。
// [POS]: 不创建键盘监听，不读取或写入音频与键位配置。
import AppKit
import CoreGraphics
import IOKit.hidsystem
import VorsmateCore

package struct TypelessDiagnosis: Codable {
    package enum Listener: String, Codable {
        case enabled, disabled, missing, unavailable

        package var title: String {
            switch self {
            case .enabled: "已启用"
            case .disabled: "已停用"
            case .missing: "未发现"
            case .unavailable: "无法读取"
            }
        }
    }

    package enum RemoteConnection: String, Codable {
        case connected, disconnected, unavailable

        package var title: String {
            switch self {
            case .connected: "已连接"
            case .disconnected: "未连接"
            case .unavailable: "无法读取"
            }
        }
    }

    package enum RemoteTakeover: String, Codable {
        case active, inactive, disabled, absent, unavailable

        package var title: String {
            switch self {
            case .active: "已接管"
            case .inactive: "未接管"
            case .disabled: "插件已关闭"
            case .absent: "插件未就绪"
            case .unavailable: "无法确认"
            }
        }
    }

    package let timestamp: Date
    package let running: Bool
    package let listener: Listener
    package let modifiers: [String]
    package let remoteConnection: RemoteConnection
    package let remoteTakeover: RemoteTakeover

    package init(
        running: Bool, listener: Listener, modifiers: [String], remoteConnection: RemoteConnection,
        remoteTakeover: RemoteTakeover
    ) {
        timestamp = Date()
        self.running = running
        self.listener = listener
        self.modifiers = modifiers
        self.remoteConnection = remoteConnection
        self.remoteTakeover = remoteTakeover
    }

    package var guidance: String {
        if !running { return "可以在这里打开 Typeless，再试一次听写快捷键。" }
        if listener == .disabled || listener == .missing || !modifiers.isEmpty {
            return "请松开按键，在空白输入框试一次实体键盘的听写快捷键。若仍失灵，可重新打开 Typeless。"
        }
        if remoteConnection == .connected && remoteTakeover != .active {
            return "遥控器已连接，但 Vorsmate 尚未接管。请查看「遥控器」的状态提示。"
        }
        return "请在空白输入框试一次实体键盘。若只有遥控器失灵，先查看「遥控器」的状态提示。"
    }
}

@MainActor
package struct TypelessRestartTarget {
    package let requestExit: () -> Bool
    package let hasExited: () -> Bool
    package let open: () async throws -> Void

    package init(
        requestExit: @escaping () -> Bool, hasExited: @escaping () -> Bool, open: @escaping () async throws -> Void
    ) {
        self.requestExit = requestExit
        self.hasExited = hasExited
        self.open = open
    }
}

@MainActor
package enum TypelessSystem {
    private static let bundleID = "now.typeless.desktop"

    private static var running: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    package static func diagnose(companionPresent: Bool, companionEnabled: Bool, companionReady: Bool)
        -> TypelessDiagnosis
    {
        let apps = running
        let (connection, mapped) = remote()
        let takeover: TypelessDiagnosis.RemoteTakeover
        if !companionPresent {
            takeover = .absent
        } else if !companionEnabled {
            takeover = .disabled
        } else if connection == .unavailable {
            takeover = .unavailable
        } else {
            takeover = companionReady && mapped ? .active : .inactive
        }
        return TypelessDiagnosis(
            running: !apps.isEmpty, listener: listener(for: Set(apps.map(\.processIdentifier))),
            modifiers: modifiers(), remoteConnection: connection, remoteTakeover: takeover)
    }

    private static func listener(for pids: Set<pid_t>) -> TypelessDiagnosis.Listener {
        guard !pids.isEmpty else { return .missing }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 256)
        var count: UInt32 = 0
        guard CGGetEventTapList(UInt32(taps.count), &taps, &count) == .success else { return .unavailable }
        let keyboard = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (1 << $1.rawValue)
        }
        let relevant = taps.prefix(Int(count)).filter {
            pids.contains($0.tappingProcess) && $0.eventsOfInterest & keyboard != 0
        }
        if relevant.contains(where: \.enabled) { return .enabled }
        if count >= taps.count { return .unavailable }
        return relevant.isEmpty ? .missing : .disabled
    }

    private static func modifiers() -> [String] {
        let sources: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState]
        let sided: [(CGKeyCode, String)] = [
            (59, "左 Control"), (62, "右 Control"), (58, "左 Option"), (61, "右 Option"),
        ]
        var held = sided.filter { code, _ in
            sources.contains { CGEventSource.keyState($0, key: code) }
        }.map(\.1)
        let flags = sources.reduce(CGEventFlags()) { $0.union(CGEventSource.flagsState($1)) }
        if flags.contains(.maskControl) && !held.contains(where: { $0.hasSuffix("Control") }) { held.append("Control") }
        if flags.contains(.maskAlternate) && !held.contains(where: { $0.hasSuffix("Option") }) { held.append("Option") }
        if flags.contains(.maskSecondaryFn) || sources.contains(where: { CGEventSource.keyState($0, key: 63) }) {
            held.append("Fn")
        }
        return held
    }

    private static func remote() -> (TypelessDiagnosis.RemoteConnection, Bool) {
        let client = IOHIDEventSystemClientCreateSimpleClient(nil)
        defer { withExtendedLifetime(client) {} }
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
            return (.unavailable, false)
        }
        let keyboards = services.filter { service in
            RemoteDeviceIdentity.keyboard.allSatisfy { name, value in
                (IOHIDServiceClientCopyProperty(service, name as CFString) as? NSObject)?.isEqual(value) == true
            }
        }
        guard !keyboards.isEmpty else { return (.disconnected, false) }
        guard keyboards.count == 1, let service = keyboards.first,
            let mapping = IOHIDServiceClientCopyProperty(service, RemoteDeviceIdentity.mapping as CFString)
                as? [[String: NSNumber]]
        else { return (.connected, false) }
        return (.connected, mapping.contains { $0[RemoteDeviceIdentity.mappingOwner] == 1 })
    }

    package static func save(_ snapshot: TypelessDiagnosis) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Vorsmate/TypelessRecovery", directoryHint: .isDirectory)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: snapshot.timestamp).replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "\(stamp)-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    package static func restartTarget() throws -> TypelessRestartTarget {
        let instances = running
        guard instances.count <= 1 else { throw RecoveryError.multipleInstances }
        let instance = instances.first
        guard let url = instance?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            Bundle(url: url)?.bundleIdentifier == bundleID
        else { throw RecoveryError.appUnavailable }
        return TypelessRestartTarget(
            requestExit: {
                guard let instance, !instance.isTerminated else { return true }
                return instance.terminate() || instance.isTerminated
            },
            hasExited: { instance?.isTerminated ?? true },
            open: {
                guard Bundle(url: url)?.bundleIdentifier == bundleID else { throw RecoveryError.appUnavailable }
                guard running.isEmpty else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            })
    }

    private enum RecoveryError: LocalizedError {
        case multipleInstances, appUnavailable
        var errorDescription: String? {
            switch self {
            case .multipleInstances: "发现多份 Typeless 正在运行。请先确认要保留哪一份。"
            case .appUnavailable: "找不到 Typeless 应用。"
            }
        }
    }
}
