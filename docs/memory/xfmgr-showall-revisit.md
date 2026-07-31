---
name: xfmgr-showall-revisit
description: "GLOBAL browser was PULLED at build 214 for a rebuild; search + sequential view now live in the NORMAL file pane. Ctrl-G is free."
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
  modified: 2026-07-31T14:07:14.430Z
---

**PULLED build 214 (2026-07-31), awaiting rebuild.** The user's call: the Global browser "is not like
the real XTree for file searching". So Global came OUT and the XTree working loop was rebuilt in the
**NORMAL file pane** first - tag files, narrow them with a content search, then read them in sequence
([[xfmgr-file-text-search]]). Global gets revisited afterwards.

**What was deleted** (SRC/xfmgr.p8): `show_all`, `show_all_frame`, `sa_recollect`, `view_walk`, the
Global-flavoured `content_search_prune`, `op_copymove_global`, `refresh_all_scanned`, the
`sa_tagged_only` var, and the Ctrl-G binding. 385 lines out. **Freed ~2.6 KB main RAM** (168 B -> 2781 B),
which is what paid for everything built after it.

**What deliberately STAYED, ready for the rebuild:** the whole `sa_*` snapshot (bank 1 @ $b000, 1024
recs), the unified `xfiles.collect(mode,pat)` walker + its `collect_tagged`/`collect_all` wrappers,
`sa_toggle_tag`/`sa_untag`/`sa_is_tagged`, and the shared flat-list renderer `draw_sa_row`/`draw_sa_page`
(Find still uses it). Unreferenced subs are dead-code-eliminated by prog8, so they cost nothing while
parked - the foundation is intact, just not wired to a key.

**Casualty to remember:** cross-directory batch copy/move went with it (`op_copymove_global` was only
reachable from the browser). `Ctrl-C`/`Ctrl-M` still act on the CURRENT dir only. Restore it with Global.

**Ctrl-G is now unbound** - keep it reserved for Global's return.

**The lesson that caused the pull:** XTree's model is tag -> prune the tags by searching -> step through
what survived. Build the browser around that loop, not around a "list everything and act on it" screen.
The 208-212 Global implementation (tag-as-mark, T tagged-only toggle, 1024 cap funded by banking the
d_* node pool) is in git history if any of it is worth recovering.

Related: [[xfmgr-file-text-search]], [[xfmgr-overlay-ram-strategy]], [[xfmgr-architecture]].
