#!/bin/bash
#
# 14-tun.sh — 系统代理在 ppp0 上无效的替代方案：用 sing-box 做 TUN 前置
#
# 为什么放弃「系统代理」这条路（13-proxy-diag.sh 的实测结论）：
#   SOCKSEnable=1、SOCKS=127.0.0.1:1080、__SCOPED__ 里 ppp0 也在，但
#   CFNetwork 实测出口和直连一模一样 → macOS 15 的 CFNetwork 不会把系统代理
#   用在 ppp0（PPP 接口不是「网络服务」，代理是按服务存的）。
#
# 本脚本的做法（TUN 与系统代理完全无关，在 IP 层截流量）：
#
#   应用程序 ──► utun233 (TUN) ──► sing-box ──► SOCKS 127.0.0.1:1080 (xray)
#                                                     │
#                                          xray ──► SS 服务器 ──(bind ppp0)──► 互联网
#
#   关键点：xray 自己要出网的流量（到 SS 服务器、到国内 DNS）必须绕开 TUN，
#   否则 sing-box 又把它送回 1080，形成无限回环。这里用三层保险：
#     1) TUN 的 route_exclude_address 不含这些地址（不进 TUN）
#     2) 路由规则：process_name=xray → 直连（绑 ppp0）
#     3) 路由规则：目标 IP = SS 服务器/国内 DNS → 直连（绑 ppp0）
#
# 用法：
#   sudo ./14-tun.sh up       开 TUN（ppp0 没拨号会先自动拨号）
#   sudo ./14-tun.sh down     关 TUN，恢复原始路由
#   sudo ./14-tun.sh status   看状态（不需要 root）
#   sudo ./14-tun.sh gen      只生成配置并校验（不启动）
#   ./14-tun.sh probe         只检查环境（不需要 root）
#   sudo ./14-tun.sh log      看 sing-box 日志
#
DIR="$(cd "$(dirname "$0")" && pwd)"
V2N="$HOME/Library/Application Support/v2rayN"
CFG="$DIR/tools/singbox-tun.json"
LOG=/tmp/e398-tun.log
PIDF=/tmp/e398-tun.pid
IFACE_TUN=utun233
SOCKS_HOST=127.0.0.1
SOCKS_PORT=""
PPP_IF=ppp0

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
bad()  { printf "  ${R}✗${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }

# ---- 定位 v2rayN（脚本被 sudo 时 $HOME 变成 /var/root，要还原真用户的家目录）----
real_home() {
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
    h=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$h" ] && { echo "$h"; return; }
    echo "/Users/$SUDO_USER"; return
  fi
  echo "$HOME"
}
H="$(real_home)"
V2N="$H/Library/Application Support/v2rayN"
XRAY_CFG="$V2N/binConfigs/config.json"

find_singbox() {
  local c
  for c in "${SINGBOX:-}" "$V2N/bin/sing_box/sing-box" /usr/local/bin/sing-box /opt/homebrew/bin/sing-box; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
SB="$(find_singbox)"

# ---- 从 xray 的 config.json 里读出入站端口和出站目标（v2rayN 换节点后重跑 gen 即可跟上）----
read_stack() {
  [ -f "$XRAY_CFG" ] || { echo "MISSING"; return; }
  /usr/bin/python3 - "$XRAY_CFG" <<'PY'
import json,sys
try:
    c=json.load(open(sys.argv[1]))
except Exception as e:
    print("MISSING"); sys.exit()
port=1080; proto=""
for ib in c.get("inbounds",[]):
    if ib.get("protocol") in ("mixed","socks"):
        port=ib.get("port",port); proto=ib.get("protocol"); break
targets=[]; kind=""
for ob in c.get("outbounds",[]):
    p=ob.get("protocol","")
    if p in ("freedom","blackhole","dns"): continue
    kind=p; s=ob.get("settings",{}) or {}
    for key in ("vnext","servers"):
        for v in (s.get(key) or []):
            a=v.get("address")
            if a and a not in targets: targets.append(a)
    break
print("%d|%s|%s|%s"%(port,proto,kind,",".join(targets)))
PY
}

# 域名 → A 记录（多个来源兜底）
resolve_ip() {
  local h="$1" ips=""
  case "$h" in
    *[0-9].[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$h"; return 0 ;;
  esac
  ips=$(dscacheutil -q host -a name "$h" 2>/dev/null | awk '/^ip_address:/{print $2}')
  [ -z "$ips" ] && ips=$(host -t A "$h" 2>/dev/null | awk '/has address/{print $NF}')
  echo "$ips"
}

port_open() { nc -z -G 2 "$1" "$2" >/dev/null 2>&1; }

ppp_up() { ifconfig "$PPP_IF" 2>/dev/null | grep -q "inet "; }

# =====================================================================
# probe
# =====================================================================
do_probe() {
  echo -e "${B}=== 0. 环境 ===${N}"
  printf "  真实用户家目录：%s\n" "$H"
  if [ -n "$SB" ]; then ok "sing-box：$SB"; "$SB" version 2>/dev/null | head -1 | sed 's/^/      /'
  else bad "没找到 sing-box（设环境变量 SINGBOX=/path/to/sing-box）"; fi
  if [ -f "$XRAY_CFG" ]; then ok "v2rayN 配置：$XRAY_CFG"; else bad "找不到 $XRAY_CFG"; fi
  local stack port proto kind targets
  stack=$(read_stack)
  if [ "$stack" = "MISSING" ]; then bad "读不了 xray 配置"; return 1; fi
  IFS='|' read -r port proto kind targets <<< "$stack"
  SOCKS_PORT="$port"
  ok "入站：${proto:-?} ${SOCKS_HOST}:${SOCKS_PORT}    出站：${kind:-?} → ${targets:-?}"
  echo
  echo -e "${B}=== 1. 链路 ===${N}"
  if ppp_up; then
    ok "ppp0 在线：$(ifconfig $PPP_IF | awk '/inet /{print $2" --> "$4}')"
  else
    bad "ppp0 不在线（sudo ./5-ppp-dial.sh --bg）"
  fi
  if port_open "$SOCKS_HOST" "$SOCKS_PORT"; then ok "SOCKS ${SOCKS_PORT} 在听"
  else bad "SOCKS ${SOCKS_PORT} 没在听（v2rayN 没启动？）"; fi
  local ep ips=""
  IFS=',' read -ra eps <<< "$targets"
  for ep in "${eps[@]}"; do [ -n "$ep" ] && ips="$ips $(resolve_ip "$ep")"; done
  ok "出站服务器 IP：$(echo $ips | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  echo
  echo -e "${B}=== 2. 代理链路（经 ppp0）===${N}"
  local direct viaproxy
  direct=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
           curl -s -m 10 -4 --interface "$PPP_IF" https://ifconfig.me/ip 2>/dev/null)
  viaproxy=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
           curl -s -m 20 -x "socks5h://${SOCKS_HOST}:${SOCKS_PORT}" https://ifconfig.me/ip 2>/dev/null)
  printf "  直连（绑 ppp0）：%s\n" "${direct:-失败}"
  printf "  经 SOCKS：      %s\n" "${viaproxy:-失败}"
  if ! ppp_up; then
    warn "ppp0 没在线，这一节无法判定（先拨号再来）"
  elif [ -n "$direct" ] && [ -n "$viaproxy" ] && [ "$direct" != "$viaproxy" ]; then
    ok "代理链路可用 —— TUN 有东西可转发"
  else
    bad "代理链路本身不通，先解决 v2rayN/节点，再谈 TUN"
  fi
  echo
  echo -e "${B}=== 3. TUN 现状 ===${N}"
  if ifconfig "$IFACE_TUN" >/dev/null 2>&1; then ok "$IFACE_TUN 存在"
  else echo "  $IFACE_TUN 不存在（未开启）"; fi
  echo "  默认路由：$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  echo "  去 8.8.8.8 走：$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')"
}

# =====================================================================
# gen
# =====================================================================
do_gen() {
  local stack port proto kind targets
  stack=$(read_stack)
  if [ "$stack" = "MISSING" ]; then bad "读不了 $XRAY_CFG"; return 1; fi
  IFS='|' read -r port proto kind targets <<< "$stack"
  SOCKS_PORT="$port"

  # 出站服务器 IP（用于 route_exclude_address + 直连规则，防回环）
  local ep ips="" cidrs=""
  IFS=',' read -ra eps <<< "$targets"
  for ep in "${eps[@]}"; do
    [ -z "$ep" ] && continue
    for ip in $(resolve_ip "$ep"); do
      case " $ips " in *" $ip "*) ;; *) ips="$ips $ip"; cidrs="$cidrs\"$ip/32\", ";; esac
    done
  done
  ips=$(echo $ips | sed 's/^ *//;s/ *$//')
  if [ -z "$ips" ]; then bad "解析不出代理服务器 IP，不能防回环，放弃"; return 1; fi
  cidrs="${cidrs}\"119.29.29.29/32\", \"223.5.5.5/32\""

  mkdir -p "$DIR/tools"
  cat > "$CFG" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "udp",   "tag": "dns-cn",     "server": "119.29.29.29", "detour": "ppp-direct" },
      { "type": "https", "tag": "dns-remote", "server": "1.1.1.1",       "detour": "proxy" }
    ],
    "rules": [
      { "domain_suffix": [".cn"], "server": "dns-cn" },
      { "rule_set": ["geosite-cn"], "server": "dns-cn" }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "$IFACE_TUN",
      "address": ["172.19.9.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 1400,
      "auto_route": true,
      "strict_route": false,
      "stack": "gvisor",
      "route_exclude_address": [ $cidrs ]
    }
  ],
  "outbounds": [
    { "type": "socks",  "tag": "proxy",      "server": "$SOCKS_HOST", "server_port": $SOCKS_PORT, "version": "5" },
    { "type": "direct", "tag": "ppp-direct", "bind_interface": "$PPP_IF" },
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block" }
  ],
  "route": {
    "rules": [
      { "process_name": ["xray"], "outbound": "ppp-direct" },
      { "ip_cidr": [ $cidrs ], "outbound": "ppp-direct" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "action": "sniff" }
    ],
    "rule_set": [
      { "type": "local", "tag": "geosite-cn", "format": "binary",
        "path": "$V2N/bin/srss/geosite-cn.srs" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-cn"
  }
}
EOF
  chmod 644 "$CFG"
  ok "配置已生成：$CFG"
  echo "     出站 ${kind} → ${targets}（IP：${ips}）"
  echo "     SOCKS ${SOCKS_HOST}:${SOCKS_PORT}    防回环 CIDR：${cidrs}"
  [ -n "$SB" ] || { bad "没有 sing-box，跳过校验"; return 1; }
  local out
  out=$("$SB" check -c "$CFG" 2>&1)
  if [ -z "$out" ]; then ok "sing-box check 通过"; else bad "sing-box check 报错："; echo "$out" | sed 's/^/      /'; return 1; fi
}

