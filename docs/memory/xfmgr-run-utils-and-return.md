---
name: xfmgr-run-utils-and-return
description: How XFMGR can run its own utils (editor/viewer/hex) and return — two researched patterns
metadata: 
  node_type: memory
  type: reference
  originSessionId: ecce6089-1862-45c8-b4ec-b0098baae389
---

Research (2026-06-30) on letting XFMGR2 run its OWN utility programs (text editor,
file viewer, hex editor) and return. Target is cooperative own-utils; 3rd-party
programs that don't cooperate are out of scope. Full writeup + recipes + sizes:
`C:\Users\Admin\.claude\plans\the-internal-text-editor-deep-alpaca.md`.

There is NO X16 OS process/swap model — you build the loop from Kernal primitives.
Two viable patterns:

**A) Banked-library overlay (lossless, no state to save).** Prog8 supports it
natively: build the util with `%output library` + `%address $A000` + `%memtop $C000`
(emits a `.bin`), expose entries via a `%jmptable` (init at $A000, then $A003/$A006…),
load with `diskio.loadlib("util-a000.bin", $a000)` into a reserved bank, call via
`extsub @bank N $a000 = ...` (Prog8 auto-JSRFARs). XFMGR stays resident -> zero state
loss. Wrap entries in `sys.save_prog8_internals()`/`restore_prog8_internals()`.
Limit: 8 KB code+data per bank. Templates: `docs/prog8/examples/fileselector/` and
`docs/prog8/examples/banking/`. (XFMGR's `xviewer` is a compiled-in module, NOT this.)

**B) Swap-and-relaunch (user-PREFERRED; utils stay full standalone PRGs).** Util is a
normal `$0801` PRG (no 8 KB limit). Key insight: the file arena (banks 2..high_bank)
and dir-extras ([[x16-banked-ram-min-config]], bank 1 `DX_BANK`) SURVIVE a child PRG
load if the child honors the bank reservation (same contract `op_edit` gives X16 Edit,
see [[xfmgr-editor-bank-handoff]]). So resume is INSTANT: snapshot only the ~3-6.5 KB
main-RAM control structures (xtree node arrays + used dname_buf + xfiles indexes +
xarena state + cursors) into one reserved bank `high_bank+1`, memcpy back on return —
no re-scan. Handoff via bank-0 `$BF00` (`cx16.set_program_args`/`get_program_args`):
survives the load, Kernal zeroes it on cold boot, so absent magic = cold start.
Relaunch both directions reuses existing `chain_run()` (dynamic-keyboard
`LOAD`+`RUN`). Cost: ~25 KB XFMGR reload per hop (optional later: golden-RAM
`$0400-$07FF` `LOAD`+`JMP` loader to skip the BASIC bounce).

Rule of thumb: small tightly-coupled tools -> A (instant, lossless); larger or
independently-runnable tools (full hex editor) -> B.
