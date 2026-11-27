// [INPUT]: 左键与修饰键事件、可替换的窗口命中与移动操作。
// [OUTPUT]: 拖动接管、点击还原、按最新指针位置限频移动、暂忙恢复与松键收尾。
// [POS]: WindowDragMonitor 的单次手势状态，不注册全局监听。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Foundation
import VorsmateCore

@MainActor
final class WindowDragGesture {
    private enum Phase {
        case idle
        case pending(CGEvent, WindowDragTarget.Hit)
        case moving(WindowDragTarget, offset: CGPoint)
        case untilMouseUp
    }

    private let hitTest: @MainActor (CGPoint) -> WindowDragTarget.Hit?
    private let resolve: @MainActor (WindowDragTarget.Hit, CGPoint) -> WindowDragTarget?
    private var phase = Phase.idle
    private var latestPosition: CGPoint?
    private var lastWritten: CGPoint?
    private var nextWrite: ContinuousClock.Instant?
    private var delivery: Task<Void, Never>?

    init(
        hitTest: @escaping @MainActor (CGPoint) -> WindowDragTarget.Hit? = WindowDragTarget.hit,
        resolve: @escaping @MainActor (WindowDragTarget.Hit, CGPoint) -> WindowDragTarget? = WindowDragTarget.resolve
    ) {
        self.hitTest = hitTest
        self.resolve = resolve
    }

    // true 表示该鼠标事件已由拖动处理。flagsChanged 始终传给系统。
    func consumes(_ type: CGEventType, event: CGEvent, modifier: WindowDragModifier, forward: (CGEvent) -> Void) -> Bool
    {
        let matches = modifier.matches(event.flags)
        switch type {
        case .leftMouseDown:
            reset(forward: forward)
            guard matches, let hit = hitTest(event.location), let down = event.copy() else { return false }
            phase = .pending(down, hit)
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
            case .pending(let down, let hit):
                if released { return false }  // reset 会在原 mouseUp 之前补发 mouseDown。
                let dx = event.location.x - down.location.x
                let dy = event.location.y - down.location.y
                guard dx * dx + dy * dy >= 9 else { return true }
                guard let target = resolve(hit, down.location) else {
                    reset(forward: forward)
                    return false
                }
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
        case .pending(let down, _):
            phase = .idle
            forward(down)
        case .moving:
            flush()
            phase = .untilMouseUp
        case .idle, .untilMouseUp:
            break
        }
    }

    func reset(forward: (CGEvent) -> Void) {
        if case .pending(let down, _) = phase { forward(down) }
        phase = .idle
        latestPosition = nil
        lastWritten = nil
        nextWrite = nil
        delivery?.cancel()
        delivery = nil
    }
}
