// [INPUT]: Blender 正交投影的 13 个实体按压区域。
// [OUTPUT]: 同一外形用于命中和系统强调色描边；摇杆上、下半独立。
// [POS]: 下拉菜单也可用键盘和 VoiceOver 选择。
import SwiftUI
import VorsmateCore

package enum RemoteFaceLayout {
    package static func key(at location: CGPoint, scale: CGFloat) -> RemoteButton? {
        let point = CGPoint(x: location.x / scale, y: location.y / scale)
        return RemoteButton.allCases.first { region($0).contains(point) }
    }
    package static func region(_ key: RemoteButton) -> Path {
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        func sector(_ degrees: Double) -> Path {
            let c = CGPoint(x: 230, y: 338.92)
            var p = Path()
            p.addArc(
                center: c, radius: 147.8, startAngle: .degrees(degrees - 45), endAngle: .degrees(degrees + 45),
                clockwise: false)
            p.addArc(
                center: c, radius: 79.6, startAngle: .degrees(degrees + 45), endAngle: .degrees(degrees - 45),
                clockwise: true)
            p.closeSubpath()
            return p
        }
        switch key {
        case .power: return circle(138.3, 118.8, 41)
        case .voice: return circle(321.7, 118.8, 41)
        case .ok: return circle(230, 338.92, 76.4)
        case .up: return sector(-90)
        case .down: return sector(90)
        case .left: return sector(180)
        case .right: return sector(0)
        case .back: return circle(154.3, 556.8, 57.7)
        case .home: return circle(154.3, 690.4, 57.7)
        case .menu: return circle(154.3, 824, 57.7)
        case .tv: return circle(305.7, 824, 57.7)
        case .volumeUp, .volumeDown:
            let upper = key == .volumeUp
            let rect = CGRect(x: 249.8, y: upper ? 501 : 623.6, width: 111.7, height: 122.6)
            return UnevenRoundedRectangle(
                topLeadingRadius: upper ? 55.8 : 0, bottomLeadingRadius: upper ? 0 : 55.8,
                bottomTrailingRadius: upper ? 0 : 55.8, topTrailingRadius: upper ? 55.8 : 0
            ).path(in: rect)
        }
    }

}

package struct RemoteFaceArtwork: View {
    let image: NSImage?
    let scale: CGFloat
    let selected: RemoteButton?
    let highlighted: Set<RemoteButton>
    package init(image: NSImage?, scale: CGFloat, selected: RemoteButton? = nil, highlighted: Set<RemoteButton> = []) {
        self.image = image
        self.scale = scale
        self.selected = selected
        self.highlighted = highlighted
    }
    package var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            Canvas { context, _ in
                context.scaleBy(x: scale, y: scale)
                if let selected, !highlighted.contains(selected) {
                    context.stroke(RemoteFaceLayout.region(selected), with: .color(.blue), lineWidth: 1.6 / scale)
                }
                for key in highlighted {
                    let path = RemoteFaceLayout.region(key)
                    context.fill(path, with: .color(.blue.opacity(0.28)))
                    context.stroke(path, with: .color(.blue), lineWidth: 2.4 / scale)
                }
            }
        }.frame(width: 460 * scale, height: 1440 * scale).accessibilityHidden(true)
    }
}

package struct RemoteFace: View {
    @Binding var selected: RemoteButton
    @GestureState private var pressed: RemoteButton?
    @State private var click: Click?
    private struct Click {
        let key: RemoteButton
        let id = UUID()
    }
    private let scale: CGFloat
    private let image: NSImage?
    private let highlighted: Set<RemoteButton>
    package init(
        selected: Binding<RemoteButton>, image: NSImage? = NSImage(named: "RC003"), scale: CGFloat = 0.29,
        highlighted: Set<RemoteButton> = []
    ) {
        _selected = selected
        self.image = image
        self.scale = scale
        self.highlighted = highlighted
    }
    private func hit(_ drag: DragGesture.Value) -> RemoteButton? {
        let key = RemoteFaceLayout.key(at: drag.startLocation, scale: scale)
        return key == RemoteFaceLayout.key(at: drag.location, scale: scale) ? key : nil
    }
    package var body: some View {
        let mouseKey = pressed ?? click?.key
        RemoteFaceArtwork(
            image: image, scale: scale, selected: selected, highlighted: highlighted.union(mouseKey.map { [$0] } ?? [])
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { drag, state, _ in state = hit(drag) }
                .onEnded { drag in
                    if let key = hit(drag) {
                        click = Click(key: key)
                        selected = key
                    }
                }
        )
        .task(id: click?.id) {
            guard click != nil else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            click = nil
        }
    }
}
