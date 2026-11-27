// [INPUT]: CoreGraphics 几何与 Foundation。
// [OUTPUT]: 截图工具、标注颜色与线宽规格、归一化标注模型及选区几何计算。
// [POS]: VorsmateCore 截图交互与标注数据层；不依赖 AppKit 或渲染实现。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import CoreGraphics
import Foundation

public enum ScreenshotTool: String, CaseIterable, Equatable, Sendable, Identifiable {
    case none
    case rectangle
    case arrow
    case pen

    public var id: Self { self }
}

public struct AnnotationColor: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let r: Double
    public let g: Double
    public let b: Double

    public init(id: String, name: String, r: Double, g: Double, b: Double) {
        self.id = id
        self.name = name
        self.r = r
        self.g = g
        self.b = b
    }

    public static let applePalette: [AnnotationColor] = [
        AnnotationColor(id: "coralRed", name: "珊瑚红", r: 1.0, g: 0.231, b: 0.188),
        AnnotationColor(id: "vibrantOrange", name: "活力橙", r: 1.0, g: 0.420, b: 0.173),
        AnnotationColor(id: "emeraldGreen", name: "翡翠绿", r: 0.188, g: 0.820, b: 0.345),
        AnnotationColor(id: "electricBlue", name: "电光蓝", r: 0.0, g: 0.478, b: 1.0),
        AnnotationColor(id: "indigoPurple", name: "靛蓝紫", r: 0.369, g: 0.361, b: 0.902),
        AnnotationColor(id: "obsidianBlack", name: "深曜黑", r: 0.110, g: 0.110, b: 0.118),
    ]

    public static let defaultColor: AnnotationColor = applePalette[0]
}

public enum AnnotationStrokeSize: String, CaseIterable, Equatable, Sendable, Identifiable {
    case thin
    case medium
    case thick

    public var id: Self { self }

    public var lineWidth: CGFloat {
        switch self {
        case .thin: 2
        case .medium: 4
        case .thick: 7
        }
    }

    public var indicatorDiameter: CGFloat {
        switch self {
        case .thin: 4
        case .medium: 7
        case .thick: 10
        }
    }
}

public enum ScreenshotAnnotationKind: Equatable, Sendable {
    case rectangle(rect: CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case pen(points: [CGPoint])
}

public struct ScreenshotAnnotation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var kind: ScreenshotAnnotationKind
    public var color: AnnotationColor
    public var size: AnnotationStrokeSize

    public init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind,
        color: AnnotationColor,
        size: AnnotationStrokeSize
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.size = size
    }
}

public enum ScreenshotSelectionGeometry {
    public enum Handle: Equatable, Sendable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
        case inside
    }

    public static func hitTest(point: CGPoint, selection: CGRect, tolerance: CGFloat = 8) -> Handle? {
        let rect = selection.standardized
        guard rect.width > 0, rect.height > 0 else { return nil }

        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
        ]
        for (handle, corner) in corners {
            if abs(point.x - corner.x) <= tolerance && abs(point.y - corner.y) <= tolerance {
                return handle
            }
        }

        if abs(point.y - rect.maxY) <= tolerance,
            point.x >= rect.minX - tolerance,
            point.x <= rect.maxX + tolerance
        {
            return .top
        }
        if abs(point.y - rect.minY) <= tolerance,
            point.x >= rect.minX - tolerance,
            point.x <= rect.maxX + tolerance
        {
            return .bottom
        }
        if abs(point.x - rect.minX) <= tolerance,
            point.y >= rect.minY - tolerance,
            point.y <= rect.maxY + tolerance
        {
            return .left
        }
        if abs(point.x - rect.maxX) <= tolerance,
            point.y >= rect.minY - tolerance,
            point.y <= rect.maxY + tolerance
        {
            return .right
        }
        if rect.contains(point) {
            return .inside
        }
        return nil
    }

    public static func resize(
        selection: CGRect,
        handle: Handle,
        delta: CGSize,
        within bounds: CGRect,
        minSize: CGFloat = 12
    ) -> CGRect {
        let sel = selection.standardized
        let b = bounds.standardized
        guard b.width > 0, b.height > 0 else { return sel }

        if handle == .inside {
            let width = min(sel.width, b.width)
            let height = min(sel.height, b.height)
            let x = min(max(sel.minX + delta.width, b.minX), b.maxX - width)
            let y = min(max(sel.minY + delta.height, b.minY), b.maxY - height)
            return CGRect(x: x, y: y, width: width, height: height)
        }

        var minX = max(b.minX, min(sel.minX, b.maxX))
        var maxX = max(b.minX, min(sel.maxX, b.maxX))
        var minY = max(b.minY, min(sel.minY, b.maxY))
        var maxY = max(b.minY, min(sel.maxY, b.maxY))
        let minW = min(minSize, b.width)
        let minH = min(minSize, b.height)

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = min(max(b.minX, minX + delta.width), maxX - minW)
        case .topRight, .right, .bottomRight:
            maxX = max(min(b.maxX, maxX + delta.width), minX + minW)
        case .top, .bottom, .inside:
            break
        }

        switch handle {
        case .topLeft, .top, .topRight:
            maxY = max(min(b.maxY, maxY + delta.height), minY + minH)
        case .bottomLeft, .bottom, .bottomRight:
            minY = min(max(b.minY, minY + delta.height), maxY - minH)
        case .left, .right, .inside:
            break
        }

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    public static func nudge(selection: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect) -> CGRect {
        resize(selection: selection, handle: .inside, delta: CGSize(width: dx, height: dy), within: bounds)
    }

    public static func snappedWindowRect(at point: CGPoint, windows: [CGRect], within bounds: CGRect) -> CGRect? {
        let b = bounds.standardized
        for rawWindow in windows {
            let window = rawWindow.standardized
            guard window.contains(point) else { continue }
            let clipped = window.intersection(b)
            guard !clipped.isNull, clipped.width >= 24, clipped.height >= 24 else { continue }
            return clipped
        }
        return nil
    }
}
