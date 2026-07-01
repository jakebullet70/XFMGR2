---
name: xfmgr-run-and-persistence
description: How XFMGR2 is built/run cleanly and where it persists input history
metadata:
  type: project
---

XFMGR2 standard build+run is `run.bat [src.p8]` (not the emulator launched from the
project root). It compiles via build.bat, copies xfmgr.prg into the `run\` folder, and
launches `x16emu -fsroot run\ -prg xfmgr.prg -run`. The clean `run\` folder exists
because the project root contains `AUTOBOOT.X16` (the user's "SADLOGIC DEV MENU"), which
the Kernal auto-runs and would otherwise hijack the launch. `run\` also holds sample
content to browse (GAMES\, DOCS\, README.TXT).

Input-history persistence is PER-PROMPT: each text prompt has its own file under a
`hist/` directory at the drive root (`run\hist\` under the emulator) — copy.his, move.his,
rename.his, mkdir.his, filespec.his. input_line takes a `histname` category arg; it calls
hist_load(cat) when the prompt opens (fills the single in-memory ring, last 15 entries,
newest-first) and hist_store+hist_save(cat) when an entry is accepted. The Up-arrow picker
is LIFO (newest at bottom, selected). Because files are per-category they start EMPTY until
you accept an entry in that specific prompt — Up does nothing on an empty category (this is
expected, not a bug; verified the save/load round-trip works headlessly). Save does
delete-then-f_open_w for portable overwrite. input_line is a real line editor (Left/Right/
Home/Backspace/insert-at-cursor, block cursor). See [[xfmgr-architecture]].

Environment-specific key: delete-tagged is Ctrl-X under the emulator (the emulator eats
Ctrl-D's $04) and Ctrl-D on real hardware, chosen at startup via `emudbg.is_emulator()`.
