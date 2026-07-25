---
name: xfmgr-file-text-search
description: "Backlog: search for TEXT CONTENT inside files (grep-style), distinct from the existing find-file-by-name crawler"
metadata:
  node_type: memory
  type: project
  originSessionId: 50cbdaf9-8664-4cd5-8a51-deebebebd509
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
