// [INPUT]: CoreGraphics 像素缓存、CoreText 字体排版、ScreenshotAnnotation 与 TranslatedTextRegion 区块列表。
// [OUTPUT]: 屏幕选区裁剪、原场景局部背景擦除／对比文字回填、矢量标注绘制与最终合成图像。
// [POS]: VorsmateSystem 原图场景翻译与标注渲染器；纯内存位图处理，不访问网络或磁盘。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import CoreGraphics
import CoreText
import Foundation
import VorsmateCore

public enum SceneImageRenderer {
    public static func crop(image: CGImage, screenFrame: CGRect, selectionScreenRect: CGRect) -> CGImage? {
        guard screenFrame.width > 0, screenFrame.height > 0,
            selectionScreenRect.width >= 1, selectionScreenRect.height >= 1
        else {
            return nil
        }

        let scaleX = CGFloat(image.width) / screenFrame.width
        let scaleY = CGFloat(image.height) / screenFrame.height
        let pxX = (selectionScreenRect.minX - screenFrame.minX) * scaleX
        let pxY = (screenFrame.maxY - selectionScreenRect.maxY) * scaleY
        let pxW = selectionScreenRect.width * scaleX
        let pxH = selectionScreenRect.height * scaleY

        let rawRect = CGRect(x: pxX, y: pxY, width: pxW, height: pxH).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rawRect.intersection(bounds)
        guard clamped.width >= 1, clamped.height >= 1, let cropped = image.cropping(to: clamped) else {
            return nil
        }
        return materializeStandaloneBitmap(cropped)
    }

