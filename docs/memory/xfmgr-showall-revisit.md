---
name: xfmgr-showall-revisit
description: "DONE build 208-212: Ctrl-G is now the all-files GLOBAL browser (tag-as-mark, T tagged-only toggle, 1024 cap); node pool banked to fund it"
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

**DONE build 208-212 (2026-07-31).** Ctrl-G's `show_all()` is now the true XTree **GLOBAL browser**:
every file across all LOGGED dirs in one flat list (via new `xfiles.collect_all`, respecting the
FileSpec), **tag is just a MARK** (`*`, drawn by `draw_sa_row`) so **Space toggles it and the row STAYS**
(`sa_toggle_tag`, unlike the old consolidation list). **T** flips ALL-files <-> TAGGED-only (XTree
Ctrl-F4); it **opens tagged-only** (per user: the 255... now 1024-slot list would overflow instantly on
a full card, so start small and reveal all on demand). **S** = content search over the TAGGED files
([[xfmgr-file-text-search]]). The three arena walkers (tagged / name-match / all-vs-spec) were unified
into one `xfiles.collect(mode,pat)` + thin wrappers.

**Cap raised 255 -> 1024:** the sa_ snapshot lives in bank 1 at $b000 (4 KB = 1024*4-byte recs), so the
only limit was the `ubyte sa_count`; widened `sa_count`/cursor/`sf_top`/all `sa_*` accessors to `uword`
(`GLOBAL_MAX=1024`). That cost ~830 B of MAIN RAM, **funded** by moving the redraw-hot `d_*` node-pool
arrays into the banked DX record ([[xfmgr-overlay-ram-strategy]]): DX_REC grew 7->14, with
`d_name_off`(+7)/`d_depth`(+9)/`d_parent`(+10) now `dx_noff`/`dx_depth`/`dx_parent` (d_first_child/
next_sibling/flags stay main-RAM). Net ~449 B free at build 212.

**Regressions caught by an adversarial review pass (not manual testing):** (1) `unlog()` (Alt-R Release)
still called `dx_clear` which after the DX_REC grow wiped a LIVE node's banked name_off/depth/parent ->
added `dx_clear_files` (clears only +0..+6); (2) content-search's `input_line` calls `box_close()` ->
`draw_frame()`, bleeding the normal dual-pane chrome over the full-screen browser -> `content_search_prune`
now repaints the browser before the scan loop ([[xfmgr-file-text-search]]). Original backlog notes below.

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
