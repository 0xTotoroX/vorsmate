# VorsmateUITests/

> L2 | 父级: ../../AGENTS.md

- Devices/SourceListTests.swift：AppKit 合成事件验证三点即时起拖、点击与排序分离、松手一次提交、取消、保存回滚、边缘停留自动滚动及回读 / 外部配置变化、界面重绘前的过时提交、动画移除命中保护及保留窗口关闭；不连接真实硬件。真实鼠标手感仍需原生界面验收。

- Updates/UpdatePanelTests.swift：安装 / 稍后 / 关闭只消费一次回调，新状态保留及不可中断阶段的关闭保护。
- Updates/UpdateSessionTests.swift：可推进等待器覆盖检查前卡住、下载停滞 / 续期、立即确认框架错误、安全重试、旧回调隔离、后台安静失败与安装阶段保护，不请求网络或真实安装。

- Panel/PluginHostTests.swift：所有已注册模块组合生命周期 / 顺序、时间对照调序及待办末项、保存失败不改运行态、禁用跨实例恢复。
- Remote/TypelessRecoveryTests.swift：用内存替身验证实体键盘和遥控器故障提示、保存与确认的先后、取消及退出超时。
- Fan/FanModelTests.swift：Mock 风扇驱动验证四项并列选择的旧配置兼容、均衡 / 增强直接切换、固定 / 曲线保存和启动 / 唤醒恢复、空闲停轮询、未授权 / 争抢与停用在途命令隔离、后台读数安静刷新 / 去重、读取中切档和停用重启恢复。
- Screenshot/TranslationModelTests.swift：Mock 驱动验证截图插件启停、单入口框选、矢量标注增删与 Esc / 调整选区重置、纯 OCR 与错误保留、按需翻译对照与 DeepSeek 预设、贴图钉住与先关叠层再保存流程及录屏权限流。
- Tasks/TasksModelTests.swift 使用内存客户端验证插件启停、离线恢复、新增保存回执、并发改名冲突和勾选。

- `Panel/CategoryScrollTests.swift` 验证滚轮、触控板、惯性与纵向意图区分。`InformationFeeds/PanelFeedTests.swift` 验证取消、迟到结果与失败后保留读数。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
