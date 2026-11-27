// [INPUT]: 左键与修饰键事件、可替换的窗口命中与移动操作。
// [OUTPUT]: 拖动接管判定、原始点击还原、按指针偏移合并移动与松键收尾。
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
                guard target.move(position) else {
                    reset(forward: forward)
                    return false
                }
                lastWritten = position
                phase = .moving(
                    target, offset: CGPoint(x: target.origin.x - down.location.x, y: target.origin.y - down.location.y))
                return true
            case .moving(_, let offset):
                latestPosition = CGPoint(x: event.location.x + offset.x, y: event.location.y + offset.y)
                if released {
                    flush()
                } else if delivery == nil {
                    // 高频鼠标只保留最新绝对位置，松手同步写入终点。
                    delivery = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                        self.flush()
                    }
                }
                return true
            }
        default:
            return false
        }
    }

    private func flush() {
        delivery?.cancel()
        delivery = nil
        guard let position = latestPosition, case .moving(let target, _) = phase else { return }
        latestPosition = nil
        guard lastWritten != position else { return }
        if target.move(position) {
            lastWritten = position
        } else {
            phase = .untilMouseUp
        }
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
        delivery?.cancel()
        delivery = nil
    }
}
