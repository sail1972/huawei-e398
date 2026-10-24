#!/bin/bash
#
# 13-proxy-diag.sh — 判定「ppp0 起来后系统代理到底卡在哪一环」
#
# 背景：ppp0 在线时 scutil 里明明写着 SOCKS 127.0.0.1:1080 已启用，
#       但 CFNetwork（Chrome/Safari 读系统代理的同一条路径）实际走的是直连。
#       可能的原因只有三种，本脚本一次性区分：
#
#   A. 写进去的 __SCOPED__[ppp0] 被 configd 秒删 → 按接口查代理查不到
#   B. 字典一直是对的，但 CFNetwork 在 ppp0 上根本不认 SOCKS → 只能换机制
#   C. 应用只认 HTTP 代理（Chromium 系列对 SOCKS 支持很差） → 补 HTTP/HTTPS
#
# 用法（要 ppp0 在线、要 root）：
#   sudo ./13-proxy-diag.sh
#
# 它会临时停掉 11-proxy-fix.sh 的看护（否则每 2 秒重写会掩盖「被删」现象），
# 结束前自动恢复。
#
set -o pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$DIR/tools"
PSET="$TOOLS/e398_proxyset"
PROBE="$TOOLS/e398_probe"
LABEL=local.e398.proxy
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
# 别让外部 HTTP_PROXY 干扰「直连出口」的测量
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

[ "$(id -u)" -eq 0 ] || { echo -e "${R}需要 root：${N} sudo $0"; exit 1; }
if ! ifconfig ppp0 2>/dev/null | grep -q "inet "; then
  echo -e "${R}ppp0 没在线${N}，先拨号：sudo ./5-ppp-dial.sh --bg"
  exit 2
fi
for f in "$PSET" "$PROBE"; do
  [ -x "$f" ] || { echo -e "${R}缺 $f${N}，先跑一次 sudo ./11-proxy-fix.sh install"; exit 3; }
done

# TUN 生效时，这个脚本的判定前提就不成立了：CFNetwork 和 curl 都被 TUN 抓走，
# 出口必然一样，再跑下去只会得出「CFNetwork 仍走直连」的假结论。
if ifconfig utun233 >/dev/null 2>&1 || pgrep -f "sing-box run -c" >/dev/null 2>&1; then
  echo -e "${G}TUN 正在接管流量${N}（utun233 存在 / sing-box 在跑）"
  echo "  这种情况下「CFNetwork 出口」和「直连出口」必然相同 —— 两条路都经过 TUN，"
  echo "  本脚本的 A/B/C 判定没有意义，已跳过（不会改动任何代理设置）。"
  echo
  echo "  看现在到底走没走代理：./14-tun.sh status"
  exit 0
fi

