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
- Disk work lives in the **miscutil overlay (bank 3)**, entry `prune_dir(parent @R0, name @R1)`
  (NOT xscan anymore). Prog8 locals aren't reentrant and diskio allows only ONE listing at a
  time, so it's **iterative, not recursive**, and as of 2026-07-05 it's an ITERATOR: each
  `prune_dir` call removes exactly ONE directory (descend from the target to the deepest leaf,
  scratch its files, `rmdir` it) and returns **0=target itself removed/done, 1=removed a subdir
  (call again), 255=error** (rmdir fail via `status_code()!=0`, or PRUNE_MAXDEPTH=24/path>=95).
  `op_prune` loops calling it, drawing a live **"(Dir: N)"** counter on CMDROW2 (same pattern as
  Find's crawl counter). On 255 the on-disk tree may be partly deleted -> rescan.
- On success the node is removed from the tree via `xtree.unlink(idx)` (detaches from
  the parent's child chain; the append-only pool slot just leaks until reset()).
- After pruning the cursor lands ONE ROW UP from the pruned dir's position (the
  previous visible entry), NOT on the parent/root.

Code: `op_prune()` in SRC/xfmgr.p8 (key wired in handle_tree, menu in menu_plain_items),
`prune_step`/`prune_dir`/`first_subdir`/`join_path`/`delete_all_files` in SRC/miscutil.p8 (bank 3),
`unlink` in SRC/xtree.p8.
Test sandbox: a disposable `run/PRUNETEST/` nested tree is used for testing (destructive).
Related: [[xfmgr-architecture]].
