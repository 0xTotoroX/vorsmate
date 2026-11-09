# VorsmateCore/

> L2 | 父级: ../AGENTS.md

- SelectionPolicy.swift：Channel、Source、Snapshot、SelectionPolicy；稳定身份、独立排序、锁定与离线回退。
- Preferences.swift：Preferences 与 PreferencesStore；配置版本检查、保存前核对会话预期值、JSON 原子保存。
- SwitchBudget.swift：切换间隔与竞争次数上限；由外部单调时钟驱动。
- FanPolicy.swift：模式、读数、控制配置、温度与硬件范围校验；旧阈值仍作线性配置读取，保留字段和模式编码。
- FanCurvePreset.swift：均衡 / 强冷的分段曲线与响应参数唯一来源；不访问硬件，不替代系统压力保护。
- FanCurveController.swift：分档温度平滑、有限升温趋势提前量、原始 / 平滑目标双重确认、接管时系统转速下界、升降速限速与回差释放；只保留内存状态，不由热点强制全速。
- TimeComparison.swift：当地 / 美西的公历时间、时差、跨日与 PST / PDT；默认跟随系统时区，支持注入，LocalDayTimeline 处理 23 / 25 小时当天滑杆。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
