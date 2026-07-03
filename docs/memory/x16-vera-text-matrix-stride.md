---
name: x16-vera-text-matrix-stride
description: "X16 VERA text matrix uses a fixed 256-byte row stride (128 cols/row), NOT width*2 — read/write cells via txt.getclr/setclr/getchr/setchr, never a hand-computed VERA address"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

The Commander X16 VERA **text matrix rows are 256 bytes apart** (128 columns × 2 bytes/cell), a
fixed power-of-2 stride, regardless of the visible width (80). So the VRAM address of cell (col,row)
is `TEXTMATRIX_BASE + row*256 + col*2` (char) / `+1` (colour) — **NOT** `(row*width+col)*2`.

Computing it as `row*width*2` reads the WRONG cell for any `row>0`. This bit the machine-state
"save the user's text colour on launch" code (2026-07-03, XFMGR builds 119→121): a hand-rolled
`vpeek($1B000 + (row*width+col)*2 + 1)` returned a garbage cell → "background colour is bad" on exit.

Fix / rule: use prog8 textio's cell accessors, which encode the correct 256-byte stride in asm:
- `txt.getclr(col @A, row @Y) -> ubyte` — colour byte (VERA text: **high nibble = bg, low nibble =
  fg**; pair with `txt.color2(byte & 15, byte >> 4)`).
- `txt.setclr(col,row,colour)`, `txt.getchr`, `txt.setchr` — same layout.
These pair with the KERNAL default map base, so they read back exactly what BASIC/the KERNAL wrote,
and work across the standard 80-col text modes (80x60 launch mode and XFMGR's 80x30). Reading the
current text colour has no KERNAL getter, so `txt.getclr` at the cursor cell (`txt.get_cursor()`) is
the way. Related: [[xfmgr-editor-bank-handoff]], [[prog8-build-toolchain]].
