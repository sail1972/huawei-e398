/*
 * E398Switcher.cpp — 在核内完成华为 E398 的 USB 模式切换（12d1:1505 → 12d1:1506）
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 一、和 Linux 驱动的对照（1.7.0 的改动全部由此而来）
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Linux 上有三方分工，各管一段，互不越界：
 *
 *   usb-storage  绑定 1505 的 08/06/50 接口（虚拟光驱），把它当 SCSI 设备
 *   usb_modeswitch 用 usb_driver_release_interface **主动解绑** usb-storage，
 *                 claim 接口，把 31 字节报文写到 MessageEndpoint(=0x01)，
 *                 然后 CheckSuccess 轮询目标 PID 是否出现
 *   option       绑定 1506 的 ff/01/01、ff/01/02（drivers/usb/serial/option.c:684-685
 *                的 USB_VENDOR_AND_INTERFACE_INFO(HUAWEI_VENDOR_ID, 0xff, 0x01, 0x01)），
 *                在 option_probe 里 **明确拒绝 class 8 的接口**：
 *                  if (iface_desc->bInterfaceClass == USB_CLASS_MASS_STORAGE)
 *                          return -ENODEV;          // "Never bind to the CD-Rom emulation interface"
 *
 * 三条可以直接照搬的原则：
 *
 *   ① 只管大容量存储接口。AT 接口（ff/01/0x）永远不碰 —— Linux 用 option_probe
 *      的 class 8 判断做到，我们以前只按 VID/PID 过滤，1505 下的 ff/01 接口也会被
 *      扫进来，对着 AT 端点重放 SCSI 报文。1.7.0 补上 class 8 过滤。
 *
 *   ② 发一次就够，不刷屏。usb_modeswitch 每个配置只发一次报文；报文是合法 CBW，
 *      连发只会让固件在"切换中"再收一次，属于纯干扰。1.6.0 的"每秒重发、永不停止"
 *      是错的，1.7.0 改成 2s/4s/8s 三次快重试 + 之后 30s 慢重试。
 *
 *   ③ 发完立刻放开接口。Linux 发完就 release_interface，让设备能重枚举。
 *      我们以前 hold 3 秒再放，把重枚举堵在半路。
 *
 * macOS 上缺了"解绑别的驱动"这一步（没有 usb_driver_release_interface 的等价物），
 * 所以只能在 IOKit 的匹配阶段抢先：
 *
 *   · Info.plist 里 personality 的 IOProbeScore = 1000000，高于苹果
 *     IOUSBMassStorageDriver 的 50000 —— 等价于 Linux 的"不绑定 usb-storage"，
 *     接口从枚举那一瞬间就归我们，不需要任何抢占动作。
 *   · 万一还是被抢了（probe 输了），才退回 kIOServiceSeize / terminate 占用者，
 *     这两条是 macOS 独有的兜底，不是主路径。
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * 二、版本演进（每个版本都是被实测推翻后才改的）
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *   1.2.0  _kmod_info 的 start/stop 传 0 → 内核报 NULL module start pointer，
 *          整个载入被回滚；但 kmutil showloaded 照样列着它（假象）。
 *   1.3.0  start/stop 换成真函数 → kmod start 成功，E398Loader 实例出现。
 *   1.4.0  personality 抢不到接口，改成 E398Loader 挂 IOResources 起线程扫描。
 *          但线程只跑 30 轮就退出。
 *   1.5.0  拔插后设备会回到 1505，所以改成永久监视；接口被占时先 seize 再 terminate。
 *   1.6.0  修 1.5.0 的三个硬伤：sendCount 满 6 次后永久放弃且不打日志；
 *          发完一直 hold 接口堵住重枚举；terminate(Synchronous) 在内核线程里阻塞。
 *
 *   1.7.0  长期使用后仍会「断联、断了切不上」，逐条查下来是四个结构性问题：
 *
 *          (a) 【两条路径互抢同一个会话】── 最严重
 *              E398Switcher（personality）和 E398Loader（常驻线程）各自持有一份
 *              E398State，各自对同一个 IOUSBHostInterface 做 open / seize。
 *              personality 线程每次 open 失败都会拿 kIOServiceSeize 去抢，而抢的
 *              对象正是自己的 loader —— 现场 ioreg 里 UsbExclusiveOwner = "E398Loader"
 *              就是铁证。两个自己人每 1~3 秒互相踢一次会话，USB 栈被搅得没法稳定。
 *              → 设全局 gActiveSwitchers：personality 一旦挂上接口，loader 立刻停手，
 *                只保留心跳；personality 没挂上（probe 输了）loader 才接管。
 *                并且在 open 失败时先看 UsbExclusiveOwner 是不是"自己人"，
 *                是就退避，绝不对自己 seize。
 *
 *          (b) 【stop() 释放了工作线程还在用的指针】
 *              E398Switcher::stop() 里 fInterface->release()，而 workerMain 可能
 *              正在用它 open/close。拔线时 provider 被 terminate 就会触发 —— 是
 *              use-after-free，能直接 panic。
 *              → provider 指针只由工作线程持有和释放，stop() 只置 fStop。
 *
 *          (c) 【报文重发没有节制】
 *              设备卡在 1505 时每 ~4 秒发一次，发一整晚 = 上万次 CBW。
 *              固件会在切换过程中反复收到新的 SCSI 命令，反而更容易挂死。
 *              → 快重试 3 次（2/4/8 秒）+ 之后 30 秒一次，且每次都记日志。
 *
 *          (d) 【异步传输的内存生命周期】
 *              超时后 pipe->io 的回调仍可能到达，若此时已 IOFree 就是写已释放内存。
 *              → 超时后置 abandoned，内存交给回调释放；回调先读 abandoned 再写 done，
 *                两边都不会释放两次。
 *
 *          另外：报文改成"提交→等完成→立刻 close"，不再 hold 三秒；
 *          诊断计数发布到 IORegistry（ioreg -r -n E398Loader 可读），
 *          以后排查不必只靠翻内核日志。
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
#include <libkern/OSAtomic.h>
#include <kern/thread.h>
#include <mach/kmod.h>
#include <string.h>

/*
 * IOUSBHostInterface / IOUSBHostPipe 自 10.15 起被标记 deprecated
 * （"Use USBDriverKit"）。kext 里没有替代品：DriverKit 需要 Apple 签发的
 * entitlements + provisioning，本地 ad-hoc 签名的 kext 用不了。
 * Intel + SIP 关闭的环境下这套 API 仍然可用，所以这里整体屏蔽弃用告警，
 * 其余告警（未使用变量、类型不匹配等）继续生效。
 */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

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
KMOD_EXPLICIT_DECL(E398Switcher, "1.7.0", E398KmodStart, E398KmodStop);
}

