#!/bin/bash
#
# build-kext.sh — 编译 E398Switcher.kext（只需要命令行工具，不需要完整 Xcode）
#
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
KF="$SDK/System/Library/Frameworks/Kernel.framework"
OUT="kext/E398Switcher.kext"
OBJ="/tmp/E398Switcher.o"

[ -d "$KF" ] || { echo "找不到 Kernel.framework，请先 xcode-select --install"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp kext-src/E398Switcher-Info.plist "$OUT/Contents/Info.plist"

echo "=== 编译 ==="
clang++ -arch x86_64 -mkernel \
    -fno-builtin -fno-common -fno-exceptions -fno-rtti -fno-stack-protector \
    -nostdinc++ -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -isysroot "$SDK" \
    -I "$KF/Headers" \
    -c kext-src/E398Switcher.cpp -o "$OBJ"

echo "=== 链接 ==="
clang++ -arch x86_64 -mkernel -nostdlib \
    -Xlinker -kext -Xlinker -undefined -Xlinker dynamic_lookup \
    -isysroot "$SDK" \
    -o "$OUT/Contents/MacOS/E398Switcher" "$OBJ"

chmod -R go-w "$OUT"
chmod 755 "$OUT/Contents/MacOS/E398Switcher"

echo "=== 签名（ad-hoc）==="
codesign --force --sign - --timestamp=none "$OUT" >/dev/null 2>&1 || true
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|Signature|Format" | sed 's/^/  /'

echo
echo "=== 产物 ==="
ls -l "$OUT/Contents/MacOS/E398Switcher" | sed 's/  */ /g'

# kmutil 的硬性要求：二进制里必须有 _kmod_info。
# Xcode 16 起的新链接器（ld-1267）不再为 kext 自动合成，靠源码里的 KMOD_EXPLICIT_DECL。
if nm -m "$OUT/Contents/MacOS/E398Switcher" 2>/dev/null | grep -q "_kmod_info"; then
  echo "  ✓ _kmod_info 存在（kmutil 可以接受）"
else
  echo "  ✗ _kmod_info 缺失！kmutil 会报 kexts must have a _kmod_info symbol"
  echo "    检查 kext-src/E398Switcher.cpp 顶部的 KMOD_EXPLICIT_DECL"
  exit 1
fi

# 光有符号还不够：内核会检查 kmod_info.start 非 NULL。
# 为 NULL 时的报错是 "NULL module start pointer" / "start failed (0xdc008007)"，
# 而且 kmutil showloaded 仍然会列出这个 kext —— 极易误判成"已加载"。
echo "  _kmod_info 内容："
if /usr/bin/python3 tools/kmod-info.py --check "$OUT/Contents/MacOS/E398Switcher"; then
  echo "  ✓ kmod start/stop 非空，内核不会因 NULL 拒绝载入"
else
  echo "  ✗ kmod start 是 NULL —— 内核一定会拒绝载入（NULL module start pointer）"
  echo "    检查 KMOD_EXPLICIT_DECL 的第三个参数，必须是真实的函数"
  exit 1
fi

echo "  未解析符号："
nm -u "$OUT/Contents/MacOS/E398Switcher" 2>/dev/null | grep -v "^ *$" | sed 's/^/    /' | head -20

echo
echo "完成 → kext/E398Switcher.kext"
