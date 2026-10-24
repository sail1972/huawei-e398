#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static IOUSBDeviceInterface **open_dev(io_service_t *out) {
    io_iterator_t it;
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = 0x12d1, p = 0x1505;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);
    IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it);
    io_service_t svc = IOIteratorNext(it);
    if (!svc) return NULL;
    IOCFPlugInInterface **plug = NULL; SInt32 sc = 0;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &sc);
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*)&dev);
    if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) return NULL;
    *out = svc;
    return dev;
}

int main(void) {
    io_service_t svc; IOUSBDeviceInterface **dev = open_dev(&svc);
    if (!dev) { printf("open failed\n"); return 1; }

    unsigned char buf[512];
    IOUSBDevRequest req;
    req.bmRequestType = 0x80; req.bRequest = 6; req.wValue = 0x0200; req.wIndex = 0;
    req.wLength = 9; req.pData = buf; req.wLenDone = 0;
    (*dev)->DeviceRequest(dev, &req);
    int total = buf[2] | (buf[3] << 8);
    printf("设备描述符: bcdUSB=0x%04x class=0x%02x sub=0x%02x proto=0x%02x bMaxPacket0=%d\n",
           buf[2] | (buf[3] << 8), buf[4], buf[5], buf[6], buf[7]);
    printf("            idVendor=0x%04x idProduct=0x%04x bNumConfigurations=%d\n",
           buf[8] | (buf[9] << 8), buf[10] | (buf[11] << 8), buf[17]);
    printf("配置描述符 wTotalLength = %d, bNumInterfaces = %d, bConfigurationValue = %d\n\n",
           total, buf[4], buf[5]);

    memset(buf, 0, sizeof buf);
    req.wLength = total > 512 ? 512 : total; req.wLenDone = 0;
    IOReturn kr = (*dev)->DeviceRequest(dev, &req);
    printf("读取完整配置: 0x%08x, 实际 %d 字节\n\n", kr, req.wLenDone);

    int i = 0, n = req.wLenDone;
    while (i < n) {
        int len = buf[i], type = buf[i + 1];
        if (len < 2) break;
        if (type == 0x04) {
            printf("接口 %d: class=0x%02x subclass=0x%02x protocol=0x%02x 端点数=%d\n",
                   buf[i + 2], buf[i + 5], buf[i + 6], buf[i + 7], buf[i + 4]);
        } else if (type == 0x05) {
            const char *dir = (buf[i + 2] & 0x80) ? "IN " : "OUT";
            const char *tt = (buf[i + 3] & 3) == 2 ? "bulk" : (buf[i + 3] & 3) == 3 ? "int" : "ctrl/iso";
            printf("    端点 0x%02x %s %s  maxpacket=%d\n",
                   buf[i + 2], dir, tt, buf[i + 4] | (buf[i + 5] << 8));
        } else if (type == 0x0b) {
            printf("    IAD: 首接口=%d 接口数=%d class=0x%02x sub=0x%02x proto=0x%02x\n",
                   buf[i + 2], buf[i + 3], buf[i + 4], buf[i + 5], buf[i + 6]);
        }
        i += len;
    }
    (*dev)->USBDeviceClose(dev);
    return 0;
}
