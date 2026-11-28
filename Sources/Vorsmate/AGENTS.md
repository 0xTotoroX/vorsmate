# Vorsmate/

> L2 | 父级: ../../AGENTS.md

- Application/AppMain.swift：NSApplication、原生编辑与关闭窗口快捷键、NSStatusItem / NSPopover、一键关机与无人值守授权菜单栏常显及右键快速操作、显隐与实例检查；开发版标记及同路径实例交接，兼容现有检查、预览（含 `--preview-translate-window`）和面板入口。
- Panel/PanelAutomation.swift：向同一路径的运行实例发送开始 / 结束命令，管理自动化保持和两分钟超时。
- Application/DevelopmentFanHelper.swift：固定签名开发包的助手移交、系统登记与应答进程路径核对。
- Panel/PanelDismissal.swift：鼠标离开约半秒收起，原生菜单范围 / 拖动 / 键盘 / 自动化保护；仅面板可见时观察，不影响后台管理。
- Panel/BrandIcon.swift：加载包内的单色海鸥矢量图，菜单栏使用 18 点、面板顶部居中使用 42 点模板图像；开发裸程序无资源时回退到字母符号。
- Application/AppModel.swift：应用组合、配置更新与冲突保护、面板显隐和退出停止。关机前释放已授权助手，失败时恢复风扇档位。开发版沿用设备与偏好，支持固定包路径的登录项管理。
- Application/PreviewOptions.swift：统一解析内存预览的主题、模拟内容和初始页面，普通启动不应用预览开关。
- Panel/PanelView.swift：总览页的三分类导航、动态分组、原地展开与详情切换；内容超过屏幕适配上限后滚动。
- Panel/PanelPluginRegistry.swift：每个模块在同一条登记中提供启停、观察信号与分类指示，面板生命周期由 PluginHost 管理。
- Panel/PluginOrderManagerView.swift：更多菜单中的「功能模块…」页，跟随总览的分类和组内排序，待办固定在信息末项。
- Devices/ChannelView.swift：三通道共用模式和单份选择 / 拖动列表装配，8 项及以内完整展开，超过 8 项以 7.5 行（330pt）露半行暗示滚动；不显示排序入口或移动图标，等待与错误反馈保留。
- Devices/SourceList.swift：AppKit 无滚动条隐式滚动列表桥（`SilentScrollView` + `ZeroScroller` 锁定 `.overlay` 且零占位宽度），三点起拖、预览让位、松手一次保存；取消 / 外部配置变化回滚、关闭清理、边缘滚动、点击与键盘选择分离。
- Devices/SourceRow.swift：原生行内容、离线状态 / 移除、辅助动作和可中断弹簧；轻微抬起，系统减少动态效果时停用动画。
- Panel/PanelSummaryRow.swift：共用总览摘要行（PanelSummaryRow / PanelActionSummaryRow）、分组卡片（PanelSectionCard）、内联展开卡片（PanelInlineCard）与内联提示（PanelInlineNotice）；悬停只强调箭头。
- Fan/FanModel.swift：保存全档位、启动 / 唤醒恢复、睡眠与关机前释放 / 唤醒或关机失败恢复、空闲停轮询；后台读数不切换界面忙碌态，串行请求与代次检查防止停用后的迟到接管。
- Fan/FanModelDriver.swift：真实 SMC / XPC / SMAppService 与内存预览的可替换边界，支持无硬件模型测试。
- Remote/RemotePanel.swift：同一菜单栏面板的全键列表、模型点选、原生方案 / 动作选单、键帽重录与 Typeless 诊断入口。
- Remote/RemoteCompanion.swift：发现并验证同目录配套应用，按开关管理子进程、控制管道、配置回执与当前生效方案名称，传递遥控器语音的就绪状态。
- Screenshot/TranslationModel.swift：截图工作流状态机，编排全局截图热键注册、矢量标注、按需 OCR／双引擎翻译回填、图片保存与桌面贴图生命周期。
- Screenshot/TranslationSceneSession.swift：面板和叠层共享的截图选区、标注、译文图层状态与合成图像缓存。
- Screenshot/TranslationPanelView.swift：总览内「截图」摘要行、就地展开「开始截图」入口及统一内联卡片中的快捷键 / 双引擎预设 / 密钥 / 语种设置。
- WindowDrag/WindowDragSectionView.swift：工具分类中的窗口拖动摘要行、修饰键菜单和辅助功能授权入口，复用面板原地展开。
- Tasks/TasksModel.swift 管理待办读取、按项目新增、带原标题核对的改名和勾选，按需打开随附或已安装的提醒事项连接器。停用时取消轮询与在途请求。
- Tasks/TasksView.swift 在同宽菜单栏内显示项目清单、行内新增与改名、独立的勾选按钮，按系统外观呈现。
- Screenshot/SystemTranslationBridge.swift：macOS 15+ Apple `Translation` 框架 `.translationTask` 离线批量翻译桥接与离线预览替身。
- Screenshot/ScreenshotOverlayWindow.swift：全屏框选与浮动贴图协调器（OverlayKeyWindow、ScreenshotOverlayController）。
- Screenshot/ScreenshotCaptureCanvas.swift：全屏窗口吸附框选画布、三分线与实时矢量标注绘制（CaptureCanvasView）。
- Screenshot/ScreenshotOverlayToolbar.swift：Liquid Glass A2 纯图标工具条、矢量图标绘制与玻璃修饰器（SceneOverlayToolbarView）。
- Screenshot/ScreenshotPinnedSticker.swift：支持多图独立滚轮缩放、透明度调节与悬停操作条的桌面贴图窗口（PinnedStickerWindow / PinnedStickerContent）。
- Remote/TypelessRecoveryPanel.swift：菜单栏内的诊断详情、保存后确认及有时限的正常退出流程；预览用内存替身。
- Panel/PluginHost.swift：内置与可选插件生命周期协议、注册表、幂等启停、刷新 / 显隐分发与开关持久化失败保护；时间资源随视图启停。
- Power/QuickShutdownView.swift：菜单栏关机详情、应用勾选和搜索、退出选项、摘要 / 详情取消入口、清理与提交反馈（倒计时展示于菜单栏，保留彩色日落动画 SunsetMark）。
- Authorization/UnattendedAuthView.swift：菜单栏无人值守授权详情页，包含本机钥匙串密码录入 / 更换 / 删除、可展开自动批准选项（隐私与安全 / 软件权限许可 / 密码与通行密钥 / 已弹出的请求）、可选截止时间设置、辅助功能授权引导、运行状态一键关闭与脱敏活动记录。
- Fan/FanView.swift：摘要显示自动 / 均衡 / 增强 / 自定义与实测值；展开为四个并列选项，自定义显示固定转速滑杆，兼容原有档位和旧自定义曲线；悬停区分热点与参考温度，临时保护与确认失败明确显示。
- Time/TimeComparisonView.swift：当地 / 美西双时钟，响应系统时区变化，点击展开当天滑杆与双向日期编辑；完成保留换算，现在 / 关闭面板复位，仅可见时定时更新。

- Updates/UpdateModel.swift：固定签名 feed 的定时 / 手动检查、独立 Sparkle 会话、来源校验和安全重试；不调用 GitHub API，不改配置或助手注册。
- Updates/UpdateUserDriver.swift：检查 / 下载停滞 / 准备的截止时间、取消与迟到回调隔离；重试前立即确认框架错误，复用同一窗口，框架负责双重验签和安装。
- Updates/UpdateFailure.swift：更新阶段 / 截止时间配置和嵌套网络、HTTP、签名、配置及安装错误的中文分类。
- Updates/UpdatePanel.swift：紧凑原生更新窗口、进度及一次性操作 / 关闭语义。

- `Panel/CategoryScrollReceiver.swift` 识别总览面板内的横向滚轮与触控板手势，过滤惯性及纵向滚动。
- `InformationFeeds/PanelFeed.swift` 保存单项最近读数并按可见性、数据源刷新周期与失败状态安排下次读取。
- `InformationFeeds/WeatherMarketsView.swift` 展示天气、选城与三项行情。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
