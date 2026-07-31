---
name: xfmgr-viewer-footer-bank9
description: "DONE build 219: the viewer's 2-line footer is drawn by xsyntax (bank 9), not tview - and every literal there needs a petscii: prefix"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-07-31T14:08:31.041Z
---

**DONE build 219 (2026-07-31).** The tview viewer's footer is now **TWO bars** (rows 28+29; text area
shrank to `shared.VIEW_ROWS = 27`), and all of it is drawn by **`syntax.draw_footer` in the xsyntax
overlay, bank 9** - jmptable entry **$A012**. tview only reports state:

    syn_draw_footer(flags @R0, setnum @R1, settot @R2, page @R3, offlo @R4, offhi @R5)

`flags` packs FF_HEX / FF_EOF / FF_COLOR / FF_SET / FF_ZSM. The 24-bit hex offset is split into a word +
a byte. tview wraps the call in `paint_footer()`.

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
