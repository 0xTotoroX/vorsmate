// [INPUT]: AppKit / CoreGraphics / CoreImage、Resources/AppIcon-Source.png；可选输出目录（默认 Resources）。
// [OUTPUT]: 保留标准透明边距的 AppIcon.png / iconset / AppIcon.icns，以及同轮廓单色矢量 StatusIcon.pdf。
// [POS]: 应用图标采用纯白底与钴蓝海鸥，菜单栏与面板标题共用同一轮廓的单色剪影。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreImage
import Foundation

let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Resources", directoryHint: .isDirectory)
let output = CommandLine.arguments.dropFirst().first.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? resources
let iconset = output.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = resources.appending(path: "AppIcon-Source.png")
let originalPNG = try Data(contentsOf: master)
guard let artwork = CIImage(data: originalPNG), artwork.extent.size == CGSize(width: 1024, height: 1024)
else { fatalError("图标母版必须为 1024 × 1024 像素") }

let imageContext = CIContext(options: [.workingColorSpace: NSNull()])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func writeIcon(size: Int, to url: URL) throws {
    if size == 1024 {
        try originalPNG.write(to: url)
        return
    }
    let image = artwork.applyingFilter(
        "CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: CGFloat(size) / artwork.extent.width, kCIInputAspectRatioKey: 1.0])
    try imageContext.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: sRGB)
}

func statusMark() -> CGPath {
    // PDF 坐标向上。闭合路径同时包含两翼和中央笑弧，缩小时仍是一个连续的剪影。
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 128, y: -139.2))
    path.addCurve(
        to: CGPoint(x: 167, y: -102.3),
        control1: CGPoint(x: 139, y: -139.2),
        control2: CGPoint(x: 151.4, y: -115.1))
    path.addCurve(
        to: CGPoint(x: 196.7, y: -93.9),
        control1: CGPoint(x: 175.9, y: -95),
        control2: CGPoint(x: 184.5, y: -91))
    path.addCurve(
        to: CGPoint(x: 244.7, y: -117.2),
        control1: CGPoint(x: 214.7, y: -98.2),
        control2: CGPoint(x: 231.4, y: -110.7))
    path.addCurve(
        to: CGPoint(x: 198, y: -109.6),
        control1: CGPoint(x: 227.8, y: -115.7),
        control2: CGPoint(x: 211.2, y: -109.6))
    path.addCurve(
        to: CGPoint(x: 162.4, y: -133.4),
        control1: CGPoint(x: 184.2, y: -109.6),
        control2: CGPoint(x: 177, y: -122.7))
    path.addCurve(
        to: CGPoint(x: 146, y: -141.2),
        control1: CGPoint(x: 157.55, y: -136.96),
        control2: CGPoint(x: 151, y: -138.5))
    path.addCurve(
        to: CGPoint(x: 146.6, y: -142.8),
        control1: CGPoint(x: 144.5, y: -142.02),
        control2: CGPoint(x: 145.1, y: -142.8))
    path.addCurve(
        to: CGPoint(x: 156.23, y: -141.14),
        control1: CGPoint(x: 150.1, y: -142.8),
        control2: CGPoint(x: 153.8, y: -142.01))
    path.addCurve(
        to: CGPoint(x: 156.54, y: -142.22),
        control1: CGPoint(x: 157.51, y: -140.68),
        control2: CGPoint(x: 157.53, y: -141.42))
    path.addCurve(
        to: CGPoint(x: 128, y: -152.9),
        control1: CGPoint(x: 149.48, y: -147.92),
        control2: CGPoint(x: 138.95, y: -152.9))
    path.addCurve(
        to: CGPoint(x: 99.46, y: -142.22),
        control1: CGPoint(x: 117.05, y: -152.9),
        control2: CGPoint(x: 106.52, y: -147.92))
    path.addCurve(
        to: CGPoint(x: 99.77, y: -141.14),
        control1: CGPoint(x: 98.47, y: -141.42),
        control2: CGPoint(x: 98.49, y: -140.68))
    path.addCurve(
        to: CGPoint(x: 109.4, y: -142.8),
        control1: CGPoint(x: 102.2, y: -142.01),
        control2: CGPoint(x: 105.9, y: -142.8))
    path.addCurve(
        to: CGPoint(x: 110, y: -141.2),
        control1: CGPoint(x: 110.9, y: -142.8),
        control2: CGPoint(x: 111.5, y: -142.02))
    path.addCurve(
        to: CGPoint(x: 93.6, y: -133.4),
        control1: CGPoint(x: 105, y: -138.5),
        control2: CGPoint(x: 98.45, y: -136.96))
    path.addCurve(
        to: CGPoint(x: 58, y: -109.6),
        control1: CGPoint(x: 79, y: -122.7),
        control2: CGPoint(x: 71.8, y: -109.6))
    path.addCurve(
        to: CGPoint(x: 11.3, y: -117.2),
        control1: CGPoint(x: 44.8, y: -109.6),
        control2: CGPoint(x: 28.2, y: -115.7))
    path.addCurve(
        to: CGPoint(x: 59.3, y: -93.9),
        control1: CGPoint(x: 24.6, y: -110.7),
        control2: CGPoint(x: 41.3, y: -98.2))
    path.addCurve(
        to: CGPoint(x: 89, y: -102.3),
        control1: CGPoint(x: 71.5, y: -91),
        control2: CGPoint(x: 80.1, y: -95))
    path.addCurve(
        to: CGPoint(x: 128, y: -139.2),
        control1: CGPoint(x: 104.6, y: -115.1),
        control2: CGPoint(x: 117, y: -139.2))
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
    context.translateBy(
        x: (18 - bounds.width * scale) / 2 - bounds.minX * scale,
        y: (18 - bounds.height * scale) / 2 - bounds.minY * scale + 0.25)
    context.scaleBy(x: scale, y: scale)
    context.addPath(mark)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
    try data.write(to: output.appending(path: "StatusIcon.pdf"))
}

func writeICNS() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path(), "-o", output.appending(path: "AppIcon.icns").path()]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("iconutil 生成 AppIcon.icns 失败（状态码 \(process.terminationStatus)）")
    }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writeIcon(size: points * scale, to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}
try originalPNG.write(to: output.appending(path: "AppIcon.png"))
try writeICNS()
try writeStatusIcon()
