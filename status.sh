#!/bin/bash
# 一键体检：不需要 root
DIR="$(cd "$(dirname "$0")" && pwd)"
PID=$(system_profiler SPUSBDataType 2>/dev/null | awk '/HUAWEI/{f=1;next} f&&/Product ID:/{print $3;exit}')

echo "================ 系统 ================"
sw_vers | tr '\n' ' '; echo
echo "架构: $(uname -m)    SIP: $(csrutil status 2>/dev/null | sed 's/.*: //')"

echo
echo "================ 设备 ================"
if [ -z "$PID" ]; then
  echo "✗ 没找到华为设备（检查是否插好、换个 USB 口）"
else
  case "$PID" in
    0x1505) echo "PID: $PID  → 零CD/装机模式（还没切换，需要 sudo ./6-install-switcher.sh 然后重启）" ;;
    0x1506) echo "PID: $PID  → modem 模式 ✓" ;;
    *)      echo "PID: $PID  → 未知模式" ;;
  esac
  system_profiler SPUSBDataType 2>/dev/null | grep -A8 "HUAWEI" | sed 's/^ */    /'
fi

echo
echo "================ 串口 ================"
ls /dev/cu.* 2>/dev/null | grep -i -E "hua|hau|modem|usb" || echo "  （没有华为串口设备）"

echo
echo "================ 驱动 ================"
if kextstat 2>/dev/null | grep -qi huawei; then
  kextstat 2>/dev/null | grep -i huawei | awk '{print "  ✓ "$6"  ("$5")"}'
else
  echo "  ✗ 没有已加载的 Huawei kext"
fi

echo
echo "================ 网络接口 ================"
networksetup -listallhardwareports 2>/dev/null | grep -A2 -i huawei || echo "  （没有 Huawei 网络接口）"
echo
echo "有 IP 的接口:"
ifconfig 2>/dev/null | awk '/^[a-z]/{dev=substr($1,1,length($1)-1)} /inet /{print "    "dev" "$2}' | grep -v "127.0.0.1"
