// [INPUT]: Quartz 的通用修饰键位，不区分左右键。
// [OUTPUT]: 窗口拖动可保存的触发键、菜单标题与精确匹配。
// [POS]: Preferences 与窗口拖动事件监听共用的配置。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics

public enum WindowDragModifier: String, Codable, CaseIterable, Sendable {
    case option, command, shift, control, function, commandOption, controlOption

    public var title: String {
        switch self {
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .function: "fn"
        case .commandOption: "⌥⌘ Option + Command"
        case .controlOption: "⌃⌥ Control + Option"
        }
    }

    public var summaryTitle: String {
        switch self {
        case .commandOption: "⌥⌘"
        case .controlOption: "⌃⌥"
        default: title
        }
    }

    public func matches(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskAlternate, .maskCommand, .maskShift, .maskControl, .maskSecondaryFn]
        let required: CGEventFlags =
            switch self {
            case .option: .maskAlternate
            case .command: .maskCommand
            case .shift: .maskShift
            case .control: .maskControl
            case .function: .maskSecondaryFn
            case .commandOption: [.maskCommand, .maskAlternate]
            case .controlOption: [.maskControl, .maskAlternate]
            }
        return flags.intersection(relevant) == required
    }
}
