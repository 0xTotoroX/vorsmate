// [INPUT]: RC003 的 HID 键盘服务、当前映射表和本机恢复记录。
// [OUTPUT]: 只映射该设备已配置的按键，保留其他来源和其他键的映射。
// [POS]: 读取回验后才允许派发；异常退出后按启动会话和服务 ID 收回本插件的条目。
import Foundation
import IOKit.hidsystem

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

@MainActor
final class ReturnLease {
    static let identity: [String: Any] = [
        "VendorID": 0x2717, "ProductID": 0x32b8, "Transport": "Bluetooth Low Energy",
        "PrimaryUsagePage": 1, "PrimaryUsage": 6,
    ]
    private typealias Map = [[String: NSNumber]]
    private let key = "UserKeyMapping" as CFString
    private let source = "HIDKeyboardModifierMappingSrc"
    private let destination = "HIDKeyboardModifierMappingDst"
    private let owner = "VorsmateRemoteLease"
    private var expected: Map = []
    private let directory = URL.applicationSupportDirectory.appending(path: "VorsmateRemote")
    private var journal: URL { directory.appending(path: "return-lease") }
    private var lockFD: Int32 = -1
    private var active: (client: IOHIDEventSystemClient, service: IOHIDServiceClient)?
    private let boot: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    func lock() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appending(path: "session.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteError.message("无法打开插件会话") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RemoteError.message("另一份遥控器插件正在运行")
        }
        lockFD = fd
    }

    deinit { if lockFD >= 0 { close(lockFD) } }

    private func services(using client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return all.filter { service in
            Self.identity.allSatisfy { name, expected in
                (IOHIDServiceClientCopyProperty(service, name as CFString) as? NSObject)?.isEqual(expected) == true
            }
        }
    }

    private func token(_ service: IOHIDServiceClient) -> String {
        "\(boot)/\(IOHIDServiceClientGetRegistryID(service))"
    }

    private func mappings(_ service: IOHIDServiceClient) throws -> Map {
        guard let value = IOHIDServiceClientCopyProperty(service, key) else { return [] }
        guard let map = value as? Map else { throw RemoteError.message("无法读取设备键位") }
        return map
    }

    private func write(_ map: Map, to service: IOHIDServiceClient) throws {
        guard IOHIDServiceClientSetProperty(service, key, map as CFArray), try mappings(service) == map else {
            throw RemoteError.message("系统未确认遥控器键位映射，请检查输入监控权限")
        }
    }

    func acquire(_ desired: [UInt64: UInt64]) throws {
        // 登录早期建立的客户端可能一直看不到稍后出现的蓝牙服务。每次接管用新的服务列表。
        let client = IOHIDEventSystemClientCreateSimpleClient(nil)
        let matches = services(using: client)
        guard matches.count == 1, let service = matches.first else { throw RemoteError.message("等待唯一的 RC003 键盘服务") }
        let replacing = active.map { token($0.service) == token(service) } ?? false
        if !replacing { try recover() }
        let previous = try mappings(service)
        // Switch profiles on the same device in one HID write; the shared Return suppression stays in place.
        let map = replacing ? previous.filter { $0[owner] != 1 } : previous
        let claimed = Set(desired.keys.map { NSNumber(value: $0) })
        guard !map.contains(where: { $0[source].map(claimed.contains) == true }) else {
            throw RemoteError.message("遥控器已有冲突的设备映射，请先释放")
        }
        guard !boot.isEmpty else { throw RemoteError.message("无法标记当前设备会话") }
        let entries: Map = desired.keys.sorted().map {
            [source: NSNumber(value: $0), destination: NSNumber(value: desired[$0]!), owner: 1]
        }
        if !replacing { try token(service).write(to: journal, atomically: true, encoding: .utf8) }
        if previous != map + entries {
            do { try write(map + entries, to: service) } catch {
                if try mappings(service) == map + entries.map({ $0.filter { $0.key != owner } }) {
                    try write(map, to: service)
                }
                throw error
            }
        }
        active = (client, service)
        expected = entries
    }

    func isSuppressed() -> Bool {
        guard let active, let map = try? mappings(active.service) else { return false }
        let claimed = Set(expected.compactMap { $0[source] })
        let readback = map.filter { $0[source].map(claimed.contains) == true }
        return readback.count == expected.count && expected.allSatisfy(readback.contains)
    }

    func recover() throws {
        active = nil
        expected = []
        guard lockFD >= 0, FileManager.default.fileExists(atPath: journal.path) else { return }
        let saved = try String(contentsOf: journal, encoding: .utf8)
        let client = IOHIDEventSystemClientCreateSimpleClient(nil)
        defer { withExtendedLifetime(client) {} }
        if let target = services(using: client).first(where: { token($0) == saved }) {
            let map = try mappings(target)
            let remaining = map.filter { $0[owner] != 1 }
            if remaining.count != map.count { try write(remaining, to: target) }
        }
        try FileManager.default.removeItem(at: journal)
    }
}
