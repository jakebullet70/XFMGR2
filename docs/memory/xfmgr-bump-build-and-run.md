---
name: xfmgr-bump-build-and-run
description: "Standing workflow — bump the build number in ONE place; build.bat auto-levels all four locations to the max, then run+test"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 56145960-9e23-49e7-aaf2-33a3aa6dab39
---

After making ANY code change to XFMGR, before handing back: **bump the build number by 1** — the
simplest is `const ubyte BUILD_NUM` in `SRC/xfmgr.p8` (~line 42) — then `build.bat` **then** `run.bat`.
Do NOT stop at building; the user tests in the emulator themselves ([[user-tests-in-emulator-themselves]]).

**As of 2026-07-24 the bats are split by responsibility (user request):** `build.bat` = compile only
(it owns the BUILD_NUM sync + memstats), `run.bat` = **stage-and-launch only, it no longer compiles**
(copies `build\` into `run\`, then starts the emulator; errors out if `build\xfmgr.prg` is missing),
`release.bat` = build + zip. So the test loop is now two commands: `build.bat` then `run.bat`.

**You no longer hand-edit the number in every file.** `build.bat` calls `syncbuild.ps1` (repo root)
BEFORE the compile, on full builds only (`SRC==xfmgr.p8`). It reads the build number from all FOUR
places, takes the **largest**, and levels the others UP to it (byte-preserving Latin-1 rewrite, so
PETSCII bytes in the `.p8` sources and UTF-8 in the README survive — only the ASCII digits change):

| File | Field | Shown as |
|---|---|---|
| `SRC/xfmgr.p8` | `BUILD_NUM = N` | "build N" top-right on the frame |
| `SRC/uiutil.p8` | `aboutln(7,"…Version 1.0.N")` (~line 330) | About modal |
| `README.md` | `*(build:N)*` near the top | GitHub readme |
| `xfmgr.hlp` | `(Build N)` on line 2 | F1 help header |

So bump **any one** of them and the next build propagates it to the rest. Running before the compile
means THIS build's binary already shows the synced number (don't move the call back after the java
compile — that reintroduces a one-build lag on the frame/About). The number is still hardcoded per
file (not threaded through the uiutil overlay's extsub boundary — the user rejected a param on
2026-07-03); `syncbuild.ps1` is what keeps them in step.

**Why:** the build number top-right lets the user confirm at a glance the emulator is running the
FRESH binary, not a stale one (asked for explicitly 2026-07-03). "Largest wins" means a bump in any
file can't be silently lost to a lower value elsewhere.

**How to apply:** edit BUILD_NUM (+1), then `& ".\build.bat"` and `& ".\run.bat"` from the repo root
(build first — run.bat only stages+launches now). run.bat is non-blocking (START launches the GUI) —
report the new build number + what to check, don't drive the GUI. Include the memory-stats block ([[always-report-mem-stats]]). syncbuild.ps1 / build.bat / run.bat
are part of the (currently uncommitted) installer WIP as of 2026-07-06. Related:
[[prog8-build-toolchain]], [[xfmgr-architecture]].
