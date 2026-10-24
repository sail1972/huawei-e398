# 原理与逆向记录

这份文档解释"为什么代码必须这么写"。每一条都是被实测推翻后才定下来的，
包括所有失败的尝试 —— 想改代码之前先读完，能省掉几天。

---

## 1. 设备的两副面孔

| | `12d1:1505`（零 CD / 装机模式） | `12d1:1506`（调制解调器模式） |
|---|---|---|
| 配置数 | 1 | 1 |
| 接口 | 只有 1 个：`08/06/0x50`（mass storage）+ CD-ROM | 3 个：`ff/01/01`、`ff/01/02`、`08/06/0x50` |
| 端点 | bulk `0x81`/`0x01` | if0：AT 口，`ATD` 之后变成 PPP 数据管道<br>if1：PCUI，持续上报 `^RSSI`<br>if5：CD-ROM（保持不变） |
| 系统里是什么 | 一个只读 U 盘 | 无驱动（厂商接口不是标准类） |

关键点：`1506` 里**没有** ACM（`02/06/00`）也没有 ECM/CDC（`0a/00/00`）接口。
所以 macOS 上不会凭空出现串口或网卡 —— 这也是华为 2013 年的官方驱动在这里
救不回来的根本原因（它要的是老 IOUSBFamily 的 serial 类，macOS 11 起就没了）。

---

## 2. 唯一的硬约束：切换必须在内核里做

```
要切模式 → 必须往 bulk OUT 0x01 写 31 字节报文
        → 必须独占 IOUSBHostInterface
        → 苹果的 IOUSBMassStorageInterfaceNub 已经 open() 了它
        → 只能在内核里用更高 IOProbeScore 抢先 / 或者把占用者赶走
        → 需要一个自建 kext 进内核集合
```

`IOUSBHostInterface.h` 的原话：*Only one service may open a session at a time*。
用户态 `USBInterfaceOpenSeize` 永远返回 `0xe00002c5`（独占冲突），
连 `diskutil eject` 之后也一样：USB 重枚举会让 mass-storage 驱动重新匹配并再次 open。

---

## 3. 那 31 字节到底是什么

与 `usb_modeswitch.d/12d1:1505` 的 `MessageContent` 逐字节一致：

```
55 53 42 43  12 34 56 78  00 00 00 00  00  00  00  11 06 20 00 00 01  00×10
└─ "USBC" ─┘ └── tag ───┘ └─ len=0 ─┘ flg lun cblen └── 非标准 CB ──┘ └─ 填充 ─┘
```

它长得像 UFI/CBW（Command Block Wrapper），但**不是合法 SCSI 命令**：
`cbLength = 0`，后面的 `11 06 20 00 00 01` 也不是任何 SCSI opcode。
它只是华为固件认的一个"暗号"。

这两个事实很重要：

- 无法让系统的存储栈"代为生成"这条命令（所以自定义 CDB / SCSI Task 路线必败）；
- 设备回 STALL 也算成功 —— Linux 的 usb_modeswitch 发完同样不管应答。
  本项目实测：发完约 1 秒后设备重枚举，PID 变 `1506`。

---

## 4. kext 的设计（v1.7.0）

### 三层职责，各管一段

| 层 | 谁 | 作用 |
|---|---|---|
| 加载锚点 | `E398Loader`（personality 挂 `IOResources`） | 保证 kext 在 USB 枚举**之前**就进内核 |
| 主路径 | `E398Switcher`（personality 挂 `IOUSBHostInterface`，score 1000000） | 接口出现时归它，直接 open → 发报文，不扫描 |
| 兜底 | `E398Loader` 的线程 | 仅当 `gActiveSwitchers == 0`（主体没匹配上）才扫描接管；平时只发心跳 |

**实测：哪条路径在真正跑**（本机 macOS 15.8.1）

```
ioreg -c IOUSBHostInterface -l | grep -A2 UsbExclusiveOwner
  "UsbExclusiveOwner" = "E398Loader"      ← 实际干活的是兜底路径
ioreg -c E398Switcher | wc -l  → 0        ← personality 一个实例都没有
```

