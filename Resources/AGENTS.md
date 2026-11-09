# Resources/

> L2 | 父级: ../AGENTS.md

- Info.plist：app.vorsmate.mac 应用身份、发行版本、最低 macOS 14 与 LSUIElement 菜单栏模式；构建脚本复制后写入实际源码修订。
- Install.txt：DMG 内的中英文拖放安装、首次启动、风扇授权与更新说明。
- AppIcon.png / AppIcon.icns：README 图标与应用图标；由 scripts/make-icon.swift 生成。
- LaunchDaemons/app.vorsmate.fan-helper.plist：SMAppService 使用的固定 MachService、BundleProgram、重启与限频策略；Standard 调度，不把正在控温的助手归入可延后执行的 Background 任务。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
