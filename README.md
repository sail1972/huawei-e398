# 华为 E398 · macOS 驱动与上网指南

在 **Intel Mac + macOS 15** 上，把华为 **E398** USB LTE 上网卡（`12d1:1505`）从
"零 CD 装机模式"切到调制解调器模式（`12d1:1506`），并用 PPP 拨号上网。

> 整套流程在这台机器上跑通并长期使用：macOS 15.8.1 / x86_64 / MacBookPro16,2（T2）/
> SIP disabled / boot-args `amfi_get_out_of_my_way=1`。
> 所有结论都是实测出来的，中间失败的每一条路都记在 [docs/04-internals.md](docs/04-internals.md) 里。

---

## 它能做什么

| 能力 | 状态 | 说明 |
|---|---|---|
| `12d1:1505` → `12d1:1506` 模式切换 | ✅ | 自建 kext 在开机时抢占 mass-storage 接口，重放 usb_modeswitch 的 31 字节报文 |
| PPP 拨号上网（IPv4） | ✅ | 用户态 USB↔stdio 桥 + `pppd` + `chat`，实测 ~6 Mbps |
| 掉线自动重拨 | ✅ | `8-ppp-keepalive.sh`（可选开机自启） |
| 全局流量走代理 | ✅ | TUN（sing-box）截 IP 层，**不用系统代理**（macOS 15 对 ppp0 不生效） |
| 华为官方驱动 / `Mobile Partner.app` | ❌ | 2013 年的 i386 二进制，依赖已移除的 IOUSBFamily 1.9，macOS 15 上无解 |
| 把 ppp0 做成"网络服务"（出现在系统设置里） | ❌ | 系统层面做不到，见 [docs/03-troubleshooting.md](docs/03-troubleshooting.md) |

## 前提（不满足就别往下走）

1. **Intel Mac**。kext 只编了 x86_64；Apple Silicon 需要另编 arm64，且 T2/SEP 相关限制不同。
2. **SIP 已完全关闭**：`csrutil status` → `disabled`。半关（`kext` 允许）不够。
3. **AMFI 已关闭**：`nvram boot-args` 里要有 `amfi_get_out_of_my_way=1`（`sudo ./12-amfi.sh on`）。
   否则自建 kext 进得了内核集合，却加载不进内核 —— 现象是"已加载"但设备纹丝不动。
4. **命令行工具**：`xcode-select --install`（只需要 `clang`，不需要完整 Xcode）。
5. modem 插在 **USB-A 口直连**（别经过 hub，切换时序对独占很敏感）。

不放心的话先跑体检，它会逐条告诉你缺什么：

```bash
./status.sh          # 不需要 root
```

## 三步开始

```bash
cd huawei-e398
./tools/build.sh              # 编译用户态工具（clang，几秒）
sudo ./6-install-switcher.sh  # 装 kext 进 AuxKC，然后重启（重启时 modem 保持插着）
```

重启后：

```bash
./7-verify.sh                 # 应该看到 12d1:1506 在 + E398Loader 实例：有
sudo ./5-ppp-dial.sh          # 拨号：通了自动转后台，命令行立刻还给你
```

看到这四行就成了：

```
=== 6. 拨通了，pppd 已在后台 ===
  ppp0：10.x.x.x --> 10.64.64.64
  默认路由：ppp0
  实测出口：112.96.x.x
```

要全局走代理（可选，需要你已有 v2rayN / xray 之类的 SOCKS 1080 在跑）：

```bash
sudo ./14-tun.sh up
```

详细步骤、每一步的判断依据 → **[docs/01-install.md](docs/01-install.md)**

## 日常命令速查

```bash
# 拨号 / 断开
sudo ./5-ppp-dial.sh              # 拨号（自适应：能 ATD 就拨，只剩 PPP 帧就复用旧会话）
sudo ./5-ppp-dial.sh --fg         # 前台跑，Ctrl+C 断开（盯日志用）
sudo ./5-ppp-dial.sh --down       # 断开本机链路（蜂窝 PDP 不一定断，见下）
./5-ppp-dial.sh --status          # 状态：ppp0 / 出口 IP / modem 处于命令态还是数据态

# 代理（TUN 模式，不依赖系统代理）
sudo ./14-tun.sh up               # 开；ppp0 没在线会先自动拨号；失败自动回滚
./14-tun.sh status
sudo ./14-tun.sh down

# 看护
sudo ./8-ppp-keepalive.sh start   # ppp0 掉线自动重拨（stop / status）

# 断联取证（怀疑"用一会儿就断"时先开它）
sudo ./15-watch.sh start          # 常驻记录 USB 事件 + 断联瞬间现场
./15-watch.sh show                # 断过之后看这里，直接给原因线索
```

`--down` 之后**立刻**再拨也能连上：脚本发现 if0 上还在流 PPP 帧，就走"复用旧会话"路径，
不发 `ATD`（发了必被运营商 `NO CARRIER` 顶回来），2~3 秒通。原理见
[docs/04-internals.md](docs/04-internals.md)。

更多日常场景（开机自启、切换网络、省流量）→ **[docs/02-usage.md](docs/02-usage.md)**

## 它是怎么做的

