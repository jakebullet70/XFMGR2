"""
png2bmx.py - convert any image (PNG/JPG/...) to a Commander X16 "BMX" bitmap file,
ready to view in XFMGR2 (press V on a *.bmx file).

Wraps irmen's cx16images.py quantizer (12-bit / 4-bit-per-channel indexed color) and
serializes the result as an uncompressed BMX v1 file. BMX layout mirrors bmx.p8's
build_header(): 32-byte header + palette (2 bytes/color, VERA GB0R little-endian) + pixels.

Requirements: Pillow  (pip install pillow)   and cx16images.py next to this script.

Usage:
    python png2bmx.py photo.jpg -o photo.bmx
    python png2bmx.py logo.png  -o logo.bmx -b 4 -d none
    python png2bmx.py pic.png   -o pic.bmx --preserve-default-16

Notes:
  * Default 320x240 lores fit: images larger than the screen are scaled down (aspect kept),
    smaller ones are NOT padded - XFMGR2 centers a smaller image itself ("stamp" load).
  * -b/--bpp 8 (256 colors) is the default; 1/2/4 also supported (pixels packed MSB-first).
"""

import argparse
import struct
import cx16images

BMX_COLORDEPTH = {1: 0, 2: 1, 4: 2, 8: 3}   # bmx.p8 vera_colordepth for each bpp


def pack_scanlines(bm, bpp: int) -> bytes:
    """Return the bitmap pixel data, each scanline byte-aligned, pixels packed MSB-first."""
    w, h = bm.width, bm.height
    if bpp == 8:
        return bytes(bm.get_pixels_8bpp(0, 0, w, h))
    pix = bm.img.load()
    per_byte = 8 // bpp
    row_bytes = (w + per_byte - 1) // per_byte
    out = bytearray(row_bytes * h)
    mask = (1 << bpp) - 1
    for y in range(h):
        base = y * row_bytes
        for x in range(w):
            idx = pix[x, y] & mask
            byte_i = base + (x // per_byte)
            shift = 8 - bpp - (x % per_byte) * bpp   # MSB-first
            out[byte_i] |= idx << shift
    return bytes(out)


def write_bmx(bm, bpp: int, filename: str, border: int = 0) -> None:
    palette = bm.get_vera_palette()          # GB0R words, little-endian, 2 bytes/color
    ncolors = len(palette) // 2
    w, h = bm.width, bm.height
    data_offset = ncolors * 2 + 32

    header = bytearray(32)
    header[0:3] = b"BMX"                     # on-disk magic $42,$4D,$58 (= petscii "bmx"; bmx.p8 FILEID)
    header[3] = 1                            # version
    header[4] = bpp
    header[5] = BMX_COLORDEPTH[bpp]
    struct.pack_into("<H", header, 6, w)
    struct.pack_into("<H", header, 8, h)
    header[10] = ncolors & 0xFF              # 256 -> 0
    header[11] = 0                           # palette_start
    struct.pack_into("<H", header, 12, data_offset)
    header[14] = 0                           # compression (uncompressed)
    header[15] = border

    with open(filename, "wb") as f:
        f.write(header)
        f.write(palette)
        f.write(pack_scanlines(bm, bpp))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Convert an image to a Commander X16 BMX bitmap file for XFMGR2")
    ap.add_argument("input", help="input image file (any format Pillow can read)")
    ap.add_argument("-o", "--output", default="output.bmx", help="output .bmx file (default: output.bmx)")
    ap.add_argument("-b", "--bpp", type=int, choices=[1, 2, 4, 8], default=8, help="bits per pixel (default: 8)")
    ap.add_argument("-d", "--dither", choices=["floydsteinberg", "ordered", "none"], default="floydsteinberg",
                    help="dither method (default: floydsteinberg)")
    ap.add_argument("--preserve-default-16", action="store_true",
                    help="keep first 16 palette entries as the X16 default palette")
    ap.add_argument("--border", type=int, default=0, help="border/background color index (default: 0)")
    args = ap.parse_args()

    from PIL import Image
    dither_map = {
        "floydsteinberg": Image.Dither.FLOYDSTEINBERG,
        "ordered": Image.Dither.ORDERED,
        "none": Image.Dither.NONE,
    }

    bm = cx16images.BitmapImage(args.input)
    bm.constrain_size(hires=False)
    bm.quantize(args.bpp, preserve_first_16_colors=args.preserve_default_16, dither=dither_map[args.dither])
    write_bmx(bm, args.bpp, args.output, border=args.border)
    print(f"wrote {args.output}  ({bm.width}x{bm.height}, {args.bpp}bpp, {len(bm.get_vera_palette())//2} colors)")
