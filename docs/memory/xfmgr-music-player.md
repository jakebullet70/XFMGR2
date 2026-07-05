---
name: xfmgr-music-player
description: "How XFMGR plays .zsm and .wav files - P key, zsmkit engine in bank 6, xmusic WAV overlay in bank 7"
metadata:
  type: project
---

FILE-pane **P** plays music (added on the `music-playback` branch, build 163). Detection is by
MAGIC BYTES via `sniff_kind()` in xfmgr.p8 (0=other 1=bmx 2=zsm 3=wav), NOT extension — hostfs
returns lowercase ascii names (same reason as [[xfmgr-bmx-image-viewer]]). ZSM=`7a 6d`@0,
WAV="RIFF"@0+"WAVE"@8. `sniff_kind` replaced the old `file_is_bmx`; V uses it too.

**ZSM (bank 6):** `zsmkit.bin` = the vendored zsmkit v2 blob (release 2.8,
docs/prog8/examples/zsmkit_v2/ZSMKIT-A000.BIN, mooinglemur/zsmkit), loaded at $A000 in bank 6 via
`loadlib` like the overlays. Called from MAIN only (a banked overlay can't `extsub @bank` a
*different* bank — the trampoline would sit in the caller's own blob). `play_zsm()` in xfmgr.p8
runs the whole loop: waitvsync + zsm_tick(0) + key poll. Jump-table offsets ($A000 init, $A003
tick, $A006 play, $A009 stop, $A00F close, $A01B setbank, $A01E setmem, $A02A getstate) are a
stable append-only ABI — match docs/prog8/examples/zsmkit_v2/zsmkit.p8.

**Two gotchas that shaped play_zsm:**
1. zsmkit's ~255 B low-RAM scratch lives in golden RAM `$0400` (zero main-RAM cost), but X16 Edit
   also uses $0400-$07FF, so `zsm_init_engine($0400)` runs at the TOP OF EVERY play, not once.
2. The whole song must be RESIDENT. It's loaded (KERNAL LOAD auto-wraps banks) into banks BORROWED
   at `xarena.high_bank+1` upward — exactly like op_edit lends banks to X16 Edit. Modal loop => the
   arena can't grow meanwhile; banks are abandoned after. MANDATORY guard `blocks/32+1 <= free
   banks` (bank 64 aliases bank 0 on 512 KB → corruption if a big song overruns).

**WAV (bank 7):** `SRC/xmusic.p8` — self-contained `%output library` overlay (ximgview template),
`play_wav(nameptr @R0) -> ubyte` ($A003; 0=ok 1=open-err 2=unsupported). Streams uncompressed PCM
(8/16-bit, mono/stereo, ≤48828 Hz) to the VERA FIFO by POLLING the AFLOW bit (no IRQ, so VERA_IEN
untouched / GETIN keeps working); 1 KB in-bank staging buffer; 8-bit XOR $80 (unsigned→signed);
rate = Hz/381+1. FIFO-fill asm lifted from docs/prog8/examples/pcmaudio/stream-simple-poll.p8.
ADPCM NOT yet supported (M4 backlog: vendor adpcm.p8 with `@requirezp` stripped — it collides with
the overlay's `%zeropage dontuse`).

**Controls (both):** SPACE pause/resume, Q/ESC/STOP stop. Missing zsmkit.bin/xmusic.ovl → P flashes
and does nothing (V on a .zsm still shows tview's header breakout). Assets staged by run.bat;
build.bat builds xmusic.ovl. Main RAM is TIGHT after this: **~507 B free** (bank map + overlay
strategy in [[xfmgr-overlay-ram-strategy]]).
