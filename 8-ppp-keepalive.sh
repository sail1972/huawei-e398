#!/bin/bash
#
# 8-ppp-keepalive.sh — 让 4G 链路自己活着
#
# 背景：
#   E398 拔插断电后会回到 12d1:1505，kext（v1.7.0）会自动切回 1506；
#   但 PPP 会话不会自己重建，必须重新拨号。这个脚本就是一个看护循环：
#   ppp0 掉了就重新拨一次号，直到你不想要为止。
#
# 用法：
#   sudo ./8-ppp-keepalive.sh start      后台启动（关终端不断）
#   ./8-ppp-keepalive.sh status          看是否在跑 + 当前链路
#   sudo ./8-ppp-keepalive.sh stop       停止看护（不会断开现有连接）
#   sudo ./8-ppp-keepalive.sh stop --down 停止看护并断开
#
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/e398-keepalive.log
APN="${2:-}"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

alive() { ifconfig ppp0 2>/dev/null | grep -q "inet "; }

watch_loop() {
  local n=0
  while :; do
    if alive; then
      sleep 15
      continue
    fi
    n=$((n+1))
    echo "[$(date '+%F %T')] ppp0 不在线，第 $n 次尝试拨号" >> "$LOG"
    # 拨号脚本自己会在「拨通」或「放弃」后返回（pppd 由它 nohup 留在后台），
    # 所以这里拿到返回值就代表这一轮有结论了，交给下面的 alive 判断下一轮。
    "$DIR/5-ppp-dial.sh" $APN >> "$LOG" 2>&1
    echo "[$(date '+%F %T')] 拨号脚本返回（pppd 在后台或已失败），10 秒后再查 ppp0" >> "$LOG"
    sleep 10
  done
}

case "${1:-status}" in
  start)
    if [ "$(id -u)" -ne 0 ]; then
      echo -e "${R}需要 root：${N} sudo $0 start"; exit 1
    fi
    if pgrep -f "8-ppp-keepalive.sh watch" >/dev/null 2>&1; then
      echo -e "  ${Y}看护已经在跑${N}（要重启先 stop）"; exit 0
    fi
    : > "$LOG"
    nohup "$DIR/8-ppp-keepalive.sh" watch $APN >> "$LOG" 2>&1 &
    sleep 2
    if pgrep -f "8-ppp-keepalive.sh watch" >/dev/null 2>&1; then
      echo -e "  ${G}✓ 看护已启动${N}（PID $(pgrep -f '8-ppp-keepalive.sh watch' | head -1)）"
      echo "    ppp0 掉线会自动重拨；日志 $LOG"
    else
      echo -e "  ${R}✗ 启动失败${N}，看 $LOG"
    fi
    ;;
  watch)
    watch_loop
    ;;
  stop)
    pkill -f "8-ppp-keepalive.sh watch" 2>/dev/null \
      && echo -e "  ${G}✓ 看护已停止${N}" || echo "  看护本来就没在跑"
    if [ "${2:-}" = "--down" ]; then
      "$DIR/5-ppp-dial.sh" --down
    fi
    ;;
  status)
    if pgrep -f "8-ppp-keepalive.sh watch" >/dev/null 2>&1; then
      echo -e "  看护：${G}运行中${N}（PID $(pgrep -f '8-ppp-keepalive.sh watch' | head -1)）"
    else
      echo "  看护：未运行（sudo ./8-ppp-keepalive.sh start）"
    fi
    "$DIR/5-ppp-dial.sh" --status
    ;;
  *)
    echo "用法：sudo $0 start|stop|status [APN]"; exit 1 ;;
esac
