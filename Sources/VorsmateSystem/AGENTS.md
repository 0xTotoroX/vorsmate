# VorsmateSystem/

> L2 | 父级: ../AGENTS.md

- SourceDriver.swift：主线程驱动协议与可见的系统错误。
- InputSourceDriver.swift：TIS 输入源枚举与切换；输入源和工作区通知。
- AudioDeviceDriver.swift：CoreAudio 输入 / 输出设备枚举、默认设备写入、插拔期间有界复核；经 CAudioListeners 配对管理监听。
- ChannelController.swift：ObservableObject 运行时；监听就绪后切换、有界回读，短暂异常冷却后单次退避重试、回读正常自动恢复；持续异常才提示，保存失败仍立即显示；停用后取消复查并拒绝迟到通知，保留只读刷新与配置重载。

适配器不录音、不监听按键；测试通过 SourceDriver 替身驱动控制器。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
