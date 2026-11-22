import Foundation
import Testing
import VorsmateCore

private func configured() -> RemoteProfile {
    var p = RemoteProfile()
    var binding = RemoteBinding()
    binding.single = RemoteAction(.typeless)
    binding.double = RemoteAction(.previousTrack)
    binding.long = RemoteAction(.mute)
    for key in RemoteButton.allCases where key != .voice { p.buttons[key.rawValue] = binding }
    p.voiceFn = true
    return p
}

@Test("三个小端键槽和两种报告长度，语音数据、错误报告不构成松开")
func remoteReport() {
    for key in RemoteButton.allCases {
        let payload: [UInt8] = [0, 0, UInt8(key.usage), 0, 0, 0]
        #expect(RemoteButton.pressed(reportID: 1, bytes: payload) == [key])
        #expect(RemoteButton.pressed(reportID: 1, bytes: [1] + payload) == [key])
        #expect(RemoteButton.pressed(reportID: 6, bytes: payload) == nil)
    }
    #expect(RemoteButton.pressed(reportID: 1, bytes: [0, 0, 0, 0, 1, 0]) == nil)
    #expect(RemoteButton.pressed(reportID: 1, bytes: [0]) == nil)
    #expect(RemoteButton.pressed(reportID: 1, bytes: [0, 0, 0, 0, 0, 0]) == [])
}

@Test("每颗普通键的短按、双击和长按互斥，重复报告不会重发")
func gestures() {
    let p = configured()
    for button in RemoteButton.allCases where button != .voice {
        var engine = RemoteGestures()
        func edge(_ down: Bool, _ t: Int) -> [RemoteStroke] { engine.ingest(down ? [button] : [], at: t, profile: p) }
        func tick(_ t: Int) -> [RemoteStroke] { engine.advance(to: t) }
        #expect(edge(true, 0).isEmpty)
        #expect(edge(false, 80).isEmpty)
        #expect(tick(379).isEmpty)
        #expect(tick(380) == [RemoteStroke(button, .single)])
        #expect(edge(true, 500).isEmpty)
        #expect(edge(false, 550).isEmpty)
        #expect(edge(true, 750).isEmpty)
        #expect(edge(false, 800) == [RemoteStroke(button, .double)])
        #expect(tick(1200).isEmpty)
        #expect(edge(true, 1400).isEmpty)
        #expect(edge(true, 1700).isEmpty)
        #expect(tick(1950) == [RemoteStroke(button, .long)])
        #expect(edge(false, 2100).isEmpty)
        #expect(tick(3000).isEmpty)
    }
}
@Test("默认只接管确定键，迁移后的 Fn 是设备本身的按下与松开")
func keyLeaseAndPersistence() throws {
    #expect(RemoteProfile().deviceMap == [0x7_0000_0028: 0])
    let p = configured()
    #expect(p.deviceMap.count == 13)
    #expect(p.deviceMap[0x7_0000_003e] == 0xff_0000_0003)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try p.save(replacing: RemoteProfile(), at: url)
    #expect(try RemoteProfile.read(from: url) == p)
    #expect(throws: (any Error).self) { try p.save(replacing: RemoteProfile(), at: url) }
}

@Test("按报告时刻区分临界双击和长按")
func gesturesAtReportDeadlines() {
    let profile = configured()
    var state = RemoteGestures()
    _ = state.ingest([.ok], at: 0, profile: profile)
    #expect(state.ingest([], at: 549, profile: profile).isEmpty)
    #expect(state.advance(to: 849) == [RemoteStroke(.ok, .single)])

    _ = state.ingest([.ok], at: 1000, profile: profile)
    #expect(state.ingest([], at: 1550, profile: profile) == [RemoteStroke(.ok, .long)])

    _ = state.ingest([.ok], at: 2000, profile: profile)
    _ = state.ingest([], at: 2100, profile: profile)
    #expect(state.ingest([.ok], at: 2399, profile: profile).isEmpty)
    #expect(state.ingest([], at: 2499, profile: profile) == [RemoteStroke(.ok, .double)])
}

