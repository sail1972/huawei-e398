#!/bin/bash
#
# 15-watch.sh — 抓「断联那一刻」到底发生了什么
#
# 为什么需要它：
#   「偶尔断一下」这种问题，事后看什么都对不上 —— ifconfig 只是没有 ppp0，
#   日志里也没有明显报错。要判断是「USB 被复位」「modem 自己重启」「运营商拆了
#   PDP」还是「pppd 主动退出」，必须在事件发生的当下同时抓住三样东西：
#     1) USB 层的内核日志（端口复位/设备终止/超电流 都在这里）
#     2) 同一时刻的设备 PID（1506 → 1505 说明是 USB 复位，不是单纯掉线）
#     3) pppd 自己说了什么（LCP 超时 / NO CARRIER / 正常 terminate）
#   这个脚本就是一个常驻采样器，一旦发现变化就把上述三样一起存档。
#
# 用法：
#   sudo ./15-watch.sh start      后台常驻（建议用 sudo，内核日志才完整）
#   ./15-watch.sh status          是否在跑 + 采样了多少轮 + 最近一次事件
#   ./15-watch.sh show            打印所有已记录的断联事件（含上下文）
#   ./15-watch.sh show 1          只看最近 1 次
#   sudo ./15-watch.sh stop
#
# 产物（默认 /tmp/e398-watch/）：
#   samples.log   每 3 秒一行：时间 ppp0 地址 设备 PID
#   usb.log       log stream 抓到的 USB/内核事件（超过 8MB 自动截尾）
#   events.log    每次状态变化 + 当时的 USB/pppd/网络快照  ← 主要看这个
#
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
W="${E398_WATCH_DIR:-/tmp/e398-watch}"
SAMP="$W/samples.log"
USB="$W/usb.log"
EV="$W/events.log"
PIDF="$W/watch.pid"
SELF="$(basename "$0")"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

now() { date '+%F %T'; }

# 当前设备 PID：1506 在线 / 1505 零CD / 空 = 没插
# 用 ioreg 而不是 e398_ctrl：后者要 IOServiceMatching 走一趟 IOKit，1~2 秒；
# 这里 3 秒采样一次，能省就省。ioreg 约 1 秒，只在需要时才调（见 sampler）。
usb_pid() {
  local out
  out=$(ioreg -w0 -r -n "HUAWEI Mobile" 2>/dev/null | grep '"idProduct"' | head -1)
  case "$out" in
    *5382*) echo 1506 ;;
    *5381*) echo 1505 ;;
    *)      echo "-" ;;
  esac
}

ppp_addr() {
  ifconfig ppp0 2>/dev/null | awk '/inet /{print $2; exit}'
}

