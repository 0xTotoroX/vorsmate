// [INPUT]: 默认键位、前台应用标识和用户对单项手势的覆盖。
// [OUTPUT]: 只覆盖已编辑项目的应用方案；按住模式与触点去抖分别保存。
import Foundation

package enum RemoteHoldMode: String, Codable, CaseIterable, Sendable {
    case once, repeatSingle, repeatLong
    package var title: String {
        switch self {
        case .once: "执行一次"
        case .repeatSingle: "连发单击动作"
        case .repeatLong: "连发长按动作"
        }
    }
}

package struct RemoteButtonOverride: Codable, Equatable, Sendable {
    package var actions: [String: RemoteAction] = [:]
    package var hold: RemoteHoldMode?
}

package struct RemoteApplicationMap: Codable, Equatable, Sendable {
    package var name: String
    package var buttons: [String: RemoteButtonOverride] = [:]
}

package enum RemoteMappingEdit: Codable, Equatable {
    case addApp(id: String, name: String)
    case removeApp(id: String)
    case action(app: String?, button: RemoteButton, gesture: RemoteGesture, value: RemoteAction?)
    case hold(app: String?, button: RemoteButton, mode: RemoteHoldMode?)
}

extension RemoteProfile {
    package func resolved(for app: String?) -> Self {
        var result = self
        result.applications = nil
        guard let app, let map = applications?[app] else { return result }
        for (key, override) in map.buttons {
            var binding = result.buttons[key] ?? RemoteBinding()
            for gesture in RemoteGesture.allCases {
                if let value = override.actions[gesture.rawValue] { binding[gesture] = value }
            }
            if let mode = override.hold { binding.hold = mode }
            result.buttons[key] = binding
        }
        return result
    }

    package func applying(_ edit: RemoteMappingEdit) throws -> Self {
        var next = self
        switch edit {
        case .addApp(let id, let name):
            guard !id.isEmpty, !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var maps = applications ?? [:]
            if maps[id] == nil { maps[id] = RemoteApplicationMap(name: name) }
            next.applications = maps
        case .removeApp(let id):
            next.applications?.removeValue(forKey: id)
        case .action(let app, let button, let gesture, let value):
            guard button != .voice else { throw PreferenceError.changedOnDisk }
            if let app {
                try next.changeOverride(app, button) { $0.actions[gesture.rawValue] = value }
            } else {
                guard let value else { throw PreferenceError.changedOnDisk }
                next.buttons[button.rawValue, default: RemoteBinding()][gesture] = value
            }
        case .hold(let app, let button, let mode):
            guard button != .voice else { throw PreferenceError.changedOnDisk }
            if let app {
                try next.changeOverride(app, button) { $0.hold = mode }
            } else {
                next.buttons[button.rawValue, default: RemoteBinding()].hold = mode == .once ? nil : mode
            }
        }
        if next.applications?.isEmpty == true { next.applications = nil }
        if next.applications != nil || next.buttons.values.contains(where: { $0.hold != nil }) {
            next.version = 2
        }
        try next.validate()
        return next
    }

    private mutating func changeOverride(
        _ app: String, _ button: RemoteButton, update: (inout RemoteButtonOverride) -> Void
    ) throws {
        guard var map = applications?[app] else { throw PreferenceError.changedOnDisk }
        var override = map.buttons[button.rawValue] ?? RemoteButtonOverride()
        update(&override)
        map.buttons[button.rawValue] = override.actions.isEmpty && override.hold == nil ? nil : override
        applications?[app] = map
    }
}