/* usb_modeswitch.d/12d1:1505 的 MessageContent，逐字节一致，共 31 字节。
 * 来源：usb-modeswitch-data 里 12d1:1505 的
 *   MessageContent="55534243123456780000000000000011062000000100000000000000000000"
 *   MessageEndpoint=0x01
 * 它是一条合法 CBW，但命令码 0x11 是华为私有的"切到 modem 模式"，
 * 无法让存储栈代为生成，只能原样重放。
 * 设备通常不回 CSW（收到就切走），所以返回 STALL/超时都算正常。 */
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

#define E398_IO_TIMEOUT_MS 2000   /* 单次 bulk 传输的硬超时 */
#define E398_BULK_WAIT_MS  2500   /* 我们自己等回调的上限（> 上面的 IO 超时） */
#define E398_BURST_MAX     3      /* 快重试次数，之后降到慢速 */
#define E398_SLOW_RETRY_MS 30000  /* 慢速重试间隔 */
#define E398_HEARTBEAT_S   60     /* 心跳间隔 */

/* ══════════════════════════════════════════════════════════════════════════
 * 全局状态：两条路径共享，用来保证"同一时刻只有一个人在管接口"
 * ══════════════════════════════════════════════════════════════════════════ */

static volatile SInt32 gActiveSwitchers = 0;  /* 已挂上 1505 接口的 personality 实例数 */
static volatile SInt32 gAttempts        = 0;  /* 累计下发报文次数 */
static volatile SInt32 gTimeouts        = 0;  /* 传输超时次数 */
static volatile SInt32 gLastStatus      = 0;  /* 最近一次 bulk 传输的返回码 */

