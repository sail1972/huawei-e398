#!/bin/bash
#
# 5-block-and-switch.sh — 用专用 kext 占位，然后重放切换报文
#
# 为什么不用 kextunload：
#   IOUSBMassStorageDriver 在 /System/Library/KernelCollections/BootKernelExtensions.kc
#   里。从 Big Sur 起，启动内核集合中的驱动在运行时不可卸载，
#   所以 Linux 的「detach usb-storage」在 macOS 上没有对应操作。
#
# 本脚本改用一个 10 行的占位 kext：
#   IOProbeScore=10000，匹配 IOUSBHostInterface + 12d1:1505，
#   在苹果的 IOUSBMassStorageInterfaceNub（无 IOProbeScore，默认 0）之前胜出。
#   它不调用 interface->open()，所以不独占端点，用户态仍可 seize。
#
set -u
cd "$(dirname "$0")" || exit 1

KEXT="$(pwd)/kext/E398Blocker.kext"
BID="local.e398.blocker"
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

pid_state() {
  local out
  out=$(./tools/e398_ctrl --probe 2>/dev/null)
  if echo "$out" | grep -q "1506 (modem): 在"; then echo 1506
  elif echo "$out" | grep -q "1505 (零CD) : 在"; then echo 1505
  else echo none; fi
}

loaded() { kmutil showloaded --list-only 2>/dev/null | grep -q "$BID"; }

echo "=== 切换前 ==="
ST=$(pid_state)
case "$ST" in
  1506) echo "${GRN}已经在 1506，不需要切换${RST}"; exit 0 ;;
  1505) echo "当前 12d1:1505（零 CD 模式）" ;;
  *)    echo "${RED}没找到 12d1:1505${RST}"; exit 1 ;;
esac

[ -d "$KEXT" ] || { echo "${RED}缺少 $KEXT，先跑 ./build-kext.sh${RST}"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo; echo "${YEL}需要 root 来加载内核扩展：${RST}"; echo "  sudo $0"; exit 1
fi

cleanup() {
  if loaded; then
    echo
    echo "=== 卸载占位 kext ==="
    kmutil unload -b "$BID" 2>/dev/null && echo "${GRN}[+] 已卸载${RST}" || \
      echo "${YEL}[!] 卸载失败，可执行：sudo kmutil unload -b $BID${RST}"
  fi
}
trap cleanup EXIT INT TERM

echo
echo "=== 加载占位 kext（取代苹果的 mass-storage nub）==="
chown -R root:wheel "$KEXT" 2>/dev/null
chmod -R go-w "$KEXT" 2>/dev/null

OUT=$(kmutil load -p "$KEXT" -z -v 2>&1)
RC=$?
echo "$OUT" | sed 's/^/  /'
if [ $RC -ne 0 ] || ! loaded; then
  echo "${RED}[x] 加载失败${RST}"
  echo
  echo "  如果错误是签名/授权相关，说明这台 T2 机器只允许「已识别开发者」签名的 kext，"
  echo "  自建 kext 这条路就断了，只能走虚拟机方案。"
  echo "  如果错误是 already loaded，先执行：sudo kmutil unload -b $BID"
  exit 2
fi

if kmutil showloaded --list-only | grep -q "$BID"; then
  echo "${GRN}[+] kext 已加载${RST}"
fi

# 等苹果的 nub 让位
sleep 1
echo
echo "=== 确认接口已释放给用户态 ==="
if ioreg -w 0 -l -c E398Blocker 2>/dev/null | grep -q "E398Blocker"; then
  echo "${GRN}[+] E398Blocker 正占着 IOUSBHostInterface${RST}"
else
  echo "${YEL}[!] 没看到 E398Blocker 实例，可能没匹配上（检查 idProduct/IOProbeScore）${RST}"
fi

echo
echo "=== 重放 31 字节 UFI 切换报文 ==="
./tools/e398_bulk --direct --verbose
SRC=$?

echo
echo "=== 结果 ==="
sleep 2
case $(pid_state) in
  1506)
    echo "${GRN}✓ 切换成功：12d1:1506${RST}"
    echo "  下一步：sudo ./2-install-driver.sh"
    ;;
  1505)
    echo "${RED}✗ 仍是 1505${RST}"
    echo "  报文发出去了但设备没买账。可能这个固件的切换命令与官方配置不同，"
    echo "  把上面的 WritePipe 返回码发我。"
    ;;
  *)
    echo "${YEL}设备正在重枚举，等 5 秒${RST}"
    sleep 5
    echo "  现在: $(pid_state)"
    ;;
esac

exit $SRC
