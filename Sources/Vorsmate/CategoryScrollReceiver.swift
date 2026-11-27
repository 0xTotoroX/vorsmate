// [INPUT]: 本面板总览窗口内的 AppKit 水平滚动与轻扫事件。
// [OUTPUT]: 每次有明确横向意图的手势最多移动一个分类；垂直滚动交回原控件。
// [POS]: PanelView 的透明背景，不接管点击、鼠标拖动或其他窗口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI

struct CategoryScrollGesture {
    private var totalX: CGFloat = 0
    private var totalY: CGFloat = 0
    private var vertical = false
    private var switched = false
    private var lastEvent: TimeInterval = -.infinity
    private var previousPrecision: Bool?

    // nil 放行事件，0 消费同一次手势的剩余量，±1 切换一次。
    mutating func scroll(
        x: CGFloat, y: CGFloat, precise: Bool, phase: NSEvent.Phase,
        momentum: NSEvent.Phase, at time: TimeInterval
    ) -> Int? {
        if !momentum.isEmpty { return switched ? 0 : nil }
        if !precise, phase.isEmpty, abs(y) > abs(x) {
            self = Self()
            return nil
        }
        let wheelReversed = !precise && switched && x * totalX < 0
        if phase.contains(.began) || previousPrecision != precise || wheelReversed
            || (phase.isEmpty && time - lastEvent > 0.24)
        {
            self = Self()
        }
        previousPrecision = precise
        lastEvent = time
        if phase.contains(.cancelled) || phase.contains(.ended) { return switched ? 0 : nil }
        if switched { return 0 }
        if vertical { return nil }

        totalX += x
        totalY += y
        if abs(totalY) > abs(totalX) * 1.35 && abs(totalY) >= (precise ? 6 : 0.5) {
            vertical = true
            return nil
        }
        guard abs(totalX) > abs(totalY) * 1.35 else { return nil }
        guard abs(totalX) >= (precise ? 24 : 0.5) else { return 0 }
        switched = true
        return totalX < 0 ? 1 : -1
    }

    mutating func swipe(x: CGFloat, y: CGFloat, at time: TimeInterval) -> Int? {
        guard abs(x) > abs(y) else { return nil }
        if switched && time - lastEvent < 0.3 { return 0 }
        switched = true
        lastEvent = time
        return x < 0 ? 1 : -1
    }
}

struct CategoryScrollReceiver: NSViewRepresentable {
    let move: (Int) -> Void

    func makeNSView(context: Context) -> Receiver { Receiver() }
    func updateNSView(_ view: Receiver, context: Context) { view.move = move }
    static func dismantleNSView(_ view: Receiver, coordinator: ()) { view.stopMonitoring() }

    final class Receiver: NSView {
        var move: ((Int) -> Void)?
        private var monitor: Any?
        private var gesture = CategoryScrollGesture()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) == true }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = CategoryScrollGesture()
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
                let point = location(of: event, in: window),
                bounds.contains(convert(point, from: nil)), NSEvent.pressedMouseButtons == 0,
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
            if let content = window.contentView {
                var hit = content.hitTest(content.convert(point, from: nil))
                while let view = hit {
                    if view is NSSlider { return false }
                    hit = view.superview
                }
            }
            let step: Int?
            if event.type == .swipe {
                step = gesture.swipe(x: event.deltaX, y: event.deltaY, at: event.timestamp)
            } else {
                step = gesture.scroll(
                    x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                    momentum: event.momentumPhase, at: event.timestamp)
            }
            guard let step else { return false }
            if step != 0 { move?(step) }
            return true
        }

        private func location(of event: NSEvent, in window: NSWindow) -> NSPoint? {
            if let target = event.window { return target === window ? event.locationInWindow : nil }
            // 部分滚轮事件只有屏幕坐标。确认实际接收窗口，再转换到面板坐标。
            let screenPoint = event.locationInWindow
            let targetNumber = event.cgEvent?.getIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            guard
                targetNumber == Int64(window.windowNumber)
                    || NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return nil }
            return window.convertPoint(fromScreen: screenPoint)
        }
    }
}
