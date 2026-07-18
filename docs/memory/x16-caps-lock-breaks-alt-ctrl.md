---
name: x16-caps-lock-breaks-alt-ctrl
description: "CAPS LOCK ON breaks XFMGR's ALT/CTRL menus; no KERNAL API clears it - shflag is $A80C in RAM bank 0"
metadata: 
  node_type: memory
  type: project
  originSessionId: a31951ee-0367-4b90-ba73-026b129abe1f
  modified: 2026-07-18T16:38:12.302Z
---

**CAPS LOCK being ON stops XFMGR's ALT and CTRL command keys from working.** ALT+letter already
returns a graphics code rather than the letter ([[x16-alt-is-commodore-key]]), and caps shifts what
the keyboard reports again on top of that, so the `when` blocks dispatching those menus stop
matching. Typed text (filenames, search terms, wildcards) also comes out uppercase.

This is why folding at the input sites is NOT a fix: it would correct typed text but not the command
keys. The machine's caps state itself has to change.

**Fixed in build 189 (PR #3):** `caps_off()` at startup, `caps_restore()` on exit, in `SRC/xfmgr.p8`.
Restore sits before all three exit branches (run_exit / setup_exit / plain quit), so every way out -
including the chain_run hand-offs to XFSETUP and Alt-X - puts caps back.

**The asymmetry that shapes the implementation:**
- **READ is documented:** `cx16.kbdbuf_get_modifiers()` ($FEC0), bit 4 ($10) = caps.
- **CLEAR is not.** No KERNAL API sets the toggle. The `kbd_leds` extapi ($FEAB, .A=$0E) drives
  only the LED and the reference says outright it "does not change the state of the kernal's caps
  lock toggle".
- The toggle is the KERNAL's **`shflag` byte at `$A80C` in RAM BANK 0** - found in the emulator's
  `x16emu/kernal.sym`, not in any published spec. The memory map marks bank 0 `$A000-$BEFF`
  "System Reserved", which is what makes it writable rather than ROM.

**The guard pattern (reusable for any undocumented poke):** if caps is already off, touch nothing at
all. Only when caps is ON do we read `$A80C` and require it to equal EXACTLY what the documented
`kbdbuf_get_modifiers()` just returned before writing. That match is meaningful precisely because we
only get there with a non-zero value, so it is not a coincidental zero. If a future ROM relocates
shflag the two disagree, the write is skipped, and the feature quietly does nothing instead of
corrupting an unrelated KERNAL variable. Restore only runs if that check passed.

Prog8 note: `&` (precedence 7) binds TIGHTER than `==` (11) - the opposite of C - so
`mods & MOD_CAPS == 0` is already `(mods & MOD_CAPS) == 0`. Parenthesise anyway for readers.

See also [[x16-adaptive-ctrl-keys]] for the other reason these keys need special handling.
