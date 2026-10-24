#!/bin/bash
# 10-diag.sh —— 抓取「kext 在 AuxKC 里却没有加载」的全部证据
#
# 用法： sudo ./10-diag.sh
# 结果： 终端打印 + 同时写一份 diag-<时间>.log 到本目录（权限 644，可直接发我）
#
# 这个脚本只读，不改任何东西。

set -uo pipefail
cd "$(dirname "$0")" || exit 1

BID="local.e398.switcher"
KEXT="/Library/Extensions/E398Switcher.kext"
OUT="diag-$(date +%Y%m%d-%H%M%S).log"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root： sudo ./10-diag.sh"
  exit 1
fi

exec > >(tee "$OUT") 2>&1

sec() { echo; echo "########## $* ##########"; }

sec "0. 环境"
date
uptime
sw_vers
echo "SIP: $(csrutil status 2>&1)"
echo "boot-args: $(nvram boot-args 2>&1)"

sec "1. kext 本体"
ls -ld "$KEXT"
echo "--- 签名 ---"
codesign -dvvv "$KEXT" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|CDHash=|flags"
echo "--- 结构校验 ---"
codesign --verify --deep --strict "$KEXT" 2>&1 && echo "  结构有效"
echo "--- _kmod_info ---"
nm -m "$KEXT/Contents/MacOS/E398Switcher" 2>/dev/null | grep -i kmod

sec "2. AuxKC 里到底有没有"
kmutil inspect -A /Library/KernelCollections/AuxiliaryKernelExtensions.kc --show-extension-info 2>/dev/null | grep -i e398 \
  || echo "  ✗ 不在 AuxKC 里"
ls -l /Library/KernelCollections/

sec "3. 内核里是否加载"
kmutil showloaded --list-only 2>/dev/null | grep -i e398 || echo "  ✗ 内核里没有"
echo "  ※ showloaded 只代表 kmod_info 登记过；kmod start 失败时它也会列在这里。"
echo "    真正的判据是内核里有没有服务实例："
if ioreg -w0 -c E398Loader 2>/dev/null | grep -q "<class E398Loader,"; then
  echo "      E398Loader 实例：有（kmod 层通过）"
else
  echo "      E398Loader 实例：无 → kext 没有真正载入"
fi
echo "--- 对照：同一个 AuxKC 里 EnergyDriver 是否加载 ---"
kmutil showloaded --list-only 2>/dev/null | grep -i energy || echo "  ✗ EnergyDriver 也没加载（说明整条路都不通）"

sec "4. kmutil 官方诊断（root 下只剩签名项）"
kmutil print-diagnostics -p "$KEXT" 2>&1 | grep -v "No variant"

sec "5. 直接尝试载入（要真实报错，不要 'requires a reboot'）"
echo "--- 5.0 二进制里的 _kmod_info（start 为 NULL 时内核必然拒绝）---"
/usr/bin/python3 tools/kmod-info.py "$KEXT/Contents/MacOS/E398Switcher" 2>&1 | sed 's/^/  /'
echo "--- 5.0b 当前内核里有没有服务实例 ---"
# ioreg -c 无匹配时会打印整棵树，必须找 "<class 类名," 才算有
if ioreg -w0 -c E398Loader 2>/dev/null | grep -q "<class E398Loader,"; then
  echo "  E398Loader 实例：有（kmod 层已通过）"
else
  echo "  E398Loader 实例：无"
fi
echo "--- 5a. kmutil load -z -b $BID ---"
kmutil load -z -b "$BID" 2>&1 | tail -8
echo "--- 5b. kmutil load -z -p <kext> ---"
kmutil load -z -p "$KEXT" 2>&1 | tail -8

sec "6. 内核日志（这是唯一能说清原因的地方）"
KLOG=/tmp/e398-klog-$$.txt
log show --last 60m --info \
  --predicate 'process == "kernel" OR process == "kernelmanagerd"' \
  --style compact >"$KLOG" 2>/dev/null
echo "  日志行数: $(wc -l < "$KLOG")"
echo
echo "--- 6a. 含 E398 的行 ---"
grep -i "e398" "$KLOG" | tail -30 || echo "  （无）"
echo
echo "--- 6b. 含 kext / kmod / amfi / signature / 0xdc00 的行 ---"
grep -iE "kext|kmod|amfi|signature|0xdc00|Failed to load" "$KLOG" | tail -40 || echo "  （无）"
echo
echo "--- 6c. 内核启动早期（前 60 行）---"
head -60 "$KLOG"

sec "7. dmesg 兜底"
dmesg 2>/dev/null | grep -iE "e398|kext|kmod|amfi" | tail -30 || echo "  （dmesg 无输出）"

sec "8. 结论"
if grep -q "NULL module start pointer" "$KLOG" 2>/dev/null; then
  echo "  → 内核明确拒绝载入：_kmod_info.start 是 NULL（module start pointer）"
  echo "    kmutil showloaded 照样会列出这个 kext，所以「已加载」是假象："
  echo "    整个载入被回滚，类没注册进 IOCatalogue，personality 只能报 Couldn't alloc class。"
  echo "    解法： ./build-kext.sh  然后  sudo ./6-install-switcher.sh  再重启"
elif kmutil showloaded --list-only 2>/dev/null | grep -qi e398 \
     && ioreg -w0 -c E398Loader 2>/dev/null | grep -q "<class E398Loader,"; then
  echo "  ✓ 已载入，且内核里有服务实例"
elif grep -qiE "amfi|Bad code signature|not signed|cs_invalid|Code Signing" "$KLOG" 2>/dev/null; then
  echo "  → 日志里出现 AMFI / 代码签名相关字眼：签名被拒是原因"
  echo "    解法： sudo nvram boot-args=\"amfi_get_out_of_my_way=1\" 然后重启（见 12-amfi.sh）"
elif grep -qiE "Failed to load|0xdc00|unresolved|symbol" "$KLOG" 2>/dev/null; then
  echo "  → 日志里有加载失败码或符号问题，把本文件发我，按报错精确定位"
else
  echo "  → 日志里没有任何关于它的记录：说明开机时根本没尝试加载这个 kext"
  echo "    这指向「开机用的集合与磁盘上的不一致」，需要换安装方式，把本文件发我"
fi

rm -f "$KLOG"
echo
echo "完整记录已保存到： $OUT"
echo "（直接把该文件发给助手即可）"
