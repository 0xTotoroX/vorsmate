// [INPUT]: Carbon.HIToolbox 全局热键接口与 TranslationShortcut 键位配置。
// [OUTPUT]: 线程安全的全局热键注册与回调分发；提供隔离预览替身。
// [POS]: 截图模块的全局快捷键桥接；模块停用时立即注销热键。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Carbon.HIToolbox
import Foundation
import VorsmateCore
import os

public enum TranslationHotKeyAction: UInt32, Equatable, Sendable {
    case screenshot = 1
}

@MainActor
public protocol TranslationHotKeyRegistrar: AnyObject {
    func apply(
        screenshot: TranslationShortcut,
        handler: @escaping @MainActor (TranslationHotKeyAction) -> Void
    ) -> [TranslationHotKeyAction]
    func unregisterAll()
}

@MainActor
public final class CarbonHotKeyCenter: TranslationHotKeyRegistrar {
    private static let signature: OSType = 0x5653_4D54  // "VSMT"

    private final class WeakBox: @unchecked Sendable {
        weak var center: CarbonHotKeyCenter?
        init(_ center: CarbonHotKeyCenter) { self.center = center }
    }

    private struct SendableOpaque: @unchecked Sendable {
        let raw: OpaquePointer
    }

    private struct RegistryState: @unchecked Sendable {
        var nextToken: UInt32 = 1
        var boxes: [UInt32: WeakBox] = [:]
    }

    private struct HandlesState: Sendable {
        var handlerRef: SendableOpaque?
        var hotKeyRefs: [UInt32: SendableOpaque] = [:]
    }

    private nonisolated static let registry = OSAllocatedUnfairLock(initialState: RegistryState())

    private let token: UInt32
    private let handles = OSAllocatedUnfairLock(initialState: HandlesState())
    private var handler: (@MainActor (TranslationHotKeyAction) -> Void)?

    public init() {
        let assigned = Self.registry.withLock { state -> UInt32 in
            let current = state.nextToken
            state.nextToken &+= 1
            if state.nextToken == 0 { state.nextToken = 1 }
            return current
        }
        self.token = assigned
        Self.registry.withLock { state in
            state.boxes[assigned] = WeakBox(self)
        }
    }

    deinit {
        _ = Self.registry.withLock { state in
            state.boxes.removeValue(forKey: token)
        }
        let state = handles.withLock { current -> HandlesState in
            let copy = current
            current = HandlesState()
            return copy
        }
        for ref in state.hotKeyRefs.values {
            UnregisterEventHotKey(ref.raw)
        }
        if let handlerRef = state.handlerRef {
            RemoveEventHandler(handlerRef.raw)
        }
    }

    public func apply(
        screenshot: TranslationShortcut,
        handler: @escaping @MainActor (TranslationHotKeyAction) -> Void
    ) -> [TranslationHotKeyAction] {
        unregisterAll()
        self.handler = handler

        guard screenshot.enabled && screenshot.isValid else { return [] }

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let action: TranslationHotKeyAction = .screenshot
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            screenshot.keyCode, screenshot.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            let wrapped = SendableOpaque(raw: ref)
            handles.withLock { $0.hotKeyRefs[action.rawValue] = wrapped }
            return []
        }
        return [action]
    }

    public func unregisterAll() {
        handler = nil
        let state = handles.withLock { current -> HandlesState in
            let copy = current
            current = HandlesState()
            return copy
        }
        for ref in state.hotKeyRefs.values {
            UnregisterEventHotKey(ref.raw)
        }
        if let handlerRef = state.handlerRef {
            RemoveEventHandler(handlerRef.raw)
        }
    }

    private func installHandlerIfNeeded() {
        let alreadyInstalled = handles.withLock { $0.handlerRef != nil }
        guard !alreadyInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let userData = UnsafeMutableRawPointer(bitPattern: Int(token))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard err == noErr, hotKeyID.signature == CarbonHotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let token = UInt32(truncatingIfNeeded: Int(bitPattern: userData))
                let center = CarbonHotKeyCenter.registry.withLock { $0.boxes[token]?.center }
                let rawID = hotKeyID.id
                Task { @MainActor [weak center] in
                    center?.dispatch(rawID: rawID)
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &ref)
        if status == noErr, let ref {
            let wrapped = SendableOpaque(raw: ref)
            handles.withLock { $0.handlerRef = wrapped }
        }
    }

    private func dispatch(rawID: UInt32) {
        guard let action = TranslationHotKeyAction(rawValue: rawID) else { return }
        handler?(action)
    }
}

@MainActor
public final class NoopHotKeyRegistrar: TranslationHotKeyRegistrar {
    public init() {}

    public func apply(
        screenshot: TranslationShortcut,
        handler: @escaping @MainActor (TranslationHotKeyAction) -> Void
    ) -> [TranslationHotKeyAction] {
        []
    }

    public func unregisterAll() {}
}
