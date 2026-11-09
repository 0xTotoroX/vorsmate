# CAudioListeners/

> L2 | 父级: ../AGENTS.md

- include/AudioListener.h：音频监听句柄接口，注册失败不返回句柄；移除失败保留句柄供重试。
- AudioListener.m：保存同一个原生 block，配对调用 CoreAudio 注册 / 移除；不读写设备选择。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
