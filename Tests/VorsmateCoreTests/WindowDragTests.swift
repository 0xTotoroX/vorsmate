// [INPUT]: 内存窗口、合成 Quartz 事件与真实手势处理器。
// [OUTPUT]: 修饰键、点击还原、目标固定、终点与中断的回归。
// [POS]: 不向系统投递事件，也不移动桌面上的窗口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Testing
import VorsmateCore

@testable import VorsmateSystem

@Suite("窗口拖动")
@MainActor
struct WindowDragTests {
    @MainActor
    private final class Fixture {
        let anchor = CGPoint(x: 40, y: 25)
        let origin = CGPoint(x: -80, y: -60)
        var number: CGWindowID? = 17
        var movable = true
        var writable = true
        var hits: [CGPoint] = []
        var resolutions: [CGWindowID] = []
        var attempts = 0
        var moves: [CGPoint] = []
        var forwarded: [CGEvent] = []
        lazy var gesture = WindowDragGesture(
            hitTest: { [unowned self] in
                self.hits.append($0)
                return self.number.map { WindowDragTarget.Hit(number: $0, pid: 42) }
            },
            resolve: { [unowned self] hit, point in
                self.resolutions.append(hit.number)
                #expect(point == self.anchor)
                guard self.movable else { return nil }
                return WindowDragTarget(origin: self.origin) { point in
                    self.attempts += 1
                    guard self.writable else { return false }
                    self.moves.append(point)
                    return true
                }
            })

        @discardableResult
        func send(_ type: CGEventType, dx: Int = 0, dy: Int = 0, flags: CGEventFlags = .maskAlternate) -> Bool {
            let event = CGEvent(source: nil)!
            event.type = type
            event.flags = flags
            event.location = CGPoint(x: anchor.x + CGFloat(dx), y: anchor.y + CGFloat(dy))
            event.setIntegerValueField(.mouseEventClickState, value: 2)
            return gesture.consumes(type, event: event, modifier: .option) { forwarded.append($0) }
        }

        func reset() { gesture.reset { forwarded.append($0) } }
    }

    @Test("单键与组合精确匹配，忽略大小写锁定和左右键位")
    func modifiers() {
        #expect(WindowDragModifier.option.matches([.maskAlternate, .maskAlphaShift]))
        #expect(!WindowDragModifier.option.matches([.maskAlternate, .maskShift]))
        #expect(!WindowDragModifier.option.matches([]))
        #expect(WindowDragModifier.commandOption.matches([.maskAlternate, .maskCommand]))
        #expect(!WindowDragModifier.commandOption.matches(.maskCommand))
        #expect(WindowDragModifier.function.matches(.maskSecondaryFn))
    }

    @Test("普通拖动及右键透传，纯修饰键点击在原 mouseUp 前还原原位置与点击次数")
    func click() {
        let f = Fixture()
        #expect(!f.send(.leftMouseDown, flags: []))
        #expect(!f.send(.leftMouseDragged, dx: 8))
        #expect(!f.send(.leftMouseUp))
        #expect(!f.send(.rightMouseDown))
        #expect(f.hits.isEmpty)
        #expect(f.send(.leftMouseDown))
        #expect(f.send(.leftMouseDragged, dx: 1, dy: -1))
        #expect(!f.send(.leftMouseUp))
        #expect(f.forwarded.count == 1)
        #expect(f.forwarded.first?.location == f.anchor)
        #expect(f.forwarded.first?.type == .leftMouseDown)
        #expect(f.forwarded.first?.flags.contains(.maskAlternate) == true)
        #expect(f.forwarded.first?.getIntegerValueField(.mouseEventClickState) == 2)
        #expect(f.resolutions.isEmpty)
    }

    @Test("负坐标、跨窗口、快速合并与松手终点均从起点计算")
    func drag() {
        let f = Fixture()
        #expect(f.send(.leftMouseDown))
        f.number = 22
        #expect(f.send(.leftMouseDragged, dx: -3))
        #expect(f.send(.leftMouseDragged, dx: -80, dy: 12))
        #expect(f.send(.leftMouseDragged, dx: -100, dy: 45))
        #expect(f.send(.leftMouseUp, dx: -104, dy: 40))
        #expect(f.hits == [f.anchor])
        #expect(f.resolutions == [17])
        #expect(f.moves == [CGPoint(x: -83, y: -60), CGPoint(x: -184, y: -20)])
        #expect(f.forwarded.isEmpty)
        #expect(!f.send(.leftMouseDragged, dx: 99))
    }

    @Test("桌面、不可移动和拒绝写入的窗口恢复应用原本的拖动")
    func unsupportedTarget() {
        let f = Fixture()
        f.number = nil
        #expect(!f.send(.leftMouseDown))
        f.number = 17
        for movable in [false, true] {
            f.movable = movable
            f.writable = false
            #expect(f.send(.leftMouseDown))
            #expect(!f.send(.leftMouseDragged, dx: 10))
            #expect(!f.send(.leftMouseUp))
        }
        #expect(f.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDown])
        #expect(f.moves.isEmpty)
    }

    @Test("松开修饰键后立即停止，按住鼠标重新按键不会转移手势")
    func releaseModifier() {
        let f = Fixture()
        #expect(f.send(.leftMouseDown))
        #expect(!f.send(.flagsChanged, flags: []))
        #expect(!f.send(.leftMouseDragged, dx: 16))
        #expect(!f.send(.leftMouseUp))
        #expect(f.forwarded.count == 1)

        #expect(f.send(.leftMouseDown))
        #expect(f.send(.leftMouseDragged, dy: 5))
        #expect(f.send(.leftMouseDragged, dy: 11))
        #expect(!f.send(.flagsChanged, flags: []))
        #expect(f.send(.leftMouseDragged, dy: 80))
        #expect(f.send(.leftMouseUp))
        #expect(f.moves == [CGPoint(x: -80, y: -55), CGPoint(x: -80, y: -49)])
        #expect(f.forwarded.count == 1)
    }

    @Test("按住时持续跟随，中途目标拒绝移动后收走余下手势")
    func moving() async throws {
        let f = Fixture()
        f.send(.leftMouseDown)
        f.send(.leftMouseDragged, dx: 5)
        f.send(.leftMouseDragged, dx: 8)
        f.send(.leftMouseDragged, dx: 18)
        let deadline = ContinuousClock.now + .seconds(2)
        while f.moves.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.moves == [CGPoint(x: -75, y: -60), CGPoint(x: -62, y: -60)])
        f.writable = false
        #expect(f.send(.leftMouseDragged, dx: 26))
        let failureDeadline = ContinuousClock.now + .seconds(2)
        while f.attempts < 3 && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        f.writable = true
        #expect(f.send(.leftMouseDragged, dx: 30))
        #expect(f.send(.leftMouseUp, dx: 34))
        #expect(f.attempts == 3)
        #expect(f.moves.last == CGPoint(x: -62, y: -60))
        #expect(f.forwarded.isEmpty)
    }

    @Test("停用取消尚未执行的移动，仅还原尚未接管的按下")
    func stop() async throws {
        let f = Fixture()
        #expect(f.send(.leftMouseDown))
        f.reset()
        #expect(f.forwarded.count == 1)
        #expect(f.send(.leftMouseDown))
        #expect(f.send(.leftMouseDragged, dx: 5))
        #expect(f.send(.leftMouseDragged, dx: 18))
        f.reset()
        try await Task.sleep(for: .milliseconds(20))
        #expect(f.moves == [CGPoint(x: -75, y: -60)])
        #expect(f.forwarded.count == 1)
    }
}
