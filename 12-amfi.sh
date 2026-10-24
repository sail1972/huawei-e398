#!/bin/bash
# 12-amfi.sh —— 允许加载 ad-hoc 签名的内核扩展（macOS 11+ 专用开关）
#
# 背景：
#   macOS 11 起，/Library/Extensions 里的 kext 必须进 AuxKC 才能开机加载，
#   而 AuxKC 里的 kext 仍然要通过 AMFI 的代码签名校验。
#   我们自建的 kext 只有 ad-hoc 签名（无 Apple Developer ID），
#   所以即使 SIP 已关闭，它也会在加载阶段被拒 —— 表现就是
#   「AuxKC 里明明有，内核里就是没有」，而且没有任何日志提示（除 AMFI 一句）。
#
#   关闭 AMFI 的开关是 boot-arg： amfi_get_out_of_my_way=1
#
# 用法：
#   sudo ./12-amfi.sh status    看当前状态
#   sudo ./12-amfi.sh on        打开开关（然后必须重启）
#   sudo ./12-amfi.sh off       撤销开关（然后重启）
#
# 风险：关闭 AMFI 会同时放松用户态的代码签名校验，整机安全性下降。
#       本机 SIP 已经处于 disabled，属于开发机配置；
#       不想长期开着，就在驱动装好、模式切换验证通过后执行 off 撤销。
#       撤销不会影响已加载的 kext，下次重启才会恢复严格校验。

set -uo pipefail

AMFI="amfi_get_out_of_my_way=1"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root： sudo ./12-amfi.sh status|on|off"
  exit 1
fi

cur() { nvram boot-args 2>/dev/null | sed 's/.*boot-args[[:space:]]*//'; }

case "${1:-status}" in
  status)
    echo "SIP      : $(csrutil status 2>&1 | sed 's/System Integrity Protection status: //')"
    b=$(cur)
    if [ -z "$b" ]; then
      echo "boot-args: （空）"
    else
      echo "boot-args: $b"
    fi
    if echo "$b" | grep -q "amfi_get_out_of_my_way=1"; then
      echo "AMFI     : 已关闭（可加载 ad-hoc 签名 kext）"
    else
      echo "AMFI     : 开启（ad-hoc 签名 kext 会被拒）"
    fi
    ;;

  on)
    b=$(cur)
    if echo "$b" | grep -q "amfi_get_out_of_my_way=1"; then
      echo "已经是打开状态： $b"
    else
      new=$(echo "$b $AMFI" | sed 's/^ *//; s/  */ /g')
      if nvram boot-args="$new" 2>/dev/null; then
        echo "✓ 已设置 boot-args = $new"
      else
        echo "✗ 写入失败。T2 机型需要先降级安全启动："
        echo "   关机 → 长按电源键进「启动安全性实用工具」→ 选择「中等安全性」+ 允许从外部介质启动"
        echo "   再进恢复模式终端执行本命令"
        exit 1
      fi
    fi
    echo
    echo "下一步： 重启（modem 保持插着），开机后跑 ./7-verify.sh"
    ;;

  off)
    b=$(cur)
    new=$(echo "$b" | sed "s/$AMFI//g" | sed 's/^ *//; s/  */ /g')
    if [ -z "$new" ]; then
      nvram -d boot-args 2>/dev/null && echo "✓ 已清除 boot-args（AMFI 恢复严格校验）"
    else
      nvram boot-args="$new" 2>/dev/null && echo "✓ boot-args = $new"
    fi
    echo "重启后生效。"
    ;;

  *)
    echo "用法： sudo ./12-amfi.sh status|on|off"
    exit 1
    ;;
esac
