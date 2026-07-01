---
name: xfmgr-editor-bank-handoff
description: "op_edit must give X16 Edit lastbank = xarena.max_bank, never a hardcoded 255"
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

When XFMGR2 launches X16 Edit (`op_edit()` in SRC/xfmgr.p8), it calls
`cx16.x16edit_loadfile_options(firstbank, lastbank, ...)` — entry point $C006,
"Load file with options 1" — to reserve banked RAM. The **last bank passed MUST be
`xarena.max_bank`** (the runtime-detected top bank), NOT a hardcoded 255.

**Why:** A stock 512 KB X16 has only 64 banks (0-63). Telling the editor it may
use up to bank 255 makes a large edit roll into banks 64+, which **alias back onto
0-63 and corrupt** XFMGR2's dir-extras (bank 1) and file arena (banks 2+). This is
the same aliasing `xarena` guards against for its own allocator via `max_bank`.

**How to apply:** `firstbank = xarena.high_bank + 1`, `lastbank = xarena.max_bank`.
Also guard `if xarena.high_bank >= xarena.max_bank` (arena filled all RAM) → flash
and return, before touching charset/ROM state — this also avoids the ubyte overflow
where `high_bank + 1` wraps to 0 when `high_bank == 255`.

**Verified:** at 512 KB the editor's Ctrl+M reports ~1892 blocks (~464 KB), not the
~8000 blocks (~2 MB) the old hardcoded-255 build advertised. See
[[x16-banked-ram-min-config]] (stock = banks 0-63, reserve the lowest bank).