原因：**开机时设备已经插着**。USB 枚举发生在 kext 进内核之前，那时匹配表里没有我们，
`IOUSBMassStorageDriver`（score 50000）先把接口绑走；IOService 的匹配是一次性的，
我们后来再注册 personality 也不会重新匹配已有服务。所以：

| 场景 | 谁在干活 |
|---|---|
| 开机器时 modem 已插 | mass-storage 先绑定 → **loader 兜底路径** |
| 开机后插 / 拔插 modem | kext 已在内存里，1000000 分胜出 → **personality 主路径** |

这也是 1.7.0 保留两层的原因：两条路必须都能跑通，而且**同一时刻只能有一个在跑**
（`gActiveSwitchers` 互斥 + `e398IsOurs()` 不抢自己）。两者的切换逻辑是同一个函数
`e398TrySwitch()`，所以修一处两边都受益。

### 1.6.0 的五个问题（1.7.0 全部修掉）

**① 两条路径互抢同一个会话**

`E398Switcher` 和 `E398Loader` 各自持有一份 `E398State`，各自对同一个
`IOUSBHostInterface` 做 `open` / `kIOServiceSeize`。personality 每次 open 失败都会
seize —— 抢的对象可能是自己的 loader。热插场景下两个"自己人"会互相踢会话，
USB 栈被搅得没法稳定。
1.7.0：全局 `gActiveSwitchers` 互斥；且 open 失败时先看 `UsbExclusiveOwner` 是不是
自己（`e398IsOurs()`），是就退避 500ms，**绝不对自己 seize**。

**② `open()` 之后 close 被跳过 → 内核对象泄漏（实测 17 天没释放）**

1.6.0 在接口已经 `inactive` 时跳过 `close()`，理由是"对失效对象 close 没意义"。
实际上 `open()` 建立的是 IOKit 会话（open count + client 引用），不 close 就永远不关。
本机现场：

```
IOUSBHostInterface@0  <class IOUSBHostInterface, !registered, !matched, inactive,
                       busy 1 (1535389 ms), retain 6>
  "idProduct"       = 5381            ← 1505 时代的对象，早就该消失
  "UsbExclusiveOwner" = "E398Loader"
```

开机 17 天、`busy 1` 一直挂着。每拔插一次就多留一个，而且设备的 USB 会话记账里
始终有个未关闭的 client。Linux 对应的是 `usb_driver_release_interface()`，
语义就是"无论设备什么状态都解绑"。

更麻烦的是连带效应：这个残留对象的 PID 还是 5381、class 还是 8，
`e398IsTarget()` 会把**每一次扫描**都判定成"1505 还在"，于是
`found` 永远大于 0、状态永远不重置、每秒对它 `open()` 一次（必然失败）——
既刷日志又让"监视中"永远不出现。

1.7.0 两个修法：
- **无条件 `close()`**。`close()` 是本地状态操作（减 open count、唤醒等待者），
  不涉及设备往返，不会像 `terminate(Synchronous)` 那样阻塞。
- `e398IsTarget()` **先看 `isInactive()`**，失效对象直接跳过。

**③ `stop()` 释放了工作线程还在用的指针**

```cpp
void E398Switcher::stop(IOService *provider) {
    fInterface->release();      // ← 线程可能正在 open/close 它
    fInterface = NULL;
}
```

拔线时 provider 被 `terminate()` 就会走到这里 —— use-after-free，能直接 panic。
1.7.0：`fProvider` 只由工作线程持有和释放，`stop()` 只置 `fStop`。

**④ 报文重发没有节制**

设备卡在 1505 时每 ~4 秒发一次 CBW，一整晚就是上万次。固件在"切换中"反复收到新的
SCSI 命令，反而更容易挂死。Linux 的 usb_modeswitch 是**每个配置只发一次**。
1.7.0：2s / 4s / 8s 三次快重试，之后固定 30 秒一次，每次都有日志。

**⑤ 异步传输的内存生命周期**

超时后 `pipe->io()` 的回调仍可能到达，此时若已 `IOFree` 就是写已释放内存。
1.7.0 用 `abandoned` 标志把释放责任交给回调，且回调**先读 abandoned 再写 done**，
两边都不会释放两次。

