#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

int main(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBDevice");
    int v = 0x12d1, p = 0x1505;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);
    io_iterator_t it; IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it);
    io_service_t svc = IOIteratorNext(it);
    if (!svc) { printf("no device\n"); return 1; }
    IOCFPlugInInterface **plug = NULL; SInt32 sc = 0;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &sc);
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*)&dev);
    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    printf("USBDeviceOpen (no seize): 0x%08x\n", kr);
    if (kr != kIOReturnSuccess) {
        kr = (*dev)->USBDeviceOpenSeize(dev);
        printf("USBDeviceOpenSeize      : 0x%08x\n", kr);
        if (kr != kIOReturnSuccess) return 2;
    }
    IOUSBDevRequest req;
    unsigned char buf[8] = {0};
    req.bmRequestType = 0x80; req.bRequest = 0; req.wValue = 0; req.wIndex = 0;
    req.wLength = 2; req.pData = buf; req.wLenDone = 0;
    kr = (*dev)->DeviceRequest(dev, &req);
    printf("GET_STATUS              : 0x%08x  data=%02x %02x (done=%d)\n", kr, buf[0], buf[1], req.wLenDone);

    req.bmRequestType = 0x80; req.bRequest = 6; req.wValue = 0x0100; req.wIndex = 0;
    req.wLength = 8; req.pData = buf; req.wLenDone = 0;
    kr = (*dev)->DeviceRequest(dev, &req);
    printf("GET_DESCRIPTOR(dev)     : 0x%08x  done=%d  %02x %02x %02x %02x %02x %02x\n",
           kr, req.wLenDone, buf[0], buf[1], buf[2], buf[3], buf[4], buf[5]);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev); (*plug)->Release(plug); IOObjectRelease(svc);
    return 0;
}
