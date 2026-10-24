#!/bin/bash
# 第 1b 步（改良版）：切换 1505 → 1506
# 用法： sudo ./1b-switch-detach.sh
#
# 相比 1-switch-mode.sh，这里：
#   1) 用修好的工具（去掉了会触发驱动重新抢占的 SetConfiguration）
#   2) 如果还是抢不到接口，就临时卸载 IOUSBMassStorageDriver，切完再装回去
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$DIR/tools/usb_switch_huawei"
MSC="/System/Library/Extensions/IOUSBMassStorageDriver.kext"

[ "$(id -u)" -eq 0 ] || { echo "需要 root： sudo $0"; exit 1; }

getpid() { system_profiler SPUSBDataType 2>/dev/null | awk '/HUAWEI/{f=1;next} f&&/Product ID:/{print $3;exit}'; }

if [ "$(getpid)" = "0x1506" ]; then
  echo "✓ 已经是 1506，不用切。直接跑： sudo ./2-install-driver.sh"
  exit 0
fi

wait_switch() {
  for i in $(seq 1 10); do
    sleep 1
    if [ "$(getpid)" = "0x1506" ]; then return 0; fi
  done
  return 1
}

echo "===== 尝试一：直接抢接口（不重启驱动匹配）====="
"$TOOL" 1505
if wait_switch; then
  echo "✓ 切换成功：12d1:1506"
  exit 0
fi

echo
echo "===== 尝试二：临时卸载 USB 存储驱动后再切 ====="
echo "（这会短暂影响所有 U 盘/读卡器，切完立刻装回）"
if kextunload "$MSC" 2>/dev/null || kextunload -b com.apple.iokit.IOUSBMassStorageDriver 2>/dev/null; then
  echo "  存储驱动已卸载"
  sleep 1
  "$TOOL" 1505
  OK=0
  wait_switch && OK=1
  echo "  装回存储驱动 ..."
  kextload "$MSC" >/dev/null 2>&1 && echo "  已装回" || echo "  ⚠ 装回失败，重启会自动恢复"
  if [ "$OK" = "1" ]; then
    echo "✓ 切换成功：12d1:1506"
    exit 0
  fi
else
  echo "  ⚠ 存储驱动卸不掉（正被其他 USB 存储设备占用）。"
  echo "    先把 U 盘/读卡器/移动硬盘都拔掉，再跑一次本脚本。"
fi

echo
CUR="$(getpid)"
echo "✗ 仍然停在 ${CUR:-未知}"
cat <<'EOF'

最后两招（按顺序）：

  1) 物理拔插：把 modem 拔下，等 3 秒插回，然后：
        ./status.sh
     看 PID 是否变成 0x1506。部分 E398 固件在光盘被弹出过一次之后，
     重新上电就直接进 modem 模式。

  2) 如果还是 1505，说明这个固件的端口配置被锁成"纯光盘"了（AT^SETPORT 限制），
     macOS 这边没有可用的 AT 口去改它 —— 直接走 README 里的虚拟机方案，
     那条路是确定能通的。
EOF
exit 4
