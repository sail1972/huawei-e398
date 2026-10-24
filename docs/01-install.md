# 安装指南

从零到能上网，一共 6 步。每一步都给了**判定标准** —— 没到标准就别往下走，
后面的步骤会以奇怪的方式失败，反而更难查。

预计耗时：15 分钟（其中重启占大半）。

---

## 第 0 步　环境自检

```bash
sw_vers                      # 期望 ProductVersion 15.x
uname -m                     # 期望 x86_64
csrutil status               # 期望 disabled
nvram boot-args              # 期望含 amfi_get_out_of_my_way=1
which clang                  # 期望 /usr/bin/clang
system_profiler SPUSBDataType | grep -A6 -i huawei | head -20
```

最后一条应该看到 `Product ID: 0x1505`（零 CD 装机模式）。

缺什么都别急着改，先跑一次本项目自带的体检，它会逐条标出问题：

```bash
./status.sh
```

`./status.sh` 是只读的，不需要 root。

> 如果 `csrutil status` 是 `enabled`：重启进恢复模式（Intel 机器是开机按住
> `⌘R`），终端执行 `csrutil disable`，再重启。
> T2 机型还需要先在"启动安全性实用工具"里把安全启动降为"中等安全性"。

---

## 第 1 步　关闭 AMFI（kext 加载的硬门槛）

macOS 11 起 `/Library/Extensions` 里的 kext 必须进 AuxKC 才能开机加载，
而 AuxKC 里的 kext 仍要过 AMFI 的签名校验。本项目自建的 kext 只有 ad-hoc 签名，
**不关 AMFI 就一定加载失败**，而且报错极其隐晦（AuxKC 里明明有，内核里就是没有）。

```bash
sudo ./12-amfi.sh status     # 看现状
sudo ./12-amfi.sh on         # 写入 boot-args，需要重启才生效
```

判定标准：`sudo ./12-amfi.sh status` 输出 `AMFI : 已关闭（可加载 ad-hoc 签名 kext）`。

> 安全提示：`amfi_get_out_of_my_way=1` 会放松整个用户态的代码签名校验。
> 驱动装完、`7-verify.sh` 通过之后可以 `sudo ./12-amfi.sh off` 撤销 ——
> 已加载的 kext 不受影响，下次重启才恢复严格校验。
> **注意：撤销后下次重启 kext 就加载不了了**，需要长期使用时请留着。

---

## 第 2 步　编译用户态工具

```bash
./tools/build.sh
```

编译 13 个 C / Objective-C 工具（AT 收发、USB↔stdio 桥、探测等）。
日常拨号真正用到的只有 `e398_at` 和 `e398_ppp`，`5-ppp-dial.sh` 发现它们不在也会现场编。

判定标准：末尾输出 `必需工具齐备（e398_at / e398_ppp）`。

不需要 root，不会动系统里的任何东西。产物在 `tools/` 下，已被 `.gitignore` 排除。

---

## 第 3 步　安装切换驱动（需要重启）

**重启前把 modem 插好**，并且中途别拔。

```bash
sudo ./6-install-switcher.sh
```

它做的事，按屏幕上的小节号：

| 小节 | 动作 | 判定 |
|---|---|---|
| 0 | 读设备状态 | 必须看到 `12d1:1505 在` |
| 1 | 编译 / 校验 `E398Switcher.kext` | 必须看到 `二进制含 _kmod_info`，且 start 指针非 0 |
| 2 | 拷进 `/Library/Extensions`（root:wheel） | 目录属主必须是 `root wheel` |
| 2.5 | 检查 AMFI | 必须是"已关闭"，否则只警告不拦你 |
| 3 | 重建 AuxKC（`kmutil install -z` → 失败换依赖写法） | `AuxKC 里已有 local.e398.switcher 1.7.0` |
| 4 | 自检 | — |
| 5 | 尝试立即加载 | 首次通常要重启，属正常 |
| 6 | 提示重启 | 回答 `y` 自动重启 |

**关键判定**：第 3 节必须出现 `✓ AuxKC 里已有 local.e398.switcher`。
这一步失败的话，重启一百次也没用 —— 先解决它（见
[03-troubleshooting.md](03-troubleshooting.md)）。

重启时 modem 保持插着。开机后 kext 会在匹配阶段抢先独占 mass-storage 接口，
异步写入 31 字节报文，设备随即重枚举成 `12d1:1506`。

---

## 第 4 步　重启后验证

```bash
./7-verify.sh
```

五节内容，怎么看：

