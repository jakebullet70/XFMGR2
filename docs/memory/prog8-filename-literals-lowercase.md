---
name: prog8-filename-literals-lowercase
description: prog8 string literals passed to KERNAL/diskio as filenames must be lowercase to match the X16 filesystem
metadata:
  type: reference
---

KERNAL/diskio filename & path literals in prog8 source must be written **lowercase**
(`"xfmgr"`, `"tview.bin"`), NOT uppercase.

Why: prog8's default cx16 PETSCII encoding maps **source lowercase a-z -> $41-$5A** — the
exact bytes BASIC's `LOAD`/the X16 host FS use to match names. Source **uppercase A-Z ->
$C1-$DA** (shifted PETSCII), which the FS does NOT match, so the file is silently "not found"
(`diskio.loadlib`/`load` returns $0000, `chdir` leaves cwd unchanged).

Hit this when `diskio.chdir("XFMGR")` did nothing and `loadlib("/XFMGR/tview.bin")` failed,
while `chdir("xfmgr")` correctly moved cwd to `/XFMGR` and the load returned a real end addr.
Confirmed via `-echo` capture: the uppercase literal echoed as `\xD8\xC6\xCD\xC7\xD2`.

Filenames coming from a diskio directory listing are already in the right encoding — only
hand-written string literals need the lowercase treatment. See [[xfmgr-run-and-persistence]],
[[x16-embedded-petscii-color-codes]].
