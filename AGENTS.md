# Vorsmate — 原生 Mac 选择管理

Swift 6 + Swift Package Manager + SwiftUI / AppKit + Sparkle + TIS + CoreAudio + IOKit / SMC。最低 macOS 14。

## 产品约定

- 简体中文界面；输入法、麦克风、播放设备分别管理。默认关闭，手动选择即锁定，自动模式按顺序选择可用项。
- 三个通道复用确定性的规则；不让新设备抢占既有顺序。锁定离线时回退，重连恢复；界面展示系统回读的真实状态。
- 支持的无线麦接收器需确认发射器连接才参与选择；仅插接收器、连接未知或状态过期时使用下一可用项，原优先级 / 锁定不变。只读厂商连接状态，不以静音、音量或说话停顿判断就绪。
- 短暂切换异常先冷却并保留监听；5 / 10 / 20 / 30 秒间隔单次复查重试，正常回读即恢复原锁定 / 优先级。进入恢复状态持续 30 秒才提示；用户关闭或退出立即取消复查，配置与监听失败仍明确报错。
- 总览左侧显示功能与状态，右侧显示当前设备或实测值。顶部按「设备 · 工具 · 系统」分类切换并支持持久化重排，时间、输入法、麦克风、播放设备、风扇和截图原地展开，一次只开一项。一键关机、无人值守授权和遥控器在同一弹层内进入详情。「更多 → 功能模块…」在同宽页面（`PluginOrderManagerView`）统一管控所有插件的启停开关与分类内顺序。设备选择与拖动排序共用一份列表，松手一次保存。错误与等待状态在收起时仍可见。导航与视觉约定见 [DESIGN.md](DESIGN.md) 与 [docs/design-system.md](docs/design-system.md)。
- 面板离开操作区域约半秒收起，拖动 / 键盘和原生菜单有交互保护；收起不停止后台管理。日常菜单包含功能模块…、登录时启动、检查更新、关于、退出；助手停用仅供显式 `--maintenance` 安装维护入口。
- 产品文案只写本项目功能；实际引入的第三方源码保留必要的版权与许可通知。
- 不修改其他已安装管理软件的配置，不隐式注册登录项，不自动发布或安装。
- 日常使用固定路径的开发版。功能完成并通过隔离验收后，用 `bash scripts/dev.sh` 增量构建并重开日常实例。开发版沿用日常配置和真实设备，停用更新与登录项管理，普通签名校验仍适用。启用本机 `vorsmate.followFanHelper` 后，同次重载同步包内助手并校验实际应答；首次系统授权或撤销授权后由用户确认。`--build-only` 独立生成验收包，实际验收使用 `--preview` 或替身。正式包使用 `bash scripts/prepare-release.sh vX.Y.Z` 从验收标签单独构建。
- 风扇首次默认自动（系统控制），调速通过用户授权的独立助手。固定 / 增强保存至配置，启用插件且助手已授权、无竞争工具时在启动与唤醒恢复；睡眠、停用、退出释放硬件但保留档位。面板隐藏且无保存 / 生效档位时暂停主进程轮询。只恢复本助手接管的风扇，不自动开启全局诊断解锁。
- 界面为自动 / 均衡 / 增强 / 自定义四个并列选项；均衡和增强对应原曲线，自定义调节固定转速，旧配置格式不变。自动不受自定义阈值干预。增强在已实测 Mac16,10 使用独立 PMU tdie 参考温度：均衡 70–95°C、确认 8 秒；增强 60–90°C、确认 4 秒。分段曲线让持续中负载下两档有实际转速差，持续上升采用有限提前量，降温缓降；参数见 docs/fan-control.md。这些是本项目偏好，不是芯片极限。最高核心温度仅监控；缺少参考读数或机型未核验时保持自动，不回退到热点驱动。
- 增强待命不拥有硬件；目标高于系统当前目标才接管，从现有转速平滑变化，冷却后释放拥有权并保留增强选择。系统严重 / 临界压力或无效温度立即交回自动，增强恢复稳定 10 秒后重新确认持续升温；失联、退出、故障与外部争抢终止本次控制。固定转速不再以最高核心热点 90°C 阻止选择或退出；仅在读数有效、系统压力正常 / 轻度及硬件范围内允许控制，触发保护后不自动恢复固定。
- 控制意图与硬件读数分别确认：助手未响应时显示待确认，不能用只读 SMC 的空配置伪装为系统模式；迟到的查询不覆盖用户新操作。
- 时间对照使用系统当前时区与 America/Los_Angeles，按所选时刻分别处理夏令时；运行中跟随时区变化，当天滑杆按实际日长换算。顶部常显双时钟，点时钟展开滑杆与日期编辑；完成时保留换算，关闭面板回到当前时间，不改变系统时区。
- macOS 26+ 使用系统弹出面板和原生 Liquid Glass；不叠加普通模糊底，减少透明度时保留可读底面，旧系统保留材质回退。