### 主流程（1.7.0）

```
personality start()  →  gActiveSwitchers++  →  起内核线程（500ms 后开始）
  └─ 循环：接口还没失效？
       ├─ open(this, 0, NULL)
       │    ├─ 成功 → 发报文
       │    ├─ 失败且占用者是自己 → 退避 500ms（不抢）
       │    ├─ 失败且有外部占用者 → seize 一次；不行就异步 terminate 一次
       │    └─ 失败且无占用者属性 → 退避 1s（设备在复位）
       ├─ 发报文：异步提交 → 每 10ms 查一次 done → 最多等 2.5s
       ├─ 立刻 close()（让设备能重枚举，对应 Linux 的 release_interface）
       └─ 退避：2s / 4s / 8s / 之后 30s
  └─ 接口失效 or fStop → 释放 fProvider，线程退出
```

### 只碰大容量存储接口

`e398IsTarget()` 除了 VID/PID，还要求 `bInterfaceClass == 8`。
这条直接对应 Linux `option_probe()` 里的：

```c
/* Never bind to the CD-Rom emulation interface */
if (iface_desc->bInterfaceClass == USB_CLASS_MASS_STORAGE)
        return -ENODEV;
```

1505 模式下除了虚拟光驱，还有 `ff/01/0x` 的 AT 接口（VID/PID 同样是 12d1:1505）。
只按 VID/PID 过滤会把 AT 接口也扫进来，对它的 bulk OUT 端点重放 SCSI 报文 —— 纯捣乱。

### 与 Linux 的完整对照

| 环节 | Linux | macOS / 本项目 | 说明 |
|---|---|---|---|
| 谁绑定存储接口 | `usb-storage`（会绑上） | 不绑：personality score 1000000 > 50000 | macOS 没有 `usb_driver_release_interface`，只能在匹配阶段抢 |
| 解绑占用者 | `usb_driver_release_interface()` | `open(kIOServiceSeize)` / `terminate()` | 仅当匹配输了才用，属兜底 |
| 发报文 | `usb_modeswitch` 写 `MessageEndpoint=0x01` | 描述符里找第一个 bulk OUT | 不硬编码端点号，实测同为 0x01 |
| 报文内容 | `55534243123456780000000000000011062000000100000000000000000000` | 逐字节相同（31 字节） | 已用脚本比对，完全一致 |
| 等结果 | `CheckSuccess=20` 轮询目标 PID | 监视 `IOUSBHostInterface::isInactive()` | 接口失效即切换成功 |
| 重试 | 每个配置一次，失败靠用户重插 | 3 次快重试 + 30s 慢重试 | 核内常驻，可以比用户态更主动，但绝不刷屏 |
| 绑定 modem 接口 | `option` 绑 `ff/01/01`、`ff/01/02` | 不碰（`bInterfaceClass == 8` 才处理） | 见 option.c:684-685 |
| 复位后重切 | `usb_reset_resume` → 重跑模式切换 | 常驻线程发现 1505 就再切 | 拔插必回 1505，所以必须常驻 |
| 电源管理 | `USB_QUIRK_*` / autosuspend 关闭 | 不做：PPP 有流量，设备不会空闲挂起 | 需要时再补 |

### 为什么必须另起线程

`start()` 运行在 USB 的 workloop 线程上，而 `IOUSBHostInterface::open()` 内部会
`commandSleep` 等 workloop 处理 —— **自己等自己，必死锁**。
内核线程不占 workloop，同步调用才安全。

### 为什么从 30 秒窗口改成永久监视

1.4.0 的线程只跑 30 轮（约 30 秒）就退出，理由是"开机时切一次就够了"。
但实测：**模式不存在固件里**，USB 断电就丢 —— 物理拔插后设备必回 `1505`，
重启反而不会（USB 没断电）。所以 30 秒窗口根本不够，v1.5.0 改成永久监视。

### 诊断计数发布到 IORegistry

每次心跳会把计数写进 `E398Loader` 的属性，排查时不必只靠翻日志：

```bash
ioreg -r -n E398Loader -w0 | grep E398
# "E398ActiveSwitchers"=1  "E398Attempts"=1  "E398Timeouts"=0  "E398LastStatus"=0
```

