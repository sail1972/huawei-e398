#!/bin/bash
# 卸载 / 回滚：把 E398Switcher 与华为官方驱动一起清掉
# 用法： sudo ./9-uninstall.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

R='\033[0;31m'; G='\033[0;32m'; B='\033[1m'; N='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}需要 root：${N} sudo $0"
  exit 1
fi

echo -e "${B}=== 1. 尝试卸载已加载的 kext ===${N}"
for bid in local.e398.switcher $(kmutil showloaded --list-only 2>/dev/null | grep -i huawei | awk '{print $6}'); do
  [ -n "$bid" ] || continue
  printf "  %-52s " "$bid"
  if kmutil unload -b "$bid" 2>/dev/null; then
    echo "已卸载"
  else
    echo "无法卸载（启动集合里的，重启后自然消失）"
  fi
done

echo
echo -e "${B}=== 2. 删除 /Library/Extensions 下的文件 ===${N}"
for k in E398Switcher HuaweiDataCardDriver; do
  D="/Library/Extensions/$k.kext"
  if [ -d "$D" ]; then
    rm -rf "$D" && echo "  已删除 $D"
  fi
done

BAK=$(ls -d /Library/Extensions/*.bak.* 2>/dev/null | tail -1)
[ -n "${BAK}" ] && echo "  备份仍在：${BAK}（需要的话手动 mv 回去）"

echo
echo -e "${B}=== 3. 恢复内核集合（让删除生效）===${N}"
# shellcheck source=tools/kc-lib.sh
source "${DIR}/tools/kc-lib.sh"
# 优先用 6 号脚本留下的备份还原（我们可能直接替换过 AuxKC）
LAST_BAK=$(ls -t /Library/KernelCollections/AuxiliaryKernelExtensions.kc.bak.* 2>/dev/null | head -1)
if [ -n "${LAST_BAK}" ]; then
  echo "  发现备份：${LAST_BAK}"
  cp -p "${LAST_BAK}" "${KC_AUX}.restore" && mv -f "${KC_AUX}.restore" "${KC_AUX}" \
    && echo "  ✓ 已还原 AuxKC（重启后生效）"
else
  kc_rebuild_plain
fi

echo
echo -e "${B}=== 4. 完成 ===${N}"
echo "  重启后这两个 kext 就彻底不在了。"
echo "  若开机出现内核崩溃/卡住："
echo "    开机按住 Shift 进安全模式（第三方 kext 不加载），再删一次；"
echo "    或进恢复模式终端执行： kmutil trigger-panic-medic"