PORT=$(scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')
PORT=${PORT:-1080}
HOST=127.0.0.1

# 看护会每 2 秒重写，先停掉，否则测不出「被删」
WAS_RUNNING=0
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  WAS_RUNNING=1
  launchctl bootout "system/$LABEL" >/dev/null 2>&1
  sleep 1
fi
restore() {
  if [ "$WAS_RUNNING" = 1 ] && [ -f "/Library/LaunchDaemons/$LABEL.plist" ]; then
    launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" >/dev/null 2>&1
  fi
}
trap restore EXIT

dump() {  # 一行摘要
  local d en hp pp hpe scoped
  d=$(scutil <<< "show State:/Network/Global/Proxies" 2>/dev/null)
  en=$(echo "$d" | awk '/SOCKSEnable/{print $3; exit}')
  hp=$(echo "$d" | awk '/SOCKSProxy/{print $3; exit}')
  pp=$(echo "$d" | awk '/SOCKSPort/{print $3; exit}')
  hpe=$(echo "$d" | awk '/HTTPEnable/{print $3; exit}')
  scoped=$(echo "$d" | awk '/__SCOPED__/{f=1;next} f&&/^    [a-z0-9]+ :/{gsub(/ :/,"");print $1}' | tr '\n' ' ')
  printf "SOCKSEnable=%-4s SOCKS=%s:%s HTTPEnable=%-4s __SCOPED__=[%s]\n" \
         "${en:-?}" "${hp:-?}" "${pp:-?}" "${hpe:-0}" "${scoped:-空}"
}

probe_line() {
  local conns before after
  before=$(lsof -nP -iTCP:$PORT 2>/dev/null | grep -c ESTABLISHED)
  printf "  CFNetwork 出口: %s" "$("$PROBE" 2>&1 | tr -d '\n')"
  sleep 1
  after=$(lsof -nP -iTCP:$PORT 2>/dev/null | grep -c ESTABLISHED)
  printf "   直连出口: %s" "$(curl -m 8 -s -4 https://ifconfig.me/ip 2>/dev/null)"
  echo "   $PORT 连接数 $before→$after"
}

echo -e "${B}=== 0. 前提 ===${N}"
echo -n "  基线："; dump
launchctl print "system/local.e398.proxy" >/dev/null 2>&1 && echo "  看护：已临时停止" || echo "  看护：未安装"

echo
echo -e "${B}=== 1. 基线（不做任何改动）===${N}"
probe_line

echo
echo -e "${B}=== 2. 只写 SOCKS（+__SCOPED__ 覆盖所有接口）===${N}"
"$PSET" set "$HOST" "$PORT" socks | sed 's/^/  /'
for t in 0.5 2 5; do
  sleep "$t"
  printf "  +%-3ss " "$t"; dump
done
probe_line

echo
echo -e "${B}=== 3. 再补 HTTP/HTTPS（1080 是 xray 的 mixed 入站，两种协议都吃）===${N}"
"$PSET" set "$HOST" "$PORT" | sed 's/^/  /'
for t in 0.5 3; do
  sleep "$t"
  printf "  +%-3ss " "$t"; dump
done
probe_line

echo
echo -e "${B}=== 4. 结论 ===${N}"
D=$(scutil <<< "show State:/Network/Global/Proxies" 2>/dev/null)
SCOPED_PPP=$(echo "$D" | awk '/^  __SCOPED__/{f=1} f&&/ppp0 :/{print "yes"; exit}')
EN=$(echo "$D" | awk '/SOCKSEnable/{print $3; exit}')
P1=$("$PROBE" 2>/dev/null | tr -d '\n')
P2=$(curl -m 8 -s -4 https://ifconfig.me/ip 2>/dev/null)
if [ -n "$P1" ] && [ "$P1" != "$P2" ]; then
  echo -e "  ${G}✓ 代理已生效${N}：CFNetwork=$P1，直连=$P2"
  echo "    现在这份配置能用了。让看护按这个保持："
  echo "      sudo ./11-proxy-fix.sh install $PORT"
elif [ -z "$SCOPED_PPP" ]; then
  echo -e "  ${R}✗ __SCOPED__ 里没有 ppp0${N}（SOCKSEnable=${EN:-?}）"
  echo "    → configd 把 ppp0 的按接口条目删掉了。这是「ppp0 不是网络服务」的直接后果，"
  echo "      只能绕开系统代理：v2rayN 开 TUN 模式（bin/sing-box 已随它安装）。"
else
  echo -e "  ${R}✗ ppp0 的 scoped 条目在、SOCKSEnable 也对，但 CFNetwork 仍走直连${N}"
  echo "    → macOS 15 的 CFNetwork 在 ppp0（PPP 接口）上不应用系统代理。"
  echo "      系统代理这条路到此为止，改用 TUN：v2rayN 里的 bin/sing-box 已在，"
  echo "      开「TUN 模式」即可（它在 IP 层截流量，不看系统代理）。"
fi
echo
echo "  端口连接数（若全程 0，说明没有任何程序连过代理）："
lsof -nP -iTCP:$PORT 2>/dev/null | grep ESTABLISHED | head -5 | sed 's/^/    /' || true
echo "  （探测结束，看护会自动恢复）"
