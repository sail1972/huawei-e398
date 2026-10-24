#!/bin/bash
# 备选方案：PPP 拨号（当 NDIS 拨号不出接口时用）
# 用法： sudo ./4-ppp.sh [APN]
# 说明：macOS 15 仍带 PPP.kext / pppd / chat，这条路理论可行，
#       但 pppd 在最近的系统上属于“没人维护的老古董”，失败也正常，
#       真要用就退回 NDIS，或用虚拟机方案（见 README）。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
APN="${1:-cmnet}"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root： sudo $0 $APN"
  exit 1
fi

DEV=$(ls /dev/cu.*Modem* 2>/dev/null | head -1)
[ -z "$DEV" ] && DEV=$(ls /dev/cu.* 2>/dev/null | grep -iE "hua|hau" | head -1)
[ -z "$DEV" ] && { echo "✗ 找不到串口，驱动没生效"; exit 2; }

# pppd 默认要读 /etc/ppp/options，现代系统默认没这个文件
mkdir -p /etc/ppp
[ -f /etc/ppp/options ] || echo "# created by E398 setup" > /etc/ppp/options

echo "串口: $DEV    APN: $APN"
echo "按 Ctrl+C 断开"
echo

exec /usr/sbin/pppd "$DEV" 115200 \
  nodetach debug noauth noipdefault usepeerdns defaultroute \
  ipcp-accept-local ipcp-accept-remote \
  connect "/usr/sbin/chat -v -t 30 \
    '' AT \
    OK 'AT+CGDCONT=1,\"IP\",\"$APN\"' \
    OK 'ATD*99***1#' \
    CONNECT"
