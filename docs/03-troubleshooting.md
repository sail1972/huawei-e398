# 排错手册

按症状查。每条都给了**判定命令**和**根因**，别靠猜。

先跑这三个中的一个：

```bash
./status.sh            # 最快：系统 / 设备 / 驱动 / 接口
./7-verify.sh          # 完整：kext 是否真加载 + 内核日志 + 接口归属
sudo ./10-diag.sh      # 兜底：落一份 diag-*.log，可直接贴出来
```

---

## `7-verify.sh` 里还是 1505

先分清是"kext 没加载"还是"加载了但没抢到接口"。

```bash
kmutil showloaded | grep e398
ioreg -l -w0 | grep -c "E398Loader"     # 有实例才算 kmod 层通过
ioreg -p IOUSB -w0 -l | grep -A2 UsbExclusiveOwner
```

| 观察 | 结论 | 修法 |
|---|---|---|
| `showloaded` 里没有 e398 | kext 根本没进内核 | 见下一节 |
| `showloaded` 有，但 `E398Loader` 计数为 0 | **假加载**：kmod start 失败被回滚 | 见下一节（`0xdc008007`） |
| 两者都有，但设备仍 1505 | 线程没抢到接口 | 拔插一次 modem；仍不行看内核日志里的 `open ... 失败` |
| `UsbExclusiveOwner` 是 `IOUSBMassStorageDriver` | 占用者没被赶走 | 拔插；v1.5.0 会先 `open(kIOServiceSeize)` 再 `terminate` |

查看它到底做了什么：

```bash
log show --last boot --predicate 'eventMessage CONTAINS "E398"' | tail -30
```

正常会看到类似 `E398Switcher: 找到 12d1:1505 接口` → `已发送切换报文`。

拔插是对的：USB 重枚举后 kext 会重新匹配一次，此时它已在内核里，一定赢。

---

## kext 不生效（Code 28 / 71 / `0xdc008007`）

这些码都是 `kmutil` / 内核的原始错误，含义各不相同：

### `Code 28` = 需要重启

集合已更新，但当前内核里还没有它。**重启就好**，不是错误。

### `Code 71` = 集合里有，内核里没有

通常是依赖版本对不上。本项目踩过的真身：

```
声明 com.apple.iokit.IOUSBHostFamily = 1.0.0
盘上实际是 CFBundleVersion = 1.2 / OSBundleCompatibleVersion = 1.0.1
→ could not find version compatible with '1.0.0'
```

修法：`kext-src/E398Switcher-Info.plist` 里依赖写成 **1.2**（脚本按这个走）。
自己改过的话用 `kmutil showloaded | grep IOUSBHostFamily` 确认盘上版本。

### `NULL module start pointer` / `0xdc008007`

内核拒绝加载并**回滚全部符号**（`__mod_init_func` 不跑、类不注册、
`ioreg` 里只剩 `Couldn't alloc class`），而 `kmutil showloaded` **照样会列出它**。
这就是"已加载但完全没作用"的经典假象。

根因：`KMOD_EXPLICIT_DECL` 的 start/stop 指针传了 0。ld-1267 之后链接器不再自动
合成 `_kmod_info`，必须显式声明并指向真实函数：

```cpp
extern "C" kern_return_t E398KmodStart(kmod_info_t *ki, void *d);
extern "C" kern_return_t E398KmodStop(kmod_info_t *ki, void *d);
KMOD_EXPLICIT_DECL(E398Switcher, "1.5.0", E398KmodStart, E398KmodStop)
```

自检（不用装，直接看二进制）：

```bash
python3 tools/kmod-info.py kext/E398Switcher.kext/Contents/MacOS/E398Switcher
# start / stop 必须是非 0 地址
```

### `No binaries or codeless kexts were provided`

真正的错误藏在上一行 `Invalid ownership (501:0) should be (0:0)`：
kext 及其**每个子目录**都必须是 `root:wheel`。`6-install-switcher.sh` 已经处理。

