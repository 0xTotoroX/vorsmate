// [INPUT]: ChannelController 的优先级、系统回读和原子保存动作。
// [OUTPUT]: 三通道共用的即时拖动、柔和吸附、点击选择与离线移除。
// [POS]: AppKit 滚动列表桥；拖动只预览位置，松手提交一次，不访问硬件或剪贴板。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct SourceList: NSViewRepresentable {
    @ObservedObject var controller: ChannelController

    func makeNSView(context: Context) -> NSScrollView {
        let list = SourceListView(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        list.autoresizingMask = .width
        list.setAccessibilityLabel("\(controller.channel.title)列表，可直接拖动排序")
        list.setAccessibilityIdentifier("sources.\(controller.channel.rawValue)")
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        configure(list)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let list = scroll.documentView as? SourceListView else { return }
        configure(list)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? SourceListView)?.cancelInteraction()
    }

    func configure(_ list: SourceListView) {
        list.choose = { [weak controller] id in controller?.select(id) }
        list.forget = { [weak controller] id in controller?.forget(id) }
        list.reorder = { [weak controller, weak list, expected = controller.policy] from, destination in
            guard let controller else { return }
            // 控制器可能已更新而 SwiftUI 尚未重绘；不能把旧下标套进新顺序。
            if controller.policy == expected {
                controller.move(fromOffsets: IndexSet(integer: from), toOffset: destination)
            }
            // 保存失败或无变化时也回读，不能把本地预览当作已经保存。
            list?.apply(policy: controller.policy, snapshot: controller.snapshot)
        }
        list.apply(policy: controller.policy, snapshot: controller.snapshot)
    }
}

@MainActor
final class SourceListView: NSView {
    static let rowHeight: CGFloat = 44
    var choose: ((String) -> Void)?
    var forget: ((String) -> Void)?
    var reorder: ((Int, Int) -> Void)?
    private(set) var displayedIDs: [String] = []
    private(set) var draggingID: String?
    private var policy = SelectionPolicy()
    private var snapshot = Snapshot()
    private var rows: [String: SourceRow] = [:]
    private var press: Press?
    private var scrollTimer: Timer?
    private var lastDragEvent: NSEvent?
    private var focusedID: String?
    private var keyboardFocus = false

    private struct Press {
        let id: String
        let location: NSPoint
        let offset: CGFloat
        var previousY: CGFloat
        var previousTime: TimeInterval
        var velocity: CGFloat = 0
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(policy next: SelectionPolicy, snapshot: Snapshot) {
        if next != policy, press != nil { finishDrag(commit: false) }
        policy = next
        self.snapshot = snapshot
        if draggingID == nil { displayedIDs = policy.priority.map(\.id) }
        let wanted = Set(displayedIDs)
        for id in Array(rows.keys) where !wanted.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for (index, source) in policy.priority.enumerated() {
            let row: SourceRow
            if let existing = rows[source.id] {
                row = existing
            } else {
                row = SourceRow()
                rows[source.id] = row
                addSubview(row)
                row.frame = NSRect(
                    x: 3, y: CGFloat(index) * Self.rowHeight, width: bounds.width - 6, height: Self.rowHeight)
            }
            let online = snapshot.sources.contains { $0.id == source.id }
            row.configure(source: source, index: index, online: online, snapshot: snapshot, lockedID: policy.lockedID)
            row.onRemove = { [weak self] in self?.forget?(source.id) }
            row.onChoose = { [weak self] in self?.select(source.id) }
            row.onMove = { [weak self] step in self?.move(source.id, by: step) }
        }
        if let focusedID, !wanted.contains(focusedID) { self.focusedID = nil }
        setFrameSize(NSSize(width: frame.width, height: CGFloat(displayedIDs.count) * Self.rowHeight))
        positionRows(animated: window != nil)
    }

    override func layout() {
        super.layout()
        for row in rows.values { row.setFrameSize(NSSize(width: max(0, bounds.width - 6), height: Self.rowHeight)) }
    }

