import Foundation
import Testing
import VorsmateCore

@testable import VorsmateSystem

@Test("有硬件标识时只连接同一只遥控器；缺少标识才按已知名称查找")
func remoteVoiceIdentity() {
    let selected = UUID()
    #expect(RemoteVoice.matchesPeripheral(selected, name: nil, identity: selected))
    #expect(!RemoteVoice.matchesPeripheral(UUID(), name: "Mi RC", identity: selected))
    #expect(RemoteVoice.matchesPeripheral(selected, name: " MI RC ", identity: nil))
    #expect(!RemoteVoice.matchesPeripheral(selected, name: nil, identity: nil))
}

@Test("能力协商要求 16 kHz，兼容旧固件的编解码字段布局")
func remoteVoiceCapabilities() {
    #expect(RemoteVoice.version16k([11, 1, 0, 2, 3, 0, 120]) == 0x100)
    #expect(RemoteVoice.version16k([11, 1, 0, 0, 3, 0, 120, 0, 0]) == 0x100)
    #expect(RemoteVoice.version16k([11, 0, 4, 0, 2, 0, 120]) == 4)
    #expect(RemoteVoice.version16k([11, 1, 0, 1, 3, 0, 120]) == nil)
    #expect(RemoteVoice.version16k([11, 1]) == nil)
}
@Test("ADPCM 高位在先，跨包延续，处理同步点与饱和")
func remoteVoicePCM() {
    var decoder = RemoteVoiceDecoder()
    #expect(decoder.decode(Data([0x17])) == [1, 12])
    #expect(decoder.decode(Data([0xf0])) == [-18, -14])
    var high = RemoteVoiceDecoder(predictor: 32_766, index: 200)
    #expect(high.decode(Data([0x77])) == [32767, 32767])
}
@Test("遥控器就绪驱动原输入顺序和锁定回退，停用后归还外部输入")
@MainActor func remoteVoiceSelection() {
    let remote = Source(id: RemoteVoice.deviceUID, name: "MiRemoteV 2ch")
    let builtIn = Source(id: "local", name: "内置")
    let policy = SelectionPolicy(enabled: true, priority: [remote, builtIn], lockedID: remote.id)
    var snapshot = Snapshot(sources: [builtIn, remote], selectedID: builtIn.id)
    for ready: Bool? in [false, true, false, nil] {
        AudioDeviceDriver.applyInputAvailability(to: &snapshot, receivers: [:], remoteReady: ready)
        #expect(policy.target(in: snapshot) == (ready == false ? builtIn.id : remote.id))
        #expect(snapshot.availability[builtIn.id] == nil)
    }
    #expect(policy.priority == [remote, builtIn])
    #expect(policy.lockedID == remote.id)
}
@Test("左右组合不折叠，通用旧配置保留显示，专用单修饰键走设备映射")
func remoteSidedShortcuts() {
    #expect(RemoteModifier.display(code: 9, flags: 0xc0000, label: "V") == "⌃⌥V")
    #expect(RemoteModifier.display(code: 9, flags: 0xc2041, label: "V") == "左⌃右⌃右⌥V")
    #expect(RemoteModifier.display(code: 54, flags: 0, label: nil) == "右⌘")
    var profile = RemoteProfile()
    let source = UInt64(7) << 32 | UInt64(RemoteButton.ok.usage)
    for key in RemoteModifier.all {
        var binding = RemoteBinding()
        binding.single = RemoteAction(.shortcut)
        binding.single.keyCode = key.code
        profile.buttons["ok"] = binding
        #expect(profile.deviceMap[source] == UInt64(7) << 32 | key.hidUsage)
        binding.long = RemoteAction(.volumeUp)
        profile.buttons["ok"] = binding
        #expect(profile.deviceMap[source] == 0)
    }
}

@Test("确定键只发一次 V，左右同族键各自释放")
func remoteModifierEdges() {
    let v = RemoteKeyEvent.sequence(code: 9, flags: 0xc0021)
    #expect(v.map(\.code) == [59, 58, 9, 9, 58, 59])
    #expect(v.map(\.down) == [true, true, true, false, false, false])
    #expect(v.last?.flags == 0)
    let both = RemoteKeyEvent.sequence(code: 62, flags: 0x40001)
    #expect(both.map(\.code) == [59, 62, 62, 59])
    #expect(both.allSatisfy { $0.modifier })
    #expect(both.map(\.flags) == [0x40001, 0x42001, 0x40001, 0])
}
