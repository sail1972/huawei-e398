/*
 * E398Switcher.cpp — 在核内完成华为 E398 的 USB 模式切换（12d1:1505 → 12d1:1506）
 *
 * 为什么必须在核内做：
 *   IOUSBHostInterface 是独占的（头文件原话：Only one service may open a session at a time），
 *   苹果的 IOUSBMassStorageInterfaceNub / IOUSBMassStorageDriver 匹配成功后立刻 open() 了它，
 *   所以用户态 USBInterfaceOpenSeize 永远只能拿到 0xe00002c5（独占）。
 *   实测：diskutil eject 掉虚拟光驱、乃至 USBDeviceReEnumerate，接口的
 *   UsbExclusiveOwner 仍然是 IOUSBMassStorageInterfaceNub，用户态拿不到。
 *
 * 版本演进（每个版本都是被实测推翻后才改的）：
 *   1.2.0  _kmod_info 的 start/stop 传 0 → 内核报 NULL module start pointer，
 *          整个载入被回滚，类没注册；但 kmutil showloaded 照样列着它（假象）。
 *   1.3.0  start/stop 换成真函数 → kmod start 成功，E398Loader 实例出现。
 *   1.4.0  personality 抢不到接口（mass-storage 的 50000 分先到先得），改成
 *          E398Loader 挂 IOResources 起线程主动扫描。但线程只跑 30 轮就退出。
 *   1.5.0  实测发现：物理拔插后设备会回到 1505（mode 不存在固件里，USB 断电就丢），
 *          所以 30 秒窗口根本不够 —— 改成永久监视，任何时刻插上都自动切换。
 *          另外接口被占用时先试 kIOServiceSeize（让 IOService 自己把占用者撤下），
 *          失败再 terminate 那个 MassStorage 子服务，两条路都记日志。
 *
 * 为什么要另起线程，而不是在 start() 里直接做：
 *   start() 跑在 USB 的 workloop 上，IOUSBHostInterface::open() 会 commandSleep
 *   等 workloop 处理 —— 自己等自己，必死。内核线程不占 workloop，同步调用才安全。
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/usb/IOUSBHostInterface.h>
#include <IOKit/usb/IOUSBHostPipe.h>
#include <IOKit/usb/IOUSBHostFamily.h>
#include <IOKit/usb/IOUSBHostDevice.h>
#include <kern/thread.h>
#include <mach/kmod.h>
#include <string.h>

/*
 * 必须有 _kmod_info，否则 kmutil 直接拒绝：
 *   cannot be placed in kernel collection because: kexts must have a _kmod_info symbol
 *
 * 老链接器（ld64）在 -kext 模式下会自动合成这个符号；本机是 ld-1267
 * （Xcode 16 起的新链接器），已经不再自动生成，只能由源码显式声明。
 *
 * 这里的 start/stop 绝不能传 0（1.2.0 的致命错误）：
 *   Kext local.e398.switcher - NULL module start pointer.
 *   Kext local.e398.switcher start failed (result 0xdc008007).
 *   后果：整个载入被回滚、类不注册，但 kmutil showloaded 照样列着它。
 */
extern "C" kern_return_t E398KmodStart(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    IOLog("E398Switcher: kmod start 成功（kext 已真正进入内核，类已注册）\n");
    return KERN_SUCCESS;
}

extern "C" kern_return_t E398KmodStop(kmod_info_t *ki, void *data)
{
    (void)ki;
    (void)data;
    return KERN_SUCCESS;
}

extern "C" {
KMOD_EXPLICIT_DECL(E398Switcher, "1.5.0", E398KmodStart, E398KmodStop);
}

/* usb_modeswitch.d/12d1:1505 的 MessageContent，逐字节一致，共 31 字节。
 * 它不是合法 SCSI 命令，无法让存储栈代为生成，只能原样重放。
 * 设备即使回 STALL 也照样会切换（Linux 下 usb_modeswitch 也是发完不管应答）。 */
