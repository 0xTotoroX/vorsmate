// [INPUT]: 已确认的窗口编号、标题栏落点和原始左键按下事件的副本。
// [OUTPUT]: 同一窗口的标题栏按下、连续拖动和提前松手事件。
// [POS]: 确认起拖后由事件线程独占，持续移动只换算坐标。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Foundation

struct WindowTitleDrag: @unchecked Sendable {
    private let down: CGEvent
    private let window: CGWindowID
    private let offset: CGVector
    private var lastPoint: CGPoint

    init(down: CGEvent, title: CGPoint, window: CGWindowID) {
        self.down = down
        self.window = window
        offset = CGVector(dx: title.x - down.location.x, dy: title.y - down.location.y)
        lastPoint = title
    }

    mutating func begin(with drag: CGEvent, post: (CGEvent) -> Void) {
        rewrite(down, at: lastPoint)
        post(down)
        // 系统以首个拖动采样建立抓取点。先交付零位移，保留确认手势前已走过的距离。
        if let anchor = drag.copy() {
            rewrite(anchor, at: lastPoint)
            anchor.setIntegerValueField(.mouseEventDeltaX, value: 0)
            anchor.setIntegerValueField(.mouseEventDeltaY, value: 0)
            post(anchor)
        }
        update(drag)
    }

    mutating func update(_ event: CGEvent) {
        lastPoint = CGPoint(x: event.location.x + offset.dx, y: event.location.y + offset.dy)
        rewrite(event, at: lastPoint)
    }

    func end(at timestamp: CGEventTimestamp, post: (CGEvent) -> Void) {
        guard let up = down.copy() else { return }
        up.type = .leftMouseUp
        up.timestamp = timestamp
        up.setDoubleValueField(.mouseEventPressure, value: 0)
        rewrite(up, at: lastPoint)
        post(up)
    }

    private func rewrite(_ event: CGEvent, at point: CGPoint) {
        event.location = point
        event.flags.subtract([.maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn])
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
    }
}
