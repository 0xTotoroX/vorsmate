// [INPUT]: 音频设备枚举和默认 ID 的可控读取。
// [OUTPUT]: 插拔期间不一致快照的有界重读和拒写前置保护。
// [POS]: 不接触真实 CoreAudio 设备的竞态回归。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreAudio
import Testing
import VorsmateCore

@testable import VorsmateSystem

@Suite("音频快照")
@MainActor
struct AudioSnapshotTests {
    @Test("默认设备在枚举后回连，复核后保留正确选择")
    func reconnectDuringRead() throws {
        var reads = 0
        let snapshot = try AudioDeviceDriver.readSnapshot(
            devices: {
                reads += 1
                let fallback = (AudioDeviceID(2), Source(id: "b", name: "B"))
                return reads == 1 ? [fallback] : [fallback, (AudioDeviceID(1), Source(id: "a", name: "A"))]
            }, selectedDevice: { 1 })
        #expect(reads == 2)
        #expect(snapshot.selectedID == "a")
    }
    @Test("设备列表仍不一致时返回错误，不产生错误的回退快照")
    func rejectInconsistentRead() {
        var reads = 0
        #expect(throws: SystemFailure.self) {
            try AudioDeviceDriver.readSnapshot(
                devices: {
                    reads += 1
                    return [(2, Source(id: "b", name: "B"))]
                }, selectedDevice: { 1 })
        }
        #expect(reads == 2)
    }
}
