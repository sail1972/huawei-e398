# 使用指南

装好之后（见 [01-install.md](01-install.md)），日常只需要记住三件事：
**拨号、看状态、关掉**。代理是第四件，可选。

---

## 1. 三个场景

### 开机后（或拔插 modem 之后）

kext 会自己在 1~3 秒内把设备切到 `12d1:1506`，但 **PPP 会话不会自动重建**，
所以要手动拨一次 —— 或者让看护帮你拨。

```bash
sudo ./5-ppp-dial.sh
```

成功的样子（然后提示符就回来了）：

```
=== 6. 拨通了，pppd 已在后台 ===
  ppp0：10.13.45.178 --> 10.64.64.64
  默认路由：ppp0
  实测出口：112.96.x.x
  DNS：120.80.80.80 / 221.5.88.88
```

### 用完想断

```bash
sudo ./5-ppp-dial.sh --down
```

它会停 pppd、停 USB 桥、清掉系统代理残留。**注意**：蜂窝侧的 PDP 会话
不一定跟着断（原因见 [04-internals.md](04-internals.md)），
本机的流量确实停了，但运营商侧可能还算你在线。

想彻底断（也彻底省电）：**把 modem 拔下来**。

### 掉了想自动恢复

```bash
sudo ./8-ppp-keepalive.sh start     # 后台看护：ppp0 一掉就重拨
./8-ppp-keepalive.sh status         # 看护在不在 + 当前链路
sudo ./8-ppp-keepalive.sh stop      # 停看护（不断开现有连接）
sudo ./8-ppp-keepalive.sh stop --down   # 停看护并断开
```

看护每 15 秒查一次 `ppp0`，日志在 `/tmp/e398-keepalive.log`。

---

## 2. 状态怎么读

```bash
./5-ppp-dial.sh --status
```

```
  设备：12d1:1506
  ppp0：10.13.45.178 --> 10.64.64.64    MTU 1500
  默认路由：ppp0
  实测出口：112.96.x.x
  modem：命令态（AT 正常）→ 下次拨号会重新 ATD
```

最后一行 `modem:` 是决定"下次拨号怎么走"的关键，只有三种：

| 显示 | 含义 | 下次拨号会 |
|---|---|---|
| `命令态（AT 正常）` | if0 还认 AT 命令 | 正常 `ATD*99***1#` 重新拨 |
| `数据态（上次的 PDP 还挂着）` | if0 上还在流 `7e ff 03 …` 的 PPP 帧 | **复用旧会话**，不发 ATD，2~3 秒通 |
| `if0 无响应` | 真卡死 | 脚本会直接让你拔插 |

`实测出口` 是用真实 HTTP 请求量出来的公网 IP，不是从 `ifconfig` 抄的 ——
它等于"你现在的流量到底从哪出去"。

只看链路不关心 modem 的话，`./status.sh` 更快（纯只读体检）。

---

## 3. 代理（可选，TUN 模式）

前提：你本机已有 SOCKS5 在听（v2rayN / xray 的 mixed 入站，默认 `127.0.0.1:1080`）。

```bash
./14-tun.sh probe       # 体检：sing-box 在不在、SOCKS 通不通、ppp0 有没有地址
sudo ./14-tun.sh up     # 开；ppp0 没在线会先自动拨号
./14-tun.sh status
sudo ./14-tun.sh down   # 关，并清掉残留路由
sudo ./14-tun.sh log 80 # 看 sing-box 日志
```

开的时候默认路由**不会被替换**，sing-box 加的是 `0.0.0.0/1` + `128.0.0.0/1`
两条更具体的路由。好处是：sing-box 一挂，流量自动退回 ppp0 直连，不会断网。

**系统代理可以关掉了**（TUN 不看它）：

```bash
sudo ./11-proxy-fix.sh off            # 清掉写进动态存储的代理
sudo ./11-proxy-fix.sh uninstall      # 卸掉那个会不停写回代理的 LaunchDaemon
```

换节点/换订阅：在 v2rayN 里换，然后

```bash
sudo ./14-tun.sh gen && sudo ./14-tun.sh up
```

`gen` 会重新读 xray 配置里的端口和节点 IP，重写防回环规则（节点 IP 变了就得重来）。

> 只想让**个别 App** 走代理、不想全局？TUN 是全局的。
> 那种情况直接在 App 里填 `SOCKS5 127.0.0.1:1080`（如浏览器插件、Telegram 内置代理），
> 别开 TUN。

