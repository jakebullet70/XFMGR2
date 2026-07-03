---
name: xfmgr-cfg-read-exists-guard
description: "themes.cfg_read loads xfmgr.cfg via diskio.loadlib (KERNAL LOAD, same as the overlays) — never f_open/f_readline, which corrupted the UI draw when the file was absent"
metadata: 
  node_type: memory
  type: project
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

`themes.cfg_read()` (SRC/themes.p8) is **self-contained**: it copies the caller's `diskio.curdir()`
into a save buffer, `diskio.chdir("xfmgr")`, LOADs xfmgr.cfg with a single **`diskio.load_raw(CFG_NAME,
&cfg_line)`** (a headerless `cbm.LOAD` — identical to the overlays' `loadlib`, both are
`internal_load_routine(..., headerless=true)`; `load_raw` is just the honest name for raw data vs a
library blob), then `diskio.chdir(savedir)` back — so it works
regardless of the cwd at the call site. It NUL-terminates at the returned end address and parses
"theme=N" in the buffer. loadlib returns 0 when the file isn't found → theme 1 (Classic). Do NOT go
back to `diskio.f_open` + `f_readline` here. (curdir() points into a transient shared buffer — copy
it out before any other diskio call.)

Why: going straight to f_open/f_readline on an ABSENT xfmgr.cfg disturbed the drive's OPEN/read
channels, and that leaked into the *next* UI draw — it showed up as the **bottom command-menu
colours being wrong / the menu not visible**. Whether it bit depended on WHERE XFMGR was launched
from (the launch dir decides whether the cfg is present on the path). The user pinned it to launch
location; the earlier theme-correlation (High-Contrast / Green Mono "no bottom menu") was a red
herring — those were just the themes previewed when XFMGR happened to start from a folder without
the cfg. Overlays load BEFORE cfg_read in start(), so it was never an overlay-load failure — it was
disk channel state from the failed read bleeding into the palette/draw that follows.

Evolution (2026-07-03, builds 109->110): first fix was a `diskio.exists()` guard; then per the user
it was changed to `loadlib` so the cfg is found+read exactly like the overlays. Rule for any config/
history read staged in /xfmgr/: use a LOAD, never f_open a file that may be absent on the path.
Related: [[xfmgr-color-theme-setup]], [[prog8-diskio-vendored-patch]], [[xfmgr-run-and-persistence]],
[[xfmgr-overlay-extension-ovl]].
