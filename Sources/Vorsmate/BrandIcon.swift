// [INPUT]: 应用包内的 StatusIcon.pdf 单色矢量资源。
// [OUTPUT]: 18 点菜单栏模板图标与 28 点面板居中图标，随系统明暗背景着色。
// [POS]: 菜单栏与面板顶部共用单色展翼标记；应用图标使用同轮廓的钴蓝海鸥。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit

@MainActor
enum BrandIcon {
    static let template: NSImage = loadTemplate(size: 18)
    static let panelMark: NSImage = loadTemplate(size: 28)

    private static func loadTemplate(size: CGFloat) -> NSImage {
        let resource = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf")
        let image =
            resource.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "v.circle", accessibilityDescription: "Vorsmate") ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
