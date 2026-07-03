---
name: xfmgr-bump-build-and-run
description: "Standing workflow — after any code change, bump BUILD_NUM then build+run so the user can test"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

After making ANY code change to XFMGR, before handing back: bump `BUILD_NUM` in `SRC/xfmgr.p8`
(the `const ubyte BUILD_NUM` near the top, ~line 42) by 1 **AND** update the matching About-screen
string `aboutln(7, "Version 1.0.N")` in `SRC/uiutil.p8` (~line 327) to the same N — they must stay
in sync (shown top-right as "build N" and on the About modal as "Version 1.0.N"). Then run `run.bat`
(compiles via build.bat, stages into run\xfmgr\, and launches the emulator). Do NOT stop at building.

The build number is hardcoded in BOTH places (not threaded through the uiutil overlay's extsub
boundary) — the user explicitly rejected passing it as a param (2026-07-03); just edit both strings
each build.

**Why:** BUILD_NUM shows top-right on the XFMGR frame; bumping it lets the user confirm at a glance
that the emulator is running the FRESH binary and not a stale one. The user asked for this
explicitly (2026-07-03) and wants to test in the emulator themselves.

**How to apply:** Edit BUILD_NUM (+1), then `& ".\run.bat" xfmgr.p8` from the repo root. run.bat is
non-blocking (START launches the GUI) — report the new build number and what to check, don't drive
the GUI. The `'Fastboot++\' is not recognized` line at the top of build/run output is a harmless
stray PATH echo, not an error. Include the build memory-stats block in the reply
([[always-report-mem-stats]]). Related: [[prog8-build-toolchain]],
[[user-tests-in-emulator-themselves]].
