---
name: xfmgr-custom-fonts-v2
description: "Backlog (V2): custom uploaded charset for a DOS double-line-box look while staying PETSCII"
metadata: 
  node_type: memory
  type: project
  originSessionId: 161df075-893b-46fb-9c32-46408d7e81e1
---

**Backlog / V2 idea (deferred 2026-07-03).** Give XFMGR2 the DOS / Norton-Commander look (double-line
box frames, and optionally restyled letters) via a **custom charset uploaded to VRAM**, WITHOUT
switching to CP437/ISO mode.

**Why this route:** the ROM CP437 charset can't be used - it needs ISO mode, which turns Alt into
AltGr and breaks XFMGR's Alt-key command menu (see [[x16-cp437-iso-keyboard]]). A custom font keeps
the machine in **PETSCII** mode, so the keyboard, command dispatch, filenames, and all existing
`petscii:` strings stay 100% unchanged - only the glyph bitmaps change.

**How to apply:**
- Stay in PETSCII text mode (keep `txt.lowercase()`, the `sc:'┌'` box screencodes, everything).
- Point VERA's text-layer charset base at a custom 2 KB font in VRAM (or copy the ROM PETSCII font
  to VRAM first, then patch only the tiles used for box-drawing). Minimum change: overwrite just the
  ~11 box-drawing screencodes (SC_V/SC_H/corners/junctions in xfmgr.p8 + uiutil.p8) with double-line
  8x8 bitmaps - ~88 bytes of glyph data - leaving all letters/digits as the stock PETSCII font.
- This is the "custom fonts" option deferred when picking ROM-charsets-only for the theme utility;
  it composes cleanly with the shipped colour themes ([[xfmgr-color-theme-setup]]) since those are
  palette remaps, orthogonal to glyph bitmaps.
- Could ride the setup utility ([[xfmgr-color-theme-setup]]) as a second option ("Box style:
  single / double"), persisted as another key in xfmgr.cfg.

Scope guess: small (glyph data + a VRAM upload at startup). No keyboard/command risk. Main-RAM cost
is just the glyph table + upload code. See [[prog8-build-toolchain]], [[xfmgr-docs-reference-tree]]
(charset examples under docs/prog8/examples/).
