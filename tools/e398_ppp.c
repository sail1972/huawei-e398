/*
 * e398_ppp.c — 把 12d1:1506 的 if0 桥接到 pppd（标准输入/输出）
 *
 * 为什么需要它：
 *   1506 模式暴露的 6 个接口全是厂商自定义类（ff/01/xx），macOS 没有任何
 *   驱动会碰它们，所以永远不会有 /dev/cu.*。华为官方 kext 是 2013 年的老货，
 *   依赖 com.apple.iokit.IOUSBFamily 的旧 API（IOUSBDevice 族），装不进
 *   macOS 15 的 AuxKC，装了也没用。
 *   实测这些接口在用户态可以直接 open + 收发 bulk，于是把它桥接成一条
 *   数据通道给 pppd 用：pppd 用 `pty` 选项起它，它负责 stdin/stdout ↔ USB。
 *
 * 实测得到的事实（E398，12d1:1506）：
 *   if0  ff/01/01  AT 口；发 ATD*99***1# 之后同一个口进入 PPP 数据态
 *   if1  ff/01/02  PCUI，持续上报 ^RSSI / ^LTERSRP / ^STIN
 *   if2/if4        无 AT 响应
 *   if5  08/06/50  CD-ROM
 *
 * 编译:
 *   clang -O2 -Wno-deprecated-declarations -o e398_ppp e398_ppp.c \
 *         -framework IOKit -framework CoreFoundation
 *
 * 用法:
 *   ./e398_ppp --iface 0 --log /tmp/e398-ppp.log      桥接（给 pppd 的 pty 用）
 *   ./e398_ppp --iface 0 --reset --cat               先 +++/ATH 复位，再当 AT 用（调试）
 *   echo -n "AT" | ./e398_ppp --iface 0 --reset      简单自测
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdarg.h>
#include <sys/time.h>
#include <pthread.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0x12d1
#define PID_MODEM 0x1506
#define RXBUF 4096

static IOUSBInterfaceInterface **gIntf = NULL;
static UInt8 gOutPipe = 0, gInPipe = 0;
static FILE *gLog = NULL;
static int gVerbose = 0;

static void logmsg(const char *fmt, ...)
{
    if (!gLog) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    fprintf(gLog, "%ld.%03d ", (long)tv.tv_sec, (int)(tv.tv_usec / 1000));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gLog, fmt, ap);
    va_end(ap);
    fputc('\n', gLog);
    fflush(gLog);
}

static int has_str(const unsigned char *hay, UInt32 n, const char *needle)
{
    size_t m = strlen(needle);
    if (!m || n < m) return 0;
    for (UInt32 i = 0; i + m <= n; i++) if (!memcmp(hay + i, needle, m)) return 1;
    return 0;
}

static int write_all(int fd, const unsigned char *b, size_t n)
{
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, b + off, n - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return 0;
}

static IOUSBDeviceInterface **open_device(void)
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
    IOObjectRelease(svc);
    if (!dev) return NULL;

    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != kIOReturnSuccess) {
        logmsg("设备打开失败 0x%08x", kr);
        (*dev)->Release(dev);
        return NULL;
    }
    return dev;
}

static IOUSBInterfaceInterface **open_iface(IOUSBDeviceInterface **dev, int want)
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
        if (num != (UInt8)want) { (*intf)->Release(intf); IOObjectRelease(isvc); continue; }

        IOReturn kr = (*intf)->USBInterfaceOpenSeize(intf);
        if (kr != kIOReturnSuccess) kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            logmsg("if%d 打开失败 0x%08x", num, kr);
            (*intf)->Release(intf); IOObjectRelease(isvc); continue;
        }

        UInt8 n = 0;
        (*intf)->GetNumEndpoints(intf, &n);
        UInt8 o = 0, in = 0;
        for (UInt8 k = 1; k <= n; k++) {
            UInt8 dir = 0, ep = 0, type = 0, iv = 0; UInt16 mps = 0;
            if ((*intf)->GetPipeProperties(intf, k, &dir, &ep, &type, &mps, &iv) != kIOReturnSuccess) continue;
            if (type == 2) { if (!dir && !o) o = k; else if (dir && !in) in = k; }
        }
        gOutPipe = o; gInPipe = in;
        found = intf;
        IOObjectRelease(isvc);
        break;
    }
    IOObjectRelease(it);
    return found;
}

/* 清掉可能残留的管道 stall */
static void clear_stalls(void)
{
    if (!gIntf) return;
    if (gInPipe) (*gIntf)->ClearPipeStallBothEnds(gIntf, gInPipe);
    if (gOutPipe) (*gIntf)->ClearPipeStallBothEnds(gIntf, gOutPipe);
}

