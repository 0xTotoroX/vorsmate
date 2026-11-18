# VorsmateRemote

独立可选的 RC003 插件。HostIdentity 校验配套父进程，App 负责控制管道和退出。RemoteFace 用实际模型投影选择所有实体键，RemoteWindow 编辑三种手势并持久保存。RemoteMonitor 只读取匹配的键盘报告并调度手势。ReturnLease 回验、恢复设备映射；ActionOutput 发送快捷键、媒体动作并打开应用。RemoteVoiceLink 协商 ATVV 并处理语音键的会话。RemoteAudioOutput 将 16 kHz PCM 写到指定 UID 的音频队列，末尾排空，断开立即停止。Typeless 使用与普通组合键相同的左右修饰键事件。

手势和配置存储在 VorsmateCore；本机个人键位仅通过显式导入迁移。预览不读取个人配置、不访问设备、不写文件。
