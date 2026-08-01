---
name: xfmgr-basload-syntax-review
description: "PARTLY REVIEWED 2026-08-01: ## IS a real BASLOAD comment and BASIC/Markdown rules are exclusive - no bug. Remaining checklist (labels, directives, leading digits) still open"
metadata: 
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T06:57:42.043Z
---

**REVIEWED 2026-08-01 - the reported symptom was NOT a bug.** `### RETURN` in a `.basl` file showed
greyed out, suspected of being the Markdown heading rule leaking into BASIC mode. It was not:

1. **`##` is a genuine BASLOAD comment.** `x16-MSEDIT/SRC/basload.md`, *"Option: ## Comment"* - "an
   alternative comment that is never included with the resulting code". So `xsyntax.basic_line`
   colouring from `##` to end-of-line is CORRECT. **Do not "fix" it.**
2. **The two rule sets are strictly exclusive.** `xsyntax.paint` is `if mode == 2 -> md_line() else
   -> basic_line()`. One or the other, never both - a Markdown rule cannot reach a BASIC file.

The genuinely weird coloring the user was seeing was the PETSCII/ASCII glyph substitutions, fixed
separately in builds 244-247 ([[x16-custom-glyph-slots]]).

**STILL OPEN from the original review checklist** (added 2026-07-24, not yet done):
- **Single-`#` directives get no color** - `#REM 0|1`, `#INCLUDE "file"` and the rest of basload.md's
  "BASLOAD Options" render as plain text. Known gap; the user was told and did not ask for it.
- **Labels** (`name:` at line start) stay default-colored - should they get their own color? Dotted
  labels like `DIR.READ.BIN.NUM16` are already kept as ONE token so an embedded `READ` is not
  mis-colored (`basic_line`), which is the important half.
- **Leading digits** are colored as "line number", but BASLOAD source has none - cosmetic.
- **Keyword coverage** vs current X16 BASIC not re-checked.

Cross-reference: MSEDIT IS a BASLOAD IDE, so `x16-MSEDIT/SRC/syntax.p8` is the gold standard to diff
against, and `SRC/basload.md` is the language spec. Byte-encoding reminder for the tables:
[[prog8-ascii-file-byte-match]].

Related: [[xfmgr-syntax-coloring]], [[xfmgr-viewer-wrap-modes]], [[xfmgr-docs-reference-tree]].
