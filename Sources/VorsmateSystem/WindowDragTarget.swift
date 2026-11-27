// [INPUT]: Quartz 全局坐标、WindowServer 的命中窗口和辅助功能窗口位置。
// [OUTPUT]: 原始窗口位置与有时限的位置写入；不移动光标，不激活其他应用。
// [POS]: 窗口拖动的系统边界，仅处理指针按下时命中的可移动窗口。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices

@MainActor
struct WindowDragTarget {
    let origin: CGPoint
    let move: (CGPoint) -> Bool

    struct Hit {
        let number: CGWindowID
        let pid: pid_t
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

        return Hit(number: number, pid: pid)
    }

    static func resolve(_ hitWindow: Hit, at point: CGPoint) -> Self? {
        guard windowNumber(at: point) == hitWindow.number else { return nil }
        if hitWindow.pid == getpid() {
            guard let window = NSApp.window(withWindowNumber: Int(hitWindow.number)), window.isMovable,
                window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen)
            else { return nil }
            let origin = appKitPoint(CGPoint(x: window.frame.minX, y: window.frame.maxY))
            return Self(origin: origin) { [weak window] position in
                guard let window, window.isVisible else { return false }
                window.setFrameTopLeftPoint(appKitPoint(position))
                return true
            }
        }

        // 针对目标进程限时，避免改变宿主其他辅助功能模块的全局超时。
        let app = AXUIElementCreateApplication(hitWindow.pid)
        let timeout: Float = 0.04
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
        return Self(origin: origin) { position in
            var position = position
            guard let value = AXValueCreate(.cgPoint, &position) else { return false }
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        }
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func appKitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }
}
