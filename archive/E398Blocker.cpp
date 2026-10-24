//
//  E398Blocker.cpp
//
//  目的：抢在 IOUSBMassStorageDriver 之前占住 12d1:1505 的那个 mass-storage 接口。
//
//  为什么需要它：
//    Linux 上 usb_modeswitch 用 libusb_detach_kernel_driver() 把 usb-storage 摘掉，
//    然后独占接口写 UFI 切换报文。macOS 没有按设备 detach 的能力，
//    而 IOUSBMassStorageDriver 又在启动内核集合（BootKernelExtensions.kc）里，
//    运行时根本不能 kextunload。
//
//  本驱动只做一件事：靠更高的 IOProbeScore 在匹配阶段胜出，占住 IOUSBHostInterface。
//  它【不调用】interface->open()，所以并不独占总线和端点；
//  苹果的 nub 因此不会加载，而用户态的 e398_bulk 仍然可以 USBInterfaceOpenSeize。
//
//  不写任何 USB 收发代码，把内核态风险压到最低。
//

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>

class E398Blocker : public IOService
{
    OSDeclareDefaultStructors(E398Blocker)

public:
    virtual bool start(IOService *provider);
    virtual void stop(IOService *provider);
};

OSDefineMetaClassAndStructors(E398Blocker, IOService)

bool E398Blocker::start(IOService *provider)
{
    if (!IOService::start(provider))
        return false;

    IOLog("E398Blocker: 已占住 IOUSBHostInterface (12d1:1505)，"
          "未 open，用户态可 seize\n");
    return true;
}

void E398Blocker::stop(IOService *provider)
{
    IOLog("E398Blocker: 释放接口\n");
    IOService::stop(provider);
}
