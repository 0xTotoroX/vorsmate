// [INPUT]: SMAppService 的 MachService、已签名客户端、系统温度压力与恢复记录。
// [OUTPUT]: root 下受限风扇服务；单调时钟调速 / 租约；固定关机 / 重启前释放风扇，命令启动后回执。
// [POS]: 唯一特权进程；启动与读状态不接管未记录的风扇。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import OSLog
import VorsmateCore
import VorsmateFan

@main
@MainActor
enum HelperMain {
    static func main() {
        guard geteuid() == 0 else { return }
        do {
            let store = OwnershipStore()
            let runtime = FanRuntime(hardware: SMCFanDriver(), owned: try store.load(), persist: store.save)
            runtime.releaseAll()
            let service = HelperService(runtime: runtime)
            let listener = NSXPCListener(machServiceName: FanServiceIdentity.name)
            listener.setConnectionCodeSigningRequirement(
                try FanServiceIdentity.requirement(identifier: FanServiceIdentity.app))
            listener.delegate = service
            listener.resume()
            // 定时续期检查不依赖客户端消息；保留主线程供 MainActor 串行访问硬件。
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    runtime.tick(
                        at: ProcessInfo.processInfo.systemUptime, thermalState: ProcessInfo.processInfo.thermalState)
                }
            }
            let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated {
                        runtime.releaseAll()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
            withExtendedLifetime((service, listener, timer, signals)) { RunLoop.main.run() }
        } catch {
            FileHandle.standardError.write(Data("Vorsmate fan helper: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

@MainActor
private final class HelperService: NSObject, NSXPCListenerDelegate {
    private let runtime: FanRuntime
    private var owner: UUID?
    init(runtime: FanRuntime) { self.runtime = runtime }
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool
    {
        let token = UUID()
        let endpoint = Endpoint { [weak self] command in
            guard let self else { throw FanFailure.unavailable }
            if command.action == .configure {
                guard self.owner == nil || self.owner == token else { throw FanFailure.competingTool }
                self.owner = token
            }
            if self.owner == token {
                if command.action != .status || !self.runtime.profiles.isEmpty {
                    self.runtime.renew(at: ProcessInfo.processInfo.systemUptime)
                } else if self.runtime.owned.isEmpty {
                    self.owner = nil
                }
            }
            switch command.action {
            case .status: break
            case .configure:
                guard let id = command.fanID, let profile = command.profile else { throw FanFailure.unavailable }
                try self.runtime.configure(
                    fanID: id, profile: profile, at: ProcessInfo.processInfo.systemUptime,
                    thermalState: ProcessInfo.processInfo.thermalState)
            case .release, .shutdown, .restart:
                guard command.action != .release || self.owner == nil || self.owner == token else {
                    throw FanFailure.competingTool
                }
                self.runtime.releaseAll()
                guard self.runtime.owned.isEmpty else { throw FanFailure.hardware("系统控制恢复尚未确认，助手继续重试。") }
                self.owner = nil
            }
            return try self.runtime.snapshot()
        }
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.owner == token else { return }
                self.runtime.releaseAll()
                self.owner = nil
            }
        }
        connection.resume()
        return true
    }
}

private final class Endpoint: NSObject, FanHelperProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "app.vorsmate.mac", category: "ShutdownHelper")
    private let action: @MainActor @Sendable (FanCommand) throws -> FanSnapshot
    init(action: @escaping @MainActor @Sendable (FanCommand) throws -> FanSnapshot) { self.action = action }
    func perform(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard data.count < 4096 else {
            reply(nil, "请求过大")
            return
        }
        Task { @MainActor in
            do {
                let command = try JSONDecoder().decode(FanCommand.self, from: data)
                try command.validate()
                let snapshot = try JSONEncoder().encode(action(command))
                if command.action == .shutdown || command.action == .restart {
                    // 回执只确认固定命令已启动，整机关机由 macOS 完成。
                    let process = Process()
                    process.executableURL = URL(filePath: "/sbin/shutdown")
                    process.arguments = [command.action == .shutdown ? "-h" : "-r", "now"]
                    let operation = command.action.rawValue
                    process.terminationHandler = { [logger] process in
                        if process.terminationReason != .exit || process.terminationStatus != 0 {
                            logger.error(
                                "\(operation, privacy: .public) command exited with status \(process.terminationStatus)"
                            )
                        }
                    }
                    do { try process.run() } catch {
                        logger.error(
                            "Could not launch \(operation, privacy: .public) command: \(error.localizedDescription)")
                        reply(nil, "无法启动\(command.action == .shutdown ? "关机" : "重启")命令：\(error.localizedDescription)")
                        return
                    }
                    logger.info("Started \(operation, privacy: .public) command")
                }
                reply(snapshot, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}

private struct OwnershipStore {
    private let folder = URL(filePath: "/var/db/vorsmate", directoryHint: .isDirectory)
    private var file: URL { folder.appending(path: "owned-fans.json") }
    func load() throws -> Set<Int> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let value = try JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: file))
        guard value.allSatisfy({ (0..<8).contains($0) }) else { throw FanFailure.invalidRange }
        return value
    }
    func save(_ ids: Set<Int>) throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(ids).write(to: file, options: .atomic)
    }
}
