// [INPUT]: CoreAudio HAL 和 Objective-C block 生命周期。
// [OUTPUT]: 用同一个原生 block 注册并移除监听。
// [POS]: Swift 跨语言监听的最小适配；无设备设置写入。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#include "AudioListener.h"
#import <Foundation/Foundation.h>
#include <stdlib.h>

struct VMAudioListener {
    AudioObjectID object;
    AudioObjectPropertyAddress address;
    dispatch_queue_t queue;
    void *block;
};

VMAudioListenerRef VMRegisterAudioListener(AudioObjectID object,
                                          const AudioObjectPropertyAddress *address,
                                          dispatch_queue_t queue,
                                          AudioObjectPropertyListenerBlock block,
                                          OSStatus *status) {
    VMAudioListenerRef listener = calloc(1, sizeof(*listener));
    if (!listener) { *status = kAudioHardwareUnspecifiedError; return NULL; }
    listener->object = object;
    listener->address = *address;
    listener->queue = queue;
    listener->block = (__bridge_retained void *)[block copy];
    *status = AudioObjectAddPropertyListenerBlock(object, address, queue,
                                                (__bridge AudioObjectPropertyListenerBlock)listener->block);
    if (*status != noErr) {
        (void)(__bridge_transfer id)listener->block;
        free(listener);
        return NULL;
    }
    return listener;
}

OSStatus VMUnregisterAudioListener(VMAudioListenerRef listener) {
    OSStatus status = AudioObjectRemovePropertyListenerBlock(listener->object, &listener->address,
                                                            listener->queue, (__bridge AudioObjectPropertyListenerBlock)listener->block);
    if (status == noErr) {
        (void)(__bridge_transfer id)listener->block;
        free(listener);
    }
    return status;
}
