---
name: xfmgr-syntax-colouring
description: "Viewer syntax colouring: xsyntax overlay in bank 9, called BY tview across banks; bank 2 is now full"
metadata: 
  node_type: memory
  type: project
  originSessionId: a31951ee-0367-4b90-ba73-026b129abe1f
  modified: 2026-07-18T07:41:45.508Z
---

**DONE 2026-07-18 (build 186):** the `V` text viewer colours BASIC/BASLOAD and Markdown.
`SRC/xsyntax.p8` is a port of `x16-MSEDIT/SRC/syntax.p8` (keyword blobs + stateless per-line
classifier).

**Architecture - it is called BY tview, not by main.** xsyntax lives in **bank 9** (`SYN_BANK`;
`xarena.FIRST_BANK` moved 9 -> 10) and tview (bank 2) JSRFARs into it once per rendered line. This
is the only overlay called from another overlay - see [[x16-bank-to-bank-jsrfar]]. Main only
`loadlib`s it and reports the result to tview via `view_set_syn` ($A006).
Entries: `$A003 setbufs, $A006 paint, $A009 probe, $A00C detect`.

**Two things that bite on a port from MSEDIT:**
1. **ASCII, not PETSCII.** tview renders RAW FILE BYTES. MSEDIT classifies its PETSCII editor
   buffer, so its tables and `fold`/`is_letter` are PETSCII. xsyntax uses `%encoding iso` (it does
   no diskio and prints nothing, so it needs PETSCII nowhere) - without it the keyword tables encode
   A-Z as $C1-$DA and NOTHING ever matches, silently. See [[prog8-ascii-file-byte-match]].
2. **Initialised tables vs the jump table.** The keyword blobs are initialised data, which would
   shove `%jmptable` off its offsets. Fixed with the manual's two-block library pattern
   (`docs/source/binlibrary.rst`): `main` holds ONLY the jmptable + `start()`, real code and tables
   go in a second block emitted after it. See [[prog8-jmptable-init-vars-gotcha]].

**BANK 2 IS NOW FULL - 10 bytes free to $C000.** The next tview change will not fit. Getting even
this far took moving the colour PAINT pass and the extension MATCHING into bank 9 (bank 9 has ~5.7
KB spare, so put anything new there). The thing that nearly sank it: 32-bit `long` file-offset
arithmetic for the find-highlight overlap cost ~600 bytes; solved by having the draw loop record the
find hit's line-relative COLUMNS as it goes (it already does that 32-bit test per char to paint the
highlight) so the syntax path stays entirely 8-bit. **If more room is needed, the identified
candidate is dropping the ZSM header-breakout page (~750 B: `view_render_zsm` + `popcount` +
`zsm_detect` + its label strings) - .zsm still plays with P and still shows its header in hex.**

Colours are consts in `shared-const.p8` (`SYN_*`), full attribute bytes `(CONTENT_BG<<4)|fg`.
Three foregrounds use theme-remapped indices (1/7/14) so they follow Alt-F10; STRING/NUMBER/COMMENT
(13/10/12) are fixed - see [[xfmgr-theme-contrast-rules]]. Viewer geometry also moved to
shared-const so both banks derive the same wrap.

Detection is by EXTENSION (`.bas`, `.bas.txt`, `.basl`, `.bl` -> BASIC; `.md` -> Markdown) - plain
text has no magic bytes, unlike the BMX/ZSM/WAV sniffers. `.bas.txt` needs its own test FIRST (a
name ending `.bas.txt` does not end with `.bas`) and is the dominant extension in `run/BASIC-*`.
`name_fold` canonicalises ASCII *and* PETSCII letters so host-fs name casing can't break the match,
and the **C key** cycles off/BASIC/Markdown as the escape hatch for a wrong guess.