`E398ActiveSwitchers = 1` 说明 personality 已经接管；一直是 0 说明它在输，走的是兜底路径。

### 关于那 88 条编译告警（1.7.0 起为 0）

| 条数 | 告警 | 来源 | 处理 |
|---|---|---|---|
| 70 | `-Winconsistent-missing-override` | **SDK 头文件**（`IOUSBHostIOSource.h`、`IOUSBHostStream.h`、`IOUSBHostPipe.h`）：这些类里一部分虚函数标了 `override`、另一部分没标，clang 就对没标的那些报 | 编译加 `-Wno-inconsistent-missing-override`。不是我们的代码，改不了也不该改 |
| 18 | `-Wdeprecated-declarations` | **我们的代码**：`IOUSBHostInterface` / `IOUSBHostPipe` 自 10.15 起标为 deprecated（"Use USBDriverKit"） | 源码里 `#pragma clang diagnostic ignored "-Wdeprecated-declarations"` 局部屏蔽 |

**为什么不用 DriverKit 换掉这套 API**：DriverKit 的 USB 驱动需要 Apple 签发的
entitlement（`com.apple.developer.driverkit.transport.usb`）+ provisioning profile，
必须走开发者账号申请；本地 ad-hoc 签名的 kext 拿不到。而 kext 里的
`IOUSBHostInterface` 在 Intel + SIP 关闭 + AuxKC 的环境下仍然完全可用 ——
所以这里是"接受弃用"而不是"必须迁移"。

处理之后同时开了 `-Wall -Wextra`，**0 条告警**；构建脚本会把告警数打出来，
以后再冒出新的（比如类型不匹配、未使用变量）会立刻看见。

版本演进：

| 版本 | 改了什么 | 触发原因 |
|---|---|---|
| 1.2.0 | 首版，`KMOD_EXPLICIT_DECL(..., 0, 0)` | 内核 `NULL module start pointer` |
| 1.3.0 | start/stop 换成真函数 | kmod 层终于通过 |
| 1.4.0 | 放弃抢 personality，改 IOResources + 内核线程 | 1000000 分仍抢不过 50000（kext 还没进内核） |
| 1.5.0 | 永久监视 + `kIOServiceSeize` 优先、terminate 兜底 | 拔插后无人切换 |
| 1.6.0 | 去掉"发满 6 次就放弃"、发完放开接口、异步 terminate、60 秒心跳 | 断联后永久停在 1505 且无日志 |
| 1.7.0 | 两条路径互斥、修 `stop()` 的 UAF、无条件 `close()`（修掉 `busy 1` 卡 17 天的对象泄漏）、报文快慢两级退避、传输内存所有权；编译 0 warning | 长期使用后仍会断联；`ioreg` 里抓到未释放的 1505 接口对象 |


---

## 5. 内核集合（AuxKC）的六个坑

macOS 11 起第三方 kext 必须进 AuxKC 才能在开机时加载。这一路踩了六个坑：

1. **必须有 `_kmod_info`**。ld-1267（Xcode 16）不再为 `-kext` 自动合成，
   否则 `kexts must have a _kmod_info symbol`。
2. **start/stop 不能为 0**。为 0 时内核报 `NULL module start pointer` /
   `start failed (0xdc008007)`，**整个载入被回滚**（`__mod_init_func` 不跑、类不注册），
   但 `kmutil showloaded` 照样列出它 —— "已加载"是假象，只有 `ioreg` 里有没有
   服务实例才是判据。`tools/kmod-info.py` 就是查这个的。
3. **必须 `-z` 跳过 approval**。ad-hoc 签名过不了公证。
4. **依赖版本必须写盘上的值**：`com.apple.iokit.IOUSBHostFamily = 1.2`
   （盘上是 `CFBundleVersion 1.2` / `OSBundleCompatibleVersion 1.0.1`），
   写 `1.0.0` 就 `Code 71`。
5. **属主必须 root:wheel，连子目录也要**。否则报
   `No binaries or codeless kexts were provided`（真错在
   `Invalid ownership (501:0) should be (0:0)`）。
