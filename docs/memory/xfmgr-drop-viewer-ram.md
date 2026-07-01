---
name: xfmgr-drop-viewer-ram
description: "Measured RAM gain from removing the internal xviewer and routing View to X16 Edit: ~3.1 KB (biggest single reclaim)"
metadata: 
  node_type: memory
  type: project
  originSessionId: b8fa7cc6-ce21-49c0-9d7e-f50a35429b63
---

**Option: pull the internal viewer (SRC/xviewer.p8), route View (V) to X16 Edit.**
Measured by an A/B build (2026-07-01, viewer in vs. `handle_file 'v'` -> `op_edit()` +
`%import xviewer` removed; `%option ignore_unused` drops the now-unreferenced module):

| | with viewer | viewer pulled | gain |
|---|--:|--:|--:|
| code (image) | 30355 B | 27492 B | **-2863 B** |
| vars (BSS) | 3944 B | 3666 B | **-278 B** |
| free to $9F00 | 705 B | **3846 B** | **+3141 B (3.1 KB)** |

**This is the single largest reclaim available** — bigger than the whole cold-bank move
(~1.6 KB) and needs no bank plumbing. BSS saved is dominated by `view_pages[100]`=200 B.

**Free / no new code:** `op_edit` (X16 Edit) already exists as the viewer's large-file
fallback, so View just repoints to it. `viewbuf`/`namebuf`/`pathbuf` are shared with the
copy path (main module), so they are NOT reclaimed and NOT lost.

**What's lost:** read-only paged text viewer (V), hex-dump toggle (H), in-file
case-insensitive search (F/N). After the change V opens X16 Edit like E — editable (can
accidentally alter files), no hex, no search. Decision pending: the viewer is a real
feature; only pull it if the 3.1 KB is needed more than read-only view/hex/search.

To execute: `handle_file 'v'` -> `op_edit()`; delete `%import xviewer` (line ~18) and
`SRC/xviewer.p8` from the build. Related: [[xfmgr-ram-savings-menu]], [[xfmgr-editor-bank-handoff]].
