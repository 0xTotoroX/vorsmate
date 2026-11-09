// [INPUT]: Carbon Text Input Source Services、AppKit 工作区通知。
// [OUTPUT]: 输入源枚举、切换、选择与可用列表变化通知。
// [POS]: SourceDriver 的输入法实现；仅访问公开输入源，不监听键盘内容。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Carbon.HIToolbox
import VorsmateCore

@MainActor
public final class InputSourceDriver: SourceDriver {
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    public init() {}

    private func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    private func boolean(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
    private func sources() -> [TISInputSource] {
        let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        return list.filter {
            string($0, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String
                && boolean($0, kTISPropertyInputSourceIsSelectCapable)
                && boolean($0, kTISPropertyInputSourceIsEnabled)
        }
    }
    public func read() throws -> Snapshot {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let values = sources().compactMap { source -> Source? in
            guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
            return Source(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }
        return Snapshot(sources: values, selectedID: string(current, kTISPropertyInputSourceID))
    }
    public func select(_ id: String) throws {
        guard let source = sources().first(where: { string($0, kTISPropertyInputSourceID) == id }) else {
            throw SystemFailure.unavailable
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw SystemFailure.status("切换输入法", status) }
    }
    public func start(onChange: @escaping @MainActor () -> Void) throws {
        stop()
        for name in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged] {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name! as String), object: nil, queue: .main
            ) { _ in Task { @MainActor in onChange() } }
            distributedObservers.append(token)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in Task { @MainActor in onChange() } }
            workspaceObservers.append(token)
        }
    }
    public func stop() {
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
    }
}
