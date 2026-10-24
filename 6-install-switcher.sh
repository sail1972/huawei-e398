#!/bin/bash
#
# 6-install-switcher.sh — 把 E398Switcher.kext 装进内核集合并加载
# 用法： sudo ./6-install-switcher.sh
#
# 这条路径的每一道坎（都是一路踩出来的，别再改回去）：
#   ① 二进制必须有 _kmod_info —— Xcode 16 的新链接器不再自动合成
#   ② 必须放在 /Library/Extensions 且 root:wheel
#   ③ 必须带 -z 跳过 approval 检查 —— ad-hoc 签名过不了公证
#   ④ 依赖必须写成 com.apple.iokit.IOUSBHostFamily = 1.2（盘上版本）
#   ⑤ 没装 KDK 时需要 --allow-missing-kdk
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1

KEXT_SRC="$DIR/kext/E398Switcher.kext"
DEST="/Library/Extensions/E398Switcher.kext"
BID="local.e398.switcher"
AUXKC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}需要 root：${N} sudo $0"
  exit 1
fi

# ---------- 0. 设备状态 ----------
echo -e "${B}=== 0. 设备状态 ===${N}"
PROBE="$("$DIR/tools/e398_ctrl" --probe 2>/dev/null)"
echo "${PROBE:-  （读不到，可能没插）}" | sed 's/^/  /'
if echo "$PROBE" | grep '1506' | grep -qE ': 在$'; then
  echo -e "  ${G}✓${N} 设备已经是 12d1:1506，不需要切换，直接拨号： ./5-ppp-dial.sh"
  exit 0
fi
if ! echo "$PROBE" | grep '1505' | grep -qE ': 在$'; then
  echo -e "  ${R}✗${N} 没找到 12d1:1505，请先把 modem 插好"
  exit 2
fi
echo -e "  ${G}✓${N} 设备处于 12d1:1505（零 CD），正是本驱动要处理的状态"

# ---------- 1. 编译 & 校验 ----------
echo
echo -e "${B}=== 1. 编译 / 校验 kext ===${N}"
if [ ! -d "$KEXT_SRC" ] || [ "kext-src/E398Switcher.cpp" -nt "$KEXT_SRC" ] \
   || [ "kext-src/E398Switcher-Info.plist" -nt "$KEXT_SRC" ]; then
  echo "  源码比产物新，重新编译…"
  ./build-kext.sh 2>&1 | grep -vE "warning:|^ *\^|^ *[0-9]+ \|" | tail -8 | sed 's/^/  /'
fi
[ -d "$KEXT_SRC" ] || { echo -e "${R}✗ kext 不存在${N}"; exit 3; }

# shellcheck source=tools/kc-lib.sh
source "${DIR}/tools/kc-lib.sh"

if kc_has_kmod_info "$KEXT_SRC"; then
  echo -e "  ${G}✓${N} 二进制含 _kmod_info（kmutil 的硬性要求）"
  # 光有符号不够：内核还会检查 start 指针（1.2.0 就是死在这一步）
  echo "  _kmod_info 实际内容："
  if /usr/bin/python3 "${DIR}/tools/kmod-info.py" --check \
        "$KEXT_SRC/Contents/MacOS/E398Switcher"; then
    echo -e "  ${G}✓${N} kmod start/stop 非空，内核不会因为 NULL 拒绝载入"
  else
    echo -e "  ${R}✗ kmod start 是 NULL，内核会报 NULL module start pointer 并回滚整个载入${N}"
    echo "    重新编译：./build-kext.sh"
    exit 4
  fi
else
  echo -e "  ${R}✗ 二进制缺少 _kmod_info，kmutil 一定会拒绝${N}"
  echo "    检查 kext-src/E398Switcher.cpp 里的 KMOD_EXPLICIT_DECL 后重新编译"
  exit 4
fi

if codesign -v "$KEXT_SRC" 2>/dev/null; then
  echo -e "  ${G}✓${N} 签名结构有效（ad-hoc）"
else
  echo -e "  ${Y}签名无效，重新 ad-hoc 签名${N}"
  codesign --force --sign - --timestamp=none "$KEXT_SRC" || { echo -e "${R}✗ 签名失败${N}"; exit 4; }
fi

# ---------- 2. 安装到 /Library/Extensions ----------
echo
echo -e "${B}=== 2. 安装到 /Library/Extensions ===${N}"
# 先卸载旧的再换，避免 kextd/内核缓存拿到半新半旧的 bundle
rm -rf "$DEST"
cp -R "$KEXT_SRC" "$DEST" || { echo -e "${R}✗ 拷贝失败${N}"; exit 5; }
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
chmod 755 "$DEST/Contents/MacOS/E398Switcher"
echo "  ✓ ${DEST}"

# root:wheel 之后再诊断一次，这一版的结论才是准的
echo "  诊断结果："
kmutil print-diagnostics -p "$DEST" 2>&1 \
  | grep -vE "No variant specified" | sed 's/^/    /' | tail -6

# ---------- 2.5 ad-hoc 签名的加载许可 ----------
echo
echo -e "${B}=== 2.5 ad-hoc 签名的加载许可（AMFI）===${N}"
BA="$(nvram boot-args 2>/dev/null | sed 's/.*boot-args[[:space:]]*//')"
if echo "$BA" | grep -q "amfi_get_out_of_my_way=1"; then
  echo -e "  ${G}✓${N} AMFI 已关闭，ad-hoc 签名的 kext 可以加载"
  AMFI_OK=1
