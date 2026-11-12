// [INPUT]: AppKit / CoreGraphics、Resources/AppIcon-Source.png；可选输出目录（默认 Resources）。
// [OUTPUT]: 保留透明边距的 AppIcon.png / iconset，以及单色矢量 StatusIcon.pdf。
// [POS]: 已选“折影”图标的尺寸导出入口；应用保留折面，菜单栏采用清晰的 V 轮廓。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import ImageIO

let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Resources", directoryHint: .isDirectory)
let output = CommandLine.arguments.dropFirst().first.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? resources
let iconset = output.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let source = CGImageSourceCreateWithURL(resources.appending(path: "AppIcon-Source.png") as CFURL, nil),
    let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil), artwork.width == artwork.height
else { fatalError("无法读取方形图标源文件 AppIcon-Source.png") }

func render(size: Int) -> Data {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

func statusMark() -> CGPath {
    // 沿用应用图标的不对称圆角 V；小尺寸去掉折面明暗，保留稳定的实心轮廓。
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 53, y: 0))
    path.addCurve(to: CGPoint(x: 160, y: 20), control1: CGPoint(x: 112, y: 0), control2: CGPoint(x: 138, y: 0))
    path.addLine(to: CGPoint(x: 303, y: 295))
    path.addLine(to: CGPoint(x: 378, y: 106))
    path.addCurve(to: CGPoint(x: 535, y: 45), control1: CGPoint(x: 402, y: 59), control2: CGPoint(x: 462, y: 41))
    path.addCurve(to: CGPoint(x: 603, y: 81), control1: CGPoint(x: 590, y: 44), control2: CGPoint(x: 622, y: 46))
    path.addLine(to: CGPoint(x: 375, y: 441))
    path.addCurve(to: CGPoint(x: 228, y: 456), control1: CGPoint(x: 342, y: 498), control2: CGPoint(x: 270, y: 513))
    path.addLine(to: CGPoint(x: 8, y: 89))
    path.addCurve(to: CGPoint(x: 53, y: 0), control1: CGPoint(x: -12, y: 53), control2: CGPoint(x: -1, y: 0))
    path.closeSubpath()
    return path
}

func writeStatusIcon() throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil)
    let mark = statusMark()
    let bounds = mark.boundingBoxOfPath
    let scale = 16.5 / bounds.width
    context.translateBy(x: (18 - bounds.width * scale) / 2, y: (18 + bounds.height * scale) / 2)
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    context.addPath(mark)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
    try data.write(to: output.appending(path: "StatusIcon.pdf"))
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: points * scale).write(to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(size: 1024).write(to: output.appending(path: "AppIcon.png"))
try writeStatusIcon()
