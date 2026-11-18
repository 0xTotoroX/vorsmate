// [INPUT]: 已选 Blender 正面图、RC003 中心键与当前插件状态。
// [OUTPUT]: 原生键位窗口；验收模式仅在内存计数发送和输入框换行。
// [POS]: 与后台监听独立，关闭普通窗口不会停用宿主插件。
import AppKit
import SwiftUI

struct RemoteWindow: View {
    @ObservedObject var monitor: RemoteMonitor
    let preview: Bool
    let verify: Bool
    @State private var draft = ""
    @FocusState private var editing: Bool

    private func record(_ line: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    var body: some View {
        HStack(spacing: 0) {
            if let url = Bundle.main.url(forResource: "RC003", withExtension: "png"),
                let image = NSImage(contentsOf: url)
            {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().interpolation(.high)
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: 36, height: 36).position(x: 57.5, y: 84.73)
                }.frame(width: 115, height: 360).padding(.horizontal, 44)
                    .accessibilityLabel("遥控器正面，已选确定键")
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("小米蓝牙遥控器 2 Pro").foregroundStyle(.secondary)
                Text("确定键").font(.title.weight(.semibold))
                LabeledContent("单击", value: "切换 Typeless 听写")
                LabeledContent("快捷键", value: "左 ⌃  左 ⌥  V")
                Divider()
                Text(preview ? "预览" : monitor.status).foregroundStyle(.secondary)
                if monitor.needsPermission && !preview {
                    Button("打开输入监控设置") { monitor.requestAccess() }
                }
                if verify {
                    Text("验收输入框").font(.headline)
                    TextEditor(text: $draft).font(.body).frame(height: 52)
                        .border(.quaternary).focused($editing)
                    Text("已发送 \(monitor.sent) 次 · 当前换行 \(draft.filter { $0 == "\n" }.count) 个")
                        .font(.callout.monospacedDigit())
                }
            }.frame(width: 258).padding(28)
        }.padding(.vertical, 14).fixedSize()
            .onAppear { if verify { editing = true } }
            .onChange(of: monitor.sent) { _, count in
                if verify { record("shortcutReceipts=\(count)") }
            }
            .onChange(of: draft.filter { $0 == "\n" }.count) { _, count in
                if verify { record("lineBreaks=\(count)") }
            }
    }
}