### `kmutil install` 输出 `done` 但集合没变

没装 KDK 时它**以退出码 0 静默跳过**依赖解析失败的 kext。两条出路：

- 装对应 build 的 KDK（`24H32`）；
- 用 `kmutil create -n aux -z --allow-missing-kdk -p <kext>` 手工重建（脚本会试）。

> 合成一个假 KDK 是**无效**的：kmutil 会校验 KDK 元数据，直接
> `Code 34 Missing Developer Kit … build 24H32`。

### kext 在集合里但仍不加载，且日志只有一句 AMFI

AMFI 没关。`sudo ./12-amfi.sh status` 必须显示"已关闭"，否则 ad-hoc 签名过不了。

---

## `✗ if0 不响应 AT`

先确认它到底是"卡死"还是"在数据态"：

```bash
./tools/e398_at --iface 0 --cmd AT --wait 1500 --hex
```

| 看到 | 含义 | 怎么办 |
|---|---|---|
| `41 54 0d 0a 4f 4b`（`AT\r\nOK`） | 命令态，正常 | 不需要处理 |
| `7e ff 03 …`（PPP 帧） | **数据态**：上次 PDP 还挂着 | 直接 `sudo ./5-ppp-dial.sh`（自动复用），或拔插 |
| 什么都没有 | 真卡死 | 拔插 |
| `0xe00002c5`（打开失败） | 端口被别的进程占着 | `pkill -f e398_ppp` 后重试 |

`+++`、`ATH`、`USBDeviceReEnumerate`、`SetConfiguration(0→1)`、USB 挂起
**全都拉不回命令态**（都实测过，代码留在 `tools/e398_power.c`）。
数据态不用怕：脚本会复用旧会话，2~3 秒就通。

---

## `NO CARRIER`

日志里出现（可能是十六进制形式 `4e 4f 20 43 41 52 52 49 45 52`）：

```
rcvd [proto=0xd] 0a 4e 4f 20 43 41 52 52 49 45 52 0d 0a
```

含义：**运营商拒了这次数据呼叫**，不是驱动问题。按概率排：

1. **上一个 PDP 还没释放** → 等 5~10 分钟，或拔插一次。若 if0 处于数据态，
   别重拨，直接复用（脚本已自动判断）。
2. **刚开机就拨，射频栈还没起来** → 脚本现在会先等 `AT+CGREG?` 到 `0,1`/`0,5`，
   再确认 `AT+CGATT: 1`。手工复现：
   ```bash
   ./tools/e398_at --iface 0 --cmd 'AT+CGREG?' --cmd 'AT+CGATT?' --cmd 'AT+CSQ'
   ```
3. **APN 不对**：
   ```bash
   ./tools/e398_at --iface 0 --cmd 'AT+COPS?' --cmd 'AT+CGDCONT?'
   sudo ./5-ppp-dial.sh 3gnet     # 联通；移动 cmnet；电信 ctnet
   ```
4. **只认 IPv4v6 的 PDP**：`sudo PDP_TYPE=IPV4V6 ./5-ppp-dial.sh 3gnet`
5. **SIM 侧**：`AT+CPIN?` 不是 `READY`（欠费停机、PIN 未解、套餐不含数据）。
6. 以上都对就是运营商账号侧的问题，找客服。

---

## 拨通了但没网

ppp0 有地址、`ping` 网关通，但打不开网页 —— 通常是 DNS 或 MTU。

```bash
scutil --dns | head -20                     # DNS 有没有 120.80.80.80
ping -c 2 -t 3 120.80.80.80                 # 直连 DNS 通不通
curl -4 -s -m 8 https://ifconfig.me/ip      # 用 IP 出口验证链路
dig @120.80.80.80 baidu.com +short          # 指定 DNS 解析
```