pid_alive() {
  local p="$1"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# ---------- 事件存档 ----------
# 发现状态变化时，立刻把三份现场一起写进 events.log。
# 不做事后回溯（log stream 的缓冲区早就滚过去了），所以必须在当下抓。
snapshot() {  # $1=事件描述
  local desc="$1"
  {
    echo
    echo "=================================================================="
    echo " $desc"
    echo " 时间：$(now)"
    echo "=================================================================="
    echo "--- 网络 ---"
    if ifconfig ppp0 >/dev/null 2>&1; then
      ifconfig ppp0 | grep -E "inet |UP|POINTOPOINT" | sed 's/^/  /'
    else
      echo "  ppp0 不存在"
    fi
    echo "  pppd 进程：$(pgrep -f 'pppd pty' | tr '\n' ' ' | sed 's/ $//')"
    pgrep -f 'pppd pty' >/dev/null 2>&1 || echo "  （没有 pppd 在跑）"
    echo "  桥接进程：$(pgrep -f 'e398_ppp --iface' | tr '\n' ' ')"
    echo
    echo "--- pppd 日志最后 12 行（/tmp/e398-pppd.log）---"
    if [ -f /tmp/e398-pppd.log ]; then
      tail -12 /tmp/e398-pppd.log | sed 's/^/  /'
    else
      echo "  （没有日志）"
    fi
    echo
    echo "--- USB 事件最后 30 行 ---"
    if [ -s "$USB" ]; then
      tail -30 "$USB" | sed 's/^/  /'
    else
      echo "  （usb.log 为空：log stream 没跑起来，或这段时间真没有 USB 事件）"
    fi
    echo
  } >> "$EV"
}

# ---------- 采样循环 ----------
sampler() {
  mkdir -p "$W"
  : >> "$SAMP"; : >> "$USB"; : >> "$EV"

  local last_addr="" last_pid="" n=0
  local down=0 up=0 switch_cnt=0
  local ev_n=0
  local prev_pid_seen=""

  # 启动时先记一条基线，否则第一次"变化"没有参照物
  last_pid=$(usb_pid)
  last_addr=$(ppp_addr)
  echo "$(now) addr=${last_addr:--} pid=${last_pid}" >> "$SAMP"

  while :; do
    sleep 3
    n=$((n+1))

    local addr pid
    addr=$(ppp_addr)
    # USB PID 每 3 轮查一次（ioreg 约 1 秒，没必要每 3 秒都查）
    if [ $((n % 3)) -eq 0 ]; then
      pid=$(usb_pid)
      last_pid="$pid"
    else
      pid="$last_pid"
    fi

    echo "$(now) addr=${addr:--} pid=${pid}" >> "$SAMP"

    # ① 链路掉线
    if [ -n "$last_addr" ] && [ -z "$addr" ]; then
      down=$((down+1))
      snapshot "[事件 $((++ev_n))] 断联：ppp0 消失（原地址 $last_addr，设备 PID $pid）"
    # ② 链路恢复
    elif [ -z "$last_addr" ] && [ -n "$addr" ]; then
      up=$((up+1))
      snapshot "[事件 $((++ev_n))] 恢复：ppp0 拿到 $addr（设备 PID $pid）"
    fi

    # ③ 设备 PID 变化 = USB 复位/重枚举（这是"是掉线还是设备重启"的关键判据）
    if [ -n "$pid" ] && [ "$pid" != "-" ] && [ -n "$prev_pid_seen" ] \
       && [ "$pid" != "$prev_pid_seen" ]; then
      switch_cnt=$((switch_cnt+1))
      snapshot "[事件 $((++ev_n))] 设备 PID 变化：$prev_pid_seen → $pid（USB 复位或重新枚举）"
    fi
    [ -n "$pid" ] && [ "$pid" != "-" ] && prev_pid_seen="$pid"

    last_addr="$addr"

    # 每 200 轮（10 分钟）写一行心跳，用来确认采样器自己没死
    [ $((n % 200)) -eq 0 ] && echo "[$(now)] 心跳：已采样 $n 轮，断联 $down 次，恢复 $up 次，PID 变化 $switch_cnt 次" >> "$EV"

    # 截尾，避免长期跑爆磁盘
    if [ -f "$USB" ] && [ "$(stat -f '%z' "$USB" 2>/dev/null || echo 0)" -gt 8388608 ]; then
      tail -20000 "$USB" > "$USB.tmp" && mv -f "$USB.tmp" "$USB"
    fi
    if [ -f "$EV" ] && [ "$(stat -f '%z' "$EV" 2>/dev/null || echo 0)" -gt 4194304 ]; then
      tail -1500 "$EV" > "$EV.tmp" && mv -f "$EV.tmp" "$EV"
    fi
  done
}

# ---------- 子命令 ----------
case "${1:-status}" in
  start)
    mkdir -p "$W"
    if [ -f "$PIDF" ] && pid_alive "$(cat "$PIDF" 2>/dev/null)"; then
      echo -e "  ${Y}已经在跑了${N}（PID $(cat "$PIDF")）。要重启先 stop。"
      exit 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo -e "  ${Y}注意${N}：不是 root，内核 USB 日志可能抓不全（建议 sudo 运行）"
    fi
    : > "$SAMP"; : > "$USB"; : > "$EV"

    # log stream 单独一个进程，输出进 usb.log。
    # 用独立脚本文件而不是 bash -c 拼引号：predicate 里有双引号，嵌在
    # bash -c "..." 里要转义三层，改一次错一次；落成文件还能直接手工重跑调试。
    cat > "$W/stream.sh" <<'EOS'
