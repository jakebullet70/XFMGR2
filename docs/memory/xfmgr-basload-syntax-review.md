---
name: xfmgr-basload-syntax-review
description: "Backlog: review the viewer's BASLOAD syntax coloring against the real BASLOAD spec (comments, labels, directives, no line numbers)"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**Backlog (added 2026-07-24).** The viewer's BASIC/BASLOAD syntax coloring (`syntax.basic_line` in
xsyntax.p8, bank 9) has partial BASLOAD support that **needs a review pass** against the actual BASLOAD
language, because it was built mostly for tokenized-BASIC listings and BASLOAD source differs (labels,
long names, no line numbers, its own comment + directive forms).

**What exists today (xsyntax.p8):**
- `detect()` (~168) maps `.basl` / `.bl` / `.bas` / `.bas.txt` all to the BASIC colorizer.
- `##` -> comment to EOL (`basic_line` ~349-353).
- REM keyword -> comment to EOL (~373-378).
- Dotted BASLOAD labels (`DIR.READ.BIN.NUM16`) kept as ONE token so an embedded `READ` isn't mis-colored;
  labels stay default-colored since no keyword contains '.' (~360-369).
- Leading digits colored as "numeric constant / line number" (~391) - but BASLOAD source has NO line
  numbers, so that comment/assumption is suspect.
- Keyword tables (~75-77) are CBM BASIC V2 + X16 additions only.

**Review checklist (verify against the spec, then fix):**
- **Comment syntax:** is `##` actually BASLOAD's comment marker? Confirm BASLOAD doesn't also use `'`
  (apostrophe) or a leading `.`/directive form for comments/metacommands. A lone `#` currently falls
  through to default - check that's right (e.g. `PRINT#` channel).
- **Labels:** should a label (name at line start, possibly `name:`) get its OWN color instead of default?
  The `:` after a label is currently treated as punctuation (token breaks at `:`).
- **Directives / metacommands:** BASLOAD has non-BASIC-V2 directives (declarations, includes, options)
  not in kw_stmt/kw_stmtx/kw_func - decide whether they should color as keywords.
- **No line numbers:** reconsider the leading-digit = line-number handling; in BASLOAD a leading number
  is unusual and may deserve plain numeric-constant treatment (cosmetic).
- **Keyword coverage:** cross-check the X16 keyword sets are complete/current.

**Gold-standard cross-reference:** x16-MSEDIT IS a BASLOAD IDE (F5 hands the file to the BASLOAD ROM
tool), and its own colorizer is `x16-MSEDIT/SRC/syntax.p8`; the language is documented in
`x16-MSEDIT/SRC/basload.md`. Diff XFMGR's `basic_line` against MSEDIT's `classify` and align on comment/
label/keyword rules. (XFMGR's viewer syntax path: [[xfmgr-syntax-coloring]]; docs tree that vendors these:
[[xfmgr-docs-reference-tree]].) Byte-encoding reminder for the tables/matching:
[[prog8-ascii-file-byte-match]]. Scope: review first, then likely small edits.
