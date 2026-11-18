# scripts/

> L2 | 父级: ../AGENTS.md

- import-remote.py：只读导入当前 RC003 的用户配置，已编辑的目标档案不会被覆盖。
- build.sh 同时输出独立签名的 VorsmateRemote.app，主包记录临时签名时的配套插件哈希。
- build.sh：Swift release 构建主应用与风扇助手，--universal 包含 arm64 / x86_64；临时目录嵌入并逐层签署 Sparkle，移除本机框架搜索路径，仅主应用附加 Apple Events entitlement，装配源码修订 / 完整许可并验证签名，再替换 dist/Vorsmate.app。VORSMATE_SIGN_IDENTITY 可指定现有 Apple 证书并加时间戳，默认临时签名仅监控；不安装或发布。
- package.sh：验证应用及助手的两种架构、签名和许可，将应用、Applications 链接及安装说明打包为 Vorsmate-<版本>.dmg；不自动签名、公证或上传。
- make-icon.swift：从 Resources/AppIcon-Source.png 导出各尺寸透明应用图标，并生成单色矢量 StatusIcon.pdf；保留已选折面材质与小尺寸轮廓。

- appcast.sh：核对包内公钥与钥匙串的更新密钥，签署发行 DMG 与完整 appcast.xml，在 dist/updates/ 生成对应官方安装包的双重签名描述，不上传 Release 附件。
- verify-update.swift：只使用应用公钥核验 feed / 安装包签名、长度与版本 / 构建号，不访问钥匙串或写入文件。
- publish-appcast.sh：显式将 dist/updates/appcast.xml 中已公开且与安装包字节一致的签名 feed 推到固定 updates 分支；独立索引，不修改主分支，不强推或创建 Release。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