#!/bin/bash
# 只留和 USB / 我们的 kext 相关的行：端口复位、设备终止、超电流、
# "not responding" 以及 kext 自己的心跳都在这个范围里。
exec log stream --style compact --level default --predicate '
  senderImagePath CONTAINS "IOUSBHostFamily"
  OR senderImagePath CONTAINS "IOUSBFamily"
  OR eventMessage CONTAINS "E398Switcher"
  OR (process == "kernel" AND eventMessage CONTAINS[c] "usb")'
EOS
    chmod 755 "$W/stream.sh"
    nohup "$W/stream.sh" >> "$USB" 2>&1 &
    echo $! > "$W/stream.pid"

    nohup "$DIR/$SELF" __sampler >> "$W/sampler.out" 2>&1 &
    echo $! > "$PIDF"

    sleep 3
    if pid_alive "$(cat "$PIDF" 2>/dev/null)"; then
      echo -e "  ${G}✓ 已开始记录${N}（PID $(cat "$PIDF")）"
      echo "    目录：$W"
      printf "    断联后看：%b./15-watch.sh show%b\n" "$B" "$N"
      if ! pid_alive "$(cat "$W/stream.pid" 2>/dev/null)"; then
        echo -e "    ${Y}!${N} log stream 没起来（usb.log 会是空的，其余功能照常）"
      fi
    else
      echo -e "  ${R}✗ 启动失败${N}，看 $W/sampler.out"
      exit 1
    fi
    ;;
  __sampler)
    sampler
    ;;
  stop)
    local_ok=1
    if [ -f "$PIDF" ]; then
      p=$(cat "$PIDF")
      if pid_alive "$p"; then kill -TERM "$p" 2>/dev/null; echo "  已停采样器（PID $p）"; else echo "  采样器没在跑"; fi
      rm -f "$PIDF"
    else
      echo "  采样器没在跑"
    fi
    if [ -f "$W/stream.pid" ]; then
      p=$(cat "$W/stream.pid")
      pid_alive "$p" && kill -TERM "$p" 2>/dev/null && echo "  已停 log stream（PID $p）"
      rm -f "$W/stream.pid"
    fi
    # 兜底：按名字清掉可能残留的（比如上次异常退出）
    pkill -f "15-watch.sh __sampler" 2>/dev/null
    echo "  记录保留在 $W/events.log"
    ;;
  status)
    echo -e "${B}=== 断联记录器 ===${N}"
    if [ -f "$PIDF" ] && pid_alive "$(cat "$PIDF" 2>/dev/null)"; then
      echo -e "  状态：${G}运行中${N}（PID $(cat "$PIDF")）"
    else
      echo -e "  状态：${Y}没在跑${N}（sudo ./15-watch.sh start）"
    fi
    if [ -f "$W/stream.pid" ] && pid_alive "$(cat "$W/stream.pid" 2>/dev/null)"; then
      echo "  USB 日志：采集正常（$(du -h "$USB" 2>/dev/null | awk '{print $1}')）"
    else
      echo -e "  USB 日志：${Y}log stream 没跑${N}"
    fi
    [ -f "$SAMP" ] && echo "  已采样：$(wc -l < "$SAMP" | tr -d ' ') 轮（约 $(( $(wc -l < "$SAMP") * 3 / 60 )) 分钟）"
    n_ev=$(grep -c '^\[事件' "$EV" 2>/dev/null || true)
    n_ev=${n_ev:-0}
    echo "  已记录事件：$n_ev 个"
    if [ "$n_ev" -gt 0 ]; then
      echo "  最近一次："
      grep '^\[事件' "$EV" | tail -1 | sed 's/^/    /'
    fi
    ;;
  show)
    n="${2:-0}"
    if [ ! -s "$EV" ]; then
      echo "  还没有记录。先 sudo ./15-watch.sh start，然后等它断一次（或者现在断一下试试）。"
      exit 0
    fi
    if [ "$n" -gt 0 ] 2>/dev/null; then
      # 只打印最近 n 个事件的段落
      awk -v keep="$n" '
        /^\[事件/ { idx++ }
        { buf[idx] = buf[idx] $0 "\n" }
        END { start = idx - keep + 1; if (start < 1) start = 1;
              for (i = start; i <= idx; i++) printf "%s", buf[i] }' "$EV"
    else
      cat "$EV"
    fi
    ;;
  *)
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
