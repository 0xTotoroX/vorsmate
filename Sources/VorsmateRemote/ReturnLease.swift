// [INPUT]: RC003 的 HID 键盘服务、当前映射表和本机恢复记录。
// [OUTPUT]: 只屏蔽该设备的 Return，保留其他来源和其他键的映射。
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
    private let client = IOHIDEventSystemClientCreateSimpleClient(nil)
    private let key = "UserKeyMapping" as CFString
    private let source = "HIDKeyboardModifierMappingSrc"
    private let destination = "HIDKeyboardModifierMappingDst"
    private let enter = NSNumber(value: UInt64(0x7_0000_0028))
    private var entry: [String: NSNumber] { [source: enter, destination: 0, "VorsmateRemoteLease": 1] }
    private let directory = URL.applicationSupportDirectory.appending(path: "VorsmateRemote")
    private var journal: URL { directory.appending(path: "return-lease") }
    private var lockFD: Int32 = -1
    private var active: IOHIDServiceClient?
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

    private func services() -> [IOHIDServiceClient] {
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
            throw RemoteError.message("系统未确认遥控器回车屏蔽，请检查输入监控权限")
        }
    }

    func acquire() throws {
        try recover()
        let matches = services()
        guard matches.count == 1, let service = matches.first else { throw RemoteError.message("等待唯一的 RC003 键盘服务") }
        let map = try mappings(service)
        guard !map.contains(where: { $0[source] == enter }) else {
            throw RemoteError.message("确定键已有设备级映射，请先释放")
        }
        guard !boot.isEmpty else { throw RemoteError.message("无法标记当前设备会话") }
        try token(service).write(to: journal, atomically: true, encoding: .utf8)
        do { try write(map + [entry], to: service) } catch {
            // Some HID filters may omit unknown metadata on readback. Undo only the
            // exact untagged result of this write before giving up ownership.
            if try mappings(service) == map + [[source: enter, destination: 0]] {
                try write(map, to: service)
            }
            throw error
        }
        active = service
    }

    func isSuppressed() -> Bool {
        guard let active, let map = try? mappings(active) else { return false }
        return map.filter { $0[source] == enter } == [entry]
    }

    func recover() throws {
        active = nil
        guard lockFD >= 0, FileManager.default.fileExists(atPath: journal.path) else { return }
        let saved = try String(contentsOf: journal, encoding: .utf8)
        if let target = services().first(where: { token($0) == saved }) {
            let map = try mappings(target)
            if map.contains(entry) {
                try write(map.filter { $0 != entry }, to: target)
            }
        }
        try FileManager.default.removeItem(at: journal)
    }
}
