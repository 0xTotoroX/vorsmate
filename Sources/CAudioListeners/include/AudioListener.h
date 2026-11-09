// [INPUT]: CoreAudio 属性、派发队列与原生 block。
// [OUTPUT]: 配对注册 / 移除的监听句柄；不读取或切换设备。
// [POS]: 保持跨 Swift 桥接的原生 block 身份和生命周期。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#pragma once
#include <CoreAudio/CoreAudio.h>

typedef struct VMAudioListener *VMAudioListenerRef;

VMAudioListenerRef VMRegisterAudioListener(AudioObjectID object,
                                          const AudioObjectPropertyAddress *address,
                                          dispatch_queue_t queue,
                                          AudioObjectPropertyListenerBlock block,
                                          OSStatus *status);
// 成功时释放句柄；失败时保留，调用方可再次移除。
OSStatus VMUnregisterAudioListener(VMAudioListenerRef listener);
