---
name: prog8-never-rewrite-source-via-powershell
description: "Never round-trip XFMGR source through PowerShell Get-Content/Set-Content - it destroys the PETSCII/box-drawing glyphs. Use sed for line deletes, Edit for everything else."
metadata: 
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
  modified: 2026-08-01T03:35:56.051Z
---

**Trap hit 2026-08-01 while moving `hist_popup` into the uiutil overlay.** I deleted a line range
with `$lines = Get-Content x.p8 ... Set-Content -Encoding utf8`. The build then failed with ~100
parse errors like `token recognition error at: '?'` and `no viable alternative at input 'sc:<?>'`.

**Cause:** XFMGR sources are full of non-ASCII literals - the box-drawing screencodes
(`sc:'┌'`, `SC_H = sc:'─'`), the tree connectors, and the `←┘` ENTER glyph inside `petscii:`
strings. A Get-Content/Set-Content round-trip re-encodes them and they come back mangled. The
damage is spread over the whole file, so it does NOT look like a localised edit mistake.

**How to delete a line range safely:** `sed -i '2749,2832d' SRC/xfmgr.p8` through the Bash tool.
sed is byte-wise and leaves the encoding alone. Verify afterwards with `grep -c "←┘" SRC/xfmgr.p8`
(it should still find them) before building.

**Recovery:** `git checkout -- SRC/xfmgr.p8`, which is why the frequent commits are worth it. Redo
with the Edit tool, which also preserves the bytes.

**The rule:** Edit tool for content changes, `sed -i` for pure line-range deletes, NEVER
Set-Content / Out-File on a `.p8`. Same applies to `xfmgr.hlp` (it has box-drawing rules).

Related: [[x16-embedded-petscii-color-codes]], [[prog8-build-toolchain]].
