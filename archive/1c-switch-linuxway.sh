#!/bin/bash
#
# 1c-switch-linuxway.sh — 完全按 Linux usb_modeswitch 的两步法切换 E398
#
#   Linux                          macOS 等价物
#   ---------------------------    --------------------------------------
#   libusb_detach_kernel_driver    kextunload IOUSBMassStorageDriver
#   往 bulk OUT 写 MessageContent   往 bulk OUT 写同样 31 字节
#   usb_modeswitch 轮询 TargetID   轮询 12d1:1506 是否出现
#
# 需要 root。会临时卸载系统 USB 存储驱动（几秒后自动装回），
# 期间其它 U 盘/读卡器会掉线，所以先拔掉它们。
#
set -u
cd "$(dirname "$0")" || exit 1

BUNDLE="com.apple.iokit.IOUSBMassStorageDriver"
TOOL="./tools/e398_bulk"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'

pid_state() {
  local out
  out=$(./tools/e398_ctrl --probe 2>/dev/null)
  if echo "$out" | grep -q "1506 (modem): 在"; then echo 1506
  elif echo "$out" | grep -q "1505 (零CD) : 在"; then echo 1505
  else echo none; fi
}

echo "=== 切换前 ==="
ST=$(pid_state)
case "$ST" in
  1506) echo "${GRN}设备已经在 1506（modem 模式），不需要切换${RST}"; exit 0 ;;
  1505) echo "当前 12d1:1505（零 CD 模式）" ;;
  *)    echo "${RED}没找到 12d1:1505，请确认 modem 已插好${RST}"; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo
  echo "${YEL}这一步需要 root（要卸载内核扩展），请用 sudo 运行：${RST}"
  echo "  sudo $0"
  exit 1
fi

[ -x "$TOOL" ] || { echo "${RED}缺少 $TOOL${RST}"; exit 1; }

echo
echo "=== 前置检查：该驱动能否卸载 ==="
if strings -a /System/Library/KernelCollections/BootKernelExtensions.kc 2>/dev/null \
     | grep -q "com.apple.iokit.IOUSBMassStorageDriver"; then
  echo "${RED}[x] IOUSBMassStorageDriver 位于启动内核集合（BootKernelExtensions.kc）${RST}"
  echo "    从 Big Sur 起，启动内核集合里的驱动【运行时不可卸载】，"
  echo "    与是否有别的 U 盘占用无关。这条路走不通。"
  echo
  echo "    请改用：${GRN}sudo ./5-block-and-switch.sh${RST}"
  echo "    （用一个高优先级的占位 kext 抢在苹果 nub 之前占住接口）"
  exit 3
fi

echo
echo "=== 卸载 IOUSBMassStorageDriver（等价于 Linux 的 detach usb-storage）==="
UNLOADED=0
if kmutil unload -b "$BUNDLE" 2>/dev/null; then
  UNLOADED=1
elif kextunload -b "$BUNDLE" 2>/dev/null; then
  UNLOADED=1
fi

if [ "$UNLOADED" -eq 0 ]; then
  echo "${RED}[x] 卸载失败：驱动仍被占用${RST}"
  echo "    请拔掉其它 USB 存储设备后重试；"
  echo "    或重启一次（重启后立刻插 modem 再跑本脚本，成功率高得多）。"
  exit 2
fi
echo "${GRN}[+] 驱动已卸载${RST}"

# 无论后面发生什么，都要把驱动装回去
restore_driver() {
  echo
  echo "=== 恢复 IOUSBMassStorageDriver ==="
  if kmutil load -b "$BUNDLE" 2>/dev/null || kextload "/System/Library/Extensions/IOUSBMassStorageDriver.kext" 2>/dev/null; then
    echo "${GRN}[+] 已装回${RST}"
  else
    echo "${YEL}[!] 自动装回失败，执行下面任一命令即可恢复：${RST}"
    echo "      sudo kmutil load -b $BUNDLE"
    echo "      sudo kextload /System/Library/Extensions/IOUSBMassStorageDriver.kext"
  fi
}
trap restore_driver EXIT INT TERM

echo
echo "=== 抢占接口并发送切换报文（等价于 usb_modeswitch 的 MessageContent）==="
"$TOOL" --direct
SRC=$?

echo
echo "=== 结果 ==="
case $(pid_state) in
  1506)
    echo "${GRN}✓ 切换成功：设备现在报告 12d1:1506${RST}"
    echo "  下一步：sudo ./2-install-driver.sh 装上官方 kext，然后 ./status.sh 看串口。"
    ;;
  1505)
    echo "${RED}✗ 设备仍在 1505${RST}"
    echo "  这个固件可能被锁死在纯光盘模式。建议："
    echo "   1) 拔插一次 modem，再跑 ./status.sh 看 PID"
    echo "   2) 仍不行则用 VMware Fusion / Parallels 把设备整个交给 Linux 虚拟机"
    ;;
  *)
    echo "${YEL}设备暂时从总线上消失了（正在重枚举），等 5 秒后再看：${RST}"
    sleep 5
    echo "  现在状态: $(pid_state)"
    ;;
esac

exit $SRC