```
开机
 └─ E398Switcher.kext（AuxKC，内核态）
     ├─ E398Loader 挂 IOResources，无条件启动（保证 kext 在 USB 枚举前就位）
     ├─ 热插时：E398Switcher personality（score 1000000）直接接管 08/06/50 接口
     ├─ 开机已插时：接口被 mass-storage 抢先绑定，由 E398Loader 的线程扫描接管
     │   └─ open → 写 31 字节 UFI 报文 → 立刻 close → 设备重枚举为 12d1:1506
     └─ 两条路径互斥（gActiveSwitchers），同一时刻只有一个在动
                        ↓
拨号
 └─ 5-ppp-dial.sh（用户态，不需要额外 kext）
     ├─ e398_at：AT+CPIN / CSQ / CGREG / CGATT / CGDCONT
     ├─ e398_ppp：IOKit 打开 if0，bulk ↔ stdio 桥
     ├─ pppd pty "<桥接>" + chat → ATD*99***1# → LCP/IPCP → ppp0
     └─ 出口 IP 实测打印，成功后 pppd 转后台
                        ↓
代理（可选）
 └─ 14-tun.sh → sing-box TUN(utun233) → SOCKS 1080(xray) → 节点 → ppp0
```

## 已知限制

- **模式切换不持久**：USB 不断电就还是 1506；**物理拔插必回 1505**，
  但 kext 会自己再切一次（1~3 秒）。重启不影响。
  kext 的监视线程是**永久**运行的：接口一出现就由 personality 接管（1.7.0 起
  personality 和兜底路径互斥，不再互抢会话），发一轮报文 → 立刻放开接口 →
  失败就按 2s / 4s / 8s 快重试，之后每 30 秒一次，并每 60 秒打一条心跳。
- **`--down` 断不干净**：`ATD` 之后 if0 变成纯数据管道，modem 固件不解析 AT。
  `+++`/`ATH`/重枚举/`SetConfiguration(0→1)`/USB 挂起全部实测无效，
  只有**拔插断电**真的拆 PDP。脚本用"复用旧会话"绕过。
- **只有一个 IPv4 地址**，没有 IPv6；MTU 1500 实测可用。
- **系统代理对 ppp0 无效**（macOS 15 的 CFNetwork 行为），所以代理必须走 TUN。
- **长连接会断**，原因不止一种（USB 被复位 / modem 自己重启 / 运营商拆 PDP）。
  这三者的现象都是"ppp0 没了"，事后无法区分 —— 用 `15-watch.sh` 在断的当下取证。

## 出问题了

| 症状 | 先看 |
|---|---|
| 用一段时间就断，断了停在 1505 | [排错 · 经常性断联](docs/03-troubleshooting.md) —— 先 `sudo ./15-watch.sh start` |
| `7-verify.sh` 里还是 1505 | [排错 · 还是 1505](docs/03-troubleshooting.md) |
| kext 在 AuxKC 里但没加载（Code 28 / 71 / `0xdc008007`） | [排错 · kext 不生效](docs/03-troubleshooting.md) |
| `✗ if0 不响应 AT` | [排错 · if0 不响应 AT](docs/03-troubleshooting.md) |
| `rcvd [proto=0xd] ... NO CARRIER` | [排错 · NO CARRIER](docs/03-troubleshooting.md) |
| 拨通了但打不开网页 | [排错 · 拨通了但没网](docs/03-troubleshooting.md) |
| TUN 起来后断网 | [排错 · TUN 断网](docs/03-troubleshooting.md) |

兜底采集证据（只读，不改任何东西，生成一份可直接贴出来的 `diag-*.log`）：

```bash
sudo ./10-diag.sh
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/01-install.md](docs/01-install.md) | 安装指南：环境准备 → 装 kext → 重启 → 验证 → 拨号 → TUN，含每步的判定标准与卸载 |
| [docs/02-usage.md](docs/02-usage.md) | 使用指南：日常开关、状态怎么读、开机自启、代理切换、流量注意 |
| [docs/03-troubleshooting.md](docs/03-troubleshooting.md) | 排错手册：按症状查，附根因与命令 |
| [docs/04-internals.md](docs/04-internals.md) | 原理与逆向记录：31 字节报文、kmod 踩坑、接口抢占、会话复用、与 Linux 驱动对照、失败尝试全表 |

## 目录

```
huawei-e398/
├── tools/build.sh          一键编译用户态工具（clang）
├── 6-install-switcher.sh   装 kext 进 AuxKC（root，需重启）
├── 7-verify.sh             重启后体检：设备 PID / kext / 服务实例 / 串口
├── 5-ppp-dial.sh           拨号主程序（--fg / --down / --status / --recover）
├── 8-ppp-keepalive.sh      掉线自动重拨
├── 15-watch.sh             断联取证：常驻记录 USB 事件 + 断联瞬间现场
├── 14-tun.sh               全局代理（sing-box TUN）
├── 11-proxy-fix.sh         系统代理写入（ppp0 上无效，留作证据）
├── 13-proxy-diag.sh        三步实验，证明 macOS 15 不给 ppp0 用系统代理
├── 10-diag.sh              一次性抓全部证据（只读）
├── 12-amfi.sh              AMFI 开关（boot-args）
├── 9-uninstall.sh          完全回滚
├── status.sh               快速体检（不需要 root）
├── build-kext.sh           单独编译 E398Switcher.kext
├── kext-src/               kext 源码（E398Switcher.cpp + Info.plist）
├── kext/E398Switcher.kext  编译产物（x86_64, ad-hoc 签名）
├── tools/                  AT / PPP 桥 / 探测工具（C / ObjC，全部有源码）
├── archive/                已证伪的脚本，留作对照
└── docs/                   四篇文档
```

## 许可

[MIT](LICENSE)。自担风险：改 kext、关 SIP、关 AMFI 都会降低系统安全性，
先想清楚再动手。设备固件归华为；本项目不含任何厂商二进制。