---

## 4. 与 Wi-Fi 共存

ppp0 拨通时会抢默认路由（`defaultroute`），所以**全局流量走 4G**，
Wi-Fi 变成闲置。想反过来（只在需要时用 4G）：

```bash
sudo ./5-ppp-dial.sh --down
```

想确认现在到底走哪条：

```bash
route -n get default | grep interface
```

想手动切回去，把 Wi-Fi 的服务顺序调高即可（系统设置 → 网络 → 顺序），
或临时 `sudo route change default <Wi-Fi 网关>`。

---

## 5. 流量与费用

```bash
netstat -ib | awk '$1=="ppp0" && $7!="" {print $7" 字节入 / "$10" 字节出"}' | tail -1
```

- E398 是 LTE Cat3 时代的设备，实测下行 **~6 Mbps**（740 KB/s），别指望更快。
- 开了 TUN 之后**所有**流量（含系统更新、iCloud、App 后台）都会走 4G，
  在没有不限量套餐的情况下建议用完就 `--down`，或者干脆只在需要时开。
- 系统更新、Time Machine 这类操作务必先断开 4G。

---

## 6. 常用 AT 命令

工具：`./tools/e398_at --iface 0 --cmd '...'`（不需要 root，也不需要 modem 处于拨号态）

```bash
./tools/e398_at --iface 0 --cmd AT                          # 探活
./tools/e398_at --iface 0 --cmd 'AT+CPIN?'                  # SIM 状态
./tools/e398_at --iface 0 --cmd 'AT+CSQ'                    # 信号（-113+2*n dBm）
./tools/e398_at --iface 0 --cmd 'AT+COPS?'                  # 运营商
./tools/e398_at --iface 0 --cmd 'AT+CGREG?' --cmd 'AT+CGATT?'  # 注册 / 附着
./tools/e398_at --iface 0 --cmd 'AT+CGDCONT?'               # APN 配置
./tools/e398_at --iface 0 --cmd 'AT+CGACT?'                 # PDP 有没有残留
./tools/e398_at --iface 0 --read 1500 --hex                 # 直接看 if0 上的原始字节
```

`--read ... --hex` 是最有用的诊断手段：能看到 if0 现在是"回 OK 文本"还是
"流 PPP 帧"。`--raw <hex>` 可以往 bulk OUT 灌原始字节（逆向实验用的，慎用）。

---

## 7. 日志在哪

| 文件 | 内容 |
|---|---|
| `/tmp/e398-pppd.log` | pppd 完整协商过程（最常见，出问题先看这个） |
| `/tmp/e398-pppd.out` | `--bg` 模式的汇总输出 |
| `/tmp/e398-ppp.log` | USB 桥接日志（管道打开/关闭、批量传输错误码） |
| `/tmp/e398-keepalive.log` | 看护循环记录 |
| `/tmp/e398-tun.log` | sing-box 日志 |
| `./diag-*.log` | `sudo ./10-diag.sh` 生成的一次性证据包 |

`/tmp` 重启会清空，需要长期留证据就先复制出来。

---

## 8. 开机自启（可选，仅供参考）

项目本身**不装任何常驻守护进程**。想开机自动拨号，用 LaunchDaemon 包住看护脚本：

```bash
sudo tee /Library/LaunchDaemons/local.e398.keepalive.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.e398.keepalive</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>exec "$HOME/WorkBuddy/华为 E398 驱动/E398/8-ppp-keepalive.sh" watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/e398-keepalive.log</string>
  <key>StandardErrorPath</key><string>/tmp/e398-keepalive.log</string>
</dict>
</plist>
EOF
sudo launchctl bootstrap system /Library/LaunchDaemons/local.e398.keepalive.plist
```

把 `<string>exec ...</string>` 里的路径改成你实际的绝对路径（**路径有空格也没关系，
这是 plist 不是 shell 字符串**）。卸载：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/local.e398.keepalive.plist
sudo rm /Library/LaunchDaemons/local.e398.keepalive.plist
```

开机到能上网的顺序是：kext 切模式（1~3 秒）→ 看护发现 ppp0 不在 → 拨号 → TUN
（TUN 不会自启，需要的话同样用 LaunchDaemon 包 `14-tun.sh up`，
但要排在拨号之后）。
