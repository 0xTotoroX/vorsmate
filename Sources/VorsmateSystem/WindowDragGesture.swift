// [INPUT]: 左键与修饰键事件、可替换的窗口命中与移动操作。
// [OUTPUT]: 拖动接管、点击还原、按最新指针位置限频移动、暂忙恢复与松键收尾。
// [POS]: WindowDragMonitor 的单次手势状态，不注册全局监听。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Foundation
import VorsmateCore

@MainActor
final class WindowDragGesture {
    @MainActor private final class Press {
        let down: CGEvent
        let hit: WindowDragTarget.Hit
        var candidate: WindowDragTarget?
        var preparedAt: ContinuousClock.Instant?
        private var firstMotion: CGVector?
        private var checkedFocus = false
        private(set) var titlePress: WindowTitleDrag?

        init(_ down: CGEvent, _ hit: WindowDragTarget.Hit) {
            self.down = down
            self.hit = hit
        }

        func startsTitleDrag(dx: CGFloat, dy: CGFloat) -> Bool {
            let distance = dx * dx + dy * dy
            if distance >= 4 { return true }
            guard distance >= 1 else {
                firstMotion = nil
                return false
            }
            // 单次微动仍算点击。连续朝外移动时无需再等一个鼠标采样。
            guard let firstMotion else {
                firstMotion = CGVector(dx: dx, dy: dy)
                return false
            }
            return distance > firstMotion.dx * firstMotion.dx + firstMotion.dy * firstMotion.dy
                && dx * firstMotion.dx + dy * firstMotion.dy > 0
        }

        var freshCandidate: WindowDragTarget? {
            guard let preparedAt, ContinuousClock.now - preparedAt < .milliseconds(350) else { return nil }
            return candidate
        }

        func prepareTitlePress(stillExposed: (WindowDragTarget.Hit, CGPoint) -> Bool, forward: (CGEvent) -> Void) {
            guard !checkedFocus, let target = freshCandidate, let point = target.titleBarPoint else { return }
            checkedFocus = true
            // 首个系统拖动事件可先在已聚焦窗口按住空白标题栏，避免启动时丢失抓取点。
            // 确认手势前不发送任何位移，后台窗口也不会被这个准备步骤激活。
            guard target.isFocused(), stillExposed(hit, point), let copy = down.copy() else { return }
            var title = WindowTitleDrag(down: copy, title: point, window: hit.number)
            title.press(post: forward)
            titlePress = title
        }

        func restoreClick(forward: (CGEvent) -> Void) {
            titlePress?.end(at: DispatchTime.now().uptimeNanoseconds, post: forward)
            forward(down)
        }
    }

    private enum Phase {
        case idle
        case pending(Press)
        case moving(WindowDragTarget, offset: CGPoint)
        case untilMouseUp
    }

    private let hitTest: @MainActor (CGPoint) -> WindowDragTarget.Hit?
    private let resolve: @MainActor (WindowDragTarget.Hit, CGPoint) -> WindowDragTarget?
    private let stillExposed: @MainActor (WindowDragTarget.Hit, CGPoint) -> Bool
    private var phase = Phase.idle
    private var latestPosition: CGPoint?
    private var lastWritten: CGPoint?
    private var nextWrite: ContinuousClock.Instant?
    private var delivery: Task<Void, Never>?

    var isTracking: Bool {
        if case .idle = phase { return false }
        return true
    }

    init(
        hitTest: @escaping @MainActor (CGPoint) -> WindowDragTarget.Hit? = WindowDragTarget.hit,
        resolve: @escaping @MainActor (WindowDragTarget.Hit, CGPoint) -> WindowDragTarget? = WindowDragTarget.resolve,
        stillExposed: @escaping @MainActor (WindowDragTarget.Hit, CGPoint) -> Bool = WindowDragTarget.stillExposed
    ) {
        self.hitTest = hitTest
        self.resolve = resolve
        self.stillExposed = stillExposed
    }

