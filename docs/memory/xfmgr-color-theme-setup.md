---
name: xfmgr-color-theme-setup
description: XFMGR2 colour-theme setup - Alt-C launches standalone XFSETUP.PRG; themes.p8 palette remap + xfmgr.cfg
metadata: 
  node_type: memory
  type: project
  originSessionId: 161df075-893b-46fb-9c32-46408d7e81e1
---

Added 2026-07-03: a colour-theme picker for XFMGR2. (Charset/font switching was also researched but
dropped - see [[x16-cp437-iso-keyboard]]; the app stays PETSCII.)

**Theme = VERA palette remap** (`SRC/themes.p8`, shared block imported by BOTH xfmgr.p8 and
xfsetup.p8). `themes.apply_theme(id)` calls `cx16.set_default_palette()` (exact ROM restore = the
"Classic" theme, and a clean baseline) then `cx16.vpoke`s RGB overrides into VERA palette RAM
($1FA00, 2 bytes/entry: byte0=`(G<<4)|B`, byte1=`R`) for the UI colour INDICES the app draws with
(0,1,7,11,14 = black/FG/accent/BG/title-hilite, per shared-const.p8). Because `txt.color2` AND the
embedded `\x9e/\x05` footer codes both select those indices, remapping the palette re-themes the
whole UI with ZERO draw-code changes. Presets 1..5: Classic / Amber Mono / Green Mono / C64 Blue /
High-Contrast (RGB rows in themes.p8).

**Standalone PRG, not an overlay.** Setup is stateless w.r.t. the tree/arena, so no state snapshot is
needed. `SRC/xfsetup.p8` is a normal $0801 PRG. Flow:
- XFMGR `Alt-C` -> `handle_alt('c')` -> `op_setup()` confirms **"Setup? loses logged dirs + tags"**
  (default No; the hop cold-restarts XFMGR) -> sets `setup_exit` -> main loop breaks -> shutdown
  branch `chain_run("/xfmgr/xfsetup.prg")` (existing dynamic-keyboard launcher).
- XFSETUP: 80x30 PETSCII, up/down pick a theme with LIVE preview (`apply_theme` each move), ENTER
  saves + returns, ESC cancels. On exit it `chain_run`s `/xfmgr/xfmgr.prg`.
- XFMGR `start()` reads the saved theme while in the /xfmgr/ folder and applies it before
  `full_redraw`: `themes.apply_theme(themes.cfg_read())`.

**Config file** `/xfmgr/xfmgr.cfg` (tiny `theme=N` text line, staged beside the .prg + overlays).
`themes.cfg_read/cfg_write` clone the `hist_save`/`hist_load` diskio pattern
([[xfmgr-run-and-persistence]]); themes.p8 has NO `%encoding` so its filename literals stay PETSCII.
Missing/garbled cfg -> theme 1 (Classic). Discoverability: `Alt-C = Config` hint in uiutil's
`menu_alt_items`. Build/run: `build.bat`/`run.bat` compile+stage `xfsetup.prg` like the overlays.
Cost: xfmgr.prg +~0.6 KB (themes apply/cfg code); ~5.3 KB main RAM still free. See [[prog8-build-toolchain]].
