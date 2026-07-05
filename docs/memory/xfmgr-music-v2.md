---
name: xfmgr-music-v2
description: Backlog — music-player polish for XFMGR2 V2 (ADPCM wav, elapsed time, README, RAM)
metadata:
  node_type: memory
  type: project
  originSessionId: 07398a8c-7c3c-4b07-a3ef-a106987a1081
---

**Feature note (music-player M4 polish — V2).** The .zsm/.wav player landed on the
`music-playback` branch (build 163, P key) with PCM WAV + ZSM playback working — see
[[xfmgr-music-player]]. These M4 items were deferred to keep the first cut reviewable and
were captured 2026-07-05.

**Backlog items, roughly smallest→largest:**
- **README.md** — document zsmkit provenance (mooinglemur/zsmkit, ZSMKIT-A000.BIN rel 2.8 →
  `zsmkit.bin`) and add `SRC/xmusic.p8` / `xmusic.ovl` + `zsmkit.bin` to the file-list / overlay
  section. Note the two new reserved banks (6=zsmkit, 7=xmusic; arena now 8..max_bank).
- **ADPCM WAV support** — the biggest item. `xmusic.p8` currently rejects compressed wavs
  (`unsupported()` allows PCM `w_fmt==1` only). To add IMA/DVI-ADPCM: vendor `SRC/adpcm-ovl.p8`
  = a copy of `docs/prog8/cx16/adpcm.p8` with its six `@requirezp` vars stripped (they collide
  with the overlay's `%zeropage dontuse` → hard compile error otherwise). Accept `w_fmt==17`
  (DVI_ADPCM) only when `block_align==256`; read 512 B/AFLOW and decode 2 blocks with
  `decode_block_mono/stereo` straight into `VERA_AUDIO_DATA` (pattern in
  docs/prog8/examples/pcmaudio/stream-wav.p8). If high-rate ADPCM underruns without ZP, cap
  accepted ADPCM at ~24 kHz. A ready test asset already exists: `samples/adpcm-mono.wav`.
- **Elapsed MM:SS** — ZSM: cheap (~80 B main) frame-counter / 60 shown on the status row. WAV:
  needs division by byte-rate; skip or do coarsely.
- **Real-SD throughput** — 48 kHz stereo 16-bit WAV is borderline on real hardware (~5-10 ms
  AFLOW window). If stutter is reported, double the in-bank staging buffer to 2 KB (bank 7 has
  room) to halve per-read overhead. Fine in the emulator.
- **Volume / seek** — nice-to-haves; zsmkit exposes `zsm_setatten`/`zsm_setrate`; WAV has no seek
  (sequential f_read) without re-open+skip.

**Watch when picked up:** main RAM is TIGHT after M1-M3 — **~507 B free to $9F00** (build 163).
ADPCM lives in the overlay (bank 7, near-zero main cost), but any main-side additions (elapsed
time, extra strings) eat that. Reclaim headroom first if needed via the lever-2 backlog
(input_line/hist_popup → overlay, ~2 KB) noted in [[xfmgr-overlay-ram-strategy]].
