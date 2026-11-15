# VorsmateUITests/

> L2 | 父级: ../../AGENTS.md

- SourceListTests.swift：AppKit 合成事件验证三点即时起拖、点击与排序分离、松手一次提交、取消、保存回滚、边缘停留自动滚动及回读 / 外部配置变化、界面重绘前的过时提交、动画移除命中保护及保留窗口关闭；不连接真实硬件。真实鼠标手感仍需原生界面验收。

- UpdatePanelTests.swift：安装 / 稍后 / 关闭只消费一次回调，新状态保留及不可中断阶段的关闭保护。

- PluginHostTests.swift：全 64 组合生命周期 / 顺序、保存失败不改运行态及禁用跨实例恢复。
- FanModelTests.swift：Mock 风扇驱动验证固定 / 均衡 / 强冷保存和启动 / 唤醒恢复、空闲停轮询、未授权 / 争抢与停用在途命令隔离。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
