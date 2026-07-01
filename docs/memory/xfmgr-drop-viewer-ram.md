---
name: xfmgr-drop-viewer-ram
description: "DONE (2026-07-01): pulled internal xviewer from XFMGR2 (+3.1 KB free); code preserved as standalone SRC/tview.p8"
metadata: 
  node_type: memory
  type: project
  originSessionId: b8fa7cc6-ce21-49c0-9d7e-f50a35429b63
---

**APPLIED 2026-07-01.** Pulled the internal viewer from XFMGR2. Code first saved as the
self-contained standalone program **SRC/tview.p8** (own main/buffers/helpers, opens a
filename directly, no editor fallback; compiles to tview.prg ~3637 B) - the seed for a
future CALLABLE viewer. Then in xfmgr.p8: `handle_file 'v'` -> `op_edit()` (View opens
X16 Edit like E), `%import xviewer` removed, **SRC/xviewer.p8 deleted** (module form is in
git; tview.p8 is the live copy). Free RAM **705 B -> 3846 B**.

**A/B measurement** (viewer in vs. `handle_file 'v'` -> `op_edit()` + `%import xviewer`
removed; `%option ignore_unused` drops the now-unreferenced module):

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

**What's lost in XFMGR:** read-only paged viewer (V), hex toggle (H), in-file search
(F/N) - all still live in SRC/tview.p8. V now opens X16 Edit like E (editable; can alter
files), no hex, no search. **tview.p8 TODO:** filename hand-off from XFMGR, large-file
(>64 KB) handling, optional path/chdir.

Related: [[xfmgr-ram-savings-menu]], [[xfmgr-editor-bank-handoff]].
