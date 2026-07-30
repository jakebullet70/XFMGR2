---
name: xfmgr-restore-font-after-x16edit
description: "DONE build 203: after X16 Edit, op_edit force-reloads charset 3 via screen_set_charset(3,0) + clears the ISO flag; txt.lowercase()/saved_charset were both wrong"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**DONE build 203 (2026-07-30).** In `op_edit()` (xfmgr.p8). Took builds 198-203 to get right; the two
wrong turns are the lesson. X16 Edit's **Ctrl-E "change font"** does TWO independent things on exit:
(1) OVERWRITES the PETSCII font glyphs in VRAM, and (2) can leave the machine in **ISO mode** (KERNAL
flag `$0372` bit `$40`; with it set CHROUT reads bytes as ISO/ASCII, so filenames render but PETSCII box
chrome garbles).

**Two dead ends, each with a diagnostic signature:**
- **`txt.lowercase()` can't repair the glyphs.** It compiles to just `CHROUT($0e)`, which only toggles
  the KERNAL's selected mode and NO-OPS when the mode is unchanged - it never re-copies the ROM glyphs.
  So after Ctrl-E the corrupt VRAM font stayed. Only `cx16.screen_set_charset(n, 0)` (0 ptr = built-in)
  FORCE-reloads the ROM glyphs into VRAM. Signature of this failure: uppercase-ish letters + garbled
  chrome, unchanged by any CHROUT toggle. (Same reason the image-viewer return path at ~1047 gets away
  with `txt.lowercase()`: the image viewer never corrupts the font glyphs, only the screen mode.)
- **Reloaded the WRONG charset number.** First force-reload used `saved_charset` - but that global is
  captured by `snapshot_machine_state()` at startup line ~368 BEFORE `txt.lowercase()` runs, so it holds
  the machine's PRE-LAUNCH charset (charset 2, upper/graphics), kept only for FINAL exit. XFMGR's RUNNING
  display font is **charset 3** (PETSCII upper/lower). Reloading 2 rendered clean letters but garbled the
  box chrome, because XFMGR's chrome codes are laid out for charset 3's screencode map, not charset 2's.
  Signature: correct letters, garbled ONLY on the graphics/box glyphs.

**The fix (build 203):** `set_screen_mode(SCREEN_MODE)` (reinit 80x30 layer + tile base) -> **`cx16.screen_set_charset(3, 0)`** (force-reload XFMGR's running PETSCII upper/lower font; literal 3, NOT saved_charset) -> clear `$0372` bit `$40` (leave ISO mode) -> `txt.color2(CLR_FG,CLR_BG)`. Caller's `dirty_full` repaints. Mirrors MSEDIT `apply_charset_mode` (edit.p8 ~2490: screen_set_charset then $0372). Still no 2KB glyph buffer; the custom-font-preservation case is deferred. Notes below.

---

**Backlog (added 2026-07-24).** When XFMGR launches the ROM-resident **X16 Edit** (E key ->
`op_edit()` in xfmgr.p8 ~2178, runs MODALLY and returns), the editor changes the VRAM charset/font.
XFMGR should **save which font/charset was selected before the call and re-select it after the editor
exits**, so EDIT's font choice doesn't bleed into XFMGR's display.

**Approach (per user, 2026-07-24): keep it cheap - do NOT buffer the 2KB glyph table.**
- Just record the CURRENT charset selection and **re-select it** after X16 Edit returns:
  `cx16.screen_set_charset(<saved>, 0)` reloads the built-in ROM font glyphs - no 2KB copy, no RAM bank
  spent. This is the same call `restore_machine_state()` already uses (xfmgr.p8 ~648) with the
  `saved_charset` captured by `snapshot_machine_state()` (~602); the gap is that restore only runs on
  XFMGR's FINAL exit (~579), not right after `op_edit()` returns.
- So the fix is small: in `op_edit()`, capture `cx16.get_charset()` before
  `cx16.x16edit_loadfile_options(...)`, and after the `rombank(oldrom)` / `disable_caseswitch()` restore,
  re-select it (guard 1..3 like restore_machine_state does). The existing `dirty_full = true` repaint
  (xfmgr.p8 ~1059) then paints text over the correct font.
- **Only if a genuine CUSTOM (non-ROM) font must be preserved** - i.e. once XFMGR uploads its own glyphs
  (the [[xfmgr-custom-fonts-v2]] / double-line-box idea, or the [[xfmgr-viewer-iso-pet-toggle]] glyph
  patch) - re-selecting a ROM charset won't bring those back. In that case **write the 2KB VRAM font out
  to a file** before launching EDIT and reload it after, rather than eating a scarce RAM bank
  ([[x16-banked-ram-min-config]], [[xfmgr-overlay-ram-strategy]]).

Note: X16 Edit already forces `sys.enable_caseswitch()` around the call (the "X16Edit charset
workaround", ~2199) and clobbers golden RAM $0400 ([[xfmgr-editor-bank-handoff]],
[[xfmgr-run-utils-and-return]]) - the font re-select slots in alongside that same cleanup. Scope: small.
