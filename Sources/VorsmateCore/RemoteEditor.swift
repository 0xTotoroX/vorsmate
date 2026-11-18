// [INPUT]: 受信任宿主与配套插件之间的继承管道。
// [OUTPUT]: 面板订阅、配置回读与带原值校验的单键修改。每个 JSON 消息占一行。
import Foundation

package enum RemoteEditorCommand: Codable, Equatable {
    case observe, stopObserving, inputPermission, postPermission
    case configure(id: UUID, revision: UUID, edit: RemoteMappingEdit)
    case change(id: UUID, button: RemoteButton, gesture: RemoteGesture, previous: RemoteAction, action: RemoteAction)
}

package struct RemoteEditorState: Codable, Equatable {
    package var profile: RemoteProfile
    package var status: String
    package var voice: String
    package var revision: UUID?
    package var frontApp: String?
    package var needsInput: Bool
    package var needsPost: Bool
    package var feedback: String?
    package var problem: String?

    package init(
        profile: RemoteProfile, status: String, voice: String, needsInput: Bool, needsPost: Bool, problem: String?,
        feedback: String?
    ) {
        self.profile = profile
        self.status = status
        self.voice = voice
        self.needsInput = needsInput
        self.needsPost = needsPost
        self.feedback = feedback
        self.problem = problem
    }
}

package enum RemoteEditorReply: Codable {
    case state(RemoteEditorState)
    case saved(UUID, state: RemoteEditorState, error: String?)
}

extension RemoteProfile {
    package func action(for button: RemoteButton, gesture: RemoteGesture) -> RemoteAction {
        buttons[button.rawValue]?[gesture] ?? RemoteAction(.none)
    }

    package func editing(_ button: RemoteButton, gesture: RemoteGesture, previous: RemoteAction, action: RemoteAction)
        throws -> Self
    {
        guard button != .voice, self.action(for: button, gesture: gesture) == previous else {
            throw PreferenceError.changedOnDisk
        }
        var copy = self
        var binding = copy.buttons[button.rawValue] ?? RemoteBinding()
        binding[gesture] = action
        copy.buttons[button.rawValue] = binding
        try copy.validate()
        return copy
    }
}
