# Vorsmate/

> L2 | 父级: ../AGENTS.md

- AppMain.swift：NSApplication、NSStatusItem / NSPopover、按内容伸缩、显隐通知与实例检查；`--inspect` / `--preview` / `--show` 入口。
- PanelDismissal.swift：鼠标离开约半秒收起，原生菜单范围 / 拖动 / 键盘保护；仅面板可见时观察，不影响后台管理。
- AppModel.swift：三通道装配、配置冲突保护与恢复、登录状态、面板可见性、无品牌演示设备与内存预览、显式 `--maintenance` 标记。
- PanelView.swift：系统玻璃总览、单项展开装配与三项日常菜单；内容超过屏幕适配上限后滚动，登录授权入口仅在需要时出现。
- ChannelView.swift：三个输入 / 音频通道共用的选择、模式、折叠优先级、恢复中 / 离线等待与持续异常反馈；恢复中不显示已锁定图标。
- PanelSummaryRow.swift：共用摘要行，左侧功能 / 管理状态，右侧当前设备或实测值；长名称与等待反馈，悬停只强调箭头。
- FanModel.swift：只读监控与助手控制确认分离、忽略迟到状态、命令失败后回读实际模式、显式助手启停、持续续期、退出 / 睡眠释放与内存预览。
- FanView.swift：摘要显示自动 / 增强档位与实测值；展开自动 / 增强散热 / 固定，增强仅均衡 / 强冷，不显示温度编辑器；悬停区分热点与参考温度，临时保护与确认失败明确显示。
- TimeComparisonView.swift：当地 / 美西双时钟，响应系统时区变化，点击展开当天滑杆与双向日期编辑；完成保留换算，现在 / 关闭面板复位，仅可见时定时更新。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
