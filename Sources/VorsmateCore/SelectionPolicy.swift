// [INPUT]: Foundation；系统提供的可用项目与当前选择。
// [OUTPUT]: Channel、Source、Snapshot、SelectionPolicy 与确定性的选择结果。
// [POS]: 共享规则核心，不访问硬件；界面与系统适配共用。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import Foundation

public enum Channel: String, CaseIterable, Codable, Sendable, Identifiable {
    case inputSource, audioInput, audioOutput
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inputSource: "输入法"
        case .audioInput: "麦克风"
        case .audioOutput: "播放设备"
        }
    }
    public var symbol: String {
        switch self {
        case .inputSource: "keyboard"
        case .audioInput: "mic"
        case .audioOutput: "speaker.wave.2"
        }
    }
}

public struct Source: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var sources: [Source]
    public var selectedID: String?
    public init(sources: [Source] = [], selectedID: String? = nil) {
        self.sources = sources
        self.selectedID = selectedID
    }
    public var selected: Source? { sources.first { $0.id == selectedID } }
}

public struct SelectionPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var priority: [Source]
    public var lockedID: String?

    public init(enabled: Bool = false, priority: [Source] = [], lockedID: String? = nil) {
        self.enabled = enabled
        self.priority = priority
        self.lockedID = lockedID
    }

    /// 首次保持当前选择靠前；此后新增设备只追加，不让系统自动切换改写用户顺序。
    public mutating func discover(_ snapshot: Snapshot) {
        var known = Set<String>()
        let names = Dictionary(snapshot.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        priority = priority.filter { known.insert($0.id).inserted }.map {
            Source(id: $0.id, name: names[$0.id] ?? $0.name)
        }
        let incoming = snapshot.sources.filter { known.insert($0.id).inserted }
        if priority.isEmpty, let current = incoming.first(where: { $0.id == snapshot.selectedID }) {
            priority.append(current)
            priority.append(contentsOf: incoming.filter { $0.id != current.id })
        } else {
            priority.append(contentsOf: incoming)
        }
    }

    public mutating func lock(_ id: String) {
        enabled = true
        lockedID = id
    }
    public mutating func automate() {
        enabled = true
        lockedID = nil
    }

    public mutating func move(_ id: String, by offset: Int) {
        guard let index = priority.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard priority.indices.contains(destination) else { return }
        priority.swapAt(index, destination)
    }

    public func target(in snapshot: Snapshot) -> String? {
        guard enabled else { return nil }
        let available = Set(snapshot.sources.map(\.id))
        if let lockedID, available.contains(lockedID) { return lockedID }
        return priority.first(where: { available.contains($0.id) })?.id
    }

    public func isWaiting(in snapshot: Snapshot) -> Bool {
        enabled && lockedID != nil && !snapshot.sources.contains { $0.id == lockedID }
    }
}
