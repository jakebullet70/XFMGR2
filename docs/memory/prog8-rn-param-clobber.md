---
name: prog8-rn-param-clobber
description: "Never pass a function CALL as an argument to a sub with @Rn params - the first arg is stored into r0 before the second is evaluated, and the call clobbers it. No compiler warning."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a31951ee-0367-4b90-ba73-026b129abe1f
  modified: 2026-07-18T18:07:53.757Z
---

In prog8, calling `f(a, g())` where `f` declares virtual-register parameters
(`sub f(uword x @R0, uword y @R1)`) is UNSAFE whenever `g()` touches r0-r3.
`strings.*` and `diskio.*` all clobber r0-r3.

The compiler stores the first argument into r0 and only THEN evaluates the
second, so the call destroys it:

    hist_save(histname, themes.progdir_cd())

    lda p8v_histname / sta cx16.r0     ; histname -> R0
    jsr themes.progdir_cd              ; CLOBBERS r0
    sta cx16.r1
    jsr cx16.JSRFAR                    ; hist_save(R0 = garbage, R1 = ok)

**Why:** prog8's argument evaluation order is unspecified and it emits NO
warning for this. It cost a full debugging session on XFMGR2 build 190: the
history folder appeared (mkdir took a literal) but no file was ever written,
because the filename was built from a garbage pointer. Passing a constant
like `&xtree.base_path` had always been safe, which is why the bug only
appeared when the constant became a function call.

**How to apply:** hoist every call-valued argument into a local first --
`uword histdir = themes.progdir_cd()` -- then pass the local. When touching
any `extsub @bank` / `@Rn` call site, read the generated `build/*.asm` and
confirm the r0/r1 loads are back-to-back with no `jsr` between them.
Applies to all overlay entry points, since they all use `@Rn` params.
See [[xfmgr-overlay-ram-strategy]], [[x16-bank-to-bank-jsrfar]].
