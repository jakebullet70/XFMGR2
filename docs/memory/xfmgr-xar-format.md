---
name: xfmgr-xar-format
description: The custom .XAR archive format + xar.ovl overlay (create/browse/extract, RLE, X16-to-X16)
metadata:
  type: project
---

XFMGR2 has custom **.XAR archive support** (build 126, branch `feature/xar-archive-support`).
X16-to-X16, RLE only — NO ZIP/ARC (the path chosen instead of [[xfmgr-zip-arc-v2]]).

**Overlay:** `SRC/xar.p8` -> `xar.ovl`, HIRAM **bank 6** (`XAR_BANK`); `xarena.FIRST_BANK`
bumped 6->7 so the arena starts at bank 7. Uses the prog8 stdlib `compression` module
(`encode_rle`/`decode_rle` = ByteRun1/PackBits). Same overlay pattern as miscutil. Fits the
bank easily (tops at ~$B6BB < $BF00). Entries (extsub @bank 6): xar_open/xar_name/xar_blocks/
xar_trunc/xar_extract/xar_create_begin/xar_create_add/xar_create_end.

**On-disk format (all little-endian, fully SEQUENTIAL — no seek):**
```
"XAR1" magic ($58 $41 $52 $31)
member_count (1 byte)
then member_count PAYLOADS, each = RLE blocks:
    raw_len(2)  -- 1..CHUNK(250); 0 ends the payload
    enc_len(2)  -- only if raw_len!=0
    enc[enc_len] -- ONE self-contained PackBits stream (encode_rle is_last_block=true)
then DIRECTORY: member_count of { blocks(2), name_len(1), name[name_len] }
```
Per-block framing (each block an independent PackBits unit of known raw size) is what lets
extract decode block-by-block into a fixed 250-byte buffer regardless of file size. Browse/
extract re-read from the front (skip payloads) — O(size) but seek-free & hostfs-robust.

**UX:** file-pane **ENTER** on a file whose first 4 bytes are the magic (`file_is_xar` sniff in
main, name-encoding independent) -> **overlay-owned** `xar_browse(nameptr)` modal: it opens/
validates, lists members (Up/Dn/PgUp/PgDn), **Enter**=extract highlighted into the archive's OWN
dir, **A**=extract all, ESC/Q close — the whole modal (frame + key loop + extract) runs IN the
overlay (textio + shared-const imported there; local px_* copies of bar_fill/hilite_row/
print_trunc/blank_span; own GETIN2 key loop). Returns 0 if not a valid archive (main flashes),
then main restores `txt.color2` + repaints. File-pane **`a`** key (shown in the menu) ->
`op_archive()`: create a .xar from the tagged files (or the highlighted one) in the current dir;
auto-appends `.xar`; caps at **64 members** (overlay MEMBER_MAX), name cells 24B via a `memory()`
slab (prog8 arrays cap at 256 elems). Create is append-only (write ch13 + read ch12 both open,
like `miscutil.do_stream_copy`).

**RAM:** the modal UI now lives in the overlay (b128). Main free-to-$9F00 ~1.8 KB; the xar bank
tops at ~$BD62 (~414 B headroom under $BF00) — trim MEMBER_MAX 64->48 (+384 B) if it needs more.

**KNOWN FOLLOW-UP:** extract has no dest-dir picker or overwrite confirm yet (writes into the
archive's dir, silently overwriting). See [[xfmgr-overlay-ram-strategy]], [[always-report-mem-stats]].
