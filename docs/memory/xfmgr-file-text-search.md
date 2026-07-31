---
name: xfmgr-file-text-search
description: "DONE build 205-212: S in the GLOBAL browser content-searches TAGGED files, untagging non-matches (XTree Ctrl-S 'search prunes the tag set')"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
---

**DONE build 205-212 (2026-07-31).** Built on the **XTree Ctrl-S model**: search does NOT make its own
results list - it **prunes the tag set**. In the GLOBAL browser ([[xfmgr-showall-revisit]]) press **S**;
it scans the currently-TAGGED files and UNTAGS every one whose CONTENTS don't contain the term, so only
matches stay tagged (press T to view just them). Untagged rows are ignored - tag candidates first
(`Ctrl-T`/`Ctrl-W`/`Space`), which also bounds the cost.

The per-file byte scan is `content_scan(dir,name,term)` in the **miscutil overlay** (bank 3, jmptable
entry $A021; main declares the matching `extsub @bank 3 $A021`). It opens the file with the overlay's own
diskio, streams 255-byte chunks through `cpbuf`, and matches with the same naive persistent-`mi` matcher
tview's `view_find_at` uses (mi carries across chunk boundaries, so a hit spanning a read boundary is not
missed) - but with an **encoding-agnostic fold** (`fold_byte`) mapping ASCII A-Z, PETSCII a-z ($41-5A
both), PETSCII A-Z ($c1-da) and ASCII a-z all to one lowercase, so a PETSCII-typed term matches ASCII or
PETSCII bytes ([[prog8-ascii-file-byte-match]]). `content_search_prune` drives it (build_path+sa_name per
file, live "Scanning n/N (any key aborts)" counter). Term capped at 32 (SCAN_TCAP == input_line maxlen).
The one search bug an adversarial review found: `input_line`'s `box_close()` repaints the normal frame
over the modal, so `content_search_prune` now repaints the browser before scanning. Original notes below.

---

**Backlog (added 2026-07-24).** Add **file text (content) search** to XFMGR - find files whose CONTENTS
contain a typed string, grep-style. This is distinct from what already ships:
- **Find file (Ctrl-F)** matches on the FILE NAME across the disk ([[xfmgr-find-file]]).
- The **text viewer** already has an in-file find (search within the one open file, prompt lives in the
  xsyntax overlay - [[xfmgr-syntax-coloring]]).

So the new piece is **searching the BYTES of files for a substring** and reporting which files (and
ideally which line) contain it - a cross-file grep, not a filename match and not limited to the open file.

**How to build (sketch):**
- Reuse the whole-disk crawler shape from Find-file ([[xfmgr-find-file]]): walk logged/known dirs, but
  instead of testing the filename, OPEN each candidate file and scan its bytes for the search term.
- Case/encoding: the term is typed in PETSCII; file bytes may be ASCII or PETSCII. Fold both to a
  canonical range before comparing (same lesson as [[prog8-ascii-file-byte-match]] and MSEDIT's
  encoding-agnostic syntax fold) so a match works regardless of the file's encoding.
- Guard cost: opening + scanning every file is slow and risky on binaries. Consider a size cap, a
  *.txt/*-ish filter (or the current filespec), and a way to bail (any key) mid-crawl - mirror the live
  counter Find-file/Prune already show ([[xfmgr-prune-command]]).
- Result UI: a flat modal list of matching files with jump-to-file, like Find-file's match list.
- Watch overlay RAM: the crawler + viewer are already tight (find prompt had to move to bank 9,
  [[xfmgr-syntax-coloring]]); a content grep may want its own overlay slot ([[xfmgr-overlay-ram-strategy]]).

Ties into the "whole-disk flat browser" idea in [[xfmgr-showall-revisit]] - both are disk-wide crawls.
Scope: medium (crawler exists; the new work is the per-file byte scan + result plumbing).