    private func positionRows(animated: Bool) {
        for (index, id) in displayedIDs.enumerated() where id != draggingID {
            rows[id]?.move(to: CGFloat(index) * Self.rowHeight, animated: animated)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        finishDrag(commit: false)
        let point = convert(event.locationInWindow, from: nil)
        // 命中当前屏幕位置，落位动画尚未结束也能立即重新抓住。
        guard let id = displayedIDs.reversed().first(where: { rows[$0]?.visibleFrame.contains(point) == true }),
            let row = rows[id]
        else { return }
        window?.makeFirstResponder(self)
        keyboardFocus = false
        focusedID = id
        press = Press(
            id: id, location: point, offset: point.y - row.visibleFrame.minY,
            previousY: point.y, previousTime: event.timestamp)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if draggingID == nil {
            guard hypot(point.x - press.location.x, point.y - press.location.y) >= 3 else { return }
            draggingID = press.id
            rows[press.id]?.setLifted(true)
            startAutoscroll()
        }
        let elapsed = event.timestamp - press.previousTime
        if elapsed > 0 { press.velocity = (point.y - press.previousY) / elapsed }
        press.previousY = point.y
        press.previousTime = event.timestamp
        self.press = press
        lastDragEvent = event
        updateDrag(at: point)
    }

    private func updateDrag(at point: NSPoint) {
        guard let press, draggingID != nil, !displayedIDs.isEmpty else { return }
        let y = min(max(point.y - press.offset, -6), bounds.height - Self.rowHeight + 6)
        rows[press.id]?.move(to: y, animated: false)
        let index = min(max(Int((y / Self.rowHeight).rounded()), 0), displayedIDs.count - 1)
        var next = displayedIDs.filter { $0 != press.id }
        next.insert(press.id, at: index)
        if next != displayedIDs {
            displayedIDs = next
            positionRows(animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if draggingID != nil {
            finishDrag(commit: bounds.intersection(visibleRect).contains(point), time: event.timestamp)
        } else {
            self.press = nil
            if rows[press.id]?.visibleFrame.contains(point) == true { select(press.id) }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if press != nil { finishDrag(commit: false) } else { super.cancelOperation(sender) }
    }

    func cancelInteraction() { finishDrag(commit: false) }

    private func finishDrag(commit: Bool, time: TimeInterval = 0) {
        scrollTimer?.invalidate()
        scrollTimer = nil
        lastDragEvent = nil
        guard let press else { return }
        let wasDragging = draggingID != nil
        self.press = nil
        draggingID = nil
        rows[press.id]?.setLifted(false)
        let original = policy.priority.map(\.id)
        let from = original.firstIndex(of: press.id)
        let to = displayedIDs.firstIndex(of: press.id)
        let velocity = time - press.previousTime < 0.1 ? min(max(press.velocity * 0.3, -220), 220) : 0
        if wasDragging, commit, let from, let to, from != to {
            rows[press.id]?.move(to: CGFloat(to) * Self.rowHeight, animated: true, velocity: velocity)
            reorder?(from, to > from ? to + 1 : to)
        } else {
            displayedIDs = original
        }
        positionRows(animated: true)
    }

    private func startAutoscroll() {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.scrollWhileDragging() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func scrollWhileDragging() {
        guard let event = lastDragEvent, draggingID != nil, let clip = enclosingScrollView?.contentView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let visible = visibleRect
        guard point.x >= visible.minX - 12, point.x <= visible.maxX + 12 else { return }
        let delta: CGFloat
        if point.y < visible.minY + 20 { delta = -6 } else if point.y > visible.maxY - 20 { delta = 6 } else { return }
        let y = min(max(clip.bounds.minY + delta, 0), max(0, bounds.height - clip.bounds.height))
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    private func select(_ id: String) {
        guard snapshot.sources.contains(where: { $0.id == id }) else { return }
        choose?(id)
    }

    private func move(_ id: String, by step: Int) {
        guard let from = policy.priority.firstIndex(where: { $0.id == id }),
            policy.priority.indices.contains(from + step)
        else { return }
        finishDrag(commit: false)
        reorder?(from, step > 0 ? from + step + 1 : from + step)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, press != nil {
            finishDrag(commit: false)
            return
        }
        guard !displayedIDs.isEmpty else {
            super.keyDown(with: event)
            return
        }
        let current = displayedIDs.firstIndex(of: focusedID ?? "") ?? 0
        if event.keyCode == 125 || event.keyCode == 126 {
            let step = event.keyCode == 125 ? 1 : -1
            if event.modifierFlags.contains(.option) {
                focusedID = displayedIDs[current]
                move(displayedIDs[current], by: step)
            } else {
                focusedID = displayedIDs[min(max(current + step, 0), displayedIDs.count - 1)]
            }
            keyboardFocus = true
            if let focusedID, let row = rows[focusedID] { scrollToVisible(row.frame) }
            needsDisplay = true
        } else if event.keyCode == 36 || event.keyCode == 49 {
            select(displayedIDs[current])
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard keyboardFocus, window?.firstResponder === self, let focusedID, let row = rows[focusedID] else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(roundedRect: row.frame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        if newWindow == nil { finishDrag(commit: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverClosing(_:)), name: NSPopover.willCloseNotification, object: nil)
    }

    @objc private func windowClosing() { cancelInteraction() }
    @objc private func popoverClosing(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
            popover.contentViewController?.view.window === window
        else { return }
        cancelInteraction()
    }
}
