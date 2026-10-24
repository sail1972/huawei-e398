#!/bin/bash
#
# 11-proxy-fix.sh — 让「系统代理」在 PPP 拨号后继续生效
#
# ============ 问题是什么（全部来自本机实测）============
# macOS 的系统代理是**按网络服务**存的。v2rayN 把 SOCKS 127.0.0.1:1080 写在
# "Wi-Fi" 这个服务上（networksetup -getsocksfirewallproxy Wi-Fi → Enabled: Yes）。
# ppp0 一成为主接口，configd 就会按新的主接口重算 State:/Network/Global/Proxies：
#
#     scutil <<< "show State:/Network/Global/IPv4"
#       PrimaryInterface : ppp0
#       PrimaryService   : <UUID>        ← 这个 UUID 在服务库里 "No such key"
#     scutil --proxy
#       SOCKSEnable : 0                  ← 代理被「关掉」了
#
# 于是所有读系统代理的 App 都以为没有代理 → 全部直连 → v2rayN 形同不存在。
# （xray 本身没问题：curl -x socks5h://127.0.0.1:1080 ifconfig.me 走的是服务器出口。）
#
# ============ 为什么一次写入不管用 ============
# 第 1 版只往 State:/Network/Global/Proxies 写一次，被 configd 在 PPP 状态收敛时
# 又重算掉了。所以本版做三件事：
#   1. 用 tools/e398_proxyset 写：global 与 __SCOPED__（覆盖所有活动接口，含 ppp0）
#      一次写全 —— scutil 的 DSL 表达不了嵌套字典，这是它做不到的；
#   2. 写之前先**真校验**（SOCKSEnable 必须为 1、Proxy/Port 必须对、ppp0 的
#      scoped 条目必须存在），不再用「有 SOCKSEnable 这个键」这种假判据；
#   3. watch 模式每 2 秒补一次，被重算掉就立刻写回。install 可把它装成 LaunchDaemon。
#
# 用法：
#   sudo ./11-proxy-fix.sh apply [端口]    立即写入（端口默认自动探测）
#   ./11-proxy-fix.sh status               看现状 + 用 CFNetwork 实测是否真走代理
#   ./11-proxy-fix.sh probe                只测：系统代理到底有没有被 App 用上
#   sudo ./11-proxy-fix.sh watch [端口]    前台看护循环（ppp0 在用时持续保证代理有效）
#   sudo ./11-proxy-fix.sh install [端口]  装成 LaunchDaemon（开机自启，永久看护）
#   sudo ./11-proxy-fix.sh uninstall       卸载 LaunchDaemon
#   sudo ./11-proxy-fix.sh off             清空，交回 configd 自己算
#
set -o pipefail
PORT_ARG="${2:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$DIR/tools"
PROXYSET="$TOOLS/e398_proxyset"
PROBE="$TOOLS/e398_probe"
WLOG=/tmp/e398-proxy.log
LABEL=local.e398.proxy
PLIST=/Library/LaunchDaemons/$LABEL.plist
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

# ---------- 编译 ----------
need_build() {  # $1=源码 $2=产物 $3=额外 framework 参数...
  local src="$1" out="$2"; shift 2
  [ -x "$out" ] && [ "$out" -nt "$src" ] && return 0
  echo "  编译 $(basename "$out") ..." >&2
  clang -fobjc-arc -O2 -Wno-nullability-completeness -Wno-deprecated-declarations \
        -o "$out" "$src" "$@" || return 1
}
ensure_tools() {
  need_build "$TOOLS/e398_proxyset.m" "$PROXYSET" \
             -framework Foundation -framework SystemConfiguration || return 1
  need_build "$TOOLS/e398_probe.m" "$PROBE" -framework Foundation || return 1
  return 0
}

# ---------- 探测端口 ----------
detect_port() {
  local svc out port
  for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    out=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null)
    if echo "$out" | grep -q "^Enabled: Yes"; then
      port=$(echo "$out" | awk '/^Port:/{print $2; exit}')
      [ -n "$port" ] && { echo "$port"; return; }
    fi
  done
  echo 1080
}

port_listening() { nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1; }

ppp0_up() { ifconfig ppp0 2>/dev/null | grep -q "inet "; }

# 真校验：0=一致 / 1=不一致 / 4=全局对但缺 ppp0 的 scoped 条目
proxy_check() { [ -x "$PROXYSET" ] || return 1; "$PROXYSET" check 127.0.0.1 "$1" >/dev/null 2>&1; }

proxy_write() {  # $1=port
  if [ -x "$PROXYSET" ]; then
    "$PROXYSET" set 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
  fi
  # 兜底：老式 scutil（写不出 __SCOPED__，但至少 global 对）
  /usr/sbin/scutil >/dev/null 2>&1 <<EOF
d.init
d.add SOCKSEnable 1
d.add SOCKSProxy 127.0.0.1
d.add SOCKSPort $1
d.add ExceptionsList <array> <string>*.local</string> <string>169.254/16</string> </array>
set State:/Network/Global/Proxies
EOF
}

