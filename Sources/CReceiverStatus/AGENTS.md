# CReceiverStatus/

> L2 | 父级: ../../AGENTS.md

- receiver_status.c / include/receiver_status.h：枚举 DJI Mini 系列的厂商接口，以 IOKit 限时读取连接状态；只打开接口 6 / Bulk IN 0x86，不使用音频流、OUT 命令、驱动分离、设备重置或配置切换。
- 会话与读取由 VorsmateSystem 的后台串行队列独占；关闭前结束当前有界读取，不跨线程释放指针。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
