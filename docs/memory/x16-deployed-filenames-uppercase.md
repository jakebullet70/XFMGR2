---
name: x16-deployed-filenames-uppercase
description: "Files the X16 program opens by name must be UPPERCASE on disk; the emulator's case-insensitive host-fs hides the bug until real hardware"
metadata: 
  node_type: memory
  type: project
  originSessionId: a31951ee-0367-4b90-ba73-026b129abe1f
  modified: 2026-07-18T07:41:20.179Z
---

**Every file an X16 prog8 program opens by name must be UPPERCASE on disk.**

Why: prog8's default PETSCII encoding maps a lowercase source literal's `a-z` to bytes **$41-$5A**,
which are the **uppercase ASCII** letters. Those are the bytes handed to the filesystem to match. So
`diskio.loadlib("xsyntax.ovl", ...)` - correctly written lowercase in source, per
[[prog8-filename-literals-lowercase]] - is actually asking the FS for `XSYNTAX.OVL`.

The two rules are complements, not contradictions:
- **source literal: lowercase** (so it encodes to $41-$5A)
- **file on disk: UPPERCASE** (so it matches those bytes)

**Why this hides:** the emulator's Windows host-fs is case-insensitive, so a lowercase file works
there and only fails on a real SD card / case-sensitive FS. Worse, `COPY /Y` on Windows overwrites
content but KEEPS an existing destination file's name casing - so a stale uppercase file from an old
install can mask a staging script that specifies lowercase destinations. XFMGR's `run.bat` had
exactly that latent bug: every overlay was uppercase on disk only by accident, and wiping
`run/xfmgr/` would have regenerated them all lowercase.

**Fixed 2026-07-18:** `run.bat` now names every staged destination explicitly in UPPERCASE
(`XFMGR.PRG`, `TVIEW.OVL`, `MISCUTIL.OVL`, `UIUTIL.OVL`, `XIMGVIEW.OVL`, `XMUSIC.OVL`,
`XSYNTAX.OVL`, `XFSETUP.PRG`, `ZSMKIT.BIN`, `XFMGR.HLP`, `XFMGR.CFG`, `INSTALL.PRG`). `build/` stays
lowercase - it is an intermediate dir nothing on the X16 reads from; the staging COPY is the
boundary where naming has to become correct. **Verify by deleting `run/xfmgr` + `run/RELEASE` and
re-running `run.bat`** - if the names come back lowercase, the fix regressed.

`SRC/install.p8`'s `FILES` manifest stays lowercase: those are prog8 literals, so they encode to the
uppercase bytes and match correctly.
