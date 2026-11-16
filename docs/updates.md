# 应用更新

源码中的更新器在启动一分钟后、之后每 12 小时检查一次，菜单也可手动检查。固定更新源为：

`https://raw.githubusercontent.com/0xTotoroX/vorsmate/updates/appcast.xml`

不再先请求 GitHub Releases API，也不使用只适用于正式版的 `/latest`。Sparkle 根据实际构建号选择更新并阻止降级。更新描述必须通过 Ed25519 签名验证，安装包也必须在解包前通过独立签名验证；只接受对应版本的官方 Universal DMG。不会因获取失败改用未签名或外部来源。

## 等待、取消与重试

检查从开始即有 20 秒截止，覆盖框架回调前的助手探测和更新源读取。下载 60 秒没有收到新数据时结束等待，有实际进展会续期；准备阶段最多等待 120 秒。进入实际安装后不强制中断。

手动失败在同一紧凑窗口明确区分断网、无法连接服务器、HTTP 状态、更新描述错误、来源不符、验签失败、配置与安装问题，提供“重试 / 关闭”。取消或超时使旧会话失效，迟到的检查、关闭或安装确认不能覆盖新操作。重试前会立即确认框架错误，避免留着未结束的旧会话。后台无更新和失败保持安静；发现新版后仍由用户确认下载和重启。

## 配置与助手

设置保存在应用包外的 Application Support。更新不改写或删除配置，不注销或重建风扇服务。应用正常退出先归还风扇控制，启动后在模块启用、助手已授权且无竞争工具时恢复保存的方案；首次未设置时由系统自动控制。

应用标识、助手标识、LaunchDaemon 描述与签名团队必须保持兼容。改变团队或协议需要独立迁移与实机验收，不能承诺无条件继承授权。不可写的安装目录可能需要系统安装授权，与重新开启风扇助手不同。

## 发布更新

Sparkle 锁定于 `Package.resolved`。更新私钥保存在登录钥匙串，账户为 `app.vorsmate.mac`；包内 `SUPublicEDKey` 仅为公钥。私钥不入仓库或资产。独立 Fork 需创建自己的密钥，并更换仓库与固定 feed 地址。

```sh
VORSMATE_SIGN_IDENTITY='证书名称或指纹' bash scripts/build.sh --universal
bash scripts/package.sh
bash scripts/appcast.sh
swift scripts/verify-update.swift dist/release/appcast.xml dist/Vorsmate.app dist/release/Vorsmate-<版本>-universal.dmg
```

每个 Release 上传 DMG 和双重签名的 appcast.xml。所有版本、构建号、最低系统、地址与签名来自实际应用和载荷；先提交最终源码再构建，不覆盖既有安装包。钥匙串公钥不匹配时生成失败，不发布不完整更新。

Release 公开、资产下载回验通过后，显式更新固定源：

```sh
bash scripts/publish-appcast.sh
```

该脚本先只用公钥检查 feed / 载荷签名、长度和版本，再核对公开 Release 的载荷摘要，最后用独立索引提交并推送 updates 分支。它不修改主分支，不创建 Release，不强推；并发更新被拒绝时先核对远端，不覆盖他人的 feed。上传后还需匿名下载固定源，确认字节与已验证文件一致。

旧 v0.3.0 / v0.3.1 使用匿名 API 发现更新，可能受出口限流影响；固定源修复不改变已发布的旧安装包。旧版无法完成应用内检查时，需要先手动安装修复构建。应用标识和更新公钥继续保留。发布、完整升级与本机安装分别验收，见[验证范围](verification.md)。
