# 参与 Vorsmate

欢迎提交问题报告、功能建议和 PR。较大的新模块请先在 Issue 中说明实际场景与界面成本；一次修改尽量围绕一个可验证的问题。

## 本地开发

使用 macOS、Xcode 26+ 与 Swift 6 / macOS SDK。应用目标系统为 macOS 14+，具体实测范围见[验证范围](docs/verification.md)。

### 日常开发版

首次从日常版切换时，先从菜单退出原 Vorsmate。之后每次修改源码，运行：

```sh
bash scripts/dev.sh
```

脚本增量编译，验证包成功后才退出并重开同一路径的开发实例。菜单栏标为「开发」，应用沿用现有偏好和真实设备。开发版不检查更新，不注册登录项，也不替换 `/Applications` 里的安装。构建失败时，正在运行的开发版继续工作。要回日常版，先退出开发版，再打开已安装的应用。

日常使用风扇调速时，先运行 `git config --local vorsmate.signIdentity '证书名称或指纹'`，选择原签名团队的 Apple 证书。后续重载自动沿用它，也可用 `VORSMATE_SIGN_IDENTITY` 单次指定。未指定时使用临时签名，风扇只读，关机走 System Events。开发版沿用已授权且可连接的助手，修改助手源码后需单独验证签名升级。

### 隔离验收与发版

```sh
swift test
bash scripts/dev.sh --build-only
open -n artifacts/dev/build/Vorsmate.app --args --preview
```

`--build-only` 生成独立验收包，预览只使用模拟设备。日常使用固定路径 `artifacts/dev/run/Vorsmate.app`。决定发布时，给验收过、已设置正式版本号与构建号的提交打标签，再用 `bash scripts/prepare-release.sh vX.Y.Z` 独立构建该版本。发布步骤见[应用更新](docs/updates.md)。

使用仓库的 `.swift-format`：

```sh
xcrun swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests scripts/make-icon.swift
xcrun swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests scripts/make-icon.swift
```

CI 执行格式检查、测试、Universal 临时签名打包及 DMG 检查。它不会安装应用或获取硬件控制权限。贡献者无需提供签名证书即可运行测试和预览；真实风扇调速需要自己的 Apple 签名与本机管理员授权。

## 修改与验证

- 保持输入 / 输出独立，尊重手动锁定、已有排序和用户数据。
- 系统行为优先使用 `SourceDriver` / `FanHardware` 替身验证；测试不得默认切换设备、录音、注册登录项或调整真实风扇。
- 风扇修改保留读数有效性、系统压力、范围校验、恢复责任和失联保护；未知型号的温度曲线需要独立核验。
- UI 修改遵守 [DESIGN.md](DESIGN.md)，附实际界面和操作结果；不要用编译成功代替交互验收。
- 维护受影响的源码契约与 `AGENTS.md` 地图。提交标题使用 Conventional Commits，例如 `fix(audio): retain the preferred microphone`。
- PR 写明解决的问题、最终行为、验证方法及尚未验证的部分。

不要提交本机设备 UID、个人配置、私人路径、签名凭据、证书或构建产物。`--inspect` 输出可能包含设备标识，应先删去这些字段。安全问题请走 [SECURITY.md](SECURITY.md) 的私密报告渠道。

自有贡献按项目 MIT License 提供。引入第三方代码时核实许可并保留原始版权与通知。
