// [INPUT]: AppKit / CoreGraphics / SwiftUI、Resources/AppIcon-Source.png；可选输出目录（默认 Resources）。
// [OUTPUT]: 保留标准透明边距的 AppIcon.png / iconset / AppIcon.icns，以及同轮廓单色矢量 StatusIcon.pdf。
// [POS]: 应用图标保留展翼形体的三维起伏与光影，菜单栏与面板标题共用同一轮廓的单色剪影。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Foundation
import ImageIO
import SwiftUI

let resources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Resources", directoryHint: .isDirectory)
let output = CommandLine.arguments.dropFirst().first.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? resources
let iconset = output.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let source = CGImageSourceCreateWithURL(resources.appending(path: "AppIcon-Source.png") as CFURL, nil),
    let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil), artwork.width == artwork.height
else { fatalError("无法读取方形图标源文件 AppIcon-Source.png") }

@MainActor
func render(size: Int) -> Data {
    let canvas = CGFloat(size)
    let box = canvas * (824.0 / 1024.0)
    let view = Image(decorative: artwork, scale: 1)
        .resizable()
        .interpolation(.high)
        .frame(width: canvas, height: canvas)
        .mask(
            RoundedRectangle(cornerRadius: box * 0.2237, style: .continuous)
                .frame(width: box, height: box)
        )
        .frame(width: canvas, height: canvas)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let image = NSBitmapImageRep(cgImage: renderer.cgImage!)
    return image.representation(using: .png, properties: [:])!
}

func statusMark() -> CGPath {
    // 单条连续闭合对称曲线（G1 共线切向）：从中央上鞍部经翼弓舒展至右翼尖，再沿胸腹弧平滑回到左翼与起点，无中缝或折角。
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 10.80))
    path.addCurve(
        to: CGPoint(x: 17.53, y: 23.70),
        control1: CGPoint(x: 7.38, y: 10.80),
        control2: CGPoint(x: 13.28, y: 18.68))
    path.addCurve(
        to: CGPoint(x: 51.39, y: 64.48),
        control1: CGPoint(x: 28.98, y: 37.18),
        control2: CGPoint(x: 39.05, y: 51.75))
    path.addCurve(
        to: CGPoint(x: 85.33, y: 87.53),
        control1: CGPoint(x: 60.80, y: 74.17),
        control2: CGPoint(x: 71.99, y: 83.93))
    path.addCurve(
        to: CGPoint(x: 98.95, y: 88.31),
        control1: CGPoint(x: 89.76, y: 88.72),
        control2: CGPoint(x: 94.41, y: 89.11))
    path.addCurve(
        to: CGPoint(x: 99.92, y: 88.09),
        control1: CGPoint(x: 99.26, y: 88.25),
        control2: CGPoint(x: 99.62, y: 88.22))
    path.addCurve(
        to: CGPoint(x: 99.94, y: 87.88),
        control1: CGPoint(x: 100.02, y: 88.04),
        control2: CGPoint(x: 100.03, y: 87.95))
    path.addCurve(
        to: CGPoint(x: 98.58, y: 87.40),
        control1: CGPoint(x: 99.57, y: 87.62),
        control2: CGPoint(x: 99.00, y: 87.54))
    path.addCurve(
        to: CGPoint(x: 87.50, y: 80.52),
        control1: CGPoint(x: 94.38, y: 86.02),
        control2: CGPoint(x: 90.72, y: 83.52))
    path.addCurve(
        to: CGPoint(x: 63.20, y: 45.04),
        control1: CGPoint(x: 77.07, y: 70.77),
        control2: CGPoint(x: 70.15, y: 57.29))
    path.addCurve(
        to: CGPoint(x: 33.79, y: 0.89),
        control1: CGPoint(x: 54.54, y: 29.78),
        control2: CGPoint(x: 46.18, y: 13.52))
    path.addCurve(
        to: CGPoint(x: 0, y: -13.80),
        control1: CGPoint(x: 24.48, y: -8.59),
        control2: CGPoint(x: 13.33, y: -13.80))
    path.addCurve(
        to: CGPoint(x: -33.79, y: 0.89),
        control1: CGPoint(x: -13.33, y: -13.80),
        control2: CGPoint(x: -24.48, y: -8.59))
    path.addCurve(
        to: CGPoint(x: -63.20, y: 45.04),
        control1: CGPoint(x: -46.18, y: 13.52),
        control2: CGPoint(x: -54.54, y: 29.78))
    path.addCurve(
        to: CGPoint(x: -87.50, y: 80.52),
        control1: CGPoint(x: -70.15, y: 57.29),
        control2: CGPoint(x: -77.07, y: 70.77))
    path.addCurve(
        to: CGPoint(x: -98.58, y: 87.40),
        control1: CGPoint(x: -90.72, y: 83.52),
        control2: CGPoint(x: -94.38, y: 86.02))
    path.addCurve(
        to: CGPoint(x: -99.94, y: 87.88),
        control1: CGPoint(x: -99.00, y: 87.54),
        control2: CGPoint(x: -99.57, y: 87.62))
    path.addCurve(
        to: CGPoint(x: -99.92, y: 88.09),
        control1: CGPoint(x: -100.03, y: 87.95),
        control2: CGPoint(x: -100.02, y: 88.04))
    path.addCurve(
        to: CGPoint(x: -98.95, y: 88.31),
        control1: CGPoint(x: -99.62, y: 88.22),
        control2: CGPoint(x: -99.26, y: 88.25))
    path.addCurve(
        to: CGPoint(x: -85.33, y: 87.53),
        control1: CGPoint(x: -94.41, y: 89.11),
        control2: CGPoint(x: -89.76, y: 88.72))
    path.addCurve(
        to: CGPoint(x: -51.39, y: 64.48),
        control1: CGPoint(x: -71.99, y: 83.93),
        control2: CGPoint(x: -60.80, y: 74.17))
    path.addCurve(
        to: CGPoint(x: -17.53, y: 23.70),
        control1: CGPoint(x: -39.05, y: 51.75),
        control2: CGPoint(x: -28.98, y: 37.18))
    path.addCurve(
        to: CGPoint(x: 0, y: 10.80),
        control1: CGPoint(x: -13.28, y: 18.68),
        control2: CGPoint(x: -7.38, y: 10.80))
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

try MainActor.assumeIsolated {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            try render(size: points * scale).write(to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
        }
    }
    try render(size: 1024).write(to: output.appending(path: "AppIcon.png"))
}
try writeICNS()
try writeStatusIcon()
