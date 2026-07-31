---
name: xfmgr-viewer-footer-bank9
description: "DONE build 219: the viewer's 2-line footer is drawn by xsyntax (bank 9), not tview - and every literal there needs a petscii: prefix"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T16:00:44.064Z
---

**DONE build 219 (2026-07-31).** The tview viewer's footer is now **TWO bars** (rows 28+29; text area
shrank to `shared.VIEW_ROWS = 27`), and all of it is drawn by **`syntax.draw_footer` in the xsyntax
overlay, bank 9** - jmptable entry **$A012**. tview only reports state:

    syn_draw_footer(flags @R0, setnum @R1, settot @R2, offlo @R3, offhi @R4, blocks @R5)

`flags` packs FF_HEX / FF_EOF / FF_COLOR / FF_SET / FF_ZSM. The 24-bit position is split into a word +
a byte. tview wraps the call in `paint_footer()`.

**The position indicator (build 227-232).** It started as a page NUMBER and was reported "not moving"
**twice** - both times the value was computed correctly and was simply the wrong QUANTITY. A page index
barely moves while reading and is meaningless in a dump; replacing it with the page-top byte offset was
no better, because stepping matches with N inside ONE page moves the highlight and never the page top.
It now shows **`Ofs $hhhhhh  nn%`**, and reports the **hit's own offset whenever the highlight is on
screen**. `blocks` is the directory entry's size (254-byte CBM blocks, 0 = unknown) - the percentage
needs a file size and measuring it in the viewer would mean reading the whole file on every open.
**The lesson: when a readout looks frozen, check whether it is answering the reader's question before
you go hunting for a codegen bug.** The renderer flags visibility at the point it picks the highlight
color - free, and it cannot disagree with what was painted, unlike bounds-checking in the footer (two
32-bit compares = 69 bytes, which overflowed the overlay).

**Why bank 9:** tview (bank 2) was completely FULL - I spent four builds shaving bytes (page cache
64->44->12, dropped labels, dropped a `>` key) before accepting that the footer had to move. It is viewer
CHROME, not syntax coloring, so it moved for exactly the reason `read_find` (the Find prompt) already
lives there. **Result: tview 8187 -> 7210 B**, and the page cache went back to the full `long[64]`.
xsyntax still has ~3.9 KB free - **it is the release valve for future viewer work.**

**TRAP 1 - encoding.** xsyntax is `%encoding iso` (it colorizes ASCII source); the viewer's screen runs
the **PETSCII** charset, where letter cases are SWAPPED relative to ISO. Every literal in the footer
needs a **`petscii:`** prefix or you get `pGdN/pGuP  tOP  bOTTOM`. Same for char literals: `'a'` is $61
in ISO but must be $41 (`petscii:'a'`) for lowercase on screen. Digits $30-$39 match in both.

**TRAP 2 - `long` into an `@Rn` param is a CODEGEN ERROR, not a warning:**
`prog8.code.core.AssemblyError: invalid register for lsw: R4`. Hoist into a local first
(`uword folo = (view_off & $0000ffff) as uword`) then pass it. See [[prog8-long-type-limits]] and
[[prog8-rn-param-clobber]].

**TRAP 3 - anything that writes the bottom row must call `paint_footer()` on the way out.**
`view_notify` and the Find prompt blank row 29 only, leaving ONE bar showing; the footer used to stay
half-drawn until the next page render, which re-reads the file from disk - long enough to look broken.
The Find prompt also blanks row 28 now, so the prompt doesn't sit on top of the key bar.

**Free-space gotcha:** the `.ovl` FILE size is NOT the headroom - BSS is allocated after the image up to
$C000. TVIEW.OVL looked like it had 646 B spare when the real margin was ~21 B. Measure by building.

Related: [[xfmgr-overlay-ram-strategy]], [[xfmgr-syntax-coloring]], [[prog8-jmptable-init-vars-gotcha]].
