// [INPUT]: 16 kHz PCM 与已安装的 MiRemoteV 2ch 回环端点。
// [OUTPUT]: 只向指定 UID 播放，末包排空；不改变系统默认输出。
import AudioToolbox
import CoreAudio
import Foundation
import VorsmateCore

@MainActor
final class RemoteAudioOutput {
    private var generation = 0
    private var queue: AudioQueueRef?
    private var free: [AudioQueueBufferRef] = []
    private var running = false
    private var draining = false
    private var stopTask: Task<Void, Never>?
    private var waitingForStop: [[Int16]] = []
    private static let capacity: UInt32 = 4096
    private static let count = 32
    var onFailure: (Error) -> Void = { _ in }

    func prepare() throws {
        if queue != nil { return }
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var created: AudioQueueRef?
        let generation = self.generation
        let status = AudioQueueNewOutputWithDispatchQueue(&created, &format, 0, .main) { [weak self] output, buffer in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, self.queue == output else { return }
                self.free.append(buffer)
                self.stopIfDrained()
            }
        }
        guard status == noErr, let created else { throw RemoteError.message("无法创建遥控器音频通道") }
        queue = created
        do {
            let uid = RemoteVoice.deviceUID as CFString
            var target = Unmanaged.passUnretained(uid)
            let size = UInt32(MemoryLayout.size(ofValue: target))
            guard AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice, &target, size) == noErr,
                isBound
            else { throw RemoteError.message("需要 MiRemoteV 2ch 虚拟音频设备") }
            for _ in 0..<Self.count {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(created, Self.capacity, &buffer) == noErr, let buffer else {
                    throw RemoteError.message("无法分配遥控器音频缓冲")
                }
                free.append(buffer)
            }
        } catch {
            close()
            throw error
        }
    }

    var isBound: Bool {
        guard let queue else { return false }
        var current: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: current))
        guard AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, &current, &size) == noErr, let current
        else { return false }
        let uid = current.takeRetainedValue()
        guard uid as String == RemoteVoice.deviceUID else { return false }
        var qualifier = Unmanaged.passUnretained(uid)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout.size(ofValue: device))
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &property,
            UInt32(MemoryLayout.size(ofValue: qualifier)), &qualifier, &deviceSize, &device)
        return status == noErr && device != kAudioObjectUnknown
    }

    func write(_ pcm: [Int16]) throws {
        guard !pcm.isEmpty, pcm.count <= Int(Self.capacity / 2) else {
            throw RemoteError.message("遥控器音频缓冲不可用")
        }
        draining = false
        if stopTask != nil {
            guard waitingForStop.count < Self.count else { throw RemoteError.message("虚拟麦克风未能及时停止") }
            waitingForStop.append(pcm)
            return
        }
        try enqueue(pcm)
    }

    private func enqueue(_ pcm: [Int16]) throws {
        guard let queue, let buffer = free.last else { throw RemoteError.message("遥控器音频缓冲不可用") }
        if !running && !isBound { throw RemoteError.message("虚拟麦克风已断开") }
        let bytes = pcm.count * 2
        pcm.withUnsafeBytes { buffer.pointee.mAudioData.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        buffer.pointee.mAudioDataByteSize = UInt32(bytes)
        guard AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr else { throw RemoteError.message("虚拟麦克风写入失败") }
        free.removeLast()
        if !running {
            guard AudioQueueStart(queue, nil) == noErr else { throw RemoteError.message("虚拟麦克风启动失败") }
            running = true
        }
    }
    func end() {
        draining = true
        stopIfDrained()
    }

    private func stopIfDrained() {
        guard draining, running, free.count == Self.count, stopTask == nil else { return }
        stopTask = Task { [weak self] in await self?.waitUntilStopped() }
    }

    private func waitUntilStopped() async {
        guard !Task.isCancelled, let queue else { return }
        do {
            guard AudioQueueStop(queue, false) == noErr else { throw RemoteError.message("虚拟麦克风关闭失败") }
            let deadline = ContinuousClock.now + .seconds(1)
            while try queueIsRunning(queue) {
                guard ContinuousClock.now < deadline else { throw RemoteError.message("虚拟麦克风未能及时停止") }
                try await Task.sleep(for: .milliseconds(10))
            }
            running = false
            stopTask = nil
            let buffered = waitingForStop
            waitingForStop.removeAll(keepingCapacity: true)
            for pcm in buffered { try enqueue(pcm) }
            stopIfDrained()
        } catch is CancellationError {
            return
        } catch {
            close()
            onFailure(error)
        }
    }

    private func queueIsRunning(_ queue: AudioQueueRef) throws -> Bool {
        var active: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: active))
        guard AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &active, &size) == noErr else {
            throw RemoteError.message("无法读取虚拟麦克风状态")
        }
        return active != 0
    }

    func close() {
        stopTask?.cancel()
        stopTask = nil
        waitingForStop.removeAll()
        generation &+= 1
        let old = queue
        queue = nil
        if let old { AudioQueueDispose(old, true) }
        free = []
        running = false
        draining = false
    }
}