- **DNS 空**：`pppd` 的 `usepeerdns` 没写进配置存储时会发生。
  `sudo ./5-ppp-dial.sh --down` 再拨一次即可（脚本会重启 pppd 并重新提交 DNS）。
- **能解析但打不开 HTTPS**：MTU 问题。实测 1500 可通，若你的链路不行：
  ```bash
  sudo ifconfig ppp0 mtu 1400
  ```
- **DNS 被篡改/污染**：改用 TUN 模式，DNS 会被劫持到 DoH。

---

## 系统代理写了但不生效

这是**系统行为**，不是配置错误：

```
SOCKSEnable=1、SOCKS=127.0.0.1:1080、__SCOPED__ 里 14 个接口全在
→ CFNetwork 出口 == 直连出口（一点没变）
```

因为 macOS 的代理是按「网络服务」存的，**ppp0 是 ifnet 但不是网络服务**，
CFNetwork 在它上面不读代理设置。复现实验：

```bash
sudo ./13-proxy-diag.sh     # 三步：基线 / 只写 SOCKS / 再补 HTTP
```

结论页会明确告诉你"系统代理这条路到此为止"。

**改用 TUN**（`sudo ./14-tun.sh up`），它截 IP 层，与代理设置无关。
`11-proxy-fix.sh` 保留只为留证据，日常别用。

---

## TUN 起来后断网

`14-tun.sh` 自带回滚（10 秒内没接管默认路由，或验证出口没变，会自动 down），
所以先看它打印的 sing-box 日志尾部。常见三种：

| 现象 | 原因 | 修法 |
|---|---|---|
| `sing-box check` 失败 | 配置语法/字段不匹配（版本差异） | `sing-box version` 对比；删掉报错的那个字段 |
| 起来了但 curl 超时 | 防回环没盖住节点 IP | `sudo ./14-tun.sh gen` 重新读节点 IP（换节点后必做） |
| 全都通但极慢 | DNS 走了代理（`.cn` 规则没命中） | 确认 `geosite-cn.srs` 路径存在，否则 `gen` 会退回只用 `.cn` 后缀 |

手工兜底（TUN 把路由搞乱时）：

```bash
sudo route delete -net 0.0.0.0/1
sudo route delete -net 128.0.0.0/1
sudo ./14-tun.sh down
```

`14-tun.sh up` 之后如果 `route -n get default` 还是 ppp0，**这是正常的** ——
sing-box 加的是两条更具体的路由，不是替换 default。

---

## 拨号脚本报 `需要 root`

`5-ppp-dial.sh`、`6-install-switcher.sh`、`9-uninstall.sh`、`10-diag.sh`、
`12-amfi.sh`、`14-tun.sh up/down` 都要 root。
`--status`、`7-verify.sh`、`status.sh`、`14-tun.sh probe` **不要 root**，别加 sudo。

---

## `sh: /Users/…/华为: No such file or directory`

老版本的坑，已修。原因：`pppd pty` 的参数会被 `/bin/sh -c` 执行，
路径里的空格把命令截断了（`status 0x7f` = 127）。
现在脚本会生成一个无空格路径的包装脚本 `/tmp/e398-pty.sh` 给 pppd 用。
如果你自己改过脚本又遇到这个，照同样思路绕开空格。

---

## 回到干净状态

```bash
sudo ./14-tun.sh down             # 先关 TUN，否则拔掉 modem 会全局没网
sudo ./8-ppp-keepalive.sh stop    # 停看护
sudo ./5-ppp-dial.sh --down
sudo ./9-uninstall.sh && sudo reboot
```

`9-uninstall.sh` 会删 `/Library/Extensions/E398Switcher.kext`，并优先用
`6-install-switcher.sh` 留下的 AuxKC 备份还原。还原不了也没关系：
kext 不在 `/Library/Extensions` 里，下次重建集合时自然就没了。

想连安全设置一起恢复：`sudo ./12-amfi.sh off` → 重启；
`csrutil enable` 需要进恢复模式。
