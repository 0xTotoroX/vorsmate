// [INPUT]: RC003 能力通知、同步点及高半字节优先的 IMA ADPCM 音频。
// [OUTPUT]: 16 kHz 单声道 PCM；输入排序沿用现有虚拟设备 UID。
import Foundation

package struct RemoteVoicePress {
    package private(set) var isDown = false
    private var openedForPress = false
    private var releasedSession = false

    package init() {}

    package var needsOpen: Bool { isDown && !openedForPress }

    @discardableResult
    package mutating func setDown(_ down: Bool, sessionActive: Bool) -> Bool {
        guard isDown != down else { return false }
        isDown = down
        if down {
            openedForPress = sessionActive && !releasedSession
        } else {
            releasedSession = sessionActive
        }
        return true
    }

    package mutating func didOpenSession() {
        if isDown { openedForPress = true }
    }

    package mutating func didEndSession() { releasedSession = false }
}

package struct RemoteVoiceDeadline {
    package enum Expiry: Equatable { case firstPacket, interrupted, maximumDuration }

    private let openedAt: TimeInterval
    private var lastPacketAt: TimeInterval?

    package init(openedAt: TimeInterval) {
        self.openedAt = openedAt
    }

    package mutating func receivedPacket(at now: TimeInterval) { lastPacketAt = now }

    package func expiry(at now: TimeInterval) -> Expiry? {
        guard let lastPacketAt else { return now - openedAt >= 3 ? .firstPacket : nil }
        if now - openedAt >= 75 { return .maximumDuration }
        return now - lastPacketAt >= 1 ? .interrupted : nil
    }
}

public enum RemoteVoice {
    public static let deviceUID = "MiRemoteV2ch_UID"

    package static func matchesPeripheral(_ id: UUID, name: String?, identity: UUID?) -> Bool {
        if let identity { return id == identity }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["mi rc", "xiaomi bluetooth remote 2 pro", "小米蓝牙语音遥控器"].contains { $0 == name }
    }

    public static func version16k(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 7, bytes[0] == 0x0b else { return nil }
        let version = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        let mask = version < 0x0100 || (bytes[3] == 0 && bytes.count >= 9) ? bytes[4] : bytes[3]
        return mask & 2 == 2 ? version : nil
    }
}

public struct RemoteVoiceDecoder {
    // Standard IMA ADPCM quantizer steps.
    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
    private var predictor: Int
    private var index: Int
    public init(predictor: Int16 = 0, index: UInt8 = 0) {
        self.predictor = Int(predictor)
        self.index = min(88, Int(index))
    }
    public mutating func decode(_ bytes: Data) -> [Int16] {
        var pcm = [Int16]()
        pcm.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            pcm.append(sample(Int(byte >> 4)))
            pcm.append(sample(Int(byte & 15)))
        }
        return pcm
    }
    private mutating func sample(_ nibble: Int) -> Int16 {
        let step = Self.steps[index]
        let magnitude = nibble & 7
        var delta = step >> 3
        if magnitude & 1 != 0 { delta += step >> 2 }
        if magnitude & 2 != 0 { delta += step >> 1 }
        if magnitude & 4 != 0 { delta += step }
        let next = Int16(clamping: predictor + (nibble & 8 == 0 ? delta : -delta))
        predictor = Int(next)
        index = min(88, max(0, index + (magnitude < 4 ? -1 : (magnitude - 3) * 2)))
        return next
    }
}
