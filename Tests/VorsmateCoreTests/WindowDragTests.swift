// [INPUT]: 内存窗口、合成 Quartz 事件与真实手势处理器。
// [OUTPUT]: 修饰键、点击还原、目标固定、暂忙恢复、终点与中断的回归。
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
        var moveResult = WindowDragTarget.MoveResult.moved
        var titlePoint: CGPoint?
        var exposed = true
        var focused = false
        var rechecks: [CGPoint] = []
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
                return WindowDragTarget(
                    origin: self.origin, titleBarPoint: self.titlePoint, isFocused: { self.focused },
                    move: { point in
                        self.attempts += 1
                        if self.moveResult == .moved { self.moves.append(point) }
                        return self.moveResult
                    })
            },
            stillExposed: { [unowned self] _, point in
                self.rechecks.append(point)
                return self.exposed
            })

        @discardableResult
        func send(
            _ type: CGEventType, dx: Int = 0, dy: Int = 0, flags: CGEventFlags = .maskAlternate,
            beginTitleDrag: ((WindowTitleDrag) -> Void)? = nil
        ) -> Bool {
            let event = CGEvent(source: nil)!
            event.type = type
            event.flags = flags
            event.location = CGPoint(x: anchor.x + CGFloat(dx), y: anchor.y + CGFloat(dy))
            event.setIntegerValueField(.mouseEventClickState, value: 2)
            return gesture.consumes(type, event: event, modifier: .option, beginTitleDrag: beginTitleDrag) {
                forwarded.append($0)
            }
        }

        func reset() { gesture.reset { forwarded.append($0) } }

        func waitForResolution() async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while resolutions.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(resolutions == [17])
        }

        func waitForAttempts(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while attempts < count && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(attempts == count)
        }
    }

    @Test("按下时预读标题栏，微动仍还原单击，起拖只复核已选窗口", arguments: [false, true])
    func preparedTitle(click: Bool) async throws {
        let f = Fixture()
        let point = CGPoint(x: 150, y: -32)
        f.titlePoint = point
        var active: WindowTitleDrag?
        let receive: (WindowTitleDrag) -> Void = { active = $0 }
        #expect(f.send(.leftMouseDown, beginTitleDrag: receive))
        try await f.waitForResolution()
        #expect(f.attempts == 0)
        #expect(f.send(.leftMouseDragged, dx: click ? 1 : 2, beginTitleDrag: receive))
        #expect(f.resolutions == [17])
        #expect(f.rechecks == (click ? [] : [point]))
        #expect((active == nil) == click)
        if click {
            #expect(!f.send(.leftMouseUp))
            #expect(f.forwarded.map(\.type) == [.leftMouseDown])
        }
    }

    @Test("预读后窗口失效或标题栏被遮住时重新确认，不向原落点发按下")
    func coveredPreparedTitle() async throws {
        let f = Fixture()
        f.titlePoint = .zero
        var active: WindowTitleDrag?
        let receive: (WindowTitleDrag) -> Void = { active = $0 }
        f.send(.leftMouseDown, beginTitleDrag: receive)
        try await f.waitForResolution()
        f.exposed = false
        f.movable = false
        #expect(!f.send(.leftMouseDragged, dx: 10, beginTitleDrag: receive))
        #expect(f.resolutions == [17, 17])
        #expect(active == nil)
        #expect(f.forwarded.map(\.type) == [.leftMouseDown])
    }

    @Test("单点抖动或原地折返保留点击，连续朝外的两个微小采样才起拖")
    func earlyDirection() async throws {
        let f = Fixture()
        f.titlePoint = .zero
        var active: WindowTitleDrag?
        let receive: (WindowTitleDrag) -> Void = { active = $0 }
        f.send(.leftMouseDown, beginTitleDrag: receive)
        try await f.waitForResolution()
        for dy in [1, 1, 0, -1, 0, 1] {
            f.send(.leftMouseDragged, dy: dy, beginTitleDrag: receive)
            #expect(active == nil)
        }
        #expect(f.send(.leftMouseDragged, dx: 1, dy: 1, beginTitleDrag: receive))
        #expect(active != nil)
        #expect(f.rechecks == [.zero])
    }

    @Test("在聚焦窗口预按标题栏，松手、松键和停用均恢复一次原内容点击")
    func primedClick() async throws {
        enum Ending: CaseIterable { case mouseUp, modifierUp, stop }
        for ending in Ending.allCases {
            let f = Fixture()
            let title = CGPoint(x: 30, y: -20)
            f.titlePoint = title
            f.focused = true
            let receive: (WindowTitleDrag) -> Void = { _ in Issue.record("轻微移动不应接管拖动") }
            f.send(.leftMouseDown, beginTitleDrag: receive)
            try await f.waitForResolution()
            #expect(f.forwarded.isEmpty)
            f.send(.leftMouseDragged, beginTitleDrag: receive)
            #expect(f.forwarded.map(\.type) == [.leftMouseDown])
            f.send(.leftMouseDragged, dx: 1, beginTitleDrag: receive)
            f.send(.leftMouseDragged, dx: 1, beginTitleDrag: receive)
            #expect(f.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged])
            switch ending {
            case .mouseUp: #expect(!f.send(.leftMouseUp))
            case .modifierUp: #expect(!f.send(.flagsChanged, flags: []))
            case .stop: f.reset()
            }
            #expect(f.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .leftMouseDown])
            let grip = CGPoint(x: title.x + 1, y: title.y)
            #expect(f.forwarded.map(\.location) == [title, grip, grip, f.anchor])
            #expect(f.forwarded.last?.flags == .maskAlternate)
            #expect(f.forwarded.last?.getIntegerValueField(.mouseEventClickState) == 2)
            #expect(f.moves.isEmpty)
        }
    }

    @Test("标题栏预按只发一次，持续位移和松手从同一原点传递")
    func primedDrag() async throws {
        let f = Fixture()
        f.titlePoint = .zero
        f.focused = true
        var active: WindowTitleDrag?
        let receive: (WindowTitleDrag) -> Void = { active = $0 }
        f.send(.leftMouseDown, beginTitleDrag: receive)
        try await f.waitForResolution()
        f.send(.leftMouseDragged, beginTitleDrag: receive)
        f.send(.leftMouseDragged, dx: 12, beginTitleDrag: receive)
        var title = try #require(active)
        let drag = try #require(CGEvent(source: nil))
        drag.type = .leftMouseDragged
        drag.location = CGPoint(x: f.anchor.x + 12, y: f.anchor.y)
        title.begin(with: drag) { f.forwarded.append($0) }
        #expect(drag.location == CGPoint(x: 12, y: 0))
        title.end(at: 123) { f.forwarded.append($0) }
        #expect(f.forwarded.map(\.type) == [.leftMouseDown, .leftMouseUp])
        #expect(f.forwarded.last?.location == drag.location)
        #expect(f.rechecks == [.zero])
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
            f.moveResult = .unavailable
            #expect(f.send(.leftMouseDown))
            #expect(!f.send(.leftMouseDragged, dx: 10))
            #expect(!f.send(.leftMouseUp))
        }
        #expect(f.forwarded.map(\.type) == [.leftMouseDown, .leftMouseDown])
        #expect(f.moves.isEmpty)
    }

    @Test("从内容区在同一窗口标题栏起拖，连续移动及松手保留位移")
    func nativeTitleDrag() throws {
        let f = Fixture()
        let title = CGPoint(x: -213, y: -41)
        f.titlePoint = title
        f.send(.leftMouseDown)
        let drag = try #require(CGEvent(source: nil))
        drag.type = .leftMouseDragged
        drag.location = CGPoint(x: f.anchor.x + 10, y: f.anchor.y - 4)
        drag.flags = [.maskAlternate, .maskAlphaShift]
        var active: WindowTitleDrag?
        #expect(
            f.gesture.consumes(
                .leftMouseDragged, event: drag, modifier: .option, beginTitleDrag: { active = $0 },
                forward: { f.forwarded.append($0) }))
        var session = try #require(active)
        var posted: [CGEvent] = []
        session.begin(with: drag) { posted.append($0) }
        #expect(posted.map(\.type) == [.leftMouseDown])
        #expect(posted.first?.type == .leftMouseDown)
        #expect(posted.first?.location == title)
        #expect(posted.first?.getIntegerValueField(.mouseEventClickState) == 1)
        #expect(drag.location == CGPoint(x: title.x + 10, y: title.y - 4))
        #expect(drag.flags == .maskAlphaShift)
        #expect(drag.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 17)
        let next = try #require(CGEvent(source: nil))
        next.type = .leftMouseDragged
        next.location = CGPoint(x: f.anchor.x - 34, y: f.anchor.y + 75)
        session.update(next)
        #expect(next.location == CGPoint(x: title.x - 34, y: title.y + 75))
        session.end(at: 12345) { posted.append($0) }
        #expect(posted.last?.type == .leftMouseUp)
        #expect(posted.last?.location == next.location)
        #expect(posted.last?.timestamp == 12345)
        #expect(posted.last?.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 17)
        #expect(f.attempts == 0)
        #expect(!f.gesture.isTracking)
        #expect(f.forwarded.isEmpty)
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
        try await f.waitForAttempts(2)
        #expect(f.moves == [CGPoint(x: -75, y: -60), CGPoint(x: -62, y: -60)])
        f.moveResult = .unavailable
        #expect(f.send(.leftMouseDragged, dx: 26))
        try await f.waitForAttempts(3)
        f.moveResult = .moved
        #expect(f.send(.leftMouseDragged, dx: 30))
        #expect(f.send(.leftMouseUp, dx: 34))
        #expect(f.attempts == 3)
        #expect(f.moves.last == CGPoint(x: -62, y: -60))
        #expect(f.forwarded.isEmpty)
    }

    @Test("首笔或途中暂忙后追上最新位置，仍可拖至终点", arguments: [false, true])
    func recoversFromBusyTarget(firstWrite: Bool) async throws {
        let f = Fixture()
        f.send(.leftMouseDown)
        if !firstWrite { f.send(.leftMouseDragged, dx: 5) }
        f.moveResult = .busy
        #expect(f.send(.leftMouseDragged, dx: 14))
        let failedAttempt = firstWrite ? 1 : 2
        try await f.waitForAttempts(failedAttempt)
        f.send(.leftMouseDragged, dx: 25)
        f.send(.leftMouseDragged, dx: 5)
        f.moveResult = .moved
        try await f.waitForAttempts(failedAttempt + 1)
        let recovered = CGPoint(x: -75, y: -60)
        #expect(f.moves == (firstWrite ? [recovered] : [recovered, recovered]))
        #expect(f.send(.leftMouseUp, dx: 34))
        #expect(f.moves.last == CGPoint(x: -46, y: -60))
        #expect(f.forwarded.isEmpty)
    }

    @Test("暂忙后的重试不会越过松键、松手或停用")
    func cancelsBusyRetry() async throws {
        enum Ending: CaseIterable { case releaseModifier, releaseMouse, stop }
        for end in Ending.allCases {
            let f = Fixture()
            f.moveResult = .busy
            f.send(.leftMouseDown)
            f.send(.leftMouseDragged, dx: 5)
            switch end {
            case .releaseModifier: f.send(.flagsChanged, flags: [])
            case .releaseMouse: f.send(.leftMouseUp, dx: 12)
            case .stop: f.reset()
            }
            let attempts = f.attempts
            f.moveResult = .moved
            try await Task.sleep(for: .milliseconds(120))
            #expect(f.attempts == attempts)
            #expect(f.moves.isEmpty)
        }
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
