/*
 * e398_bulk.c — 原样重放华为 12d1:1505 的 UFI 切换报文
 *
 * Linux 的 usb_modeswitch 做两件事：
 *   1) libusb_detach_kernel_driver()         让 usb-storage 松手
 *   2) 往 bulk OUT 端点写 31 字节 UFI 报文
 * macOS 上 (1) 的等价物是让 IOUSBMassStorageDriver 松手（见 1c 脚本），
 * 本工具负责 (2)，并额外提供不需要 root 的「重枚举空窗」试探模式。
 *
 * 编译:
 *   clang -O2 -Wno-deprecated-declarations -o e398_bulk e398_bulk.c \
 *         -framework IOKit -framework CoreFoundation
 * 用法:
 *   ./e398_bulk --direct            直接抢接口（存储驱动已卸载时用，需 root）
 *   ./e398_bulk --direct --verbose  同上，打印接口诊断
 *   ./e398_bulk --race              重枚举抢空窗（无需 root，成功率低）
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0x12d1
#define PID_ZERO_CD 0x1505
#define PID_MODEM   0x1506

static int gVerbose = 0;

/* usb-modeswitch 数据文件 12d1:1505 的 MessageContent，31 字节 */
static const unsigned char kMsg[31] = {
    0x55, 0x53, 0x42, 0x43, 0x12, 0x34, 0x56, 0x78,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
    0x06, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

static int pid_present(int pid)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = VID, p = pid;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it) != KERN_SUCCESS) return 0;
    io_service_t s = IOIteratorNext(it);
    int f = (s != 0);
    if (s) IOObjectRelease(s);
    IOObjectRelease(it);
    return f;
}

/* 打开设备（设备级占用与接口级占用互不影响） */
static IOUSBDeviceInterface **open_device(int pid, io_service_t *outSvc)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = VID, p = pid;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it) != KERN_SUCCESS) return NULL;
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOUSBDeviceInterface **dev = NULL;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plug, &score) == KERN_SUCCESS && plug) {
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
        (*plug)->Release(plug);
    }
    if (!dev) { IOObjectRelease(svc); return NULL; }

    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != kIOReturnSuccess) {
        if (gVerbose) printf("  设备打开失败 0x%08x\n", kr);
        (*dev)->Release(dev);
        IOObjectRelease(svc);
        return NULL;
    }
    if (outSvc) *outSvc = svc; else IOObjectRelease(svc);
    return dev;
}

/* 用 CreateInterfaceIterator 拿接口，不依赖 IOClass 名字 */
static IOUSBInterfaceInterface **grab_interface(IOUSBDeviceInterface **dev)
{
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t it = 0;
    IOReturn kr = (*dev)->CreateInterfaceIterator(dev, &req, &it);
    if (kr != kIOReturnSuccess) {
        if (gVerbose) printf("  CreateInterfaceIterator 0x%08x\n", kr);
        return NULL;
    }

    IOUSBInterfaceInterface **found = NULL;
    io_service_t isvc;
    int idx = 0;
    while ((isvc = IOIteratorNext(it))) {
        idx++;
        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;
        kr = IOCreatePlugInInterfaceForService(isvc, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plug, &score);
        if (kr != kIOReturnSuccess || !plug) {
            if (gVerbose) printf("  接口 #%d 插件创建 0x%08x\n", idx, kr);
            IOObjectRelease(isvc);
            continue;
        }
        IOUSBInterfaceInterface **intf = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                (LPVOID *)&intf);
        (*plug)->Release(plug);
        if (!intf) { IOObjectRelease(isvc); continue; }

        kr = (*intf)->USBInterfaceOpenSeize(intf);
        if (gVerbose) printf("  接口 #%d USBInterfaceOpenSeize -> 0x%08x\n", idx, kr);
        if (kr == kIOReturnSuccess) {
            UInt8 num = 0;
            (*intf)->GetInterfaceNumber(intf, &num);
            printf("  [+] 抢到接口 #%d (bInterfaceNumber=%d)\n", idx, num);
            found = intf;
            IOObjectRelease(isvc);
            break;
        }
        (*intf)->Release(intf);
        IOObjectRelease(isvc);
    }
    IOObjectRelease(it);
    return found;
}

