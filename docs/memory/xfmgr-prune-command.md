---
name: xfmgr-prune-command
description: Prune (P) in the DIR column recursively deletes a directory subtree
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

The DIR column has a **Prune** command (key `p`, shown as "Prune" in the tree menu)
that recursively deletes the selected directory and EVERYTHING under it on disk.

**Why/how to apply:**
- Guarded by a **typed confirmation**: the user must type the word `prune` (not the
  dir name). Root (node 0) is refused ("can't prune the drive root").
- Disk work is `xscan.prune(parent_path, name)`. Prog8 locals aren't reentrant and
  diskio allows only ONE listing at a time, so it's **iterative, not recursive**:
  repeatedly descend from the target to a directory with no subdirs (a leaf), scratch
  its files with `diskio.delete("*")`, `rmdir` it, repeat. Any `rmdir` failure
  (`diskio.status_code() != 0`) aborts with false to avoid spinning; depth/path-length
  guards (PRUNE_MAXDEPTH=24, path>=95) also abort. On false the on-disk tree may be
  partly deleted -> the user should rescan.
- On success the node is removed from the tree via `xtree.unlink(idx)` (detaches from
  the parent's child chain; the append-only pool slot just leaks until reset()).
- After pruning the cursor lands ONE ROW UP from the pruned dir's position (the
  previous visible entry), NOT on the parent/root.

Code: `op_prune()` in SRC/xfmgr.p8 (key wired in handle_tree, menu in menu_plain_items),
`prune`/`first_subdir`/`join_path` in SRC/xscan.p8, `unlink` in SRC/xtree.p8.
Test sandbox: a disposable `run/PRUNETEST/` nested tree is used for testing (destructive).
Related: [[xfmgr-architecture]].
