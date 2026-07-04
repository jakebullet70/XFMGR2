#!/usr/bin/env python3
# mklz16.py -- author a .LZ16 compressed file for the X16 xcplz.prg decompressor.
#
# Console-independent replacement for MAKECPLZ.exe (single-file mode): calls the
# `lzsa` CLI directly via subprocess, so it never blocks on a console the way
# MAKECPLZ's internal SHELL-out does. Produces a byte-identical header to
# MAKECPLZ for the same input + chunk size.
#
# LZ16 format (see tools/CPLZ-APPS/LZ16-COMPRESSED-FORMAT.TXT):
#   HEADER (19 bytes, X16 reads it at $450):
#     "LZ16"                4 bytes  magic
#     OUTSIZE               5 bytes  CBM float  -- total uncompressed size
#     NUMCHUNKS             5 bytes  CBM float  -- number of chunks
#     DEFAULTCHUNK_SIZE     2 bytes  uint LE    -- uncompressed size of every chunk but last
#     LASTCHK_SIZE          2 bytes  uint LE    -- uncompressed size of the last chunk
#     OUTNAMELENGTH         1 byte              -- length of stored filename
#   FILENAME                N bytes  (no terminator)
#   then per chunk:
#     "zc"                  2 bytes  magic
#     CHK_COMPRESSED_SIZE   2 bytes  uint LE    -- compressed byte count that follows
#     <compressed data>              raw LZSA2 block (lzsa -r -f2), decoded by ROM memory_decompress
#
# Usage:
#   python mklz16.py <lzsa.exe> <input_file> [CS=<4096..60416>] [name=<stored_name>]
#
# CS defaults to 45000 (MAKECPLZ's default). Each chunk is self-verified by
# round-tripping through `lzsa -d` before it is written.

import sys, os, subprocess, struct, tempfile

def cbm_float(n: int) -> bytes:
    """Encode a non-negative integer as a 5-byte Commodore BASIC (MFLPT) float."""
    if n == 0:
        return bytes(5)
    e = n.bit_length() - 1                      # 2^e <= n < 2^(e+1)
    trueM = (n << (31 - e)) if (31 - e) >= 0 else (n >> (e - 31))
    expbyte = e + 129                           # bias 129
    M = trueM & 0x7FFFFFFF                       # drop implied leading 1 / hold sign=0 (positive)
    return bytes([expbyte]) + M.to_bytes(4, 'big')

def lz_block(lzsa: str, raw: bytes) -> bytes:
    """Compress one chunk to a raw LZSA2 block and self-verify the round-trip."""
    with tempfile.TemporaryDirectory() as d:
        i = os.path.join(d, 'in'); o = os.path.join(d, 'out')
        open(i, 'wb').write(raw)
        subprocess.run([lzsa, '-r', '-f2', i, o], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        enc = open(o, 'rb').read()
        i2 = os.path.join(d, 'in2'); o2 = os.path.join(d, 'out2')
        open(i2, 'wb').write(enc)
        subprocess.run([lzsa, '-d', '-r', '-f2', i2, o2], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        back = open(o2, 'rb').read()
        assert back == raw, "round-trip mismatch (%d vs %d bytes)" % (len(back), len(raw))
        assert len(enc) <= 0xFFFF, "compressed chunk too big for 16-bit size field"
        return enc

def main():
    if len(sys.argv) < 3:
        print("usage: python mklz16.py <lzsa.exe> <input_file> [CS=N] [name=STORED]")
        sys.exit(2)
    lzsa   = sys.argv[1]
    inpath = sys.argv[2]
    cs     = 45000
    stored = os.path.basename(inpath)
    for a in sys.argv[3:]:
        if a.upper().startswith("CS="):
            cs = int(a.split('=', 1)[1])
        elif a.lower().startswith("name="):
            stored = a.split('=', 1)[1]
    if not (4096 <= cs <= 60416):
        print("CS must be 4096..60416 (X16 VRAM decompress limit)"); sys.exit(2)

    data = open(inpath, 'rb').read()
    outsize = len(data)
    if outsize == 0:
        print("empty input"); sys.exit(2)

    # split into DEFAULTCHUNK-sized pieces; last piece is whatever remains
    chunks = [data[o:o+cs] for o in range(0, outsize, cs)]
    numchunks = len(chunks)
    lastchk = len(chunks[-1])
    name = stored.encode('ascii')
    assert len(name) <= 255, "stored name too long"

    body = bytearray()
    for idx, raw in enumerate(chunks):
        enc = lz_block(lzsa, raw)
        body += b'zc'
        body += struct.pack('<H', len(enc))
        body += enc

    hdr = bytearray()
    hdr += b'LZ16'
    hdr += cbm_float(outsize)
    hdr += cbm_float(numchunks)
    hdr += struct.pack('<H', cs)             # DEFAULTCHUNK_SIZE
    hdr += struct.pack('<H', lastchk)        # LASTCHK_SIZE
    hdr.append(len(name))
    hdr += name

    outpath = os.path.splitext(inpath)[0] + ".LZ16"
    with open(outpath, 'wb') as f:
        f.write(hdr)
        f.write(body)

    total = len(hdr) + len(body)
    print("wrote %s : %d bytes (header %d + payload %d)" % (outpath, total, len(hdr), len(body)))
    print("  uncompressed %d B in %d chunk(s) of %d (last %d) -> stored name %r"
          % (outsize, numchunks, cs, lastchk, stored))
    print("  ratio %.1f%%" % (100.0 * len(body) / outsize))

if __name__ == '__main__':
    main()