@Test("单独的 F18 由设备直接产生，组合键或配置了其他手势时仍使用派发")
func physicalFunctionKey() {
    var profile = RemoteProfile()
    var binding = RemoteBinding()
    binding.single = RemoteAction(.shortcut)
    binding.single.keyCode = 79
    binding.single.flags = 0x0080_0100
    let source: UInt64 = 0x7_0000_0028
    profile.buttons[RemoteButton.ok.rawValue] = binding
    #expect(profile.deviceMap(canPost: false)[source] == 0x7_0000_006d)

    binding.double = .dictationShortcut
    profile.buttons[RemoteButton.ok.rawValue] = binding
    #expect(profile.deviceMap[source] == 0)

    binding.double = RemoteAction(.none)
    binding.single.flags = 0x0084_0000
    profile.buttons[RemoteButton.ok.rawValue] = binding
    #expect(profile.deviceMap[source] == 0)
}

@Test("初始松开不触发；旧版独立确定键连续短按仍可立即切换；取消会丢弃等待中的动作")
func defaultAndCancellation() {
    var p = RemoteProfile()
    var engine = RemoteGestures()
    func edge(_ keys: Set<RemoteButton>, _ time: Int) -> [RemoteStroke] {
        engine.ingest(keys, at: time, profile: p)
    }
    #expect(edge([], 0).isEmpty)
    for time in [100, 400] {
        #expect(edge([.ok], time).isEmpty)
        #expect(edge([.ok], time + 10).isEmpty)
        #expect(edge([], time + 80) == [RemoteStroke(.ok, .single)])
    }
    p = configured()
    #expect(edge([.ok, .up], 600).isEmpty)
    #expect(edge([.up], 680).isEmpty)
    #expect(engine.deadline == 980)
    engine = RemoteGestures()
    #expect(engine.deadline == nil)
    #expect(edge([], 2000).isEmpty)
}

@Test("面板只修改所选手势，过期操作和语音键写入均拒绝")
func editFromMenuPanel() throws {
    let initial = configured()
    let before = initial.action(for: .ok, gesture: .double)
    var chord = RemoteAction(.shortcut)
    chord.keyCode = 9
    chord.label = "V"
    chord.flags = RemoteModifier.flags(RemoteModifier.all.filter { $0.code == 62 || $0.code == 58 })
    let request = RemoteEditorCommand.change(id: UUID(), button: .ok, gesture: .double, previous: before, action: chord)
    let data = try JSONEncoder().encode(request)
    #expect(!data.contains(0x0a))
    #expect(try JSONDecoder().decode(RemoteEditorCommand.self, from: data) == request)
    let changed = try initial.editing(.ok, gesture: .double, previous: before, action: chord)
    #expect(changed.action(for: .ok, gesture: .single) == initial.action(for: .ok, gesture: .single))
    #expect(changed.action(for: .ok, gesture: .long) == initial.action(for: .ok, gesture: .long))
    #expect(changed.action(for: .ok, gesture: .double) == chord)
    #expect(changed.deviceMap == initial.deviceMap)
    #expect(throws: PreferenceError.self) {
        try changed.editing(.ok, gesture: .double, previous: before, action: .init(.none))
    }
    #expect(throws: PreferenceError.self) {
        try changed.editing(.voice, gesture: .single, previous: .init(.none), action: chord)
    }
    #expect(RemoteModifier.keycaps(code: 9, flags: chord.flags ?? 0, label: "V") == ["右⌃", "左⌥", "V"])
}

@Test("新确定键使用普通快捷键；旧版听写预设可以按原值重新录入")
func editLegacyDictationShortcut() throws {
    let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data(#"{"kind":"typeless"}"#.utf8))
    let shortcut = RemoteProfile().action(for: .ok, gesture: .single)
    #expect(shortcut.kind == .shortcut)
    #expect(shortcut.keyCode == 9 && shortcut.flags == 0xC0021 && shortcut.label == "V")
    #expect(legacy.editableAction == shortcut)
    #expect(!RemoteAction.Kind.choices.contains(.typeless))
    var old = configured()
    var binding = old.buttons[RemoteButton.ok.rawValue] ?? RemoteBinding()
    binding.single = legacy
    old.buttons[RemoteButton.ok.rawValue] = binding
    let updated = try old.editing(.ok, gesture: .single, previous: legacy, action: shortcut)
    #expect(updated.action(for: .ok, gesture: .single) == shortcut)
    #expect(updated.action(for: .ok, gesture: .double) == binding.double)
    #expect(updated.action(for: .ok, gesture: .long) == binding.long)
    #expect(updated.deviceMap[0x7_0000_0028] == 0)
}
