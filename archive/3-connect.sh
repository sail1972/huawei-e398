#!/bin/bash
# 第 3 步：拨号上网（NDIS 方式，E398 走的是这条）
# 用法： ./3-connect.sh [APN]
#   APN 不填默认 cmnet（移动）。联通用 3gnet，电信用 ctnet，物联网卡按运营商给的填。
# 需要能看到 /dev/cu.HUAWEIMobile-Pcui，也就是第 2 步驱动已生效。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
AT="$DIR/tools/at.py"
APN="${1:-cmnet}"

PCUI=$(ls /dev/cu.*Pcui* 2>/dev/null | head -1)
[ -z "$PCUI" ] && PCUI=$(ls /dev/cu.* 2>/dev/null | grep -iE "hua|hau" | head -1)

if [ -z "$PCUI" ]; then
  echo "✗ 找不到华为串口。先确认："
  echo "   ./status.sh 里“驱动”和“串口”两栏是否正常"
  exit 2
fi
echo "使用串口：$PCUI     APN：$APN"
echo

echo "--- 1. 探测模块 ---"
python3 "$AT" "$PCUI" "AT"      || exit 3
python3 "$AT" "$PCUI" "ATI"
python3 "$AT" "$PCUI" "AT+CGSN"
echo
echo "--- 2. SIM 状态 ---"
python3 "$AT" "$PCUI" "AT+CPIN?"
python3 "$AT" "$PCUI" "AT+CSQ"
echo
echo "--- 3. 设置 APN 并拨号 ---"
python3 "$AT" "$PCUI" "AT+CGDCONT=1,\"IP\",\"$APN\""
python3 "$AT" "$PCUI" "AT^NDISDUP=1,1,\"$APN\""

echo
echo "--- 4. 等待数据接口 ---"
IF=""
for i in $(seq 1 15); do
  sleep 2
  IF=$(networksetup -listallhardwareports 2>/dev/null | grep -A2 -i huawei | awk '/Device:/{print $2; exit}')
  [ -n "$IF" ] && break
done

if [ -z "$IF" ]; then
  echo "✗ 没有出现 Huawei 网络接口。"
  echo "  可能这个固件不走 NDIS，改用 PPP： sudo ./4-ppp.sh $APN"
  exit 4
fi
echo "✓ 数据接口：$IF"

for i in $(seq 1 10); do
  IP=$(ipconfig getifaddr "$IF" 2>/dev/null)
  [ -n "$IP" ] && break
  sleep 2
done

if [ -z "${IP:-}" ]; then
  echo "→ 没有自动拿到 IP，手动要一次 DHCP"
  sudo ipconfig set "$IF" DHCP
  sleep 4
  IP=$(ipconfig getifaddr "$IF" 2>/dev/null)
fi

echo
if [ -n "${IP:-}" ]; then
  echo "================ 已连接 ================"
  echo "  接口: $IF"
  echo "  IP  : $IP"
  echo "  网关: $(ipconfig getoption "$IF" router 2>/dev/null)"
  echo "  DNS : $(ipconfig getoption "$IF" domain_name_server 2>/dev/null)"
  echo
  curl -s -m 8 -o /dev/null -w "  连通性测试: HTTP %{http_code}\n" https://www.baidu.com || true
  echo
  echo "  断开： python3 $AT $PCUI 'AT^NDISDUP=0,1'"
else
  echo "✗ 接口存在但没拿到 IP。检查：SIM 是否欠费/未激活、APN 是否正确、信号 AT+CSQ 是否 >10"
fi
