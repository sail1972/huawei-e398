/*
 * e398_scsi.c — 通过 macOS 存储栈给 E398 的虚拟光驱发任意 SCSI CDB
 *
 * 目的：Linux 上 usb_modeswitch 必须 detach usb-storage 再往 bulk 端点写报文。
 * macOS 上苹果的 IOUSBMassStorageDriver 不让抢接口，但它自己就是一条 SCSI 栈，
 * 可以尝试通过 SCSITaskDevice 用户客户端把 CDB 交给它，由它组 CBW 发给设备。
 *
 * 现代 macOS 上 IOSCSITaskDevice 往往没有实例，真正的节点是
 * IOSCSIPeripheralDeviceType05 之类的 nub，所以这里逐个候选类去试。
 *
 * 编译:
 *   clang -O2 -Wno-deprecated-declarations -o e398_scsi e398_scsi.c \
 *         -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/scsi/SCSICommandDefinitions.h>

static const char *kCandidates[] = {
    "IOSCSITaskDevice",
    "IOSCSIPeripheralDeviceType05",
    "IOSCSIPeripheralDeviceType00",
    "IOSCSIPeripheralDeviceNub",
    "IOSCSIMultimediaCommandsDevice",
    "IOCDBlockStorageDriver",
    "IOBlockStorageDriver",
    NULL
};

static int is_huawei(io_service_t svc)
{
    char path[2048];
    if (IORegistryEntryGetPath(svc, kIOServicePlane, path) == KERN_SUCCESS) {
        if (strcasestr(path, "HUAWEI") || strcasestr(path, "12d1")) return 1;
    }
    CFTypeRef v = IORegistryEntrySearchCFProperty(
        svc, kIOServicePlane, CFSTR("USB Product Name"), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (v) {
        int hit = 0;
        if (CFGetTypeID(v) == CFStringGetTypeID()) {
            char buf[256];
            if (CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8))
                hit = (strcasestr(buf, "HUAWEI") != NULL);
        }
        CFRelease(v);
        if (hit) return 1;
    }
    return 0;
}

static void hexdump(const UInt8 *p, int n)
{
    for (int i = 0; i < n; i++) printf("%02x ", p[i]);
    printf("\n");
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    UInt8 cdb[16];
    int cdbLen = 0;
    int listOnly = 0;
    memset(cdb, 0, sizeof cdb);

    if (argc < 2) {
        fprintf(stderr,
            "用法:\n"
            "  %s --list\n"
            "  %s --huawei            发 11 06 20 00 00 01（切换）\n"
            "  %s --eject             发 1b 00 00 00 02 00（弹出）\n"
            "  %s --report-luns       发 a1 00 ...（验证通路）\n"
            "  %s --cdb 1b0000000200\n", argv[0], argv[0], argv[0], argv[0], argv[0]);
        return 1;
    }
    if (!strcmp(argv[1], "--list")) {
        listOnly = 1;
    } else if (!strcmp(argv[1], "--huawei")) {
        static const UInt8 c[6] = { 0x11, 0x06, 0x20, 0x00, 0x00, 0x01 };
        memcpy(cdb, c, 6); cdbLen = 6;
    } else if (!strcmp(argv[1], "--eject")) {
        static const UInt8 c[6] = { 0x1b, 0x00, 0x00, 0x00, 0x02, 0x00 };
        memcpy(cdb, c, 6); cdbLen = 6;
    } else if (!strcmp(argv[1], "--report-luns")) {
        static const UInt8 c[12] = { 0xa1, 0x00, 0x00, 0x00, 0x00, 0x00,
                                     0x00, 0x00, 0x00, 0x10, 0x00, 0x00 };
        memcpy(cdb, c, 12); cdbLen = 12;
    } else if (!strcmp(argv[1], "--cdb") && argc > 2) {
        const char *h = argv[2];
        for (; h[0] && h[1] && cdbLen < 16; h += 2) {
            char t[3] = { h[0], h[1], 0 };
            cdb[cdbLen++] = (UInt8)strtoul(t, NULL, 16);
        }
    } else {
        fprintf(stderr, "参数不认识\n");
        return 1;
    }

    int totalHits = 0;

    for (int ci = 0; kCandidates[ci]; ci++) {
        CFMutableDictionaryRef match = IOServiceMatching(kCandidates[ci]);
        if (!match) continue;

        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMasterPortDefault, match, &iter) != KERN_SUCCESS)
            continue;

        io_service_t svc;
        while ((svc = IOIteratorNext(iter))) {
            char path[2048] = "(no path)";
            IORegistryEntryGetPath(svc, kIOServicePlane, path);
            int hw = is_huawei(svc);

            if (listOnly) {
                printf("%-34s %s %s\n", kCandidates[ci], hw ? "[华为]" : "[其它]", path);
                IOObjectRelease(svc);
                continue;
            }
            if (!hw) { IOObjectRelease(svc); continue; }
            totalHits++;

            printf("=== 命中类 %s ===\n%s\n", kCandidates[ci], path);

            IOCFPlugInInterface **plug = NULL;
            SInt32 score = 0;
            kern_return_t kr = IOCreatePlugInInterfaceForService(
                svc, kIOSCSITaskDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
            if (kr != KERN_SUCCESS || !plug) {
                printf("  [x] 该类不支持 SCSITaskDevice 用户客户端 (0x%08x)\n\n", kr);
                IOObjectRelease(svc);
                continue;
            }

            SCSITaskDeviceInterface **dev = NULL;
            (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
                                    (LPVOID *)&dev);
            if (!dev) {
                printf("  [x] QueryInterface 失败\n\n");
                (*plug)->Release(plug);
                IOObjectRelease(svc);
                continue;
            }

            printf("  [+] 拿到 SCSITaskDevice 接口\n");
            printf("  独占可用: %s\n",
                   (*dev)->IsExclusiveAccessAvailable(dev) ? "是" : "否（被占用）");

            IOReturn ok = (*dev)->ObtainExclusiveAccess(dev);
            printf("  ObtainExclusiveAccess: 0x%08x\n", ok);
            if (ok != kIOReturnSuccess) {
                printf("  [!] 拿不到独占权，跳过\n\n");
                (*dev)->Release(dev);
                (*plug)->Release(plug);
                IOObjectRelease(svc);
                continue;
            }

            SCSITaskInterface **task = (*dev)->CreateSCSITask(dev);
            if (!task) {
                printf("  [x] CreateSCSITask 失败\n\n");
                (*dev)->ReleaseExclusiveAccess(dev);
                (*dev)->Release(dev);
                (*plug)->Release(plug);
                IOObjectRelease(svc);
                continue;
            }

            printf("  发送 CDB: ");
            hexdump(cdb, cdbLen);

            ok = (*task)->SetCommandDescriptorBlock(task, cdb, (UInt8)cdbLen);
            if (ok != kIOReturnSuccess)
                printf("  [!] SetCommandDescriptorBlock 0x%08x\n", ok);
            (*task)->SetTimeoutDuration(task, 10000);

            SCSI_Sense_Data sense;
            memset(&sense, 0, sizeof sense);
            SCSITaskStatus status = 0;
            UInt64 done = 0;

            ok = (*task)->ExecuteTaskSync(task, &sense, &status, &done);
            printf("\n  ExecuteTaskSync : 0x%08x\n", ok);
            printf("  SCSITaskStatus  : 0x%02x (%s)\n", status,
                   status == kSCSITaskStatus_GOOD ? "GOOD" :
                   status == kSCSITaskStatus_CHECK_CONDITION ? "CHECK CONDITION" : "其它");
            printf("  传输字节数      : %llu\n", done);
            if (status == kSCSITaskStatus_CHECK_CONDITION)
                printf("  Sense: key=0x%02x ASC=0x%02x ASCQ=0x%02x\n",
                       sense.SENSE_KEY & 0x0f, sense.ADDITIONAL_SENSE_CODE,
                       sense.ADDITIONAL_SENSE_CODE_QUALIFIER);

            (*task)->Release(task);
            (*dev)->ReleaseExclusiveAccess(dev);
            (*dev)->Release(dev);
            (*plug)->Release(plug);
            IOObjectRelease(svc);
            printf("\n");
        }
        IOObjectRelease(iter);
    }

    if (listOnly) return 0;
    if (!totalHits) {
        fprintf(stderr, "所有候选类都没有命中华为设备\n");
        return 1;
    }
    return 0;
}
