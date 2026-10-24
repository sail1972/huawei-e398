/*
 * e398_at.c — 在 12d1:1506 的厂商接口上收发 AT（用户态，无需驱动、无需 root）
 *
 * 实测接口布局（E398，1506 模式）：
 *   if0  ff/01/01  AT 命令口        ← 发 AT 有 OK
 *   if1  ff/01/02  PCUI/URC 口      ← 主动上报 ^RSSI / ^LTERSRP / ^STIN
 *   if2  ff/01/03  无响应
 *   if3  ff/01/09  只有中断端点
 *   if4  ff/01/08  无响应（疑似数据口）
 *   if5  08/06/50  CD-ROM（苹果存储驱动占着，打不开）
 *
 * 编译:
 *   clang -O2 -Wno-deprecated-declarations -o e398_at e398_at.c \
 *         -framework IOKit -framework CoreFoundation
 *
 * 用法:
 *   ./e398_at                                   逐个接口发 AT，报出谁响应
 *   ./e398_at --iface 0 --cmd "AT+CPIN?"        单条命令
 *   ./e398_at --iface 0 --cmd AT --cmd "AT+CSQ" 按顺序发多条
 *   ./e398_at --iface 1 --read 3000             只读 3 秒（看主动上报）
 *   ./e398_at --iface 0 --dial "*99#"           发 ATD 拨号，打印回什么
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
#define PID_MODEM 0x1506

static int gVerbose = 0;
static int gHex = 0;

static int contains(const unsigned char *hay, UInt32 n, const char *needle)
{
    size_t m = strlen(needle);
    if (m == 0 || n < m) return 0;
    for (UInt32 i = 0; i + m <= n; i++)
        if (memcmp(hay + i, needle, m) == 0) return 1;
    return 0;
}

static void dump(const unsigned char *b, UInt32 n, const char *tag)
{
    printf("  %s (%u 字节)", tag, (unsigned)n);
    if (gHex) {
        printf("\n     ");
        for (UInt32 i = 0; i < n && i < 96; i++) printf("%02x ", b[i]);
    }
    printf("\n     |");
    for (UInt32 i = 0; i < n && i < 200; i++) {
        unsigned char c = b[i];
        putchar((c >= 0x20 && c < 0x7f) ? c : (c == '\r' ? ' ' : (c == '\n' ? ' ' : '.')));
    }
    printf("|\n");
}

static IOUSBDeviceInterface **open_device(io_service_t *outSvc)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = VID, p = PID_MODEM;
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
        fprintf(stderr, "  ✗ 设备打开失败 0x%08x\n", kr);
        (*dev)->Release(dev);
        IOObjectRelease(svc);
        return NULL;
    }
    if (outSvc) *outSvc = svc; else IOObjectRelease(svc);
    return dev;
}

/* 打开指定编号的接口，拿 bulk 管道 */
static IOUSBInterfaceInterface **open_iface(IOUSBDeviceInterface **dev, int want,
                                            UInt8 *outPipe, UInt8 *inPipe)
{
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t it = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &it) != kIOReturnSuccess) return NULL;

    IOUSBInterfaceInterface **found = NULL;
    io_service_t isvc;
    while ((isvc = IOIteratorNext(it))) {
        IOCFPlugInInterface **plug = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(isvc, kIOUSBInterfaceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plug, &score) != KERN_SUCCESS || !plug) {
            IOObjectRelease(isvc); continue;
        }
        IOUSBInterfaceInterface **intf = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
        (*plug)->Release(plug);
        if (!intf) { IOObjectRelease(isvc); continue; }

        UInt8 num = 255;
        (*intf)->GetInterfaceNumber(intf, &num);
        if (want >= 0 && num != (UInt8)want) { (*intf)->Release(intf); IOObjectRelease(isvc); continue; }

        IOReturn kr = (*intf)->USBInterfaceOpenSeize(intf);
        if (kr != kIOReturnSuccess) kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            printf("  if%-2d 打不开（被驱动占用）0x%08x\n", num, kr);
            (*intf)->Release(intf); IOObjectRelease(isvc); continue;
        }

        UInt8 n = 0, o = 0, i2 = 0;
        (*intf)->GetNumEndpoints(intf, &n);
        for (UInt8 k = 1; k <= n; k++) {
            UInt8 dir = 0, ep = 0, type = 0, iv = 0; UInt16 mps = 0;
            if ((*intf)->GetPipeProperties(intf, k, &dir, &ep, &type, &mps, &iv) != kIOReturnSuccess) continue;
            if (gVerbose) printf("    if%d 管道%d dir=%s type=%d mps=%d\n", num, k, dir ? "IN" : "OUT", type, mps);
            if (type == 2) { if (!dir && !o) o = k; else if (dir && !i2) i2 = k; }
        }
        *outPipe = o; *inPipe = i2;
        found = intf;
        IOObjectRelease(isvc);
        break;
    }
    IOObjectRelease(it);
    return found;
}

