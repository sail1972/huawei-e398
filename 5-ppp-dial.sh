#!/bin/bash
#
# 5-ppp-dial.sh — 用「用户态桥接 + pppd」拨号上网，不需要任何串口驱动
#
# 为什么不用华为官方驱动：
#   HuaweiDataCardDriver.kext 是 2013 年的产物，personality 匹配的是 IOUSBDevice
#   （旧 IOUSBFamily API），依赖 com.apple.iokit.IOUSBFamily 1.9；它在 macOS 15
#   上既没进内核集合，也没有 /dev 节点。而 1506 模式暴露的 6 个接口全是厂商
#   自定义类 ff/01/xx，苹果一个驱动都不会碰 —— 所以「等它自己出现串口」永远等不到。
#
# 实际做法：
#   tools/e398_ppp 用 IOKit 用户态直接打开 if0（AT 口），把 USB bulk 端点
#   桥接到自己的标准输入输出；pppd 用 pty 选项起它，chat 在上面发 AT 命令，
#   ATD*99***1# 之后同一个口进入 PPP 数据态，PPP 帧就这样流起来了。
#
# 用法：
#   sudo ./5-ppp-dial.sh              拨号（拨通后 pppd 自动转后台，命令行立刻还给你）
#   sudo ./5-ppp-dial.sh --fg         老行为：前台跑 pppd，Ctrl+C 断开（只用于调试）
#   sudo ./5-ppp-dial.sh --bg         先脱壳再拨号（等价于默认行为，保留给脚本调用）
#   sudo ./5-ppp-dial.sh 3gnet        指定 APN
#   ./5-ppp-dial.sh --status          看链路状态（不需要 root）
#   sudo ./5-ppp-dial.sh --down       断开本机链路（蜂窝 PDP 不断，下次 --bg 秒复用）
#   sudo ./5-ppp-dial.sh --recover    先复位 USB（AT 口卡在数据态时用）
#
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$DIR/tools"
PPP_LOG=/tmp/e398-ppp.log
CHAT_FILE=/tmp/e398-chat.txt
PTY_CMD=/tmp/e398-pty.sh
PPP_OUT=/tmp/e398-pppd.out
PPP_PPPD=/tmp/e398-pppd.log
IFACE=0

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

# 终端里如果带着 HTTP_PROXY（某些工具会设），curl 会走那个代理，量到的「直连出口」
# 就不是直连了。统一清掉，本脚本只关心真实链路。
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

MODE=dial
BG=0
FG=0
RECOVER=0
RESUME=0
APN=""
for a in "$@"; do
  case "$a" in
    --recover) RECOVER=1 ;;
    --bg)      BG=1 ;;
    --fg)      FG=1 ;;
    --down)    MODE=down ;;
    --status)  MODE=status ;;
    -h|--help)
      cat <<'USAGE'
5-ppp-dial.sh — 华为 E398 拨号（用户态桥接 + pppd，不需要任何第三方 kext）

  sudo ./5-ppp-dial.sh              拨号（拨通后自动转后台，命令行立刻返回）
  sudo ./5-ppp-dial.sh --fg         前台跑 pppd，Ctrl+C 断开（调试用）
  sudo ./5-ppp-dial.sh --bg         先脱壳再拨号（脚本调用用，等价默认行为）
  ./5-ppp-dial.sh --status          看链路状态（不需要 root）
  sudo ./5-ppp-dial.sh --down       断开本机链路（蜂窝 PDP 不断，下次秒复用）
  sudo ./5-ppp-dial.sh --recover    先重枚举 USB（基本用不上，卡死还是得拔插）
  sudo ./5-ppp-dial.sh 3gnet        指定 APN（联通 3gnet / 移动 cmnet / 电信 ctnet）
USAGE
      exit 0 ;;
    PDP_TYPE=*) PDP_TYPE="${a#PDP_TYPE=}" ;;
    *) APN="$a" ;;
  esac
done

