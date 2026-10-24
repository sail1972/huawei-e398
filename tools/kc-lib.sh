#!/bin/bash
# kc-lib.sh — 内核集合重建的公共函数（被 2 / 6 / 9 号脚本 source）
#
# 实测结论（macOS 15.8.1 / 24H32 / Intel / SIP 已关闭）：
#   1. 没装官方 KDK 时，`kmutil install` 会以退出码 0 "成功"，
#      但解析不了依赖的 kext 会被静默丢弃 → 必须自己校验 AuxKC 里到底有没有。
#   2. `-z / --no-authorization` 是关键：ad-hoc 签名的 kext 过不了
#      "approval checks"（用户审批 / 公证），不带 -z 会被判
#      "Authenticating extension failed: Bad code signature"。
#      `kmutil create` 的 `-Z`（代码签名检查）默认就是 false，所以 create 反而不卡这关。
#   3. kext 二进制必须有 `_kmod_info` 符号。Xcode 16 起的新链接器 ld-1267 不再为
#      kext 自动合成它，kmutil 会报
#      "cannot be placed in kernel collection because: kexts must have a _kmod_info symbol"。
#      → 源码里用 KMOD_EXPLICIT_DECL 显式声明，见 kext-src/E398Switcher.cpp。
#   4. kext 必须在 /Library/Extensions（或 /System/Library/Extensions）下，
#      且 root:wheel 所有；否则报 "No binaries or codeless kexts were provided"
#      或 "Invalid ownership (501:20) should be (0:0)"。
#   5. 依赖必须能解析：`com.apple.iokit.IOUSBHostFamily` 盘上版本是 1.2，
#      声明 1.0.0 会报 Code 71。
#
# 只定义函数，不执行任何动作；调用方负责以 root 运行。

KC_AUX="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
KC_BOOT="/System/Library/KernelCollections/BootKernelExtensions.kc"
KC_SYS="/System/Library/KernelCollections/SystemKernelExtensions.kc"
KC_KERNEL="/System/Library/Kernels/kernel"

# 日志查询默认只看最近 30 分钟。
# `log show --last boot --predicate 'eventMessage CONTAINS ...'` 会扫描本次开机以来的
# 全部日志（CONTAINS 用不上索引）。开机一两天、日志几十万条时，单条命令要几十秒到
# 几分钟 —— 7-verify 以前就是「卡」在这一步，看起来像内核死锁，其实只是在扫日志。
# 需要完整 range 时：KC_LOG_FULL=1 ./7-verify.sh
KC_LOG_MIN="${KC_LOG_MIN:-30}"

# ---------------------------------------------------------------------------
# 带超时执行一条命令（macOS 没有 coreutils 的 timeout）
#   $1 = 秒数，其余 = 命令
#
# 首选 perl 的 alarm + exec：实测 macOS 上 alarm 会跨 exec 保留（POSIX 允许，
# Linux/BSD 都是保留的），于是"超时"就是给目标进程自己挂一个闹钟，
# 快命令零开销、超时精确，也不用管孙进程（sudo 是 exec 过去的，同一个 pid）。
#   返回：命令自己的退出码；被闹钟打断时是 142（128+SIGALRM）。
# 万一没有 perl，退回"看门狗子 shell"写法（会慢一点，但行为一致）。
# ---------------------------------------------------------------------------
kc_run_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV; die "exec: $!"' "$secs" "$@"
    return $?
  fi
  kc_run_timeout_bash "$secs" "$@"
}

kc_run_timeout_bash() {
  local secs="$1"; shift
  local out pid wd rc
  out=$(mktemp "${TMPDIR:-/tmp}/e398-to.XXXXXX") || return 1
  "$@" >"$out" 2>&1 &
  pid=$!
  (
    sleep "$secs"
    kill -TERM "$pid" 2>/dev/null
    pkill -TERM -P "$pid" 2>/dev/null
    sleep 1
    kill -KILL "$pid" 2>/dev/null
    pkill -KILL -P "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill -TERM "$wd" 2>/dev/null
  pkill -TERM -P "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$out"
  case "$rc" in
    143|137) rc=124 ;;
  esac
  return $rc
}

# 集合里某个 kext 的版本号（没有则输出空）
# 用 kmutil inspect 读，别用 strings：strings 分不清"已经装了"和"报错文本里提到了它"，
# 而且它看不出装的是哪个版本 —— 这会导致新版本永远装不进去（曾踩过）。
kc_aux_version() {  # $1 = bundle id
  kmutil inspect -A "$KC_AUX" --show-extension-info 2>/dev/null \
    | awk -v id="$1" '$1==id {print $2; exit}'
}