/* 内核里不保证有 strstr，自己写一个子串判断，避免链接期缺符号。 */
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

/* 占用者是不是我们自己。用于避免"自己 seize 自己"这种自杀式抢占。 */
static bool e398IsOurs(const char *owner)
{
    return e398StrContains(owner, "E398Switcher") || e398StrContains(owner, "E398Loader");
}

/* 把 IOKit 返回码翻译成人话，日志里不要再出现光秃秃的 0xe00002c5 */
static const char *e398Reason(IOReturn kr)
{
    switch (kr) {
    case kIOReturnSuccess:         return "成功";
    case kIOReturnExclusiveAccess: return "接口已被独占";
    case kIOReturnNotOpen:         return "会话未建立";
    case kIOReturnNotAttached:     return "设备已不在（拔出或重枚举中）";
    case kIOReturnNoDevice:        return "设备不存在";
    case kIOReturnBusy:            return "设备忙";
    case kIOReturnTimeout:         return "超时";
    case kIOReturnNotResponding:   return "设备无响应";
    case kIOReturnUnsupported:     return "设备不支持该请求";
    case kIOReturnNotFound:        return "没找到 bulk OUT 端点";
    case kIOReturnNoMemory:        return "内存不足";
    case kIOReturnOverrun:         return "数据溢出";
    default:                       return "其它错误";
    }
}

/* 可被打断的睡眠：每 100ms 看一次 fStop，stop() 之后线程最多 100ms 就退出。
 * 不用 IOSleep(30000) 一口气睡过去，否则 kext 卸载/关机要等半分钟。 */
static void e398SleepMs(volatile bool *stopFlag, uint32_t ms)
{
    for (uint32_t slept = 0; slept < ms; slept += 100) {
        if (stopFlag && *stopFlag) {
            return;
        }
        IOSleep(100);
    }
}

/* 每一"代"（一次 USB 枚举）的状态。设备重枚举时整体清零，天然不会"永久放弃"。 */
struct E398State {
    IOService *client;      /* open/close 用谁的名义（驱动自己） */
    int        attempts;    /* 本代累计下发次数 */
    int        burst;       /* 连续快重试计数 */
    int        openFails;   /* 连续 open 失败次数（用于降噪日志） */
    int        ownWaits;    /* 因为"自己人占着"退避的次数 */
    int        timeouts;    /* 本代拿不到完成回调的次数 */
    bool       seizeTried;  /* 本代是否已经处理过外部占用者 */
};

/* ══════════════════════════════════════════════════════════════════════════
 * 报文发送：提交 → 等完成 → 释放
 * ══════════════════════════════════════════════════════════════════════════ */

struct E398Xfer {
    IOUSBHostCompletion      comp;
    IOBufferMemoryDescriptor *buf;
    volatile bool            done;       /* 回调已跑完 */
    volatile bool            abandoned;  /* 提交方已放弃等待，内存归回调 */
    IOReturn                 status;
    uint32_t                 bytes;
};

/* 完成回调只做"写结果 + 必要时释放"，不碰任何可能已经消失的对象。
 * 顺序很重要：先读 abandoned，再写 done。这样提交方看到 done 时，
 * 回调已经不会再访问这块内存了。 */
static void e398PacketDone(void *owner, void *parameter,
                           IOReturn status, uint32_t bytesTransferred)
{
    (void)owner;
    E398Xfer *x = (E398Xfer *)parameter;
    if (!x) {
        return;
    }

    bool mine = x->abandoned;

    x->status = status;
    x->bytes  = bytesTransferred;
    __sync_synchronize();   /* 保证 done 置位时 status/bytes 已经落地 */
    x->done = true;

    if (mine) {
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
            return pipe;
        }
    }
    return NULL;
}

/* 同步发一次报文（内部异步提交 + 轮询等完成）。
 * 返回值是设备/传输的真实状态，调用方据此决定要不要重试。 */