/* 在接口上找 bulk OUT，写报文，再读 CSW */
static int push_payload(IOUSBInterfaceInterface **intf)
{
    UInt8 n = 0;
    IOReturn kr = (*intf)->GetNumEndpoints(intf, &n);
    if (kr != kIOReturnSuccess) { printf("  [!] GetNumEndpoints 0x%08x\n", kr); return -1; }
    if (gVerbose) printf("  端点数: %d\n", n);

    UInt8 outPipe = 0, inPipe = 0;
    for (UInt8 i = 1; i <= n; i++) {
        UInt8 dir = 0, num = 0, type = 0, interval = 0;
        UInt16 mps = 0;
        if ((*intf)->GetPipeProperties(intf, i, &dir, &num, &type, &mps, &interval) != kIOReturnSuccess)
            continue;
        if (gVerbose)
            printf("    管道 %d: dir=%s num=%d type=%d mps=%d\n",
                   i, dir ? "IN" : "OUT", num, type, mps);
        if (type == kIOUSBEndpointTypeBulk || type == 2) {
            if (dir == 0 && !outPipe) outPipe = i;
            else if (dir == 1 && !inPipe) inPipe = i;
        }
    }
    if (!outPipe) { printf("  [x] 没找到 bulk OUT 端点\n"); return -1; }

    printf("  [.] 写入 31 字节切换报文 → 管道 %d\n", outPipe);
    kr = (*intf)->WritePipeTO(intf, outPipe, (void *)kMsg, sizeof kMsg, 3000, 3000);
    printf("  WritePipe: 0x%08x %s\n", kr,
           kr == kIOReturnSuccess ? "✓ 已发出" :
           kr == (IOReturn)0xe0004052 ? "(管道 stall：设备可能已开始切换)" : "");

    if (inPipe) {
        unsigned char csw[13];
        memset(csw, 0, sizeof csw);
        UInt32 cswLen = sizeof csw;
        IOReturn r2 = (*intf)->ReadPipeTO(intf, inPipe, csw, &cswLen, 2000, 2000);
        if (gVerbose)
            printf("  ReadPipe(CSW): 0x%08x len=%u sig=%02x%02x%02x%02x\n",
                   r2, cswLen, csw[0], csw[1], csw[2], csw[3]);
    }
    return 0;
}

static int wait_for_1506(void)
{
    printf("\n=== 等待设备重枚举 ===\n");
    for (int i = 0; i < 15; i++) {
        sleep(1);
        if (pid_present(PID_MODEM)) {
            printf("✓ 切换成功，设备现在是 12d1:1506（%ds）\n", i + 1);
            return 0;
        }
        if (gVerbose) printf("  %2ds ...\n", i + 1);
    }
    printf("✗ 15 秒内没有出现 1506\n");
    return 2;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    int race = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--direct")) race = 0;
        if (!strcmp(argv[i], "--verbose")) gVerbose = 1;
    }

    printf("=== 切换前 ===\n  1505:%s  1506:%s\n\n",
           pid_present(PID_ZERO_CD) ? "在" : "不在",
           pid_present(PID_MODEM) ? "在" : "不在");

    int ok = 0;

    if (!race) {
        io_service_t dsvc = 0;
        IOUSBDeviceInterface **dev = open_device(PID_ZERO_CD, &dsvc);
        if (!dev) {
            fprintf(stderr, "[x] 打不开 12d1:1505（可能不在该模式，或需要 root）\n");
            return 1;
        }
        IOUSBInterfaceInterface **intf = grab_interface(dev);
        if (intf) {
            push_payload(intf);
            (*intf)->USBInterfaceClose(intf);
            (*intf)->Release(intf);
            ok = 1;
        }
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        if (dsvc) IOObjectRelease(dsvc);
        if (!ok) {
            fprintf(stderr,
                "[x] 抢不到接口：IOUSBMassStorageDriver 仍占着它。\n"
                "    请先跑 1c-switch-linuxway.sh（它会临时卸载该驱动）。\n");
            return 1;
        }
    } else {
        for (int attempt = 1; attempt <= 6 && !ok; attempt++) {
            io_service_t dsvc = 0;
            IOUSBDeviceInterface **dev = open_device(PID_ZERO_CD, &dsvc);
            if (!dev) { usleep(500000); continue; }

            printf("--- 第 %d 次尝试 ---\n", attempt);
            IOReturn kr = (*dev)->USBDeviceReEnumerate(dev, 0);
            printf("  ReEnumerate: 0x%08x\n", kr);
            (*dev)->USBDeviceClose(dev);
            (*dev)->Release(dev);
            if (dsvc) IOObjectRelease(dsvc);
            if (kr != kIOReturnSuccess) { usleep(800000); continue; }

            /* 重枚举后立刻反复试着抢 */
            for (int i = 0; i < 300 && !ok; i++) {
                io_service_t s2 = 0;
                IOUSBDeviceInterface **d2 = open_device(PID_ZERO_CD, &s2);
                if (d2) {
                    IOUSBInterfaceInterface **intf = grab_interface(d2);
                    if (intf) {
                        printf("  [+] 约 %d ms 时抢到接口\n", i * 3);
                        push_payload(intf);
                        (*intf)->USBInterfaceClose(intf);
                        (*intf)->Release(intf);
                        ok = 1;
                    }
                    (*d2)->USBDeviceClose(d2);
                    (*d2)->Release(d2);
                }
                if (s2) IOObjectRelease(s2);
                usleep(3000);
            }
            if (!ok) printf("  [-] 这一轮没抢到\n");
        }
        if (!ok) {
            fprintf(stderr,
                "\n[x] 空窗期抢占失败：驱动重绑定比用户态轮询快得多。\n"
                "    这是 macOS 的固有差异，只能靠 1c 脚本先卸载驱动。\n");
            return 2;
        }
    }

    return wait_for_1506();
}
