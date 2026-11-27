# VorsmateSystem/

> L2 | 父级: ../AGENTS.md

- SourceDriver.swift：主线程驱动协议与可见的系统错误。
- InputSourceDriver.swift：TIS 输入源枚举与切换；输入源和工作区通知。
- AudioDeviceDriver.swift：CoreAudio 输入 / 输出枚举与写入、插拔期间有界复核；配对管理音频监听，并为输入通道附加 USB 接收器及 RC003 插件的就绪状态。
- ReceiverMonitor.swift：后台串行读取厂商接口，按 USB 序列号匹配音频 UID；有界读取、断连重开、过期回退和停止清理，不写接收器设置。
- ChannelController.swift：ObservableObject 运行时；选择与拖动松手单次保存、监听切换与有界回读、冷却重试与持续异常反馈；保存失败保持原策略，停用取消复查并拒绝迟到通知，保留只读刷新与配置重载。

- ShutdownController.swift：五秒倒计时、批量选择保存、开始时固定待退出进程、收起面板继续执行、取消反馈、强制退出有界回读与系统提交。
- ShutdownDriver.swift：常规应用枚举、退出前资格复核、温和退出与 SIGKILL 强制退出、原进程内核存活回读、CFPreferences 窗口恢复设置与 ByHost 列表清理、后台线程 System Events 动作与权限错误归类及纯内存预览。
- UnattendedAuthDriver.swift：本机非同步钥匙串密码存储、OpenDirectory 本地口令核验、开启时补查、事件监听与内存预览驱动。已有弹窗和「隐私与安全」内嵌弹窗只记录，交由本人确认。
- UnattendedAuthController.swift：主线程无人值守授权状态机；重启默认关闭、可选截止定时、锁屏状态保持与到期 / 失效核对、密码失效自动停用及脱敏活动记录。
- TranslationDriver.swift：ScreenCaptureKit 桌面快照与 CGWindowList 窗口矩形采集、录屏权限预检 / 引导、Vision 带位置框 OCR 区块提取、剪贴板图文读写、PNG 保存面板与离线预览替身。
- SceneImageRenderer.swift：屏幕选区像素裁切、局部背景 / 前景对比色采样、原场景文字回填与矢量标注叠加合成图像。
- TranslationService.swift：本机非同步钥匙串 API 密钥存储、NaturalLanguage 语种判断与 OpenAI 兼容批量翻译客户端（支持网络替身）。
- GlobalHotKeyCenter.swift：Carbon 全局截图热键线程安全注册与停用注销，附预览空实现。
- TypelessRecovery.swift：系统进程、事件监听、修饰键与遥控接管回读；保存诊断快照并提供 Typeless 的正常退出和打开操作。

适配器不录音、不监听按键；测试通过 SourceDriver 替身驱动控制器。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
