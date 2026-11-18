// [INPUT]: 去重的实体键快照、单调毫秒时间以及键位配置。
// [OUTPUT]: 胜出的按键/手势组合和最近一个判定截止时间。
// [POS]: 报告与定时器共用状态机；断连或停用时丢弃整份状态。
public struct RemoteStroke: Equatable, Sendable {
    public let button: RemoteButton
    public let gesture: RemoteGesture
    public init(_ button: RemoteButton, _ gesture: RemoteGesture) {
        self.button = button
        self.gesture = gesture
    }
}
public struct RemoteGestures: Sendable {
    private struct State: Sendable {
        var down = false
        var fired = false
        var second = false
        var releasedAt: Int?
        var holdAt: Int?
        var singleAt: Int?
    }
    private var states: [RemoteButton: State] = [:]
    public init() {}
    public var deadline: Int? { states.values.compactMap { [$0.holdAt, $0.singleAt].compactMap { $0 }.min() }.min() }
    public mutating func advance(to now: Int) -> [RemoteStroke] {
        var result: [RemoteStroke] = []
        for key in RemoteButton.allCases {
            guard var state = states[key] else { continue }
            if let due = state.holdAt, due <= now {
                result.append(RemoteStroke(key, .long))
                state.holdAt = nil
                state.fired = true
            }
            if let due = state.singleAt, due <= now {
                result.append(RemoteStroke(key, .single))
                state.singleAt = nil
            }
            states[key] = state
        }
        return result
    }
    public mutating func ingest(_ pressed: Set<RemoteButton>, at now: Int, profile: RemoteProfile) -> [RemoteStroke] {
        var result = advance(to: now)
        for key in RemoteButton.allCases where key != .voice {
            guard let binding = profile.buttons[key.rawValue] else { continue }
            var state = states[key] ?? State()
            let down = pressed.contains(key)
            guard state.down != down else { continue }
            state.down = down
            if down {
                // Suppress contact chatter only. Intentional double clicks and rapid direction presses survive.
                let bounced = !binding.rapid && state.releasedAt.map { now - $0 < 18 } == true
                state.fired = bounced
                state.second = !bounced && state.singleAt != nil
                if !bounced {
                    state.singleAt = nil
                    if binding.long.kind != .none { state.holdAt = now + profile.longMilliseconds }
                }
            } else {
                state.releasedAt = now
                state.holdAt = nil
                if !state.fired {
                    if state.second {
                        result.append(RemoteStroke(key, .double))
                    } else if binding.double.kind != .none {
                        state.singleAt = now + profile.doubleMilliseconds
                    } else {
                        result.append(RemoteStroke(key, .single))
                    }
                }
                state.second = false
            }
            states[key] = state
        }
        return result
    }
}
