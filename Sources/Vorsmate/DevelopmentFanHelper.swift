// [INPUT]: 固定日常开发包、SMAppService、已验签的风扇 XPC 连接及系统进程路径。
// [OUTPUT]: 交还风扇、重新登记包内助手，或只读确认应答进程来自当前开发包。
// [POS]: scripts/dev.sh 在主程序交接时显式调用；模拟预览与正式版不登记开发服务。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Darwin
import Foundation
import ServiceManagement
import VorsmateCore
import VorsmateFan

@MainActor
enum DevelopmentFanHelper {
    static func run() -> Never {
        let bundle = Bundle.main
        let path = bundle.bundleURL.resolvingSymlinksInPath()
        guard CommandLine.arguments.count == 3,
            let action = CommandLine.arguments.last, ["verify", "sync"].contains(action),
            bundle.object(forInfoDictionaryKey: "VorsmateDevelopmentBuild") as? Bool == true,
            bundle.object(forInfoDictionaryKey: "VorsmateDevelopmentFanHelperHash") is String,
            bundle.bundleIdentifier == FanServiceIdentity.app, FanServiceIdentity.teamID() != nil,
            Array(path.pathComponents.suffix(4)) == ["artifacts", "dev", "run", "Vorsmate.app"]
        else {
            fputs("风扇助手交接仅供已签名并启用助手跟随的固定日常开发包使用。\n", stderr)
            exit(2)
        }
        let service = SMAppService.daemon(plistName: FanServiceIdentity.plist)
        Task {
            do {
                if action == "sync" { try await synchronize(service) }
                guard service.status == .enabled else { throw FanFailure.notAuthorized }
                try await verify(expected: path.appending(path: "Contents/MacOS/VorsmateFanHelper"))
                exit(0)
            } catch {
                if service.status == .requiresApproval {
                    fputs("请在系统设置「通用 → 登录项与扩展」中允许 Vorsmate 的后台服务。\n", stderr)
                    exit(3)
                }
                let reason = error as NSError
                fputs("风扇助手：\(reason.localizedDescription) (\(reason.domain) \(reason.code))\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func synchronize(_ service: SMAppService) async throws {
        guard service.status != .requiresApproval else { throw FanFailure.notAuthorized }
        let replacing = service.status == .enabled
        if replacing {
            try await FanConnection.releaseRegisteredHelperForReload()
            try await service.unregister()
        }
        // macOS 的后台登记有时在注销完成后仍短暂返回 EPERM，等待交接结束再登记一次。
        do {
            try service.register()
        } catch {
            guard replacing, service.status != .requiresApproval, (error as NSError).code == Int(EPERM) else {
                throw error
            }
            try await Task.sleep(for: .seconds(2))
            guard service.status != .requiresApproval else { throw FanFailure.notAuthorized }
            if service.status != .enabled { try service.register() }
        }
    }

    private static func verify(expected: URL) async throws {
        let client = FanConnection()
        defer { client.invalidate() }
        _ = try await client.request(FanCommand(action: .status))
        guard let pid = client.peerPID, pid > 0 else { throw FanFailure.unavailable }
        var bytes = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else {
            throw FanFailure.remote("无法回读应答助手的路径。")
        }
        let actual = URL(filePath: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)).resolvingSymlinksInPath()
        guard actual.path == expected.path else { throw FanFailure.remote("系统应答来自另一份风扇助手：\(actual.path)") }
        print("开发版风扇助手已应答：\(actual.path) (PID \(pid))")
    }
}
