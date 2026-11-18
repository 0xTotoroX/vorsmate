# VorsmateCoreTests/

> L2 | 父级: ../AGENTS.md

- RemoteConfirmTests.swift：13 个实体键报告、单击 / 双击 / 长按互斥、独立配置冲突保护、面板单手势修改和过期编辑拒绝。
- PolicyTests.swift：优先级、拖动上下 / 批量 / 边界、锁定重连、输入源、重试预算及配置保护；ControllerTests 验证三通道拖动单次保存、生效、无效移动不保存及失败重试不改锁定。
- ControllerTests.swift：FakeDriver 驱动的切换回读、冷却退避、无通知自动恢复、持续异常提示、成功后争抢限频、手动覆盖与取消复查；保留保存恢复、只读刷新、当前设备锁定与监听失败验证。
- AudioSnapshotTests.swift：模拟读取期间的设备回连，验证有界复核与不一致快照拒绝。
- ReceiverTests.swift：状态帧校验 / 分包 / 版本 / 同长度非状态包、静音无关、连接确认与过期、优先级 / 锁定回退及序列号匹配；ControllerTests 补充实际规则到驱动选择的回归。
- FanTests.swift：旧数据兼容、固定在高热点 / 正常压力下可选可持续、压力和读数异常保护、自动不受热点干预、参考温度独立、待命无拥有权、拒绝请求保留原模式、重新确认、外部争抢、责任失败与租约恢复。
- FanCurveTests.swift：两档持续中负载的实际差异、有限趋势提前量、小波动不变速、短脉冲不接管、系统目标下界、分档升降速、冷却释放及采样 / 时钟边界。
- TimeComparisonTests.swift：可注入的当地时区、非整点 / 反向 / 零时差、独立夏令时、跨年以及 23 / 25 小时滑杆边界。

- UpdateTests.swift：语义版本、对应官方新旧安装包命名匹配与外部域名 / 仓库、协议、路径和异常版本拒绝。

- PluginPreferencesTests.swift：旧版配置默认回退、新字段原子保存往返 / 冲突及六模块顺序。
- ShutdownTests.swift：Mock 驱动和可推进时钟验证五秒倒计时、15 种取消组合、排除 / 保存、温和 / 强制顺序、错误与预览反馈。
- FanCommandTests.swift：助手关机 / 重启固定无参数命令、额外载荷和未知动作拒绝。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md

- RemoteVoiceTests.swift：协议、解码、原输入优先级以及左右修饰键的回归。
