// [INPUT]: CSMC / PMU 只读桥、VorsmateCore 风扇数据类型与本机型号。
// [OUTPUT]: 核心热点与独立增强参考温度、转速、受限模式写入及有界回读。
// [POS]: 所有 SMC 访问在主线程串行；写入仅在独立 root 助手中使用。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CSMC
import Foundation
import VorsmateCore

@MainActor
public protocol FanHardware: AnyObject {
    func read() throws -> FanSnapshot
    func setRPM(_ rpm: Double, fanID: Int) throws
    func restore(fanID: Int) throws
}

@MainActor
public final class SMCFanDriver: FanHardware {
    private var metadata: [String: (UInt32, UInt32)] = [:]
    private var sensors: [String]?
    private let referenceReader: OpaquePointer?
    public init() {
        // 仅对已经实测的机型启用这套 PMU 曲线；其他机型继续自动 / 只读。
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [UInt8](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = result == 0 ? String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) : ""
        referenceReader = model == "Mac16,10" ? pmu_create() : nil
    }
    isolated deinit { pmu_destroy(referenceReader) }
    private func info(_ name: String) throws -> (UInt32, UInt32) {
        guard smc_open() == 0 else { throw FanFailure.unavailable }
        if let cached = metadata[name] { return cached }
        var size: UInt32 = 0
        var type: UInt32 = 0
        guard smc_key_info(smc_key(name), &size, &type) == 0, (1...32).contains(size) else {
            throw FanFailure.hardware(name)
        }
        metadata[name] = (size, type)
        return (size, type)
    }
    private func readNumber(_ name: String) throws -> Double {
        let (size, type) = try info(name)
        var value = 0.0
        guard smc_read_num(smc_key(name), size, type, &value) == 0, value.isFinite else {
            throw FanFailure.hardware(name)
        }
        return value
    }
    private func writeNumber(_ name: String, _ value: Double) throws {
        guard geteuid() == 0 else { throw FanFailure.notAuthorized }
        let (size, type) = try info(name)
        guard smc_write_num(smc_key(name), size, type, value) == 0 else {
            throw FanFailure.hardware("\(name) / \(smc_last_result())")
        }
    }
    private func modeKey(_ id: Int) throws -> String {
        for name in ["F\(id)Md", "F\(id)md"] { if (try? info(name)) != nil { return name } }
        throw FanFailure.unavailable
    }
    private func temperatureSensors() -> [String] {
        if let sensors { return sensors }
        var found: [String] = []
        if let number = try? readNumber("#KEY"), number > 0, number <= 10_000 {
            for index in 0..<UInt32(number) {
                var key: UInt32 = 0
                guard smc_key_at_index(index, &key) == 0 else { continue }
                var chars = [CChar](repeating: 0, count: 5)
                smc_key_str(key, &chars)
                let name = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if ["Tp", "Te", "Tg", "TC", "TG"].contains(where: { name.hasPrefix($0) }),
                    let value = try? readNumber(name), value > 0, value < 130
                {
                    found.append(name)
                }
            }
        }
        sensors = found
        return found
    }
    public func read() throws -> FanSnapshot {
        let count = try readNumber("FNum")
        guard count >= 0, count <= 8 else { throw FanFailure.unavailable }
        var fans: [FanReading] = []
        for id in 0..<Int(count) {
            fans.append(
                FanReading(
                    id: id, actualRPM: try readNumber("F\(id)Ac"),
                    targetRPM: try readNumber("F\(id)Tg"), minimumRPM: try readNumber("F\(id)Mn"),
                    maximumRPM: try readNumber("F\(id)Mx"), hardwareMode: Int(try readNumber(modeKey(id)))))
        }
        let temperatures = temperatureSensors().compactMap { try? readNumber($0) }.filter { $0 > 0 && $0 < 130 }
        var reference = 0.0
        let controlTemperature = pmu_read(referenceReader, &reference) == 0 ? reference : nil
        return FanSnapshot(fans: fans, temperature: temperatures.max(), controlTemperature: controlTemperature)
    }
    private func confirm(_ name: String, value: Double, tolerance: Double = 0.1) throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let actual = try? readNumber(name), abs(actual - value) <= tolerance { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw FanFailure.timeout
    }
    public func setRPM(_ rpm: Double, fanID: Int) throws {
        guard (0..<8).contains(fanID), rpm.isFinite else { throw FanFailure.invalidRange }
        let minRPM = try readNumber("F\(fanID)Mn")
        let maxRPM = try readNumber("F\(fanID)Mx")
        guard rpm >= max(500, minRPM), rpm <= maxRPM else { throw FanFailure.invalidRange }
        let key = try modeKey(fanID)
        // 只采用已验证回读的直接模式。拒绝时返回错误，不自动进入全局诊断解锁。
        if try readNumber(key) != 1 {
            try writeNumber(key, 1)
            try confirm(key, value: 1)
        }
        try writeNumber("F\(fanID)Tg", rpm)
        try confirm("F\(fanID)Tg", value: rpm, tolerance: 100)
    }
    public func restore(fanID: Int) throws {
        guard (0..<8).contains(fanID) else { throw FanFailure.unavailable }
        let key = try modeKey(fanID)
        if try readNumber(key) == 1 { try writeNumber(key, 0) }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let mode = try? readNumber(key), mode == 0 || mode == 3 { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw FanFailure.timeout
    }
}
