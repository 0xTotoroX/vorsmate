// [INPUT]: ShutdownController 的应用清单、偏好与可取消执行状态。
// [OUTPUT]: 第五个可展开模块、一键关机 / 重启、跳过列表和模拟反馈。
// [POS]: 复用 PanelSummaryRow 的原生紧凑界面，真实执行只经控制器。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import SwiftUI
import VorsmateCore
import VorsmateSystem

struct QuickShutdownView: View {
    @ObservedObject var controller: ShutdownController
    @Binding var expanded: Bool
    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                PanelSummaryRow(
                    title: "一键下班", symbol: "power", status: controller.status,
                    value: "\(controller.appCount) 个应用", expanded: expanded, pending: controller.executing)
            }.buttonStyle(.plain).accessibilityIdentifier("shutdown.summary")
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let countdown = controller.countdown {
                        HStack {
                            Text("\(countdown) 秒后\(controller.pendingAction?.title ?? "关机")")
                                .font(.title3.weight(.semibold)).monospacedDigit()
                            Spacer()
                            Button("取消") { controller.cancel() }.keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("shutdown.cancel")
                        }
                    } else if controller.executing {
                        Text("正在清理").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("立即下班（关机）") { controller.start(.shutdown) }
                                .accessibilityIdentifier("shutdown.start")
                            Button("清理并重启") { controller.start(.restart) }
                                .accessibilityIdentifier("shutdown.restart")
                        }
                    }
                    Group {
                        Toggle("强制关闭未保存应用", isOn: policyBinding(\.forceCloseApps))
                            .help("可能丢失未保存内容；关闭后，等待保存的应用会阻止本次操作。")
                        Toggle("下次开机不恢复窗口", isOn: policyBinding(\.disableReopenWindows))
                        if controller.apps.isEmpty { Text("没有可清理的应用").foregroundStyle(.secondary) }
                        ForEach(controller.apps) { app in
                            Button {
                                controller.toggleExcluded(app.id)
                            } label: {
                                HStack {
                                    Text(app.name).lineLimit(2)
                                    Spacer()
                                    Text(controller.policy.excludedBundleIDs.contains(app.id) ? "跳过" : "清理")
                                        .foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(
                                    app.name + (controller.policy.excludedBundleIDs.contains(app.id) ? "，跳过清理" : "，将清理")
                                )
                        }
                        Text("跳过仅保留到系统关机或重启前。").font(.callout).foregroundStyle(.secondary)
                    }.disabled(controller.countdown != nil || controller.executing)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let feedback = controller.error ?? controller.message {
                Text(feedback).font(.callout).foregroundStyle(controller.error == nil ? Color.secondary : .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
    private func policyBinding(_ key: WritableKeyPath<ShutdownPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.policy[keyPath: key] },
            set: {
                var next = controller.policy
                next[keyPath: key] = $0
                controller.updatePolicy(next)
            })
    }
}
