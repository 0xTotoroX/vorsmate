// [INPUT]: IOKit USB 注册表与厂商状态接口。
// [OUTPUT]: 接收器枚举、限时只读会话与配对关闭；不暴露控制命令。
// [POS]: 无音频流、无驱动分离的原生 USB 边界。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t registryID;
    char serial[256];
} VMReceiverInfo;
typedef struct VMReceiverSession *VMReceiverRef;

size_t VMReceiverList(VMReceiverInfo *items, size_t capacity);
VMReceiverRef VMReceiverOpen(uint64_t registryID, int32_t *status);
// 超时返回成功和零字节；其他失败由调用者关闭并重新发现。
int32_t VMReceiverRead(VMReceiverRef session, void *bytes, uint32_t *size);
void VMReceiverClose(VMReceiverRef session);
