// [OUTPUT]: 只在本地视图获得焦点时录入一次组合，保留左右修饰键。
import SwiftUI
import VorsmateCore

package struct KeyRecorder: NSViewRepresentable {
    let capture: (RemoteAction) -> Void
    package init(capture: @escaping (RemoteAction) -> Void) { self.capture = capture }
    package func makeNSView(context: Context) -> Field {
        let field = Field(labelWithString: "请按下快捷键")
        field.capture = capture
        return field
    }
    package func updateNSView(_ nsView: Field, context: Context) { nsView.capture = capture }
    package final class Field: NSTextField {
        var capture: ((RemoteAction) -> Void)?
        package override var acceptsFirstResponder: Bool { true }
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                DispatchQueue.main.async { [weak self, weak window] in if let self { window?.makeFirstResponder(self) }
                }
            }
        }
        package override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }
        private var held = [RemoteModifier]()
        private var chord = [RemoteModifier]()
        private var completed = false
        package override func flagsChanged(with event: NSEvent) {
            guard !completed, let key = RemoteModifier.all.first(where: { $0.code == event.keyCode }) else { return }
            let bits = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            if bits & key.bit != 0 {
                if !held.contains(key) { held.append(key) }
                chord = held
            } else if held.contains(key) {
                held.removeAll { $0 == key }
                if held.isEmpty, let last = chord.last {
                    var action = RemoteAction(.shortcut)
                    action.keyCode = last.code
                    action.flags = RemoteModifier.flags(Array(chord.dropLast()))
                    action.label = last.title
                    completed = true
                    capture?(action)
                }
            }
        }
        package override func keyDown(with event: NSEvent) {
            guard !event.isARepeat, !completed else { return }
            completed = true
            var action = RemoteAction(.shortcut)
            action.keyCode = event.keyCode
            action.flags = (event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)) & 0x00ff_ffff
            let special: [UInt16: String] = [
                36: "回车", 48: "Tab", 49: "空格", 51: "退格", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
            ]
            let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
            action.label = special[event.keyCode] ?? (character.isEmpty ? "键码 \(event.keyCode)" : character)
            capture?(action)
        }
    }
}