static IOReturn e398SendSwitchSync(IOUSBHostInterface *intf, E398State *st)
{
    if (st->timeouts >= 4) {
        /* 本代已经连续 4 次拿不到完成回调：设备多半半死不活，不再制造新的孤儿内存。
         * 注意这是"本代"计数 —— 设备重枚举（新一代）会清零，不会变成永久放弃。 */
        return kIOReturnNotResponding;
    }

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
        /* 提交失败 = 回调不会来，内存由我们自己收 */
        if (x->buf) {
            x->buf->release();
        }
        IOFree(x, sizeof(E398Xfer));
        return kr;
    }

    for (uint32_t waited = 0; waited < E398_BULK_WAIT_MS && !x->done; waited += 10) {
        IOSleep(10);
    }

    if (!x->done) {
        /* 传输还没回来。绝不能再碰 x：置 abandoned 后，谁最后到谁释放。
         * 这里必须先置位、然后立刻返回 —— 置位之后的任何一次读都可能是已释放内存。 */
        x->abandoned = true;
        st->timeouts++;
        __sync_fetch_and_add(&gTimeouts, 1);
        IOLog("E398Switcher: 报文 %dms 未完成（本代第 %d 次超时），内存交给回调回收\n",
              E398_BULK_WAIT_MS, st->timeouts);
        return kIOReturnTimeout;
    }

    IOReturn result = x->status;
    if (x->buf) {
        x->buf->release();
    }
    IOFree(x, sizeof(E398Xfer));
    return result;
}

/* ══════════════════════════════════════════════════════════════════════════
 * 单个接口的切换逻辑
 * ══════════════════════════════════════════════════════════════════════════ */

/* 只认 1505 + 大容量存储接口。
 * Linux 的 option_probe 里那句 "Never bind to the CD-Rom emulation interface"
 * 就是这道闸：1505 下面还有 ff/01/0x 的 AT 接口，对它们重放 SCSI 报文是纯捣乱。 */
