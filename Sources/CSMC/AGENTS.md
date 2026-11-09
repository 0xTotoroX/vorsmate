# CSMC/

> L2 | 父级: ../AGENTS.md

- smc.c：来自 beomwookang/macos-fan-control 的 MIT AppleSMC 桥；Vorsmate 增加只读键枚举。
- include/smc.h：SMC 公开接口；主线程串行调用，不支持并发连接。
- pmu.c / include/pmu.h：本项目的只读 PMU tdie 温度适配；动态解析 IOKit 温度接口，每实例独立持有服务，任一所选读数丢失即失败并重新发现，不监听输入事件。

许可全文见 ../../LICENSES/fanctl-MIT.txt。本模块含原始读写 API，但 XPC 从不暴露任意键写入。

[PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
