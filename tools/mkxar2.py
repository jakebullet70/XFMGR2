#!/usr/bin/env python3
# mkxar2.py -- author a XAR2 (LZSA2) archive for XFMGR2.
#
# XFMGR2's xar.ovl can EXTRACT XAR2 (LZSA2) archives on the X16 via the ROM's
# memory_decompress ($FEED), but the X16 has NO LZSA2 compressor, so XAR2 files
# must be authored off-device with this tool + the `lzsa` CLI.
#
#   XAR1 = RLE/PackBits  -> X16 can both create AND extract (in-app 'a' key)
#   XAR2 = LZSA2 blocks  -> desktop-authored here, X16 extract-only
#
# Requires lzsa (https://github.com/emmanuel-marty/lzsa). Blocks use `-r -f2`,
# the exact raw-LZSA2 opts the X16 ROM and MAKECPLZ use.
#
# Usage:
#   python mkxar2.py <lzsa.exe> <out.xar> "name1=path1" ["name2=path2" ...]
#
# Each member is chunked to CHUNK(250) raw bytes (xar.p8's bufB is 256), every
# chunk compressed independently and self-verified by round-trip before writing.

import sys, os, subprocess, struct, tempfile

LZSA = sys.argv[1]          # path to lzsa.exe
OUT  = sys.argv[2]          # output .xar
CHUNK = 250                 # must match xar.p8 CONST CHUNK (bufB is 256)

# members: list of (archive_name_bytes, data_bytes)
members = []
for spec in sys.argv[3:]:
    name, path = spec.split('=', 1)
    members.append((name.encode('ascii'), open(path, 'rb').read()))

def lz_block(raw: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        i = os.path.join(d, 'in'); o = os.path.join(d, 'out')
        open(i, 'wb').write(raw)
        subprocess.run([LZSA, '-r', '-f2', i, o], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        enc = open(o, 'rb').read()
        # self-verify: decompress the raw block back and compare
        i2 = os.path.join(d, 'in2'); o2 = os.path.join(d, 'out2')
        open(i2, 'wb').write(enc)
        subprocess.run([LZSA, '-d', '-r', '-f2', i2, o2], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        back = open(o2, 'rb').read()
        assert back == raw, "round-trip mismatch (len %d vs %d)" % (len(back), len(raw))
        return enc

buf = bytearray(b'XAR2')
buf.append(len(members))
# payloads
for name, data in members:
    off = 0
    while off < len(data):
        raw = data[off:off+CHUNK]
        enc = lz_block(raw)
        assert len(raw) <= 0xFFFF and len(enc) <= 0xFFFF
        buf += struct.pack('<H', len(raw))
        buf += struct.pack('<H', len(enc))
        buf += enc
        off += len(raw)
    buf += struct.pack('<H', 0)     # raw_len==0 ends the payload
# directory
for name, data in members:
    blocks = (len(data) + 255) // 256
    buf += struct.pack('<H', blocks)
    buf.append(len(name))
    buf += name

open(OUT, 'wb').write(buf)
print("wrote %s : %d bytes, %d member(s)" % (OUT, len(buf), len(members)))
for name, data in members:
    print("  member %r : %d bytes raw -> %d chunk(s)" % (name.decode(), len(data), (len(data)+CHUNK-1)//CHUNK))
