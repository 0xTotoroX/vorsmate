// [INPUT]: Foundation XPC、Security 签名身份、Codable 风扇命令。
// [OUTPUT]: 固定能力协议、双向签名要求、超时且仅完成一次的调用，保留助手的具体错误。
// [POS]: UI 与 root 助手的窄边界；不接受任意文件、进程、命令或 SMC 键。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Security
import VorsmateCore

public enum FanServiceIdentity {
    public static let name = "app.vorsmate.fan-helper"
    public static let app = "app.vorsmate.mac"
    public static let plist = "app.vorsmate.fan-helper.plist"
    public static func teamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    public static func requirement(identifier: String) throws -> String {
        guard let team = teamID(), team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw FanFailure.notAuthorized
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
}

public struct FanCommand: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case status, configure, release }
    public var action: Action
    public var fanID: Int?
    public var profile: FanProfile?
    public init(action: Action, fanID: Int? = nil, profile: FanProfile? = nil) {
        self.action = action
        self.fanID = fanID
        self.profile = profile
    }
}

@objc public protocol FanHelperProtocol {
    func perform(_ data: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

@MainActor
public final class FanConnection {
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    public init() {}
    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        let requirement = try FanServiceIdentity.requirement(identifier: FanServiceIdentity.name)
        let value = NSXPCConnection(machServiceName: FanServiceIdentity.name, options: .privileged)
        let id = UUID()
        value.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        value.setCodeSigningRequirement(requirement)
        value.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.connection = nil
                self.connectionID = nil
            }
        }
        value.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.invalidate()
            }
        }
        value.resume()
        connection = value
        connectionID = id
        return value
    }
    public func invalidate() {
        connection?.invalidate()
        connection = nil
        connectionID = nil
    }
    public func request(_ command: FanCommand) async throws -> FanSnapshot {
        let data = try JSONEncoder().encode(command)
        let connection = try connected()
        let id = connectionID
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    pending.finish(.failure(error))
                } as? FanHelperProtocol
            guard let proxy else {
                pending.finish(.failure(FanFailure.notAuthorized))
                return
            }
            proxy.perform(data) { data, error in
                // 助手已经格式化业务 / 硬件错误，不能一律再标成风扇访问失败。
                if let error {
                    pending.finish(.failure(FanFailure.remote(error)))
                    return
                }
                do {
                    guard let data, data.count < 100_000 else { throw FanFailure.unavailable }
                    pending.finish(.success(try JSONDecoder().decode(FanSnapshot.self, from: data)))
                } catch { pending.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                if pending.finish(.failure(FanFailure.connectionTimeout)) {
                    Task { @MainActor in
                        guard let self, self.connectionID == id else { return }
                        // 不让迟到的控制请求在调用方已报错后继续保有续期连接。
                        self.invalidate()
                    }
                }
            }
        }
    }
}

private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FanSnapshot, Error>?
    init(_ continuation: CheckedContinuation<FanSnapshot, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<FanSnapshot, Error>) -> Bool {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(with: result)
        return saved != nil
    }
}
