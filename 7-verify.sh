#!/bin/bash
#
# 7-verify.sh — 重启后体检：驱动有没有真正载入、接口归谁、设备有没有切过去
# 不需要 root
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/kc-lib.sh
source "${DIR}/tools/kc-lib.sh"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
BID="local.e398.switcher"
AUXKC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"

echo -e "${B}=== 1. 内核扩展是否加载 ===${N}"

SHOW=$(kmutil showloaded --list-only 2>/dev/null | grep "$BID")
[ -n "$SHOW" ] && echo "$SHOW" | sed 's/^/  /'

# kmutil showloaded 只说明 kmod_info 登记过，不代表 kext 载入成功：
# kmod start 失败时它也照样列着（1.2.0 就是这样骗了所有人）。
# 真正的判据是内核日志没有 NULL/failed，并且 IORegistry 里有服务实例。
KMOD_ERR=$(kc_kmod_error)
SVC=0
kc_has_service && SVC=1

if [ -n "$KMOD_ERR" ]; then
  echo -e "  ${R}✗ kmod 层拒绝了载入${N}："
  echo "$KMOD_ERR" | tail -4 | sed 's/^/    /'
  LOADED=0; KMOD_FAIL=1
  if echo "$KMOD_ERR" | grep -q "NULL module start pointer"; then
    echo -e "    原因：_kmod_info.start 是 NULL → 装进集合的仍是旧版 kext（≤1.2.0）"
    echo -e "    解法：${G}./build-kext.sh && sudo ./6-install-switcher.sh${N}，然后重启"
  fi
elif [ "$SVC" -eq 1 ]; then
  echo -e "  ${G}✓ 已载入，内核里已有 E398 服务实例${N}"
  LOADED=1; KMOD_FAIL=0
elif [ -n "$SHOW" ]; then
  echo -e "  ${Y}⚠ kmutil 列着它，但内核里没有服务实例（假加载，见上面日志）${N}"
  LOADED=0; KMOD_FAIL=0
else
  echo -e "  ${R}✗ 没有加载${N}"
  LOADED=0; KMOD_FAIL=0
  # 区分"没进集合"和"进了集合但没加载"——这两种处理完全不同
  if [ -n "$(kc_aux_version "$BID")" ]; then
    VER=$(kc_aux_version "$BID")
    echo -e "  ${Y}集合里有它（v${VER}），但内核里没有${N}"
    BA=$(nvram boot-args 2>/dev/null | sed 's/.*boot-args[[:space:]]*//')
    if echo "$BA" | grep -q "amfi_get_out_of_my_way=1"; then
      echo -e "  AMFI 已关闭，所以不是签名问题 → 集合要开机才映射，重启一次"
    else
      echo -e "  ${R}AMFI 仍开启 → 这就是原因${N}：ad-hoc 签名被拒，集合里有也加载不进来"
      echo -e "  先执行： ${G}sudo ./12-amfi.sh on${N}  然后重启"
    fi
  else
    echo -e "  ${Y}集合里也没有 → 安装没成功，重跑 sudo ./6-install-switcher.sh${N}"
  fi
fi

echo
echo -e "${B}=== 2. 驱动内核日志（本次开机） ===${N}"
OUT=$(log show --last boot --predicate 'eventMessage CONTAINS "E398Switcher"' \
        --style compact 2>/dev/null | tail -10)
if [ -n "$OUT" ]; then
  echo "$OUT" | sed 's/^/  /'
else
  echo "  （没有 E398Switcher 的日志 = 驱动代码一行都没执行过）"
  sudo -n dmesg 2>/dev/null | grep -i "e398" | tail -8 | sed 's/^/  /'
fi

echo
echo -e "${B}=== 3. 设备当前 PID ===${N}"
PROBE=$("$DIR/tools/e398_ctrl" --probe 2>/dev/null)
echo "${PROBE:-  （读不到）}" | sed 's/^/  /'

echo
echo -e "${B}=== 4. 接口现在归谁 ===${N}"
echo "  华为接口的独占者（UsbExclusiveOwner）："
EXC=$(ioreg -w0 -r -c IOUSBHostInterface -l 2>/dev/null \
        | grep -A40 '"USB Product Name" = "HUAWEI Mobile"' \
        | grep -m1 '"UsbExclusiveOwner"')
