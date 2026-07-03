---
name: x16-cp437-iso-keyboard
description: "Why XFMGR stays PETSCII - CP437 needs ISO mode, which breaks the ALT/CTRL command keys"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 161df075-893b-46fb-9c32-46408d7e81e1
---

Researched 2026-07-03 while considering switching XFMGR2's whole UI to the CP437 (IBM-PC) charset
for a DOS / Norton-Commander look (double-line boxes + ASCII text). **Abandoned - CP437 needs ISO
mode, and ISO mode changes the keyboard in a way that breaks XFMGR's command dispatch.**

Key facts (X16 R49):
- `txt.cp437()` = `CHR$($0F)` (enable ISO mode) + `screen_set_charset(7)`. CP437 glyphs ONLY render
  in ISO mode: in ISO mode the byte code is used as the screencode directly, so a CP437-encoded byte
  (`cp437:'x'`) drawn via `txt.setchr` shows the right glyph (verified compiling + vendored
  `docs/prog8/examples/charsets.p8`). You cannot get CP437 glyphs while staying in PETSCII mode.
- **ISO mode changes the keyboard** (X16 Reference - 03 - Editor.md): letter keys return ASCII, and
  the **ALT key becomes AltGr** - Alt+S types `ß`, Alt+G `©`, Alt+R `®`, etc. (Editor.md:162-199).
- XFMGR treats **ALT as the Commodore key**: in PETSCII mode Alt+letter delivers Commodore graphics
  codes `$A1-$BF`, which `alt_letter[]` in xfmgr.p8 decodes back to the letter (see
  [[x16-alt-is-commodore-key]]). In ISO mode those codes never arrive, so the whole ALT command menu
  (Alt-S/X/Q/R/P/F3) breaks. CTRL+letter still delivers `$01-$1A` in both modes, but the normalize
  step (`+$40` -> $41-5A) would need `+$60` for ASCII lowercase literals.

Consequences / decision:
- **XFMGR stays PETSCII.** Its box frames keep the single-line PETSCII glyphs (`sc:'┌'` etc.).
- To get the CP437 double-line DOS look WITHOUT ISO mode you'd upload a **custom charset** to VRAM
  (keeps PETSCII keyboard/CHROUT/filenames intact) - deferred, not done.
- The alternative "full CP437 + rework ALT" would mean reading the raw keynum (scancode hook $032E)
  to decode ALT ourselves, or moving the ALT commands off the Commodore key - both invasive.
- **Colour themes are charset-independent** (VERA palette remap), so the theme setup feature shipped
  in PETSCII regardless - see [[xfmgr-color-theme-setup]].

Also: filename literals for diskio must stay PETSCII regardless (the emulator host-fs SETNAM path
matches petscii bytes - the basis of [[prog8-filename-literals-lowercase]]); a global `%encoding
cp437` would have needed every filename literal tagged `petscii:`.
