# Vorsmate — 原生 Mac 选择管理

Swift 6 + Swift Package Manager + SwiftUI / AppKit + TIS + CoreAudio + IOKit / SMC。最低 macOS 14。

## 产品约定

- 简体中文界面；输入法、麦克风、播放设备分别管理。默认关闭，手动选择即锁定，自动模式按顺序选择可用项。
- 三个通道复用确定性的规则；不让新设备抢占既有顺序。锁定离线时回退，重连恢复；界面展示系统回读的真实状态。
- 支持的无线麦接收器需确认发射器连接才参与选择；仅插接收器、连接未知或状态过期时使用下一可用项，原优先级 / 锁定不变。只读厂商连接状态，不以静音、音量或说话停顿判断就绪。
- 短暂切换异常先冷却并保留监听；5 / 10 / 20 / 30 秒间隔单次复查重试，正常回读即恢复原锁定 / 优先级。进入恢复状态持续 30 秒才提示；用户关闭或退出立即取消复查，配置与监听失败仍明确报错。
- 保持简洁。默认只显示总览：左侧功能与管理状态，右侧当前设备或实测值；点击整行展开操作，一次只展开一项。低频排序再折叠，错误与等待状态不随操作区隐藏；布局约定见 [DESIGN.md](DESIGN.md)。
- 面板离开操作区域约半秒收起，拖动 / 键盘和原生菜单有交互保护；收起不停止后台管理。日常菜单只有登录时启动、关于、退出；助手停用仅供显式 `--maintenance` 安装维护入口。
- 产品文案只写本项目功能；实际引入的第三方源码保留必要的版权与许可通知。
- 不修改其他已安装管理软件的配置，不隐式注册登录项，不自动发布或安装。
- 风扇启动只读；调速通过用户授权的独立助手。默认自动（系统控制），固定 / 增强不跨重启保存。只恢复本助手接管的风扇，不自动开启全局诊断解锁。
- 界面为自动 / 增强散热 / 固定；增强仅保留均衡 / 强冷。自动不受自定义阈值干预。增强在已实测 Mac16,10 使用独立 PMU tdie 参考温度：均衡 70–95°C、确认 8 秒；强冷 60–90°C、确认 4 秒。分段曲线让持续中负载下两档有实际转速差，持续上升采用有限提前量，降温缓降；参数见 docs/fan-control.md。这些是本项目偏好，不是芯片极限。最高核心温度仅监控；缺少参考读数或机型未核验时保持自动，不回退到热点驱动。
- 增强待命不拥有硬件；目标高于系统当前目标才接管，从现有转速平滑变化，冷却后释放拥有权并保留增强选择。系统严重 / 临界压力或无效温度立即交回自动，增强恢复稳定 10 秒后重新确认持续升温；失联、退出、故障与外部争抢终止本次控制。固定转速不再以最高核心热点 90°C 阻止选择或退出；仅在读数有效、系统压力正常 / 轻度及硬件范围内允许控制，触发保护后不自动恢复固定。
- 控制意图与硬件读数分别确认：助手未响应时显示待确认，不能用只读 SMC 的空配置伪装为系统模式；迟到的查询不覆盖用户新操作。
- 时间对照使用系统当前时区与 America/Los_Angeles，按所选时刻分别处理夏令时；运行中跟随时区变化，当天滑杆按实际日长换算。顶部常显双时钟，点时钟展开滑杆与日期编辑；完成时保留换算，关闭面板回到当前时间，不改变系统时区。
- macOS 26+ 使用系统弹出面板和原生 Liquid Glass；不叠加普通模糊底，减少透明度时保留可读底面，旧系统保留材质回退。

## 地图

| 路径 | 职责 |
| --- | --- |
| [Sources/VorsmateCore](Sources/VorsmateCore/AGENTS.md) | 数据、优先级、锁定、配置、重试预算与时间换算 |
| [Sources/VorsmateSystem](Sources/VorsmateSystem/AGENTS.md) | 系统适配、通知、切换与回读控制器 |
| [Sources/CAudioListeners](Sources/CAudioListeners/AGENTS.md) | CoreAudio 原生监听句柄，配对注册与移除 |
| [Sources/CReceiverStatus](Sources/CReceiverStatus/AGENTS.md) | 无线麦厂商 USB 接口的限时只读状态流 |
| [Sources/VorsmateFan](Sources/VorsmateFan/AGENTS.md) | 风扇监控、控制规则执行、XPC 双向身份校验 |
| [Sources/VorsmateFanHelper](Sources/VorsmateFanHelper/AGENTS.md) | 单一特权写入者、续期与恢复记录 |
| [Sources/CSMC](Sources/CSMC/AGENTS.md) | MIT AppleSMC 桥、只读键枚举与独立 PMU 温度读取 |
| [Sources/Vorsmate](Sources/Vorsmate/AGENTS.md) | 应用生命周期、装配、原生界面与只读检查入口 |
| [Tests/VorsmateCoreTests](Tests/VorsmateCoreTests/AGENTS.md) | 规则与控制器的无硬件测试 |
| scripts/build.sh / scripts/package.sh | 构建本机或 Universal 签名应用，打包 DMG 与校验文件；不安装、不上传 |
| scripts/make-icon.swift / Resources/AppIcon* / Resources/StatusIcon.pdf | “折影”母版、应用图标各尺寸导出和菜单栏单色矢量标记 |
| Resources/Info.plist / Resources/Install.txt | 应用身份、最低系统、版本与双语安装说明 |
| Resources/LaunchDaemons/ | SMAppService 助手注册描述；注册不等于授权通过 |
| THIRD_PARTY_NOTICES.md / LICENSES/ | 来源、修改边界与随应用分发的第三方许可 |
| DESIGN.md | 紧凑总览、按需展开与原生材质的当前设计约定 |
| [docs](docs/AGENTS.md) | 风扇说明、验证范围与未验证项 |
| [.github](.github/AGENTS.md) | macOS 自动检查与 PR 说明模板，不自动发布应用 |
| .swift-format | Swift 代码格式唯一配置，开发与 CI 共用 |
| README.md / README.en.md / CONTRIBUTING.md / SECURITY.md | 使用、贡献与私密漏洞报告入口 |

## 验证

Swift 改动运行仓库 `.swift-format` 对应的格式检查；规则与系统控制变化运行 `swift test`；应用变化运行 `bash scripts/build.sh`。`--inspect` 只读检查真实设备；`--preview` 只用虚构设备。界面修改须观察原生界面，编译不能代替验收。真实插拔、睡眠唤醒、登录启动与签名分发分别记录，不能用模拟测试冒充。

实际系统切换应先识别是否有其他管理工具运行，保留当前选择与配置；不把关停其他软件作为默认测试步骤。用户设备 UID、个人配置与本机诊断输出留在忽略的 `artifacts/`，不提交。
