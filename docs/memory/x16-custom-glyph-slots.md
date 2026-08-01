---
name: x16-custom-glyph-slots
description: "How XFMGR draws the ASCII glyphs PETSCII lacks - patch the VRAM charset in place, the free slot map, and the txt.lowercase ordering trap"
metadata: 
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T05:27:44.342Z
---

**DONE builds 244-247 (2026-08-01).** PETSCII has no `{ | } ~ _ \` glyph and no DOWN arrow. The
viewer used to fold them onto OTHER REAL characters (`; < = > ← £`) so a source line READ as correct
while saying something else - the failure that started this was `DIR_READ_BIN_NUM16` drawing as
`DIR←READ←BIN←NUM16` in a BASLOAD file.

**Patch the default charset IN PLACE** - `main.patch_font` writes glyph bitmaps to VRAM `$1F000 +
slot*8`, 8 bytes per glyph, one bit per pixel. [[xfmgr-custom-fonts-v2]] planned a whole uploaded
font; that turned out unnecessary. MSEDIT needed a second VRAM tilebase (`PLAN-ISO-MODE.md`, Path B)
only because it switches fonts PER DOCUMENT. XFMGR has ONE charset for the whole app, so there is no
tilebase to juggle and no font file to ship - just ~56 bytes of data and a VERA write loop.

VERA write: `VERA_CTRL=0`, `ADDR_L/M` = low 16 bits, `ADDR_H = $11` (bit 0 = address bit 16, `$10` =
auto-increment 1), then stream bytes to `VERA_DATA0`.

**THE TRAP - ordering.** `patch_font` must run AFTER every charset load, and `txt.lowercase()` is
one: the X16's upper/lower case switch RE-UPLOADS the charset from ROM into VRAM. Build 245 patched
right after `set_screen_mode`, before `txt.lowercase()`, and drew the STOCK `$78` glyph (a mid-height
bar) instead of an underscore. Call sites: startup (after `txt.lowercase()`), `op_edit` (after
`screen_set_charset(3,0)`), and the image-viewer return. Symptom of a miss = the stock graphics glyph
for that slot, NOT a blank.

**Slot map** (all verified against the build, see below):

| slot | glyph | how the viewer reaches it |
|---|---|---|
| `$74-$77` | `{ | } ~` | `scr_of`: `b - 7` for `$7B-$7E` |
| `$78` | `_` | `scr_of`: explicit `b == $5f` branch |
| `$79` / `$7A` | down / up arrow | `SC_ARROW_DN` / `SC_ARROW_UP`, the pane scroll marks |
| `$1C` | `\` | FREE - the existing `-$40` fold already lands `\` here |

`$74-$7A` are contiguous, so all seven ride ONE write.

**How to verify a slot is free** (do this, do not eyeball a charset chart):
`grep -oE 'lda +#\$[67][0-9a-f]' build/xfmgr.asm | sort | uniq -c` - every screencode the program can
emit as an immediate. Chrome sits at `$6B-$73` and `$7D`, plus reverse-video twins at `$C0+` (the
selection bar draws box chars inverted - that is why `$C0/$DD/$EB/$ED` show up). Text paths never
exceed `$5A`. Note prog8's `sc:'┌'` values MATCH MSEDIT's constants (`SC_TL $70`, `SC_V $5D`, ...).

`_` cannot ride the `-$40` fold: `$5F-$40 = $1F`, which is the `←` the command menu draws in
`←┘ Log`. That branch cost real bytes in a bank with none - paid for by testing `b > $7a` FIRST in
`scr_of`, which makes the a-z test one compare instead of two.

**TABs render as ONE space, not a column stop** ([[xfmgr-viewer-iso-pet-toggle]]). True stops need the
emit path to run N times for one byte; that build was **170 B over $C000**. Bank 2 (tview) is FULL -
it had ~30 B free before this work and has ~0 now. Upgrading to real tab stops needs a reclaim first;
best candidate is `view_render_zsm` (366 B) -> xsyntax (bank 9, ~3.5 KB free), but everything fat in
tview (`view_render_hex` 419, `view_find_at` 412) reads `viewbuf`, which dies when another bank maps.

Related: [[xfmgr-syntax-coloring]], [[xfmgr-overlay-ram-strategy]], [[x16-cp437-iso-keyboard]].
