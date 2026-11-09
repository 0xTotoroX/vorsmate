# VorsmateCoreTests/

> L2 | 父级: ../AGENTS.md

- PolicyTests.swift：音频设备优先级、锁定重连、输入源、重试预算、配置往返与损坏保护。
- ControllerTests.swift：FakeDriver 驱动的切换回读、无通知重试、迟到通知、保存恢复、只读刷新、当前设备锁定与监听失败。
- AudioSnapshotTests.swift：模拟读取期间的设备回连，验证有界复核与不一致快照拒绝。
- FanTests.swift：旧数据兼容、固定在高热点 / 正常压力下可选可持续、压力和读数异常保护、自动不受热点干预、参考温度独立、待命无拥有权、拒绝请求保留原模式、重新确认、外部争抢、责任失败与租约恢复。
- FanCurveTests.swift：两档持续中负载的实际差异、有限趋势提前量、小波动不变速、短脉冲不接管、系统目标下界、分档升降速、冷却释放及采样 / 时钟边界。
- TimeComparisonTests.swift：可注入的当地时区、非整点 / 反向 / 零时差、独立夏令时、跨年以及 23 / 25 小时滑杆边界。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
