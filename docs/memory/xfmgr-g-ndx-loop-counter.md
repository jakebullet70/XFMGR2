---
name: xfmgr-g-ndx-loop-counter
description: g_ndx is a shared global loop counter reused by leaf for-loops to save BSS
metadata:
  type: reference
---

`g_ndx` is a module-level `ubyte` in `main` (declared next to `g_key`), a shared counter
reused by many `for` loops so each sub no longer needs its own static counter byte. Same
motive as `g_key`; see [[prog8-static-variable-allocation]] (every local is its own byte).

**Safety rule (the whole reason it works):** `g_ndx` may be the counter of a loop ONLY if
that loop is a "leaf" — its body calls NO other `main`-defined subroutine and contains no
nested loop. External-module calls (txt.*, xtree.*, xfiles.*, xarena.*, strings.*, diskio.*,
cx16.*, cbm.*, hlprs.*) are fine: they can't see `main.g_ndx`, so they can't clobber it.
Because a converted loop never calls another sub that uses `g_ndx`, and loops aren't nested,
nothing overwrites the counter mid-iteration. Sequential leaf loops in one sub may each use
`g_ndx`.

**The one deliberate exception:** `draw_box` loop 2 (`for g_ndx ...: box_row(...)`) DOES call
a main sub. It's safe only because `box_row` and its callee `blank_span` keep LOCAL counters.
So those two must NEVER be converted to `g_ndx`, or draw_box's border row breaks.

**Loops that must stay local** (their body reaches a sub that uses `g_ndx`, or a batch sub):
list-repaint loops `draw_tree` / `draw_files` / `show_all` / `pick_draw_all` / `hist_popup`
(they call row-draw subs that use `g_ndx` via hilite_row/build_tree_line), and batch loops
calling `copy_one` / `hist_ptr` (op_copymove, op_copymove_global, hist_store, hist_save).

Applied 2026-07-01 across ~17 subs / 22 loops: BSS −19 B (20 locals removed, +1 for the
global), code −27 B, net +46 B free. When ADDING a loop here, reuse `g_ndx` if it's a leaf
loop; otherwise declare a local. Watch build.bat's main-RAM high-water to confirm.
