---
name: x16-alt-is-commodore-key
description: On the X16, ALT+letter returns a Commodore-key graphics code, not the letter
metadata:
  type: reference
---

On the Commander X16, the ALT key acts as the **Commodore (graphics) key**: holding ALT and
pressing a letter does NOT return that letter from GETIN — it returns a PETSCII graphics code
in the range $A1..$BF (161..191), scattered (not linear). E.g. ALT+S delivers 174 ($AE) =
Commodore-S; ALT+X = 189 ($BD). Function keys are unaffected (ALT+F3 still = 134).

The modifier byte from `cx16.kbdbuf_get_modifiers()` ($FEC0, bit1=$02=alt) DOES correctly
report ALT held — so detecting "ALT is down" works fine; only the returned key code is the
gotcha. Symptom in XFMGR2: the ALT menu appeared (modifier detected) but ALT+letter commands
never fired because the code never matched 's'/'x'.

Fix used in [xfmgr.p8]: a 31-entry reverse table `alt_letter[]` indexed by (code-161) maps the
graphics codes back to base letters; wait_command applies it only when the ALT menu is active
(menu_mode==2). Compare with the CTRL path, where the emulator instead eats some combos
outright (Ctrl-D/$04, Ctrl-S, Ctrl-M=$0D) — see [[xfmgr-architecture]].
