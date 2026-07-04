---
name: xfmgr-fkey-save-restore
description: "backlog + research — save F-key macros on start, restore on exit; how X16 pfkey works and why true snapshot isn't clean"
metadata: 
  node_type: memory
  type: project
  originSessionId: bd1a090e-2c8b-4d29-a3b0-e992481b15dd
---

Backlog: on XFMGR start, preserve the KERNAL F-key macros; on exit, restore them.

**Research findings (X16 KERNAL):**
- Set macros via `pfkey`: EXTAPI `$FEAB`, `.A=7` (prog8 `cx16.EXTAPI_pfkey=$07`), ROM
  **R47+**. Inputs: `r0`=ptr to string, `.X`=key# (1-8 = F1-F8, 9 = SHIFT+RUN),
  `.Y`=len 0-10 (0 disables). Carry set on error. 10-byte max (kbd-buffer sized,
  same limit as [[x16-launch-program-dynamic-keyboard]]).
- **`pfkey` is WRITE-ONLY. No read-back API**, and the public Memory Map doesn't
  expose the KERNAL macro table. A true snapshot of user customizations would need
  a direct RAM read at an undocumented, ROM-version-specific address = fragile.
- Macros only expand in the KERNAL screen editor (BASIN/line input). XFMGR reads
  keys via GETIN, so macros are dormant mid-run; feature is only about state left
  on exit.

**Strategies:**
- Preferred: **restore-to-defaults** — rewrite known default strings with `pfkey`
  on exit (robust, doesn't disturb screen). Doesn't preserve hand-customized keys.
- `$FF81` (SCINIT) reinstalls default macros but ALSO clears screen + resets
  palette/charset/keymap — too heavy for a clean exit.

**Default macros (write LOWERCASE in prog8 source per
[[prog8-filename-literals-lowercase]] so they encode to $4C.. not $C1-DA):**
F1 `list:` · F2 `save"@:` · F3 `load "` · F4 40/80 toggle (special) · F5 `run:`
· F6 `monitor` · F7 `dos"$`+CR · F8 `dos"` · F9-F11 undefined · F12 debug.

**Open question:** what triggers the "save"? If XFMGR never reprograms the
F-keys, there's nothing to restore. Only matters if XFMGR/a launched util sets
them, or if we `pfkey`-disable (len 0) during XFMGR text-input dialogs so a stray
F-key can't inject a macro.
