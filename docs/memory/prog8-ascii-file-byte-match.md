---
name: prog8-ascii-file-byte-match
description: "Parsing an ASCII disk file byte-by-byte must use raw ASCII codes, not prog8 char literals (they're PETSCII)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: d0a6835b-bf21-46c8-9499-640b23747d2a
---

When XFMGR reads a plain-ASCII text file from disk (e.g. `xfmgr.hlp`) and inspects
its bytes, compare against **raw ASCII byte codes**, NOT prog8 char literals. This
program compiles strings as PETSCII, so a source `'B'` is `$C2`, `'u'` is `$55`,
`'i'` `$49`, `'l'` `$4C`, `'d'` `$44` — none equal the file's real ASCII
`$42,$75,$69,$6C,$64`. A letter comparison silently never matches.

The trap: digits (`$30-$39`) and space (`$20`) are identical in ASCII and PETSCII,
so numeric/whitespace scanning works and hides the bug — only letter comparisons fail.

Real case (fixed 2026-07-05): `install.p8` `read_build()` scanned for `"Build"`
using char literals, so it always returned 0 and the installer printed nothing
about the release/installed build. Fix: `const ubyte A_B = $42` … and compare
`hbuf[i] == A_B`, etc. Same class of issue as [[prog8-filename-literals-lowercase]]
(source letters ≠ the bytes the FS/file actually holds); see also [[x16-cp437-iso-keyboard]].
