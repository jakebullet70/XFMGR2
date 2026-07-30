---
name: xfmgr-viewer-iso-pet-toggle
description: "DONE build 197: viewer I key toggles ISO/ASCII <-> PETSCII display (content_scr per-byte remap); { } \\ | ~ glyph patch deferred"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**DONE build 197 (2026-07-24) - core shipped.** In tview.p8: `bool view_pet` (false = ASCII/ISO default,
reset per file in view_file); `content_scr(b)` is the whole switch - view_pet false maps a byte via the
existing `scr_of` (ASCII/ISO), true maps via `txt.petscii2scr` (PETSCII), non-printables in the active
encoding -> '.'. The text render loop and the hex ASCII sidebar both draw through content_scr on the RAW
byte; syntax classify still gets the ASCII-clamped byte (a separate `sc` local) so coloring is stable
across the toggle. The `'i'` key flips view_pet. Page boundaries are byte-based (CR/LF), so they don't
move - the toggle just re-renders the current page. The machine charset never changes (XFMGR's UI +
Alt/Ctrl keys stay safe). **Footer:** originally showed a live `I:ISO`/`I:PET` mode label, but build 198
(viewer Find history, [[xfmgr-viewer-find-history]]) needed the bytes - bank 2 was full - so it was cut
to a fixed `ISO` key hint; the text's own readability shows which mode is active.

**DEFERRED (still backlog):** the five ISO-only glyphs `{ } \ | ~` glyph patch (MSEDIT font_setup/
font_xfer) - in ASCII/ISO mode those still render as their `scr_of` approximation, and `_`/backtick are
unmapped, same known limit MSEDIT documents. Auto-sniff-on-open (byte histogram) also not done; encoding
is manual via I. Original design notes with the MSEDIT file:line references kept below.

---

**Backlog (added 2026-07-24).** The text viewer (tview, [[xfmgr-drop-viewer-ram]]) should support
**both ISO/ASCII and PETSCII** text with a **live toggle key**, so a file authored in either encoding
reads correctly instead of showing garbled letters (ISO/ASCII doc shown as PETSCII, or vice-versa).

**DON'T design this from scratch - x16-MSEDIT already worked out every detail.** Port its approach.
Repo: `C:\dev\CmdrX16\dos_tools\x16-MSEDIT` (the `ED` editor; XFMGR's V key already hands off to it).
Design doc: `x16-MSEDIT/PLAN-ISO-MODE.md` (reads the whole Path-A/Path-B trade-off).

**The key idea (why it's safe here):** the machine **never flips to the real KERNAL ISO charset** -
that would garble XFMGR's own PETSCII UI strings + box chrome AND break the Alt/Ctrl command keys
(see [[x16-cp437-iso-keyboard]], [[x16-adaptive-ctrl-keys]]). Instead the **display always keeps the
PETSCII upper/lower font**, and an ISO doc's stored ASCII bytes are **remapped onto that font per byte**
at render time. Only glyphs and (for an editor) keyboard-decode differ.

**Reference implementation, file:line in x16-MSEDIT/SRC:**
- `edit.p8` `apply_charset_mode()` (~2490) - the whole switch. `screen_set_charset(5,0)` (thin PETSCII
  font in BOTH modes; MUST be called or the charset/keyboard half-inits -> wrong chars + lockup), then
  the per-mode branch. **Keyboard-decode part ($0372 bit $40 + EXTAPI $feab) is editor-only - a
  read-only viewer skips it entirely.**
- `edit.p8` `iso_scr(b)` (~2536) - THE portable core: map a stored ASCII byte to a screencode in the
  PETSCII-superset font. Letters fold to the SAME slots a PETSCII doc uses (ASCII A-Z $41-5A -> PETSCII
  $C1-DA; a-z $61-7A -> $41-5A; then `txt.petscii2scr`), so ordinary text renders identically both ways.
- `edit.p8` `font_setup`/`font_xfer`/`font_patch` (~2557-2603) - the five ISO-only glyphs `{ } \ | ~`
  have no PETSCII code; capture them ONCE from the ROM THIN ISO font (charset 6) and stamp into free
  screencode slots ($5b/$5c/$1c/$5e/$5f - chosen to miss the box-draw chrome). Re-stamp after every
  `screen_set_charset` (the reload wipes them). `_` and backtick are a known unmapped limit.
- `tview.p8` (~415, ~606) - MSEDIT's OWN viewer: `theme.ISO_MODE` gates one small fold on each key/byte.
  This is the closest analog to XFMGR's tview - lift this shape directly.
- `edoc.p8` a2p/p2a/recode (~52-102) - the buffer round-trip model (internal PETSCII, disk ASCII). A
  read-only VIEWER likely needs NONE of this - it never writes - so it can be pure display-side remap.
- `syntax.p8` fold (~46-55) - classify() is encoding-AGNOSTIC (folds letters to canonical $41-5A), since
  the toggle is a VIEW flip, not a buffer re-encode. XFMGR's xsyntax ([[xfmgr-syntax-coloring]]) can
  do the same so coloring survives the toggle.

**Flag strategy (from the plan doc):** start as `const bool` (compiler dead-strips the unused branch =
zero cost, proves the false build is byte-identical to today), then promote to a **runtime `bool` +
toggle key** once proven - the runtime var is what costs RAM (both branches ship), so it's a deliberate
later step. Could auto-sniff encoding on open (byte histogram) and default to it, key = manual override.

**Scope for XFMGR:** smaller than MSEDIT's editor version - display-only (no keyboard ISO decode, no
recode/round-trip). Mainly: an `iso_scr`-style remap in the render path + the one-time glyph patch +
a footer toggle. Watch viewer overlay space (the syntax path already had to move to bank 9,
[[xfmgr-syntax-coloring]]). Related byte-encoding gotchas: [[prog8-ascii-file-byte-match]],
[[prog8-filename-literals-lowercase]], [[x16-embedded-petscii-color-codes]].
