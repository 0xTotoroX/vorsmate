// [INPUT]: 应用包内的 StatusIcon.pdf 单色矢量资源。
// [OUTPUT]: 18 点模板图标，随系统明暗背景着色。
// [POS]: 菜单栏与面板标题共用品牌标记；应用图标独立保留完整折面材质。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit

@MainActor
enum BrandIcon {
    static let template: NSImage = {
        let resource = Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf")
        let image =
            resource.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "v.circle", accessibilityDescription: "Vorsmate") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
