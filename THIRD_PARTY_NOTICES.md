# 第三方许可通知

## 随应用分发的源码

`Sources/CSMC/smc.c` 与 `Sources/CSMC/include/smc.h` 来自 [beomwookang/macos-fan-control](https://github.com/beomwookang/macos-fan-control)，MIT License，Copyright © 2026 Beom Woo Kang。Vorsmate 增加只读键枚举接口；其余保留原实现。完整许可在 [LICENSES/macos-fan-control-MIT.txt](LICENSES/macos-fan-control-MIT.txt)，构建时随应用分发。

## 随应用分发的框架

[Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle) 提供更新包验证、下载、安装和重启，采用 MIT 及所列第三方许可。完整版权及许可见 [LICENSES/Sparkle-LICENSE.txt](LICENSES/Sparkle-LICENSE.txt)，框架及该通知随应用分发。

## 遥控器音频互操作

RC003 插件在运行时使用用户已安装的 MiRemoteV 2ch 音频设备。插件独立实现蓝牙语音、IMA ADPCM 解码及快捷键发送，采用项目 MIT 许可。构建产物不包含 SayAll 软件、其虚拟音频驱动或旧键盘桥。