kc_aux_has() {  # $1 = bundle id
  [ -n "$(kc_aux_version "$1")" ]
}

kc_loaded() {  # $1 = bundle id
  kmutil showloaded --list-only 2>/dev/null | grep -q "$1"
}

kc_any_collection_has() {  # $1 = bundle id
  local bid="$1" kc
  kc_aux_has "$bid" && return 0
  for kc in /System/Library/KernelCollections/*.kc; do
    [ -f "$kc" ] || continue
    strings -a "$kc" 2>/dev/null | grep -q "$bid" && return 0
  done
  return 1
}

# 二进制里是否有 _kmod_info —— 没有的话后面所有步骤都是白跑
kc_has_kmod_info() {  # $1 = kext 路径
  local kext="$1" exec_name exe
  exec_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
                "$kext/Contents/Info.plist" 2>/dev/null)
  [ -n "$exec_name" ] || return 1
  exe="$kext/Contents/MacOS/${exec_name}"
  [ -f "$exe" ] || return 1
  nm -m "$exe" 2>/dev/null | grep -q "_kmod_info"
}

# ---------------------------------------------------------------------------
# 有 _kmod_info 符号还不够：内核载入时会检查 kmod_info.start 是否为 NULL。
#   为 NULL 时的原文：
#     Kext local.e398.switcher - NULL module start pointer.
#     Kext local.e398.switcher start failed (result 0xdc008007).
#   更坑的是 kmutil showloaded 照样会把它列出来（kmod_info 已登记），
#   于是"已加载"是假象，真实情况是整个 kext 载入被回滚、类没注册。
# ---------------------------------------------------------------------------
kc_kmod_start_ok() {  # $1 = kext 路径
  local kext="$1" exec_name exe
  exec_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
                "$kext/Contents/Info.plist" 2>/dev/null)
  [ -n "$exec_name" ] || return 1
  exe="$kext/Contents/MacOS/${exec_name}"
  [ -f "$exe" ] || return 1
  /usr/bin/python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kmod-info.py" \
      --check "$exe" >/dev/null 2>&1
}

# IORegistry 里是否真有某个类的实例。
# 注意：ioreg -c 在没有匹配时会【打印整棵 IORegistry 树】（1200+ 行），
# 所以「输出非空」≠「有实例」——必须到输出里找 "<class 类名,"。
# 加超时：内核里若有驱动卡在 IOKit 锁上，ioreg 会无限期阻塞（7-verify 的另一个疑似卡点）。
kc_has_class() {  # $1 = 类名
  local out
  out=$(kc_run_timeout 15 ioreg -w0 -c "$1")
  echo "$out" | grep -q "<class $1,"
}

# 内核里是否真的出现了我们的服务实例 —— 这是「kmod 载入成功」唯一可靠的证据。
# （kmod 载入失败时 IOKit 只有 "Couldn't alloc class"，不会接受 personality。）
kc_has_service() {
  kc_has_class E398Loader || kc_has_class E398Switcher
}

# 本次开机以来 kmod 层的失败记录（有输出 = 有失败）
# 普通用户读内核日志有时会拿到空，退回 sudo -n（没有缓存凭证就静默跳过）。
kc_kmod_error() {
  local pred out
  pred='eventMessage CONTAINS "local.e398.switcher"'
  if [ "${KC_LOG_FULL:-0}" = "1" ]; then
    out=$(kc_run_timeout 240 log show --last boot --predicate "$pred" --style compact)
  else
    out=$(kc_run_timeout 20 log show --last "${KC_LOG_MIN}m" --predicate "$pred" --style compact)
  fi
  echo "$out" \
    | grep -E "NULL module start pointer|start failed|failed to load|Couldn't alloc class" \
    | tail -6
}

# ---------- 依赖改写 ----------
#   keep —— 完整声明（IOUSBHostFamily = 1.2，与盘上版本一致）★首选
#   kpi  —— 只留 com.apple.kpi.*
#   none —— 完全删掉 OSBundleLibraries
kc_set_deps() {  # $1 = kext 路径, $2 = kpi|none|keep
  local kext="$1" mode="$2" plist="$1/Contents/Info.plist" exec_name
  [ -f "$plist" ] || return 1
  /usr/libexec/PlistBuddy -c "Delete :OSBundleLibraries" "$plist" >/dev/null 2>&1
  case "$mode" in
    keep)
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries dict" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.iokit.IOUSBHostFamily string 1.2" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.iokit string 8.0.0" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.mach string 8.0.0" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.libkern string 8.0.0" "$plist" >/dev/null 2>&1
      ;;
    kpi)
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries dict" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.iokit string 8.0.0" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.mach string 8.0.0" "$plist" >/dev/null 2>&1
      /usr/libexec/PlistBuddy -c "Add :OSBundleLibraries:com.apple.kpi.libkern string 8.0.0" "$plist" >/dev/null 2>&1
      ;;
    none) : ;;
  esac
  # 改过 plist 必须重新签名
  exec_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)
  [ -n "${exec_name}" ] && chmod 755 "$kext/Contents/MacOS/${exec_name}" 2>/dev/null
  rm -rf "$kext/Contents/_CodeSignature"
  codesign --force --sign - --timestamp=none "$kext" >/dev/null 2>&1 || return 1
  chown -R root:wheel "$kext" 2>/dev/null
  chmod -R go-w "$kext" 2>/dev/null
  return 0
}

# ---------- 生成 aux 集合（不需要 KDK） ----------
# -Z 显式关掉代码签名检查（本来默认就是关的，写上防版本变化）
# -z 跳过审批检查
kc_create_aux() {  # $1 = kext 路径, $2 = 输出 .kc 路径, $3 = 1 表示一并带上其它已装 kext
  local kext="$1" out="$2" with_extra="${3:-0}" args=() k
  rm -f "$out"
  args=(-n aux -z -Z --allow-missing-kdk -k "$KC_KERNEL" -B "$KC_BOOT" -S "$KC_SYS"
        -p "$kext" -x -A "$out")
  if [ "$with_extra" = "1" ]; then
    for k in /Library/Extensions/EnergyDriver.kext /Library/Extensions/HighPointRR.kext \
             /Library/Extensions/HighPointIOP.kext; do
      [ -d "$k" ] && args+=(-p "$k")
    done
  fi
  kmutil create "${args[@]}" 2>&1 | sed 's/^/       /'
  [ -f "$out" ] && return 0
  return 1
}

# ---------- 把生成的 aux 集合装到位 ----------
# 校验不能只看 bundle id：kmutil 失败时会把报错文本也写进产物，导致 strings 假阳性。
# 这里用类名符号 __ZN12E398Switcher 判断。
kc_install_aux() {  # $1 = 新的 .kc, $2 = 期望包含的 bundle id
  local new="$1" bid="$2" backup
  strings -a "$new" 2>/dev/null | grep -q "__ZN12E398Switcher" || {
    echo "      新集合里没有 E398Switcher 的二进制（只有报错文本），放弃安装"
    return 1
  }
  strings -a "$new" 2>/dev/null | grep -q "__ZN11E398Loader" || {
    echo "      新集合里缺少 E398Loader（加载挂钩没进集合），放弃安装"
    return 1
  }
  backup="${KC_AUX}.bak.$(date +%Y%m%d-%H%M%S)"
  if [ -f "$KC_AUX" ]; then
    cp -p "$KC_AUX" "$backup" 2>/dev/null && echo "      原集合已备份：${backup}"
  fi
  chown root:wheel "$new" 2>/dev/null
  chmod 644 "$new" 2>/dev/null
  if cp -p "$new" "${KC_AUX}.new" 2>/dev/null && mv -f "${KC_AUX}.new" "$KC_AUX" 2>/dev/null; then
    chown root:wheel "$KC_AUX" 2>/dev/null
    chmod 644 "$KC_AUX" 2>/dev/null
    echo "      ✓ 已替换 ${KC_AUX}"
    return 0
  fi
  echo "      ✗ 替换失败（/Library/KernelCollections 不可写，确认用 sudo 运行）"
  return 1
}

# 已装进集合时，试着把 kext 直接装进运行中的内核（不用重启）
# 返回：0 = 已加载，2 = 需要重启（Code 28，正常结果），1 = 其它错误
kc_load_now() {  # $1 = kext 路径
  local kext="$1" out bid
  bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$kext/Contents/Info.plist" 2>/dev/null)
  echo "  → 尝试直接装进运行中的内核：kmutil load -z -b ${bid}"
  # 用 -b 精确定位：用 -p 会顺带把集合里其它待加载的 kext（HighPoint 之类）一起拖进来，
  # 它们失败会盖掉我们真正的报错。
  out=$(kmutil load -z -b "$bid" 2>&1)
  if echo "$out" | grep -q "requires a reboot"; then
    echo "     → Code 28：内核集合只能在开机时映射，需要重启后才生效（这是正常结果，不是错误）"
    return 2
  fi
  if kc_loaded "$bid"; then
    # showloaded 里有 ≠ 真的载入成功：kmod start 失败时它照样列在这里。
    # 只有内核里出现服务实例才算数。
    sleep 1
    if kc_has_service; then
      echo "     ✓ 已经加载进内核（服务实例已出现）"
      return 0
    fi
    echo "     ⚠ kmutil 说已加载，但内核里没有服务实例 —— 这就是「假加载」"
    local err
    err=$(kc_kmod_error)
    [ -n "$err" ] && echo "$err" | sed 's/^/       /'
    return 1
  fi
  if [ -n "$out" ]; then
    echo "$out" | tail -6 | sed 's/^/       /'
  fi
  return 0
}

# ---------- 主流程 ----------
kc_rebuild() {  # $1 = kext 路径, $2 = bundle id；成功返回 0
  local kext="$1" bid="$2" mode tmp

  # 0. 硬检查：二进制没有 _kmod_info 就不用往下试了
  if ! kc_has_kmod_info "$kext"; then
    echo "  ✗ 二进制缺少 _kmod_info 符号（kmutil 会直接拒绝）"
    echo "    重新编译即可：./build-kext.sh"
    return 1
  fi
  # 0.1 硬检查：_kmod_info.start 为 NULL 时内核会拒绝整个 kext，
  #     但 kmutil 全程不报错、showloaded 还会列出它 —— 1.2.0 就栽在这里。
  if ! kc_kmod_start_ok "$kext"; then
    echo "  ✗ _kmod_info 的 start 是 NULL（内核会报 NULL module start pointer 并拒绝载入）"
    echo "    重新编译即可：./build-kext.sh（它会打印 _kmod_info 的实际内容）"
    return 1
  fi

  local want_ver in_ver
  want_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$kext/Contents/Info.plist" 2>/dev/null)
  in_ver=$(kc_aux_version "$bid")

  if [ -n "$in_ver" ] && [ "$in_ver" = "$want_ver" ]; then
    echo "  ✓ ${KC_AUX} 里已经是 ${bid} ${in_ver}，版本一致，无需重建"
    kc_load_now "$kext"
    return 0
  fi
  if [ -n "$in_ver" ]; then
    echo "  集合里当前是 ${in_ver}，要装的是 ${want_ver} → 需要更新"
  fi

  # 1. 官方路径：kmutil install（-z 跳过审批，ad-hoc 签名必须带）
  echo
  echo "  → 1) kmutil install -z --force --allow-missing-kdk"
  kmutil install -z --force -v --allow-missing-kdk 2>&1 | tail -12 | sed 's/^/       /'
  if kc_aux_has "$bid"; then
    echo "     ✓ AuxKC 已包含 ${bid}"
    kc_load_now "$kext"
    return 0
  fi
  echo "     ✗ 没有进集合"

  # 2. kmutil load -z（会触发一次集合重建，并把 kext 装进运行中的内核）
  echo
  echo "  → 2) kmutil load -z -p（顺便免重启加载）"
  kmutil load -z -p "$kext" 2>&1 | tail -12 | sed 's/^/       /'
  if kc_aux_has "$bid" || kc_loaded "$bid"; then
    echo "     ✓ 已进集合 / 已加载"
    return 0
  fi
  echo "     ✗ 没有进集合"

  # 3. 自己造集合，依次换依赖写法
  for mode in keep kpi none; do
    case "$mode" in
      keep) echo; echo "  → 3A) 自己生成集合：完整依赖（IOUSBHostFamily = 1.2）" ;;
      kpi)  echo; echo "  → 3B) 自己生成集合：只声明 com.apple.kpi.*" ;;
      none) echo; echo "  → 3C) 自己生成集合：不声明任何依赖" ;;
    esac
    kc_set_deps "$kext" "$mode" || { echo "      plist 改写失败"; continue; }

    tmp="/tmp/e398-aux-${mode}.kc"
    if kc_create_aux "$kext" "$tmp" 1 || kc_create_aux "$kext" "$tmp" 0; then
      echo "     ✓ 生成成功：$(stat -f '%z' "$tmp") 字节"
      if kc_install_aux "$tmp" "$bid"; then
        return 0
      fi
    else
      echo "     ✗ kmutil create 失败"
    fi
  done

  # 三条路都不通时，把 kernelmanagerd 的真实原因捞出来，避免瞎猜
  echo
  echo "  ---- kernelmanagerd 最近日志（真正的原因通常在这里）----"
  log show --last 3m --predicate 'process == "kernelmanagerd"' --style compact 2>/dev/null \
    | tail -12 | sed 's/^/    /' || echo "    （取不到日志）"

  return 1
}

# ---------- 卸载用：只求把 kext 从集合里拿掉 ----------
kc_rebuild_plain() {
  echo "  → 重建 auxiliary 集合"
  kmutil install -z --force -v --allow-missing-kdk 2>&1 | tail -6 | sed 's/^/     /'
  kmutil rebuild 2>&1 | tail -4 | sed 's/^/     /'
}
