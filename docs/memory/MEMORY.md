# Project Memory

- [Prog8/X16 build & test toolchain](prog8-build-toolchain.md) — how to compile and run X16 Prog8 here
- [XFMGR2 architecture](xfmgr-architecture.md) — the XTree-clone module layout and memory model
- [XFMGR2 run & persistence](xfmgr-run-and-persistence.md) — run.bat clean-launch + history file in data/
- [Startup root anchor](xfmgr-startup-root-anchor.md) — tree always rooted at "/"; startup descends to + selects launch folder
- [X16 ALT is the Commodore key](x16-alt-is-commodore-key.md) — ALT+letter returns a graphics code, not the letter
- [Launching a PRG on exit](x16-launch-program-dynamic-keyboard.md) — 10-byte kbd buffer; dynamic-keyboard chain_run
- [Prog8 static variable allocation](prog8-static-variable-allocation.md) — every local is its own byte; no overlap
- [Prog8 module-split cost](prog8-module-split-cost.md) — cross-module calls are free; per-block init is the real cost
- [X16 banked RAM min config](x16-banked-ram-min-config.md) — stock = banks 0-63; reserve the LOWEST bank
- [X16 Edit bank handoff](xfmgr-editor-bank-handoff.md) — op_edit lastbank must be xarena.max_bank, never 255
- [Run own utils and return](xfmgr-run-utils-and-return.md) — banked overlay vs swap-and-relaunch patterns
- [Prune command](xfmgr-prune-command.md) — DIR-col P recursively deletes a dir subtree (iterative, typed confirm)
- [Always report mem stats](always-report-mem-stats.md) — include build memory-stats block in replies
- [Revisit ShowAll](xfmgr-showall-revisit.md) — backlog: ShowAll is tagged-only across logged dirs; consider a whole-disk flat browser
- [ZIP/ARC support (V2)](xfmgr-zip-arc-v2.md) — backlog: browse/extract archives in V2; DEFLATE/ARC decompress is the hard part
- [RAM savings menu](xfmgr-ram-savings-menu.md) — verified ~2.9 KB of held main-RAM savings + the 3 overflow bugs already fixed
- [Memory is git-tracked](memory-is-git-tracked.md) — this memory folder is a junction into the repo (docs/memory)
