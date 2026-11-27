# VorsmateSystem/

> L2 | 父级: ../AGENTS.md

- SourceDriver.swift：主线程驱动协议与可见的系统错误。
- InputSourceDriver.swift：TIS 输入源枚举与切换；输入源和工作区通知。
- AudioDeviceDriver.swift：CoreAudio 输入 / 输出枚举与写入、插拔期间有界复核；配对管理音频监听，并为输入通道附加 USB 接收器及 RC003 插件的就绪状态。
- ReceiverMonitor.swift：后台串行读取厂商接口，按 USB 序列号匹配音频 UID；有界读取、断连重开、过期回退和停止清理，不写接收器设置。
- ChannelController.swift：ObservableObject 运行时；选择与拖动松手单次保存、监听切换与有界回读、冷却重试与持续异常反馈；保存失败保持原策略，停用取消复查并拒绝迟到通知，保留只读刷新与配置重载。

- ShutdownController.swift：五秒倒计时、批量选择保存、开始时固定待退出进程、收起面板继续执行、取消反馈、强制退出有界回读与系统提交。
- ShutdownDriver.swift：常规应用枚举、退出前资格复核、温和退出与 SIGKILL 强制退出、原进程内核存活回读、CFPreferences 窗口恢复设置与 ByHost 列表清理、后台线程 System Events 动作与权限错误归类及纯内存预览。
- UnattendedAuthCredentials.swift：本机非同步钥匙串密码存储、OpenDirectory 本地口令核验及内存 / 固定值测试替身。
- UnattendedAuthAccessibility.swift：Apple 进程签名核验（`anchor apple`）、有界 AX 弹窗 / 嵌套弹层遍历、软件权限许可弹窗识别、焦点远程控件归属查询、窗口存活判定与受控键盘提交辅助函数。
- UnattendedAuthDriver.swift：无人值守授权事件监听（含系统管理员弹窗、隐私与安全、应用软件权限许可及通行密钥 / Apple 密码内嵌远程验证服务）、开启时补查、审批流程协调、控件所属进程验签与内存预览驱动。
- UnattendedAuthController.swift：主线程无人值守授权状态机；重启默认关闭、按选项持久化并路由自动批准或保留本人确认、可选截止定时、锁屏状态保持与到期 / 失效核对、密码失效自动停用及脱敏活动记录。
- TranslationDriver.swift：ScreenCaptureKit 桌面快照与 CGWindowList 窗口矩形采集、录屏权限预检 / 引导、Vision 带位置框 OCR 区块提取、剪贴板图文读写、PNG 保存面板与离线预览替身。
- SceneImageRenderer.swift：屏幕选区像素裁切、局部背景 / 前景对比色采样、原场景文字回填与矢量标注叠加合成图像。
- TranslationService.swift：本机非同步钥匙串 API 密钥存储、NaturalLanguage 语种判断与 OpenAI 兼容批量翻译客户端（支持网络替身）。
- WindowDragMonitor.swift：会话级鼠标与修饰键监听、辅助功能权限状态和停用释放，预览使用内存。
- WindowDragGesture.swift：左键拖动阈值、点击还原、固定窗口与指针偏移，按上次写入时间合并移动，暂忙时追上最新位置，松键或停用取消重试。
- WindowDragTarget.swift：WindowServer 窗口命中、跨进程 AX 位置读写与宿主原生窗口移动，区分暂时通信失败和窗口不可移动。
- TasksHubClient.swift 每次访问时查找当前用户的提醒事项连接器，使用本机地址、原状态核对与可替换的网络传输。
- GlobalHotKeyCenter.swift：Carbon 全局截图热键线程安全注册与停用注销，附预览空实现。
- TypelessRecovery.swift：系统进程、事件监听、修饰键与遥控接管回读；保存诊断快照并提供 Typeless 的正常退出和打开操作。

适配器不录音、不监听按键；测试通过 SourceDriver 替身驱动控制器。

- `WeatherMarketClient.swift` 从 Open-Meteo 查询城市与天气，从 Nasdaq、CoinGecko 和 ExchangeRate-API 独立读取带时间的报价。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
