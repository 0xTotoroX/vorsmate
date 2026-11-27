// [INPUT]: ApplicationServices 辅助功能元素、CoreGraphics 键盘事件与 Security 代码签名核验。
// [OUTPUT]: Apple 系统进程验签、有界 AX 弹窗/弹层遍历、窗口存活判定与受控键盘提交辅助函数。
// [POS]: VorsmateSystem 无人值守授权底层 AX / 签名工具；仅供 SystemUnattendedAuthDriver 调用，不读取密码框内容。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

struct UnattendedAuthInspectedDialog {
    let texts: [String]
    let passwordField: AXUIElement?
    let approveButton: AXUIElement?
    let usePasswordButton: AXUIElement?
}

enum UnattendedAuthAX {
    private static let approveButtonTitles: Set<String> = [
        "好", "允许", "允许访问", "修改设置", "更新设置", "解锁", "安装软件", "安装帮助程序", "继续", "批准",
        "OK", "Allow", "Allow Access", "Modify Settings", "Update Settings", "Unlock", "Install Software",
        "Install Helper", "Continue", "Approve",
    ]
    private static let usePasswordButtonTitles: Set<String> = [
        "使用密码…", "使用密码...", "使用密码", "Use Password…", "Use Password...", "Use Password",
    ]

    static func isVerifiedAppleProcess(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    static func inspectWindow(_ window: AXUIElement) -> UnattendedAuthInspectedDialog {
        var texts: [String] = []
        var passwordField: AXUIElement?
        var approveButton: AXUIElement? = copyElementAttribute(window, kAXDefaultButtonAttribute)
        var usePasswordButton: AXUIElement?

        if let title = copyStringAttribute(window, kAXTitleAttribute), !title.isEmpty {
            texts.append(title)
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 200 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role = copyStringAttribute(node, kAXRoleAttribute) ?? ""
            let subrole = copyStringAttribute(node, kAXSubroleAttribute) ?? ""

            if role == kAXStaticTextRole {
                if let value = copyStringAttribute(node, kAXValueAttribute), !value.isEmpty {
                    texts.append(value)
                } else if let title = copyStringAttribute(node, kAXTitleAttribute), !title.isEmpty {
                    texts.append(title)
                }
            } else if role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole {
                // 绝不读取密码框内容，只记录控件引用。
                if passwordField == nil { passwordField = node }
            } else if role == kAXButtonRole {
                let title = copyStringAttribute(node, kAXTitleAttribute) ?? ""
                if usePasswordButton == nil && usePasswordButtonTitles.contains(title) {
                    usePasswordButton = node
                } else if approveButton == nil && approveButtonTitles.contains(title) {
                    approveButton = node
                }
            }

            guard depth < 8 else { continue }
            for child in copyChildren(node) {
                queue.append((child, depth + 1))
            }
        }

        return UnattendedAuthInspectedDialog(
            texts: deduplicatePreservingOrder(texts),
            passwordField: passwordField,
            approveButton: approveButton,
            usePasswordButton: usePasswordButton
        )
    }

    @MainActor
    static func windowPresence(_ target: AXUIElement, pid: pid_t) -> SystemUnattendedAuthDriver.WindowPresence {
        if NSRunningApplication(processIdentifier: pid)?.isTerminated == true {
            return .absent
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            return .absent
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let windowsErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        var matchesWindowsOrSheets = false
        if windowsErr == .success, let windows = windowsValue as? [AXUIElement] {
            if windows.contains(where: { CFEqual($0, target) }) {
                matchesWindowsOrSheets = true
            } else {
                for window in windows where copySheets(window).contains(where: { CFEqual($0, target) }) {
                    matchesWindowsOrSheets = true
                    break
                }
            }
        }

        var focusedValue: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        let matchesFocused =
            focusedErr == .success
            && focusedValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, target) } == true

        var mainValue: CFTypeRef?
        let mainErr = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainValue)
        let matchesMain =
            mainErr == .success
            && mainValue.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, target) } == true

        return SystemUnattendedAuthDriver.classifyWindowPresence(
            processTerminated: false,
            windowsError: windowsErr,
            matchesWindowsOrSheets: matchesWindowsOrSheets,
            focusedError: focusedErr,
            matchesFocused: matchesFocused,
            mainError: mainErr,
            matchesMain: matchesMain)
    }

    static func collectSheets(of appElement: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        {
            for window in windows {
                for sheet in copySheets(window) where !result.contains(where: { CFEqual($0, sheet) }) {
                    result.append(sheet)
                }
            }
        }
        if let focused = copyElementAttribute(appElement, kAXFocusedWindowAttribute),
            copyStringAttribute(focused, kAXRoleAttribute) == kAXSheetRole,
            !result.contains(where: { CFEqual($0, focused) })
        {
            result.append(focused)
        }
        return result
    }

    static func copySheets(_ window: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &value) == .success,
            let sheets = value as? [AXUIElement]
        {
            result.append(contentsOf: sheets)
        }
        for child in copyChildren(window) where copyStringAttribute(child, kAXRoleAttribute) == kAXSheetRole {
            if !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    static func typePasswordAndReturn(_ password: String, into field: AXUIElement, pid: pid_t) -> Bool {
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let utf16 = Array(password.utf16)
        for codeUnit in utf16 {
            var unit = codeUnit
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return submitReturnKey(to: pid, focus: field)
    }

    static func submitReturnKey(to pid: pid_t, focus: AXUIElement) -> Bool {
        _ = AXUIElementSetAttributeValue(focus, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return false }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private static func deduplicatePreservingOrder(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
