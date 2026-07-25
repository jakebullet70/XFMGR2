---
name: xfmgr-viewer-line-gutter
description: "Backlog: optional line-number gutter in the text viewer (toggle on/off), portable from MSEDIT's ln_on/gutter_w"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**Backlog (added 2026-07-24).** Give the text viewer (tview, [[xfmgr-drop-viewer-ram]]) an **optional
line-number gutter** - a left column showing each line's number, toggled on/off with a viewer key
(footer entry, like the color toggle already there).

**Port from MSEDIT - it already has this.** Repo `C:\dev\CmdrX16\dos_tools\x16-MSEDIT`, file:line in
SRC/edit.p8:
- `bool ln_on` (~203) - gutter on/off, default OFF, menu toggle.
- `ubyte gutter_w` (~204) - current gutter width in columns (0 = off); **text rendering starts at
  gutter_w**, so the whole render path offsets by it.
- the number-draw loop (~1000-1004): `put_uw_at` / per-digit `petscii2scr('0' + n%10)` right-aligned in
  the gutter, drawn with `txt.setchr` (direct VRAM, no scroll).

**XFMGR specifics:**
- The viewer already tracks page start positions (`view_pages[]`, see the tview PgDn logic), so it knows
  the first line number on a page; increment per rendered line for the gutter labels.
- Width is dynamic: size gutter_w to the digit count of the largest visible line number so it doesn't
  waste columns on short files. Shrinks the text area by gutter_w columns - recompute the wrap/column math.
- Toggle should re-render the current page (same as the color toggle). Persisting the preference could
  ride xfmgr.cfg like the theme ([[xfmgr-color-theme-setup]], [[xfmgr-cfg-read-exists-guard]]) - optional.
- Watch viewer overlay space ([[xfmgr-syntax-coloring]], [[xfmgr-overlay-ram-strategy]]); the digit
  rendering is cheap but every added viewer feature competes for the same tight bank.

Pairs naturally with [[xfmgr-viewer-iso-pet-toggle]] (both are viewer render-path toggles). Scope: small.
