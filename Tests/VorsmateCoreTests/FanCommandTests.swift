// [INPUT]: 固定枚举 XPC 命令与内存 JSON。
// [OUTPUT]: 关机 / 重启拒绝额外载荷和未知动作的协议回归。
// [POS]: 特权边界静态命令测试，绝不连接或启动助手。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore
import VorsmateFan

@Suite("助手固定命令")
struct FanCommandTests {
    @Test("关机和重启只允许无参数命令", arguments: [FanCommand.Action.shutdown, .restart])
    func fixed(action: FanCommand.Action) throws {
        let command = FanCommand(action: action)
        try command.validate()
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(FanCommand.self, from: data).action == action)
        #expect(throws: (any Error).self) { try FanCommand(action: action, fanID: 0).validate() }
        #expect(throws: (any Error).self) { try FanCommand(action: action, profile: FanProfile()).validate() }
    }
    @Test("未知系统动作不能解码")
    func unknown() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FanCommand.self, from: Data(#"{"action":"shell"}"#.utf8))
        }
    }
}