else
  echo -e "  ${Y}⚠ AMFI 仍开启${N}"
  echo "    本 kext 只有 ad-hoc 签名（没有 Apple Developer ID）。macOS 11+ 即使在"
  echo "    SIP 关闭的情况下，也要求 AuxKC 里的 kext 通过 AMFI 的签名校验；"
  echo "    被拒时的表现就是「集合里明明有，内核里就是没有」，且几乎没有日志。"
  echo
  echo -e "    请另外执行一次： ${G}sudo ./12-amfi.sh on${N}"
  echo "    （写入 boot-args=amfi_get_out_of_my_way=1，重启后生效；可随时 off 撤销）"
  AMFI_OK=0
fi

# ---------- 3. 进内核集合 ----------
echo
echo -e "${B}=== 3. 加入内核集合 ===${N}"
if kc_rebuild "$DEST" "$BID"; then
  KC_OK=1
else
  KC_OK=0
fi

# ---------- 4. 验证 ----------
echo
echo -e "${B}=== 4. 验证 ===${N}"
if [ "${KC_OK}" -eq 1 ]; then
  echo -e "  ${G}✓ ${AUXKC} 已包含 ${BID}${N}"
  echo "     修改时间：$(stat -f '%Sm' "${AUXKC}")"
else
  echo -e "  ${R}✗ AuxKC 里仍然没有 ${BID}${N}"
  echo
  echo "  判断依据："
  echo "   · 提到 _kmod_info          → 二进制问题，./build-kext.sh 重编"
  echo "   · 提到 Bad code signature  → 少了 -z（跳过 approval 检查）"
  echo "   · 提到 Code 71 / kpi.*     → 依赖版本不对"
  echo "   · 提到 Code 34 Missing KDK → 只有这条才真的需要官方 KDK"
  echo
  echo "  回滚： sudo ./9-uninstall.sh"
  exit 6
fi

# ---------- 5. 加载 ----------
echo
echo -e "${B}=== 5. 加载并切换 ===${N}"
kc_load_now "$DEST" || true
sleep 1

if kc_has_service; then
  echo -e "  ${G}✓ 内核里已经有 E398 服务实例（kmod 层通过，类已注册）${N}"
  NEED_REBOOT=0
elif kc_loaded "$BID"; then
  # v1.2.0 就是这个形态：showloaded 列着 1.2.0，实际 kmod start 失败、类没注册。
  echo -e "  ${Y}⚠ kmutil showloaded 里有 ${BID}，但内核里没有服务实例${N}"
  ERR="$(kc_kmod_error)"
  if [ -n "${ERR}" ]; then
    echo "  内核日志（本次开机）："
    echo "${ERR}" | sed 's/^/    /'
  fi
  echo
  echo "  这是「假加载」：kmod 层拒绝了整个 kext，IOKit 里连类都没有。"
  echo "  如果日志是 NULL module start pointer → kext 还是旧版本，重编重装一遍。"
  NEED_REBOOT=1
else
  echo -e "  ${G}✓ 已排进集合，${Y}重启后生效${N}"
  echo "     Code 28 = 内核集合只能开机时映射，这一步到此为止是正常的。"
  NEED_REBOOT=1
fi

echo
echo -e "${B}=== 6. 下一步 ===${N}"
echo
if [ "${NEED_REBOOT}" -eq 1 ]; then
  echo -e "  ${B}重启一次${N}（modem 保持插着）。集合里已经有了，开机即生效。"
  echo "  开机会先由 IOResources 上的 E398Loader 把 kext 拉进内核（不再依赖 USB 匹配），"
  echo "  然后 E398Switcher 以 IOProbeScore=1000000 抢在 mass-storage(50000) 之前拿到接口。"
  echo
  echo -e "  重启后跑： ${G}./7-verify.sh${N}"
  echo
  echo -e "  如果开机后还是 1505：把 modem 拔下来、等 3 秒、插回去，"
  echo "  此时 kext 已在内核里，重新匹配一定由我们赢。"
else
  echo -e "  驱动已经在内核里了，但它面对的是一个【已被 mass-storage 占住】的接口，"
  echo "  日志里会看到“接口已被占用”，这属于正常。让它重新匹配一次："
  echo
  echo -e "    ${G}把 modem 拔下来，等 3 秒，再插回去${N}"
  echo
  echo -e "  然后跑： ${G}./7-verify.sh${N}"
fi
echo
echo -e "  回滚： ${B}sudo ./9-uninstall.sh${N} 然后重启"
echo
echo -e "  ${Y}万一开不了机${N}：开机按住 Shift 进安全模式（第三方 kext 不加载），"
echo "              或恢复模式终端执行：kmutil trigger-panic-medic"
echo
if [ "${AMFI_OK:-0}" -eq 0 ]; then
  echo -e "  ${Y}${B}注意${N}：AMFI 还没关闭。现在重启，kext 仍然会被签名校验挡在门外。"
  echo -e "          先执行 ${G}sudo ./12-amfi.sh on${N}，再重启。"
  echo
fi
read -r -p "  现在重启？[y/N] " ans
case "${ans:-N}" in
  y|Y) echo "  3 秒后重启…"; sleep 3; shutdown -r now ;;
  *)   echo "  好的，记得自己手动重启。" ;;
esac
