// [INPUT]: RC003 键盘输入报告，报告 1 的三个小端 16 位键值。
// [OUTPUT]: 完整按下和松开仅产生一次确定动作。
// [POS]: 只处理遥控器中心键；采集与系统动作由独立插件负责。
public struct RemoteConfirm: Sendable {
    private var held = false
    public init() {}

    public mutating func released(reportID: UInt32, bytes: [UInt8]) -> Bool {
        guard reportID == 1 else { return false }
        let offset: Int
        switch bytes.count {
        case 6: offset = 0
        case 7 where bytes[0] == 1: offset = 1
        default: return false
        }
        var down = false
        for i in stride(from: offset, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            // USB HID rollover / POSTFail / ErrorUndefined are not a key release.
            if (1...3).contains(usage) { return false }
            if usage == 0x28 { down = true }
        }
        defer { held = down }
        return held && !down
    }
}
