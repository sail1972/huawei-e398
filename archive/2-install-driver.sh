#!/bin/bash
#
# 2-install-driver.sh — 安装华为官方数据卡驱动（让 1506 变成可用的串口）
# 用法： sudo ./2-install-driver.sh
#
# 注意：macOS 15 无法在运行时加载自建/未签名 kext（kextd 已被移除），
#       所以本脚本装进 /Library/Extensions 后重建 AuxKC，必须重启才生效。
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/kext/HuaweiDataCardDriver.kext"
DEST="/Library/Extensions/HuaweiDataCardDriver.kext"
BID="com.huawei.driver.HuaweiDataCardDriver"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

echo -e "${Y}${B}========== 这个脚本已经废弃 ==========${N}"
echo "华为 4.25.09 驱动是 2013 年的：依赖 macOS 11 起就移除的旧 IOUSBFamily API，"
echo "全盘没签名，在 macOS 15 上既进不了内核集合、也不会产生 /dev 串口。"
echo "实测（本机）：装了之后 kmutil showloaded 里没有它，AuxKC 里也没有。"
echo
echo -e "现在改用用户态方案： ${G}sudo ./5-ppp-dial.sh${N}（不需要任何第三方 kext）"
echo
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}需要 root：${N} sudo $0"
  exit 1
fi
[ -d "$SRC" ] || { echo -e "${R}✗ 找不到驱动原件：$SRC${N}"; exit 2; }

read -r -p "仍要继续装这个老驱动？[y/N] " _a
case "${_a:-N}" in y|Y) ;; *) echo "已取消。用 sudo ./5-ppp-dial.sh"; exit 0 ;; esac

echo -e "${B}=== 0. 前提检查 ===${N}"
PROBE=$("$DIR/tools/e398_ctrl" --probe 2>/dev/null)
echo "$PROBE" | sed 's/^/  /'
if ! echo "$PROBE" | grep '1506' | grep -qE ': 在$'; then
  echo -e "  ${Y}⚠ 设备现在不是 1506。驱动只匹配 0x1506，装了也不会生效。${N}"
  echo "    先跑 sudo ./6-install-switcher.sh 并重启，把模式切过去。"
  read -r -p "  仍要继续安装？[y/N] " a
  case "${a:-N}" in y|Y) ;; *) exit 3 ;; esac
fi

echo
echo -e "${B}=== 1. 安装到 /Library/Extensions ===${N}"
if [ -e "$DEST" ]; then
  BAK="$DEST.bak.$(date +%Y%m%d%H%M%S)"
  mv "$DEST" "$BAK" && echo "  旧版本备份到 $BAK"
fi
cp -R "$SRC" "$DEST" || { echo -e "${R}✗ 拷贝失败${N}"; exit 4; }

xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
find "$DEST" -name "*.kext" -type d -exec chmod 755 {} \;
echo "  ✓ $DEST"

echo
echo -e "${B}=== 2. ad-hoc 签名（含所有插件）===${N}"
codesign --force --deep --sign - --timestamp=none "$DEST" 2>&1 | grep -v "replacing existing signature" | tail -3 | sed 's/^/  /'
if codesign -v --deep "$DEST" 2>/dev/null; then
  echo -e "  ${G}✓ 签名校验通过${N}"
else
  echo -e "  ${Y}签名校验有警告，继续（SIP 已关闭时不强制）${N}"
fi

echo
echo -e "${B}=== 3. 重建内核集合 ===${N}"
# shellcheck source=tools/kc-lib.sh
source "${DIR}/tools/kc-lib.sh"
kc_rebuild "${DEST}" "${BID}"
KC_RC=$?

echo
echo -e "${B}=== 4. 验证 ===${N}"
if [ "${KC_RC}" -eq 0 ] && kc_any_collection_has "${BID}"; then
  echo -e "  ${G}✓ 已进入内核集合${N}"
else
  echo -e "  ${Y}没查到 ${BID}${N}"
  echo "    先跑 sudo ./6-install-switcher.sh，它会打印完整诊断。"
fi

echo
echo -e "${B}=== 5. 完成，需要重启 ===${N}"
echo "  重启后设备应出现 /dev/tty.HUAWEIMobile-* 与 /dev/cu.HUAWEIMobile-*"
echo
echo -e "  重启后体检： ${G}./7-verify.sh${N}"
echo -e "  ${Y}出问题回滚${N}：sudo ./9-uninstall.sh 然后重启"
echo
echo -e "  ${Y}如果开机内核崩溃（老驱动在 15 上有可能）${N}："
echo "    开机按住 Shift 进安全模式（第三方 kext 不加载），跑 ./9-uninstall.sh；"
echo "    或恢复模式终端：kmutil trigger-panic-medic"
echo
read -r -p "  现在重启？[y/N] " ans
case "${ans:-N}" in
  y|Y) echo "  3 秒后重启…"; sleep 3; shutdown -r now ;;
  *)   echo "  好的，记得自己手动重启。" ;;
esac
