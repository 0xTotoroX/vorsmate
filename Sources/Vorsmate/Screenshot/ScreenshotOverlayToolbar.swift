// [INPUT]: TranslationModel、TranslationSceneSession、ScreenshotAnnotation 与 SwiftUI。
// [OUTPUT]: Liquid Glass Morphing A2 纯图标工具条、统一 20×20 矢量图标与玻璃胶囊修饰器。
// [POS]: 框选完成后贴底展开的交互工具栏及复用矢量图标组件。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore

enum ScreenshotVectorIconKind {
    case rect
    case arrow
    case pen
    case undo
    case ocr
    case translate
    case pin
    case save
    case close
    case done
    case copy
    case zoomMini
    case opacityMini
}

struct ScreenshotVectorIcon: View {
    let kind: ScreenshotVectorIconKind
    var size: CGFloat = 20

    var body: some View {
        let scale = size / 20.0
        let strokeWidth: CGFloat = (kind == .done ? 1.85 : 1.65) * scale
        let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)

        ZStack {
            strokePath(scale: scale)
                .stroke(style: style)
            if let fill = fillPath(scale: scale) {
                fill.fill()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func strokePath(scale: CGFloat) -> Path {
        var path = Path()
        switch kind {
        case .rect:
            path.addRoundedRect(
                in: CGRect(x: 3.5, y: 4.5, width: 13, height: 11), cornerSize: CGSize(width: 2, height: 2))
        case .arrow:
            path.move(to: CGPoint(x: 4.5, y: 15.5))
            path.addLine(to: CGPoint(x: 15, y: 5))
            path.move(to: CGPoint(x: 8.5, y: 4.5))
            path.addLine(to: CGPoint(x: 15.5, y: 4.5))
            path.addLine(to: CGPoint(x: 15.5, y: 11.5))
        case .pen:
            path.move(to: CGPoint(x: 6.3, y: 16.5))
            path.addLine(to: CGPoint(x: 7.7, y: 9.7))
            path.addLine(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 12.3, y: 9.7))
            path.addLine(to: CGPoint(x: 13.7, y: 16.5))
            path.move(to: CGPoint(x: 7.7, y: 9.7))
            path.addLine(to: CGPoint(x: 12.3, y: 9.7))
        case .undo:
            path.move(to: CGPoint(x: 7.4, y: 4.5))
            path.addLine(to: CGPoint(x: 4.2, y: 7.5))
            path.addLine(to: CGPoint(x: 7.4, y: 10.5))
            path.move(to: CGPoint(x: 4.6, y: 7.5))
            path.addLine(to: CGPoint(x: 11.6, y: 7.5))
            path.addArc(
                center: CGPoint(x: 11.6, y: 11.25),
                radius: 3.75,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: false)
            path.addLine(to: CGPoint(x: 6.5, y: 15))
        case .ocr:
            path.move(to: CGPoint(x: 3.5, y: 7.0))
            path.addLine(to: CGPoint(x: 3.5, y: 4.0))
            path.addLine(to: CGPoint(x: 6.5, y: 4.0))
            path.move(to: CGPoint(x: 13.5, y: 4.0))
            path.addLine(to: CGPoint(x: 16.5, y: 4.0))
            path.addLine(to: CGPoint(x: 16.5, y: 7.0))
            path.move(to: CGPoint(x: 16.5, y: 13.0))
            path.addLine(to: CGPoint(x: 16.5, y: 16.0))
            path.addLine(to: CGPoint(x: 13.5, y: 16.0))
            path.move(to: CGPoint(x: 6.5, y: 16.0))
            path.addLine(to: CGPoint(x: 3.5, y: 16.0))
            path.addLine(to: CGPoint(x: 3.5, y: 13.0))
            path.move(to: CGPoint(x: 6.5, y: 8.5))
            path.addLine(to: CGPoint(x: 13.5, y: 8.5))
            path.move(to: CGPoint(x: 6.5, y: 11.7))
            path.addLine(to: CGPoint(x: 11.8, y: 11.7))
        case .translate:
            // Bilingual 文 (top-left) / A (bottom-right)
            path.move(to: CGPoint(x: 6.4, y: 3.3))
            path.addLine(to: CGPoint(x: 6.4, y: 5.0))
            path.move(to: CGPoint(x: 3.3, y: 5.4))
            path.addLine(to: CGPoint(x: 9.5, y: 5.4))
            path.move(to: CGPoint(x: 8.0, y: 5.4))
            path.addLine(to: CGPoint(x: 4.0, y: 11.2))
            path.move(to: CGPoint(x: 4.8, y: 6.5))
            path.addLine(to: CGPoint(x: 8.8, y: 10.7))

            path.move(to: CGPoint(x: 10.6, y: 16.5))
            path.addLine(to: CGPoint(x: 13.8, y: 8.4))
            path.addLine(to: CGPoint(x: 17.0, y: 16.5))
            path.move(to: CGPoint(x: 11.7, y: 13.8))
            path.addLine(to: CGPoint(x: 15.9, y: 13.8))
        case .pin:
            path.move(to: CGPoint(x: 6.6, y: 3.5))
            path.addLine(to: CGPoint(x: 13.4, y: 3.5))
            path.move(to: CGPoint(x: 7.6, y: 3.5))
            path.addLine(to: CGPoint(x: 7.9, y: 8.0))
            path.addLine(to: CGPoint(x: 5.3, y: 11.8))
            path.addLine(to: CGPoint(x: 14.7, y: 11.8))
            path.addLine(to: CGPoint(x: 12.1, y: 8.0))
            path.addLine(to: CGPoint(x: 12.4, y: 3.5))
            path.move(to: CGPoint(x: 10, y: 11.8))
            path.addLine(to: CGPoint(x: 10, y: 16.5))
        case .save:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 10, y: 12.2))
            path.move(to: CGPoint(x: 6.6, y: 8.9))
            path.addLine(to: CGPoint(x: 10, y: 12.4))
            path.addLine(to: CGPoint(x: 13.4, y: 8.9))
            path.move(to: CGPoint(x: 4.0, y: 12.6))
            path.addLine(to: CGPoint(x: 4.0, y: 15.8))
            path.addLine(to: CGPoint(x: 16.0, y: 15.8))
            path.addLine(to: CGPoint(x: 16.0, y: 12.6))
        case .close:
            path.move(to: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 15, y: 15))
            path.move(to: CGPoint(x: 15, y: 5))
            path.addLine(to: CGPoint(x: 5, y: 15))
        case .done:
            path.move(to: CGPoint(x: 4.5, y: 10.5))
            path.addLine(to: CGPoint(x: 8.3, y: 14.3))
            path.addLine(to: CGPoint(x: 15.5, y: 6.1))
        case .copy:
            path.addRoundedRect(
                in: CGRect(x: 7.5, y: 7.5, width: 9.0, height: 9.0), cornerSize: CGSize(width: 1.8, height: 1.8))
            path.move(to: CGPoint(x: 5.5, y: 12.5))
            path.addLine(to: CGPoint(x: 4.8, y: 12.5))
            path.addQuadCurve(to: CGPoint(x: 3.5, y: 11.2), control: CGPoint(x: 3.5, y: 12.5))
            path.addLine(to: CGPoint(x: 3.5, y: 4.8))
            path.addQuadCurve(to: CGPoint(x: 4.8, y: 3.5), control: CGPoint(x: 3.5, y: 3.5))
            path.addLine(to: CGPoint(x: 11.2, y: 3.5))
            path.addQuadCurve(to: CGPoint(x: 12.5, y: 4.8), control: CGPoint(x: 12.5, y: 3.5))
            path.addLine(to: CGPoint(x: 12.5, y: 5.5))
        case .zoomMini:
            path.addEllipse(in: CGRect(x: 4.0, y: 4.0, width: 9.6, height: 9.6))
            path.move(to: CGPoint(x: 12.3, y: 12.3))
            path.addLine(to: CGPoint(x: 16.2, y: 16.2))
        case .opacityMini:
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 13, height: 13))
        }
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }

    private func fillPath(scale: CGFloat) -> Path? {
        var path = Path()
        switch kind {
        case .rect:
            let corners = [
                CGPoint(x: 3.5, y: 4.5),
                CGPoint(x: 16.5, y: 4.5),
                CGPoint(x: 3.5, y: 15.5),
                CGPoint(x: 16.5, y: 15.5),
            ]
            for pt in corners {
                path.addEllipse(in: CGRect(x: pt.x - 1.2, y: pt.y - 1.2, width: 2.4, height: 2.4))
            }
        case .pen:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addLine(to: CGPoint(x: 7.9, y: 9.5))
            path.addLine(to: CGPoint(x: 12.1, y: 9.5))
            path.closeSubpath()
        case .opacityMini:
            path.move(to: CGPoint(x: 10, y: 3.5))
            path.addArc(
                center: CGPoint(x: 10, y: 10),
                radius: 6.5,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: true)
            path.closeSubpath()
        default:
            return nil
        }
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

private enum ToolbarIndicatorKey: Hashable {
    case rect
    case arrow
    case pen
    case ocr
    case translate
}

private struct ToolbarIndicatorCenterKey: PreferenceKey {
    static let defaultValue: [ToolbarIndicatorKey: CGFloat] = [:]
    static func reduce(value: inout [ToolbarIndicatorKey: CGFloat], nextValue: () -> [ToolbarIndicatorKey: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SceneOverlayToolbarView: View {
    @ObservedObject var model: TranslationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var indicatorCenters: [ToolbarIndicatorKey: CGFloat] = [:]

    private let shellSpaceName = "SceneToolbarShellSpace"

    var body: some View {
        let session = model.sceneSession
        let activeTool = session?.activeTool ?? .none
        let translationActive = session?.translationActive ?? false
        let hasSubBar =
            activeTool != .none
            || translationActive
            || (session?.ocrRunning ?? false)
            || (session?.errorMessage != nil)
        let cornerRadius: CGFloat = hasSubBar ? 20 : 22

        VStack(spacing: 0) {
            AppleTranslationHostView(coordinator: model.appleCoordinator)
                .frame(width: 0, height: 0)

            row1(session: session)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if let session, hasSubBar {
                hairlineWithIndicator(activeKey: activeIndicatorKey(for: session))
                row2(session: session)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .coordinateSpace(name: shellSpaceName)
        .onPreferenceChange(ToolbarIndicatorCenterKey.self) { centers in
            indicatorCenters = centers
        }
        .modifier(OverlayGlassModifier(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
    }

    @ViewBuilder
    private func row1(session: TranslationSceneSession?) -> some View {
        let activeTool = session?.activeTool ?? .none
        let translationActive = session?.translationActive ?? false
        let annotationsEmpty = session?.annotations.isEmpty ?? true
        let busyOCR = session?.ocrRunning ?? false
        let busyTrans = session?.translating ?? false

        HStack(spacing: 4) {
            toolButton(
                kind: .rect,
                key: .rect,
                active: activeTool == .rectangle,
                help: "矩形标注"
            ) {
                model.selectAnnotationTool(activeTool == .rectangle ? .none : .rectangle)
            }
            toolButton(
                kind: .arrow,
                key: .arrow,
                active: activeTool == .arrow,
                help: "箭头标注"
            ) {
                model.selectAnnotationTool(activeTool == .arrow ? .none : .arrow)
            }
            toolButton(
                kind: .pen,
                key: .pen,
                active: activeTool == .pen,
                help: "画笔标注"
            ) {
                model.selectAnnotationTool(activeTool == .pen ? .none : .pen)
            }
            iconButton(
                kind: .undo,
                active: false,
                disabled: annotationsEmpty,
                help: "撤销标注 (⌘Z)"
            ) {
                model.undoAnnotation()
            }

            toolbarDivider

            toolButton(
                kind: .ocr,
                key: .ocr,
                active: busyOCR,
                disabled: busyOCR || busyTrans,
                help: "识别文字并复制"
            ) {
                model.triggerSceneOCR()
            }
            toolButton(
                kind: .translate,
                key: .translate,
                active: activeTool == .none && translationActive,
                help: "翻译选区"
            ) {
                model.toggleSceneTranslation()
            }

            toolbarDivider

            iconButton(
                kind: .pin,
                active: false,
                disabled: session == nil,
                help: "钉住为桌面贴图"
            ) {
                model.pinSceneSticker()
            }
            iconButton(
                kind: .save,
                active: false,
                disabled: session == nil,
                help: "保存图片 (⌘S)"
            ) {
                model.saveSceneImage()
            }
            iconButton(
                kind: .close,
                active: false,
                disabled: false,
                help: "关闭 (Esc)"
            ) {
                model.cancelCaptureOverlay()
            }
            Button {
                model.finishAndCopyImage()
            } label: {
                ScreenshotVectorIcon(kind: .done)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(session == nil)
            .help("完成并复制图片 (回车 / ⌘C)")
            .accessibilityLabel("完成并复制图片")
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    private func toolButton(
        kind: ScreenshotVectorIconKind,
        key: ToolbarIndicatorKey,
        active: Bool,
        disabled: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        iconButton(kind: kind, active: active, disabled: disabled, help: help, action: action)
            .background(indicatorAnchor(key))
    }

    private func indicatorAnchor(_ key: ToolbarIndicatorKey) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ToolbarIndicatorCenterKey.self,
                value: [key: geo.frame(in: .named(shellSpaceName)).midX])
        }
    }

    private func iconButton(
        kind: ScreenshotVectorIconKind,
        active: Bool,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScreenshotVectorIcon(kind: kind)
                .foregroundStyle(
                    disabled
                        ? Color.primary.opacity(0.28)
                        : (active ? Color.accentColor : Color.primary.opacity(0.86))
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func activeIndicatorKey(for session: TranslationSceneSession) -> ToolbarIndicatorKey? {
        if session.ocrRunning {
            return .ocr
        }
        switch session.activeTool {
        case .rectangle: return .rect
        case .arrow: return .arrow
        case .pen: return .pen
        case .none: return session.translationActive ? .translate : nil
        }
    }

    @ViewBuilder
    private func hairlineWithIndicator(activeKey: ToolbarIndicatorKey?) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .overlay(alignment: .leading) {
                if let activeKey, let centerX = indicatorCenters[activeKey] {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: centerX, y: 0.5)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: activeKey)
                }
            }
    }

    @ViewBuilder
    private func row2(session: TranslationSceneSession) -> some View {
        if session.ocrRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在识别文字…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if session.activeTool != .none {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(AnnotationStrokeSize.allCases) { strokeSize in
                        let selected = session.activeStrokeSize == strokeSize
                        Button {
                            model.selectAnnotationStrokeSize(strokeSize)
                        } label: {
                            ZStack {
                                if selected {
                                    Circle()
                                        .fill(Color.primary.opacity(0.09))
                                        .frame(width: 24, height: 24)
                                }
                                Circle()
                                    .fill(Color.primary.opacity(selected ? 0.88 : 0.45))
                                    .frame(width: strokeSize.indicatorDiameter, height: strokeSize.indicatorDiameter)
                            }
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(strokeHelp(strokeSize))
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 16)

                HStack(spacing: 8) {
                    ForEach(AnnotationColor.applePalette) { color in
                        let selected = session.activeColor == color
                        Button {
                            model.selectAnnotationColor(color)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(red: color.r, green: color.g, blue: color.b))
                                    .frame(width: 14, height: 14)
                                if selected {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                        .frame(width: 20, height: 20)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }
            }
        } else if session.translationActive {
            if session.translating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error = session.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(error)
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(TranslationTargetLanguage.allCases) { target in
                            Button {
                                model.switchTargetLanguage(target)
                            } label: {
                                if model.preferences.targetLanguage == target {
                                    Text("✓ \(target.title)")
                                } else {
                                    Text(target.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.preferences.targetLanguage.shortTitle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换目标语种")

                    Button {
                        model.toggleSceneComparison()
                    } label: {
                        Text("对照")
                            .font(.callout)
                            .foregroundStyle(session.showingComparison ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                session.showingComparison
                                    ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.translatedImage == nil)
                    .help("切换显示原图 / 译文（空格键）")

                    Button {
                        model.copyTranslatedText()
                    } label: {
                        Text(session.toastMessage ?? "复制译文")
                            .font(.callout)
                            .foregroundStyle(session.toastMessage != nil ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("复制识别译文")
                }
            }
        } else if let error = session.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(error)
        }
    }

    private func strokeHelp(_ size: AnnotationStrokeSize) -> String {
        switch size {
        case .thin: "细线条"
        case .medium: "中线条"
        case .thick: "粗线条"
        }
    }
}

private struct OverlayGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}

struct OverlayCapsuleGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }
}
