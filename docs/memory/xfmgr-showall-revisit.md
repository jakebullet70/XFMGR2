---
name: xfmgr-showall-revisit
description: "Showall REBUILT at build 233-234 as a scope flag on the normal file pane; costed plan for getting past the 255-row cap, incl. the approved dedicated index bank"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T18:06:35.013Z
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

**THE SCALING PLAN (costed 2026-07-31, not yet built).** Two limits bite past a few hundred files:

1. **`sort_index` is insertion sort with a far string read per comparison** - no cached key. Average
   comparisons n(n-1)/4: **16k at 255 (~1.2 s, the pause the user reported), 262k at 1024 (~19 s)**.
   Fix = **shell sort** (Knuth gaps) - the same loop wrapped in a gap sequence, **~60 bytes, zero RAM**,
   6x fewer compares at 255 and 18x at 1024. Do this first; it is also a PREREQUISITE for (2), because
   a banked index makes every shift a far read+write.
2. **The 255-row cap is main RAM.** `ft_bank`+`ft_off`+`ft_dir` = 1020 B; 1024 rows would be 4096 B and
   **does not fit** (free RAM was 1491 B at build 234). So: **drop `ft_*` and let the pane index the
   banked table directly for both scopes** - frees 1020 B, single code path. Then widen
   `file_cursor`/`file_top`/`ft_count` and the 7 `ubyte i` accessors to uword: ~85 + ~53 + 7 sites,
   +250-450 B image because 16-bit compares cost ~2x. Net still ahead ~600-750 B.

**USER DECISION (2026-07-31): "when ready, give it its own bank."** The index moves out of its cramped
$b000 corner of bank 1 into a **dedicated 8 KB bank**, record widened 4 -> 8 bytes with a **4-char
uppercase sort key inline**. That buys the ~20x sort (compare the key in the bank window, only far-read
the full name on a tie) AND 1024 rows without robbing main RAM. Costs ~400 files of arena capacity out
of ~22,000 available (arena is banks 9..63 at ~400 records/bank) - cheap. NOTE this shifts
`xarena.FIRST_BANK` and every bank-map comment; see [[xfmgr-overlay-ram-strategy]].

**Still to build:** phase 2 `B` Branch (current dir + subdirs - a subtree predicate in `collect`),
phase 3 `\` jump-to-directory (XTree Treespec) + Alt-Tag scope choice, README/xfmgr.hlp text for
Showall. The uword widening is the change that can fail QUIETLY (a missed `ubyte` truncates a cursor
and the pane silently jumps to the wrong file) - worth an adversarial review pass over the diff.

Related: [[xfmgr-file-text-search]], [[xfmgr-overlay-ram-strategy]], [[xfmgr-architecture]],
[[readable-variable-names]].
