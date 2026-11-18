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
    private static let capacity: UInt32 = 4096
    private static let count = 32

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
                if self.draining && self.free.count == Self.count { self.finish() }
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
        guard let queue, !pcm.isEmpty, pcm.count <= Int(Self.capacity / 2), let buffer = free.popLast() else {
            throw RemoteError.message("遥控器音频缓冲不可用")
        }
        if !running && !isBound { throw RemoteError.message("虚拟麦克风已断开") }
        draining = false
        let bytes = pcm.count * 2
        pcm.withUnsafeBytes { buffer.pointee.mAudioData.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        buffer.pointee.mAudioDataByteSize = UInt32(bytes)
        guard AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr else { throw RemoteError.message("虚拟麦克风写入失败") }
        if !running {
            guard AudioQueueStart(queue, nil) == noErr else { throw RemoteError.message("虚拟麦克风启动失败") }
            running = true
        }
    }
    func end() {
        draining = true
        if free.count == Self.count { finish() }
    }
    private func finish() {
        if running, let queue { AudioQueueStop(queue, false) }
        draining = false
        running = false
    }
    func close() {
        generation &+= 1
        let old = queue
        queue = nil
        if let old { AudioQueueDispose(old, true) }
        free = []
        running = false
        draining = false
    }
}
