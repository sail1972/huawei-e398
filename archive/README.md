# archive —— 走过的死路

这里的脚本**不要用**。留着是因为每一条都对应一个"看起来可行、实测不通"的思路，
写文档和复盘时需要证据。

| 文件 | 思路 | 为什么死了 |
|---|---|---|
| `1-switch-mode.sh` | 用户态 `USBInterfaceOpenSeize` 打开 mass-storage 接口后发 31 字节 | `0xe00002c5`：接口被 `IOUSBMassStorageInterfaceNub` 独占，永远拿不到 |
| `1b-switch-detach.sh` | 先 `diskutil eject` 掉虚拟光驱，趁空窗期抢接口 | 内核重绑定快于用户态轮询，6 轮全败 |
| `1c-switch-linuxway.sh` | 完全照抄 usb_modeswitch：端点 0 发 `SET_FEATURE(1)` 或灌报文 | 全部 STALL（`0xe000404f`）；`GET_MAX_LUN` 通说明 class 通道通、固件不收报文 |
| `5-block-and-switch.sh` | 自建 `E398Blocker.kext` 只 attach 占位、不 open，把占用者挡住 | 原理性错误：接口同一时刻只能有一个 open session，挡住别人自己也拿不到 |
| `E398Blocker.cpp/.plist` | 上面那个 kext 的源码 | 同上；v1.5.0 的 `E398Switcher` 才是对的 |
| `2-install-driver.sh` | 装华为官方 `HuaweiDataCardDriver.kext`，把 1506 变成 `/dev/tty.HUAWEIMobile-*` | 2013 年的驱动：依赖 macOS 11 起移除的 IOUSBFamily 1.9 API、无签名、进不了 AuxKC。装完 `kmutil showloaded` 里没有它 |
| `3-connect.sh` | NDIS 方式（`AT^NDISDUP`）拨号，靠 `/dev/cu.*Pcui*` | 那个串口从来没出现过（官方驱动没生效），没有串口就没有入口 |
| `4-ppp.sh` | 早期 PPP 尝试，同样依赖 Pcui 串口 | 同上。真正的 PPP 方案是用户态桥接（现在的 `5-ppp-dial.sh`），不依赖任何串口 |

结论在 [../docs/04-internals.md](../docs/04-internals.md) 第 2、11 节，也写在
`kext-src/E398Switcher.cpp` 开头的注释里。
