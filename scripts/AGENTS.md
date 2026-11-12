# scripts/

> L2 | 父级: ../AGENTS.md

- build.sh：Swift release 构建主应用与风扇助手，--universal 包含 arm64 / x86_64；临时目录装配源码修订 / 完整许可并验证签名，再替换 dist/Vorsmate.app。VORSMATE_SIGN_IDENTITY 可指定现有 Apple 证书并加时间戳，默认临时签名仅监控；不安装或发布。
- package.sh：验证应用及助手的两种架构、签名和许可，将应用、Applications 链接及安装说明打包为 DMG，生成 SHA256SUMS；不自动签名、公证或上传。
- make-icon.swift：从 Resources/AppIcon-Source.png 导出各尺寸透明应用图标，并生成单色矢量 StatusIcon.pdf；保留已选折面材质与小尺寸轮廓。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
