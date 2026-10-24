/*
 * e398_reenum.c — 让华为 E398 重新枚举一次（等价于拔插，但不用动手）
 *
 * 用途：当 E398Switcher.kext 已加载、但设备接口在 kext 加载前就被苹果的
 *       IOUSBMassStorageInterfaceNub 匹配走了时，重新枚举会让匹配重来一次，
 *       这次 E398Switcher（IOProbeScore=100000）会先拿到接口。
 *
 * 实测不需要 root：打开设备节点 + USBDeviceReEnumerate 都是普通用户可用的。
 *
 * 编译：clang -O2 -Wno-deprecated-declarations -o e398_reenum e398_reenum.c \
 *            -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

int main(void)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBDevice");
    int vid = 0x12d1, pid = 0x1505;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), nv);
    CFDictionarySetValue(match, CFSTR("idProduct"), np);
    CFRelease(nv);
    CFRelease(np);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, match, &iter) != KERN_SUCCESS) {
        printf("匹配失败\n");
        return 1;
    }

    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!svc) {
        printf("没找到 12d1:1505 —— 设备现在不是光盘模式？\n");
        return 2;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                      kIOCFPlugInInterfaceID, &plug, &score);
    if (!plug) {
        printf("创建插件接口失败\n");
        IOObjectRelease(svc);
        return 3;
    }

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                            (LPVOID *)&dev);
    if (!dev) {
        printf("取不到 IOUSBDeviceInterface\n");
        (*plug)->Release(plug);
        IOObjectRelease(svc);
        return 4;
    }

    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        printf("打开设备失败 0x%08x\n", kr);
        (*dev)->Release(dev);
        (*plug)->Release(plug);
        IOObjectRelease(svc);
        return 5;
    }

    kr = (*dev)->USBDeviceReEnumerate(dev, 0);
    printf("USBDeviceReEnumerate: 0x%08x %s\n", kr, kr == kIOReturnSuccess ? "(已触发)" : "(失败)");

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    (*plug)->Release(plug);
    IOObjectRelease(svc);
    return kr == kIOReturnSuccess ? 0 : 6;
}