# =====================================================================
# down
# =====================================================================
do_down() {
  echo -e "${B}=== 关 TUN ===${N}"
  local pid=""
  [ -f "$PIDF" ] && pid=$(cat "$PIDF" 2>/dev/null)
  [ -z "$pid" ] && pid=$(pgrep -f "sing-box run -c $CFG" 2>/dev/null | head -1)
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null && echo "  已发 TERM 给 $pid"
    for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; kill -0 "$pid" 2>/dev/null || break; done
    kill -9 "$pid" 2>/dev/null
  else
    echo "  sing-box 没在跑"
  fi
  pkill -f "sing-box run -c $CFG" 2>/dev/null
  rm -f "$PIDF"
  sleep 1
  # 兜底：sing-box 被 -9 杀掉时路由会留在表里（0/1 + 128/1 指向 utun），网就断了
  if netstat -rn -f inet 2>/dev/null | grep -q "$IFACE_TUN"; then
    warn "IPv4 残留路由指向 $IFACE_TUN，清理中"
    route delete -net 0.0.0.0/1       >/dev/null 2>&1
    route delete -net 128.0.0.0/1     >/dev/null 2>&1
  fi
  if netstat -rn -f inet6 2>/dev/null | grep -q "$IFACE_TUN"; then
    warn "IPv6 残留路由指向 $IFACE_TUN，清理中"
    route delete -inet6 -net ::/1     >/dev/null 2>&1
    route delete -inet6 -net 8000::/1 >/dev/null 2>&1
  fi
  echo "  默认路由：$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  echo "  去 8.8.8.8 走：$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')"
  ok "已关闭"
}