- 内置插件按 time / inputSource / audioInput / audioOutput / fan / quickShutdown / unattendedAuth 排列，全部默认启用；通道内管理与无人值守授权仍默认关闭。PluginHost 统一激活、停用、刷新和显隐通知，禁用立即释放监听 / 定时器 / 控制；分隔线只存在于两个启用模块之间。Preferences 继续 version 1，缺失新字段回退默认，原子保存。
- 一键关机在系统分类：五秒倒计时在菜单栏图标旁显示，鼠标移开或收起面板仍继续执行；面板与菜单栏右键、插件停用均可取消未提交动作；只清理常规应用，跳过自身、Finder、系统基础服务及用户排除项，强制退出在 AppKit 之后以 SIGKILL 终止忽略普通退出的进程。关闭强制选项时，未退出应用阻止关机；“跳过”只跳过清理，不能阻止系统最终退出应用。启用风扇助手时先通过原连接释放风扇控制，再统一写好不恢复窗口标记并走 System Events 正常图形关机 / 重启，使 loginwindow 正常注销并保留排除应用的退出状态；系统事件失败时恢复风扇控制。所有开发验收使用 Mock 或 --preview，严禁关机、重启或关闭真实运行应用；不覆盖 /Applications/Vorsmate.app。
- 无人值守授权在系统分类：默认关闭且重启恢复关闭；密码经本机校验后仅保存于本机非同步钥匙串（不上云、不写日志 / 剪贴板 / 活动记录）。截止时间可选，默认按时长 30 分钟，未设截止不显示到期时间或剩余时长；锁屏不改变开关，截止时间按墙钟照常生效。开启期间菜单栏常显状态并支持右键、总览或详情一键关闭；常规系统管理员弹窗外，可通过选项开关「隐私与安全」「软件权限许可」（仅经 `anchor apple` 验签并匹配明确“允许/不允许”权限句式的系统弹窗，绝不回退默认按钮或模拟鼠标）、「密码与通行密钥」（仅验证为 Apple 授权服务的远程控件）与「已弹出的请求」自动批准（默认全开）；关闭选项、受阻或未覆盖弹窗保留由本人确认，绝不伪装为已批准。规则与未实机验证边界见 [docs/unattended-auth.md](docs/unattended-auth.md)。

- 更新在启动一分钟后及每 12 小时直接读取固定 updates 分支的签名 feed，不调用 GitHub API 或 /latest；Sparkle 必须验证 feed 与安装包的双重 Ed25519 签名。检查 20 秒截止，下载无进展 60 秒、准备 120 秒截止；取消与失败后可重试，旧会话回调不能覆盖新状态，实际安装阶段不强制中断；更新不修改 settings.json 或注销助手。安装前用户确认，所有反馈复用紧凑窗口。预览不启动网络更新。Release 只附 DMG、说明仅列英中功能变化；appcast.xml 单独发布到固定 updates 分支，见 docs/updates.md。

- 小米遥控器是独立、默认关闭的可选插件。配套包与宿主同目录，拥有自己的输入权限；RC003 全键映射、配置导入、左右修饰键、遥控器音频与实机验收见 [docs/remote.md](docs/remote.md)。
- 截图是默认关闭的可选插件，支持全屏窗口吸附与聚焦框选、矩形 / 箭头 / 画笔矢量标注、Apple Vision 文字识别复制、按需原场景译文回填（支持原图对照与复制译文）、图片保存以及可缩放调透明度的纯图标桌面贴图；默认采用 macOS 系统离线翻译，并可选配置自定义 OpenAI 兼容模型接口（内置 DeepSeek / OpenAI / Ollama 预设，密钥仅存本机非同步钥匙串，不写配置或日志）；停用立即注销热键并销毁叠层与贴图窗口。
- 窗口拖动是工具分类下默认关闭的可选插件。获得辅助功能授权后，按住所选修饰键（默认 ⌥ Option）可以用左键从可移动窗口内部拖动。使用按下时的窗口及相对偏移，目标应用短暂忙碌后继续跟随最新位置。松键即停止，保留修饰键单击及不可移动窗口的原始输入。预览使用内存状态，停用释放监听。
- 待办是「工具」分类下默认关闭的可选插件，仅连接本机 `0xTotoro` Local Hub（`~/.local/share/0xTotoro/runtime.json`），在缺少配置或服务未启动时保持未连接状态且不阻塞主程序；启用后按 `Project` 分组列表展示未完成待办、分区标签（如 `测试分区`）、一键完成、1 行快速添加与 `codex://` 跳转，停用立即停止轮询与请求。

工具页的天气与行情分别启停。只有在面板内显示时才请求外部数据。总览按可见分类顺序处理水平滚动，每次手势切换一页，边界停止，纵向滚动沿用原控件。

