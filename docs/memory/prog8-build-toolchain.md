---
name: prog8-build-toolchain
description: How to compile and run Commander X16 Prog8 programs in this project
metadata: 
  node_type: memory
  type: reference
  originSessionId: ff94bf97-5839-406e-b6b3-a755dab25e6a
---

Compiling/running X16 Prog8 here required tools NOT on PATH — found by searching:

- **Java**: `C:\dev\b4x\java19\bin\java.exe` (nothing on PATH; no JAVA_HOME)
- **64tass assembler** (prog8 needs it to assemble): `C:\8bitProgramming\64tass-1.60\64tass.exe`
- **Compiler**: `prog8c.jar` in the project root (Prog8 v12.1.1)
- **Emulator**: `C:\8bitProgramming\x16emu\x16emu.exe` (path also in LOCAL.BAT)

Build: `build.bat <src.p8>` (created in project root) sets PATH for both, then
`java -jar prog8c.jar -target cx16 <src.p8>` → produces `<src>.prg`.

Automated run + output capture (since the emulator is a GUI):
`x16emu -prg X.prg -run -echo -warp` with `-RedirectStandardOutput` to a file —
`-echo` mirrors KERNAL text output (incl. `txt.print`) to host stdout. Run with
`-WorkingDirectory` set to a CLEAN folder, else the project's `AUTOBOOT.X16` hijacks
boot into a dev menu instead of running your prg. Start-Process, sleep ~6s, Stop-Process.
The emulator sets host-fs root = working directory, so put a sample file tree there to test.

Prog8 v12 gotchas hit: array **length** capped at 256 (use `memory("name",size,0)` slab +
pointer arithmetic for bigger buffers); array **index** must be a byte (use `ubyte` ids,
sentinel 255 not $ffff); no `:` statement separator; `peek`/`poke` are builtins (can't be
sub names); subs are NOT re-entrant (no recursion — use iterative + explicit stacks).
See [[xfmgr-architecture]].
