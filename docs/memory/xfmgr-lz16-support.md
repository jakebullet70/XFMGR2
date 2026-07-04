---
name: xfmgr-lz16-support
description: LZ16 vs XAR2, the mklz16.py desktop builder, and the 3-tier cost estimate to support .LZ16 in XFMGR
metadata:
  type: project
---

**LZ16 is a DIFFERENT format from XAR2 — two containers, one codec.** LZSA2 is just the
compression algorithm (the only thing the X16 ROM `memory_decompress` $FEED can decode).
Two independent file wrappers use it:
- **XAR** (ours, [[xfmgr-xar-format]]): magic XAR1(RLE)/XAR2(LZSA2), 250-byte blocks,
  built into XFMGR (Enter browses), XFMGR-private (only XFMGR reads; XAR2 authored only by
  `tools/mkxar2.py`).
- **LZ16** (Anthony Henry's, in `tools/CPLZ-APPS/`): magic `LZ16`, CBM-float sizes, big
  chunks up to ~60 KB VRAM-streamed, optional inner **cpio** for multi-file. Public spec
  (`LZ16-COMPRESSED-FORMAT.TXT`) + public reader (`xcplz.prg`). NOT wired into XFMGR.

**`tools/mklz16.py` (DONE):** console-independent desktop LZ16 builder — single-file mode.
Calls `lzsa -r -f2` per chunk via subprocess, self-verifies each round-trips, writes header
+ `zc` chunk frames. Header is **byte-identical to MAKECPLZ** for the same input+CS (verified
on test.txt). CBM-float encode: expbyte = e+129 where e=bitlen-1; trueM = n<<(31-e); store
expbyte + (trueM & 0x7FFFFFFF) big-endian. Default CS=45000; sizes little-endian in header.
Replaces `MAKECPLZ.exe`, which **hangs headless** (its qb64pe internal SHELL-out to lzsa
blocks with no console; only writes the 19+name header then stalls). Multi-file LZ16 is
authorable off-device today: `tar -cf x.cpio --format=newc <folder>` then `mklz16.py`.

**LZ16 read path (from xcplz `LZFILES.p8`/`cpio.p8`):** parse 19B header; per chunk read
`zc`+size via MACPTR, stream compressed bytes into VRAM, `memory_decompress_from_func` with a
custom VRAM-streaming feeder (`GET_LZDATA` asmsub, 256B cache) VRAM->VRAM; copy VRAM->bank
`$A000` in 4KB blocks then MCIOUT to disk. Flips VERA text/graphics layers for big buffers.
If output is `.cpio` -> `cpio.p8` unpacks members.

**COST to support .LZ16 IN XFMGR (backlog, estimate):**
- **Tier 1 — launch xcplz.prg + return (~1/2 session, ~50 lines, 0 new banks):** Enter on
  `.LZ16` -> swap-and-relaunch to XCPLZ.PRG (like the editor handoff [[xfmgr-run-utils-and-return]]),
  return to XFMGR after. Full feature incl cpio TODAY. Catch: XCPLZ prompts for filename via
  input_chars and the dynamic-keyboard chain buffer is only 10 bytes ([[x16-launch-program-dynamic-keyboard]]),
  so either user types it or patch XCPLZ (we have source) to read the target from a tiny file
  XFMGR writes. Downside: it's XCPLZ's screen, not an XFMGR modal.
- **Tier 2 — native single-file overlay (~1-2 sessions, +1 overlay bank, ~0 main RAM, ~300-350
  lines):** port LZFILES+Chunk into a new bank (7; bump xarena.FIRST_BANK->8) like xar.ovl.
  KEY: **drop the `floats` dependency** (Def/Last_Chk_Size are already uwords; decode NumChks
  with a ~15-line CBM-float->uword) so it fits a 7.9 KB overlay. Real risk = **VERA/VRAM state
  juggling** (XFMGR's text UI lives in VRAM; decompressor uses VRAM bank 1 + flips layers) —
  needs careful save/restore so the file pane survives.
- **Tier 3 — + cpio multi-file (+1-2 sessions, likely +2 banks, ~400 lines):** port cpio.p8.
  No timestamps on hostfs regardless.

**RECOMMENDATION:** do **Tier 1 first** — cheapest, de-risks the format on real hardware
(`run/BIGTEST.LZ16` staged: 9999 B / 3 chunks CS=4096, stored name `bigtest.txt`, last line
`Line 200 -- LAST LINE -- ZZZ-END-OF-FILE-MARK-!!`; `run/XCPLZ.PRG` also staged). Only invest
in Tier 2 native overlay if the XCPLZ handoff feels clunky. LZ16 is the right target if the
goal is an INTEROPERABLE format others can make+read (vs XFMGR-private XAR). See
[[xfmgr-overlay-ram-strategy]], [[xfmgr-zip-arc-v2]].
