// [INPUT]: VorsmateCore；虚构的输入源与音频 UID。
// [OUTPUT]: 优先级、锁定、插拔、独立通道与配置保存的行为验证。
// [POS]: 不调用真实硬件的规则回归测试。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation
import Testing

@testable import VorsmateCore

private let dji = Source(id: "dji", name: "DJI Wireless Mic")
private let airpods = Source(id: "airpods", name: "AirPods")
private let builtin = Source(id: "builtin", name: "内置麦克风")

@Suite("选择规则")
struct PolicyTests {
    @Test("戴上 AirPods 后，DJI 优先级仍最高")
    func djiWins() {
        var policy = SelectionPolicy(enabled: true, priority: [dji, builtin])
        let connected = Snapshot(sources: [airpods, dji, builtin], selectedID: airpods.id)
        policy.discover(connected)
        #expect(policy.target(in: connected) == dji.id)
        #expect(policy.priority.map(\.id) == [dji.id, builtin.id, airpods.id])
    }
    @Test("第一次发现保持当前设备在前，不立刻切换")
    func firstDiscovery() {
        var policy = SelectionPolicy(enabled: true)
        policy.discover(Snapshot(sources: [airpods, dji], selectedID: dji.id))
        #expect(policy.priority == [dji, airpods])
    }
    @Test("锁定优先于排序；离线回退；重新接入恢复锁定")
    func lockLifecycle() {
        var policy = SelectionPolicy(enabled: true, priority: [dji, builtin, airpods])
        policy.lock(airpods.id)
        let all = Snapshot(sources: [dji, airpods, builtin], selectedID: dji.id)
        #expect(policy.target(in: all) == airpods.id)
        let unplugged = Snapshot(sources: [dji, builtin], selectedID: builtin.id)
        policy.discover(unplugged)
        #expect(policy.target(in: unplugged) == dji.id)
        #expect(policy.isWaiting(in: unplugged))
        #expect(policy.lockedID == airpods.id)
        #expect(policy.target(in: all) == airpods.id)
        policy.automate()
        #expect(policy.target(in: all) == dji.id)
    }
    @Test("暂停和空设备列表不会写入目标")
    func pausedAndEmpty() {
        var policy = SelectionPolicy(priority: [dji], lockedID: dji.id)
        #expect(policy.target(in: Snapshot(sources: [dji])) == nil)
        policy.enabled = true
        #expect(policy.target(in: Snapshot()) == nil)
    }
    @Test("排序保留离线设备，重命名不丢失 UID")
    func discoveryAndMove() {
        var policy = SelectionPolicy(enabled: true, priority: [dji, builtin, dji])
        policy.discover(Snapshot(sources: [Source(id: dji.id, name: "重命名麦克风")]))
        #expect(policy.priority.map(\.id) == [dji.id, builtin.id])
        #expect(policy.priority[0].name == "重命名麦克风")
        policy.move(builtin.id, by: -1)
        #expect(policy.priority.map(\.id) == [builtin.id, dji.id])
        policy.move(builtin.id, by: -1)
        #expect(policy.priority.first?.id == builtin.id)
    }
    @Test("麦克风与播放设备使用独立排序与锁定")
    func separateChannels() {
        var preferences = Preferences()
        preferences[.audioInput] = SelectionPolicy(enabled: true, priority: [dji, airpods])
        preferences[.audioOutput] = SelectionPolicy(enabled: true, priority: [airpods, builtin])
        let input = Snapshot(sources: [dji, airpods])
        let output = Snapshot(sources: [builtin, airpods])
        #expect(preferences[.audioInput].target(in: input) == dji.id)
        #expect(preferences[.audioOutput].target(in: output) == airpods.id)
        #expect(!preferences[.inputSource].enabled)
    }
    @Test("输入法同样按独立顺序锁定与恢复自动")
    func inputSources() {
        let abc = Source(id: "com.apple.keylayout.ABC", name: "ABC")
        let pinyin = Source(id: "pinyin", name: "拼音")
        var policy = SelectionPolicy(enabled: true, priority: [pinyin, abc])
        let snapshot = Snapshot(sources: [abc, pinyin], selectedID: abc.id)
        #expect(policy.target(in: snapshot) == pinyin.id)
        policy.lock(abc.id)
        #expect(policy.target(in: snapshot) == abc.id)
        policy.automate()
        #expect(policy.target(in: snapshot) == pinyin.id)
    }
    @Test("连续竞争有上限，正常间隔不会误触发")
    func switchBudget() {
        var budget = SwitchBudget()
        #expect(budget.request(at: 0) == .allow)
        #expect(budget.request(at: 0.2) == .wait)
        #expect(budget.request(at: 1) == .allow)
        #expect(budget.request(at: 2) == .allow)
        #expect(budget.request(at: 3) == .allow)
        #expect(budget.request(at: 4) == .suspend)
        #expect(budget.request(at: 10) == .allow)
    }
}

@Suite("配置保存")
struct PreferencesTests {
    @Test("持久化完整保留暂停、顺序和离线锁定")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorsmate-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferencesStore(url: folder.appending(path: "settings.json"))
        #expect(try store.load() == Preferences())
        var preferences = Preferences()
        preferences[.audioInput] = SelectionPolicy(enabled: true, priority: [dji, builtin], lockedID: dji.id)
        try store.save(preferences)
        #expect(try store.load() == preferences)
    }
    @Test("损坏配置与未来版本读取失败但不被覆盖")
    func preserveInvalidData() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "vorsmate-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore(url: url)
        let invalid = Data("not-json".utf8)
        try invalid.write(to: url)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(try Data(contentsOf: url) == invalid)
        var future = Preferences()
        future.version = 9
        try store.save(future)
        #expect(throws: PreferenceError.self) { try store.load() }
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)).version == 9)
    }
    @Test("运行期间替换配置后，旧会话拒绝覆盖", arguments: [1, 9])
    func refuseExternalReplacement(version: Int) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "vorsmate-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore(url: url)
        let original = Preferences()
        try store.save(original)
        var external = original
        external.version = version
        external[.audioInput] = SelectionPolicy(enabled: true, priority: [airpods])
        try store.save(external)
        let before = try Data(contentsOf: url)
        var next = original
        next[.audioInput] = SelectionPolicy(enabled: true, priority: [dji])
        #expect(throws: PreferenceError.self) { try store.save(next, replacing: original) }
        #expect(try Data(contentsOf: url) == before)
    }
}
