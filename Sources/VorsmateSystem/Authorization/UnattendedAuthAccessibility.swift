// [INPUT]: ApplicationServices 辅助功能元素、CoreGraphics 键盘事件与 Security 代码签名核验。
// [OUTPUT]: Apple 系统进程验签、有界 AX 弹窗/弹层遍历、软件权限许可识别、窗口存活判定与受控键盘提交辅助函数。
// [POS]: VorsmateSystem 无人值守授权底层 AX / 签名工具；仅供 SystemUnattendedAuthDriver 调用，不读取密码框内容。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Security

struct UnattendedAuthInspectedDialog {
    let texts: [String]
    let buttonTitles: [String]
    let passwordField: AXUIElement?
    let approveButton: AXUIElement?
    let permissionApproveButton: AXUIElement?
    let usePasswordButton: AXUIElement?
}

enum UnattendedAuthAX {
    private static let approveButtonTitles: Set<String> = [
        "好", "允许", "允许访问", "修改设置", "更新设置", "解锁", "安装软件", "安装帮助程序", "继续", "批准",
        "OK", "Allow", "Allow Access", "Modify Settings", "Update Settings", "Unlock", "Install Software",
        "Install Helper", "Continue", "Approve",
    ]
    private static let usePasswordButtonTitles: Set<String> = [
        "使用密码…", "使用密码...", "使用密码", "输入密码",
        "Use Password…", "Use Password...", "Use Password", "Enter Password",
    ]
    private static let permissionPrimaryApproveTitles: Set<String> = [
        "允许", "允许访问", "允许完全访问", "允许访问所有照片", "继续允许",
        "Allow", "Allow Access", "Allow Full Access", "Allow All Photos", "Continue Allowing",
    ]
    private static let permissionFallbackApproveTitles: Set<String> = ["好", "OK"]
    private static let permissionDenyTitles: Set<String> = [
        "不允许", "拒绝", "以后", "取消",
        "Don’t Allow", "Don't Allow", "Deny", "Not Now", "Cancel",
    ]
    private static let blockedPromptKeywords = [
        "恶意软件", "无法验证开发者", "移到废纸篓", "Move to Trash", "malware", "cannot be verified",
    ]
    private static let chinesePermissionActionWords = [
        "访问", "使用", "控制", "接收", "录制", "捕捉", "查找", "共享", "修改", "读取", "添加", "连接", "追踪", "关联",
    ]
    private static let chinesePermissionPhrases = [
        "想访问", "想要访问", "想使用", "想要使用", "想控制", "想要控制", "想修改", "想要修改",
        "想要捕捉", "想录制", "想要录制", "想查找", "想要查找", "想接收", "想要接收", "想获得授权",
    ]
    private static let englishPermissionActionWords = [
        "access", "control", "use", "capture", "record", "find", "modify", "receive", "add", "read",
        "administer", "update",
    ]
    private static let englishPermissionAllowPhrases = [
        "access", "to access", "to use", "to control", "to find", "to receive", "to add",
        "to capture", "to record", "full access",
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

    static func inspectWindow(
        _ window: AXUIElement,
        fallbackPasswordField: AXUIElement? = nil
    ) -> UnattendedAuthInspectedDialog {
        var texts: [String] = []
        var rawButtonTitles: [String] = []
        var passwordField: AXUIElement?
        var approveButton: AXUIElement? = copyElementAttribute(window, kAXDefaultButtonAttribute)
        var primaryPermissionApproveButton: AXUIElement?
        var fallbackPermissionApproveButton: AXUIElement?
        var usePasswordButton: AXUIElement?

        if let title = copyStringAttribute(window, kAXTitleAttribute), !title.isEmpty {
            texts.append(title)
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 250 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            let role = copyStringAttribute(node, kAXRoleAttribute) ?? ""
            let subrole = copyStringAttribute(node, kAXSubroleAttribute) ?? ""

            if role == kAXStaticTextRole || role == kAXTextAreaRole {
                if let value = copyStringAttribute(node, kAXValueAttribute), !value.isEmpty {
                    texts.append(value)
                } else if let title = copyStringAttribute(node, kAXTitleAttribute), !title.isEmpty {
                    texts.append(title)
                }
            } else if role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole {
                // 绝不读取密码框内容，只记录控件引用。
                if passwordField == nil { passwordField = node }
            } else if role == kAXButtonRole {
                let title = buttonTitle(for: node)
                if !title.isEmpty {
                    rawButtonTitles.append(title)
                }
                if usePasswordButton == nil && usePasswordButtonTitles.contains(title) {
                    usePasswordButton = node
                } else if approveButton == nil && approveButtonTitles.contains(title) {
                    approveButton = node
                }
                // 绝不回退到 kAXDefaultButtonAttribute，防止默认焦点为“不允许”时误点。
                if primaryPermissionApproveButton == nil && permissionPrimaryApproveTitles.contains(title) {
                    primaryPermissionApproveButton = node
                } else if fallbackPermissionApproveButton == nil && permissionFallbackApproveTitles.contains(title) {
                    fallbackPermissionApproveButton = node
                }
            }

            guard depth < 10 else { continue }
            for child in copyChildren(node) {
                queue.append((child, depth + 1))
            }
        }

        if passwordField == nil,
            let fallbackPasswordField,
            isSecureTextField(fallbackPasswordField)
        {
            passwordField = fallbackPasswordField
        }

        return UnattendedAuthInspectedDialog(
            texts: deduplicatePreservingOrder(texts),
            buttonTitles: deduplicatePreservingOrder(rawButtonTitles),
            passwordField: passwordField,
            approveButton: approveButton,
            permissionApproveButton: primaryPermissionApproveButton ?? fallbackPermissionApproveButton,
            usePasswordButton: usePasswordButton
        )
    }

    static func matchesAppPermissionPrompt(texts: [String], buttonTitles: [String]) -> Bool {
        let hasAllowButton = buttonTitles.contains {
            permissionPrimaryApproveTitles.contains($0) || permissionFallbackApproveTitles.contains($0)
        }
        let hasDenyButton = buttonTitles.contains { permissionDenyTitles.contains($0) }
        guard hasAllowButton && hasDenyButton else { return false }

        let combinedAll = (texts + buttonTitles).joined(separator: " ")
        if blockedPromptKeywords.contains(where: { combinedAll.localizedCaseInsensitiveContains($0) }) {
            return false
        }

        let joinedTexts = texts.joined(separator: " ")
        let matchesChinese =
            (joinedTexts.contains("允许")
                && chinesePermissionActionWords.contains(where: { joinedTexts.contains($0) }))
            || chinesePermissionPhrases.contains(where: { joinedTexts.contains($0) })
        if matchesChinese { return true }

        let lower = joinedTexts.lowercased()
        let matchesEnglishVerb =
            (lower.contains("would like to ") || lower.contains("wants to "))
            && englishPermissionActionWords.contains(where: { lower.contains($0) })
        let matchesEnglishAllow =
            lower.contains("allow ")
            && englishPermissionAllowPhrases.contains(where: { lower.contains($0) })
        return matchesEnglishVerb || matchesEnglishAllow
    }

    private static func buttonTitle(for button: AXUIElement) -> String {
        if let title = copyStringAttribute(button, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return title
        }
        if let desc = copyStringAttribute(button, kAXDescriptionAttribute)?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !desc.isEmpty
        {
            return desc
        }
        var queue = copyChildren(button)
        var visited = 0
        while !queue.isEmpty && visited < 12 {
            let child = queue.removeFirst()
            visited += 1
            if copyStringAttribute(child, kAXRoleAttribute) == kAXStaticTextRole {
                if let value = copyStringAttribute(child, kAXValueAttribute)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                    !value.isEmpty
                {
                    return value
                }
                if let title = copyStringAttribute(child, kAXTitleAttribute)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                    !title.isEmpty
                {
                    return title
                }
            }
            queue.append(contentsOf: copyChildren(child))
        }
        return ""
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
        collectNestedSheets(from: window, depth: 0, into: &result)
        return result
    }

    private static func collectNestedSheets(from element: AXUIElement, depth: Int, into result: inout [AXUIElement]) {
        guard depth <= 3 else { return }
        var directSheets: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSheets" as CFString, &value) == .success,
            let sheets = value as? [AXUIElement]
        {
            directSheets.append(contentsOf: sheets)
        }
        for child in copyChildren(element) where copyStringAttribute(child, kAXRoleAttribute) == kAXSheetRole {
            directSheets.append(child)
        }
        for sheet in directSheets {
            if !result.contains(where: { CFEqual($0, sheet) }) {
                result.append(sheet)
            }
            collectNestedSheets(from: sheet, depth: depth + 1, into: &result)
        }
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    static func focusedUIElement() -> AXUIElement? {
        copyElementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    static func enclosingWindowOrSheet(for element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { break }
            let role = copyStringAttribute(node, kAXRoleAttribute)
            if role == kAXSheetRole || role == kAXWindowRole {
                return node
            }
            current = copyElementAttribute(node, kAXParentAttribute)
        }
        if let topLevel = copyElementAttribute(element, kAXTopLevelUIElementAttribute) {
            return topLevel
        }
        return copyElementAttribute(element, kAXWindowAttribute)
    }

    static func isSecureTextField(_ element: AXUIElement) -> Bool {
        copyStringAttribute(element, kAXRoleAttribute) == kAXTextFieldRole
            && copyStringAttribute(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
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