static bool e398IsTarget(IOUSBHostInterface *intf)
{
    if (!intf || intf->isInactive()) {
        /* 已经失效的对象（上一次枚举的残留）绝对不能碰：
         * 对它 open 只会一直返回 kIOReturnNotAttached，而且会让扫描每轮都把它
         * 当成"1505 还在"，于是 found 永远 > 0、状态永远不重置。
         * 本机实测就有这么一个开机 17 天的残留对象，正是这条判断缺失造成的。 */
        return false;
    }

    OSNumber *vid = OSDynamicCast(OSNumber, intf->getProperty("idVendor"));
    OSNumber *pid = OSDynamicCast(OSNumber, intf->getProperty("idProduct"));
    OSNumber *cls = OSDynamicCast(OSNumber, intf->getProperty("bInterfaceClass"));

    if (!vid || !pid) {
        return false;
    }
    if (vid->unsigned32BitValue() != 0x12d1 || pid->unsigned32BitValue() != 0x1505) {
        return false;
    }
    if (cls && cls->unsigned32BitValue() != 8) {
        return false;   /* 不是大容量存储接口：不碰 */
    }
    return true;
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

/* 尝试切换一次（内部自带 open / 抢占 / 发送 / 关闭）。
 * 返回值 = 建议这次之后等多久再试（毫秒）。 */
static uint32_t e398TrySwitch(IOUSBHostInterface *intf, E398State *st, const char *who)
{
    IOReturn kr = intf->open(st->client, 0, NULL);
    bool opened = (kr == kIOReturnSuccess);

    if (!opened) {
        OSString *owner = OSDynamicCast(OSString, intf->getProperty("UsbExclusiveOwner"));
        const char *o = owner ? owner->getCStringNoCopy() : NULL;

        if (o && e398IsOurs(o)) {
            /* 自己人还占着这个会话：等它放手。
             * 1.5.0/1.6.0 在这里直接 seize —— 抢的正是另一个自己的实例。
             * 现场的 UsbExclusiveOwner="E398Loader" 就是这么来的，
             * 两个路径每 1~3 秒互相踢一次，USB 栈根本没法稳定。 */
            if (st->ownWaits++ < 3) {
                IOLog("E398Switcher: 接口被本驱动的 %s 占着，等它放手（不抢自己的会话）\n", o);
            }
            return 500;
        }

        if (!o) {
            /* 没有占用者属性却打不开：设备正在复位/重枚举的概率最大 */
            if (st->openFails++ < 3) {
                IOLog("E398Switcher: open 失败 0x%08x（%s），无占用者属性，等设备稳定\n",
                      kr, e398Reason(kr));
            }
            return 1000;
        }

        if (st->seizeTried) {
            /* 已经动过手（seize 或 terminate），给对方时间退场，不要连环抢 */
            return 1000;
        }
        st->seizeTried = true;

        IOLog("E398Switcher: 接口被外部驱动 %s 独占（0x%08x），尝试 seize\n",
              o, kr);
        IOReturn sr = intf->open(st->client, kIOServiceSeize, NULL);
        if (sr == kIOReturnSuccess) {
            IOLog("E398Switcher: kIOServiceSeize 成功，已接管接口\n");
            opened = true;
        } else {
            /* 等价于 Linux 的 unbind：把占用者踢掉。异步，绝不 Synchronous ——
             * 它的等待依赖 USB workloop，workloop 被复位流程占住时线程会永久挂死。 */
            IOService *blocker = e398FindBlocker(intf);
            if (blocker) {
                const char *cls = blocker->getMetaClass()->getClassName();
                IOLog("E398Switcher: seize 失败（0x%08x），异步终止占用者 %s\n",
                      sr, cls ? cls : "?");
                blocker->terminate(0);
                blocker->release();
            } else {
                IOLog("E398Switcher: seize 失败（0x%08x），且子节点里没有 MassStorage 服务\n",
                      sr);
            }
            return 1000;
        }
    }

    /* 到这里接口已经归我们独占（open 成功或 seize 成功） */
    if (st->openFails > 0) {
        IOLog("E398Switcher: 接口已就绪（此前失败 %d 次）\n", st->openFails);
        st->openFails = 0;
    }

    IOReturn io = e398SendSwitchSync(intf, st);

    /* 必须 close —— 哪怕接口已经 inactive。
     *
     * open() 建立的是 IOKit 的会话：open count + client 引用。设备切模式会立刻重枚举，
     * 我们常常在这一刻还没 close，如果因为 "isInactive 就别动" 而跳过，这个会话
     * 就永远不会关闭。后果（本机实测）：对象带着 busy 1 永久留在 IORegistry 里，
     *   IOUSBHostInterface@0 <..., !registered, !matched, inactive, busy 1 (1535389 ms)>"
     *   "idProduct" = 5381   "UsbExclusiveOwner" = "E398Loader"
     * 开机 17 天没释放。每拔插一次就多留一个，属于内核对象泄漏；
     * 而且设备的 USB 会话记账一直挂着一个未关闭的 client，对稳定性只有坏处。
     *
     * Linux 那边是 usb_driver_release_interface()，语义就是"无论设备什么状态都解绑"。
     * close() 本身是本地状态操作（减 open count、唤醒等待者），不涉及设备往返，
     * 不会像 terminate(Synchronous) 那样阻塞。 */
    intf->close(st->client);

    st->attempts++;
    st->burst++;
    __sync_fetch_and_add(&gAttempts, 1);
    gLastStatus = io;

    if (io == kIOReturnSuccess) {
        IOLog("E398Switcher: 第 %d 次下发 31 字节切换报文（%s）=> 成功，等设备重枚举为 12d1:1506\n",
              st->attempts, who);
    } else {
        /* STALL / 超时都正常：设备收到报文就切走，不回应 CSW */
        IOLog("E398Switcher: 第 %d 次下发（%s）返回 0x%08x（%s）\n",
              st->attempts, who, io, e398Reason(io));
    }

    /* 退避：连续快重试用的报文很少，但每次都可能真的生效 ——
     * 又不能在没生效时无节制地刷。2s / 4s / 8s 之后就每 30 秒一次。 */
    if (st->burst <= E398_BURST_MAX) {
        return (uint32_t)(1000u << st->burst);
    }
    if (st->burst == E398_BURST_MAX + 1) {
        IOLog("E398Switcher: 连发 %d 次仍未切换，转为每 %d 秒重试一次（不再高频重发）\n",
              st->burst, E398_SLOW_RETRY_MS / 1000);
    }
    return E398_SLOW_RETRY_MS;
}

/* ══════════════════════════════════════════════════════════════════════════
 * E398Switcher —— personality 主体。接口一出现就归它管，不需要扫描
 * ══════════════════════════════════════════════════════════════════════════ */

class E398Switcher : public IOService
{
    OSDeclareDefaultStructors(E398Switcher)

private:
    /* 只由工作线程读、释放；stop() 绝不碰，避免 UAF */
    IOUSBHostInterface *fProvider;
    E398State           fState;
    volatile bool       fStop;
    bool                fCounted;   /* 是否已计入 gActiveSwitchers */

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

    /* 离开 workloop 再 open —— 否则 commandSleep 会自己等自己。
     * 等 500ms 是给 USB 枚举收尾留的余量。 */
    IOSleep(500);

    while (!self->fStop && self->fProvider && !self->fProvider->isInactive()) {
        uint32_t waitMs = e398TrySwitch(self->fProvider, &self->fState, "personality");
        if (waitMs < 100) {
            waitMs = 100;
        }
        e398SleepMs(&self->fStop, waitMs);
    }

    if (self->fProvider && self->fProvider->isInactive()) {
        IOLog("E398Switcher: 接口已失效（设备切换/拔出成功），本次切换结束\n");
    }

    if (self->fProvider) {
        self->fProvider->release();
        self->fProvider = NULL;
    }
    self->release();   /* 对应 start() 里为线程做的 retain */
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

    memset(&fState, 0, sizeof(fState));
    fState.client = this;
    fStop   = false;
    fCounted = true;
    __sync_fetch_and_add(&gActiveSwitchers, 1);

    intf->retain();
    fProvider = intf;

    IOLog("E398Switcher: personality 接管 12d1:1505 接口（probe score 赢了 mass-storage），"
          "交给后台线程\n");

    retain();
    thread_t th = NULL;
    if (kernel_thread_start(&E398Switcher::workerMain, this, &th) != KERN_SUCCESS) {
        release();
        fProvider = NULL;
        intf->release();
        __sync_fetch_and_sub(&gActiveSwitchers, 1);
        fCounted = false;
        IOLog("E398Switcher: personality 线程创建失败\n");
        return false;
    }
    thread_deallocate(th);
    return true;
}

void E398Switcher::stop(IOService *provider)
{
    /* 只置标志，不释放 fProvider：工作线程可能正拿它 open/close。
     * 1.6.0 在这里 release()，拔线时 provider 被 terminate 会踩到已释放内存。 */
    fStop = true;

    if (fCounted) {
        fCounted = false;
        __sync_fetch_and_sub(&gActiveSwitchers, 1);
    }
    IOService::stop(provider);
}

/* ══════════════════════════════════════════════════════════════════════════
 * E398Loader —— 挂在 IOResources 上，保证 kext 一定加载；兜底 + 心跳
 * ══════════════════════════════════════════════════════════════════════════ */

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

    IOLog("E398Switcher: kext 已加载（loader 挂钩生效），监视 12d1:1505\n");

    /* 线程结束时 release 掉这里的 retain，保证 this 在线程存活期间有效 */
    retain();
    thread_t th = NULL;
    if (kernel_thread_start(&E398Loader::threadMain, this, &th) != KERN_SUCCESS) {
        release();
        IOLog("E398Switcher: 创建监视线程失败（personality 仍然会工作）\n");
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

/* 扫一遍所有 IOUSBHostInterface，遇到 1505 的大容量存储接口就处理。
 * *waitMs 带回建议的下次等待时间。 */
static int e398OneRound(E398State *st, uint32_t *waitMs)
{
    OSDictionary *match = IOService::serviceMatching("IOUSBHostInterface");
    if (!match) {
        return 0;
    }
    OSIterator *iter = IOService::getMatchingServices(match);
    match->release();
    if (!iter) {
        return 0;
    }

    int seen = 0;
    IOService *svc = NULL;
    while ((svc = (IOService *)iter->getNextObject()) != NULL) {
        IOUSBHostInterface *intf = OSDynamicCast(IOUSBHostInterface, svc);
        if (!intf || !e398IsTarget(intf)) {
            continue;
        }
        seen++;
        /* getNextObject 下次调用时会释放上一个对象，先自己 retain */
        intf->retain();
        uint32_t w = e398TrySwitch(intf, st, "loader");
        if (waitMs && w > *waitMs) {
            *waitMs = w;
        }
        intf->release();
    }
    iter->release();
    return seen;
}

void E398Loader::run(void)
{
    int      sec       = 0;
    int      lastBeat  = 0;
    int      lastFound = -1;      /* -1 = 还没扫过；用来抓「1505 重新出现」这个边沿 */
    uint32_t nextWait  = 1000;    /* 下一轮之前等多久（由 e398TrySwitch 的退避决定） */

    for (;;) {
        e398SleepMs(&fStop, nextWait);
        if (fStop) {
            break;
        }
        sec += (int)(nextWait / 1000);
        if (sec <= 0) {
            sec = 1;
        }

        /* 心跳：判断「线程活着但切不动」还是「线程根本没在跑」的唯一依据。
         * 同时把计数发布到 IORegistry，排查时不用只靠翻日志：
         *   ioreg -r -n E398Loader -w0 | grep E398 */
        if (sec - lastBeat >= E398_HEARTBEAT_S) {
            lastBeat = sec;
            int found = lastFound < 0 ? 0 : lastFound;
            IOLog("E398Switcher: 心跳 %ds —— 看到 1505 接口 %d 个，personality 在管 %d 个，"
                  "累计下发 %d 次，超时 %d 次，最近返回 0x%08x\n",
                  sec, found, (int)gActiveSwitchers,
                  (int)gAttempts, (int)gTimeouts, (unsigned)gLastStatus);

            setProperty("E398ActiveSwitchers", (unsigned long long)gActiveSwitchers, 32);
            setProperty("E398Attempts",        (unsigned long long)gAttempts, 32);
            setProperty("E398Timeouts",        (unsigned long long)gTimeouts, 32);
            setProperty("E398LastStatus",      (unsigned long long)(UInt32)gLastStatus, 32);
            setProperty("E398Found1505",       (unsigned long long)found, 32);
        }

        /* personality 已经在管同一个接口时，这里只做心跳，绝不插手。
         * 这是 1.7.0 最关键的一条：以前两条路径各自 open/seize，互相踢会话。 */
        if (gActiveSwitchers > 0) {
            nextWait = 1000;
            continue;
        }

        uint32_t waitMs = 1000;
        int found = e398OneRound(&fState, &waitMs);

        /* 边沿记录：1505 重新出现 = 设备刚经历过一次 USB 复位/重插。
         * 这条日志直接对得上「断联」的时间点，排查时先找它。 */
        if (found > 0 && lastFound <= 0) {
            IOLog("E398Switcher: 检测到 12d1:1505（设备刚复位或刚插入），开始切换\n");
        }
        lastFound = found;

        if (found == 0) {
            /* 设备已切走或还没插：把本代计数清掉，下一次插上是全新的一代 */
            memset(&fState, 0, sizeof(fState));
            fState.client = this;
            nextWait = 1000;
            if (sec - lastBeat >= 300) {
                IOLog("E398Switcher: 监视中（已运行 %d 秒，当前没有 12d1:1505）\n", sec);
                lastBeat = sec;   /* 借用同一个计时器，避免重复刷 */
            }
        } else {
            /* 有设备时用 e398TrySwitch 给的退避（2s / 4s / 8s / 30s），
             * 但不低于 1 秒 —— 否则会把 CPU 打满。 */
            nextWait = waitMs < 1000 ? 1000 : waitMs;
        }
    }

    IOLog("E398Switcher: 监视线程退出\n");
}
