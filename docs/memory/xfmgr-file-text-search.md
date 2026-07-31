---
name: xfmgr-file-text-search
description: "DONE build 214-225: Ctrl-S/Ctrl-E content-searches the TAGGED files of the CURRENT dir, untagging misses; Ctrl-V/Ctrl-L then reads what survived"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T14:08:03.706Z
---

**DONE build 214-225 (2026-07-31).** The XTree working loop, in the **NORMAL file pane** (Global was
pulled to make room - [[xfmgr-showall-revisit]]):

**tag** (`T` one / `Ctrl-T` all / `Ctrl-W` wildcard) -> **narrow** (`Ctrl-S`) -> **read** (`Ctrl-V`).

**Search = prune the tag set** (XTree Ctrl-S model): it makes no results list. It scans the currently
TAGGED files of THIS directory and UNTAGS every one whose CONTENTS lack the term, so only matches stay
tagged. `op_search_tagged` drives it; the per-file byte scan is still `content_scan(dir,name,term)` in
the **miscutil overlay** (bank 3, $A021) with the encoding-agnostic `fold_byte` (ASCII/PETSCII, either
case, all fold together - [[prog8-ascii-file-byte-match]]). Term capped 32 (SCAN_TCAP). During the scan
the **file-pane highlight bar walks to each file** (`file_cursor` + `draw_files_cursor()`) and
`draw_status()` ticks the top-right "N Tagged" down on each miss. No closing banner - the live counter
and the '*' markers already tell the story.

**Sequential viewer** `view_tagged()`: walks the tagged files BY INDEX (not a for-loop, so it can go
backwards). `view_file(...setmode 1...)` returns **0=quit, 1=next file, 2=previous**; running off either
end softly re-shows the current file. Shows "File n/m" in the footer.

**The search term persists** in `str srch_term` (its OWN storage in main - it must survive from the
search until a later Ctrl-V, and any shared cold slot would be clobbered by a copy/move or Find). It is
passed to the viewer as a 4th param, which pre-seeds `view_find` so **every file opens ON its first hit,
highlighted**.

**Viewer keys during a walk:** `N`/`Space` = next match, and when a file's hits run out they **roll on
into the next file** (this is the "go through dozens of files just by doing NEXT" the user asked for).
`+`/`-` step files directly. `Space` is find-next like native XTree - never overload it with next-file.
With no search term active, N/Space in a walk simply means next file.

**Adaptive keys** (the emulator eats Ctrl-S AND Ctrl-V): Search = Ctrl-S hw / **Ctrl-E** emu, View =
Ctrl-V hw / **Ctrl-L** emu. See [[x16-adaptive-ctrl-keys]] for the pattern and why L (not B or Q).

**Trap, cost several builds:** the renderer highlights `view_match..+len` whenever `view_find` is
non-empty, and a FAILED search used to leave the term set while `view_match` kept a stale offset -> a
bogus highlight over unrelated text. **Always clear `view_find[0]` on a miss** (F key, N/Space wrap, and
the seeded search when the term isn't in that file); `view_run` now also resets `view_match`.

Related: [[xfmgr-viewer-footer-bank9]], [[xfmgr-find-file]] (that one matches file NAMES, not contents).