static int hexv(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 写一条命令，最多等 waitMs，把收到的都打印出来 */
static int xfer(IOUSBInterfaceInterface **intf, UInt8 outPipe, UInt8 inPipe,
                const char *cmd, int waitMs, int quiet, int noBreak)
{
    if (cmd && *cmd) {
        if (!strcmp(cmd, "+++")) {
            /* PPP 数据态退出：+++ 前后各需 1 秒静默，然后 ATH */
            usleep(1000000);
            IOReturn kr = (*intf)->WritePipeTO(intf, outPipe, (void *)"+++", 3, 1000, 1000);
            printf("  → +++ (kr 0x%08x)，静默 1.2s 后 ATH\n", kr);
            usleep(1200000);
            (*intf)->WritePipeTO(intf, outPipe, (void *)"ATH\r", 4, 1000, 1000);
            cmd = NULL;
        } else {
            char line[128];
            snprintf(line, sizeof line, "%s\r", cmd);
            if (!quiet) printf("  → %s\n", cmd);
            IOReturn kr = (*intf)->WritePipeTO(intf, outPipe, line, (UInt32)strlen(line), 1000, 1000);
            if (kr != kIOReturnSuccess) { printf("  ✗ 写失败 0x%08x\n", kr); return -1; }
        }
    }

    unsigned char all[2048];
    UInt32 total = 0;
    int got = 0, elapsed = 0;
    while (elapsed < waitMs) {
        unsigned char buf[512];
        UInt32 len = sizeof buf;
        IOReturn kr = (*intf)->ReadPipeTO(intf, inPipe, buf, &len, 200, 200);
        elapsed += 200;
        if (kr == kIOReturnSuccess && len > 0) {
            got = 1;
            for (UInt32 i = 0; i < len && total < sizeof all - 1; i++) all[total++] = buf[i];
            if (!noBreak && (contains(all, total, "\r\nOK") || contains(all, total, "ERROR") ||
                contains(all, total, "CONNECT")))
                break;
        } else if (kr != 0xe0004051 /* timeout */) {
            if (!quiet) printf("  ✗ 读失败 0x%08x\n", kr);
            break;
        }
        if (!noBreak && got && total > 0 && elapsed >= 800) break;
    }
    if (got && total) { if (!quiet) dump(all, total, "←"); return (int)total; }
    if (!quiet) printf("  ← (无响应)\n");
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    int only = -1, waitMs = 1500, readOnly = 0, drainMs = 0;
    const char *dial = NULL;
    const char *rawHex = NULL;
    static const char *cmds[16];
    int ncmd = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--verbose")) gVerbose = 1;
        else if (!strcmp(argv[i], "--hex")) gHex = 1;
        else if (!strcmp(argv[i], "--iface") && i + 1 < argc) only = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--wait") && i + 1 < argc) waitMs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--read") && i + 1 < argc) { waitMs = atoi(argv[++i]); readOnly = 1; }
        else if (!strcmp(argv[i], "--dial") && i + 1 < argc) dial = argv[++i];
        else if (!strcmp(argv[i], "--drain") && i + 1 < argc) drainMs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--raw") && i + 1 < argc) rawHex = argv[++i];
        else if (!strcmp(argv[i], "--cmd") && i + 1 < argc && ncmd < 16) cmds[ncmd++] = argv[++i];
    }

    io_service_t dsvc = 0;
    IOUSBDeviceInterface **dev = open_device(&dsvc);
    if (!dev) { fprintf(stderr, "找不到 12d1:1506 或无法打开\n"); return 1; }

    if (only < 0 && ncmd == 0 && !dial && !readOnly) {
        printf("=== 探测 12d1:1506 各接口 ===\n");
        for (int k = 0; k <= 5; k++) {
            UInt8 o = 0, in = 0;
            IOUSBInterfaceInterface **intf = open_iface(dev, k, &o, &in);
            if (!intf) continue;
            UInt8 cls = 0, sub = 0, proto = 0;
            (*intf)->GetInterfaceClass(intf, &cls);
            (*intf)->GetInterfaceSubClass(intf, &sub);
            (*intf)->GetInterfaceProtocol(intf, &proto);
            printf("--- if%d  ff/%02x/%02x  out=%d in=%d ---\n", k, sub, proto, o, in);
            if (!o || !in) printf("  缺 bulk 对\n");
            else xfer(intf, o, in, "AT", 1200, 0, 0);
            (*intf)->USBInterfaceClose(intf);
            (*intf)->Release(intf);
        }
        (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
        if (dsvc) IOObjectRelease(dsvc);
        return 0;
    }

    UInt8 outPipe = 0, inPipe = 0;
    int target = only < 0 ? 0 : only;
    IOUSBInterfaceInterface **intf = open_iface(dev, target, &outPipe, &inPipe);
    if (!intf || !outPipe || !inPipe) {
        fprintf(stderr, "✗ 打开接口失败（out=%d in=%d）\n", outPipe, inPipe);
        return 1;
    }
    printf("=== if%d 已打开（out=%d in=%d）===\n", target, outPipe, inPipe);

    if (readOnly) {
        xfer(intf, outPipe, inPipe, NULL, waitMs, 0, 0);
    } else {
        if (rawHex) {
            unsigned char b[256]; int n = 0;
            const char *p = rawHex;
            while (*p && n < (int)sizeof b) {
                while (*p == ' ' || *p == ',' || *p == ':') p++;
                if (!p[0] || !p[1]) break;
                int hi = hexv(p[0]), lo = hexv(p[1]);
                if (hi < 0 || lo < 0) break;
                b[n++] = (unsigned char)(hi * 16 + lo);
                p += 2;
            }
            IOReturn kr = (*intf)->WritePipeTO(intf, outPipe, b, (UInt32)n, 3000, 3000);
            printf("  → raw %d 字节，WritePipeTO=0x%08x\n", n, kr);
            xfer(intf, outPipe, inPipe, NULL, waitMs, 0, 1);
        }
        for (int i = 0; i < ncmd; i++) xfer(intf, outPipe, inPipe, cmds[i], waitMs, 0, 0);
        if (dial) {
            char d[128];
            snprintf(d, sizeof d, "ATD%s;", dial);
            printf("  → %s  （拨号后等 %d ms）\n", d, waitMs);
            xfer(intf, outPipe, inPipe, d, waitMs, 0, 0);
        }
        if (drainMs > 0) { printf("  [drain] 继续读 %d ms（不提前退出）\n", drainMs); xfer(intf, outPipe, inPipe, NULL, drainMs, 0, 1); }
    }

    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    if (dsvc) IOObjectRelease(dsvc);
    return 0;
}
