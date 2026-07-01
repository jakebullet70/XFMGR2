---
name: always-report-mem-stats
description: User wants the build memory-stats block included in responses
metadata:
  type: feedback
---

After any build of XFMGR2, include the memory-stats summary in the reply to the user
(at least main RAM used + high-water address + free bytes; the full block when it's handy).

**Why:** main RAM is tight on the X16 (~38 KB usable from $0801) and the user actively tracks
the high-water as features are added.

**How to apply:** `build.bat` prints the block (parsed by memstats.ps1) - surface those numbers
in the response, don't just say "built clean". Watch the high-water climb toward $9F00. See
[[prog8-static-variable-allocation]] and [[xfmgr-run-and-persistence]].
