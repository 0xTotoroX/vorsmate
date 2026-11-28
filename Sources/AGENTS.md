# Sources/

> L2 | 父级: ../AGENTS.md

- VorsmateCore/：纯规则、稳定身份与持久化；不依赖界面或设备 API。
- CAudioListeners/：CoreAudio 原生 block 生命周期桥，确保监听配对移除。
- VorsmateSystem/：系统适配器与可测试的主线程控制器，依赖 Core、CAudioListeners 和 CReceiverStatus。
- Vorsmate/：AppKit 入口与 SwiftUI 界面，组合 Core、System、Fan、RemoteUI 和 Sparkle。Application 负责启动和持久化，Panel 负责导航和模块登记，功能目录落地各自界面与状态。
- CSMC/：MIT C 桥，IOKit 读写协议和数据类型转换。
- VorsmateFan/：风扇硬件适配、执行与 XPC，依赖 Core / CSMC。
- VorsmateFanHelper/：独立 root 助手，仅接受经过签名验证的固定风扇请求。
- VorsmateRemote/：独立遥控器应用及宿主管道、HID 与音频执行，依赖 Core 和 RemoteUI。
- VorsmateRemoteUI/：遥控器共享界面和录键组件，依赖 Core。
- CReceiverStatus/：无线接收器 USB 只读状态桥。

同一功能在应用、规则、适配器和测试中使用相同的目录名。按现有目标的职责选择落点。跨目标的直接导入在 Package.swift 声明，CI 使用 SwiftPM 的显式依赖检查。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
