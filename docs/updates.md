# 应用更新

正常运行时在启动一分钟后检查官方 GitHub Releases，之后每 12 小时检查一次；更多菜单提供“检查更新…”。使用发布列表统一比较数字版本，不使用 GitHub 的 `/latest`。按语义版本选择包含官方 Universal DMG 的最新发布，不降级、不使用草稿或其他仓库的资产。

发现新版后，Sparkle 负责下载、Ed25519 验证、解包、替换与重启；载荷在解包前验签。自定义交互层只显示同一紧凑窗口中的状态和操作，不替换框架的安装逻辑。用户确认安装和重启；下载前可取消，准备完成后可稍后安装。后台网络失败不弹窗；手动检查失败可见。没有 appcast 的旧发布只提供发布页入口，不假装可以应用内安装。

配置位于应用包外的 Application Support，更新不改写、不删除该文件。应用正常退出仍归还本助手控制的风扇；启动后按既有约定使用系统自动模式。更新不注销或重建风扇服务，应用标识、助手标识、LaunchDaemon 描述与签名团队保持兼容。改变签名团队或助手协议需要独立迁移与实机验收，不能承诺无条件继承授权。不可写的安装目录可能需要系统安装授权，这与重新开启风扇助手不同。

## 发布更新

Sparkle 锁定于 `Package.resolved`。更新私钥保存在登录钥匙串，账户 `app.vorsmate.mac`；包内 `SUPublicEDKey` 仅为公钥。私钥不入仓库或发布资产。自行分发时使用 Sparkle 的 `generate_keys --account app.vorsmate.mac` 建立自己的密钥并替换包内公钥；独立 Fork 还需改为自己的仓库地址。

```sh
VORSMATE_SIGN_IDENTITY='证书名称或指纹' bash scripts/build.sh --universal
bash scripts/package.sh
bash scripts/appcast.sh
```

每个新 Release 上传 **DMG、appcast.xml**。描述文件的版本号、构建号、最低系统和载荷签名从实际应用 / 安装包读取，地址指向同一版本的 GitHub Release。先提交最终源码再构建；不覆盖已发布安装包。缺少私钥或公钥不匹配时生成步骤失败，不发布不完整更新。

构建嵌入并逐层签署 Sparkle，移除开发机框架搜索路径，随包携带完整许可。默认临时签名只供本地开发，不启用 hardened runtime；使用 Apple 身份的发行包启用 hardened runtime，嵌套组件使用同一身份。

公开安装包自 v0.3.0 起内置更新器并随附签名 `appcast.xml`；v0.2.0 及更早版本尚未内置更新器，需手动安装 v0.3.0 或更新版本后才能使用应用内升级。代码接入、本地安装与发布分别验收，见 [验证范围](verification.md)。