6. **没 KDK 时 `kmutil install` 静默跳过**（退出码 0，集合不变）。出路是
   `kmutil create -n aux -z --allow-missing-kdk -p <kext>`；
   合成一个假 KDK 没用（会校验元数据，`Code 34`）。

另外：`Code 28` 不是错误，是"已就位，等重启"。

---

## 6. 用户态：怎么把 if0 变成一条网线

`1506` 之后还得拨号。厂商接口没有驱动，但 macOS 允许用户态直接拿接口：

```c
IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, ...)
(*intf)->USBInterfaceOpenSeize(intf)     // 或 USBInterfaceOpen（没别人占时）
```

拿到 `IOUSBInterfaceInterface**` 之后就能 `ReadPipe/WritePipe` 收发 bulk。
为此有两个小工具：

- `tools/e398_at.c`：往 bulk OUT 发 AT 命令并读回。支持 `--cmd`（文本）、
  `--read`、`--hex`（看原始字节）、`--raw <hex>`（灌任意字节，逆向用）。
- `tools/e398_ppp.c`：把 if0 的 bulk 端点桥到 stdin/stdout，日志只写文件
  （stdout 被 pty 占用了）。另有 `--reenum` / `--hangup` / `--cat` 等实验开关。

### 为什么是 `pppd pty`

macOS 自带 `com.apple.nke.ppp`（v1.9，在内核里）和 `/usr/sbin/pppd`，
但 pppd 需要一个**串口设备**。我们没有串口，于是：

```
pppd  ──pty──▶  /tmp/e398-pty.sh  ──exec──▶  e398_ppp  ──bulk──▶  if0
```

`pppd pty <command>` 会用 `/bin/sh -c` 执行那条命令。**坑**：路径里的空格会被
shell 截断（现象是 `sh: /Users/…/华为: No such file or directory`，
pppd 报 `Connect script failed`，`status 0x7f` = 127）。
所以脚本生成一个无空格路径的包装脚本 `/tmp/e398-pty.sh`：

```sh
exec "/绝对路径/tools/e398_ppp" --iface 0 --log /tmp/e398-ppp.log
```

### 拨号序列（照 Linux 侧）

```
AT+CPIN?                必须 READY（否则直接退出，别等 75 秒）
AT+CSQ                  信号（-113 + 2*rssi dBm）
AT+CGREG?               等 0,1 / 0,5（最多 15 秒）
AT+CGATT?               为 0 则补 AT+CGATT=1（注册 ≠ 附着，这是成功率的漏点）
AT+CGACT=0,1            仅当 +CGACT: 1,1 时才发（清残留 PDP）
AT+CGDCONT=1,"IP",<apn>
ATD*99***1#
→ LCP → (EAP/CHAP 协商) → IPCP → ppp0
```

`pppd` 参数：`noauth noipdefault usepeerdns defaultroute ipcp-accept-local
ipcp-accept-remote noccp novj nopcomp noaccomp lcp-echo-interval 20
lcp-echo-failure 4`，MTU 1500（实测大包能过）。

顺带一个 macOS 独有的观察：对端在 LCP 里提 `<auth chap MD5>`，pppd 会
`ConfNak <auth eap>`，对端随后**干脆不提认证**，直接 ConfAck。属于华为侧的老实现。

---

## 7. 为什么 `--down` 之后 modem 拉不回命令态

`ATD*99#` 之后 if0 就变成纯数据管道，modem 固件不再解析 AT。
逐一实测（代码留在 `tools/e398_power.c` / `e398_at --raw`）：

| 手段 | 结果 |
|---|---|
| `+++`（静默 1 秒）+ `ATH` | 被忽略，仍在数据态 |
| `USBDeviceReEnumerate` | 返回 0x0 成功，设备仍 1506，数据照流（不断电 ≠ 重置固件） |
| `USBDeviceSuspend(1)` | `0xe00002eb` = kIOReturnBusy（if5 被存储驱动占着，拿不到独占） |
| `SetConfiguration(0)` → `(1)` | 都成功，数据照流 |
| 注入 LCP TermReq（自带 FCS-16） | 对端不回 TermAck，但 LCP 被关掉，对端开始重启 LCP |
| 注入 LCP EchoReq | **对端回 EchoRep**（`c0 21 0a`）→ 管道通、对端活着 |
| 注入 LCP ConfReq（MRU + magic） | **对端直接 ConfAck** → 会话可以原地复用 |