    // true 表示该鼠标事件已由拖动处理。flagsChanged 始终传给系统。
    func consumes(
        _ type: CGEventType, event: CGEvent, modifier: WindowDragModifier,
        beginTitleDrag: ((WindowTitleDrag) -> Void)? = nil, forward: (CGEvent) -> Void
    ) -> Bool {
        let matches = modifier.matches(event.flags)
        switch type {
        case .leftMouseDown:
            reset(forward: forward)
            guard matches, let hit = hitTest(event.location), let down = event.copy() else { return false }
            let press = Press(down, hit)
            phase = .pending(press)
            if beginTitleDrag != nil {
                // 按下后先让鼠标回调返回，再利用指针尚未移动的时间查找标题栏。
                Task { @MainActor [weak self, weak press] in
                    guard let self, let press else { return }
                    press.candidate = self.resolve(press.hit, press.down.location)
                    press.preparedAt = .now
                }
            }
            return true
        case .flagsChanged:
            if !matches { interrupt(forward: forward) }
            return false
        case .leftMouseDragged, .leftMouseUp:
            if !matches { interrupt(forward: forward) }
            let released = type == .leftMouseUp
            defer { if released { reset(forward: forward) } }
            switch phase {
            case .idle:
                return false
            case .untilMouseUp:
                return true
            case .pending(let press):
                if released { return false }  // reset 会在原 mouseUp 之前补发 mouseDown。
                let down = press.down
                let hit = press.hit
                let dx = event.location.x - down.location.x
                let dy = event.location.y - down.location.y
                let distanceSquared = dx * dx + dy * dy
                let hasTitle = beginTitleDrag != nil && press.candidate?.titleBarPoint != nil
                if hasTitle {
                    guard press.startsTitleDrag(dx: dx, dy: dy) else {
                        press.prepareTitlePress(stillExposed: stillExposed, forward: forward)
                        return true
                    }
                    if let started = press.titlePress, let beginTitleDrag {
                        phase = .idle
                        beginTitleDrag(started)
                        return true
                    }
                } else if distanceSquared < 9 {
                    return true
                }
                guard let target = targetForDrag(press) else {
                    reset(forward: forward)
                    return false
                }
                if let title = target.titleBarPoint, let beginTitleDrag {
                    phase = .idle
                    beginTitleDrag(WindowTitleDrag(down: down, title: title, window: hit.number))
                    return true
                }
                guard distanceSquared >= 9 else { return true }
                let position = CGPoint(x: target.origin.x + dx, y: target.origin.y + dy)
                guard moveOrRetry(position, on: target, retryIfBusy: true) else {
                    reset(forward: forward)
                    return false
                }
                phase = .moving(
                    target, offset: CGPoint(x: target.origin.x - down.location.x, y: target.origin.y - down.location.y))
                return true
            case .moving(_, let offset):
                latestPosition = CGPoint(x: event.location.x + offset.x, y: event.location.y + offset.y)
                if released {
                    flush()
                } else {
                    scheduleDelivery(retryIfBusy: true)
                }
                return true
            }
        default:
            return false
        }
    }

    private func targetForDrag(_ press: Press) -> WindowDragTarget? {
        if let candidate = press.freshCandidate,
            stillExposed(press.hit, candidate.titleBarPoint ?? press.down.location)
        {
            return candidate
        }
        return resolve(press.hit, press.down.location)
    }

    private func scheduleDelivery(retryIfBusy: Bool) {
        guard delivery == nil else { return }
        let deadline = nextWrite
        delivery = Task { @MainActor in
            if let deadline, ContinuousClock.now < deadline {
                do { try await Task.sleep(until: deadline, tolerance: .zero, clock: .continuous) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.flush(retryIfBusy: retryIfBusy)
        }
    }

    private func flush(retryIfBusy: Bool = false) {
        delivery?.cancel()
        delivery = nil
        guard let position = latestPosition, case .moving(let target, _) = phase else { return }
        latestPosition = nil
        if !moveOrRetry(position, on: target, retryIfBusy: retryIfBusy) {
            phase = .untilMouseUp
        }
    }

    private func moveOrRetry(_ position: CGPoint, on target: WindowDragTarget, retryIfBusy: Bool) -> Bool {
        guard lastWritten != position else { return true }
        let start = ContinuousClock.now
        switch target.move(position) {
        case .moved:
            lastWritten = position
            // 从上次实际写入起限频，间隔已到即可移动。
            nextWrite = start + .milliseconds(8)
        case .busy:
            // 超时的请求仍可能生效。保留最新目标，静止时最多再试一次。
            lastWritten = nil
            latestPosition = position
            nextWrite = .now + .milliseconds(80)
            if retryIfBusy { scheduleDelivery(retryIfBusy: false) }
        case .unavailable:
            return false
        }
        return true
    }

    func interrupt(forward: (CGEvent) -> Void) {
        switch phase {
        case .pending(let press):
            phase = .idle
            press.restoreClick(forward: forward)
        case .moving:
            flush()
            phase = .untilMouseUp
        case .idle, .untilMouseUp:
            break
        }
    }

    func reset(forward: (CGEvent) -> Void) {
        if case .pending(let press) = phase { press.restoreClick(forward: forward) }
        phase = .idle
        latestPosition = nil
        lastWritten = nil
        nextWrite = nil
        delivery?.cancel()
        delivery = nil
    }
}