| 节 | 正常表现 | 不正常时 |
|---|---|---|
| 1. 内核扩展是否加载 | `showloaded` 里有 `local.e398.switcher (1.7.0)` **且** `E398Loader 实例：有` | 只有 showloaded 没有实例 → kmod start 失败，看第 2 节日志 |
| 2. 内核日志 | 有 `E398Switcher: 已发送切换报文` 之类的行 | 出现 `NULL module start pointer` / `0xdc008007` → kext 被内核回滚 |
| 3. 设备 PID | `12d1:1506` | 还是 1505 → 见 [troubleshooting](03-troubleshooting.md) |
| 4. 接口归谁 | `UsbExclusiveOwner` 是 E398 相关 | 被 `IOUSBMassStorageDriver` 占着 → 拔插一次重来 |
| 5. AT 通道 / PPP | `if0 回 OK`（或 `ppp0` 已有地址） | `if0 不响应 AT` → 上次拨号留下的数据态，见 troubleshooting |

判定标准：**第 3 节显示 `12d1:1506 在`**。

> 如果还是 1505 且日志里说"接口已被占用"：把 modem 拔下来，等 3 秒，插回去。
> 此时 kext 已在内核里，重新匹配一定由我们赢。

---

## 第 5 步　拨号

```bash
sudo ./5-ppp-dial.sh
```

它会按 Linux 侧华为 ppp 脚本的顺序自检，任何一环不对都会直接说清是哪一环：

```
=== 3a. SIM 与信号 ===      AT+CPIN? 必须 READY；AT+CSQ 打印 dBm
=== 3b. 等分组域注册 ===    AT+CGREG? 等到 0,1 / 0,5（最多 15 秒）
=== 3c. 确保 PS 附着 ===    AT+CGATT? 若为 0 则补 AT+CGATT=1
=== 4. APN ===             按 AT+COPS? 的运营商自动选 3gnet / cmnet / ctnet
=== 5. 启动 pppd ===        chat: AT+CGDCONT → ATD*99***1# → LCP/IPCP
=== 6. 拨通了，pppd 已在后台 ===
```

成功的标志：

```
  ppp0：10.x.x.x --> 10.64.64.64
  默认路由：ppp0
  实测出口：112.96.x.x        ← 这是 ppp0 的真实公网出口
```

然后**提示符会立刻回来**（pppd 已转后台，日志 `/tmp/e398-pppd.log`）。

APN 不对就手动指定：

```bash
sudo ./5-ppp-dial.sh 3gnet      # 联通
sudo ./5-ppp-dial.sh cmnet      # 移动
sudo ./5-ppp-dial.sh ctnet      # 电信
sudo ./PDP_TYPE=IPV4V6 ./5-ppp-dial.sh 3gnet   # 个别地区/套餐只认 IPv4v6
```

验证：

```bash
./5-ppp-dial.sh --status
curl -4 -s https://ifconfig.me/ip     # 应该等于上面那个"实测出口"
```

---

## 第 6 步　（可选）让全局流量走代理

如果你本来就有 SOCKS5 代理（v2rayN / xray 的 mixed 入站，通常是 `127.0.0.1:1080`）：

```bash
./14-tun.sh probe       # 体检，不需要 root
sudo ./14-tun.sh up     # 开 TUN
```

**为什么不能用系统代理**：ppp0 是 ifnet，但不是"网络服务"，
`networksetup` 配不到它；即使强行写进 `State:/Network/Global/Proxies`，
macOS 15 的 CFNetwork 依然直连（`13-proxy-diag.sh` 的三步实验可复现）。
所以走 TUN，在 IP 层截流量，与系统代理无关。

判定标准：`sudo ./14-tun.sh up` 末尾打印的出口 IP **≠** ppp0 直连出口
（说明流量真的进了隧道）。失败会自动回滚并打印 sing-box 日志最后 30 行。

细节和防回环设计 → [04-internals.md](04-internals.md)。

---

## 卸载 / 回滚

```bash
sudo ./9-uninstall.sh     # 删 kext（优先用 6 留下的 AuxKC 备份还原）
sudo reboot
```

如果还想恢复安全设置：

```bash
sudo ./12-amfi.sh off     # 撤销 AMFI 放宽，重启生效
# csrutil enable 需要进恢复模式
```

拔掉 modem 后系统与安装前没有任何区别（本项目不装任何常驻守护进程，
除非你自己开了 `8-ppp-keepalive.sh` 或 `11-proxy-fix.sh install`）。

---

## 装完的样子（供对照）

```
$ ./7-verify.sh
=== 1. 内核扩展是否加载 ===
  151    0 0xffffff7f970da000 ...  local.e398.switcher (1.7.0)
      E398Loader 实例：有（kmod 层通过）
=== 3. 设备当前 PID ===
  12d1:1506 在
=== 5. AT 通道 / PPP ===
  ✓ if0 回 OK（AT 通道正常）

$ ./5-ppp-dial.sh --status
  设备：12d1:1506
  ppp0：10.13.45.178 --> 10.64.64.64    MTU 1500
  默认路由：ppp0
  实测出口：112.96.x.x
  modem：命令态（AT 正常）→ 下次拨号会重新 ATD
```
