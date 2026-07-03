---
name: prog8-diskio-vendored-patch
description: "SRC/diskio_patched.p8 is a vendored+bounds-fixed copy of prog8's diskio; imported as diskio_patched because prog8 won't let a source file shadow an embedded library by name"
metadata: 
  node_type: memory
  type: project
  originSessionId: f3d00c60-c71e-4045-88f8-0aa07cdf93f6
---

Added 2026-07-03 while fixing the [[xfmgr-find-file]] crash. **`SRC/diskio_patched.p8` is a
vendored copy of prog8 v12.2.1's bundled `prog8lib/cx16/diskio.p8`** (extracted from
`prog8c.jar`) with ONE change: `internal_next_entry()` now BOUNDS the directory-entry filename
read. Upstream copies the listing name into `list_filename` (a **50-byte** buffer) with **no
length check**, so a filename longer than the buffer overruns it and corrupts adjacent memory.
The whole-disk Find crawl lists every directory (incl. sample folders with 55-58 char hostfs
names like `CYCLOPS-…1977.pdf`); in the bank-3 overlay `list_filename` sits just before the
history ring, so the overrun corrupted history state and crashed on the **next input prompt**
(the crash repro was: search → jump → change file filter). Patch: cap the stored name at 51
chars (+NUL), keep consuming to the closing quote to stay in sync with the channel; grow
`list_filename` to 52 to match `xfiles.NAME_RD_CAP` / `xarena.read_str`'s 51-char cap so name
handling truncates uniformly at 51 everywhere (no crash; names >51 chars truncate in copies only).

**prog8 gotcha — you CANNOT shadow an embedded library module by filename.** Dropping
`SRC/diskio.p8` (same name) does nothing: `%import diskio` always resolves to the embedded
`prog8lib/cx16/diskio.p8`, even with `-srcdirs SRC`. Verified by grepping the generated `.asm`
for a marker var (`fnlen`) — absent = the embedded one was used. **The working pattern:** name
the file something NON-embedded (`diskio_patched.p8`) but keep the block inside named `diskio`,
then change every `%import diskio` to `%import diskio_patched` (7 sites: xfmgr, xtree, xscan,
themes, tview, miscutil, xfsetup). All `diskio.*` call sites stay unchanged. Confirm the patch
took by grepping `xfmgr.asm` AND `miscutil.asm` for `fnlen` (must appear in both — main + the
crawl overlay). Cost: image +8 B, still ~3.8 KB low-RAM free.

**On prog8 upgrade: RE-FORK.** Re-extract the new bundled `diskio.p8`
(`unzip -p prog8c.jar prog8lib/cx16/diskio.p8`), re-apply just this bounds patch, keep the
`diskio_patched.p8` name + `diskio` block. See the loud header comment in the file.
