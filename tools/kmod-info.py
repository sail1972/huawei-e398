#!/usr/bin/env python3
"""
kmod-info.py — 直接读 kext 二进制里的 _kmod_info，把内核关心的字段打出来。

为什么需要它：
    kmutil 只检查「有没有 _kmod_info 这个符号」，不检查里面的 start/stop 是不是 NULL。
    而内核在载入时会检查：
        Kext <id> - NULL module start pointer.
        Kext <id> start failed (result 0xdc008007).
    一旦 start 是 NULL，整个 kext 载入被回滚 —— 类不会注册到 IOCatalogue，
    表现就是「kmutil list 里能看到版本号，但驱动服务从未出现」。

用法：
    kmod-info.py <kext 里的可执行文件>
    kmod-info.py --check <file>     # start 为 NULL 时返回 1

struct kmod_info 布局（__DATA,__data，pack(4)，共 0xC4 字节）：
    0x00 next              0x08 info_version      0x0C id
    0x10 name[64]          0x50 version[64]
    0x90 reference_count   0x94 reference_list
    0x9C address           0xA4 size              0xAC hdr_size
    0xB4 start             0xBC stop
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2

OFF_START = 0xB4
OFF_STOP = 0xBC


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def load_sections(data):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        die("不是 64 位 Mach-O（magic=0x%08x）" % magic)
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    sections = []
    symtab = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            so = off + 72
            for _ in range(nsects):
                sectname = data[so:so + 16].rstrip(b"\0").decode("latin-1")
                segname = data[so + 16:so + 32].rstrip(b"\0").decode("latin-1")
                addr, size = struct.unpack_from("<QQ", data, so + 32)
                foff = struct.unpack_from("<I", data, so + 48)[0]
                sections.append((segname, sectname, addr, size, foff))
                so += 80
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            symtab = (symoff, nsyms, stroff, strsize)
        off += cmdsize
    return sections, symtab


def find_symbol(data, sections, symtab, name):
    if not symtab:
        die("没有符号表（被 strip 过？）")
    symoff, nsyms, stroff, _ = symtab
    want = name.encode()
    for i in range(nsyms):
        base = symoff + i * 16
        n_strx = struct.unpack_from("<I", data, base)[0]
        n_value = struct.unpack_from("<Q", data, base + 8)[0]
        end = data.index(b"\0", stroff + n_strx)
        if data[stroff + n_strx:end] == want:
            return n_value
    return None


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if len(args) != 1:
        die(__doc__)
    path = args[0]
    data = open(path, "rb").read()

    sections, symtab = load_sections(data)
    addr = find_symbol(data, sections, symtab, "_kmod_info")
    if addr is None:
        print("  ✗ 符号表里没有 _kmod_info")
        return 1

    loc = None
    for seg, sect, saddr, ssize, foff in sections:
        if saddr <= addr < saddr + ssize:
            loc = (seg, sect, foff + (addr - saddr))
            break
    if loc is None:
        print("  ✗ _kmod_info 的地址 0x%x 不落在任何 section 里" % addr)
        return 1

    seg, sect, file_off = loc
    blob = data[file_off:file_off + 0xC4]
    if len(blob) < 0xC4:
        print("  ✗ 读不到完整的 kmod_info（只有 %d 字节）" % len(blob))
        return 1

    info_version, kid = struct.unpack_from("<II", blob, 0x08)
    name = blob[0x10:0x50].split(b"\0")[0].decode("latin-1")
    version = blob[0x50:0x90].split(b"\0")[0].decode("latin-1")
    start, stop = struct.unpack_from("<QQ", blob, OFF_START)

    print("  _kmod_info @ %s,%s +0x%x（文件偏移 0x%x）" % (seg, sect, addr - 0, file_off))
    print("  info_version = %d   id = 0x%x" % (info_version, kid))
    print("  name         = %r" % name)
    print("  version      = %r" % version)
    print("  start        = 0x%016x%s" % (start, "" if start else "   ← NULL！内核会拒绝载入"))
    print("  stop         = 0x%016x%s" % (stop, "" if stop else "   ← NULL"))

    if info_version != 1:
        print("  ⚠ info_version 不是 1，内核可能拒绝这个结构")
    if check and start == 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
