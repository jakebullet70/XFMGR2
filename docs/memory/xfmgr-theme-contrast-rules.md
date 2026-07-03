---
name: xfmgr-theme-contrast-rules
description: XFMGR theme palettes must satisfy per-pairing contrast; index 14 does double duty (border fg AND selection-bar bg)
metadata: 
  node_type: memory
  type: project
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

When editing the theme palette rows in `SRC/themes.p8` (THEME_RGB, 5 colours per theme in
THEME_IDX order 0/1/7/11/14), each theme must pass ALL of these pairings, not just text-on-bg:

- **keys must pop off the surrounding text** — footer hotkeys are the ACCENT (idx 7, the `\x9e`
  codes) printed right next to FG body text (idx 1, `\x05`). They must differ perceptually
  (redmean ΔE > ~150), NOT just vs the background. This is the bug that made X16 Blue's keys
  "invisible" (2026-07-03): accent `7,14,15` cyan ≈ FG `11,13,15` pale blue, both washed-out light
  blue → keys blended into the text even though keys/bg contrast was a fine 7.4.
- **border/title (idx 14) must separate from the field bg (idx 11)** — CLR_BOX `$be` draws idx-14
  frame lines on the idx-11 field. X16 Blue's `4,6,12` on `1,3,10` (ΔE 139) made boxes vanish.
- **selection bar** = HILITE `$e1` = FG (idx 1) text on TITLE (idx 14) background. So **idx 14 does
  DOUBLE DUTY**: it's a foreground (border, vs idx 11) AND a background (selection bar, vs idx 1).
  A monochrome theme fails this easily — Amber Mono had FG `15,10,0` on title `12,8,0` (CR 1.55),
  an unreadable amber-on-amber highlighted row. Fixed by darkening title to `7,4,0`.

Fixed values (2026-07-03): X16 Blue = FG `11,13,15` / accent `15,13,2` / bg `0,1,6` / title
`3,6,13`; Amber Mono = FG `15,10,0` / accent `15,15,8` / bg `2,1,0` / title `7,4,0`. Classic (id 1)
has no row — it is the exact ROM default (`cx16.set_default_palette()`); leave it alone.

Verify offline before building: a redmean-ΔE + WCAG script over the RGB444 rows is faster than
eyeballing. Screen bg = idx 11 (`txt.color2(CLR_FG, CLR_BG)` at start). Related:
[[xfmgr-color-theme-setup]], [[x16-embedded-petscii-color-codes]].
