// [INPUT]: 插件自己的键位档案、RC003 Report 1 的三个小端键值。
// [OUTPUT]: 实体按钮、互斥手势的动作、可回读的独立配置。
// [POS]: 默认仅启用确定键；迁移工具写入用户的完整配置。
import Foundation

public enum RemoteButton: String, CaseIterable, Codable, Sendable, Identifiable {
    case power, voice, up, left, ok, right, down, back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu, tv
    public var id: Self { self }
    public var name: String {
        switch self {
        case .power: "电源键"
        case .voice: "语音键"
        case .up: "上键"
        case .left: "左键"
        case .ok: "确定键"
        case .right: "右键"
        case .down: "下键"
        case .back: "返回键"
        case .volumeUp: "音量 +"
        case .home: "主页键"
        case .volumeDown: "音量 −"
        case .menu: "菜单键"
        case .tv: "TV 键"
        }
    }
    public var usage: UInt16 {
        switch self {
        case .power: 0x66
        case .voice: 0x3e
        case .up: 0x52
        case .left: 0x50
        case .ok: 0x28
        case .right: 0x4f
        case .down: 0x51
        case .back: 0xf1
        case .volumeUp: 0x80
        case .home: 0x4a
        case .volumeDown: 0x81
        case .menu: 0x65
        case .tv: 0x35
        }
    }

    public static func pressed(reportID: UInt32, bytes: [UInt8]) -> Set<Self>? {
        guard reportID == 1 else { return nil }
        let offset: Int
        switch bytes.count {
        case 6: offset = 0
        case 7 where bytes[0] == 1: offset = 1
        default: return nil
        }
        var result = Set<Self>()
        for index in stride(from: offset, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if (1...3).contains(usage) { return nil }
            if let key = Self.allCases.first(where: { $0.usage == usage }) { result.insert(key) }
        }
        return result
    }
}

public struct RemoteAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case none, typeless, shortcut, openApplication, volumeUp, volumeDown, mute, playPause, previousTrack, nextTrack
    }
    public var kind: Kind
    public var keyCode: UInt16?
    public var flags: UInt64?
    public var label: String?
    public var bundleID: String?
    public var path: String?
    public init(_ kind: Kind) { self.kind = kind }
}

public enum RemoteGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case single, double, long
    public var id: Self { self }
    public var name: String {
        switch self {
        case .single: "单击"
        case .double: "双击"
        case .long: "长按"
        }
    }
}
public struct RemoteBinding: Codable, Equatable, Sendable {
    public var single = RemoteAction(.none)
    public var double = RemoteAction(.none)
    public var long = RemoteAction(.none)
    public var rapid = false
    public init() {}
    public subscript(_ gesture: RemoteGesture) -> RemoteAction {
        get {
            switch gesture {
            case .single: single
            case .double: double
            case .long: long
            }
        }
        set {
            switch gesture {
            case .single: single = newValue
            case .double: double = newValue
            case .long: long = newValue
            }
        }
    }
}
public struct RemoteProfile: Codable, Equatable, Sendable {
    public var version = 1
    public var buttons: [String: RemoteBinding] = [:]
    public var doubleMilliseconds = 300
    public var longMilliseconds = 550
    public var voiceFn = false
    public init() {
        var ok = RemoteBinding()
        ok.single = RemoteAction(.typeless)
        buttons[RemoteButton.ok.rawValue] = ok
    }
    public var deviceMap: [UInt64: UInt64] {
        var values: [UInt64: UInt64] = [:]
        for button in RemoteButton.allCases {
            let source = UInt64(7) << 32 | UInt64(button.usage)
            if button == .voice {
                if voiceFn { values[source] = 0xff_0000_0003 }
            } else if buttons[button.rawValue] != nil {
                values[source] = 0
            }
        }
        return values
    }

    public func validate() throws {
        guard version == 1, (1...3000).contains(doubleMilliseconds), (1...5000).contains(longMilliseconds) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for binding in buttons.values {
            for gesture in RemoteGesture.allCases {
                let action = binding[gesture]
                if action.kind == .shortcut && action.keyCode.map({ $0 <= 127 }) != true {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if action.kind == .openApplication
                    && (action.bundleID?.isEmpty != false || action.path?.hasPrefix("/") != true)
                {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }
    public static var location: URL { URL.applicationSupportDirectory.appending(path: "VorsmateRemote/buttons.json") }
    public static func read(from url: URL = location) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let p = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try p.validate()
        return p
    }
    public func save(replacing previous: Self, at url: URL = location) throws {
        try validate()
        guard try Self.read(from: url) == previous else { throw PreferenceError.changedOnDisk }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
