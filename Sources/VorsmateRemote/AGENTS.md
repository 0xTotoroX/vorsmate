# VorsmateRemote

独立可选的 RC003 插件。HostIdentity 校验配套父进程，App 负责控制管道和退出。App 向宿主回传当前配置和保存结果，RemoteMonitor 负责持久化。RemoteWindow 保留独立预览和显式真机验收入口；模型点选与录入复用 VorsmateRemoteUI。RemoteMonitor 只读取匹配的键盘报告，随前台应用切换键位、取消未完成手势并调度连发。ReturnLease 回验、恢复设备映射；ActionOutput 发送快捷键、媒体动作并打开应用。RemoteVoiceLink 协商 ATVV 并处理语音键的会话。RemoteAudioOutput 将 16 kHz PCM 写到指定 UID 的音频队列，末尾排空，断开立即停止。Typeless 使用与普通组合键相同的左右修饰键事件。

手势按 HID 报告时间判定，等待组合键的间隔不阻塞主线程。语音会话按首包和连续包的到达时间检测中断。音频尾包排空后确认队列已停止，再接续新会话。

手势和配置存储在 VorsmateCore；本机个人键位仅通过显式导入迁移。预览不读取个人配置、不访问设备、不写文件。