# =====================================================================
# up
# =====================================================================
do_up() {
  echo -e "${B}=== 1. 前置检查 ===${N}"
  [ -n "$SB" ] || { bad "没找到 sing-box"; exit 1; }
  ok "sing-box $("$SB" version 2>/dev/null | head -1 | awk '{print $3}')"

  local stack port
  stack=$(read_stack)
  [ "$stack" = "MISSING" ] && { bad "读不了 xray 配置 $XRAY_CFG（v2rayN 是不是没启动过？）"; exit 2; }
  IFS='|' read -r port proto kind targets <<< "$stack"
  SOCKS_PORT="${port:-1080}"
  if ! port_open "$SOCKS_HOST" "$SOCKS_PORT"; then
    bad "SOCKS ${SOCKS_PORT} 没在听 → 先把 v2rayN 启动起来（它是 xray 的宿主）"
    exit 2
  fi
  ok "SOCKS ${SOCKS_HOST}:${SOCKS_PORT} 在听"

  if ! ppp_up; then
    warn "ppp0 没在线，先拨号"
    "$DIR/5-ppp-dial.sh" --bg
    # --bg 会等自己那套流程跑完（最多 80 秒），这里再兜一层，防止刚好卡在边界
    if ! ppp_up; then
      printf "  再多等 30 秒"
      local i
      for i in $(seq 1 15); do sleep 2; printf "."; ppp_up && break; done
      echo
    fi
  fi
  ppp_up || {
    bad "ppp0 没起来，TUN 开不了（别急，链路问题，跟 TUN 无关）"
    echo "    拨号日志：tail -40 /tmp/e398-pppd.out"
    if grep -qi "NO CARRIER" /tmp/e398-pppd.log 2>/dev/null; then
      echo -e "    ${Y}日志里是 NO CARRIER${N}：运营商拒了这次数据呼叫（套餐用尽/APN 未开通/"
      echo "      上一条会话还挂着）。脚本已自动清会话，直接重跑本命令即可；"
      echo "      还不行试：sudo PDP_TYPE=IPV4V6 ./5-ppp-dial.sh"
    fi
    exit 3
  }
  ok "ppp0 $(ifconfig $PPP_IF | awk '/inet /{print $2" --> "$4}')"

  local base
  base=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
         curl -s -m 10 -4 --interface $PPP_IF https://ifconfig.me/ip 2>/dev/null)
  echo "  直连出口（走 ppp0）：${base:-失败}"

  echo
  echo -e "${B}=== 2. 生成配置 ===${N}"
  do_gen || exit 4

  echo
  echo -e "${B}=== 3. 启动 sing-box ===${N}"
  do_down >/dev/null 2>&1
  : > "$LOG"
  nohup "$SB" run -c "$CFG" >> "$LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDF"
  echo "  PID $pid，日志 $LOG"
  printf "  等 $IFACE_TUN 接管去 8.8.8.8 的路"
  local i up=0 via=""
  for i in $(seq 1 20); do
    sleep 0.5; printf "."
    if ifconfig "$IFACE_TUN" >/dev/null 2>&1; then
      via=$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')
      [ "$via" = "$IFACE_TUN" ] && { up=1; break; }
    fi
  done
  echo
  if [ "$up" -ne 1 ]; then
    bad "10 秒内 TUN 没接管流量（去 8.8.8.8 走的是 ${via:-?}）"
    tail -25 "$LOG" | sed 's/^/    /'
    do_down >/dev/null 2>&1
    exit 5
  fi
  ok "去 8.8.8.8 已经走 $IFACE_TUN"

  echo
  echo -e "${B}=== 4. 验证 ===${N}"
  local ip https
  ip=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
       curl -s -m 12 -4 https://ifconfig.me/ip 2>/dev/null)
  printf "  不设任何代理的 curl 出口：%s\n" "${ip:-失败}"
  https=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
       curl -s -o /dev/null -w '%{http_code}' -m 15 https://www.google.com 2>/dev/null)
  printf "  https://www.google.com → HTTP %s\n" "${https:-失败}"
  echo "  DNS（经 TUN 劫持后解析）："
  dscacheutil -q host -a name www.apple.com 2>/dev/null | awk '/ip_address/{print "    "$2}' | head -2

  if [ -n "$ip" ] && [ "$ip" != "$base" ]; then
    ok "出口已变成 $ip（≠ 直连 $base）→ 全局流量走代理了"
    echo
    echo -e "${B}=== 5. 说明 ===${N}"
    echo "  · 现在所有 App 都走代理，与系统代理设置无关（系统代理可以关掉，不影响）"
    echo "  · 关掉：sudo $0 down      看日志：sudo $0 log      状态：$0 status"
    echo "  · 链路断了先确认 ppp0：./5-ppp-dial.sh --status"
    exit 0
  else
    bad "出口没变（${ip:-失败}），TUN 可能没生效"
    echo "  —— sing-box 日志最后 30 行 ——"
    tail -30 "$LOG" | sed 's/^/    /'
    warn "已自动回滚，网络恢复原状"
    do_down >/dev/null 2>&1
    exit 6
  fi
}

