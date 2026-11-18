// [OUTPUT]: 应用方案继承与回退、按住连发、释放及上下文切换的回归。
import Foundation
import Testing
import VorsmateCore

@Test("应用只覆盖指定手势，显式无动作、恢复继承和移除方案可区分")
func applicationInheritance() throws {
    let id = "com.example.browser"
    var p = try RemoteProfile().applying(
        .action(app: nil, button: .left, gesture: .single, value: .init(.previousTrack)))
    let defaultOK = p.action(for: .ok, gesture: .single)
    p = try p.applying(.addApp(id: id, name: "浏览器"))
    p = try p.applying(.action(app: id, button: .left, gesture: .single, value: .init(.none)))
    p = try p.applying(.action(app: nil, button: .left, gesture: .long, value: .init(.volumeUp)))
    p = try p.applying(.hold(app: id, button: .left, mode: .repeatLong))
    let browser = p.resolved(for: id)
    #expect(browser.action(for: .left, gesture: .single).kind == .none)
    #expect(browser.action(for: .left, gesture: .long).kind == .volumeUp)
    #expect(browser.action(for: .ok, gesture: .single) == defaultOK)
    #expect(browser.buttons["left"]?.hold == .repeatLong)
    #expect(p.resolved(for: "com.example.other").action(for: .left, gesture: .single).kind == .previousTrack)
    p = try p.applying(.action(app: id, button: .left, gesture: .single, value: nil))
    #expect(p.resolved(for: id).action(for: .left, gesture: .single).kind == .previousTrack)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: RemoteProfile.advancedLocation(for: url))
    }
    let legacy = RemoteProfile()
    try legacy.save(replacing: legacy, at: url)
    let before = try Data(contentsOf: url)
    try p.save(replacing: legacy, at: url)
    #expect(try Data(contentsOf: url) == before)
    #expect(FileManager.default.fileExists(atPath: RemoteProfile.advancedLocation(for: url).path))
    #expect(try RemoteProfile.read(from: url) == p)
    p = try p.applying(.removeApp(id: id))
    #expect(p.applications == nil)
    #expect(throws: PreferenceError.self) { try p.applying(.hold(app: id, button: .left, mode: .repeatSingle)) }
}

@Test("版本 1 键位可继续使用，只有新功能要求版本 2；单修饰键仅在执行一次时直通")
func legacyProfileAndHoldRouting() throws {
    let old = Data(#"{"version":1,"buttons":{},"doubleMilliseconds":300,"longMilliseconds":550,"voiceFn":true}"#.utf8)
    let original = try JSONDecoder().decode(RemoteProfile.self, from: old)
    try original.validate()
    var mod = RemoteAction(.shortcut)
    mod.keyCode = 61
    let p = try original.applying(.action(app: nil, button: .left, gesture: .single, value: mod))
    #expect(p.version == 1)
    let source: UInt64 = 0x7_0000_0050
    #expect(p.deviceMap[source] == 0x7_0000_00e6)
    let repeatProfile = try p.applying(.hold(app: nil, button: .left, mode: .repeatSingle))
    #expect(repeatProfile.version == 2)
    #expect(repeatProfile.deviceMap[source] == 0)
    #expect(throws: PreferenceError.self) { try p.applying(.hold(app: nil, button: .voice, mode: .repeatSingle)) }
}

@Test("连发两种目标均只在按住时执行；迟到不补发，释放无尾击")
func holdRepeat() throws {
    for mode in [RemoteHoldMode.repeatSingle, .repeatLong] {
        let p = try RemoteProfile().applying(.action(app: nil, button: .ok, gesture: .long, value: .init(.volumeDown)))
            .applying(.action(app: nil, button: .ok, gesture: .double, value: .init(.mute)))
            .applying(.hold(app: nil, button: .ok, mode: mode))
        var g = RemoteGestures()
        let trigger: RemoteGesture = mode == .repeatSingle ? .single : .long
        #expect(g.ingest([.ok], at: 0, profile: p).isEmpty)
        #expect(g.advance(to: 549).isEmpty)
        #expect(g.advance(to: 550) == [RemoteStroke(.ok, trigger)])
        #expect(g.advance(to: 669).isEmpty)
        #expect(g.advance(to: 670) == [RemoteStroke(.ok, trigger, repeated: true)])
        #expect(g.advance(to: 1100) == [RemoteStroke(.ok, trigger, repeated: true)])
        #expect(g.ingest([], at: 1300, profile: p).isEmpty)
        #expect(g.deadline == nil)
        #expect(g.advance(to: 2000).isEmpty)
        #expect(g.ingest([.ok], at: 2001, profile: p).isEmpty)
        #expect(g.ingest([], at: 2040, profile: p).isEmpty)
        #expect(g.ingest([.ok], at: 2140, profile: p).isEmpty)
        #expect(g.ingest([], at: 2180, profile: p) == [RemoteStroke(.ok, .double)])
    }
}

@Test("切换应用或停用时丢弃待判单击和连发，持续按住的键须先松手")
func cancelHeldContext() throws {
    let p = try RemoteProfile().applying(.action(app: nil, button: .ok, gesture: .double, value: .init(.mute)))
        .applying(.hold(app: nil, button: .ok, mode: .repeatSingle))
    var g = RemoteGestures()
    _ = g.ingest([.ok], at: 0, profile: p)
    _ = g.advance(to: 550)
    g.cancel(holding: [.ok])
    #expect(g.ingest([.ok], at: 600, profile: p).isEmpty)
    #expect(g.advance(to: 1600).isEmpty)
    #expect(g.ingest([], at: 1700, profile: p).isEmpty)
    _ = g.ingest([.ok], at: 1900, profile: p)
    _ = g.ingest([], at: 1920, profile: p)
    g.cancel(holding: [])
    #expect(g.advance(to: 2300).isEmpty)
}
