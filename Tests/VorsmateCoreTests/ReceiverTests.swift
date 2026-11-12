// [INPUT]: 无个人标识的状态帧、可控时间与接收器 / 备用设备快照。
// [OUTPUT]: 连接解析、去抖、过期、优先级、锁定回退与设备身份匹配回归。
// [POS]: 不打开硬件、不录音的无线麦就绪测试；实机验证另外记录。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing
import VorsmateCore

@testable import VorsmateSystem

@Suite("无线麦就绪")
struct ReceiverTests {
    // v2 状态帧只含状态 / 标志，不含身份帧、序列号或音频数据。
    private let off = Self.bytes(
        "5536043d5a020000005b03032600030000000020200106000000000000000000000000000000000000000000000000003e000000073e")
    private let on = Self.bytes(
        "555604675a020000005b03034600030000000020200106000000000000000000000000000000000000000000020000003e00000002020000001a182504210078000000000000000000000000000000000000000054ce"
    )

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    private func checksum(_ bytes: [UInt8]) -> [UInt8] {
        var frame = Array(bytes.dropLast(2))
        var crc: UInt16 = 0x3692
        for byte in frame {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x8408 : 0) }
        }
        frame += [UInt8(crc & 255), UInt8(crc >> 8)]
        return frame
    }

    @Test("实机格式的有校验状态帧正确区分零发射器与 TX2")
    func capturedStatus() {
        var decoder = ReceiverStatusDecoder()
        #expect(decoder.append(off + on + off) == [0, 2, 0])
    }

    @Test("跨包拆分、合包与噪声后重新同步，不接受损坏的连接位")
    func framing() {
        var decoder = ReceiverStatusDecoder()
        var corrupted = on
        corrupted[44] = 0
        #expect(decoder.append([0, 1, 85, 255, 4, 0] + Array(off.prefix(12))).isEmpty)
        #expect(decoder.append(Array(off.dropFirst(12)) + corrupted + on) == [0, 2])
        var badHeader = on
        badHeader[3] ^= 1
        #expect(decoder.append(badHeader + off) == [0])
    }

    @Test("同长度的其他推送不能当成连接状态，连接掩码可先于 TX 槽到达")
    func frameShape() {
        var decoder = ReceiverStatusDecoder()
        var identity = on
        identity[14] = 1
        identity[19] = 64
        #expect(decoder.append(checksum(identity)).isEmpty)
        var early = off
        early[44] = 1
        #expect(decoder.append(checksum(early)) == [1])
        early[44] = 3
        #expect(decoder.append(checksum(early)) == [3])
    }

    @Test("旧版协议按可变长 TX 槽读取，覆盖零只、任意一只及两只")
    func legacyProtocol() {
        let frames = [
            "553804e15a020000005b03000000004000000000000000004000000000000000000000000000000000000000000000000000000000008f72",
            "5546048b5a020000005b03000000002000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000b8fb",
            "5546048b5a020000005b0300000000400000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000008d8",
            "555404f65a020000005b0300000000200000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000008c6c",
        ]
        var decoder = ReceiverStatusDecoder()
        for (index, frame) in frames.enumerated() {
            #expect(decoder.append(Self.bytes(frame)) == [UInt8(index)])
        }
    }

    @Test("静音及音量等无关标志不改变连接判断")
    func silenceIsNotDisconnection() {
        var decoder = ReceiverStatusDecoder()
        var state = ReceiverReadiness()
        for index in 0..<20 {
            var frame = on
            for offset in [20, 21, 22, 48, 58, 59, 60, 61, 62] {
                frame[offset] = index.isMultiple(of: 2) ? 0 : 255
            }
            let masks = decoder.append(checksum(frame))
            #expect(masks == [2])
            for mask in masks { state.receive(mask: mask, at: Double(index)) }
            if index > 0 { #expect(state.availability(at: Double(index)) == .ready) }
        }
    }

    @Test("连接需新鲜状态确认，短暂断连不过早回退，持续断开才回退")
    func debounce() {
        var state = ReceiverReadiness()
        #expect(state.availability(at: 0) == .unknown)
        state.receive(mask: 2, at: 0)
        #expect(state.availability(at: 0.4) == .checking)
        state.receive(mask: 2, at: 0.4)
        #expect(state.availability(at: 0.4) == .ready)
        state.receive(mask: 0, at: 1)
        state.receive(mask: 0, at: 1.4)
        #expect(state.availability(at: 1.4) == .ready)
        state.receive(mask: 2, at: 1.5)
        #expect(state.availability(at: 1.5) == .ready)
        state.receive(mask: 0, at: 2)
        state.receive(mask: 0, at: 3)
        #expect(state.availability(at: 3) == .waitingForTransmitter)
        state.receive(mask: 1, at: 3.2)
        state.receive(mask: 1, at: 3.6)
        #expect(state.availability(at: 3.6) == .ready)
    }

    @Test("状态过期或时钟回退不能沿用历史已连接结果")
    func expiry() {
        var state = ReceiverReadiness()
        state.receive(mask: 2, at: 10)
        state.receive(mask: 2, at: 11)
        #expect(state.availability(at: 14.1) == .unknown)
        state.receive(mask: 2, at: 15)
        #expect(state.availability(at: 15) == .checking)
        state.receive(mask: 2, at: 16)
        #expect(state.availability(at: 16) == .ready)
        state.receive(mask: 2, at: 1)
        #expect(state.availability(at: 1) == .checking)
    }

    @Test("自动与锁定均跳过未就绪接收器，重连恢复且排序不丢失", arguments: [false, true])
    func eligibility(locked: Bool) throws {
        let receiver = Source(id: "rx", name: "无线麦")
        let backup = Source(id: "backup", name: "备用麦")
        let policy = SelectionPolicy(enabled: true, priority: [receiver, backup], lockedID: locked ? "rx" : nil)
        let before = try JSONEncoder().encode(policy)
        var snapshot = Snapshot(sources: [receiver, backup], selectedID: "rx")
        for status in [SourceAvailability.unknown, .checking, .waitingForTransmitter] {
            snapshot.availability["rx"] = status
            #expect(policy.target(in: snapshot) == "backup")
            #expect(policy.isWaiting(in: snapshot) == locked)
            #expect(snapshot.selectedID == "rx")
            #expect(snapshot.sources.count == 2)
        }
        snapshot.availability["rx"] = .ready
        #expect(policy.target(in: snapshot) == "rx")
        #expect(!policy.isWaiting(in: snapshot))
        #expect(try JSONDecoder().decode(SelectionPolicy.self, from: before) == policy)
        snapshot.availability["rx"] = .waitingForTransmitter
        snapshot.sources = [receiver]
        #expect(policy.target(in: snapshot) == nil)
    }

    @Test("按音频 UID 与 USB 序列号匹配，其他麦克风不受限制")
    func identity() {
        let prefix = "AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:"
        let states: [String: SourceAvailability] = ["TEST-A": .ready, "TEST-B": .waitingForTransmitter]
        #expect(ReceiverMonitor.availability(for: prefix + "TEST-A:3", states: states) == .ready)
        #expect(ReceiverMonitor.availability(for: prefix + "TEST-B:3", states: states) == .waitingForTransmitter)
        #expect(ReceiverMonitor.availability(for: prefix + "TEST-C:3", states: states) == .unknown)
        #expect(ReceiverMonitor.availability(for: "other-manufacturer:Wireless Mic Rx:TEST-A:3", states: states) == nil)
    }
}
