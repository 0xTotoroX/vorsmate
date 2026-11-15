# Vorsmate/

> L2 | 父级: ../AGENTS.md

- AppMain.swift：NSApplication、NSStatusItem / NSPopover、按内容伸缩、显隐通知与实例检查；`--inspect` / `--preview` / `--show` 入口。
- PanelDismissal.swift：鼠标离开约半秒收起，原生菜单范围 / 拖动 / 键盘保护；仅面板可见时观察，不影响后台管理。
- BrandIcon.swift：加载包内单色矢量 V，菜单栏和面板标题共用 18 点模板图像；开发裸程序无资源时回退到字母符号。
- AppModel.swift：六模块 PluginHost 装配、兼容配置和模块开关保存、配置冲突保护与恢复、登录状态、面板可见性、无品牌演示设备与内存预览（`--preview-long-list` 扩展滚动验收数据）、显式 `--maintenance` 标记。
- PanelView.swift：动态插件列表与无首尾 / 重复分隔线、单项展开和功能模块二级菜单；内容超过屏幕适配上限后滚动，登录授权入口仅在需要时出现。
- ChannelView.swift：三通道共用模式和单份选择 / 拖动列表装配，不显示排序入口或移动图标，等待与错误反馈保留。
- SourceList.swift：AppKit 滚动列表桥，三点起拖、预览让位、松手一次保存；取消 / 外部配置变化回滚、关闭清理、边缘滚动、点击与键盘选择分离。
- SourceRow.swift：原生行内容、离线状态 / 移除、辅助动作和可中断弹簧；轻微抬起，系统减少动态效果时停用动画。
- PanelSummaryRow.swift：共用摘要行，左侧功能 / 管理状态，右侧当前设备或实测值；长名称与等待反馈，悬停只强调箭头。
- FanModel.swift：保存全档位、启动 / 唤醒恢复、睡眠 / 停用释放、空闲停轮询；后台读数不切换界面忙碌态，串行请求与代次检查防止停用后的迟到接管。
- FanModelDriver.swift：真实 SMC / XPC / SMAppService 与内存预览的可替换边界，支持无硬件模型测试。
- PluginHost.swift：六插件生命周期协议、注册表、幂等启停、刷新 / 显隐分发与开关持久化失败保护；时间资源随视图启停。
- QuickShutdownView.swift：第五个展开模块、应用数量 / 倒计时摘要、关机 / 重启按钮、选项、跳过列表与执行反馈。
- FanView.swift：摘要显示自动 / 增强档位与实测值；展开自动 / 增强散热 / 固定，增强仅均衡 / 强冷，不显示温度编辑器；悬停区分热点与参考温度，临时保护与确认失败明确显示。
- TimeComparisonView.swift：当地 / 美西双时钟，响应系统时区变化，点击展开当天滑杆与双向日期编辑；完成保留换算，现在 / 关闭面板复位，仅可见时定时更新。

- UpdateModel.swift：官方 GitHub Releases 定时发现、检查菜单与 Sparkle 调度，不改配置或助手注册。
- UpdateUserDriver.swift：Sparkle 自定义交互层，检查 / 下载 / 准备 / 重启复用同一窗口，框架负责验签和安装。
- UpdatePanel.swift：紧凑原生更新窗口、进度及一次性操作 / 关闭语义。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