/* 若上次会话把口留在 PPP 数据态，用 +++ / ATH 拉回命令态 */
static void do_reset(void)
{
    if (!gIntf || !gOutPipe) return;
    logmsg("复位：+++ / ATH");
    clear_stalls();
    usleep(1000000);
    (*gIntf)->WritePipeTO(gIntf, gOutPipe, (void *)"+++", 3, 1000, 1000);
    usleep(1200000);
    (*gIntf)->WritePipeTO(gIntf, gOutPipe, (void *)"\rATH\r", 5, 1000, 1000);

    unsigned char buf[512];
    for (int i = 0; i < 5; i++) {
        UInt32 len = sizeof buf;
        if ((*gIntf)->ReadPipeTO(gIntf, gInPipe, buf, &len, 300, 300) == kIOReturnSuccess && len > 0) {
            char s[160]; UInt32 j = 0;
            for (UInt32 k = 0; k < len && j < sizeof s - 1; k++) {
                unsigned char c = buf[k];
                s[j++] = (c >= 0x20 && c < 0x7f) ? (char)c : ' ';
            }
            s[j] = 0;
            logmsg("复位响应: %s", s);
        }
    }

    /* 确认命令态可用 */
    (*gIntf)->WritePipeTO(gIntf, gOutPipe, (void *)"AT\r", 3, 1000, 1000);
    for (int i = 0; i < 5; i++) {
        UInt32 len = sizeof buf;
        if ((*gIntf)->ReadPipeTO(gIntf, gInPipe, buf, &len, 300, 300) == kIOReturnSuccess && len > 0) {
            if (has_str(buf, len, "OK")) { logmsg("复位成功：AT -> OK"); return; }
        }
    }
    logmsg("复位后 AT 仍无 OK（可能仍在数据态，或电话还挂着）");
}

/* 线程 1：stdin → USB bulk OUT */
static void *pump_in(void *arg)
{
    (void)arg;
    unsigned char buf[1024];
    for (;;) {
        ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n <= 0) { logmsg("stdin 关闭，退出"); exit(0); }
        IOReturn kr = (*gIntf)->WritePipeTO(gIntf, gOutPipe, buf, (UInt32)n, 2000, 2000);
        if (kr != kIOReturnSuccess) {
            logmsg("写 USB 失败 0x%08x（%zd 字节）", kr, n);
            clear_stalls();
        }
    }
    return NULL;
}

/* 线程 2：USB bulk IN → stdout */
static void *pump_out(void *arg)
{
    (void)arg;
    unsigned char buf[RXBUF];
    int fails = 0;
    for (;;) {
        UInt32 len = sizeof buf;
        IOReturn kr = (*gIntf)->ReadPipeTO(gIntf, gInPipe, buf, &len, 1000, 1000);
        if (kr == kIOReturnSuccess && len > 0) {
            fails = 0;
            if (write_all(STDOUT_FILENO, buf, len) != 0) { logmsg("stdout 写失败，退出"); exit(0); }
        } else if (kr != kIOReturnSuccess) {
            /* 超时是常态；连续大量错误才认为断了 */
            if (++fails % 100 == 0) logmsg("读 USB 连续失败 %d 次，最后一次 0x%08x", fails, kr);
            if (fails > 600) { logmsg("读 USB 彻底失败，退出"); exit(3); }
            usleep(10000);
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    int iface = 0, reset = 0, catmode = 0, reenum = 0, hangup = 0;
    const char *logpath = "/tmp/e398-ppp.log";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--iface") && i + 1 < argc) iface = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
        else if (!strcmp(argv[i], "--reset")) reset = 1;
        else if (!strcmp(argv[i], "--cat")) catmode = 1;
        else if (!strcmp(argv[i], "--reenum")) reenum = 1;
        else if (!strcmp(argv[i], "--hangup")) hangup = 1;
        else if (!strcmp(argv[i], "--verbose")) gVerbose = 1;
        else if (!strcmp(argv[i], "--help")) {
            printf("用法: e398_ppp [--iface N] [--log 路径] [--reset] [--cat]\n");
            return 0;
        }
    }

    gLog = fopen(logpath, "a");
    logmsg("=== e398_ppp 启动 iface=%d ===", iface);

    IOUSBDeviceInterface **dev = open_device();
    if (!dev) { logmsg("找不到 12d1:1506"); return 1; }

    if (reenum) {
        IOReturn kr = (*dev)->USBDeviceReEnumerate(dev, 0);
        logmsg("ReEnumerate -> 0x%08x（等价于拔插一次）", kr);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return kr == kIOReturnSuccess ? 0 : 4;
    }

    gIntf = open_iface(dev, iface);
    if (!gIntf || !gOutPipe || !gInPipe) {
        logmsg("接口打开失败（out=%d in=%d）", gOutPipe, gInPipe);
        return 2;
    }
    logmsg("接口 if%d 已打开 out=%d in=%d", iface, gOutPipe, gInPipe);

    if (hangup) {
        /* 只做「把 modem 从 PPP 数据态拉回命令态」，然后退出 */
        do_reset();
        (*gIntf)->USBInterfaceClose(gIntf);
        (*gIntf)->Release(gIntf);
        (*dev)->USBDeviceClose(dev);
        (*dev)->Release(dev);
        return 0;
    }

    if (reset) do_reset();

    if (catmode) {
        /* 调试：把 stdin 原样发出去，把收到的原样打到 stdout，不进入线程模式 */
        pthread_t t;
        pthread_create(&t, NULL, pump_out, NULL);
        pump_in(NULL);
        return 0;
    }

    pthread_t t1, t2;
    pthread_create(&t1, NULL, pump_out, NULL);
    pthread_create(&t2, NULL, pump_in, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    return 0;
}
