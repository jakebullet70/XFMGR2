---
name: x16-embedded-petscii-color-codes
description: Save code bytes by embedding PETSCII colour control codes inside one txt.print string instead of separate txt.color()+txt.print() calls
metadata: 
  node_type: memory
  type: reference
  originSessionId: b8fa7cc6-ce21-49c0-9d7e-f50a35429b63
---

**Technique: inline PETSCII colour codes to shrink multi-colour text.** On the X16, the
KERNAL's CHROUT (which `txt.print` calls per byte) interprets PETSCII colour **control
codes** inline, so a run like

```prog8
txt.color(COL_ACCENT) : txt.print(">")     ; ~5B (lda+jsr) + ~7B (lda/ldy/jsr) each segment
txt.color(COL_FG)     : txt.print("Expand ")
```

collapses to ONE string + ONE call:

```prog8
txt.print(petscii:"\x9e>\x05Expand ")      ; \x9e=accent \x05=fg, as raw bytes in the string
```

**Colour code ↔ COL_* index (X16 DEFAULT palette only):**
- `\x05` = white  = `COL_FG` (1)
- `\x9e` = yellow = `COL_ACCENT` (7)
- `\x9a` = lt-blue = `COL_TITLE` (14)

(General C64/X16 set: $1c red, $1e grn, $1f blu, $81 orange, $90 blk, $99 lt-grn, $9b lt-gray,
$9c purple, $9f cyan.) Glyphs embed too: `←`=$5f, `┘`=$fd (so `←┘` = the `CR_STR` ENTER glyph),
`↑`=$5e — just type them in the `petscii:"..."` literal.

**Verified facts (Prog8 v12, this project):**
- `\xNN` escapes survive the `petscii:` prefix as RAW bytes (asm dump: `.byte $9e,$3e,$05,...`),
  NOT re-encoded. Confirmed with a probe.
- The app runs in mixed/lowercase mode, so Prog8 encodes UPPER letters to $c1..$da — same as any
  existing `txt.print("Esc")`, so nothing special needed for capitals.
- End each string with the colour the following code expects (usually `\x05` = `COL_FG`) so later
  prints/rows inherit the right colour, exactly as the old trailing `txt.color(COL_FG)` did.

**Measured:** converting `pick_dir` footer (8 segments), `hist_popup` footer, and `prompt_hint`
saved **170 bytes** of image (freed the same in main RAM, 1.8→2.0 KB). Savings ≈ 5B per colour
change + collapsing N prints to 1.

**Trade-off / when NOT to use:** hardcodes the colour bytes, DECOUPLING from the `COL_*` theme
constants — a retheme (e.g. changing `COL_ACCENT` off 7) won't propagate to the `\x9e`s; you'd
hand-edit every string. And `"\x9e<\x05Collapse"` is less readable. Use for STATIC, colour-heavy
strings (menus, footers, hints); keep `txt.color()` calls where content is dynamic (sort mode,
paths, counts) or where theme-following matters. Related: [[xfmgr-architecture]],
[[always-report-mem-stats]].
