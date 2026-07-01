---
name: xfmgr-showall-revisit
description: "Backlog — revisit/expand ShowAll; today it is tagged-only across logged dirs, not a whole-disk flat browser"
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

**Feature note (revisit ShowAll).** The user wants to reconsider the ShowAll
feature down the road. Captured 2026-07-01.

**What ShowAll is TODAY:** `Ctrl-G` runs `show_all()` (SRC/xfmgr.p8), which calls
`xfiles.collect_tagged()` (SRC/xfiles.p8) to walk every **logged** (`FL_SCANNED`)
directory and gather all **tagged, non-hidden** files into a flat, scrollable,
full-screen list (path + name + block size; `U` untags in place, `Esc`/`Q` exits).
It's the springboard for the cross-directory batch ops: `Ctrl-C` copy / `Ctrl-O`
move / `Ctrl-X`(emu)|`Ctrl-D`(hw) delete — all acting on the whole tagged set to one
destination. Fed by `Ctrl-W` (tag by wildcard), `Ctrl-T` (tag all), `Ctrl-I` (invert).

**The gap vs. classic DOS XTree ShowAll:** XTree's Showall dumps *every* file on the
drive into one flat list and you tag *within* it. XFMGR is inverted (tag first, then
consolidate) and **tagged-only**. It also only spans directories already logged —
there is **no whole-disk crawl** (on-demand logging), so unvisited branches don't
appear. Hard cap `GLOBAL_MAX = 255` files.

**Revisit ideas / directions to weigh:**
- A true "browse ALL files on the card, flat, regardless of tags" mode (a whole-disk
  crawl + untagged flat browser) — the classic behavior the user knows.
- If pursued, mind the constraints: 255-item cap, per-entry RAM (sa_bank/off/dir
  arrays are already 255 each), and the cost of a full recursive crawl on a large
  FAT32 SD / HostFS root. Would likely need paging or a raised/removed cap.
- Possibly sort/group the ShowAll list, or filter by spec within it.

Related: [[xfmgr-architecture]], [[always-report-mem-stats]].
