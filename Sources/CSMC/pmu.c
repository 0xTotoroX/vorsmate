// [INPUT]: IOKit 温度服务的动态符号、CoreFoundation。
// [OUTPUT]: PMU tdie 最高温度；符号、传感器或读数缺失时失败，不以其他类型替代。
// [POS]: 每个读取器独立持有服务；主线程串行调用，无写入和后台线程。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#include "pmu.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

struct pmu_reader {
    void *library;
    CFTypeRef client;
    CFArrayRef services;
    CFTypeRef (*create)(CFAllocatorRef);
    int (*match)(CFTypeRef, CFDictionaryRef);
    CFArrayRef (*services_for)(CFTypeRef);
    CFTypeRef (*property)(CFTypeRef, CFStringRef);
    CFTypeRef (*event)(CFTypeRef, int64_t, int32_t, int64_t);
    double (*value)(CFTypeRef, int32_t);
};

void pmu_destroy(pmu_reader *r) {
    if (!r) return;
    if (r->services) CFRelease(r->services);
    if (r->client) CFRelease(r->client);
    if (r->library) dlclose(r->library);
    free(r);
}

pmu_reader *pmu_create(void) {
    pmu_reader *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!r->library) { pmu_destroy(r); return NULL; }
    r->create = dlsym(r->library, "IOHIDEventSystemClientCreate");
    r->match = dlsym(r->library, "IOHIDEventSystemClientSetMatching");
    r->services_for = dlsym(r->library, "IOHIDEventSystemClientCopyServices");
    r->property = dlsym(r->library, "IOHIDServiceClientCopyProperty");
    r->event = dlsym(r->library, "IOHIDServiceClientCopyEvent");
    r->value = dlsym(r->library, "IOHIDEventGetFloatValue");
    if (!r->create || !r->match || !r->services_for || !r->property || !r->event || !r->value) {
        pmu_destroy(r); return NULL;
    }
    r->client = r->create(kCFAllocatorDefault);
    if (!r->client) { pmu_destroy(r); return NULL; }
    // 仅匹配温度用途，不打开键盘、鼠标等输入设备。
    int page = 0xff00, usage = 5;
    CFNumberRef page_value = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usage_value = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page_value, usage_value };
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 2,
                                                 &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    r->match(r->client, matching);
    CFRelease(matching); CFRelease(page_value); CFRelease(usage_value);
    return r;
}

int pmu_read(pmu_reader *r, double *temperature) {
    if (!r || !temperature) return -1;
    if (!r->services) {
        CFArrayRef all = r->services_for(r->client);
        if (!all) return -1;
        CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
            CFTypeRef service = CFArrayGetValueAtIndex(all, i);
            CFTypeRef name = r->property(service, CFSTR("Product"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID() && CFStringHasPrefix(name, CFSTR("PMU tdie"))) {
                CFArrayAppendValue(selected, service);
            }
            if (name) CFRelease(name);
        }
        CFRelease(all);
        if (CFArrayGetCount(selected) == 0) { CFRelease(selected); return -1; }
        r->services = selected;
    }
    double hottest = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(r->services); i++) {
        CFTypeRef service = CFArrayGetValueAtIndex(r->services, i);
        CFTypeRef event = r->event(service, 15, 0, 0);
        double value = event ? r->value(event, 15 << 16) : NAN;
        if (event) CFRelease(event);
        if (!isfinite(value) || value <= 0 || value >= 130) {
            // 下次重新发现；不能将部分传感器失联误当作温度下降。
            CFRelease(r->services); r->services = NULL;
            return -1;
        }
        hottest = fmax(hottest, value);
    }
    *temperature = hottest;
    return 0;
}
