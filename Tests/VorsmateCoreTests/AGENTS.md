# VorsmateCoreTests/

> L2 | 父级: ../../AGENTS.md

- Remote/RemoteApplicationTests.swift：应用覆盖与继承、旧配置升级与并发写入、禁用动作与原生键、连发节奏和切换时中止。
- Remote/RemoteConfirmTests.swift：13 个实体键报告、单击 / 双击 / 长按互斥与临界时间、独立配置冲突保护、面板单手势修改和过期编辑拒绝。
- Devices/PolicyTests.swift：优先级、拖动上下 / 批量 / 边界、锁定重连、输入源、重试预算及配置保护；ControllerTests 验证三通道拖动单次保存、生效、无效移动不保存及失败重试不改锁定。
- Devices/ControllerTests.swift：FakeDriver 驱动的切换回读、冷却退避、无通知自动恢复、持续异常提示、成功后争抢限频、手动覆盖与取消复查；保留保存恢复、只读刷新、当前设备锁定与监听失败验证。
- Devices/AudioSnapshotTests.swift：模拟读取期间的设备回连，验证有界复核与不一致快照拒绝。
- Devices/ReceiverTests.swift：状态帧校验 / 分包 / 版本 / 同长度非状态包、静音无关、连接确认与过期、优先级 / 锁定回退及序列号匹配；ControllerTests 补充实际规则到驱动选择的回归。
- Fan/FanTests.swift：旧数据兼容、固定在高热点 / 正常压力下可选可持续、压力和读数异常保护、自动不受热点干预、参考温度独立、待命无拥有权、拒绝请求保留原模式、重新确认、外部争抢、责任失败与租约恢复。
- Fan/FanCurveTests.swift：两档持续中负载的实际差异、有限趋势提前量、小波动不变速、短脉冲不接管、系统目标下界、分档升降速、冷却释放及采样 / 时钟边界。
- Time/TimeComparisonTests.swift：可注入的当地时区、非整点 / 反向 / 零时差、独立夏令时、跨年以及 23 / 25 小时滑杆边界。

- Updates/UpdateTests.swift：语义版本、对应官方新旧安装包命名匹配与外部域名 / 仓库、协议、路径和异常版本拒绝。

- Configuration/PluginPreferencesTests.swift：旧版配置默认回退、新字段原子保存往返 / 冲突、可选插件的独立开关及模块顺序（含无人值守授权、截图、待办）。
- WindowDrag/WindowDragTests.swift：用合成事件和内存窗口验证普通输入透传、点击与轻微抖动、标题栏预读与遮挡复核、初始抓取点和提前松手、跨坐标拖动、暂忙恢复，以及松键和停用取消重试。
- Tasks/TasksPolicyTests.swift：runtime.json 解析 / 离线回退、Reminders tree 投影、codex:// 校验与 Mock Hub HTTP 客户端测试。
- Screenshot/TranslationPolicyTests.swift：快捷键校验、语种解析、DeepSeek 预设与 OpenAI 地址校验、旧配置兼容解码、OCR 区块合并、选区几何与标注合成渲染、预览保存及 Mock 批量翻译测试。
- Power/ShutdownTests.swift：Mock 验证倒计时与 15 种取消组合、清理与回读期间取消、批量排除、固定应用范围、退出顺序、终端强制退出回读 / 超时和等待回执防重。
- Authorization/UnattendedAuthTests.swift：内存替身与可注入时钟验证重启默认关闭、可选截止与状态文案、锁屏保持与到期 / 失效核对、受阻不伪装批准、密码变更 / 删除、活动记录脱敏往返与停用清理。
- Fan/FanCommandTests.swift：助手关机 / 重启固定无参数命令、额外载荷和未知动作拒绝。

- `InformationFeeds/WeatherMarketTests.swift` 验证天气和行情解码、来源日期以及缺价行为。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md

- Remote/RemoteVoiceTests.swift：协议、解码、语音首包及断流、原输入优先级以及左右修饰键的回归。