# =====================================================================
# status
# =====================================================================
do_status() {
  local stack port
  stack=$(read_stack); IFS='|' read -r port proto kind targets <<< "$stack"
  SOCKS_PORT="${port:-1080}"
  echo -e "${B}=== TUN 状态 ===${N}"
  # 注意：进程是 root 起的，普通用户 `kill -0` 会返回 EPERM，
  # 不能用它判活（旧版就是这么误报「非本脚本启动」的），只认 pgrep。
  local pid="" running=""
  running=$(pgrep -f "sing-box run -c $CFG" 2>/dev/null | head -1)
  [ -f "$PIDF" ] && pid=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$running" ]; then
    if [ "$running" = "$pid" ]; then ok "sing-box 在跑（PID $running，本脚本启动）"
    else ok "sing-box 在跑（PID $running）"; fi
  else
    echo "  sing-box 没在跑"
    [ -n "$pid" ] && echo "    （pidfile 记的 $pid 已退出）"
  fi
  if ifconfig "$IFACE_TUN" >/dev/null 2>&1; then ok "$IFACE_TUN 存在"; else echo "  $IFACE_TUN 不存在"; fi
  echo "  默认路由：$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  echo "  去 8.8.8.8 走：$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')"
  ppp_up && echo "  ppp0：$(ifconfig $PPP_IF | awk '/inet /{print $2" --> "$4}')" || echo "  ppp0：未连接"
  if port_open "$SOCKS_HOST" "$SOCKS_PORT"; then echo "  SOCKS ${SOCKS_PORT}：在听"; else echo "  SOCKS ${SOCKS_PORT}：没在听"; fi
  printf "  实测出口："
  local ip
  ip=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
       curl -s -m 10 -4 https://ifconfig.me/ip 2>/dev/null)
  echo "${ip:-失败}"
  local s_en s_port
  s_en=$(scutil --proxy 2>/dev/null | awk '/SOCKSEnable/{print $3; exit}')
  s_port=$(scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')
  echo "  系统代理：SOCKSEnable=${s_en:-?} port=${s_port:-?}（TUN 模式下可有可无）"
}

case "${1:-}" in
  probe)  do_probe ;;
  gen)    do_gen ;;
  up)     [ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo $0 up"; exit 1; }; do_up ;;
  down)   [ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo $0 down"; exit 1; }; do_down ;;
  status) do_status ;;
  log)    tail -${2:-40} "$LOG" 2>/dev/null || echo "没有日志 $LOG" ;;
  -h|--help|"")
    cat <<'USAGE'
14-tun.sh — 用 sing-box 做 TUN 前置（系统代理在 ppp0 上无效时的替代方案）

  sudo ./14-tun.sh up      开 TUN（ppp0 没在线会先自动拨号；失败会自动回滚）
  sudo ./14-tun.sh down    关 TUN，恢复原始路由
  ./14-tun.sh status       看状态（不需要 root）
  ./14-tun.sh probe        只体检，不改任何东西（不需要 root）
  sudo ./14-tun.sh gen     只生成并校验 tools/singbox-tun.json
  sudo ./14-tun.sh log 80  看 sing-box 日志

原理：TUN 在 IP 层截全部流量 → sing-box → SOCKS 127.0.0.1:1080（xray）→ 节点 → ppp0
     所以跟「系统代理」「网络服务」这些 macOS 概念彻底无关。
USAGE
    ;;
  *) bad "未知参数：$1（-h 看用法）"; exit 1 ;;
esac
