---
name: x16-launch-program-dynamic-keyboard
description: How XFMGR launches another PRG on exit; X16 keyboard buffer is only 10 bytes
metadata:
  type: reference
---

The X16 keyboard buffer holds exactly **10 bytes** (verified headlessly via kbdbuf_peek's
queue-length return). So stuffing a full `LOAD"NAME.PRG"`+CR+`RUN`+CR (~20 bytes) via
`cx16.kbdbuf_put` is truncated mid-name (symptom: BASIC shows `load"hello` and nothing runs).

XFMGR's `chain_run(name)` (Alt-X execute / exit-to-run) instead uses the **dynamic keyboard**,
modelled on AUTOBOOT.BASL's COMP_TO_BASLOAD: PRINT the `LOAD"name"` line on screen, move the
cursor back UP onto it with two cursor-up codes ($91), then feed only `CR` + `RUN` + `CR` (5
bytes, fits) through the buffer. BASIC's screen editor re-reads the whole LOAD line off the
screen when it sees the CR. Layout that works (verified: target actually loads AND runs):
clear ($93) -> nl -> "running…" (row 1, gets overwritten by BASIC's "READY.") -> nl ->
`load"name"` (row 2) -> $91 $91 (cursor up to row 0) -> kbdbuf_clear, then put $0d 'r' 'u' 'n' $0d.
The 2-up count is what makes BOTH the LOAD and RUN fire (1 or 3 ups: RUN never runs). A harmless
cosmetic empty `LOAD ":*"` may flash first; it loads nothing / gets overwritten.

Note `LOAD"x"` from a *running* BASIC program auto-runs the loaded program (CBM chaining) — that's
why feeding RUN (which starts our on-screen LOAD line) ends up launching the target. Sample
PONG.PRG/MAZE.PRG in run\GAMES are 10-byte text stubs; run\GAMES\HELLO.PRG is a real compiled
prog8 program (SRC\hello.p8) kept as a genuine Alt-X test target. See [[xfmgr-run-and-persistence]]
and [[x16-alt-is-commodore-key]].
