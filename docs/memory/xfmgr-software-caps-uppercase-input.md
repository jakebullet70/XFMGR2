---
name: xfmgr-software-caps-uppercase-input
description: "Backlog: let the user type UPPERCASE in input fields via MSEDIT's software-Caps-Lock trick (fold at insert, KERNAL caps stays off)"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
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
