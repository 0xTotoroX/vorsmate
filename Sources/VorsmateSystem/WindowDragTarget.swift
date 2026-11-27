// [INPUT]: Quartz 全局坐标、WindowServer 的命中窗口和辅助功能窗口位置。
// [OUTPUT]: 可用的原生标题栏落点、原始窗口位置和有时限的移动回退。
// [POS]: 窗口拖动的系统边界，仅处理指针按下时命中的可移动窗口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices

@MainActor
struct WindowDragTarget {
    enum MoveResult {
        case moved, busy, unavailable
    }

    private static let timeout: Float = 0.04

    let origin: CGPoint
    var titleBarPoint: CGPoint? = nil
    let move: (CGPoint) -> MoveResult

    struct Hit {
        let number: CGWindowID
        let pid: pid_t
        var bounds: CGRect? = nil
    }

    private static func windowNumber(at point: CGPoint) -> CGWindowID? {
        let number = NSWindow.windowNumber(at: appKitPoint(point), belowWindowWithWindowNumber: 0)
        guard number > 0 else { return nil }
        return CGWindowID(exactly: number)
    }

    static func hit(at point: CGPoint) -> Hit? {
        guard let number = windowNumber(at: point),
            let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?.first,
            let pid = info[kCGWindowOwnerPID as String] as? pid_t,
            let level = info[kCGWindowLayer as String] as? Int,
            (NSWindow.Level.normal.rawValue...NSWindow.Level.modalPanel.rawValue).contains(level)
        else { return nil }

        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        }
        return Hit(number: number, pid: pid, bounds: bounds)
    }

    static func resolve(_ hitWindow: Hit, at point: CGPoint) -> Self? {
        guard windowNumber(at: point) == hitWindow.number else { return nil }
        if hitWindow.pid == getpid() {
            guard let window = NSApp.window(withWindowNumber: Int(hitWindow.number)), window.isMovable,
                window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen)
            else { return nil }
            let origin = appKitPoint(CGPoint(x: window.frame.minX, y: window.frame.maxY))
            let title = titleBarPoint(in: hitWindow, origin: origin) { point in
                let local = window.convertPoint(fromScreen: appKitPoint(point))
                guard !window.contentLayoutRect.contains(local), let frame = window.contentView?.superview else {
                    return false
                }
                var view = frame.hitTest(local)
                while let current = view {
                    if current is NSControl { return false }
                    view = current.superview
                }
                return true
            }
            return Self(origin: origin, titleBarPoint: title) { [weak window] position in
                guard let window, window.isVisible else { return .unavailable }
                window.setFrameTopLeftPoint(appKitPoint(position))
                return .moved
            }
        }

        // 针对目标进程限时，避免改变宿主其他辅助功能模块的全局超时。
        let app = AXUIElementCreateApplication(hitWindow.pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit
        else { return nil }
        AXUIElementSetMessagingTimeout(hit, timeout)
        let window: AXUIElement
        if let value = attribute(kAXWindowAttribute, of: hit), CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = value as! AXUIElement
        } else if attribute(kAXRoleAttribute, of: hit) as? String == kAXWindowRole {
            window = hit
        } else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, timeout)
        var owner: pid_t = 0
        var writable = DarwinBoolean(false)
        var origin = CGPoint.zero
        guard AXUIElementGetPid(window, &owner) == .success, owner == hitWindow.pid,
            attribute("AXFullScreen", of: window) as? Bool != true,
            AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &writable) == .success,
            writable.boolValue, let value = attribute(kAXPositionAttribute, of: window),
            CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        else { return nil }
        let title = externalTitleBarPoint(in: hitWindow, origin: origin, app: app, window: window)
        return Self(origin: origin, titleBarPoint: title) { position in
            var position = position
            guard let value = AXValueCreate(.cgPoint, &position) else { return .unavailable }
            switch AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) {
            case .success: return .moved
            case .cannotComplete: return .busy
            default: return .unavailable
            }
        }
    }

    private static func externalTitleBarPoint(
        in hit: Hit, origin: CGPoint, app: AXUIElement, window: AXUIElement
    ) -> CGPoint? {
        let titleElement = attribute(kAXTitleUIElementAttribute, of: window)
        guard titleElement != nil || attribute(kAXCloseButtonAttribute, of: window) != nil else { return nil }
        return titleBarPoint(in: hit, origin: origin) { point in
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
                let element
            else { return false }
            if CFEqual(element, window) { return true }
            AXUIElementSetMessagingTimeout(element, timeout)
            let role = attribute(kAXRoleAttribute, of: element) as? String
            if role == kAXStaticTextRole, let titleElement { return CFEqual(element, titleElement) }
            guard role == kAXToolbarRole, let owner = attribute(kAXWindowAttribute, of: element) else { return false }
            return CFEqual(owner, window)
        }
    }

    private static func titleBarPoint(in hit: Hit, origin: CGPoint, accepts: (CGPoint) -> Bool) -> CGPoint? {
        guard var frame = hit.bounds, frame.width >= 100, frame.height >= 28 else { return nil }
        frame.origin = origin
        // 顶边留出调整大小区域，左右留出交通灯和工具栏按钮。
        for fraction in [0.5, 0.75, 0.32, 0.85] {
            let point = CGPoint(x: frame.minX + max(75, frame.width * fraction), y: frame.minY + 10)
            if point.x < frame.maxX - 12, windowNumber(at: point) == hit.number, accepts(point) { return point }
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func appKitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }
}
