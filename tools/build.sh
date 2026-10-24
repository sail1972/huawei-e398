#!/bin/bash
#
# tools/build.sh — 编译本项目的全部用户态工具（不需要 root，不需要完整 Xcode）
#
# 用法：
#   ./tools/build.sh            编译缺的
#   ./tools/build.sh --force    全部重编
#
# 只有 clang（命令行工具）就够了：xcode-select --install
set -u
cd "$(dirname "$0")" || exit 1

FORCE=0
for a in "$@"; do
  case "$a" in
    --force|-f) FORCE=1 ;;
    -h|--help)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

if ! command -v clang >/dev/null 2>&1; then
  echo "✗ 找不到 clang。先装命令行工具： xcode-select --install"
  exit 1
fi

CFLAGS="-O2 -Wno-deprecated-declarations"
FRAMEWORKS="-framework IOKit -framework CoreFoundation"
FRAMEWORKS_CF="-framework IOKit -framework CoreFoundation -framework Foundation"

# 名字｜源码｜框架集合
TARGETS=(
  "e398_at:e398_at.c:core"
  "e398_ppp:e398_ppp.c:core"
  "e398_power:e398_power.c:core"
  "e398_reenum:e398_reenum.c:core"
  "e398_probe:e398_probe.m:cf"
  "e398_proxyset:e398_proxyset.m:cf"
  "e398_ctrl:e398_ctrl.c:core"
  "e398_bulk:e398_bulk.c:core"
  "e398_scsi:e398_scsi.c:core"
  "devdesc:devdesc.c:core"
  "dumpdesc:dumpdesc.c:core"
  "probe:probe.c:core"
  "usb_switch_huawei:usb_switch_huawei.c:core"
)

ok=0; skip=0; fail=0
for t in "${TARGETS[@]}"; do
  IFS=':' read -r out src kind <<< "$t"
  [ -f "$src" ] || continue
  if [ "$FORCE" -eq 0 ] && [ -x "$out" ] && [ "$out" -nt "$src" ]; then
    printf "  = %-20s 已是最新\n" "$out"
    skip=$((skip+1)); continue
  fi
  [ "$kind" = cf ] && FW="$FRAMEWORKS_CF" || FW="$FRAMEWORKS"
  printf "  + %-20s 编译中…" "$out"
  if clang $CFLAGS -o "$out" "$src" $FW 2>/tmp/e398-build-$$.log; then
    echo -e "\r  ✓ $out 已生成"
    ok=$((ok+1))
  else
    echo -e "\r  ✗ $out 编译失败"
    sed 's/^/      /' /tmp/e398-build-$$.log | head -10
    fail=$((fail+1))
  fi
done
rm -f /tmp/e398-build-$$.log

echo
echo "完成：新编 ${ok}，已最新 ${skip}，失败 $fail"
[ "$fail" -eq 0 ] || exit 1

# 日常只需要这两个：AT 通道 + PPP 桥接
for t in e398_at e398_ppp; do
  [ -x "$t" ] || { echo "✗ 缺 $t —— 拨号脚本无法工作"; exit 1; }
done
echo "必需工具齐备（e398_at / e398_ppp）"
