// [INPUT]: macOS 虚拟键码及 NSEvent 原始通用 / 左右修饰位。
// [OUTPUT]: 可显示和逐键发送的修饰键组合，兼容旧配置中的通用标志。
import CoreGraphics

public struct RemoteModifier: Equatable, Sendable {
    public let code: UInt16
    public let bit: UInt64
    public let family: UInt64
    public let title: String
    public let genericTitle: String

    public var hidUsage: UInt64 {
        switch code {
        case 59: 0xe0
        case 56: 0xe1
        case 58: 0xe2
        case 55: 0xe3
        case 62: 0xe4
        case 60: 0xe5
        case 61: 0xe6
        default: 0xe7
        }
    }

    public static let all: [Self] = [
        .init(code: 59, bit: 1, family: 1 << 18, title: "左⌃", genericTitle: "⌃"),
        .init(code: 62, bit: 0x2000, family: 1 << 18, title: "右⌃", genericTitle: "⌃"),
        .init(code: 58, bit: 0x20, family: 1 << 19, title: "左⌥", genericTitle: "⌥"),
        .init(code: 61, bit: 0x40, family: 1 << 19, title: "右⌥", genericTitle: "⌥"),
        .init(code: 56, bit: 2, family: 1 << 17, title: "左⇧", genericTitle: "⇧"),
        .init(code: 60, bit: 4, family: 1 << 17, title: "右⇧", genericTitle: "⇧"),
        .init(code: 55, bit: 8, family: 1 << 20, title: "左⌘", genericTitle: "⌘"),
        .init(code: 54, bit: 16, family: 1 << 20, title: "右⌘", genericTitle: "⌘"),
    ]
    public static func keys(_ flags: UInt64) -> [Self] {
        var result = [Self]()
        for key in all {
            if flags & key.bit != 0 {
                result.append(key)
            } else if flags & key.family != 0, !result.contains(where: { $0.family == key.family }),
                !all.contains(where: { $0.family == key.family && flags & $0.bit != 0 })
            {
                result.append(key)
            }
        }
        return result
    }
    public static func flags(_ keys: [Self]) -> UInt64 {
        keys.reduce(0) { $0 | $1.bit | $1.family }
    }
    public static func keycaps(code: UInt16, flags: UInt64, label: String?) -> [String] {
        var parts = keys(flags).filter { $0.code != code }.map { flags & $0.bit != 0 ? $0.title : $0.genericTitle }
        parts.append(all.first { $0.code == code }?.title ?? label ?? "键码 \(code)")
        return parts
    }
    public static func display(code: UInt16, flags: UInt64, label: String?) -> String {
        keycaps(code: code, flags: flags, label: label).joined()
    }
}

public struct RemoteKeyEvent: Sendable {
    public let code: UInt16
    public let down: Bool
    public let modifier: Bool
    public let flags: UInt64

    public static func sequence(code: UInt16, flags: UInt64) -> [Self] {
        let extras = flags & ~RemoteModifier.flags(RemoteModifier.all)
        let primary = RemoteModifier.all.first { $0.code == code }
        var modifiers = RemoteModifier.keys(flags).filter { $0.code != code }
        if let primary { modifiers.append(primary) }
        var held = [RemoteModifier]()
        var events = [Self]()
        for key in modifiers {
            held.append(key)
            events.append(Self(code: key.code, down: true, modifier: true, flags: extras | RemoteModifier.flags(held)))
        }
        if primary == nil {
            var active = extras | RemoteModifier.flags(held)
            if [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 123, 124, 125, 126].contains(
                code)
            {
                active |= CGEventFlags.maskNumericPad.rawValue
            }
            events.append(Self(code: code, down: true, modifier: false, flags: active))
            events.append(Self(code: code, down: false, modifier: false, flags: active))
        }
        while let key = held.popLast() {
            events.append(Self(code: key.code, down: false, modifier: true, flags: extras | RemoteModifier.flags(held)))
        }
        return events
    }
}