# 一次「确认写进去了」，必要时最多重写 3 次（configd 会在 PPP 收敛时重算）
apply_once() {  # $1=port $2=静默?
  local port="$1" quiet="${2:-}" i
  for i in 1 2 3; do
    proxy_check "$port" && { [ -z "$quiet" ] && echo -e "  ${G}✓ 已生效（第 $i 次校验）${N}"; return 0; }
    proxy_write "$port"
    sleep 1
  done
  proxy_check "$port" && return 0
  return 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${R}需要 root：${N} sudo $0 $1"
    exit 1
  fi
}

case "${1:-status}" in

# ================= apply =================
apply)
  need_root "apply"
  ensure_tools || { echo -e "${R}✗ 工具编译失败${N}"; exit 1; }
  PORT="${PORT_ARG:-$(detect_port)}"
  echo -e "${B}=== 把系统代理补到 ppp0 上 ===${N}"
  echo "  端口：127.0.0.1:$PORT（SOCKS）"
  if ! port_listening "$PORT"; then
    echo -e "  ${Y}⚠ 127.0.0.1:$PORT 没人监听${N} —— 现在写进去只会让所有 App 连不上"
    echo "    先确认 v2rayN 在运行、且它确实是这个端口：lsof -nP -iTCP:$PORT -sTCP:LISTEN"
    exit 4
  fi
  if apply_once "$PORT"; then
    echo "    $(scutil --proxy | grep -E 'SOCKSEnable|SOCKSProxy|SOCKSPort' | tr -d ' ' | tr '\n' ' ')"
    printf "    CFNetwork 实测出口："
    "$PROBE" 2>/dev/null || printf "（探测失败）"
  else
    echo -e "  ${R}✗ 写入后校验仍不一致${N}"
    echo "    实际值：$(scutil --proxy | grep -E 'SOCKSEnable|SOCKSProxy|SOCKSPort' | tr -d ' ' | tr '\n' ' ')"
    echo "    如果反复被改回，用 watch/install 持续看护：sudo $0 install $PORT"
    exit 2
  fi
  ;;

# ================= off =================
off)
  need_root "off"
  ensure_tools || true
  if [ -x "$PROXYSET" ]; then "$PROXYSET" off; else
    /usr/sbin/scutil <<'EOF'
d.init
set State:/Network/Global/Proxies
EOF
  fi
  echo -e "  ${G}✓ 已清空${N}（之后由 configd 按各网络服务自己算）"
  ;;

# ================= watch（看护循环）=================
watch)
  need_root "watch"
  ensure_tools || { echo "工具编译失败"; exit 1; }
  PORT="${PORT_ARG:-$(detect_port)}"
  echo "[$(date '+%F %T')] watch 启动，端口 $PORT，ppp0=$(ppp0_up && echo up || echo down)" >> "$WLOG"
  applied=0; misses=0; reverts=0; downs=0
  while :; do
    if ppp0_up; then
      downs=0
      if [ "$PORT" != "" ] && ! port_listening "$PORT"; then
        # 代理软件退出/换端口：先把自己写的那份撤掉，别把上网搞坏
        if [ "$applied" = 1 ]; then
          [ -x "$PROXYSET" ] && "$PROXYSET" off >/dev/null 2>&1
          echo "[$(date '+%F %T')] 端口 $PORT 不再监听 → 已清空代理" >> "$WLOG"
          applied=0
        fi
        sleep 5
        newp=$(detect_port)
        if [ -n "$newp" ] && [ "$newp" != "$PORT" ] && port_listening "$newp"; then
          PORT="$newp"
          echo "[$(date '+%F %T')] 端口切换到 $PORT" >> "$WLOG"
        fi
        continue
      fi
      if ! proxy_check "$PORT"; then
        # 记下「被改成了什么样」，这是判断 configd 有没有删 scoped 条目的唯一线索
        why=$("$PROXYSET" check 127.0.0.1 "$PORT" 2>&1 | tr -d '\n')
        proxy_write "$PORT"
        sleep 1
        if proxy_check "$PORT"; then
          reverts=$((reverts+1))
          if [ "$applied" = 0 ]; then
            echo "[$(date '+%F %T')] 已写入 SOCKS+HTTP 127.0.0.1:$PORT → $("$PROXYSET" check 127.0.0.1 "$PORT" 2>&1)" >> "$WLOG"
          elif [ "$reverts" -le 6 ] || [ $((reverts % 30)) -eq 0 ]; then
            echo "[$(date '+%F %T')] 被改回（第 $reverts 次）：$why → 已重写" >> "$WLOG"
          fi
          applied=1; misses=0
        else
          misses=$((misses+1))
          [ "$misses" -le 3 ] && echo "[$(date '+%F %T')] 写入后仍不一致（第 $misses 次）：$("$PROXYSET" check 127.0.0.1 "$PORT" 2>&1)" >> "$WLOG"
        fi
      else
        applied=1
      fi
    else
      applied=0
      # 拨号脚本现在是「拨通就退出、pppd 留在后台」，这个看护会变成孤儿进程。
      # ppp0 连续 60 秒不在就自己收工（LaunchDaemon 那个由 launchd 管，不动它）。
      downs=$((downs+1))
      if [ "$downs" -ge 30 ] && [ -z "$XPC_SERVICE_NAME" ]; then
        echo "[$(date '+%F %T')] ppp0 已断开 60 秒，看护退出" >> "$WLOG"
        exit 0
      fi
    fi
    sleep 2
  done
  ;;

