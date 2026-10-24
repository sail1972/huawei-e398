#!/bin/bash
# 第 1 步：把 E398 从零CD模式(1505) 切到 modem 模式(1506)
# 需要 root： sudo ./1-switch-mode.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$DIR/tools/usb_switch_huawei"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root 权限，请这样运行："
  echo "    sudo $0"
  exit 1
fi

getpid() { system_profiler SPUSBDataType 2>/dev/null | awk '/HUAWEI/{f=1;next} f&&/Product ID:/{print $3;exit}'; }

PID_NOW="$(getpid)"
echo "当前 PID: ${PID_NOW:-未找到设备}"

if [ -z "$PID_NOW" ]; then
  echo "✗ 没检测到华为设备，先插好再试。"
  exit 2
fi

if [ "$PID_NOW" = "0x1506" ]; then
  echo "✓ 已经是 modem 模式，不用切换。直接跑第 2 步：sudo ./2-install-driver.sh"
  exit 0
fi

[ -x "$TOOL" ] || { echo "✗ 找不到 $TOOL"; exit 3; }

# 先把可能还挂着的虚拟光盘卸掉
for d in $(diskutil list 2>/dev/null | awk '/CD_partition_scheme/{print $NF}'); do
  diskutil eject "/dev/$d" >/dev/null 2>&1 && echo "已弹出虚拟光盘 $d"
done

echo
echo "→ 发送切换报文 ..."
"$TOOL" 1505
RC=$?

echo
echo "→ 等待重新枚举 ..."
for i in $(seq 1 12); do
  sleep 1
  P="$(getpid)"
  if [ "$P" = "0x1506" ]; then
    echo "✓ 切换成功！现在是 12d1:1506 (modem 模式)"
    exit 0
  fi
done

echo "✗ 还是 ${P:-未找到}，没切过去。"
echo
echo "请试这两招（按顺序）："
echo "  1) 把 modem 拔下来，等 3 秒再插回去，然后运行 ./status.sh 看 PID"
echo "     （很多 E398 在弹出光盘后，靠一次拔插就固定进 1506）"
echo "  2) 若仍是 1505，再跑一次本脚本"
exit 4
