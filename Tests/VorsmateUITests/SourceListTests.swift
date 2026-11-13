// [INPUT]: 原生 SourceListView、合成鼠标事件和内存优先级。
// [OUTPUT]: 即时起拖、一次落位、点击分离、取消和外部更新的行为回归。
// [POS]: AppKit 事件层验证；不启动应用管理、不访问真实设备或用户配置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Testing
import VorsmateCore
import VorsmateSystem

@testable import Vorsmate

@MainActor
private final class ListDriver: SourceDriver {
    var snapshot = Snapshot(sources: ["a", "b", "c"].map { Source(id: $0, name: $0.uppercased()) })
    func read() throws -> Snapshot { snapshot }
    func select(_ id: String) throws { snapshot.selectedID = id }
    func start(onChange: @escaping @MainActor () -> Void) throws {}
    func stop() {}
}

@Suite("列表拖动", .serialized)
@MainActor
struct SourceListTests {
    private func list() -> SourceListView {
        let list = SourceListView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        let sources = ["a", "b", "c"].map { Source(id: $0, name: $0.uppercased()) }
        list.apply(policy: SelectionPolicy(enabled: true, priority: sources), snapshot: Snapshot(sources: sources))
        return list
    }
    private func event(_ type: NSEvent.EventType, x: CGFloat = 80, y: CGFloat, time: Double) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 132 - y), modifierFlags: [], timestamp: time,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("移动三点即起拖，鼠标跟随和让位不保存，松手只提交一次且不触发选择")
    func immediateDrag() {
        let list = list()
        var moves: [(Int, Int)] = []
        var selected: [String] = []
        list.reorder = { moves.append(($0, $1)) }
        list.choose = { selected.append($0) }
        list.mouseDown(with: event(.leftMouseDown, y: 110, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 106, time: 1.01))
        #expect(list.draggingID == "c")
        list.mouseDragged(with: event(.leftMouseDragged, y: 22, time: 1.05))
        #expect(list.displayedIDs == ["c", "a", "b"])
        #expect(moves.isEmpty)
        list.mouseUp(with: event(.leftMouseUp, y: 22, time: 1.06))
        #expect(moves.count == 1)
        #expect(moves.first?.0 == 2)
        #expect(moves.first?.1 == 0)
        #expect(selected.isEmpty)
        #expect(list.draggingID == nil)
    }

    @Test("短点击选择，轻微抖动不变成排序")
    func click() {
        let list = list()
        var selected: [String] = []
        var moves = 0
        list.choose = { selected.append($0) }
        list.reorder = { _, _ in moves += 1 }
        list.mouseDown(with: event(.leftMouseDown, y: 66, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 67, time: 1.01))
        list.mouseUp(with: event(.leftMouseUp, y: 67, time: 1.02))
        #expect(selected == ["b"])
        #expect(moves == 0)
    }

    @Test("Escape、列表外松手、视图关闭都取消预览", arguments: ["escape", "outside", "close"])
    func cancel(reason: String) {
        let list = list()
        var moves = 0
        list.reorder = { _, _ in moves += 1 }
        list.mouseDown(with: event(.leftMouseDown, y: 22, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 110, time: 1.02))
        #expect(list.displayedIDs == ["b", "c", "a"])
        if reason == "escape" { list.cancelOperation(nil) }
        if reason == "outside" { list.mouseUp(with: event(.leftMouseUp, x: 350, y: 110, time: 1.03)) }
        if reason == "close" { list.viewWillMove(toWindow: nil) }
        #expect(moves == 0)
        #expect(list.displayedIDs == ["a", "b", "c"])
        #expect(list.draggingID == nil)
    }

    @Test("向下拖到底使用正确插入位置，保存失败后回到持久顺序")
    func failedSave() {
        let list = list()
        var moves = 0
        list.reorder = { from, to in
            #expect(from == 0 && to == 3)
            moves += 1
            let sources = ["a", "b", "c"].map { Source(id: $0, name: $0.uppercased()) }
            list.apply(policy: SelectionPolicy(enabled: true, priority: sources), snapshot: Snapshot(sources: sources))
        }
        list.mouseDown(with: event(.leftMouseDown, y: 22, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 110, time: 1.02))
        list.mouseUp(with: event(.leftMouseUp, y: 110, time: 1.03))
        #expect(moves == 1)
        #expect(list.displayedIDs == ["a", "b", "c"])
    }

    @Test("回读不打断拖动，外部顺序变化取消过时手势")
    func refresh() {
        let list = list()
        var moves = 0
        list.reorder = { _, _ in moves += 1 }
        let sources = ["a", "b", "c"].map { Source(id: $0, name: $0.uppercased()) }
        list.mouseDown(with: event(.leftMouseDown, y: 110, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 22, time: 1.02))
        list.apply(
            policy: SelectionPolicy(enabled: true, priority: sources),
            snapshot: Snapshot(sources: sources, selectedID: "b"))
        #expect(list.draggingID == "c")
        #expect(list.displayedIDs == ["c", "a", "b"])
        list.apply(
            policy: SelectionPolicy(enabled: true, priority: Array(sources.reversed())),
            snapshot: Snapshot(sources: sources))
        list.mouseUp(with: event(.leftMouseUp, y: 22, time: 1.03))
        #expect(list.draggingID == nil)
        #expect(list.displayedIDs == ["c", "b", "a"])
        #expect(moves == 0)
    }

    @Test("长列表拖到边缘自动滚动，滚动中不保存")
    func autoscroll() {
        let list = list()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        scroll.documentView = list
        let sources = (0..<8).map { Source(id: String($0), name: "设备 \($0)") }
        list.apply(policy: SelectionPolicy(priority: sources), snapshot: Snapshot(sources: sources))
        var saves = 0
        list.reorder = { _, _ in saves += 1 }
        func localEvent(_ type: NSEvent.EventType, y: CGFloat, time: Double) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: list.convert(NSPoint(x: 80, y: y), to: nil),
                modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        list.mouseDown(with: localEvent(.leftMouseDown, y: 22, time: 1))
        list.mouseDragged(with: localEvent(.leftMouseDragged, y: 128, time: 1.03))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(saves == 0)
        list.cancelOperation(nil)
        #expect(list.draggingID == nil)
        #expect(list.displayedIDs == sources.map(\.id))
    }

    @Test("控制器先更新而界面尚未刷新时，旧下标不能提交到新配置")
    func staleBridge() {
        let driver = ListDriver()
        var saves = 0
        let controller = ChannelController(
            channel: .audioInput, driver: driver, policy: SelectionPolicy(priority: driver.snapshot.sources),
            persist: { _ in saves += 1 })
        defer { controller.stop() }
        controller.refresh(readOnly: true)
        let list = list()
        SourceList(controller: controller).configure(list)
        list.mouseDown(with: event(.leftMouseDown, y: 110, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 22, time: 1.02))
        let updated = SelectionPolicy(priority: Array(driver.snapshot.sources.reversed()))
        controller.reload(updated)
        list.mouseUp(with: event(.leftMouseUp, y: 22, time: 1.03))
        #expect(saves == 0)
        #expect(controller.policy == updated)
        #expect(list.displayedIDs == ["c", "b", "a"])
    }

    @Test("离线移除只在行静止时命中，落位动画中不误删")
    func movingRemoveButton() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        let row = SourceRow()
        parent.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        row.configure(source: Source(id: "a", name: "A"), index: 0, online: false, snapshot: Snapshot(), lockedID: nil)
        row.layoutSubtreeIfNeeded()
        let button = row.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first!
        func point() -> NSPoint { button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: parent) }
        #expect(row.hitTest(point()) === button)
        row.move(to: 44, animated: true)
        #expect(row.hitTest(point()) == nil)
        row.layer?.removeAllAnimations()
        #expect(row.hitTest(point()) === button)
    }

    @Test("窗口关闭但内容仍保留时，取消拖动而不提交")
    func retainedWindowCloses() {
        _ = NSApplication.shared
        let list = list()
        let window = NSWindow(
            contentRect: list.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        var saves = 0
        list.reorder = { _, _ in saves += 1 }
        list.mouseDown(with: event(.leftMouseDown, y: 110, time: 1))
        list.mouseDragged(with: event(.leftMouseDragged, y: 22, time: 1.02))
        #expect(list.draggingID != nil)
        window.close()
        #expect(list.draggingID == nil)
        #expect(list.displayedIDs == ["a", "b", "c"])
        #expect(saves == 0)
    }
}