if [ -n "$EXC" ]; then echo "    $EXC"; else echo "    （接口当前无人独占 —— 机会窗口）"; fi
printf "  E398Switcher 服务实例      : "
if kc_has_class E398Switcher; then
  echo "有（它已经抢到接口，正在发报文）"
else
  echo "无"
fi
printf "  mass-storage 接口 nub      : "
if kc_has_class IOUSBMassStorageInterfaceNub; then
  echo "在（接口被苹果存储驱动占着）"
else
  echo "不在（接口空闲）"
fi

echo
echo -e "${B}=== 5. AT 通道 / PPP ===${N}"
if [ -x "$(dirname "$0")/tools/e398_at" ]; then
  ATOUT=$("$(dirname "$0")/tools/e398_at" --iface 0 --cmd AT --wait 1500 2>&1)
  if echo "$ATOUT" | grep -q "OK"; then
    echo "  ✓ if0 AT 通道正常（用户态可直接访问，不需要任何串口驱动）"
  else
    echo "  ✗ if0 不响应 AT —— 大概率上一次拨号把它留在 PPP 数据态"
    echo "    拔插 modem（等 5 秒）后重试：sudo ./5-ppp-dial.sh"
  fi
fi
if ifconfig ppp0 >/dev/null 2>&1; then
  echo "  ✓ ppp0 存在：$(ifconfig ppp0 | grep -E "inet " | head -1 | tr -s ' ')"
else
  echo "  ppp0：未连接"
fi

echo
echo -e "${B}=== 结论 ===${N}"
if echo "$PROBE" | grep '1506' | grep -qE ': 在$'; then
  echo -e "  ${G}✓ 设备已切到 12d1:1506（modem 模式）${N}"
  echo
  echo "  下一步：直接拨号（用户态桥接 + pppd，不需要任何第三方 kext）"
  echo "      sudo ./5-ppp-dial.sh"
elif echo "$PROBE" | grep '1505' | grep -qE ': 在$'; then
  if [ "${KMOD_FAIL:-0}" -eq 1 ]; then
    echo -e "  ${R}✗ 还是 1505，因为 kext 根本没进内核${N}（kmod 层被拒，见第 1 节）"
    echo
    echo -e "  重编 + 重装： ${G}./build-kext.sh && sudo ./6-install-switcher.sh${N}"
    echo "  然后重启。新版会在第 5 节显示 _kmod_info 的 start 是否非空。"
  elif [ "${LOADED}" -eq 0 ]; then
    BA=$(nvram boot-args 2>/dev/null | sed 's/.*boot-args[[:space:]]*//')
    if echo "$BA" | grep -q "amfi_get_out_of_my_way=1"; then
      echo -e "  ${Y}⚠ 还是 1505，驱动也没加载${N}"
      echo
      echo "  按顺序："
      echo "   1) 重启一次（集合里已有 kext 与关闭 AMFI 的 boot-arg，开机生效）"
      echo "   2) 重启后仍 1505 → 拔插 modem 让它重新匹配"
      echo "   3) 仍不行 → sudo ./10-diag.sh 抓日志（会写成 diag-*.log）"
    else
      echo -e "  ${Y}⚠ 还是 1505，驱动没加载 —— 卡在签名${N}"
      echo
      echo -e "  ad-hoc 签名的 kext 被 AMFI 拒绝，AuxKC 里有也加载不进来。"
      echo -e "  执行： ${G}sudo ./12-amfi.sh on${N}   然后重启"
      echo "  撤销： sudo ./12-amfi.sh off（重启后恢复严格校验）"
    fi
  else
    echo -e "  ${Y}⚠ 驱动已真正载入，但还是 1505${N}"
    echo
    echo "  看第 2 节日志："
    echo "   · “接口已被占用” → 匹配顺序没抢到，拔插 modem 重试"
    echo "   · “没有 bulk OUT 端点” → 这个接口不是存储接口，需要换匹配条件"
    echo "   · 完全没有日志 → E398Loader 的 IOResources 匹配没触发，把第 1/2 节发我"
  fi
  echo
  echo -e "  回滚： ${B}sudo ./9-uninstall.sh${N} 然后重启"
else
  echo "  设备没插，或两个 PID 都没看到。"
fi