# ---- --status：不需要 root ----
if [ "$MODE" = status ]; then
  pid_of() { ioreg -w0 -r -n "HUAWEI Mobile" 2>/dev/null | grep -q "\"idProduct\" = $1"; }
  if pid_of 5382; then echo "  设备：12d1:1506（modem 模式）"
  elif pid_of 5381; then echo "  设备：12d1:1505（零CD，kext 应会自动切）"
  else echo "  设备：没看到 HUAWEI Mobile"; fi

  if ifconfig ppp0 >/dev/null 2>&1; then
    echo "  ppp0：$(ifconfig ppp0 | awk '/inet /{print $2" --> "$4}')  MTU $(ifconfig ppp0 | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1); exit}')"
    echo "  默认路由：$(netstat -rn -f inet 2>/dev/null | awk '/^default/{print $2" ("$4")"; exit}')"
    echo "  DNS：$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
    printf "  出口 IP（直连）："
    curl -m 8 -s -4 https://ifconfig.me/ip 2>/dev/null || printf "（取不到，链路可能不通）"
    echo
  else
    echo "  ppp0：未连接（拨号：sudo ./5-ppp-dial.sh）"
    # 顺手报告 modem 现在是什么态：决定下次拨号是「重新 ATD」还是「复用旧会话」
    if [ -x "$TOOLS/e398_at" ]; then
      STATE_HEX=$("$TOOLS/e398_at" --iface 0 --cmd AT --wait 1200 --hex 2>/dev/null)
      if printf '%s' "$STATE_HEX" | grep -q "4f 4b"; then
        echo "  modem：命令态（AT 正常）→ 下次拨号会重新 ATD"
      elif printf '%s' "$STATE_HEX" | grep -qE "7e ff|7e c0 21"; then
        echo "  modem：数据态（上次的 PDP 还挂着）→ 下次拨号会复用它，2~3 秒就通"
      elif printf '%s' "$STATE_HEX" | grep -q "无响应"; then
        echo -e "  modem：${Y}if0 无响应${N} → 可能真卡死了，拔插一次再试"
      fi
    fi
  fi
  S_EN=$(scutil --proxy 2>/dev/null | awk '/SOCKSEnable/{print $3; exit}')
  S_H=$(scutil --proxy 2>/dev/null | awk '/SOCKSProxy/{print $3; exit}')
  S_P=$(scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')
  printf "  系统代理："
  if [ -z "$S_P" ]; then
    echo "无（读系统代理的 App 会直连；修复：sudo ./11-proxy-fix.sh apply）"
  elif [ "${S_EN:-0}" = "1" ]; then
    echo "SOCKS ${S_H}:${S_P} 已启用"
  else
    echo "SOCKS ${S_H}:${S_P} 存在但 SOCKSEnable=${S_EN} → App 仍当没有代理"
    echo "            修复：sudo ./11-proxy-fix.sh install    （装看护，被 configd 重算掉会写回）"
  fi
  if [ -x "$TOOLS/e398_probe" ]; then
    if ifconfig utun233 >/dev/null 2>&1; then
      echo -e "  TUN：${G}utun233 已接管${N}（./14-tun.sh status）→ 全局走代理，上面那条系统代理不用管了"
    else
    P1=$("$TOOLS/e398_probe" 2>/dev/null | tr -d '\n')
    P2=$(curl -m 8 -s -4 https://ifconfig.me/ip 2>/dev/null)
    echo "  实测出口：CFNetwork ${P1:-失败} / 直连 ${P2:-失败}"
    if [ -n "$P1" ] && [ "$P1" != "$P2" ]; then
      echo -e "            ${G}✓ 两个不同 → 系统代理真的被 App 用上了${N}"
    else
      echo -e "            ${R}✗ 两个相同 → 请求没走代理（TUN：sudo ./14-tun.sh up）${N}"
    fi
    fi
  fi
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}需要 root：${N} sudo $0 ${APN:-}"
  exit 1
fi

# 工具没编译过就现场编（clang 是系统自带，不需要装 Xcode）
need_build() {
  local src="$1" out="$2"
  [ -x "$out" ] && [ "$out" -nt "$src" ] && return 0
  echo "  编译 $(basename "$out") ..."
  clang -O2 -Wno-deprecated-declarations -o "$out" "$src" \
        -framework IOKit -framework CoreFoundation || return 1
}
need_build "$TOOLS/e398_at.c"  "$TOOLS/e398_at"  || { echo "✗ e398_at 编译失败"; exit 1; }
need_build "$TOOLS/e398_ppp.c" "$TOOLS/e398_ppp" || { echo "✗ e398_ppp 编译失败"; exit 1; }

# ---- --down ----
if [ "$MODE" = down ]; then
  echo -e "${B}=== 断开 ===${N}"
  # 先停 pppd（它退出时会删掉 ppp0 和默认路由），再断开 USB 桥接
  pkill -f "pppd pty $PTY_CMD" 2>/dev/null && echo "  已停 pppd" || echo "  pppd 本来就没在跑"
  sleep 2
  pkill -f "e398_ppp --iface" 2>/dev/null && echo "  已停 USB 桥接" || true
  sleep 1
  if [ -x "$DIR/11-proxy-fix.sh" ]; then
    "$DIR/11-proxy-fix.sh" off >/dev/null 2>&1 && echo "  已清掉写进动态存储的代理"
  fi
  if ifconfig ppp0 >/dev/null 2>&1; then
    echo -e "  ${Y}ppp0 仍然存在${N}（pppd 还在收尾，几秒后再看：./5-ppp-dial.sh --status）"
  else
    echo -e "  ${G}✓ 本机链路已断开${N}"
  fi
  echo
  echo -e "  ${Y}注意：蜂窝侧的 PDP 会话通常不会跟着断${N}"
  echo "    ATD*99# 之后 if0 就是纯数据管道，modem 固件不认 +++ / ATH，"
  echo "    USB 重枚举、SetConfiguration(0→1)、USB 挂起也都拉不回来（都实测过）。"
  echo "    三种收尾方式，随便挑："
  echo "      1) 立刻 sudo $0 —— 复用这条会话，2~3 秒就通（不重新拨号，最省事）"
  echo "      2) 等 5~10 分钟 —— 没人应答对端的 LCP，它会自己放弃并拆掉 PDP，"
  echo "         届时 modem 自动回命令态（实测 AT+CGACT? 会变回 1,0）"
  echo "      3) 拔下 modem 等 5 秒再插回 —— 最干脆，kext 会自动切回 1506"
  if pgrep -f "sing-box run" >/dev/null 2>&1 || ifconfig utun233 >/dev/null 2>&1; then
    echo
    echo -e "  ${Y}TUN（utun233/sing-box）还开着${N}：ppp0 一断，全局流量就没出口了。"
    echo "    要么立刻 sudo $0 复连，要么先 sudo ./14-tun.sh down"
  fi
  exit 0
fi

# ---- 已经在线就别重复拨 ----
if ifconfig ppp0 2>/dev/null | grep -q "inet "; then
  echo -e "  ${G}✓ ppp0 已在线${N}：$(ifconfig ppp0 | awk '/inet /{print $2}')"
  echo "    查看：./5-ppp-dial.sh --status    断开：sudo ./5-ppp-dial.sh --down"
  exit 0
fi

# ---- --bg：转成一个脱离终端的子进程去真正拨号 ----
if [ "$BG" -eq 1 ]; then
  echo -e "${B}=== 后台拨号 ===${N}"
  : > "$PPP_OUT"
  # 子进程本身也是「拨通就退出」，pppd 由它 nohup 留在后台。这里只负责等结果。
  PDP_TYPE="${PDP_TYPE:-}" nohup "$DIR/5-ppp-dial.sh" ${APN:-} >> "$PPP_OUT" 2>&1 &
  echo "  子进程 PID $!，日志 $PPP_OUT"
  echo -n "  等待 ppp0 拿到地址"
  # 80 秒：子脚本自己最多等 75 秒，这里必须比它宽，否则会把「其实通了」判成失败
  for i in $(seq 1 80); do
    sleep 1
    printf "."
    if ifconfig ppp0 2>/dev/null | grep -q "inet "; then break; fi
  done
  echo
  if ifconfig ppp0 2>/dev/null | grep -q "inet "; then
    echo -e "  ${G}✓ 已连接${N}：$(ifconfig ppp0 | awk '/inet /{print $2" --> "$4}')"
    echo "    关掉这个终端也不会断。状态：./5-ppp-dial.sh --status"
  else
    echo -e "  ${R}✗ 80 秒内没拿到 IP${N}，看日志：tail -40 $PPP_OUT"
    echo "    日志里出现 'rcvd [LCP ConfReq' 但一直不 up → 对方在等下一条 ConfReq，多等几秒或者重跑"
    echo "    出现 'if0 既不回 AT，也没有 PPP 数据' → modem 真卡死，拔插一次"
  fi
  exit 0
fi

echo -e "${B}=== 1. 设备状态 ===${N}"
is_pid() { ioreg -w0 -r -n "HUAWEI Mobile" 2>/dev/null | grep -q "\"idProduct\" = $1"; }

if ! is_pid 5382 && is_pid 5381; then
  echo "  看到 12d1:1505（零CD）—— kext 的监视线程会在 1~2 秒内自动切过去，等它"
  for i in $(seq 1 25); do
    sleep 1
    if is_pid 5382; then break; fi
    printf "."
  done
  echo
fi

if ! is_pid 5382; then
  echo -e "  ${R}✗ 25 秒内没切到 12d1:1506${N}"
  if ! is_pid 5381; then
    echo "    连 1505 都看不到：modem 没插好"
  else
    echo "    还停在 1505（零CD）—— kext 的切换没做完。"
    echo
    # 现场证据：接口被谁占着 + 驱动自己的计数。
    OWN=$(ioreg -w0 -r -c IOUSBHostInterface -l 2>/dev/null \
          | grep -A40 '"USB Product Name" = "HUAWEI Mobile"' \
          | grep -m1 '"UsbExclusiveOwner"')
    [ -n "$OWN" ] && echo "    接口独占者：$OWN"
    echo "    kext 版本：  $(kmutil showloaded --list-only 2>/dev/null | grep -o 'local.e398.switcher ([0-9.]*)' | head -1)"
    # 1.7.0 起这些计数发布在 E398Loader 的 IORegistry 属性里
    # （ioreg 的属性行格式是 `"key" = value`，等号两边有空格）
    CNT=$(ioreg -r -n E398Loader -w0 2>/dev/null \
          | grep -o '"E398[A-Za-z0-9]*" = [-0-9]*' | sed 's/^/    /')
    [ -n "$CNT" ] && echo "$CNT" || echo "    （读不到 E398 计数 —— 驱动可能没加载）"
    echo
    echo "    判据："
    echo "     · E398Attempts 一直是 0 且没有心跳 → 切换线程根本没在跑"
    echo "     · E398Attempts 在涨但设备不动   → 报文发了但设备没理会，拔插一次"
    echo "     · E398Timeouts 在涨             → 报文提交后拿不到完成，设备半死，拔插"
    echo "     · 独占者是 E398Loader/Switcher 且版本 <= 1.6.0 → 两条路径互抢的老 bug"
    echo -e "       升级：${G}./build-kext.sh && sudo ./6-install-switcher.sh${N} 然后重启"
    echo
    echo "    临时救急：拔插 modem（5 秒）让它以新对象重新枚举。"
  fi
  exit 2
fi
echo -e "  ${G}✓${N} 12d1:1506 在线"

if [ "$RECOVER" -eq 1 ]; then
  echo -e "\n${B}=== 2. 复位 USB（等价于拔插一次）===${N}"
  "$TOOLS/e398_ppp" --reenum >/dev/null 2>&1
  # 重枚举之后设备会先掉线再回来，kext 的监视线程还要重新抢一次接口。
  # 原来固定 sleep 6 秒，在慢一点的情况下会误判成「没回来」——改成轮询。
  printf "  已重枚举，等设备回到 1506"
  OKDEV=0
  for i in $(seq 1 25); do
    sleep 1; printf "."
    if is_pid 5382; then OKDEV=1; break; fi
  done
  echo
  if [ "$OKDEV" -eq 1 ]; then
    echo -e "  ${G}✓${N} 12d1:1506 已回来"
  else
    echo -e "  ${Y}!${N} 25 秒内没看到 1506，照常往下试（AT 自检会告诉你真实状态）"
  fi
fi

echo -e "\n${B}=== 3. AT 口自检 ===${N}"
# 三种状态，决定后面走哪条路：
#   cmd   AT 回 OK                       → 正常路径：chat 发 ATD，重新拨号
#   data  if0 上在流 PPP 帧（7e ff 03…）  → 复用路径：不拨号，直接重新协商 LCP/IPCP
#   none  什么都不回                       → 真卡死，只能拔插
ATOUT=$("$TOOLS/e398_at" --iface "$IFACE" --cmd AT --wait 2000 --hex 2>&1)
if printf '%s' "$ATOUT" | grep -q "4f 4b"; then
  echo -e "  ${G}✓${N} if0 回 OK（AT 通道正常）"
elif printf '%s' "$ATOUT" | grep -qE "7e ff|7e c0 21"; then
  RESUME=1
  echo -e "  ${Y}!${N} if0 还在 PPP 数据态：AT 不通，但 PPP 帧还在流 → 上次的 PDP 会话没断"
  echo -e "    ${G}→ 不重新拨号，直接在这条会话上重开 pppd（走 LCP/IPCP 重新协商，几秒就通）${N}"
  echo "    实测结论（都试过了，别再试）：+++ / ATH / USBDeviceReEnumerate /"
  echo "    SetConfiguration(0→1) 都拉不回命令态，只有断电（拔插）才会真的断掉 PDP。"
else
  echo -e "  ${R}✗ if0 既不回 AT，也没有 PPP 数据${N}"
  echo "$ATOUT" | sed 's/^/    /'
  echo
  echo -e "  ${Y}这种情况 modem 真的卡住了，只能断电${N}："
  echo "    1) 把 modem 拔下来，等 5 秒，插回去（kext 会自动切到 1506）"
  echo "    2) 然后再 sudo $0 ${APN:-}"
  exit 3
fi

# ---- 等分组域注册 ----
# modem 刚从 1505 切到 1506（开机后 kext 自动切的）时，射频/SIM 栈还在初始化，
# 这时候立刻 ATD 很容易被网络侧用 NO CARRIER 顶回来。等 +CGREG 报 1/5 再拨。
if [ "$RESUME" -eq 0 ]; then
# ---- SIM / 信号预检 ----
# 这两项不通的话拨号必然失败，而现象是「NO CARRIER / IPCP 不动」，很容易被当成
# 驱动或脚本的锅。Linux 侧的华为 ppp 拨号脚本也是先 CPIN/CSQ 再发 ATD，顺序照抄。
echo -e "\n${B}=== 3a. SIM 与信号 ===${N}"
CPIN=$("$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CPIN?' --wait 1500 2>&1 | tr -d '\r')
if echo "$CPIN" | grep -q '+CPIN: READY'; then
  echo -e "  ${G}✓${N} SIM 就绪（+CPIN: READY）"
else
  echo -e "  ${R}✗ SIM 状态不对${N}：$(echo "$CPIN" | grep -o '+CPIN: [A-Z ]*' | head -1)"
  case "$CPIN" in
    *"SIM PIN"*)      echo "    卡设了 PIN，得先解锁（本脚本不解 PIN）" ;;
    *"NOT INSERTED"*) echo "    没插卡，或卡没接触好" ;;
    *"NOT READY"*)    echo "    卡还没初始化好，等几秒再跑一次" ;;
    *)                echo "    原始回显：$(echo "$CPIN" | tr '\n' ' ' | cut -c1-120)" ;;
  esac
  exit 4
