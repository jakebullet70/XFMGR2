---
name: xfmgr-docs-reference-tree
description: "In-repo docs/ vendors prog8 stdlib, X16 manuals, examples, and agent skills"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f57043d0-c280-46a9-ba6d-9010f3f42cb2
---

The repo vendors reference material under `docs/` (committed) - prefer these local copies
when looking things up instead of reaching to the external install:

- `docs/prog8/cx16/*.p8` - Prog8 cx16 stdlib SOURCES (diskio, textio, syslib, floats, gfx,
  sprites, psg, verafx, etc.). Grep here for exact signatures (e.g. diskio.f_open takes `str`).
- `docs/prog8/examples/` - Prog8 examples; `examples/banking/` is the loadable-library / bank
  pattern the tview overlay is modeled on (see [[xfmgr-drop-viewer-ram]], [[prog8-jmptable-init-vars-gotcha]]).
- `docs/x16/*.md` - official Commander X16 reference manuals (KERNAL, Memory Map, VERA,
  CMDR-DOS, 65C02, Character Sets, IO, Sound, ...).
- `docs/agents/prog8/SKILL.md` and `docs/agents/ASM/SKILL.md` - prog8 and 6502-ASM coding
  skill guides (language gotchas, syntax, stdlib pointers).
- `docs/prog8/PROGB.PLAN.MD` + `PROG8_TO_PROGB_CONVERSION.md` - design + AI conversion guide
  for **ProgB**, a QuickBASIC-style syntax frontend that parses to the SAME Prog8 AST/backend
  (`.pb` files, UPPERCASE keywords, `END X` blocks). A separate effort, not XFMGR.

The external install at `C:\8bitProgramming\prog8-12.2.1` still has what docs/ does NOT: the
compiler SOURCE (Kotlin) and the `.rst` reference docs (e.g. binlibrary.rst). Use it for
compiler-internal questions. See [[prog8-build-toolchain]] and [[memory-is-git-tracked]].
