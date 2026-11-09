# Sources/

> L2 | 父级: ../AGENTS.md

- VorsmateCore/：纯规则、稳定身份与持久化；不依赖界面或设备 API。
- CAudioListeners/：CoreAudio 原生 block 生命周期桥，确保监听配对移除。
- VorsmateSystem/：TIS / CoreAudio 驱动与可测试的主线程控制器，依赖 Core / CAudioListeners。
- Vorsmate/：AppKit 入口与 SwiftUI 界面，组合 Core / System。
- CSMC/：MIT C 桥，IOKit 读写协议和数据类型转换。
- VorsmateFan/：风扇硬件适配、执行与 XPC，依赖 Core / CSMC。
- VorsmateFanHelper/：独立 root 助手，仅接受经过签名验证的固定风扇请求。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
