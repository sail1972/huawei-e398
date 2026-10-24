/*
 * e398_power.c — 不拔线让 E398 重新上电（USB 挂起/恢复 或 重新配置）
 *
 * 背景：ATD*99# 之后 if0 变成纯数据管道，AT 完全失效（+++ / ATH 都被忽略），
 *       USBDeviceReEnumerate 也不管用（设备不断电，固件不重置数据通道）。
 *       唯一能让 modem 丢掉 PDP 会话的办法是「断电重来」。
 *
 * 用法：
 *   ./e398_power suspend      USB 挂起 2 秒再恢复（等价于总线复位，通常能断掉会话）
 *   ./e398_power reconfig     SetConfiguration(0) → SetConfiguration(1)
 *   ./e398_power both         先 suspend，失败再 reconfig
 *
 * 编译：
 *   clang -O2 -Wno-deprecated-declarations -o e398_power e398_power.c \
 *         -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static int open_dev(int pid, IOUSBDeviceInterface ***out, io_service_t *svcOut)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = 0x12d1, p = pid;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it) != KERN_SUCCESS) return 0;
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) return 0;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOUSBDeviceInterface **dev = NULL;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score) == KERN_SUCCESS && plug) {
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
        (*plug)->Release(plug);
    }
    if (!dev) { IOObjectRelease(svc); return 0; }

    IOReturn kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != kIOReturnSuccess) kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        printf("  设备打开失败 0x%08x\n", kr);
        (*dev)->Release(dev);
        IOObjectRelease(svc);
        return 0;
    }
    *out = dev;
    if (svcOut) *svcOut = svc; else IOObjectRelease(svc);
    return 1;
}

static void close_dev(IOUSBDeviceInterface **dev, io_service_t svc)
{
    if (dev) {
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
    }
    if (svc) IOObjectRelease(svc);
}

static int do_suspend(void)
{
    printf("== USB 挂起 2 秒 ==\n");
    IOUSBDeviceInterface **dev = NULL;
    io_service_t svc = 0;
    if (!open_dev(0x1506, &dev, &svc)) { printf("  没找到 12d1:1506\n"); return 1; }

    IOReturn kr = (*dev)->USBDeviceSuspend(dev, 1);
    printf("  USBDeviceSuspend(1) -> 0x%08x\n", kr);
    if (kr != kIOReturnSuccess) { close_dev(dev, svc); return 2; }
    sleep(2);
    kr = (*dev)->USBDeviceSuspend(dev, 0);
    printf("  USBDeviceSuspend(0) -> 0x%08x\n", kr);
    close_dev(dev, svc);
    return kr == kIOReturnSuccess ? 0 : 3;
}

static int do_reconfig(void)
{
    printf("== SetConfiguration(0) → (1) ==\n");
    IOUSBDeviceInterface **dev = NULL;
    io_service_t svc = 0;
    if (!open_dev(0x1506, &dev, &svc)) { printf("  没找到 12d1:1506\n"); return 1; }

    UInt8 cfg = 0;
    (*dev)->GetConfiguration(dev, &cfg);
    printf("  当前配置 = %d\n", cfg);

    IOReturn kr = (*dev)->SetConfiguration(dev, 0);
    printf("  SetConfiguration(0) -> 0x%08x\n", kr);
    if (kr != kIOReturnSuccess) { close_dev(dev, svc); return 2; }
    usleep(1500000);
    kr = (*dev)->SetConfiguration(dev, 1);
    printf("  SetConfiguration(1) -> 0x%08x\n", kr);
    close_dev(dev, svc);
    return kr == kIOReturnSuccess ? 0 : 3;
}

int main(int argc, char **argv)
{
    const char *what = argc > 1 ? argv[1] : "suspend";
    if (!strcmp(what, "suspend")) return do_suspend();
    if (!strcmp(what, "reconfig")) return do_reconfig();
    if (!strcmp(what, "both")) {
        int r = do_suspend();
        if (r == 0) return 0;
        sleep(1);
        return do_reconfig();
    }
    printf("用法: e398_power [suspend|reconfig|both]\n");
    return 9;
}