所以只有**拔插断电**真的拆 PDP。但不用拔 —— 有两条更好的路：

### 复用旧会话

既然对端一直在发 `LCP ConfReq` 等应答，新的 pppd **不用发 ATD**，
直接在这条还活着的管道上重开 LCP/IPCP 就能通（实测 2~3 秒）。
发了 ATD 反而会被运营商 `NO CARRIER` 顶回来。

`5-ppp-dial.sh` 的判断逻辑（用 `--cmd AT --hex` 的输出）：

| if0 上的字节 | 判定 | 走哪条路 |
|---|---|---|
| 有 `4f 4b`（`OK`） | 命令态 | 正常 `ATD` 拨号 |
| 有 `7e ff` / `7e c0 21` | 数据态 | **复用**：跳过 ATD/chat，pppd 不加 `connect` |
| 都没有 | 卡死 | 提示拔插 |

### 等它自己死

没人应答对端的 LCP，它就会一路重启（id 从 `0x05` 涨到 `0x19`，每次 30~50 秒），
最后放弃并拆掉 PDP —— 实测 `AT+CGACT?` 从 `1,1` 变回 `1,0`，AT 恢复 `OK`。
这解释了那个"玄学"：**`--down` 完等 40 秒就拨必失败，等十几分钟再拨就正常**。

---

## 8. 为什么系统代理对 ppp0 无效

```
SOCKSEnable=1
SOCKS=127.0.0.1:1080
__SCOPED__ 里 14 个接口全在（含 ppp0），5 秒内没被 configd 改回
→ CFNetwork 出口 == 直连出口（完全没变）
同一时刻 1080 上有 15+ 条 ESTABLISHED（xray 活着，端口通）
```

根因：macOS 的代理按「**网络服务**（Network Service）」存储，
`ppp0` 是 ifnet，但没有对应的服务对象 —— 它不出现在"系统设置 → 网络"里，
`networksetup` 也设不了。写进 `State:/Network/Global/Proxies` 的动态字典会被
configd 按服务重算时覆盖，即使没被覆盖，CFNetwork 在 PPP 接口上也不读它。

`13-proxy-diag.sh` 是三步可复现实验（基线 / 只写 SOCKS / 再补 HTTP），
它会在结论里直接说"这条路到此为止"。

---

## 9. TUN 方案与防回环

```
App → utun233(sing-box) → SOCKS 127.0.0.1:1080(xray) → 节点 → ppp0
```

TUN 在 IP 层截流量，不看任何代理设置。唯一的坑是**回环**：
xray 自己去连节点、自己去查 DNS 的流量，也会被 TUN 抓走 → 死循环。三层保险：

1. TUN 的 `route_exclude_address`：节点 IP + 直连 DNS 不经过 TUN；
2. `process_name: ["xray"] → 直连`；
3. `ip_cidr: [节点/DNS] → 直连`。

两个"直连"出口都写着 `bind_interface: ppp0`，所以隧道出口被钉死在蜂窝网卡上
（`en0` 的 Wi-Fi 完全不参与）。

细节：`utun233` / `172.19.9.1/30` / `mtu 1400` / `stack: gvisor` /
`auto_route: true` / `strict_route: false`。DNS 分流：`.cn` 与 `geosite-cn`
走 `119.29.29.29`（直连），其余走 DoH `1.1.1.1`（经代理），TUN 内 `hijack-dns`。

**默认路由不会被替换**：sing-box 加的是 `0.0.0.0/1` + `128.0.0.0/1` 两条更具体的路由。
好处是 sing-box 一挂，流量自动退回 ppp0 直连，不会断网。
代价是 `route -n get default` 仍显示 ppp0 —— 这是正常的，别当成没生效。

`14-tun.sh gen` 会从 xray 配置里读端口和节点地址，重写这份 JSON。
换节点之后必须重新 `gen`，否则 `route_exclude_address` 里的旧 IP 不再匹配，
回环就出现了。

