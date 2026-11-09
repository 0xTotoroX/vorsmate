// [INPUT]: AppKit / CoreGraphics；可选输出目录（默认 Resources）。
// [OUTPUT]: 自绘 AppIcon.png 和各尺寸 iconset，不依赖外部图像或字体。
// [POS]: 应用图标可重复生成入口；iconutil 将 iconset 合成为 icns。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit

let output = URL(filePath: CommandLine.arguments.dropFirst().first ?? "Resources", directoryHint: .isDirectory)
let iconset = output.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGPath(
        roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
        cornerWidth: 182, cornerHeight: 182, transform: nil)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12), blur: 24,
        color: NSColor.black.withAlphaComponent(0.2).cgColor)
    context.addPath(tile)
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let colors =
        [
            CGColor(red: 0.08, green: 0.27, blue: 0.62, alpha: 1),
            CGColor(red: 0.22, green: 0.66, blue: 0.96, alpha: 1),
        ] as CFArray
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!,
        start: CGPoint(x: 512, y: 96), end: CGPoint(x: 512, y: 928), options: [])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
    context.setLineWidth(3)
    context.strokePath()

    // 三条独立滑杆延续菜单栏“管理选择”的含义。
    for (y, knobX) in [(664.0, 400.0), (512.0, 648.0), (360.0, 492.0)] {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(42)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.78))
        context.move(to: CGPoint(x: 270, y: y))
        context.addLine(to: CGPoint(x: 754, y: y))
        context.strokePath()
        context.setShadow(
            offset: CGSize(width: 0, height: -8), blur: 12,
            color: CGColor(red: 0.01, green: 0.1, blue: 0.3, alpha: 0.32))
        context.setFillColor(CGColor(gray: 1, alpha: 0.98))
        context.fillEllipse(in: CGRect(x: knobX - 54, y: y - 54, width: 108, height: 108))
        context.restoreGState()
    }
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: points * scale).write(to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(size: 1024).write(to: output.appending(path: "AppIcon.png"))
