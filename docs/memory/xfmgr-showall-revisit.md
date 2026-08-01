---
name: xfmgr-showall-revisit
description: "Showall/Branch are a scope flag on the normal file pane; ONE shell-sorted 1024-row file index in banked RAM (builds 233-237). Dedicated index bank still approved and pending."
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T02:46:23.604Z
---

**History:** the standalone GLOBAL browser was PULLED at build 214 because it "is not like the real
XTree for file searching" - XTree's model is tag -> prune the tags by searching -> step through what
survived ([[xfmgr-file-text-search]]), not a separate list-everything screen. The `sa_*` gather, the
unified `xfiles.collect(mode,pat)` walker and `sa_toggle_tag`/`sa_untag`/`sa_is_tagged` were kept
parked (prog8 dead-code-eliminates unreferenced subs, so they cost nothing while unwired).

**REBUILT build 233-234 (2026-07-31) the XTree way.** Real XTree has ONE file window with one command
menu; Normal / Branch / Showall / Global are a **scope flag**, not separate screens. So Showall is now
`xfiles.file_scope` (0=SCOPE_DIR, 2=SCOPE_DISK; 1=SCOPE_BRANCH reserved for phase 2), entered with
**`S` from the tree pane**, left with **Esc**. `build_scoped_index()` materialises the banked `sa_*`
gather into the SAME `ft_*` pane index the normal view uses, so ~60 call sites, every file operation
and the whole renderer work unchanged. The one thing a multi-dir list needs that a single-dir one did
not is **`ft_dir[]` - the owning directory of each row**; per-file ops route through
`cd_to_entry(i)` which builds that row's path and chdirs. In SCOPE_DIR every `ft_dir[i]` is just
`cur_dir`, so there is one code path, not two. Cross-directory batch copy/move came back nearly free.
`sa_total` counts matches past EVERY cap so the header can say "255 of 1837 Files" instead of lying.

**BUILD 236 - ONE BANKED INDEX (done 2026-07-31).** `ft_bank[]`/`ft_off[]`/`ft_dir[]` are GONE. There
is now one index in bank 1 @ $b000 (4-byte rows, `INDEX_MAX`=1024) serving directory listings, scoped
views and the Find browser alike - they were three views of the same record all along, so the `sa_*`
accessors folded into `get_*`/`is_tagged` and ~50 lines of duplication went with them. Rows are read
via **`row_load(i)` -> `fr_bank`/`fr_off`/`fr_dir`**, one bank switch for all three; `fr_*` is a single
staging buffer, so consume it before the next `row_load` (same rule as xtree's `name_ptr`).

Why it had to move: three main-RAM arrays of 1024 rows = 4 KB this program does not have. And the
255-row truncation was worse than it looked - the kept rows were **whatever the walk reached first,
sorted among themselves**, so an alphabetical-looking list silently omitted arbitrary files. A single
directory can exceed 255 files now too. **BSS -989 B, image +473 B, free 1242 -> 1758 B.**

`sort_index` is a **shell sort** (Knuth gaps). Every comparison costs a far string read; insertion
sort wanted n(n-1)/4 of them (~16k at 255 = the reported pause, ~262k at 1024 = ~19 s). Now ~2.5k /
~14.5k. It is a PREREQUISITE for the banked index, not a nicety: each shift is a far read+write.

**Traps this refactor exposed (all fixed):** Find gathered its matches and THEN called `select_dir`,
which rebuilds the same index - the results were overwritten before the browser drew them.
`toggle_tag`/`hide` lost their `dir` param (every caller passed the row's own dir, the only correct
value). The Ctrl-V tagged walk indexed with `ubyte cur/j`. `cur_blocks` was a uword - a whole-disk
total passes 65535 easily (~16 MB); it is a `long` printed via **`conv.str_l`**, because writing the
digit loop with 32-bit `/` and `%` drags in prog8's general long divide and costs **790 B**.

**BUILD 237 - Branch.** `file_scope` 1 = SCOPE_BRANCH. `collect()` gained **`collect_root`**
(`xtree.NONE` = whole disk, else stay inside that subtree via `in_branch()`, which walks parents -
cost is per DIRECTORY, not per file). xfmgr keeps `branch_root` SEPARATE from `cur_dir` on purpose:
cur_dir follows the tree cursor and a drifting branch would change what the next Ctrl-C acts on.
**Scope-exit guards:** `op_find` and `op_release` (Alt-R, which is NOT focus-guarded) both
`leave_scope()` first - Find renumbers every tree node, and unlog frees records a scoped index still
points into. `op_relog` was already safe via `rebuild_view()`.

**STILL TO BUILD:** phase 3 `\` jump-to-directory (XTree Treespec) + Alt-Tag scope choice. And the
**USER-APPROVED dedicated bank** ("when ready, give it its own bank", 2026-07-31): move the index out
of its $b000 corner into a **dedicated 8 KB bank**, row widened 4 -> 8 bytes with a **4-char uppercase
sort key inline**, so a comparison reads the key in the bank window and only far-reads the full name on
a tie (~20x sort) and rows go past 1024. Costs ~400 files of arena capacity out of ~22,000 (arena =
banks 9..63 at ~400 records/bank). Only matters past 1024 files. Shifts `xarena.FIRST_BANK` and every
bank-map comment - see [[xfmgr-overlay-ram-strategy]].

Related: [[xfmgr-file-text-search]], [[xfmgr-overlay-ram-strategy]], [[xfmgr-architecture]],
[[readable-variable-names]].
