/*
 * usb_switch_huawei —— 把华为 E398 从 "零 CD/装机模式" (12d1:1505) 切到 "modem 模式" (12d1:1506)
 *
 * 原理：向设备的 Bulk-Only 端点写入 usb_modeswitch 的 Huawei 专用切换报文
 *       (一条 START-STOP-UNIT / LoEj 的 CBW)，设备收到后重新枚举为 1506。
 *       macOS 的 diskutil eject 只卸载介质，不会触发这个切换，所以必须直接打端点。
 *
 * 用法： sudo ./usb_switch_huawei [productID]     默认 1505
 *       sudo ./usb_switch_huawei --info          只打印设备信息，不做动作
 *
 * 编译： clang -O2 -o usb_switch_huawei usb_switch_huawei.c -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define HUAWEI_VID 0x12d1

static const unsigned char kMsg[31] = {
    0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
    0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

static void cfstr_to_c(io_service_t svc, CFStringRef key, char *out, size_t n) {
    out[0] = 0;
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, out, n, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

/* 在给定接口上找 bulk OUT 管道并写入切换报文 */
static int blast_interface(io_service_t isvc) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOUSBInterfaceInterface **intf = NULL;
    IOReturn kr;
    int rc = -1;

    kr = IOCreatePlugInInterfaceForService(isvc, kIOUSBInterfaceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != kIOReturnSuccess || !plug) return -1;

    kr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                 (LPVOID *)&intf);
    if (kr != kIOReturnSuccess || !intf) { (*plug)->Release(plug); return -1; }

    kr = (*intf)->USBInterfaceOpenSeize(intf);
    if (kr == kIOReturnExclusiveAccess) {
        printf("  [.] seize 报独占，再试普通 open\n");
        kr = (*intf)->USBInterfaceOpen(intf);
    }
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "  [!] 抢占接口失败: 0x%08x (%s)\n", kr,
                kr == kIOReturnNotPrivileged ? "需要 root，请用 sudo" :
                kr == kIOReturnExclusiveAccess ? "接口被其他驱动占用" : "未知");
        goto done;
    }

    UInt8 nEp = 0;
    (*intf)->GetNumEndpoints(intf, &nEp);
    for (UInt8 p = 1; p <= nEp; p++) {
        UInt8 dir = 0, num = 0, type = 0, interval = 0;
        UInt16 maxp = 0;
        if ((*intf)->GetPipeProperties(intf, p, &dir, &num, &type, &maxp, &interval) != kIOReturnSuccess)
            continue;
        if (dir != kUSBOut || type != kUSBBulk) continue;

        kr = (*intf)->WritePipeTO(intf, p, (void *)kMsg, sizeof(kMsg), 1000, 1000);
        printf("  [*] 已向 pipe %u 写入切换报文 -> 0x%08x %s\n", p, kr,
               kr == kIOReturnSuccess ? "(成功)" : "(失败)");
        if (kr == kIOReturnSuccess) { rc = 0; break; }
        (*intf)->ClearPipeStallBothEnds(intf, p);
    }
    if (rc != 0) fprintf(stderr, "  [!] 没找到可用的 bulk OUT 端点\n");
    (*intf)->USBInterfaceClose(intf);

done:
    (*intf)->Release(intf);
    (*plug)->Release(plug);
    return rc;
}

int main(int argc, char **argv) {
    int target = 0x1505, info_only = 0;
    if (argc > 1) {
        if (!strcmp(argv[1], "--info")) info_only = 1;
        else target = (int)strtol(argv[1], NULL, 16);
    }

    CFMutableDictionaryRef match = IOServiceMatching("IOUSBDevice");
    if (!match) { fprintf(stderr, "IOServiceMatching 失败\n"); return 2; }

    int vid = HUAWEI_VID, pid = target;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR("idVendor"), nv);
    CFDictionarySetValue(match, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, match, &it) != KERN_SUCCESS || !it) {
        fprintf(stderr, "找不到 12d1:%04x —— 设备可能不在这个模式/没插好\n", target);
        return 3;
    }

    io_service_t svc;
    int found = 0, switched = 0;
    while ((svc = IOIteratorNext(it))) {
        found++;
        char prod[128] = "?", man[128] = "?";
        cfstr_to_c(svc, CFSTR("USB Product Name"), prod, sizeof prod);
        cfstr_to_c(svc, CFSTR("USB Vendor Name"), man, sizeof man);
        printf("[+] 找到设备: %s / %s (12d1:%04x)\n", man, prod, target);

        if (info_only) { IOObjectRelease(svc); continue; }

        IOCFPlugInInterface **plug = NULL;
        IOUSBDeviceInterface **dev = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess) {
            fprintf(stderr, "  [!] 无法创建设备插件\n");
            IOObjectRelease(svc); continue;
        }
        if ((*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                     (LPVOID *)&dev) != kIOReturnSuccess || !dev) {
            fprintf(stderr, "  [!] QueryInterface 失败\n");
            (*plug)->Release(plug); IOObjectRelease(svc); continue;
        }

        IOReturn kr = (*dev)->USBDeviceOpenSeize(dev);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "  [!] 打开设备失败: 0x%08x (%s)\n", kr,
                    kr == kIOReturnNotPrivileged ? "需要 root，请用 sudo 运行" :
                    kr == kIOReturnExclusiveAccess ? "设备被占用，先拔插一次再试" : "未知");
        } else {
            /* 注意：这里绝对不能调 SetConfiguration——
               它会让 IOUSBHostFamily 重新枚举接口并重新匹配驱动，
               结果 AppleUSBMassStorageDriver 又抢回接口，seize 必然失败。*/

            IOUSBFindInterfaceRequest req;
            req.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
            req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
            req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
            req.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

            io_iterator_t iit = 0;
            if ((*dev)->CreateInterfaceIterator(dev, &req, &iit) == kIOReturnSuccess) {
                io_service_t isvc;
                while ((isvc = IOIteratorNext(iit))) {
                    if (blast_interface(isvc) == 0) switched = 1;
                    IOObjectRelease(isvc);
                }
                IOObjectRelease(iit);
            }
            (*dev)->USBDeviceClose(dev);
        }
        (*dev)->Release(dev);
        (*plug)->Release(plug);
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);

    if (!found) { fprintf(stderr, "没有匹配 12d1:%04x 的设备\n", target); return 3; }
    if (info_only) return 0;

    printf("\n等待设备重新枚举 ...\n");
    sleep(5);
    if (switched) printf("切换报文已送达。请运行 ./status.sh 确认 PID 是否变成 1506。\n");
    return switched ? 0 : 4;
}
