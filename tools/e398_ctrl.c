/*
 * e398_ctrl.c — 华为 E398 (12d1:1505 -> 12d1:1506) 模式切换
 *
 * 移植自 usb_modeswitch 的 HuaweiMode 分支：
 *     usb_control_msg(devh, USB_TYPE_STANDARD + USB_RECIP_DEVICE,
 *                     USB_REQ_SET_FEATURE, 0x0001, 0, buffer, 0, 1000);
 * 即 bmRequestType=0x00, bRequest=0x03(SET_FEATURE), wValue=1, wIndex=0, wLength=0
 *
 * 这条请求走端点 0，不需要抢占 bulk 接口，因此不需要 kextunload，
 * 也不需要 root（实测 GET_STATUS/GET_DESCRIPTOR 均已可用）。
 *
 * 编译:
 *   clang -O2 -Wno-deprecated-declarations -o e398_ctrl e398_ctrl.c \
 *         -framework IOKit -framework CoreFoundation
 * 用法:
 *   ./e398_ctrl            发送华为切换请求并等待设备重枚举
 *   ./e398_ctrl --probe    只报告当前 PID
 *   ./e398_ctrl --raw 0x40 0x76 0x01 0x00  发任意控制请求（调试用）
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0x12d1
#define PID_ZERO_CD 0x1505
#define PID_MODEM   0x1506

/* 在 IOService 平面里查询某个 pid 是否出现 */
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
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it) != KERN_SUCCESS)
        return 0;
    io_service_t svc = IOIteratorNext(it);
    int found = (svc != 0);
    if (svc) IOObjectRelease(svc);
    IOObjectRelease(it);
    return found;
}

/* 打开设备：先普通 open，失败再 seize */
static IOUSBDeviceInterface **open_device(int productId)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = VID, p = productId;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it) != KERN_SUCCESS) {
        fprintf(stderr, "无法枚举 USB 设备\n");
        return NULL;
    }
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) {
        fprintf(stderr, "没找到 %04x:%04x\n", VID, productId);
        return NULL;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        fprintf(stderr, "创建插件接口失败 0x%08x\n", kr);
        IOObjectRelease(svc);
        return NULL;
    }

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                            (LPVOID *)&dev);
    if (!dev) {
        fprintf(stderr, "QueryInterface 失败\n");
        (*plug)->Release(plug);
        IOObjectRelease(svc);
        return NULL;
    }

    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) {
        printf("  [.] USBDeviceOpen 返回 0x%08x，尝试 seize\n", kr);
        kr = (*dev)->USBDeviceOpenSeize(dev);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "  [x] 设备打开失败 0x%08x\n", kr);
            (*dev)->Release(dev);
            (*plug)->Release(plug);
            IOObjectRelease(svc);
            return NULL;
        }
    }
    printf("  [+] 设备已打开（端点 0 可用）\n");

    (*plug)->Release(plug);
    IOObjectRelease(svc);
    return dev;
}

static IOReturn send_request(IOUSBDeviceInterface **dev,
                             UInt8 bmRequestType, UInt8 bRequest,
                             UInt16 wValue, UInt16 wIndex,
                             void *data, UInt16 wLength)
{
    IOUSBDevRequest req;
    memset(&req, 0, sizeof req);
    req.bmRequestType = bmRequestType;
    req.bRequest      = bRequest;
    req.wValue        = wValue;
    req.wIndex        = wIndex;
    req.wLength       = wLength;
    req.pData         = data;
    req.wLenDone      = 0;
    return (*dev)->DeviceRequest(dev, &req);
}

/* 官方 usb_modeswitch.d/12d1:1505 的 MessageContent */
static const char *UFI_HEX =
    "55534243123456780000000000000011062000000100000000000000000000";

static int hex2bin(const char *hex, unsigned char *out, int maxlen)
{
    int n = (int)strlen(hex) / 2;
    if (n > maxlen) n = maxlen;
    for (int i = 0; i < n; i++) {
        unsigned int b = 0;
        sscanf(hex + i * 2, "%2x", &b);
        out[i] = (unsigned char)b;
    }
    return n;
}

/* 尝试把 31 字节 UFI 报文用端点 0 的控制传输送进去
 * （Linux 上 usb_modeswitch 的 MessageEndpoint=0 就是这样发的） */
