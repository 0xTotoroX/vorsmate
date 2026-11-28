// [INPUT]: Quartz 左键和修饰键事件、宿主的起拖判定与权限生命周期。
// [OUTPUT]: 普通事件透传，已接管的标题栏事件直接送交系统。
// [POS]: 独立交互线程承载事件端口，主线程只处理起拖判定和兼容回退。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Foundation
import VorsmateCore

struct WindowDragDecision: @unchecked Sendable {
    var consumed = false
    var tracking = false
    var replay: [CGEvent] = []
    var native: WindowTitleDrag?
}

final class WindowDragEventTap {
    typealias Decide = @MainActor @Sendable (CGEventType, CGEvent, WindowDragModifier) -> WindowDragDecision

    let port: CFMachPort
    private let worker: Worker

    init?(
        modifier: WindowDragModifier, decide: @escaping Decide,
        recover: @escaping @MainActor @Sendable () -> Void
    ) {
        let worker = Worker(modifier: modifier, decide: decide, recover: recover)
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { proxy, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let worker = Unmanaged<Worker>.fromOpaque(context).takeUnretainedValue()
                    let consumed = worker.consume(type, event: event) { $0.tapPostEvent(proxy) }
                    return consumed ? nil : Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(worker).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        else { return nil }
        self.port = port
        self.worker = worker
        worker.start(port, source: source)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func setModifier(_ value: WindowDragModifier) {
        worker.perform { worker in
            worker.endNative()
            worker.modifier = value
        }
    }

    deinit {
        CGEvent.tapEnable(tap: port, enable: false)
        worker.perform { worker in
            worker.endNative()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    // 手势状态由事件线程独占。两线程只在启动时交接 runLoop，后续命令均投递到该循环。
    private final class Worker: @unchecked Sendable {
        private static let releaseMarker: Int64 = 0x564F_5253_4452_4147
        // 副本只交给主线程，系统回调中的原事件仍由本线程持有。
        private struct Snapshot: @unchecked Sendable { let event: CGEvent }
        let decide: Decide
        let recover: @MainActor @Sendable () -> Void
        var modifier: WindowDragModifier
        var native: WindowTitleDrag?
        var tracking = false
        var untilUp = false
        private let ready = DispatchSemaphore(value: 0)
        private var loop: CFRunLoop!
        private var source: CFRunLoopSource!
        private var port: CFMachPort!

        init(modifier: WindowDragModifier, decide: @escaping Decide, recover: @escaping @MainActor @Sendable () -> Void)
        {
            self.modifier = modifier
            self.decide = decide
            self.recover = recover
        }

        func start(_ port: CFMachPort, source: CFRunLoopSource) {
            self.port = port
            self.source = source
            let thread = Thread { [self] in
                loop = CFRunLoopGetCurrent()
                CFRunLoopAddSource(loop, self.source, .commonModes)
                ready.signal()
                CFRunLoopRun()
                endNative()
                CFRunLoopSourceInvalidate(self.source)
                CFMachPortInvalidate(self.port)
            }
            thread.name = "Vorsmate.WindowDrag"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
        }

        func perform(_ action: @escaping @Sendable (Worker) -> Void) {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { action(self) }
            CFRunLoopWakeUp(loop)
        }

        func endNative() {
            if let native {
                native.end(at: DispatchTime.now().uptimeNanoseconds) {
                    $0.setIntegerValueField(.eventSourceUserData, value: Self.releaseMarker)
                    $0.post(tap: .cgSessionEventTap)
                }
                self.native = nil
                untilUp = true
            }
        }

        func consume(_ type: CGEventType, event: CGEvent, post: (CGEvent) -> Void) -> Bool {
            if type == .leftMouseUp, event.getIntegerValueField(.eventSourceUserData) == Self.releaseMarker {
                return false
            }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                endNative()
                tracking = false
                DispatchQueue.main.async { self.recover() }
                return false
            }
            if type == .leftMouseDown {
                native?.end(at: event.timestamp, post: post)
                native = nil
                untilUp = false
            }
            if var session = native {
                if !modifier.matches(event.flags) {
                    session.end(at: event.timestamp, post: post)
                    native = nil
                    untilUp = true
                } else if type == .leftMouseDragged || type == .leftMouseUp {
                    session.update(event)
                    native = type == .leftMouseUp ? nil : session
                    return false
                } else {
                    return false
                }
            }
            if untilUp {
                if type == .leftMouseUp { untilUp = false }
                return type == .leftMouseDragged || type == .leftMouseUp
            }
            guard tracking || (type == .leftMouseDown && modifier.matches(event.flags)) else { return false }
            guard let copy = event.copy() else { return false }
            let snapshot = Snapshot(event: copy)
            let trigger = modifier
            let result = DispatchQueue.main.sync { decide(type, snapshot.event, trigger) }
            result.replay.forEach(post)
            tracking = result.tracking
            if var session = result.native {
                session.begin(with: event, post: post)
                native = session
                return false
            }
            return result.consumed
        }
    }
}
