// [INPUT]: DJI Mini 系列厂商状态字节流与外部单调时钟。
// [OUTPUT]: 经校验的无线连接掩码、连接确认与状态过期判断。
// [POS]: 无硬件的协议 / 就绪规则；不以静音、音量或说话停顿判断连接。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum SourceAvailability: String, Codable, Sendable {
    case ready, checking, waitingForTransmitter, unknown

    public var label: String? {
        switch self {
        case .ready: nil
        case .checking: "确认连接中"
        case .waitingForTransmitter: "等待发射器"
        case .unknown: "连接状态未知"
        }
    }
}

public struct ReceiverStatusDecoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}

    // 按公开协议独立实现，只解释连接字段：
    // https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md
    public mutating func append(_ bytes: [UInt8]) -> [UInt8] {
        buffer.append(contentsOf: bytes)
        var masks: [UInt8] = []
        while buffer.count >= 4 {
            let length = Int(buffer[1])
            guard buffer[0] == 0x55, buffer[2] == 0x04, length >= 14,
                Self.crc8(buffer.prefix(3)) == buffer[3]
            else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            let frame = Array(buffer.prefix(length))
            let v2 = Self.crc16(frame, seed: 0x3692) == 0
            let v1 = !v2 && Self.crc16(frame, seed: 0) == 0xbb01
            guard v1 || v2 else {
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(length)
            guard frame[4] == 0x5a, frame[5] == 0x02,
                frame[8] == 0, frame[9] == 0x5b, frame[10] == 3
            else { continue }
            if v2, frame[11] == 3, Self.isV2Status(frame) {
                // 掩码可能比 TX 槽早一个包出现；不读取音量、静音或电池字段。
                masks.append(frame[44] & 3)
            } else if v1, frame[11] == 0, let mask = Self.v1Mask(frame) {
                masks.append(mask)
            }
        }
        // 总长度是单字节；未完成帧至多保留 254 字节。
        return masks
    }

    private static func isV2Status(_ frame: [UInt8]) -> Bool {
        guard [54, 86, 118].contains(frame.count), frame[12] == frame.count - 16, frame[13] == 0,
            Array(frame[14..<20]) == [3, 0, 0, 0, 0, 32]
        else { return false }
        // 长度字段也会出现在身份 / 音量推送中，必须再验证 RX / TX 记录头。
        var units = Set<UInt8>()
        for offset in stride(from: 52, to: frame.count - 2, by: 32) {
            guard frame[offset] == 2, [1, 2].contains(frame[offset + 1]),
                units.insert(frame[offset + 1]).inserted,
                Array(frame[(offset + 2)..<(offset + 6)]) == [0, 0, 0, 26]
            else { return false }
        }
        return true
    }

    private static func v1Mask(_ frame: [UInt8]) -> UInt8? {
        guard [56, 70, 84].contains(frame.count) else { return nil }
        var offset = 14
        var mask: UInt8 = 0
        for index in 0..<2 {
            guard offset + 2 <= frame.count - 24 else { return nil }
            switch frame[offset + 1] & 0x60 {
            case 0x20:
                mask |= 1 << index
                offset += 23
            case 0x40: offset += 9
            default: return nil
            }
        }
        return offset + 24 == frame.count ? mask : nil
    }

    private static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        // 协议的 0xEE 初值按位反转后为 0x77；使用反射多项式 0x8C。
        var crc: UInt8 = 0x77
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x8c : 0) }
        }
        return crc
    }

    private static func crc16(_ bytes: [UInt8], seed: UInt16) -> UInt16 {
        var crc = seed
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x8408 : 0) }
        }
        return crc
    }
}

public struct ReceiverReadiness: Sendable {
    private var confirmed: SourceAvailability = .checking
    private var candidate: Bool?
    private var candidateSince: TimeInterval = 0
    private var lastStatus: TimeInterval?
    public init() {}

    public mutating func receive(mask: UInt8, at time: TimeInterval) {
        if let lastStatus, time < lastStatus || time - lastStatus > 3 {
            self = Self()
        }
        lastStatus = time
        let connected = mask & 3 != 0
        if candidate != connected {
            candidate = connected
            candidateSince = time
        } else if time - candidateSince >= (connected ? 0.3 : 0.8) {
            // 至少两个新鲜状态包确认；短暂射频抖动不立即回退。
            confirmed = connected ? .ready : .waitingForTransmitter
        }
    }

    public func availability(at time: TimeInterval) -> SourceAvailability {
        guard let lastStatus, time >= lastStatus, time - lastStatus <= 3 else { return .unknown }
        return confirmed
    }
}
