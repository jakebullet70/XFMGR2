---
name: xfmgr-showall-revisit
description: "Showall/Branch are a scope flag on the normal file pane; ONE shell-sorted 2048-row file index in dedicated banks 10-11 with an inline 4-char sort key (builds 233-243). DONE."
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T04:12:01.140Z
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

**BUILDS 238-240 - Alt-J jump-to-directory** (XTree Treespec; logs every level on the way down, which
is how you widen what Showall can see), **Alt-T tag-branch**, **Alt-U untag-the-whole-disk**.

**BUILD 242 - THE DEDICATED INDEX BANK (done 2026-08-01).** `INDEX_BANK` = **banks 10 and 11**,
`INDEX_MAX` = 2048, 8-byte rows: `+0 bank  +1 off  +3 dir  +4..+7 sort key`. 1024 rows/bank is
deliberate - it keeps row addressing a shift and a mask (`i >> 10`, `(i & 1023) * 8`); a non-power-of-2
row would need a real multiply on every access. `xarena.FIRST_BANK` 10 -> **12**.

The key is the first 4 filename chars folded through **`strings.lowerchar`** - the SAME fold
`compare_nocase` uses internally. Folding to UPPERCASE (the obvious choice, and what the plan above
said) would be WRONG and would corrupt the order silently: `'_'` = $5F sorts after a lowercase-folded
letter and before an uppercase-folded one, so key order and tie-break order would disagree.
`make_key` reads chars one at a time stopping at NUL - reading 4 blind runs into the next record.
`sort_index` decides most comparisons from `fr_key_hi`/`fr_key_lo` and far-reads both full names only
on a genuine tie; size mode no longer reads names at all. Costs **691 B of main RAM** (the code, not
the bank space - the banks are half empty). Dropping the key to 2 chars would give ~150-200 B back but
ties explode on real name sets (every file in SRC/ starts with `x`) - **decided: keep 4**.
Verified nothing else can reach banks 10/11: X16 Edit and the zsmkit song loader both take
`xarena.high_bank + 1`, which is >= 13.

**BUILD 243 - Alt-S defers the sort.** Alt-S SELECTS an order (advancing `sort_mode` + repainting the
ALT menu label, highlighted while `sort_pending`); the re-sort fires ONCE when ALT is released. It is
committed from **`wait_command`**, not the main loop's dirty-flag repaint - releasing a modifier is not
a keypress, so that repaint never runs, which is why `apply_sort` draws the pane itself.

Related: [[xfmgr-file-text-search]], [[xfmgr-overlay-ram-strategy]], [[xfmgr-architecture]],
[[readable-variable-names]].
