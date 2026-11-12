// [INPUT]: macOS IOKit / IOUSBLib；DJI Mini 系列 VID/PID 与接口描述符。
// [OUTPUT]: 仅接口 6、Bulk IN 0x86 的状态流，单次读取最多等待 100ms。
// [POS]: 接收器状态桥；不打开设备控制接口，不改配置，不分离 HID / 音频驱动。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#include "receiver_status.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

struct VMReceiverSession {
    IOUSBInterfaceInterface182 **interface;
    UInt8 pipe;
};

static int number(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberIntType, &result);
    if (value) CFRelease(value);
    return result;
}

static int supported(io_service_t service) {
    return number(service, CFSTR("idVendor")) == 0x2ca3 &&
           number(service, CFSTR("idProduct")) == 0x4011 &&
           number(service, CFSTR("bInterfaceNumber")) == 6 &&
           number(service, CFSTR("bInterfaceClass")) == 255;
}

size_t VMReceiverList(VMReceiverInfo *items, size_t capacity) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOUSBHostInterface"), &iterator) != KERN_SUCCESS) return 0;
    size_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (count < capacity && supported(service)) {
            VMReceiverInfo info = {0};
            IORegistryEntryGetRegistryEntryID(service, &info.registryID);
            CFTypeRef serial = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                CFSTR("USB Serial Number"), kCFAllocatorDefault,
                kIORegistryIterateRecursively | kIORegistryIterateParents);
            if (serial && CFGetTypeID(serial) == CFStringGetTypeID())
                CFStringGetCString(serial, info.serial, sizeof(info.serial), kCFStringEncodingUTF8);
            if (serial) CFRelease(serial);
            items[count++] = info;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

VMReceiverRef VMReceiverOpen(uint64_t registryID, int32_t *status) {
    *status = kIOReturnNotFound;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (!service) return NULL;
    if (!supported(service)) { IOObjectRelease(service); return NULL; }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    *status = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (*status != kIOReturnSuccess || !plugin) return NULL;
    IOUSBInterfaceInterface182 **interface = NULL;
    HRESULT query = (*plugin)->QueryInterface(plugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID182), (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (query || !interface) { *status = kIOReturnUnsupported; return NULL; }
    UInt8 alternate = 255;
    *status = (*interface)->GetAlternateSetting(interface, &alternate);
    if (*status == kIOReturnSuccess && alternate != 0) *status = kIOReturnUnsupported;
    if (*status != kIOReturnSuccess) { (*interface)->Release(interface); return NULL; }
    *status = (*interface)->USBInterfaceOpen(interface);
    if (*status != kIOReturnSuccess) { (*interface)->Release(interface); return NULL; }
    UInt8 endpoints = 0, pipe = 0;
    *status = (*interface)->GetNumEndpoints(interface, &endpoints);
    if (*status == kIOReturnSuccess) {
        for (UInt8 index = 1; index <= endpoints; ++index) {
            UInt8 direction = 0, number = 0, type = 0, interval = 0;
            UInt16 packetSize = 0;
            if ((*interface)->GetPipeProperties(interface, index, &direction, &number,
                    &type, &packetSize, &interval) == kIOReturnSuccess &&
                    direction == kUSBIn && number == 6 && type == kUSBBulk) {
                pipe = index;
                break;
            }
        }
    }
    VMReceiverRef session = pipe ? calloc(1, sizeof(*session)) : NULL;
    if (!session) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        *status = pipe ? kIOReturnNoMemory : kIOReturnUnsupported;
        return NULL;
    }
    session->interface = interface;
    session->pipe = pipe;
    *status = kIOReturnSuccess;
    return session;
}

int32_t VMReceiverRead(VMReceiverRef session, void *bytes, uint32_t *size) {
    IOReturn result = (*session->interface)->ReadPipeTO(
        session->interface, session->pipe, bytes, size, 100, 100);
    if (result == kIOUSBTransactionTimeout) { *size = 0; return kIOReturnSuccess; }
    if (result != kIOReturnSuccess) *size = 0;
    return result;
}

void VMReceiverClose(VMReceiverRef session) {
    if (!session) return;
    (*session->interface)->USBInterfaceClose(session->interface);
    (*session->interface)->Release(session->interface);
    free(session);
}