static const UInt8 kE398SwitchPacket[31] = {
    0x55, 0x53, 0x42, 0x43,   /* "USBC" 签名 */
    0x12, 0x34, 0x56, 0x78,   /* tag */
    0x00, 0x00, 0x00, 0x00,   /* data transfer length = 0 */
    0x00,                     /* flags：Data-Out */
    0x00,                     /* LUN */
    0x00,                     /* CB length */
    0x11, 0x06, 0x20, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

#define E398_IO_TIMEOUT_MS 2000
#define E398_MAX_SEND      6      /* 同一个接口最多重发几次报文 */

/* 内核里不保证有 strstr（stdlib 的 string.h 在 KERNEL 下只给一部分），
 * 自己写一个子串判断，避免链接期缺符号。 */
static bool e398StrContains(const char *haystack, const char *needle)
{
    if (!haystack || !needle) {
        return false;
    }
    for (const char *h = haystack; *h; h++) {
        const char *a = h;
        const char *b = needle;
        while (*a && *b && *a == *b) {
            a++;
            b++;
        }
        if (*b == '\0') {
            return true;
        }
    }
    return false;
}

/* ==========================================================================
 * 报文发送
 * ========================================================================== */

struct E398Xfer {
    IOUSBHostCompletion      comp;
    IOBufferMemoryDescriptor *buf;
};

/* 完成回调：只记日志、释放资源，不碰任何可能已经消失的对象。 */
static void e398PacketDone(void *owner, void *parameter,
                           IOReturn status, uint32_t bytesTransferred)
{
    (void)owner;
    E398Xfer *x = (E398Xfer *)parameter;

    if (status == kIOReturnSuccess) {
        IOLog("E398Switcher: 切换报文已送达（%u 字节），设备应重新枚举为 12d1:1506\n",
              bytesTransferred);
    } else {
        IOLog("E398Switcher: 报文返回 status=0x%08x bytes=%u（STALL 属正常，"
              "观察设备是否重枚举）\n", status, bytesTransferred);
    }

    if (x) {
        if (x->buf) {
            x->buf->release();
        }
        IOFree(x, sizeof(E398Xfer));
    }
}

/* 从接口描述符里找第一个 bulk OUT 端点。不硬编码端点号。 */
static IOUSBHostPipe *e398FindBulkOut(IOUSBHostInterface *intf)
{
    if (!intf) {
        return NULL;
    }
    const StandardUSB::ConfigurationDescriptor *cfg = intf->getConfigurationDescriptor();
    const StandardUSB::InterfaceDescriptor *ifd = intf->getInterfaceDescriptor();
    if (!cfg || !ifd) {
        return NULL;
    }

    const StandardUSB::Descriptor *cur = NULL;
    while ((cur = StandardUSB::getNextAssociatedDescriptorWithType(
                cfg, ifd, cur, kDescriptorTypeEndpoint)) != NULL) {
        const StandardUSB::EndpointDescriptor *ep =
            (const StandardUSB::EndpointDescriptor *)cur;
        if (StandardUSB::getEndpointType(ep) != kEndpointTypeBulk) {
            continue;
        }
        if (StandardUSB::getEndpointDirection(ep) != kEndpointDirectionOut) {
            continue;
        }
        UInt8 addr = StandardUSB::getEndpointAddress(ep);
        IOUSBHostPipe *pipe = intf->copyPipe(addr);
        if (pipe) {
            IOLog("E398Switcher: 接口 #%u 使用 bulk OUT 端点 0x%02x\n",
                  ifd->bInterfaceNumber, addr);
            return pipe;
        }
    }
    return NULL;
}

/* 异步提交，立刻返回。缓冲区与 completion 都在堆上，活到回调为止。 */
static IOReturn e398SendSwitch(IOUSBHostInterface *intf)
{
    IOUSBHostPipe *pipe = e398FindBulkOut(intf);
    if (!pipe) {
        return kIOReturnNotFound;
    }

    E398Xfer *x = (E398Xfer *)IOMalloc(sizeof(E398Xfer));
    if (!x) {
        pipe->release();
        return kIOReturnNoMemory;
    }
    memset(x, 0, sizeof(*x));

    x->buf = IOBufferMemoryDescriptor::withOptions(kIODirectionOut,
                                                   sizeof(kE398SwitchPacket));
    if (!x->buf) {
        IOFree(x, sizeof(E398Xfer));
        pipe->release();
        return kIOReturnNoMemory;
    }
    memcpy(x->buf->getBytesNoCopy(), kE398SwitchPacket, sizeof(kE398SwitchPacket));

    x->comp.owner     = NULL;
    x->comp.action    = &e398PacketDone;
    x->comp.parameter = x;

    IOReturn kr = pipe->io(x->buf, (uint32_t)sizeof(kE398SwitchPacket),
                           &x->comp, E398_IO_TIMEOUT_MS);
    pipe->release();

    if (kr != kIOReturnSuccess) {
        x->buf->release();
        IOFree(x, sizeof(E398Xfer));
    }
    return kr;
}

/* ==========================================================================
 * 扫描 / 抢占 / 切换 —— 两个类共用同一套逻辑
 * ========================================================================== */

struct E398State {
    IOService           *client;       /* open/close 用谁的名义（驱动自己） */
    bool                 seizeTried;   /* 是否试过 kIOServiceSeize */
    bool                 killTried;    /* 是否 terminate 过占用者 */
    int                  sendCount;    /* 已提交报文次数 */
    int                  openFails;    /* open 连续失败次数（用于降噪日志） */
    IOUSBHostInterface  *held;         /* 已 open 且 retain 的接口 */
};

static bool e398IsTarget(IOUSBHostInterface *intf)
{
    OSNumber *vid = OSDynamicCast(OSNumber, intf->getProperty("idVendor"));
    OSNumber *pid = OSDynamicCast(OSNumber, intf->getProperty("idProduct"));
    if (!vid || !pid) {
        return false;
    }
    return vid->unsigned32BitValue() == 0x12d1 && pid->unsigned32BitValue() == 0x1505;
}

/* 找出占着接口的服务（正常情况下是 IOUSBMassStorageInterfaceNub）。
 * 返回值已 retain，调用方负责 release。 */
static IOService *e398FindBlocker(IOUSBHostInterface *intf)
{
    OSIterator *kids = intf->getChildIterator(gIOServicePlane);
    if (!kids) {
        return NULL;
    }

    IOService *found = NULL;
    IOService *child = NULL;
    while ((child = OSDynamicCast(IOService, kids->getNextObject())) != NULL) {
        const char *name = child->getMetaClass()->getClassName();
        if (e398StrContains(name, "MassStorage")) {
            found = child;
            found->retain();
            break;
        }
    }
    kids->release();
    return found;
}

/* 返回 true 表示报文已经提交出去了 */
static bool e398HandleInterface(IOUSBHostInterface *intf, E398State *st)
{
    /* 已经持有这个接口：只在还没发够次数时重发 */
    if (st->held == intf) {
        if (st->sendCount >= E398_MAX_SEND) {
            return false;
        }
        st->sendCount++;
        IOReturn kr = e398SendSwitch(intf);
        IOLog("E398Switcher: 重发报文 #%d -> 0x%08x\n", st->sendCount, kr);
        return (kr == kIOReturnSuccess);
    }

    /* 换了一个接口对象：把旧的放掉 */
    if (st->held) {
        st->held->close(st->client);
        st->held->release();
        st->held = NULL;
        st->seizeTried = false;
        st->killTried  = false;
        st->sendCount  = 0;
        st->openFails  = 0;
    }

    OSString *owner = OSDynamicCast(OSString, intf->getProperty("UsbExclusiveOwner"));

    if (owner) {
        /* 路线 1：kIOServiceSeize —— 让 IOService 把当前占用者撤下来 */
        if (!st->seizeTried) {
            st->seizeTried = true;
            if (intf->open(st->client, kIOServiceSeize, NULL)) {
                IOLog("E398Switcher: kIOServiceSeize 成功，已从 %s 手里接管接口\n",
                      owner->getCStringNoCopy());
                st->held = intf;
                intf->retain();
                st->sendCount = 1;
                IOReturn kr = e398SendSwitch(intf);
                IOLog("E398Switcher: 已独占接口，下发 31 字节切换报文 -> 0x%08x\n", kr);
                return (kr == kIOReturnSuccess);
            }
            IOLog("E398Switcher: kIOServiceSeize 失败（占用者 %s 不让）\n",
                  owner->getCStringNoCopy());
        }

        /* 路线 2：terminate 那个 MassStorage 子服务（= Linux 的 unbind usb-storage） */
        if (!st->killTried) {
            st->killTried = true;
            IOService *blocker = e398FindBlocker(intf);
            if (blocker) {
                const char *cls = blocker->getMetaClass()->getClassName();
                IOLog("E398Switcher: 终止占用者 %s 以释放接口\n", cls ? cls : "?");
                blocker->terminate(kIOServiceSynchronous);
                blocker->release();
            } else {
                IOLog("E398Switcher: 属性说有占用者，但子节点里没找到 MassStorage 服务\n");
            }
        }
        return false;   /* 下一轮再看占用是否解除 */
    }

    /* 接口空闲：直接 open */
    if (intf->open(st->client, 0, NULL)) {
        IOLog("E398Switcher: 已独占接口（原本空闲），下发 31 字节切换报文\n");
        st->held = intf;
        intf->retain();
        st->sendCount = 1;
        IOReturn kr = e398SendSwitch(intf);
        IOLog("E398Switcher: 报文提交结果 0x%08x\n", kr);
        return (kr == kIOReturnSuccess);
    }

    /* 兜底再来一次 seize */
    if (intf->open(st->client, kIOServiceSeize, NULL)) {
        IOLog("E398Switcher: seize 兜底成功\n");
        st->held = intf;
        intf->retain();
        st->sendCount = 1;
        IOReturn kr = e398SendSwitch(intf);
        IOLog("E398Switcher: 报文提交结果 0x%08x\n", kr);
        return (kr == kIOReturnSuccess);
    }

    if (++st->openFails <= 3) {
        IOLog("E398Switcher: 接口没有占用者属性，但 open 仍然失败（第 %d 次）\n",
              st->openFails);
    }
    return false;
}

/* 扫一遍所有 IOUSBHostInterface，遇到 12d1:1505 就处理。
 * 返回 true 表示这一轮已经把报文发出去了。 */
static bool e398OneRound(E398State *st, int *foundCount)
{
    OSDictionary *match = IOService::serviceMatching("IOUSBHostInterface");
    if (!match) {
        return false;
    }
    OSIterator *iter = IOService::getMatchingServices(match);
    match->release();
    if (!iter) {
        return false;
    }

    bool submitted = false;
    int  seen = 0;
    IOService *svc = NULL;
    while ((svc = (IOService *)iter->getNextObject()) != NULL) {
        IOUSBHostInterface *intf = OSDynamicCast(IOUSBHostInterface, svc);
        if (!intf || !e398IsTarget(intf)) {
            continue;
        }
        seen++;
        /* getNextObject 下次调用时会释放上一个对象，先自己 retain */
        intf->retain();
        if (e398HandleInterface(intf, st)) {
            submitted = true;
        }
        intf->release();
    }
    iter->release();

    if (foundCount) {
        *foundCount = seen;
    }
    return submitted;
}

/* ==========================================================================
 * E398Switcher —— personality 双保险（匹配成功时也只交给线程做）
 * ========================================================================== */

class E398Switcher : public IOService
{
    OSDeclareDefaultStructors(E398Switcher)

private:
    IOUSBHostInterface *fInterface;
    E398State           fState;

    static void workerMain(void *arg, wait_result_t waitResult);

public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(E398Switcher, IOService)

void E398Switcher::workerMain(void *arg, wait_result_t waitResult)
{
    (void)waitResult;
    E398Switcher *self = (E398Switcher *)arg;

    /* 先离开 workloop，再 open —— 否则 commandSleep 会自己等自己 */
    IOSleep(1500);

    /* 给 loader 线程让路：它可能已经在处理同一个接口。
     * 只有在接口仍然被占着时才自己动手（seize / terminate）。 */
    for (int i = 0; i < 20; i++) {
        if (!self->fInterface) {
            break;
        }
        if (e398HandleInterface(self->fInterface, &self->fState)) {
            IOLog("E398Switcher: personality 线程完成切换\n");
            break;
        }
        IOSleep(1000);
    }
    self->release();
}

bool E398Switcher::start(IOService *provider)
{
    if (!IOService::start(provider)) {
        return false;
    }
    IOUSBHostInterface *intf = OSDynamicCast(IOUSBHostInterface, provider);
    if (!intf) {
        return false;
    }

    fInterface = intf;
    fInterface->retain();
    memset(&fState, 0, sizeof(fState));
    fState.client = this;

    /* 绝不在 start() 里 open()：这里跑在 workloop 上。 */
    IOLog("E398Switcher: personality 匹配到接口（交给后台线程处理）\n");

    retain();
    thread_t th = NULL;
    if (kernel_thread_start(&E398Switcher::workerMain, this, &th) != KERN_SUCCESS) {
        release();
        IOLog("E398Switcher: personality 线程创建失败\n");
    } else {
        thread_deallocate(th);
    }
    return true;
}

void E398Switcher::stop(IOService *provider)
{
    if (fState.held == fInterface) {
        fState.held = NULL;
    }
    if (fInterface) {
        fInterface->release();
        fInterface = NULL;
    }
    IOService::stop(provider);
}

/* ==========================================================================
 * E398Loader —— 挂在 IOResources 上，开机必定加载；永久监视 USB
 * ========================================================================== */

class E398Loader : public IOService
{
    OSDeclareDefaultStructors(E398Loader)

private:
    volatile bool fStop;
    E398State     fState;

    static void threadMain(void *arg, wait_result_t waitResult);
    void run(void);

public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(E398Loader, IOService)

bool E398Loader::start(IOService *provider)
{
    if (!IOService::start(provider)) {
        return false;
    }

    fStop = false;
    memset(&fState, 0, sizeof(fState));
    fState.client = this;

    IOLog("E398Switcher: kext 已加载（loader 挂钩生效），开始永久监视 12d1:1505\n");

    /* 线程结束时 release 掉这里的 retain，保证 this 在线程存活期间有效 */
    retain();
    thread_t th = NULL;
    if (kernel_thread_start(&E398Loader::threadMain, this, &th) != KERN_SUCCESS) {
        release();
        IOLog("E398Switcher: 创建监视线程失败（切换不会发生）\n");
    } else {
        thread_deallocate(th);
    }
    return true;
}

void E398Loader::stop(IOService *provider)
{
    fStop = true;
    IOService::stop(provider);
}

void E398Loader::threadMain(void *arg, wait_result_t waitResult)
{
    (void)waitResult;
    E398Loader *self = (E398Loader *)arg;
    self->run();
    self->release();
}

void E398Loader::run(void)
{
    int sec = 0;

    for (;;) {
        IOSleep(1000);
        if (fStop) {
            break;
        }
        sec++;

        int found = 0;
        bool submitted = e398OneRound(&fState, &found);

        if (submitted) {
            IOLog("E398Switcher: 第 %d 秒已下发切换报文，等待设备重枚举\n", sec);
            continue;   /* 等设备变成 1506，这轮不再重复扫 */
        }

        if (found > 0) {
            /* 看到 1505 但还没切成功：每秒都在处理，日志由 handleInterface 打 */
            continue;
        }

        /* 没有 1505 了：设备要么已经是 1506，要么还没插。
         * 这时把之前持有的接口放掉，为下一次拔插做准备。 */
        if (fState.held) {
            fState.held->close(fState.client);
            fState.held->release();
            fState.held        = NULL;
            fState.seizeTried  = false;
            fState.killTried   = false;
            fState.sendCount   = 0;
            fState.openFails   = 0;
        }

        if (sec % 300 == 0) {
            IOLog("E398Switcher: 监视中（已运行 %d 秒，当前没有 12d1:1505）\n", sec);
        }
    }
    IOLog("E398Switcher: 监视线程退出\n");
}
