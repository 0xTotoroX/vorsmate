// [INPUT]: VorsmateCore 的 Snapshot、Source 与 Channel。
// [OUTPUT]: 主线程 SourceDriver 协议、统一系统错误。
// [POS]: 控制器与 TIS / CoreAudio 的边界，支持不触碰硬件的测试替身。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import VorsmateCore

@MainActor
public protocol SourceDriver: AnyObject {
    func read() throws -> Snapshot
    func select(_ id: String) throws
    func start(onChange: @escaping @MainActor () -> Void) throws
    func stop()
}

public enum SystemFailure: LocalizedError {
    case status(String, Int32)
    case unavailable
    case inconsistentSnapshot
    public var errorDescription: String? {
        switch self {
        case .status(let action, let code): "\(action)失败（\(code)）"
        case .unavailable: "此项目已不可用，请重新选择。"
        case .inconsistentSnapshot: "音频设备正在变化，稍后会重新读取。"
        }
    }
}
