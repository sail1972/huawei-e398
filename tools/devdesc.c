/*
 * devdesc.c — 读 12d1:1505 的设备描述符和全部配置描述符
 *
 * 目的：确认这台 E398 到底有几套配置（bNumConfigurations）。
 * 如果存在第二套配置直接就是 modem 接口，那么只要发一条
 * SET_CONFIGURATION(2) 就能切换，完全不需要碰 bulk 接口。
 *
 * 编译: clang -O2 -Wno-deprecated-declarations -o devdesc devdesc.c \
 *              -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static IOUSBDeviceInterface **open_dev(void)
{
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = 0x12d1, p = 0x1505;
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
    if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) {
        if ((*dev)->USBDeviceOpenSeize(dev) != kIOReturnSuccess) {
            (*dev)->Release(dev);
            return NULL;
        }
    }
    return dev;
}

static IOReturn get_desc(IOUSBDeviceInterface **dev, UInt8 type, UInt8 index,
                         void *buf, UInt16 len)
{
    IOUSBDevRequest req;
    memset(&req, 0, sizeof req);
    req.bmRequestType = 0x80;
    req.bRequest = 6;                     /* GET_DESCRIPTOR */
    req.wValue = (UInt16)((type << 8) | index);
    req.wIndex = 0;
    req.wLength = len;
    req.pData = buf;
    return (*dev)->DeviceRequest(dev, &req);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    IOUSBDeviceInterface **dev = open_dev();
    if (!dev) { fprintf(stderr, "打不开 12d1:1505\n"); return 1; }

    unsigned char d[18];
    memset(d, 0, sizeof d);
    IOReturn kr = get_desc(dev, 1, 0, d, 18);
    printf("GET_DESCRIPTOR(device) -> 0x%08x, bLength=%d\n", kr, d[0]);
    printf("  原始字节: ");
    for (int i = 0; i < 18; i++) printf("%02x ", d[i]);
    printf("\n\n");
    printf("  bcdUSB              = 0x%04x\n", d[2] | (d[3] << 8));
    printf("  bDeviceClass        = 0x%02x\n", d[4]);
    printf("  bDeviceSubClass     = 0x%02x\n", d[5]);
    printf("  bDeviceProtocol     = 0x%02x\n", d[6]);
    printf("  bMaxPacketSize0     = %d\n", d[7]);
    printf("  idVendor            = 0x%04x\n", d[8] | (d[9] << 8));
    printf("  idProduct           = 0x%04x\n", d[10] | (d[11] << 8));
    printf("  bcdDevice           = 0x%04x\n", d[12] | (d[13] << 8));
    printf("  bNumConfigurations  = %d   <<<<<< 关键\n\n", d[17]);

    int ncfg = d[17];
    if (ncfg <= 0 || ncfg > 8) { printf("配置数异常，放弃\n"); return 2; }

    for (int i = 0; i < ncfg; i++) {
        unsigned char c[9];
        memset(c, 0, sizeof c);
        kr = get_desc(dev, 2, (UInt8)i, c, 9);
        printf("配置 #%d: GET -> 0x%08x  wTotalLength=%d  bNumInterfaces=%d  bConfigurationValue=%d  bmAttributes=0x%02x  bMaxPower=%d\n",
               i, kr, c[2] | (c[3] << 8), c[4], c[5], c[7], c[8] * 2);
    }

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 0;
}