static int try_msg_control(int productId)
{
    unsigned char msg[64];
    int len = hex2bin(UFI_HEX, msg, sizeof msg);
    printf("  报文长度 %d 字节: ", len);
    for (int i = 0; i < len; i++) printf("%02x", msg[i]);
    printf("\n\n");

    /* bmRequestType, bRequest, wValue, wIndex, 是否带数据 */
    struct { UInt8 rt; UInt8 rq; UInt16 val; UInt16 idx; int data; const char *desc; } tries[] = {
        { 0x21, 0x00, 0x0000, 0x0000, 1, "class/interface  bRequest=0 (usb_modeswitch MessageEndpoint=0 的做法)" },
        { 0x20, 0x00, 0x0000, 0x0000, 1, "class/device     bRequest=0" },
        { 0x41, 0x01, 0x0000, 0x0000, 1, "vendor/interface bRequest=1" },
        { 0x40, 0x01, 0x0000, 0x0000, 1, "vendor/device    bRequest=1" },
        { 0x21, 0x01, 0x0000, 0x0000, 1, "class/interface  bRequest=1" },
        { 0x21, 0xff, 0x0000, 0x0000, 0, "BOT Mass-Storage Reset（仅复位，不带数据）" },
        { 0xa1, 0xfe, 0x0000, 0x0000, 0, "GET_MAX_LUN（探测接口是否响应）" },
    };

    int n = (int)(sizeof tries / sizeof tries[0]);
    for (int i = 0; i < n; i++) {
        IOUSBDeviceInterface **dev = open_device(productId);
        if (!dev) return 1;
        IOReturn kr;
        if (tries[i].data && tries[i].rt & 0x80) {
            unsigned char in[64] = {0};
            kr = send_request(dev, tries[i].rt, tries[i].rq, tries[i].val,
                              tries[i].idx, in, (UInt16)len);
            printf("  [%d] %-62s -> 0x%08x  回读 %02x %02x %02x %02x\n",
                   i + 1, tries[i].desc, kr, in[0], in[1], in[2], in[3]);
        } else if (tries[i].data) {
            kr = send_request(dev, tries[i].rt, tries[i].rq, tries[i].val,
                              tries[i].idx, msg, (UInt16)len);
            printf("  [%d] %-62s -> 0x%08x\n", i + 1, tries[i].desc, kr);
        } else if (tries[i].rt & 0x80) {
            unsigned char in[8] = {0};
            kr = send_request(dev, tries[i].rt, tries[i].rq, tries[i].val,
                              tries[i].idx, in, 1);
            printf("  [%d] %-62s -> 0x%08x  值=%d\n", i + 1, tries[i].desc, kr, in[0]);
        } else {
            kr = send_request(dev, tries[i].rt, tries[i].rq, tries[i].val,
                              tries[i].idx, NULL, 0);
            printf("  [%d] %-62s -> 0x%08x\n", i + 1, tries[i].desc, kr);
        }
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);

        /* 给固件一点时间重新枚举 */
        for (int w = 0; w < 6; w++) {
            usleep(400000);
            if (pid_present(PID_MODEM)) {
                printf("\n✓ 第 %d 条请求就切换成功了，设备现在是 12d1:1506\n", i + 1);
                return 0;
            }
        }
        if (!pid_present(productId)) {
            printf("      （设备已从总线上消失，可能正在重枚举）\n");
            for (int w = 0; w < 10; w++) {
                usleep(500000);
                if (pid_present(PID_MODEM)) {
                    printf("\n✓ 设备重新出现为 12d1:1506\n");
                    return 0;
                }
                if (pid_present(productId)) break;
            }
        }
    }
    printf("\n✗ 端点 0 的 7 种组合都没能触发切换\n");
    return 2;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
        printf("12d1:1505 (零CD) : %s\n", pid_present(PID_ZERO_CD) ? "在" : "不在");
        printf("12d1:1506 (modem): %s\n", pid_present(PID_MODEM) ? "在" : "不在");
        return 0;
    }

    if (argc > 1 && strcmp(argv[1], "--msg-control") == 0) {
        printf("=== 尝试用端点 0 送 UFI 报文（不需要 root / 不需要 kext）===\n");
        if (!pid_present(PID_ZERO_CD)) {
            fprintf(stderr, "[x] 当前没有 12d1:1505\n");
            return 1;
        }
        return try_msg_control(PID_ZERO_CD);
    }

    if (argc > 1 && strcmp(argv[1], "--raw") == 0 && argc >= 6) {
        UInt8 rt = (UInt8)strtoul(argv[2], NULL, 0);
        UInt8 rq = (UInt8)strtoul(argv[3], NULL, 0);
        UInt16 val = (UInt16)strtoul(argv[4], NULL, 0);
        UInt16 idx = (UInt16)strtoul(argv[5], NULL, 0);
        IOUSBDeviceInterface **dev = open_device(PID_ZERO_CD);
        if (!dev) return 1;
        IOReturn kr = send_request(dev, rt, rq, val, idx, NULL, 0);
        printf("  控制请求 %02x/%02x wValue=0x%04x wIndex=0x%04x -> 0x%08x\n",
               rt, rq, val, idx, kr);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return kr == kIOReturnSuccess ? 0 : 2;
    }

    int target = (argc > 1 && strcmp(argv[1], "--from-modem") == 0) ? PID_MODEM : PID_ZERO_CD;

    printf("=== 切换前 ===\n");
    printf("  1505: %s    1506: %s\n",
           pid_present(PID_ZERO_CD) ? "在" : "不在",
           pid_present(PID_MODEM) ? "在" : "不在");

    if (!pid_present(target)) {
        fprintf(stderr, "\n[x] 当前没有 %04x:%04x，请先插好设备\n", VID, target);
        return 1;
    }

    printf("\n=== 发送 HuaweiMode 切换请求 (SET_FEATURE, wValue=1) ===\n");
    IOUSBDeviceInterface **dev = open_device(target);
    if (!dev) return 1;

    IOReturn kr = send_request(dev, 0x00, 0x03, 0x0001, 0x0000, NULL, 0);
    printf("  SET_FEATURE 返回 0x%08x %s\n", kr,
           kr == kIOReturnSuccess ? "(成功)" : "(设备可能已立刻断开，属正常)");

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);

    printf("\n=== 等待设备重枚举 ===\n");
    for (int i = 0; i < 20; i++) {
        sleep(1);
        int m = pid_present(PID_MODEM);
        printf("  %2ds  1506:%s\n", i + 1, m ? " 出现了 ✓" : " 还没有");
        if (m) {
            printf("\n✓ 切换成功！设备现在是 12d1:1506\n");
            return 0;
        }
    }

    printf("\n✗ 20 秒内没看到 1506\n");
    if (pid_present(PID_ZERO_CD))
        printf("  设备仍在 1505，建议拔插一次再看。\n");
    else
        printf("  设备已从总线上消失（可能正在重枚举），请稍后跑 ./status.sh 确认。\n");
    return 2;
}
