// [INPUT]: 只读诊断和可替换的 Typeless 应用操作。
// [OUTPUT]: 同一菜单栏弹层内的状态、保存、确认与恢复反馈。
// [POS]: 只有用户明确确认后才请求退出，预览操作只在内存模拟。
import SwiftUI
import VorsmateSystem

@MainActor
final class TypelessRecoveryModel: ObservableObject {
    enum Phase: Equatable {
        case idle, confirming, exiting, opening
        case finished(String)
        case failed(String)
    }

    @Published private(set) var snapshot: TypelessDiagnosis?
    @Published private(set) var phase: Phase = .idle
    private let read: @MainActor () -> TypelessDiagnosis
    private let save: @MainActor (TypelessDiagnosis) throws -> Void
    private let target: @MainActor () throws -> TypelessRestartTarget
    private let exitTimeout: Duration

    var busy: Bool { phase == .exiting || phase == .opening }

    init(
        read: @escaping @MainActor () -> TypelessDiagnosis,
        save: @escaping @MainActor (TypelessDiagnosis) throws -> Void,
        target: @escaping @MainActor () throws -> TypelessRestartTarget, exitTimeout: Duration = .seconds(15)
    ) {
        self.read = read
        self.save = save
        self.target = target
        self.exitTimeout = exitTimeout
    }

    func refresh() {
        guard !busy, phase != .confirming else { return }
        snapshot = read()
        phase = .idle
    }

    func prepare() {
        guard !busy, phase != .confirming else { return }
        let current = read()
        snapshot = current
        do {
            try save(current)
            phase = .confirming
        } catch {
            phase = .failed("无法保存诊断。\(error.localizedDescription)")
        }
    }

    func cancelConfirmation() {
        if phase == .confirming { phase = .idle }
    }

    func confirm() async {
        guard phase == .confirming else { return }
        phase = .exiting
        do {
            try Task.checkCancellation()
            let app = try target()
            guard app.requestExit() else {
                phase = .failed("Typeless 未接受退出请求。请检查是否仍在录音或转写。")
                return
            }
            let deadline = ContinuousClock.now.advanced(by: exitTimeout)
            var exited = app.hasExited()
            while !exited && ContinuousClock.now < deadline {
                try await Task.sleep(until: min(ContinuousClock.now.advanced(by: .milliseconds(100)), deadline))
                exited = ContinuousClock.now < deadline && app.hasExited()
            }
            guard exited else {
                snapshot = read()
                phase = .failed("等待 Typeless 退出超时，已停止重新打开。设置已保留。")
                return
            }
            try Task.checkCancellation()
            phase = .opening
            try await app.open()
            snapshot = read()
            phase = .finished("Typeless 已打开。请在空白输入框试一次原来的听写快捷键。")
        } catch is CancellationError {
            phase = .idle
        } catch {
            snapshot = read()
            phase = .failed(error.localizedDescription)
        }
    }

    static func preview(remoteFault: Bool, timesOut: Bool) -> TypelessRecoveryModel {
        var reopened = false
        return TypelessRecoveryModel(
            read: {
                TypelessDiagnosis(
                    running: true, listener: remoteFault || reopened ? .enabled : .disabled,
                    modifiers: remoteFault || reopened ? [] : ["左 Control", "Fn"], remoteConnection: .connected,
                    remoteTakeover: remoteFault ? .inactive : .active)
            },
            save: { _ in },
            target: {
                TypelessRestartTarget(requestExit: { true }, hasExited: { !timesOut }, open: { reopened = true })
            },
            exitTimeout: .seconds(1))
    }
}

struct TypelessRecoveryPanel: View {
    @ObservedObject var model: TypelessRecoveryModel
    let preview: Bool
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: back) { Label("Vorsmate", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("typeless.back")
                Text("Typeless 诊断与恢复").font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 20)

            if let snapshot = model.snapshot {
                PanelSectionCard {
                    VStack(alignment: .leading, spacing: 9) {
                        diagnosticRow("Typeless", snapshot.running ? "运行中" : "未运行", id: "running")
                        diagnosticRow("快捷键监听", snapshot.listener.title, id: "listener")
                        diagnosticRow(
                            "系统检测到按下",
                            snapshot.modifiers.isEmpty
                                ? "未检测到 Control、Option 或 Fn" : snapshot.modifiers.joined(separator: "、"),
                            id: "modifiers")
                        Divider()
                        diagnosticRow("小米遥控器", snapshot.remoteConnection.title, id: "remote")
                        diagnosticRow("Vorsmate 接管", snapshot.remoteTakeover.title, id: "takeover")
                    }
                    .padding(14)
                }
                .padding(.horizontal, 16)

                Text(snapshot.guidance).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("typeless.guidance")
            }
            actions
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear(perform: model.cancelConfirmation)
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .confirming:
            Text(preview ? "模拟诊断已保存。请确认录音和转写均已结束。" : "诊断已保存。请确认录音和转写均已结束。")
                .font(.callout)
            HStack {
                Button("取消", action: model.cancelConfirmation)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("typeless.cancel")
                Spacer()
                Button("确认重新打开") { Task { await model.confirm() } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("typeless.confirm")
            }
        case .exiting, .opening:
            ProgressView(model.phase == .exiting ? "正在等待 Typeless 退出" : "正在打开 Typeless")
                .controlSize(.small).accessibilityIdentifier("typeless.progress")
        case .idle, .finished, .failed:
            if case .finished(let message) = model.phase {
                PanelInlineNotice(text: message, symbol: "checkmark.circle")
                    .accessibilityIdentifier("typeless.result")
            }
            if case .failed(let message) = model.phase {
                PanelInlineNotice(text: message, symbol: "exclamationmark.circle", isError: true)
                    .accessibilityIdentifier("typeless.error")
            }
            HStack {
                Button("重新检查", action: model.refresh).accessibilityIdentifier("typeless.refresh")
                Spacer()
                Button("重新打开 Typeless…", action: model.prepare)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("typeless.prepare")
            }
        }
    }

    private func diagnosticRow(_ label: String, _ value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier("typeless." + id)
    }
}
