// [OUTPUT]: 两个原生界面共用的动作和左右修饰键名称。
import VorsmateCore

extension RemoteAction.Kind {
    package var title: String {
        switch self {
        case .none: "无动作"
        case .typeless: "切换 Typeless 听写"
        case .shortcut: "自定义快捷键"
        case .openApplication: "打开应用…"
        case .volumeUp: "增大音量"
        case .volumeDown: "减小音量"
        case .mute: "静音"
        case .playPause: "播放 / 暂停"
        case .previousTrack: "上一首"
        case .nextTrack: "下一首"
        }
    }
}
extension RemoteAction {
    package var keycaps: [String] { RemoteModifier.keycaps(code: keyCode ?? 0, flags: flags ?? 0, label: label) }
    package var title: String {
        if kind == .openApplication { return label ?? "打开应用" }
        guard kind == .shortcut else { return kind.title }
        return RemoteModifier.display(code: keyCode ?? 0, flags: flags ?? 0, label: label)
    }
}
