import Testing
import VorsmateCore

@Test("每次中心键释放只切换一次，其他键、重复、错误与语音报告不触发")
func remoteConfirmEdges() {
    var key = RemoteConfirm()
    func released(reportID: UInt32, bytes: [UInt8]) -> Bool { key.released(reportID: reportID, bytes: bytes) }
    for prefix in [[], [UInt8(1)]] {
        for _ in 0..<2 {
            for _ in 0..<4 {
                #expect(!released(reportID: 1, bytes: prefix + [0x50, 0, 0x28, 0, 0, 0]))
            }
            #expect(!released(reportID: 1, bytes: prefix + [1, 0, 0, 0, 0, 0]))
            #expect(!released(reportID: 6, bytes: [0, 0, 0, 0, 0, 0]))
            #expect(!released(reportID: 1, bytes: [0, 0]))
            #expect(released(reportID: 1, bytes: prefix + [0x50, 0, 0, 0, 0, 0]))
            #expect(!released(reportID: 1, bytes: prefix + [0, 0, 0, 0, 0, 0]))
        }
    }
}
