---
name: xfmgr-software-caps-uppercase-input
description: "DONE build 196: software Caps Lock in the line editor - Caps Lock key toggles upper_mode, folds typed letters to capitals at insert, normalized to ASCII on ENTER"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**DONE build 196 (2026-07-24).** Implemented in xfmgr.p8: `bool upper_mode`; `caps_clear(mods)` factored
out of `caps_off` and shared; `input_key()` (wait_key that polls the Caps Lock key, clears the KERNAL
bit via caps_clear, flips upper_mode once per press, redraws); `draw_caps_hint()` shows "CAPS" on the
LEFT of the prompt's row 2; `input_line` uses input_key, the char branch folds an unshifted letter
$41-$5A UP to $C1-$DA when upper_mode (SHIFT already gives $C1-$DA), and the ENTER handler folds every
$C1-$DA back to ASCII uppercase $41-$5A. **Net: on-disk/history bytes are byte-identical to before
(always $41-$5A); only the live DISPLAY case changed, and the user can now lock/show capitals.** The
original design notes are kept below for reference.

---

**Backlog (added 2026-07-24).** Let the user type **uppercase characters in XFMGR input fields**
(filename entry, find/search terms, wildcards, mkdir/rename names). Today XFMGR force-clears the KERNAL
Caps Lock at startup because Caps breaks the Alt/Ctrl command keys ([[x16-caps-lock-breaks-alt-ctrl]],
[[x16-adaptive-ctrl-keys]]) - which as a side effect leaves the user **no way to type capitals** in
those prompts. XFMGR is PETSCII-lowercase, so unshifted keys give a-z; Shift gives graphics-adjacent
codes, not clean capitals - so "just press Shift" doesn't cleanly work either.

**Copy MSEDIT's SOFTWARE Caps Lock - it already solved exactly this.** Repo:
`C:\dev\CmdrX16\dos_tools\x16-MSEDIT`. The idea: a `upper_mode` bool that folds typed letters to
uppercase **at INSERT time**, while the KERNAL Caps bit stays OFF (so the Alt menus keep working). The
Caps Lock KEY toggles this software flag instead of the machine's caps state.

**Reference, file:line in x16-MSEDIT/SRC/edit.p8:**
- `bool upper_mode` decl (~52) - "software Caps Lock: fold typed letters to uppercase at INSERT time
  (never via the KERNAL shflag, which breaks the Alt menus)."
- **Toggle** in `get_editor_key` (~1822-1828): when the Caps Lock modifier is seen, call `caps_kill()`
  to clear the KERNAL Caps bit (menus need it gone); on a SUCCESSFUL clear, flip `upper_mode` EXACTLY
  ONCE per press. If it can't clear (a ROM where shflag moved) DON'T flip - avoids a flicker loop.
- **Apply at insert** (~5069-5076): for a printable key, if `upper_mode`:
  - PETSCII: `k += $80` folds lowercase $41-$5A up to capital $C1-$DA.
  - ISO: `k -= $20` folds a-z $61-$7A up to A-Z $41-$5A. (only relevant once [[xfmgr-viewer-iso-pet-toggle]] lands)
- **Footer indicator** (~1751): `mnu_mode(...)` shows "CAPS" when on, widening the status field.

XFMGR already has the hard part - `caps_off`/`caps_kill` + the guarded shflag write at `$a80c`
([[x16-caps-lock-breaks-alt-ctrl]]). So the port is small:
1. Add a `upper_mode` bool.
2. In the input-line editor (`input_line` in xfmgr.p8, used by all the prompts), when a Caps Lock press
   is detected, clear the KERNAL bit via the existing guarded path and flip `upper_mode` once.
3. At the char-accept site in `input_line`, if `upper_mode` and the byte is $41-$5A, add $80 before
   storing (so it lands as PETSCII capital $C1-$DA).
4. Optionally show "CAPS" in the prompt/banner while active.

Note the storage encoding: a folded capital is PETSCII $C1-$DA. Make sure the consumers (filename open,
find match) handle that case - the deployed-filename rule ([[x16-deployed-filenames-uppercase]]) and the
ASCII/PETSCII byte-match gotchas ([[prog8-ascii-file-byte-match]], [[prog8-filename-literals-lowercase]])
are the things to check when the typed name is later used against the filesystem. Scope: small, no new
machine-state risk (caps stays off, same as now). Related: [[x16-alt-is-commodore-key]].
