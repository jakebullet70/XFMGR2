---
name: x16-writes-land-in-cwd
description: "On the X16, LOAD and DOS SCRATCH accept an absolute path but OPEN-for-write does NOT - chdir in, write by bare name, chdir back"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b210f6d4-617b-4233-91f5-55349490611d
  modified: 2026-08-03T12:34:30.580Z
---

Learned 2026-08-03 (build 266) from "the theme setup won't save".

**The asymmetry:** an absolute path works for READING (`diskio.load_raw("/utils/xfmgr/xfmgr.cfg", ...)`)
and for DELETING (`diskio.delete` emits DOS `S:`+path, which the drive honours), but **not** for
`diskio.f_open_w` - a write open puts the file in the CURRENT directory regardless of the path you
hand it. So the pattern for writing any file is always: save `diskio.curdir()` into your own buffer
(it is transient), `chdir` to the target folder, `f_open_w(bare_name)`, then `chdir` back.

**Why it bites so hard:** the natural way to write this is delete-then-create (the portable
overwrite). The delete DOES take the path, so it succeeds; the create then silently does not. The
result is not "the save failed", it is **the existing file is gone** - which reads as a setting that
never persists rather than a write that never happened, and sends you looking in the wrong place.
`themes.cfg_write` did exactly this and destroyed `<progdir>xfmgr.cfg` on every save.

Every other writer here already had it right - `op_copymove` chdirs into the destination before
copying ("hostfs lands writes in the current dir"), `hist_save` chdirs before writing its ring,
`install.p8` writes bare names. If a new writer skips the chdir, this is the bug.

Related: [[xfmgr-color-theme-setup]], [[xfmgr-cfg-read-exists-guard]] (why the READ side uses LOAD
and never f_open), [[prog8-filename-literals-lowercase]] (the name bytes must match the disk).
