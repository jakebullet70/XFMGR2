---
name: xfmgr-bmx-image-viewer
description: BMX image viewer overlay + png2bmx converter tooling for XFMGR2
metadata: 
  node_type: memory
  type: reference
  originSessionId: 34a3aff3-3870-4671-a1b8-ab8c9f46ea15
---

XFMGR2 has a BMX image viewer: pressing **V** on a BMX file dispatches to `SRC/ximgview.p8`
(a banked `%output library` overlay in reserved HIRAM **bank 5**, `IMG_BANK`), which shows the
native X16 BMX bitmap full-screen (320x240) and returns to text mode on any key. It mirrors the
`SRC/tview.p8` overlay pattern and adapts `docs/prog8/examples/showbmx.p8` + the vendored
`docs/prog8/cx16/bmx.p8` loader (palette + bitmap load straight into VRAM). Adding it bumped the
arena floor `xarena.FIRST_BANK` 5 -> 6.

**Dispatch = magic-byte sniff, NOT filename extension.** `file_is_bmx()` in `SRC/xfmgr.p8` opens the
file and checks the first 3 bytes are `$42,$4D,$58` (= petscii "bmx" = ascii "BMX", bmx.p8 FILEID).
Name-extension matching was tried first and FAILED: the emulator host-fs (`-fsroot`) returns
filenames as **lowercase ASCII** ('b'=$62), not the petscii $42 the code assumed. Content bytes have
no such ambiguity. Same trick tview uses for ZSM (zsm_detect).

**Two gotchas that bit during bring-up:**
- Returning from the viewer: the overlay's `cbm.CINT()` + `cx16.set_screen_mode()` reset VERA to the
  **uppercase charset**, so the V handler must re-call `txt.lowercase()` after set_screen_mode.
- BMX on-disk magic is uppercase-ascii `b"BMX"` ($42,$4D,$58), NOT `b"bmx"` ($62,$6D,$78) - png2bmx
  writes `b"BMX"`.

**Making .bmx assets** (`tools/`):
- `tools/cx16images.py` = irmen's quantizer (image -> 12-bit indexed PNG/BMP; does NOT emit .bmx).
- `tools/png2bmx.py` = our wrapper: any image -> real .bmx. Run from `tools/` so `import cx16images` resolves:
  `python png2bmx.py IN.png -o OUT.bmx [-b 1|2|4|8] [-d none] [--preserve-default-16]`.
- Needs Pillow. **Python is NOT on PATH here** — installed at
  `C:\Users\Admin\AppData\Local\Programs\Python\Python312\python.exe` (3.12.10, Pillow 12.3.0).
- A quick no-Python test asset can be built in PowerShell (header 32B + palette 512B + WxH pixels);
  `run/test.bmx` was made that way. `run/photo.bmx` was made via png2bmx.

See [[xfmgr-run-and-persistence]], [[prog8-build-toolchain]], [[user-tests-in-emulator-themselves]].