    private static func materializeStandaloneBitmap(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let preferredSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ctx =
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: preferredSpace,
                bitmapInfo: bitmapInfo)
            ?? CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo)
        guard let ctx else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    public static func render(original: CGImage, regions: [TranslatedTextRegion]) -> CGImage {
        let width = original.width
        let height = original.height
        guard width > 0, height > 0 else { return original }

        let activeRegions = regions.filter { !$0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !activeRegions.isEmpty else { return original }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard
            let sampleCtx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo)
        else {
            return original
        }
        sampleCtx.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let dataPtr = sampleCtx.data else { return original }
        let bytesPerRow = sampleCtx.bytesPerRow
        let cleanSnapshot = [UInt8](
            UnsafeBufferPointer(
                start: dataPtr.assumingMemoryBound(to: UInt8.self),
                count: bytesPerRow * height))

        let orderedIndices = activeRegions.indices.sorted { lhs, rhs in
            let a = activeRegions[lhs].normalizedBox
            let b = activeRegions[rhs].normalizedBox
            if a.midY != b.midY { return a.midY > b.midY }
            return a.minX < b.minX
        }

        let canvasSize = CGSize(width: width, height: height)
        for index in orderedIndices {
            let region = activeRegions[index]
            let box = region.normalizedBox
            let pxRect = CGRect(
                x: box.minX * canvasSize.width,
                y: box.minY * canvasSize.height,
                width: max(4, box.width * canvasSize.width),
                height: max(8, box.height * canvasSize.height))

            let (bgRGB, fgRGB) = sampleColors(
                pixels: cleanSnapshot,
                imageWidth: width,
                imageHeight: height,
                bytesPerRow: bytesPerRow,
                cgRect: pxRect)

            let availableWidth = maxAvailableWidth(
                for: box,
                in: activeRegions,
                excluding: index,
                canvasSize: canvasSize)
            let drawWidth = max(pxRect.width, availableWidth)
            let line = fittedLine(
                text: region.translated,
                maxWidth: drawWidth,
                boxHeight: pxRect.height,
                foreground: fgRGB)
            let lineBounds = CTLineGetBoundsWithOptions(line, [])

            var bgRect = CGRect(
                x: pxRect.minX - 3,
                y: pxRect.minY - 2,
                width: max(pxRect.width + 6, min(drawWidth + 6, lineBounds.width + 10)),
                height: pxRect.height + 4)
            let canvasRect = CGRect(origin: .zero, size: canvasSize)
            bgRect = bgRect.intersection(canvasRect)
            guard bgRect.width >= 2, bgRect.height >= 2 else { continue }

            let bgColor = CGColor(
                red: CGFloat(bgRGB.r) / 255,
                green: CGFloat(bgRGB.g) / 255,
                blue: CGFloat(bgRGB.b) / 255,
                alpha: 0.96)
            let radius = min(6, bgRect.height * 0.2)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            sampleCtx.saveGState()
            sampleCtx.setFillColor(bgColor)
            sampleCtx.addPath(bgPath)
            sampleCtx.fillPath()

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let textHeight = ascent + descent
            let baselineY = bgRect.minY + (bgRect.height - textHeight) / 2 + descent
            sampleCtx.textPosition = CGPoint(x: max(bgRect.minX + 3, pxRect.minX), y: baselineY)
            CTLineDraw(line, sampleCtx)
            sampleCtx.restoreGState()
        }

        return sampleCtx.makeImage() ?? original
    }

    public static func renderAnnotations(
        base: CGImage,
        annotations: [ScreenshotAnnotation],
        scaleFactor: CGFloat
    ) -> CGImage {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0, !annotations.isEmpty else { return base }

        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo)
        else {
            return base
        }

        let canvasSize = CGSize(width: width, height: height)
        ctx.draw(base, in: CGRect(origin: .zero, size: canvasSize))

        let scale = max(1, scaleFactor)
        for annotation in annotations {
            let color = CGColor(
                red: annotation.color.r,
                green: annotation.color.g,
                blue: annotation.color.b,
                alpha: 1)
            let strokeWidth = annotation.size.lineWidth * scale

            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(strokeWidth)

            switch annotation.kind {
            case .rectangle(let normRect):
                let rect = normRect.standardized
                let pxRect = CGRect(
                    x: rect.minX * canvasSize.width,
                    y: rect.minY * canvasSize.height,
                    width: rect.width * canvasSize.width,
                    height: rect.height * canvasSize.height)
                if pxRect.width >= 1 || pxRect.height >= 1 {
                    let cornerRadius = min(6 * scale, min(pxRect.width, pxRect.height) * 0.25)
                    let path = CGPath(
                        roundedRect: pxRect,
                        cornerWidth: cornerRadius,
                        cornerHeight: cornerRadius,
                        transform: nil)
                    ctx.setLineJoin(.round)
                    ctx.addPath(path)
                    ctx.strokePath()
                }

            case .arrow(let normStart, let normEnd):
                let p1 = CGPoint(x: normStart.x * canvasSize.width, y: normStart.y * canvasSize.height)
                let p2 = CGPoint(x: normEnd.x * canvasSize.width, y: normEnd.y * canvasSize.height)
                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let length = hypot(dx, dy)
                if length >= 1 {
                    let ux = dx / length
                    let uy = dy / length
                    let px = -uy
                    let py = ux
                    let headLength = min(length * 0.65, max(strokeWidth * 3.4, 14 * scale))
                    let headHalfWidth = headLength * 0.42
                    let shaftEnd = CGPoint(x: p2.x - ux * headLength * 0.72, y: p2.y - uy * headLength * 0.72)

                    ctx.setLineCap(.round)
                    ctx.move(to: p1)
                    ctx.addLine(to: shaftEnd)
                    ctx.strokePath()

                    let baseCenter = CGPoint(x: p2.x - ux * headLength, y: p2.y - uy * headLength)
                    let leftWing = CGPoint(x: baseCenter.x + px * headHalfWidth, y: baseCenter.y + py * headHalfWidth)
                    let rightWing = CGPoint(x: baseCenter.x - px * headHalfWidth, y: baseCenter.y - py * headHalfWidth)
                    ctx.move(to: p2)
                    ctx.addLine(to: leftWing)
                    ctx.addLine(to: rightWing)
                    ctx.closePath()
                    ctx.fillPath()
                }

            case .pen(let normPoints):
                guard let first = normPoints.first else { break }
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let startPt = CGPoint(x: first.x * canvasSize.width, y: first.y * canvasSize.height)
                ctx.move(to: startPt)
                if normPoints.count == 1 {
                    ctx.addLine(to: startPt)
                } else {
                    for normPt in normPoints.dropFirst() {
                        ctx.addLine(to: CGPoint(x: normPt.x * canvasSize.width, y: normPt.y * canvasSize.height))
                    }
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        return ctx.makeImage() ?? base
    }

    public static func renderComposite(
        original: CGImage,
        translated: CGImage?,
        showTranslation: Bool,
        annotations: [ScreenshotAnnotation],
        scaleFactor: CGFloat
    ) -> CGImage {
        let base = (showTranslation ? translated : nil) ?? original
        return renderAnnotations(base: base, annotations: annotations, scaleFactor: scaleFactor)
    }

    private struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8

        var luminance: CGFloat {
            (0.299 * CGFloat(r) + 0.587 * CGFloat(g) + 0.114 * CGFloat(b)) / 255.0
        }

        func distance(to other: RGB) -> Int {
            abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
        }
    }

    private static func maxAvailableWidth(
        for box: CGRect, in regions: [TranslatedTextRegion], excluding currentIndex: Int, canvasSize: CGSize
    ) -> CGFloat {
        let rightMargin: CGFloat = 8
        var maxPxX = canvasSize.width - rightMargin
        for (idx, sibling) in regions.enumerated() where idx != currentIndex {
            let sBox = sibling.normalizedBox
            let minH = min(box.height, sBox.height)
            let sameRow = abs(box.midY - sBox.midY) < minH * 0.55
            if sameRow && sBox.minX > box.maxX {
                maxPxX = min(maxPxX, sBox.minX * canvasSize.width - 8)
            }
        }
        let pxStart = box.minX * canvasSize.width
        return max(box.width * canvasSize.width, maxPxX - pxStart)
    }

    private static func fittedLine(text: String, maxWidth: CGFloat, boxHeight: CGFloat, foreground: RGB) -> CTLine {
        let startSize = max(12, min(64, boxHeight * 0.78))
        let minSize = max(10, boxHeight * 0.46)
        let fgColor = CGColor(
            red: CGFloat(foreground.r) / 255,
            green: CGFloat(foreground.g) / 255,
            blue: CGFloat(foreground.b) / 255,
            alpha: 1)

        var fontSize = startSize
        while fontSize >= minSize {
            let line = makeLine(text: text, fontSize: fontSize, color: fgColor)
            let width = CTLineGetBoundsWithOptions(line, []).width
            if width <= maxWidth || fontSize <= minSize {
                if width > maxWidth {
                    let ellipsis = makeLine(text: "…", fontSize: fontSize, color: fgColor)
                    return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
                }
                return line
            }
            let ratio = maxWidth / max(width, 1)
            let nextSize = max(minSize, min(fontSize - 1, fontSize * ratio))
            if nextSize >= fontSize { break }
            fontSize = nextSize
        }
        return makeLine(text: text, fontSize: minSize, color: fgColor)
    }

    private static func makeLine(text: String, fontSize: CGFloat, color: CGColor) -> CTLine {
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private static func sampleColors(
        pixels: [UInt8],
        imageWidth: Int,
        imageHeight: Int,
        bytesPerRow: Int,
        cgRect: CGRect
    ) -> (bg: RGB, fg: RGB) {
        // CGContext 原点在左下角，内存缓冲区原点在左上角，需翻转 Y。
        let topMinY = max(0, min(imageHeight - 1, Int((CGFloat(imageHeight) - cgRect.maxY).rounded())))
        let topMaxY = max(topMinY + 1, min(imageHeight, Int((CGFloat(imageHeight) - cgRect.minY).rounded())))
        let minX = max(0, min(imageWidth - 1, Int(cgRect.minX.rounded())))
        let maxX = max(minX + 1, min(imageWidth, Int(cgRect.maxX.rounded())))

        var borderR: [UInt8] = []
        var borderG: [UInt8] = []
        var borderB: [UInt8] = []

        func readPixel(x: Int, y: Int) -> RGB {
            let offset = y * bytesPerRow + x * 4
            return RGB(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2])
        }

        let outerMinX = max(0, minX - 2)
        let outerMaxX = min(imageWidth - 1, maxX + 1)
        let outerMinY = max(0, topMinY - 2)
        let outerMaxY = min(imageHeight - 1, topMaxY + 1)
        let stepX = max(1, (outerMaxX - outerMinX) / 24)
        for x in stride(from: outerMinX, through: outerMaxX, by: stepX) {
            for y in [outerMinY, outerMaxY] {
                let c = readPixel(x: x, y: y)
                borderR.append(c.r)
                borderG.append(c.g)
                borderB.append(c.b)
            }
        }
        let stepY = max(1, (outerMaxY - outerMinY) / 12)
        for y in stride(from: outerMinY, through: outerMaxY, by: stepY) {
            for x in [outerMinX, outerMaxX] {
                let c = readPixel(x: x, y: y)
                borderR.append(c.r)
                borderG.append(c.g)
                borderB.append(c.b)
            }
        }

        let bg = RGB(
            r: median(borderR, fallback: 255),
            g: median(borderG, fallback: 255),
            b: median(borderB, fallback: 255))

        var inkSamples: [(dist: Int, color: RGB)] = []
        let innerStepX = max(1, (maxX - minX) / 24)
        let innerStepY = max(1, (topMaxY - topMinY) / 12)
        for y in stride(from: topMinY, to: topMaxY, by: innerStepY) {
            for x in stride(from: minX, to: maxX, by: innerStepX) {
                let c = readPixel(x: x, y: y)
                let dist = c.distance(to: bg)
                if dist > 70 {
                    inkSamples.append((dist, c))
                }
            }
        }

        let fg: RGB
        if inkSamples.isEmpty {
            fg = bg.luminance > 0.5 ? RGB(r: 22, g: 22, b: 22) : RGB(r: 245, g: 245, b: 245)
        } else {
            let sorted = inkSamples.sorted { $0.dist > $1.dist }
            let topSlice = sorted.prefix(max(1, sorted.count / 3))
            fg = RGB(
                r: median(topSlice.map(\.color.r), fallback: 22),
                g: median(topSlice.map(\.color.g), fallback: 22),
                b: median(topSlice.map(\.color.b), fallback: 22))
        }
        return (bg, fg)
    }

    private static func median(_ values: [UInt8], fallback: UInt8) -> UInt8 {
        guard !values.isEmpty else { return fallback }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