## 地图

| 路径 | 职责 |
| --- | --- |
| [Sources/VorsmateRemote](Sources/VorsmateRemote/AGENTS.md) | 可选 RC003 插件、后台设备接入、配置写入与听写输出 |
| [Sources/VorsmateRemoteUI](Sources/VorsmateRemoteUI/AGENTS.md) | 菜单栏和独立验收共用的模型、按键名称与快捷键录入 |
| [Sources/VorsmateCore](Sources/VorsmateCore/AGENTS.md) | 数据、优先级、锁定、配置、重试预算与时间换算 |
| [Sources/VorsmateSystem](Sources/VorsmateSystem/AGENTS.md) | 系统适配、通知、切换与回读控制器 |
| [Sources/CAudioListeners](Sources/CAudioListeners/AGENTS.md) | CoreAudio 原生监听句柄，配对注册与移除 |
| [Sources/CReceiverStatus](Sources/CReceiverStatus/AGENTS.md) | 无线麦厂商 USB 接口的限时只读状态流 |
| [Sources/VorsmateFan](Sources/VorsmateFan/AGENTS.md) | 风扇监控、控制规则执行、XPC 双向身份校验 |
| [Sources/VorsmateFanHelper](Sources/VorsmateFanHelper/AGENTS.md) | 单一特权写入者、续期与恢复记录 |
| [Sources/CSMC](Sources/CSMC/AGENTS.md) | MIT AppleSMC 桥、只读键枚举与独立 PMU 温度读取 |
| [Sources/Vorsmate](Sources/Vorsmate/AGENTS.md) | 应用生命周期、装配、原生界面与只读检查入口 |
| [Tests/VorsmateCoreTests](Tests/VorsmateCoreTests/AGENTS.md) | 规则与控制器的无硬件测试 |
| [Tests/VorsmateUITests](Tests/VorsmateUITests/AGENTS.md) | AppKit 合成事件的拖动与取消回归，不访问真实硬件 |
| scripts/build.sh / scripts/package.sh | 构建本机或 Universal 签名应用，打包 DMG；不安装、不上传 |
| scripts/appcast.sh / Package.resolved | 签名更新描述与 Sparkle 依赖锁定；私钥留在钥匙串 |
| scripts/make-icon.swift / Resources/AppIcon* / Resources/StatusIcon.pdf | 展翼应用图标母版、各尺寸导出和同轮廓菜单栏单色矢量标记 |
| Resources/Remote/ | 可选插件元数据、原创 RC003 Blender 模型及正面按键投影 |
| Resources/Info.plist / Resources/Vorsmate.entitlements / Resources/Install.txt | 应用身份、最低系统、版本、系统动作回退声明与双语安装说明 |
| Resources/LaunchDaemons/ | SMAppService 助手注册描述；注册不等于授权通过 |
| THIRD_PARTY_NOTICES.md / LICENSES/ | 来源、修改边界与随应用分发的第三方许可 |
| DESIGN.md | 总览、原地展开、详情导航及菜单的使用边界与原生视觉约定 |
| [docs](docs/AGENTS.md) | 设计语言与设计系统、风扇、无人值守授权等专题说明、验证范围与未验证项 |
| [.github](.github/AGENTS.md) | macOS 自动检查与 PR 说明模板，不自动发布应用 |
| .swift-format | Swift 代码格式唯一配置，开发与 CI 共用 |
| README.md / README.en.md / CONTRIBUTING.md / SECURITY.md | 使用、贡献与私密漏洞报告入口 |

## 验证

Swift 改动运行仓库 `.swift-format` 对应的格式检查；规则与系统控制变化运行 `swift test`；应用变化运行 `bash scripts/build.sh`。`--inspect` 只读检查真实设备；`--preview` 只用虚构设备。界面修改须观察原生界面，编译不能代替验收。真实插拔、睡眠唤醒、登录启动与签名分发分别记录，不能用模拟测试冒充。

验收真实菜单栏时，先确认正在运行的 App 包。用其 `Contents/MacOS/Vorsmate` 可执行文件调用 `--computer-use-panel begin "$session_id"` 打开并保持弹层，其中 `session_id` 由 `uuidgen` 生成。读取最新辅助功能状态后操作，完成或中止时用同一标识调用 `--computer-use-panel end "$session_id"`。保持两分钟后自动结束，同一标识再次开始可以续期。旧构建的后台重开入口是 `open -g "$app_bundle"`。系统鼠标由用户控制，状态栏实际点按或物理指针移出的验收由用户配合执行。

实际系统切换应先识别是否有其他管理工具运行，保留当前选择与配置；不把关停其他软件作为默认测试步骤。用户设备 UID、个人配置与本机诊断输出留在忽略的 `artifacts/`，不提交。
