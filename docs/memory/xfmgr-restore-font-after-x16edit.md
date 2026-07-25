---
name: xfmgr-restore-font-after-x16edit
description: "Backlog: after the modal X16 Edit (ROM) returns in op_edit, re-select XFMGR's charset so the editor's font change doesn't persist"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
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
