// [INPUT]: 单调时钟时间，由控制器在真实写入前提供。
// [OUTPUT]: 有界重试与竞争暂停判断。
// [POS]: 防止与其他管理软件反复争抢同一个系统设置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public struct SwitchBudget: Sendable {
    public enum Permission: Equatable { case allow, wait, suspend }
    private var attempts: [TimeInterval] = []
    public init() {}
    public mutating func request(at time: TimeInterval) -> Permission {
        attempts.removeAll { time - $0 >= 6 }
        if let last = attempts.last, time - last < 0.8 { return .wait }
        guard attempts.count < 4 else { return .suspend }
        attempts.append(time)
        return .allow
    }
}
