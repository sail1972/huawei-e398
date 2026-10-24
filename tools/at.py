#!/usr/bin/env python3
"""极简 AT 命令收发工具（不依赖 pyserial）

用法:
  ./at.py <设备> <命令> [超时秒]      # 单条
  ./at.py <设备> -f <脚本文件>        # 逐行发送，空行/以#开头跳过
"""
import os
import select
import sys
import termios
import time
import tty


def open_port(dev):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        tty.setraw(fd)
    except termios.error:
        pass
    attrs = termios.tcgetattr(fd)
    attrs[4] = attrs[5] = termios.B115200
    attrs[2] |= termios.CLOCAL | termios.CREAD
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_until(fd, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r:
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if b"OK" in buf or b"ERROR" in buf or b"+CME ERROR" in buf:
            break
    return buf.decode("utf-8", "replace")


def send(fd, cmd, timeout=2.0):
    os.write(fd, (cmd + "\r").encode())
    return read_until(fd, timeout)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    dev = sys.argv[1]
    argc = sys.argv[2:]
    fd = open_port(dev)
    try:
        if argc[0] == "-f":
            for line in open(argc[1], encoding="utf-8"):
                cmd = line.strip()
                if not cmd or cmd.startswith("#"):
                    continue
                print(">> " + cmd)
                print(send(fd, cmd, 3.0).strip())
            return 0
        timeout = float(argc[1]) if len(argc) > 1 else 2.0
        print(send(fd, argc[0], timeout).strip())
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
