---
name: xfmgr-overlay-extension-ovl
description: "XFMGR bank overlays ship as .OVL (not .bin) — prog8 emits <name>.bin, build.bat renames to <name>.ovl"
metadata: 
  node_type: memory
  type: project
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

The four HIRAM bank overlays are **tview.ovl / miscutil.ovl / uiutil.ovl / ximgview.ovl** (renamed
from .bin on 2026-07-03, build 110, at the user's request). Any older memory that says "tview.bin"
etc. is stale — the extension is now **.ovl**.

The build chain (prog8 has no output-extension option, so a rename step does it):
- `build.bat`: each `%output library` overlay compiles to `<name>.bin` in the repo root, then a
  `MOVE /Y <name>.bin <name>.ovl` renames it. (xfmgr.prg and xfsetup.prg stay .prg.)
- `run.bat`: stages `<name>.ovl` into `run\xfmgr\`.
- `xfmgr.p8`: loads them with `diskio.loadlib("<name>.ovl", $a000)` (lowercase literal so the
  host-fs matches — see [[prog8-filename-literals-lowercase]]).

If you add a new overlay, replicate all three: MOVE in build.bat, COPY in run.bat, loadlib in
xfmgr.p8 — all lowercase `.ovl`. A missing/mis-cased name -> loadlib returns 0 -> the *_ok flag
false -> that overlay's feature silently no-ops. Related: [[xfmgr-overlay-ram-strategy]],
[[xfmgr-architecture]], [[xfmgr-cfg-read-exists-guard]] (cfg is loaded the same way).
