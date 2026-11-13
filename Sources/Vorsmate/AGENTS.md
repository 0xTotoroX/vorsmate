# Vorsmate/

> L2 | 父级: ../AGENTS.md

- AppMain.swift：NSApplication、NSStatusItem / NSPopover、按内容伸缩、显隐通知与实例检查；`--inspect` / `--preview` / `--show` 入口。
- PanelDismissal.swift：鼠标离开约半秒收起，原生菜单范围 / 拖动 / 键盘保护；仅面板可见时观察，不影响后台管理。
- BrandIcon.swift：加载包内单色矢量 V，菜单栏和面板标题共用 18 点模板图像；开发裸程序无资源时回退到字母符号。
- AppModel.swift：三通道装配、配置冲突保护与恢复、登录状态、面板可见性、无品牌演示设备与内存预览（`--preview-long-list` 扩展滚动验收数据）、显式 `--maintenance` 标记。
- PanelView.swift：系统玻璃总览、单项展开装配与三项日常菜单；内容超过屏幕适配上限后滚动，登录授权入口仅在需要时出现。
- ChannelView.swift：三通道共用模式和单份选择 / 拖动列表装配，不显示排序入口或移动图标，等待与错误反馈保留。
- SourceList.swift：AppKit 滚动列表桥，三点起拖、预览让位、松手一次保存；取消 / 外部配置变化回滚、关闭清理、边缘滚动、点击与键盘选择分离。
- SourceRow.swift：原生行内容、离线状态 / 移除、辅助动作和可中断弹簧；轻微抬起，系统减少动态效果时停用动画。
- PanelSummaryRow.swift：共用摘要行，左侧功能 / 管理状态，右侧当前设备或实测值；长名称与等待反馈，悬停只强调箭头。
- FanModel.swift：只读监控与助手控制确认分离、忽略迟到状态、命令失败后回读实际模式、显式助手启停、持续续期、退出 / 睡眠释放与内存预览。
- FanView.swift：摘要显示自动 / 增强档位与实测值；展开自动 / 增强散热 / 固定，增强仅均衡 / 强冷，不显示温度编辑器；悬停区分热点与参考温度，临时保护与确认失败明确显示。
- TimeComparisonView.swift：当地 / 美西双时钟，响应系统时区变化，点击展开当天滑杆与双向日期编辑；完成保留换算，现在 / 关闭面板复位，仅可见时定时更新。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
