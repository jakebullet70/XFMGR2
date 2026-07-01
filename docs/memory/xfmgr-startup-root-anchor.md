---
name: xfmgr-startup-root-anchor
description: "Tree is always rooted at the drive root \"/\"; startup descends to and selects the launch folder"
metadata: 
  node_type: memory
  type: project
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

XFMGR's tree is **always anchored at the drive root** `/`, not at the directory it
was launched from. `xtree.init()` sets `base_path = "/"` (so `build_path(node 0)`
is absolute regardless of cwd). At startup `start()` captures `diskio.curdir()`,
logs+expands the root, then calls `xscan.open_path(launchpath)` to descend the tree
segment-by-segment (logging+expanding each level), landing the cursor/file-pane on
the **launch folder** (`start_node`). XTree-style: whole drive logged from root,
current folder highlighted.

**Why/how to apply:**
- `start_node` (1 byte) holds the launch-folder node. Plain `q` quit rebuilds the
  launch dir via `xtree.build_path(start_node, exit_dir)` — base_path is no longer
  the launch dir, so do NOT use base_path for "return to where I started".
- Because base_path is now genuinely `/`: the `hist/` folder lives at `/hist`, and
  copy/move **relative** destinations resolve from `/` (matches the long-standing
  "relative to the drive root" code comments — now actually true).
- `open_path` (SRC/xscan.p8) reuses `pr_leaf` as per-segment scratch (prune isn't
  running at startup); matches a child by case-sensitive `strings.compare` against
  `diskio.list_filename`; stops at the deepest segment it can find on disk.
- Default `run.bat` launches the PRG with cwd already AT the fsroot, so it starts
  at root (`start_node` = 0, no visible change). To exercise the descent, boot to
  BASIC and `DOS"CD:GAMES` then `LOAD"XFMGR.PRG",8` / `RUN`.

Code: `start()` SRC/xfmgr.p8, `open_path` SRC/xscan.p8, `init` SRC/xtree.p8.
Related: [[xfmgr-architecture]], [[xfmgr-run-and-persistence]].
