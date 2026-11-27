// [INPUT]: 有界等待的异步来源替身。
// [OUTPUT]: 切城市、关闭面板与单一来源失败时的读数隔离回归。
// [POS]: 天气和行情视图的读取生命周期测试。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing

@testable import Vorsmate

@MainActor
@Suite("面板信息读数生命周期")
struct PanelFeedTests {
    @Test("清空或取消期间返回的旧结果不能改写当前城市")
    func obsoleteResult() async {
        for cancel in [false, true] {
            let feed = PanelFeed<Int>(interval: .seconds(3600))
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let (entered, notify) = AsyncStream<Void>.makeStream()
            let task = Task {
                await feed.watch {
                    notify.yield()
                    for await _ in stream { break }
                    return 42
                }
            }
            for await _ in entered { break }
            if cancel { task.cancel() } else { feed.clear() }
            continuation.finish()
            await task.value
            #expect(feed.value == nil && !feed.failed)
        }
    }

    @Test("刷新失败仍保留上次成功的读数")
    func retainsLastValue() async {
        let feed = PanelFeed<Int>(interval: .milliseconds(1))
        actor Source {
            var count = 0
            func read() throws -> Int {
                count += 1
                if count == 1 { return 42 }
                throw URLError(.notConnectedToInternet)
            }
        }
        let source = Source()
        let task = Task { await feed.watch { try await source.read() } }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !feed.failed && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(feed.failed)
        #expect(feed.value == 42)
    }
}
