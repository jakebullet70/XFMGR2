---
name: xfmgr-viewer-find-history
description: "DONE build 198: viewer Find prompt gets up-arrow history (viewfind ring); main loads/saves around view_file, read_find recalls via cwd-safe hist_get/hist_store"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**DONE build 198 (2026-07-24).** Up-arrow now recalls earlier terms in the viewer's Find prompt, on its
OWN "viewfind" ring (str VIEWFIND_CAT in xfmgr.p8). Division forced by the cwd hazard: `hist_load`/
`hist_save` chdir, which would break the viewer's RELATIVE `f_open(namebuf)`, so **main** runs them
around `view_file` (load before + `chdir(pathbuf)` to restore; save after) and passes the primed count
as `view_file(&namebuf, histcount)` (255 = history off). `read_find` (xsyntax, bank 9) uses only the
cwd-SAFE bank-3 ops it declares itself - `hist_get` (up-arrow inline cycle 0..count-1, wraps) and
`hist_store` (on ENTER) - never hist_load/save. Count threads main -> view_file (tview `vhist`) ->
read_find. bank 9 had 5 KB free; bank 2 (tview) was FULL - the find-history threading overflowed it by
15 B, reclaimed by dropping the encoding footer's live ISO/PET mode label (build 197) to a fixed "ISO"
key hint. **Build 199:** the Find prompt shows a right-justified `↑ Recent` hint (find_recall_hint in
xsyntax) whenever history exists, so the key is discoverable. Original design notes below.

---

**Backlog (added 2026-07-24).** The text viewer's in-file **Find** prompt should get **up-arrow input
history** (recall previous search terms), the same way every XFMGR main prompt does ([[xfmgr-find-file]]
and the shared-history note: "UP-arrow in any input pops up a scrollable picker", xfmgr.p8 ~214).

**Where it lives / the wrinkle:** the viewer find prompt is `read_find` in **xsyntax.p8 (bank 9)** (~88,
entry `$A00F`, called by tview via `syn_read_find`). It is a self-contained mini line-editor -
ENTER/ESC/backspace/printable only, **no up-arrow ($91 / key 145) handling today** (see the key loop
~106-132). It was pushed into bank 9 purely because tview's own bank ran out of space.

Meanwhile the **history ring + its ops live in the miscutil overlay (bank 3)** behind the `hist_*`
extsubs (`hist_load`/`hist_store`/`hist_save`/`hist_get`, xfmgr.p8 ~305-308), and the scrollable
**picker UI** (`hist_draw_row` etc.) lives in MAIN RAM (xfmgr.p8 ~2422). So wiring history into read_find
crosses banks.

**How to build (sketch):**
- Add an up-arrow branch to `read_find`'s key loop. Two viable designs:
  1. **Inline cycle (simplest):** on up-arrow, JSRFAR into bank 3 to `hist_load(cat, instdir)` (once) then
     `hist_get(slot, &buf)` and drop the entry straight into the find field, cycling on repeated presses.
     Bank-to-bank JSRFAR is legal ([[x16-bank-to-bank-jsrfar]]); and MAIN low RAM (the receive buffer, e.g.
     the existing `hist_line`) is visible from bank 9 - only the $A000-$BFFF window is bank-private
     ([[xfmgr-overlay-ram-strategy]]). No picker box needed.
  2. **Full picker:** reuse main's popup. Cleaner UX but read_find is nested two banks deep (main -> tview
     bank 2 -> xsyntax bank 9); likely means returning a sentinel up to main to run the picker, then
     re-entering. More plumbing.
- **Category:** main's Ctrl-F find-FILE prompt already uses the "find" category. The viewer's in-file find
  is different semantics - consider its own cat (e.g. "viewfind") so file-name searches and in-file text
  searches don't share a ring. Persisted as `hist/viewfind.his` under the install dir like the others.
- **Encoding caveat:** read_find stores keys RAW as PETSCII (the fold to ASCII happens later in tview's
  `view_fold`, xsyntax.p8 ~94-96). History entries are stored/recalled in that SAME raw form, so a
  recalled term must go into the field pre-fold - don't double-fold ([[prog8-ascii-file-byte-match]]).
- Guard: if the miscutil overlay isn't loaded (`misc_ok` false), skip history silently, exactly as
  `input_line` does (xfmgr.p8 ~304).

Pairs with the other viewer backlog items ([[xfmgr-viewer-iso-pet-toggle]], [[xfmgr-viewer-line-gutter]])
and the possible file-content search ([[xfmgr-file-text-search]]). Scope: small-medium (the cross-bank
call is the only non-trivial part).
