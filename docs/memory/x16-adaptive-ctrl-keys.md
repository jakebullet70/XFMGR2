---
name: x16-adaptive-ctrl-keys
description: XFMGR rebinds the CTRL keys the x16 emulator swallows - Delete/Find/Move differ emu vs hardware
metadata: 
  node_type: memory
  type: project
  originSessionId: 8083e14b-c2de-429f-bb82-9254f48d6034
  modified: 2026-07-31T14:09:03.718Z
---

The x16emu emulator window GRABS some Ctrl combos before they reach the app, so XFMGR picks
**environment-specific CTRL keys** at startup via `emudbg.is_emulator()` ([[prog8-build-toolchain]]).

**Five adaptive commands** (emulator key / hardware key):

| Command | Emulator | Hardware |
|---|---|---|
| Delete tagged | Ctrl-X | Ctrl-D |
| Find files | Ctrl-N | Ctrl-F |
| Move tagged | Ctrl-O | Ctrl-M |
| Search tagged (contents) | Ctrl-E | Ctrl-S |
| View tagged (sequential) | Ctrl-L | Ctrl-V |

(Tag-by-wildcard is Ctrl-W in BOTH — not adaptive, just avoided, since Ctrl-S is swallowed.)

**Ctrl-V is swallowed too** (the emulator's PASTE) — found 2026-07-31 when Search + the sequential
viewer were added ([[xfmgr-file-text-search]]). **Choosing an emulator substitute needs care:**
Ctrl+letter folds to control codes $01-$1A, and several collide with this app's RAW navigation keys —
**Ctrl-B = $02 = PgDn**, **Ctrl-Q = $11 = cursor-down**. That ruled out the obvious mnemonics (B for
Browse, Q); **Ctrl-L** ($0C, "Look") and **Ctrl-E** ($05) are clean. The collision is only cosmetic
(dispatch keys off the held-modifier menu_mode), but there is no reason to court it.

**Pattern (mirror this for any new adaptive key):**
- TWO globals per key: `x_key` = lowercase **dispatch** char (e.g. 'x'/'d'), `x_char` = uppercase
  **display** char (e.g. 'X'/'D'). Set together in the `if emudbg.is_emulator() {...} else {...}` block
  in `start()` (SRC/xfmgr.p8).
- **Dispatch by runtime compare** in `handle_ctrl`: `if letter == move_key { ... return }` BEFORE the
  `when letter` block — a runtime var can't be a constant `when`-case.
- **Label** via a `*_label(char)` helper in uiutil (bank 4): hardware picks the letter out of the whole
  word (`\x9eD\x05elete`, `\x9eM\x05ove`); emulator uses `<KEY>-<Word>` since the emu key isn't the
  word's first letter (`X-Del`, `N-Find`, `O-Move`). `move_char` is threaded to `ui_draw_commands` as
  an extra @R5 param.
- Ctrl+letter arrives as control code $01..$1A; `wait_command` folds it to $41..$5A ('A'..'Z'). So on
  hardware **Ctrl-M ($0D) folds to 'M'** and dispatches fine; the emulator just never lets $0D through.

Both `xfmgr.hlp` (F1 help: CTRL-menu list + an Emulator-vs-Hardware table) and `README.md` document the
split — keep all three (code, hlp, readme) in step when adding/changing an adaptive key. Move was made
adaptive 2026-07-05 (was Ctrl-O only). Related: [[xfmgr-architecture]], [[x16-alt-is-commodore-key]].
