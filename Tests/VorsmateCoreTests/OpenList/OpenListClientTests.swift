// [INPUT]: 临时本机连接器、合成状态和安全关闭回执。
// [OUTPUT]: 命令参数、挂载状态、在途关闭保护的回执与回环地址校验。
// [POS]: 不访问真实网盘与磁盘挂载的网盘适配器测试。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing

@testable import VorsmateSystem

@Suite("本机网盘适配器")
struct OpenListClientTests {
    @Test("只以固定参数调用本机连接器并解析状态")
    func dispatchAndStatus() async throws {
        let runner = try Self.stubRunner()
        defer { try? FileManager.default.removeItem(at: runner.deletingLastPathComponent()) }
        let client = OpenListClient(runner: runner) { executable, arguments in
            #expect(executable.path == "/usr/bin/python3")
            #expect(Array(arguments.dropLast()) == ["-B", runner.path])
            switch arguments.last {
            case "status":
                return LocalToolResult(status: 0, output: "测试盘 A：已开启\n测试盘 B：已关闭\n专用连接：已加载\n")
            case "start", "stop":
                return LocalToolResult(status: 0, output: "")
            case "gui":
                return LocalToolResult(status: 0, output: "http://127.0.0.1:5580/login\n")
            default: throw OpenListError.invalidResponse
            }
        }
        #expect(try await client.status() == OpenListStatus(mounted: 1, total: 2, connectionLoaded: true))
        try await client.start()
        try await client.stop()
        #expect(try await client.webInterface().absoluteString == "http://127.0.0.1:5580/login")
    }

    @Test("正在上传的拒绝回执保留，且不会重试或绕过")
    func preservesRefusedStop() async throws {
        let runner = try Self.stubRunner()
        defer { try? FileManager.default.removeItem(at: runner.deletingLastPathComponent()) }
        let message = "测试盘有待上传修改，请等上传完成后再关闭。"
        let calls = Commands()
        let client = OpenListClient(runner: runner) { _, arguments in
            await calls.record(arguments.last)
            return LocalToolResult(status: 1, output: message)
        }
        await #expect(throws: OpenListError.operationRejected(message)) { try await client.stop() }
        #expect(await calls.values == ["stop"])
    }

    @Test(
        "网页入口只接受本机登录地址",
        arguments: [
            "https://example.invalid/login", "http://127.0.0.1.example.invalid:5580/login",
            "http://127.0.0.1:5580/unexpected", "http://example.invalid@127.0.0.1:5580/login",
        ])
    func rejectsUnexpectedWebURL(_ address: String) async throws {
        let runner = try Self.stubRunner()
        defer { try? FileManager.default.removeItem(at: runner.deletingLastPathComponent()) }
        let client = OpenListClient(runner: runner) { _, _ in LocalToolResult(status: 0, output: address) }
        await #expect(throws: OpenListError.invalidResponse) { try await client.webInterface() }
    }

    @Test("连接器缺失时不执行任何本机命令")
    func missingConnector() async {
        let absent = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let client = OpenListClient(runner: absent) { _, _ in
            Issue.record("Unexpected local command")
            return LocalToolResult(status: 0, output: "")
        }
        await #expect(throws: OpenListError.missingConnector) { try await client.status() }
    }

    @Test("进程输出超过管道容量仍能读取完整")
    func readsLargeCommandOutput() async throws {
        let result = try await LocalToolProcess.run(
            URL(fileURLWithPath: "/usr/bin/head"), ["-c", "131072", "/dev/zero"])
        #expect(result.status == 0)
        #expect(result.output.utf8.count == 131_072)
    }

    private actor Commands {
        private(set) var values: [String] = []
        func record(_ value: String?) { if let value { values.append(value) } }
    }

    private static func stubRunner() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appending(path: "runner.py")
        try Data().write(to: file)
        return file
    }
}
