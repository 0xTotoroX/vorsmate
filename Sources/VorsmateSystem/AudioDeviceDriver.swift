import CAudioListeners
// [INPUT]: CoreAudio HAL、CAudioListeners 原生监听句柄和稳定设备 UID。
// [OUTPUT]: 输入或输出设备枚举、默认设备切换与变化通知。
// [POS]: SourceDriver 的音频实现；不打开音频流，不录音。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreAudio
import Foundation
import VorsmateCore

@MainActor
public final class AudioDeviceDriver: SourceDriver {
    private let input: Bool
    private var listeners: [VMAudioListenerRef] = []
    private var generation = 0
    private var removalError: OSStatus = noErr
    private let system = AudioObjectID(kAudioObjectSystemObject)
    public init(input: Bool) { self.input = input }
    private var scope: AudioObjectPropertyScope {
        input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }
    private var defaultSelector: AudioObjectPropertySelector {
        input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
    private func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw SystemFailure.status(action, status) }
    }
    private func number(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "读取音频属性")
        return value
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "读取设备名称")
        guard let value else { throw SystemFailure.unavailable }
        return value.takeRetainedValue() as String
    }
    private func devices() throws -> [(AudioDeviceID, Source)] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "枚举音频设备")
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if size > 0 {
            let status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
            }
            try check(status, "枚举音频设备")
        }
        return ids.compactMap { id in
            // 插拔期间单台设备可能消失；跳过它，不丢弃其他在线设备。
            guard (try? number(id, kAudioDevicePropertyDeviceIsAlive)) == 1,
                (try? number(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope)) == 1,
                let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                let name = try? string(id, kAudioObjectPropertyName)
            else { return nil }
            return (id, Source(id: uid, name: name))
        }
    }
    public func read() throws -> Snapshot {
        try Self.readSnapshot(devices: devices, selectedDevice: { try number(system, defaultSelector) })
    }
    static func readSnapshot(
        devices: () throws -> [(AudioDeviceID, Source)],
        selectedDevice: () throws -> AudioDeviceID
    ) throws -> Snapshot {
        // 枚举和默认设备读取不是原子操作；重连期间先复核，不能把正确目标误判为离线。
        for _ in 0..<2 {
            let values = try devices()
            let selected = try selectedDevice()
            if selected == kAudioObjectUnknown || values.contains(where: { $0.0 == selected }) {
                return Snapshot(sources: values.map(\.1), selectedID: values.first { $0.0 == selected }?.1.id)
            }
        }
        throw SystemFailure.inconsistentSnapshot
    }
    public func select(_ id: String) throws {
        guard var device = try devices().first(where: { $0.1.id == id })?.0 else { throw SystemFailure.unavailable }
        var property = address(defaultSelector)
        try check(
            AudioObjectSetPropertyData(
                system, &property, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &device), "切换音频设备")
    }
    public func start(onChange: @escaping @MainActor () -> Void) throws {
        stop()
        try check(removalError, "停止旧的音频监听")
        do {
            let currentGeneration = generation
            for selector in [kAudioHardwarePropertyDevices, defaultSelector] {
                var property = address(selector)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self, self.generation == currentGeneration else { return }
                        onChange()
                    }
                }
                var status: OSStatus = noErr
                let handle = VMRegisterAudioListener(system, &property, .main, listener, &status)
                try check(status, "监听音频变化")
                if let handle { listeners.append(handle) }
            }
        } catch {
            stop()
            throw error
        }
    }
    public func stop() {
        generation &+= 1
        removalError = noErr
        listeners = listeners.filter { handle in
            let status = VMUnregisterAudioListener(handle)
            if status != noErr {
                removalError = status
                return true
            }
            return false
        }
    }
}
