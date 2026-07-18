---
name: x16-bank-to-bank-jsrfar
description: "A banked overlay CAN @bank-call another bank - JSRFAR is bank-agnostic; the blocker is data visibility, not the call"
metadata: 
  node_type: memory
  type: project
  originSessionId: a31951ee-0367-4b90-ba73-026b129abe1f
  modified: 2026-07-18T07:41:08.306Z
---

**A bank overlay CAN call another bank overlay.** Confirmed working 2026-07-18 (XFMGR build 186:
tview in bank 2 JSRFARs into xsyntax in bank 9, once per rendered line).

The comment in `SRC/xfmgr.p8` next to the zsmkit extsubs says "Only main (always mapped below
$9F00) may call it - a banked overlay cannot @bank-call a different bank". **That generalisation is
wrong.** It may hold for zsmkit specifically (an external blob with its own conventions), but not in
general. `docs/x16/X16 Reference - 05 - KERNAL.md` on JSRFAR ($FF6E) is explicit: *"This works
independently of which RAM or ROM bank the currently executing code is residing in."* JSRFAR is what
prog8 emits for `extsub @bank` with a CONSTANT bank; it runs from ROM, reads its 3 inline argument
bytes from the caller's still-mapped code, switches, calls, and restores the caller's bank before
RTS. (Prog8's `todo.rst` notes a VARIABLE bank still has an operand-patching problem - constants are
the safe form.)

**The real constraint is DATA, not the call.** While bank N is mapped at $A000, the caller's own
bank RAM is invisible. So anything shared between two overlays must live in **main RAM** (mapped
below $A000 regardless of bank) and be passed as a pointer. In XFMGR the viewer's line + colour
buffers are main-RAM buffers owned by xfmgr.p8, handed to tview at startup, which forwards them to
xsyntax - see [[xfmgr-syntax-colouring]]. A name/string held in the calling overlay must be
`strings.copy`'d into that shared buffer before the far call can see it.

**Always gate the far call.** Calling into a bank whose overlay failed to load jumps into garbage.
Pattern used: main does the `loadlib` and passes the result in; the callee bank also exposes a
`probe()` returning a magic byte, and the caller only enables the feature if the magic comes back.
That one check proves the blob loaded, the `%jmptable` really is at its fixed offsets, AND that the
bank-to-bank call works on this machine - degrading to the feature being off instead of crashing.

See [[xfmgr-overlay-ram-strategy]] for the bank map and [[prog8-jmptable-init-vars-gotcha]].
