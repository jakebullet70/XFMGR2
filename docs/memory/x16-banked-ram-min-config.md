---
name: x16-banked-ram-min-config
description: Don't assume high HIRAM banks exist; reserve the LOWEST bank for fixed tables
metadata:
  type: reference
---

A stock Commander X16 ships with 512 KB of banked RAM = banks **0-63** only (bank 0 is the
Kernal's). The address space allows banks up to 255 (2 MB) but those banks only exist on an
upgraded machine. So code must NOT hardcode a high bank (e.g. 255) for storage — it would
read/write nothing on a default machine.

**How to apply:** when reserving a fixed bank for a table (as XFMGR2 does for the xtree
dir-extras side-table), reserve the **lowest** bank and grow the dynamic allocator upward
from there. XFMGR2 uses bank 1 for the 7-byte/node dir-extras record and sets
`xarena.FIRST_BANK = 2` so the bump allocator never collides with it. Bank 1 is guaranteed
present on every X16. See [[xfmgr-architecture]].