fi
CSQ=$("$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CSQ' --wait 1500 2>&1 | tr -d '\r')
RS=$(echo "$CSQ" | grep -o '+CSQ: [0-9]*' | head -1 | awk '{print $2}')
case "$RS" in
  ""|99)
    echo -e "  ${Y}!${N} 信号读不到（+CSQ: ${RS:-?},99）→ 天线/位置问题，拨号大概率失败" ;;
  *)
    # 注意 10# ：AT 可能回 "+CSQ: 08,99"，直接做算术会被 bash 当八进制（08 非法）
    RSN=$((10#$RS))
    if [ "$RSN" -lt 8 ]; then
      echo -e "  ${Y}!${N} 信号偏弱（+CSQ: $RS ≈ $(( -113 + 2*RSN ))dBm）"
    else
      echo -e "  ${G}✓${N} 信号 +CSQ: $RS（≈ $(( -113 + 2*RSN ))dBm）"
    fi ;;
esac

echo -e "\n${B}=== 3b. 等分组域注册 ===${N}"
REG=0
for i in $(seq 1 15); do
  R=$("$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CGREG?' --wait 1200 2>&1 | tr -d '\r')
  if echo "$R" | grep -qE '\+CGREG: [0-9],[15]'; then REG=1; break; fi
  printf "."
  sleep 1
done
echo
if [ "$REG" = 1 ]; then
  echo -e "  ${G}✓${N} 已注册到分组域（$(echo "$R" | grep -o '+CGREG: [0-9],[0-9]*' | head -1)）"
else
  echo -e "  ${Y}!${N} 15 秒内没看到 +CGREG: 0,1 —— 继续尝试，被 NO CARRIER 顶回来的概率偏高"
fi

# ---- 确认 PS 域已附着 ----
# CGREG 只说明「注册上了」，个别网络还要 CGATT=1（附着）才允许激活 PDP，
# 否则 ATD 会在 PDP 激活那一步被顶回来。Linux 侧的华为 ppp 脚本也是这个顺序。
ATT=$("$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CGATT?' --wait 1200 2>&1 | tr -d '\r')
if echo "$ATT" | grep -q '+CGATT: 1'; then
  echo -e "  ${G}✓${N} PS 域已附着（+CGATT: 1）"
else
  echo -e "  ${Y}!${N} PS 域未附着（$(echo "$ATT" | grep -o '+CGATT: [0-9]' | head -1)）→ 尝试 AT+CGATT=1"
  "$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CGATT=1' --wait 4000 >/dev/null 2>&1
  sleep 2
fi

# ---- 清掉可能残留的 PDP 会话 ----
# 上一次拨号被中断（或机器直接重启）时，网络侧那条会话可能还挂着，再次激活会被
# 运营商用 NO CARRIER 顶回来。只在「真有一条 active 的会话」时才去拆，
# 无脑每次都发会让刚建好的上下文白掉一次，反而多一轮失败。
ACT=$("$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CGACT?' --wait 1200 2>&1 | tr -d '\r')
if echo "$ACT" | grep -q '+CGACT: 1,1'; then
  echo -e "  ${Y}!${N} 上一条 PDP 还激活着 → 先拆掉再拨（$(echo "$ACT" | grep -o '+CGACT: 1,1' | head -1)）"
  "$TOOLS/e398_at" --iface "$IFACE" --cmd 'AT+CGACT=0,1' --wait 2500 >/dev/null 2>&1
  sleep 2
else
  echo "  ✓ 没有残留的 PDP 会话，直接拨"
fi

# ---- APN ----
if [ -z "$APN" ]; then
  COPS=$("$TOOLS/e398_at" --iface "$IFACE" --cmd "AT+COPS?" --wait 2000 2>&1 | tr -d '\r')
  case "$COPS" in
    *CUGSM*|*UNICOM*|*CHN-CU*) APN=3gnet ;;
    *CMCC*|*CMNET*)            APN=cmnet ;;
    *CHN-CT*|*TELECOM*)        APN=ctnet ;;
    *)                          APN=3gnet ;;
  esac
  OP=$(echo "$COPS" | grep -o '"[^"]*"' | head -1)
  echo -e "\n${B}=== 4. APN ===${N}"
  echo -e "  运营商 ${OP:-未知} → APN ${G}$APN${N}（不对就 sudo $0 你的APN）"
else
  echo -e "\n${B}=== 4. APN ===${N}\n  指定为 ${G}$APN${N}"
fi
else
  echo -e "\n${B}=== 3b/4. 跳过注册检查与 APN（复用现有 PDP 会话）===${N}"
  echo "  这条会话的 APN/地址都是上次协商好的，重新发 ATD 反而会被顶回来，所以不拨号。"
fi

# ---- pppd 环境 ----
mkdir -p /etc/ppp /var/spool/lock
[ -f /etc/ppp/options ] || { echo "# created by E398 setup" > /etc/ppp/options; chmod 644 /etc/ppp/options; }

# 个别地区/套餐只认 IPv4v6 的 PDP，被 NO CARRIER 顶回来时可以试：
#   sudo ./5-ppp-dial.sh 3gnet PDP_TYPE=IPV4V6
PDP_TYPE="${PDP_TYPE:-IP}"

cat > "$CHAT_FILE" <<EOF
ABORT 'BUSY'
ABORT 'NO ANSWER'
ABORT 'NO CARRIER'
ABORT 'ERROR'
ABORT 'NO DIALTONE'
TIMEOUT 40
'' AT
OK ATE0
OK AT+CGDCONT=1,"$PDP_TYPE","$APN"
OK ATD*99***1#
CONNECT ''
EOF
chmod 600 "$CHAT_FILE"

echo -e "\n${B}=== 5. 启动 pppd ===${N}"
echo "  AT 通道日志：$PPP_LOG"
echo "  拨号脚本：  $CHAT_FILE"
echo

# ⚠ pppd 的 pty 选项是用 `sh -c "<字符串>"` 执行的，路径里一旦有空格
#   （例如 ~/My Projects/huawei-e398/...），整串直接塞进去会被空格切断，
#   报 `sh: /Users/you/My: No such file or directory`。
#   所以生成一个不含空格的小包装脚本，pty 只指向它。
cat > "$PTY_CMD" <<EOF
#!/bin/sh
exec "$TOOLS/e398_ppp" --iface $IFACE --log "$PPP_LOG"
EOF
chmod 755 "$PTY_CMD"

# 上一次残留的桥接进程会占着接口（USBInterfaceOpenSeize），先清掉
pkill -f "e398_ppp --iface" 2>/dev/null
sleep 1

echo -e "  拨通后 pppd 自动转后台，命令行立刻还给你（要断开：sudo $0 --down）"
echo -e "  想原样盯着 pppd 日志调试：加 --fg"
echo

# ppp0 一拿到地址就把系统代理补上，之后每 2 秒校验一次，被 configd 重算掉就写回。
# 为什么必须看护：macOS 的代理是按「网络服务」存的，ppp0 不是服务，configd 在 PPP
# 状态收敛时会把它算成 SOCKSEnable=0（第 1 版只写一次，就是这么失效的）。
PROXY_WATCH=""
if [ -x "$DIR/11-proxy-fix.sh" ]; then
  if launchctl print system/local.e398.proxy >/dev/null 2>&1; then
    echo -e "  ${G}✓${N} 代理看护已由 LaunchDaemon 负责（local.e398.proxy）"
  else
    (
      for i in $(seq 1 90); do
        ifconfig ppp0 2>/dev/null | grep -q "inet " && break
        sleep 1
      done
      exec "$DIR/11-proxy-fix.sh" watch
    ) >/dev/null 2>&1 &
    PROXY_WATCH=$!
    echo "  代理看护已启动（每 2 秒校验，日志 /tmp/e398-proxy.log）"
  fi
fi

RC=0
UP=0
: > "$PPP_PPPD"
PPPD_ARGS=(pty "$PTY_CMD"
  nodetach local debug noauth noipdefault usepeerdns defaultroute
  ipcp-accept-local ipcp-accept-remote
  noccp novj nopcomp noaccomp lcp-echo-interval 20 lcp-echo-failure 4)
if [ "$RESUME" -eq 1 ]; then
  # 复用路径：不发 ATD（一拨就会被运营商 NO CARRIER 顶回来），
  # 直接让 pppd 在这条还活着的管道上重开 LCP/IPCP。对方（GGSN）也正在等，
  # 实测它会把我们的 LCP ConfReq 直接 ConfAck。
  echo -e "${Y}  复用模式：不发 ATD，直接重新协商 PPP${N}"
else
  PPPD_ARGS+=(connect "/usr/sbin/chat -v -t 40 -f $CHAT_FILE")
fi

# ⚠ 这里不再把命令行卡住。
#   以前是「nodetach + 前台」，pppd 起来后必须有人 Ctrl+C 才回 shell，
#   连通了也像卡死（就是这次报的问题）。现在改成：
#     后台起 pppd → 本脚本盯着 pppd 日志和 ppp0 → 一通就打印结果并退出。
#   nohup 让它忽略 SIGHUP，关终端/退出脚本都不会把它带走；
#   nodetach 保留是为了「一个 pid 对应一个 pppd」，方便 kill -0 判断死活
#   （不带 nodetach 时 pppd 会自己 fork，$! 立刻失效）。
#   要老行为就加 --fg。
if [ "$FG" -eq 1 ]; then
  /usr/sbin/pppd "${PPPD_ARGS[@]}" 2>&1 | tee -a "$PPP_PPPD"
  RC=${PIPESTATUS[0]}
else
  nohup /usr/sbin/pppd "${PPPD_ARGS[@]}" >> "$PPP_PPPD" 2>&1 &
  PPPD_PID=$!
  LINES=0
  # 75 秒 = chat 的 40 秒超时 + 一轮 LCP/IPCP 重试；复用路径通常 2~3 秒就通
  DEADLINE=$((SECONDS + 75))
  while [ "$SECONDS" -lt "$DEADLINE" ]; do
    sleep 1
    # 增量打印（按行数取，只打整行，避免半行拼出乱码）
    if [ -s "$PPP_PPPD" ]; then
      TOTAL=$(wc -l < "$PPP_PPPD" 2>/dev/null | tr -d ' ')
      if [ "${TOTAL:-0}" -gt "$LINES" ]; then
        sed -n "$((LINES + 1)),${TOTAL}p" "$PPP_PPPD"
        LINES=$TOTAL
      fi
    fi
    if ifconfig ppp0 2>/dev/null | grep -q "inet "; then UP=1; break; fi
    kill -0 "$PPPD_PID" 2>/dev/null || break
  done
  # 收尾：把循环期间没来得及打出来的日志补上
  if [ -s "$PPP_PPPD" ]; then
    TOTAL=$(wc -l < "$PPP_PPPD" 2>/dev/null | tr -d ' ')
    if [ "${TOTAL:-0}" -gt "$LINES" ]; then
      sed -n "$((LINES + 1)),${TOTAL}p" "$PPP_PPPD"
    fi
  fi
  if [ "$UP" -ne 1 ]; then
    kill "$PPPD_PID" 2>/dev/null
    sleep 1
    kill -9 "$PPPD_PID" 2>/dev/null
    RC=1
  fi
fi

echo
if [ "$UP" -eq 1 ]; then
  echo -e "${B}=== 6. 拨通了，pppd 已在后台 ===${N}"
  LIP=$(ifconfig ppp0 | awk '/inet /{print $2}')
  RIP=$(ifconfig ppp0 | awk '/inet /{print $4}')
  MTU=$(ifconfig ppp0 | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1); exit}')
  echo -e "  ppp0：${G}${LIP} --> ${RIP}${N}   MTU ${MTU}"
  echo "  默认路由：$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  D1=$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')
  [ -n "$D1" ] && echo "  DNS：$D1"
  printf "  实测出口："
  EIP=$(curl -m 10 -s -4 https://ifconfig.me/ip 2>/dev/null)
  echo "${EIP:-（取不到，链路可能还没通，看 ./5-ppp-dial.sh --status）}"
  echo
  echo "  · 命令行已经还给你了，pppd 在后台跑，关掉终端也不会断"
  echo "  · 状态：./5-ppp-dial.sh --status     断开：sudo $0 --down"
  echo "  · 要全局走代理：sudo ./14-tun.sh up"
  echo "  · pppd 日志：$PPP_PPPD"
  exit 0
fi

echo -e "${B}=== 6. 没拨通（pppd 已退出/被停）===${N}"
echo "  —— USB 桥接日志最后 12 行 ——"
tail -12 "$PPP_LOG" 2>/dev/null | sed 's/^/    /'
echo "  —— pppd 日志最后 15 行 ——"
tail -15 "$PPP_PPPD" 2>/dev/null | sed 's/^/    /'
if [ "${RC:-0}" -ne 0 ]; then
  echo
  # 分类：这次到底是「运营商拒了呼叫」还是「数据没在 if0 上」还是「端口被占」
  # 注意：PPP 流里出现的 ASCII "NO CARRIER" 在 pppd 日志里是十六进制转义的一串
  #       `rcvd [proto=0xd] 0a 4e 4f 20 43 41 52 52 49 45 52 0d 0a`
  if grep -qi "NO CARRIER" "$PPP_PPPD" 2>/dev/null \
     || grep -q "4e 4f 20 43 41 52 52 49 45 52" "$PPP_PPPD" 2>/dev/null; then
    echo -e "  ${R}运营商拒绝了这次数据呼叫（NO CARRIER）${N}"
    echo "    这不是驱动/脚本的问题：AT 自检过了、LCP 也谈起来了，"
    echo "    是在 LCP 之后、IPCP 之前那一层（PDP 激活）被网络侧顶回来的。"
    echo "    常见原因：套餐流量用尽/停机欠费、该 APN 对本卡未开通、"
    echo "              同一账号的上一条会话还挂在网络侧、当前小区拒绝上网。"
    echo "    可以试："
    echo "      1) 等 10 秒重跑（脚本会先拆掉残留的 PDP 会话再拨）"
    echo "      2) 换 PDP 类型：sudo PDP_TYPE=IPV4V6 $0 ${APN}"
    echo "      3) 换 APN：联通 3gnet / uninet，移动 cmnet，电信 ctnet"
    echo "      4) 连试 3 次都一样 → 账号侧问题，找运营商客服"
    NEED_RETRY=1
  elif grep -q "0xe00002c5" "$PPP_LOG" 2>/dev/null; then
    echo -e "  ${Y}端口被别的进程占着（0xe00002c5）${N}"
    echo "    pkill -f e398_ppp 后重试"
  elif grep -q "0xe00002c0" "$PPP_LOG" 2>/dev/null; then
    echo -e "  ${Y}USB 接口在半路失效（0xe00002c0 = kIOReturnNoDevice）${N}"
    echo "    通常是呼叫被拒后 modem 自己复位了 USB。看上面有没有 NO CARRIER，"
    echo "    拔插一次 modem 也可以让它彻底干净地重来。"
  else
    echo -e "  ${Y}常见原因${N}"
    echo "    1) chat 里看到 CONNECT 但随后 LCP 超时 → 数据不在 if0 上：把 if0 换成 if4 试"
    echo "       编辑本脚本第 31 行 IFACE=0 → IFACE=4"
    echo "    2) ATD 返回 NO CARRIER / ERROR → SIM 欠费、PIN 未解或 APN 不对"
    echo "       ./tools/e398_at --iface 0 --cmd 'AT+CPIN?' --cmd 'AT+CSQ' 自己看一下"
  fi
  echo "    完整日志：$PPP_PPPD"
fi
echo
if [ "$RESUME" -eq 1 ] && [ "${RC:-0}" -ne 0 ]; then
  echo -e "  ${Y}复用这条旧会话没谈成${N}（上面 pppd 日志里 LCP 一直没到 up）。"
  echo "    modem 还卡在数据态。可以：拔插一次；或等几分钟让对端自己拆掉 PDP；"
  echo "    之后再 sudo $0 ${APN:-}"
else
  echo "  再拨一次：sudo $0 —— 脚本会先看 if0：AT 能通就重新 ATD，只有 PPP 帧就复用旧会话。"
  echo "  如果刚才已经发过 ATD，modem 会停在数据态：想立刻回命令态只能拔插一次。"
fi
if [ -n "$PROXY_WATCH" ]; then
  kill "$PROXY_WATCH" 2>/dev/null
  echo "  已停代理看护"
fi
# NO CARRIER 大多是瞬时拒绝（刚切完模式/上一条会话还没释放），自动再来一次。
# 只重试一次，避免在真的欠费时无限打转。
if [ "${NEED_RETRY:-0}" = 1 ] && [ "${E398_RETRY:-0}" != 1 ]; then
  echo
  echo -e "  ${Y}8 秒后自动重试一次${N}（NO CARRIER 是瞬时的概率很高）"
  sleep 8
  E398_RETRY=1 exec "$0" ${APN:-}
fi
echo "  完成。要再拨一次：sudo $0 ${APN}"
echo "  连上了但打不开网页？看 DNS：scutil --dns | head -20"
exit "${RC:-0}"
