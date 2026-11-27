# Resources/

> L2 | 父级: ../AGENTS.md

- Info.plist：app.vorsmate.mac 应用身份、发行版本、最低 macOS 14 、LSUIElement 菜单栏模式与一键下班 Apple Events 用途说明；构建脚本复制后写入实际源码修订。
- Vorsmate.entitlements：主应用 Apple Events 声明，仅用于无助手时的 System Events 关机 / 重启回退，仍需用户系统授权；不赋予助手或 Sparkle。
- Install.txt：DMG 内的中英文拖放安装、首次启动、风扇授权与更新说明。
- AppIcon-Source.png：1024×1024 应用图标母版。钴蓝海鸥居中，纯白圆角底面为 824×824，四周透明。
- AppIcon.png / AppIcon.icns：README 图标与应用图标；由 scripts/make-icon.swift 从母版导出。
- StatusIcon.pdf：18 点同轮廓单色展翼矢量图，由同一脚本以单条闭合对称曲线生成；菜单栏和面板标题以模板图像共用，随系统明暗着色。
- LaunchDaemons/app.vorsmate.fan-helper.plist：SMAppService 使用的固定 MachService、BundleProgram、重启与限频策略；Standard 调度，不把正在控温的助手归入可延后执行的 Background 任务。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
