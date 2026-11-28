<div align="center">
  <img src="Resources/AppIcon.png" alt="Vorsmate" width="96" />
  <h1>Vorsmate</h1>
  <p>原生 Mac 菜单栏面板，集中管理输入法、音频设备、风扇、时间对照与常用系统工具。</p>
  <p>
    <strong>简体中文</strong> ·
    <a href="README.en.md">English</a> ·
    <a href="https://github.com/0xTotoroX/vorsmate/releases/latest">下载</a> ·
    <a href="https://github.com/0xTotoroX/vorsmate/issues">问题反馈</a>
  </p>
  <p>
    <a href="https://github.com/0xTotoroX/vorsmate/actions/workflows/ci.yml"><img src="https://github.com/0xTotoroX/vorsmate/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  </p>
</div>

## 功能

面板按信息、工具、系统三类收纳各模块。点击分类、横滚鼠标滚轮或用触控板双指左右滑动即可切换。右上角「功能模块…」可以开关模块和调整顺序。待办固定在信息页末尾。应用基于 SwiftUI 与 AppKit 构建，macOS 26 及以上支持系统 Liquid Glass。天气和行情开启后从各自的数据源读数，无需注册账号。

### 内置模块

| 分类 | 模块 | 说明 |
| --- | --- | --- |
| 系统 | 输入法 | 快速切换或锁定系统输入源，拖动排序后按优先级自动选择。 |
| 系统 | 音频设备 | 分别管理麦克风与播放设备的优先级和锁定，断连回退、重连恢复；支持的无线麦在发射器连接后才参与选择。 |
| 系统 | 风扇控制 | 自动、均衡、增强、自定义四档切换，支持温度平滑缓降、固定转速与睡眠唤醒自动恢复。 |
| 信息 | 时间对照 | 并排显示当地与美西时间，点击编辑日期或拖动滑杆换算，自动处理夏令时。 |
| 系统 | 一键关机 | 关机或重启前清理指定应用，提供 5 秒可取消倒计时、搜索批量勾选、排除列表与强制退出选项。 |
| 系统 | 无人值守授权 | 经本机钥匙串校验管理员密码后，在设定时长或截止时刻内自动批准符合 Apple 签名校验的系统授权弹窗；已有弹窗与「隐私与安全」弹窗保留人工确认。 |

### 可选模块

默认关闭，可在右上角「功能模块…」开启。

| 模块 | 说明 |
| --- | --- |
| 天气 | 选择城市后查看当前气温与天气状况，点开可看当天温度范围和数据时间。数据来自 Open-Meteo。 |
| 行情 | 点开查看纳斯达克 100、SOL 美元价格和美元兑人民币参考汇率，每项标注来源及报价时间。再点收起。 |
| 待办 | 查看 Apple 提醒事项中 Project 分组的待办。点项目名旁的「＋」新增，点标题改名，点圆圈完成。首次点「打开连接器」设置独立补丁，可与 Obsidian、浏览器共用。当前补丁适用于 Apple Silicon 和 macOS 27.2 及以上版本。 |
| 截图与翻译 | 快捷键触发全屏窗口吸附框选，支持矩形、箭头与画笔标注，离线 OCR 复制、系统离线翻译或自定义 OpenAI 兼容接口原场景回填，以及可缩放调透明度的桌面贴图。 |
| 窗口拖动 | 授予 Vorsmate 辅助功能权限后，按住 ⌥ Option，用左键从可移动窗口内任意位置拖动。可在「工具 → 窗口拖动」更换修饰键。 |
| 小米遥控器 | 将构建出的 `VorsmateRemote.app` 放在 `Vorsmate.app` 同目录后启用，为 RC003 按键配置分应用快捷键、手势与按住连发，支持通过 MiRemoteV 2ch 虚拟音频设备收音。 |

## 安装

### 系统要求

macOS 14 及以上，支持 Apple Silicon 与 Intel（Universal 通用安装包）；应用界面目前为简体中文。

### 下载安装包

1. 从 [GitHub Releases](https://github.com/0xTotoroX/vorsmate/releases/tag/v0.4.0) 下载 `Vorsmate-0.4.0.dmg`。
2. 打开磁盘镜像，将 `Vorsmate.app` 拖入 `Applications`。
3. 从“应用程序”启动，点击菜单栏图标打开面板。

### 更新与升级

应用会在启动一分钟后及每 12 小时自动检查固定签名源，也可在右上角菜单手动检查；更新清单与安装包均经过双重签名验证，升级保留配置与风扇助手授权。

从 `v0.3.2` 及更早版本升级时，因安装包命名规则变更，需从 Releases 手动安装一次 `v0.4.0` 或更新版本，之后恢复应用内自动更新。

### 从源码构建

需要 Xcode 26+ 与 Swift 6 / macOS SDK。

```sh
git clone https://github.com/0xTotoroX/vorsmate.git
cd vorsmate
swift test
bash scripts/dev.sh
```

默认临时签名构建支持输入法、音频和风扇监控；启用风扇调速或打包通用 DMG 需指定本机 Apple 签名证书：

```sh
VORSMATE_SIGN_IDENTITY='证书名称或指纹' bash scripts/build.sh --universal
bash scripts/package.sh
```

正式构建产物位于 `dist/`，完整本地开发与签名说明见 [CONTRIBUTING.md](CONTRIBUTING.md#本地开发)。

## 使用要点

- 设备切换与排序：输入法与音频均提供关闭、自动、锁定三种模式；展开列表后点击即切换并锁定，直接拖动整行调整优先级，松手保存，拖出列表或按 `Esc` 取消。音频应用若自带设备选项，请设为“系统默认”。
- 面板与后台管理：鼠标离开面板后自动收起，后台规则继续生效；登录时启动、功能模块管理、检查更新、关于和退出均位于右上角菜单。
- 权限与隐私：风扇调速需在面板内授权独立助手；无人值守授权需辅助功能权限，管理员密码仅保存在本机非同步钥匙串，不录音、不记录键盘输入。

## 文档

- [无线麦支持说明](docs/wireless-microphones.md)
- [风扇控制规则](docs/fan-control.md)
- [无人值守授权说明](docs/unattended-auth.md)
- [小米遥控器配置](docs/remote.md)
- [更新机制与发布](docs/updates.md)
- [菜单栏设计说明](DESIGN.md)

## 参与贡献与许可

欢迎提交 Issue 与 Pull Request，开发流程见[贡献指南](CONTRIBUTING.md)，安全问题请通过[安全政策](SECURITY.md)报告。

基于 [MIT License](LICENSE) 开源，随应用分发的第三方源码与许可见[第三方通知](THIRD_PARTY_NOTICES.md)。
