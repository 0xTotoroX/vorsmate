# VorsmateFanHelper/

> L2 | 父级: ../AGENTS.md

- HelperMain.swift：SMAppService root 助手、已签名 XPC、单客户端拥有权、独立定时检查智能调速 / 租约、传递系统温度压力、退出 / 失联 / 重启恢复；恢复记录位于 /var/db/vorsmate/owned-fans.json。主线程事件循环保留 MainActor 硬件访问约定，2 秒定时检查不依赖客户端消息。

固定协议允许查询、配置风扇、交回系统与无参数关机 / 重启；关机前 releaseAll 并确认无未释放拥有权，回复 snapshot 后只执行 /sbin/shutdown -h now 或 -r now，不提供任意文件、进程、shell 或 SMC 键访问。注册助手必须由用户在系统中授权。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
