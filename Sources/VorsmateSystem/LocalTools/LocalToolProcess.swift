// [INPUT]: 已知本机可执行文件及逐项传入的参数。
// [OUTPUT]: 离开主线程读取本机进程的退出状态和回执，各调用者自行解释。
// [POS]: 收藏封面和网盘的执行适配器，不经过 shell，也不记录命令输出。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

struct LocalToolResult: Sendable {
    let status: Int32
    let output: String
}

enum LocalToolProcess {
    typealias Run = @Sendable (URL, [String]) async throws -> LocalToolResult

    static func run(_ executable: URL, _ arguments: [String]) async throws -> LocalToolResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        let output = Pipe()
                        process.executableURL = executable
                        process.arguments = arguments
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = output
                        process.standardError = output
                        try process.run()
                        let captured = Result { try output.fileHandleForReading.readToEnd() ?? Data() }
                        process.waitUntilExit()
                        return LocalToolResult(
                            status: process.terminationStatus,
                            output: String(decoding: try captured.get(), as: UTF8.self))
                    })
            }
        }
    }
}
