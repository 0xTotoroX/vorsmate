// [INPUT]: CReceiverStatus 的只读会话、协议解码与单调时钟。
// [OUTPUT]: 按 USB 序列号匹配的即时可用状态；变化才通知主线程。
// [POS]: 麦克风驱动的后台状态读取，不使用音频、麦克风授权或外部依赖。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CReceiverStatus
import Foundation
import VorsmateCore

// 所有会话 / 计时器 / 解码器仅在 queue 使用；cancelled 单独用锁保护。
final class ReceiverMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.vorsmate.receiver", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var timer: DispatchSourceTimer?
    private var entries: [UInt64: Entry] = [:]
    private var lastScan: TimeInterval = -.infinity
    private var published: [String: SourceAvailability] = [:]
    private let changed: @Sendable ([String: SourceAvailability]) -> Void

    private struct Entry {
        var serial: String
        var handle: VMReceiverRef?
        var decoder = ReceiverStatusDecoder()
        var readiness = ReceiverReadiness()
        var retryAt: TimeInterval = 0
    }

    init(changed: @escaping @Sendable ([String: SourceAvailability]) -> Void) { self.changed = changed }

    func start() {
        queue.async { [self] in
            guard !isCancelled else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lock.withLock { cancelled = true }
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            for entry in entries.values { VMReceiverClose(entry.handle) }
            entries.removeAll()
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func scan(at time: TimeInterval) {
        var devices = [VMReceiverInfo](repeating: VMReceiverInfo(), count: 16)
        let count = VMReceiverList(&devices, devices.count)
        var present = Set<UInt64>()
        for var info in devices.prefix(count) {
            present.insert(info.registryID)
            if entries[info.registryID] == nil {
                let serial = withUnsafeBytes(of: &info.serial) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                entries[info.registryID] = Entry(serial: serial)
            }
        }
        for id in entries.keys.filter({ !present.contains($0) }) {
            VMReceiverClose(entries.removeValue(forKey: id)?.handle)
        }
        lastScan = time
    }

    private func poll() {
        guard !isCancelled else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if time - lastScan >= 1 { scan(at: time) }
        for id in Array(entries.keys) {
            guard !isCancelled, var entry = entries[id] else { break }
            if entry.handle == nil, time >= entry.retryAt {
                var status: Int32 = 0
                entry.handle = VMReceiverOpen(id, &status)
                entry.retryAt = time + 2
            }
            if let handle = entry.handle {
                // 一次定时唤醒排空已有推送，不能只读一个包让旧状态在 USB 队列堆积。
                let deadline = ProcessInfo.processInfo.systemUptime + 0.08
                for _ in 0..<32 {
                    guard !isCancelled else { break }
                    var bytes = [UInt8](repeating: 0, count: 512)
                    var size = UInt32(bytes.count)
                    let status = VMReceiverRead(handle, &bytes, &size)
                    if status != 0 {
                        VMReceiverClose(handle)
                        entry.handle = nil
                        entry.decoder = ReceiverStatusDecoder()
                        entry.readiness = ReceiverReadiness()
                        entry.retryAt = time + 2
                        break
                    }
                    let receivedAt = ProcessInfo.processInfo.systemUptime
                    for mask in entry.decoder.append(Array(bytes.prefix(Int(size)))) {
                        entry.readiness.receive(mask: mask, at: receivedAt)
                    }
                    if size == 0 || receivedAt >= deadline { break }
                }
            }
            entries[id] = entry
        }
        var states: [String: SourceAvailability] = [:]
        let now = ProcessInfo.processInfo.systemUptime
        for entry in entries.values where !entry.serial.isEmpty {
            // 同序列号多接收器无法确定音频端点归属，不能混用连接状态。
            states[entry.serial] = states[entry.serial] == nil ? entry.readiness.availability(at: now) : .unknown
        }
        if !isCancelled, states != published {
            published = states
            changed(states)
        }
    }

    static func availability(for sourceID: String, states: [String: SourceAvailability]) -> SourceAvailability? {
        let prefix = "AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:"
        guard sourceID.hasPrefix(prefix) else { return nil }
        let serial = sourceID.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false).first
        return serial.flatMap { states[String($0)] } ?? .unknown
    }
}
