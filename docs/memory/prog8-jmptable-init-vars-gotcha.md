---
name: prog8-jmptable-init-vars-gotcha
description: "%jmptable offsets break if the main block has INITIALIZED variables"
metadata: 
  node_type: memory
  type: project
  originSessionId: f57043d0-c280-46a9-ba6d-9010f3f42cb2
---

In a prog8 `%output library` overlay, `%jmptable` only lands at the expected fixed
offsets if the block holding it has **no initialized variables**. prog8 emits a block's
INITIALIZED variables (e.g. `str x = "?"*80`, any `= value`) *inline before* its code and
jump table, shoving the table down; UNinitialized vars go to the relocated BSS section at
the tail and cost nothing inline.

**Symptom that found it (tview banked viewer):** `extsub @bank 2 $A003 = view_file` called
into `$3F` filler bytes (`namebuf`'s "?" data) instead of `jmp view_file`. `$3F` = `BBR3
zp,rel`; executing that garbage bounced on zero-page state — by luck fell through to the real
`jmp` sometimes (viewer worked) and hit `$00`/BRK other times (crash). Classic "works once,
crashes the second call" because ZP differed between calls.

**Fix:** declare the buffers uninitialized so they go to BSS. `str namebuf = "?"*80` →
`ubyte[81] namebuf`; `str view_find = "?"*33` → `ubyte[34] view_find`. `ubyte[]` is accepted
anywhere a `str` param is expected (decays to a uword pointer). Layout then is the intended
`$A000 jmp start` / `$A003 jmp view_file`, and the offsets stay stable across rebuilds.

**How to verify:** after building, check `tview.vice-mon-list` — the jumptable target sub can
be anywhere, but the 3 bytes at `$A003` must be `jmp <that sub>` (confirm `p8s_start` = `$A006`,
proving `$A003-$A005` is the table entry). See [[x16-launch-program-dynamic-keyboard]] and the
overlay design in [[xfmgr-drop-viewer-ram]].

**`memory()` slab in an overlay (same trap, subtler):** a big buffer (>256 bytes, prog8's array
cap) must be a `memory()` slab, but `uword hist_buf = memory("name", 500, 0)` is an INITIALIZED
var — it emits the 2-byte slab address inline before the jump table and shifts every offset.
Fix: declare `uword hist_buf` UNINITIALIZED and assign it in `start()`:
`hist_buf = memory("name", 500, 0)`. The reservation is compile-time; the runtime assignment of
that constant costs nothing inline. (miscutil's 500 B input-history ring, added alongside prune.)
Also, each `@R0/@R1` entry param must be captured into a local at the very top of the sub before
any `strings.*`/`diskio.*` call (which clobber `cx16.r0-r3`) — prog8 warns "reusing R0-R15 as
parameters risks overwriting"; the capture makes it safe. See [[xfmgr-run-utils-and-return]].
