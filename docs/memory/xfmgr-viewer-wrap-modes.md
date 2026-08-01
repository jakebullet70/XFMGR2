---
name: xfmgr-viewer-wrap-modes
description: "Viewer wrap modes (W cycles char/word/off, default OFF) and the trap that syn_paint re-derives screen positions, so any layout change must be mirrored there"
metadata: 
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T06:57:08.936Z
---

**DONE builds 249-250 (2026-08-01).** The text viewer has ONE wrap setting, cycled by `W`, not two
toggles - "wrap at a word boundary" and "do not wrap" are answers to the same question:

| `view_wrap` | behaviour |
|---|---|
| `WRAP_CHAR` 0 | break anywhere; every byte on screen, words split (the original) |
| `WRAP_WORD` 1 | break at spaces |
| `WRAP_OFF` 2 | one logical line = one screen row, truncated; ←/→ pan by `HSCROLL_STEP` |

**`WRAP_OFF` is the DEFAULT** (user's call, build 250): it is the only mode that does not lie about
the file. Wrapping invents line breaks that are not in the bytes and a wrapped line reads as two.

**Word wrap needs NO line buffer.** The lookahead reads `viewbuf` directly - the bytes after the
cursor are already in the chunk just read. A word straddling a chunk boundary is treated as fitting
(falls back to a character break for that one word: rare, harmless). A word longer than a whole row
must still split or the renderer loops forever.

**THE TRAP - `syn_paint` re-derives screen positions.** It is NOT told where each character landed;
it re-walks the line applying the wrap rule itself, so cell k of the buffer maps to cell k on screen.
**Any change to tview's layout rule must be mirrored in xsyntax.paint or the right colors land on the
wrong cells.** That is why the wrap mode is passed in the HIGH NIBBLE of `paint`'s `mode` byte
(syntax mode in the low nibble) - it keeps the signature and the jmptable slot unchanged, the same
trick the footer uses with bits 5-6 of its flags byte.

Coloring is deliberately SKIPPED, never faked, in the two cases it cannot be got right:
- **panned** (`view_hscroll != 0`): the first visible char is not buffer index 0, so `ln_col + i`
  is wrong for every cell.
- **`WRAP_WORD` on a line longer than `VIEW_WIDTH`**: only tview knows where it broke, and it decided
  from raw file bytes that are gone by paint time. A shorter line never wrapped, so it colors fine.

**Changing wrap re-anchors the page chain HERE, not at byte 0.** Wrap decides how many rows a logical
line takes, which decides where a page ends, so every cached offset below is invalid. But restarting
at 0 re-read the file from the top and threw away your place. `view_pages[0] = view_pages[view_page]`
instead - any byte offset is a valid page start (a page may already begin mid-line). PgUp then
dead-ends there, like the cache-restart in `pages_push`.

Related: [[xfmgr-syntax-coloring]], [[xfmgr-viewer-iso-pet-toggle]], [[xfmgr-viewer-line-gutter]]
(dropped - XTree has no gutter), [[xfmgr-basload-syntax-review]].
