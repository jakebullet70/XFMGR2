---
name: xfmgr-color-theme-setup
description: XFMGR2 settings screen - Alt-F10 launches standalone XFSETUP.PRG; themes.p8 palette remap + multi-key xfmgr.cfg
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
- XFMGR `Alt-F10` -> `handle_alt($15)` -> `op_setup()` confirms **"Setup? loses logged dirs + tags"**
  (moved off Alt-C on 2026-07-03; F10 = keycode $15, passes through the ALT menu unchanged like
  Alt-F3=134. See [[xfmgr-find-file]] which took a CTRL slot in the same session.)
  (default No; the hop cold-restarts XFMGR) -> sets `setup_exit` -> main loop breaks -> shutdown
  branch `chain_run("/xfmgr/xfsetup.prg")` (existing dynamic-keyboard launcher).
- XFSETUP: 80x30 PETSCII. On exit it `chain_run`s `/xfmgr/xfmgr.prg`.
- XFMGR `start()` calls `themes.cfg_read()` at the TOP (its `hw_keys` result is needed by the
  CTRL-key block) and applies the returned theme id later, before `full_redraw`.

**Rebuilt build 196 (2026-08-13) on x16-MSEDIT's EDCFG model** (`x16-MSEDIT/SRC/edcfg.p8` - read it
before touching this): a full-screen LIST of settings under non-selectable section headers, one row
each. Up/Dn picks (headers skipped), Lt/Rt changes with live preview, **F10 saves + exits, Esc
cancels** (ENTER no longer saves - it only fires the one ACTION row). Rows today: Color theme /
Command keys ([[x16-adaptive-ctrl-keys]] override) / Input history (RETURN clears). Adding a setting =
SET_ROW entry + change() arm + draw arm + HELP1/HELP2 line + a var in themes.p8 + one `append_kv`.

**Config file** `<install>/xfmgr.cfg`, now one `key=<digit>\r` line per setting (`theme=`, `hwkeys=`).
`themes.cfg_read` parses them in ONE byte loop keyed on each line's FIRST letter; unknown/absent keys
keep their defaults, so an old single-line cfg still reads. **Only XFSETUP writes it** (`cfg_write`
moved out of themes.p8 into xfsetup.p8, MSEDIT's EDIT/EDCFG split) - reads use an absolute path via
`load_raw`, the write chdirs in and writes a BARE name ([[x16-writes-land-in-cwd]]). themes.p8 has NO
`%encoding` so its filename + key literals stay PETSCII. Discoverability: `F10 Config` hint in uiutil's
`menu_alt_items` (both panes). Build/run: `build.bat`/`run.bat` compile+stage `xfsetup.prg` like the overlays.
Cost of the 196 rework: 95 B of xfmgr low RAM (412 -> 317 B free below $9F00 - the tightest resource
here, so keep new parsing OUT of themes.p8). See [[prog8-build-toolchain]], [[always-report-mem-stats]].