# ================= install / uninstall =================
install)
  need_root "install"
  ensure_tools || exit 1
  PORT="${PORT_ARG:-$(detect_port)}"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DIR/11-proxy-fix.sh</string>
    <string>watch</string>
    <string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/e398-proxy.out</string>
  <key>StandardErrorPath</key><string>/tmp/e398-proxy.out</string>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"
  launchctl bootout "system/$LABEL" >/dev/null 2>&1
  if launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null; then
    echo -e "  ${G}✓ 已安装 LaunchDaemon${N}：$LABEL（端口 $PORT）"
    echo "    以后 ppp0 一起来就自动把系统代理补上，被 configd 重算掉也会 2 秒内写回。"
    echo "    日志：tail -f $WLOG"
  else
    echo -e "  ${R}✗ launchctl bootstrap 失败${N}，检查 $PLIST"
    exit 1
  fi
  ;;

uninstall)
  need_root "uninstall"
  launchctl bootout "system/$LABEL" >/dev/null 2>&1 || launchctl unload -w "$PLIST" >/dev/null 2>&1
  rm -f "$PLIST"
  echo -e "  ${G}✓ 已卸载${N}（$LABEL）"
  ;;

# ================= probe =================
probe)
  ensure_tools || exit 1
  printf "  CFNetwork（读系统代理）出口："
  "$PROBE" 2>&1 || echo "（失败）"
  printf "  直连（curl，不读系统代理）："
  curl -m 10 -s https://ifconfig.me/ip 2>/dev/null || echo "（失败）"
  echo
  echo "  两个不一样 → 系统代理生效；一样 → 代理没被用上"
  ;;

# ================= status =================
status)
  ensure_tools >/dev/null 2>&1 || true
  echo -e "${B}=== 系统代理现状 ===${N}"
  PORT_NOW=$(scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')
  EN_NOW=$(scutil --proxy 2>/dev/null | awk '/SOCKSEnable/{print $3; exit}')
  if [ -z "$PORT_NOW" ]; then
    echo -e "  有效代理：${R}无${N}  ← 读系统代理的 App 会走直连"
  else
    HOST_NOW=$(scutil --proxy 2>/dev/null | awk '/SOCKSProxy/{print $3; exit}')
    if [ "${EN_NOW:-0}" = "1" ]; then
      echo -e "  有效代理：${G}启用${N}  SOCKS ${HOST_NOW}:${PORT_NOW}"
    else
      echo -e "  有效代理：${R}被禁用${N}（SOCKSEnable=${EN_NOW}，写了等于没写）"
    fi
    if [ -x "$PROXYSET" ]; then
      printf "  ppp0 的 scoped 条目："
      "$PROXYSET" check "${HOST_NOW:-127.0.0.1}" "$PORT_NOW" 2>/dev/null | sed 's/^一致：//'
    fi
  fi
  echo "  探测到的端口：$(detect_port)"
  printf "  主接口："; scutil <<< "show State:/Network/Global/IPv4" | awk '/PrimaryInterface/{print $3}'
  echo "  各服务上的代理设置："
  for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
    out=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null)
    if echo "$out" | grep -q "^Enabled: Yes"; then
      echo "    $svc : $(echo "$out" | awk '/^Server:/{s=$2}/^Port:/{print "SOCKS "s":"$2; exit}')"
    fi
  done
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo -e "  看护进程：${G}已安装${N}（$LABEL）"
  else
    echo "  看护进程：未安装（sudo ./11-proxy-fix.sh install 可常驻）"
  fi
  if [ -x "$PROBE" ]; then
    printf "  实测：CFNetwork 出口 "
    "$PROBE" 2>/dev/null || printf "（失败）"
    printf " / 直连出口 "
    curl -m 10 -s https://ifconfig.me/ip 2>/dev/null
    echo
  fi
  ;;

*)
  echo "用法：sudo $0 apply [端口] | $0 status | $0 probe | sudo $0 watch [端口] | sudo $0 install [端口] | sudo $0 uninstall | sudo $0 off"
  exit 1 ;;
esac
