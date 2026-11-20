# VorsmateCore/

> L2 | 父级: ../AGENTS.md

- SelectionPolicy.swift：Channel、Source、Snapshot、SelectionPolicy；单次及 IndexSet 批量插入排序、锁定与未就绪回退，运行时就绪状态独立于持久优先级。
- ReceiverStatus.swift：无线连接状态帧的流式校验、版本与记录识别、连接 / 断连确认和过期；不读取音量判断就绪。
- RemoteProfile.swift / RemoteGestures.swift：RC003 三槽报告、独立键位存储、手势截止时间与互斥触发。
- RemoteDeviceIdentity.swift：键位接管与只读诊断共用的 RC003 HID 匹配条件与映射标记。
- RemoteApplicationMaps.swift：前台应用的逐手势覆盖、默认继承、按住模式与配置编辑。
- RemoteEditor.swift：宿主与插件的按键编辑消息、实体键反馈、配置校验与单手势更新。
- RemoteModifiers.swift / RemoteVoice.swift：左右修饰键解析、16 kHz 能力识别、独立 IMA ADPCM 解码与既有音频 UID。
- PluginID.swift：内置与可选模块顺序、标题、图标与通道映射。
- ShutdownPolicy.swift：关机 / 重启动作、强制退出 / 窗口恢复偏好与按 Bundle ID 聚合的应用条目。
- Preferences.swift：兼容 version 1 的插件禁用、风扇档位、关机偏好与 PreferencesStore；配置版本检查、目录锁内核对预期值并原子写入 JSON；遥控器配置与导入工具沿用同一锁约定。
- SwitchBudget.swift：切换间隔与竞争次数上限；由外部单调时钟驱动。
- FanPolicy.swift：模式、读数、控制配置、温度与硬件范围校验；旧阈值仍作线性配置读取，保留字段和模式编码。
- FanCurvePreset.swift：均衡 / 强冷的分段曲线与响应参数唯一来源；不访问硬件，不替代系统压力保护。
- FanCurveController.swift：分档温度平滑、有限升温趋势提前量、原始 / 平滑目标双重确认、接管时系统转速下界、升降速限速与回差释放；只保留内存状态，不由热点强制全速。
- TimeComparison.swift：当地 / 美西的公历时间、时差、跨日与 PST / PDT；默认跟随系统时区，支持注入，LocalDayTimeline 处理 23 / 25 小时当天滑杆。

- UpdatePolicy.swift：固定签名 feed / 发布页地址、对应官方新旧命名安装包校验与语义版本规则；解析、版本选择和双重验签交由 Sparkle。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