---

## 10. 与 Linux 拨号流程的对照（模式切换见 §4）

Linux 下（`usb_modeswitch` + `option` 驱动）能跑的，这里逐条对应：

| Linux 那套 | 本项目 | 结论 |
|---|---|---|
| `usb_modeswitch` 的 HuaweiAltMode 31 字节报文 | kext 里原样重放 | 一样，只是必须在内核里才能抢到接口 |
| `option` 驱动把 if0 同时当 AT 口和 PPP 数据口 | `tools/e398_ppp` 用户态打开 if0，bulk ↔ stdio，给 `pppd pty` | 等价，且不需要第三方 kext |
| 拨号前 `AT+CPIN?` / `AT+CSQ` | `5-ppp-dial.sh` 的 3a 段 | 照抄 |
| `AT+CGREG?` 等到 `0,1`/`0,5` | 3b 段轮询 | 照抄 |
| `AT+CGATT=1` 确保 PS 附着 | 新增（`+CGATT: 0` 时补发） | 照抄 |
| `AT+CGDCONT` → `ATD*99***1#` | chat 脚本里就是这两条 | 一样 |
| `pppd` 的 `usepeerdns` / `ipcp-accept-*` / `noccp` / `novj` | 参数一致，MTU 1500 | 一样 |
| **`huawei_cdc_ncm` / `cdc_ether`（NDIS 路线）** | **不适用** | 1506 只暴露 `ff/01/01`、`ff/01/02`、`08/06/50`，没有 ACM 也没有 ECM，macOS 上没有网卡可认 |
| **`option` 驱动 close 时复位接口**（所以 `poff` 完能立刻 `pon`） | **做不到** | 固件不认 `+++`/`ATH`，重枚举/挂起/改配置都断不掉 PDP → 用会话复用绕过 |

一句话：**协议流程能搬的全搬了**（CPIN→CSQ→CGREG→CGATT→CGDCONT→ATD→LCP/IPCP），
搬不了的是"内核串口驱动"和"接口复位"这两件事，用用户态桥接与会话复用替代。

---

## 11. 失败尝试总表（别再试了）

| 尝试 | 结果 |
|---|---|
| `diskutil eject` / 弹出虚拟光盘 | 设备重枚举，PID 仍 1505 |
| 端点 0 发华为 `SET_FEATURE(1)`（usb_modeswitch 的 HuaweiMode） | STALL，`0xe000404f` |
| 端点 0 直接送 31 字节（class/vendor × interface/device 四种组合） | 全部 STALL；但 `GET_MAX_LUN` 返回 0，说明 class 通道通、固件不收报文 |
| SCSI Task 用户客户端发自定义 CDB | macOS 15 上 `IOSCSITaskDevice` 无实例，`Type05` 返回 `kIOReturnUnsupported` |
| 重枚举后的空窗期抢接口 | 内核重绑定快于用户态轮询，6 轮全败 |
| `SET_CONFIGURATION(2)` | `bNumConfigurations = 1`，只有一套配置 |
| `USBDeviceReEnumerate(kUSBReEnumerateCaptureDeviceBit)` | 头文件明确：不会终止已附着到 Mass Storage 接口的驱动 |
| `kextunload IOUSBMassStorageDriver` | 在 `BootKernelExtensions.kc` 里，Big Sur 起运行时不可卸载 |
| 占位 kext（只 attach 不 open） | 原理性错误：接口同一时刻只能有一个 open session |
| 华为官方驱动（`MobileConnectDriver.pkg`） | x86_64 但依赖已移除的 IOUSBFamily 1.9，无签名、进不了内核集合 → 加载后 `kmutil showloaded` 里没有它 |
| `Mobile Partner.app` 界面 | i386/PPC，macOS 15 跑不起来 |
| 合成假 KDK 绕开 kmutil 检查 | `Code 34 Missing Developer Kit … build 24H32` |
| 系统代理（SOCKS/HTTP/HTTPS + `__SCOPED__`） | 写入成功但 CFNetwork 不读 → 见第 8 节 |
