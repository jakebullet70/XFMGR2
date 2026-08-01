---
name: xfmgr-overlay-ram-strategy
description: "How XFMGR frees main RAM by moving code into bank overlays, current bank map, and what's left to move"
metadata: 
  node_type: memory
  type: project
  originSessionId: 34a3aff3-3870-4671-a1b8-ab8c9f46ea15
  modified: 2026-08-01T02:46:26.314Z
---

XFMGR is main-RAM constrained; the lever for headroom is moving cold code into HIRAM bank
overlays (%output library blobs, org $A000, loaded via diskio.loadlib, called via `extsub @bank`).

**Bank map** (see [[x16-banked-ram-min-config]], xarena.FIRST_BANK): 0=Kernal, 1=xtree dir-extras
(the 14-byte DX per-node record at $a000 - now also holds name_off/depth/parent, see below)
+ **xfiles' one FILE INDEX at $b000** (1024 * 4-byte rows, uword-indexed - since build 236 this is
THE index for directory listings, scoped views AND Find, not a ShowAll-only side table; see
[[xfmgr-showall-revisit]]), 2=tview (viewer), 3=miscutil
(wildcard/prune/history + stream_copy byte-pump + whole-disk Find crawler + content_scan),
4=uiutil (bottom dialogs + About/modal-box drawing),
5=ximgview (BMX image viewer, see [[xfmgr-bmx-image-viewer]]), 6=zsmkit v2 engine blob (ZSM
playback, see [[xfmgr-music-player]]), 7=xmusic (WAV/PCM streamer), **8=xtree dir-NAME slab**
(NAME_BANK, a DATA bank not an overlay - see below). Arena = banks **9**..max_bank (FIRST_BANK is
now 9). Each overlay keeps a fixed `%jmptable` at $A003+
(KEEP module vars UNINITIALIZED or they shove the table — see [[prog8-jmptable-init-vars-gotcha]]).

**As of 2026-07-03: 6.5 KB free to $9F00** (was ~2.2 KB before this push). Won by: copy byte-pump
-> miscutil.stream_copy (+deleted viewbuf), and the confirm/banner/prompt + About + command-menu
UI -> uiutil (~4.8 KB overlay in bank 4). uiutil entries: ui_flash/toast/ask_yn/ask_overwrite/
ask_confirm_each/ask_delete_this/banner_copymove/banner_delete/copy_diag/draw_box/box_header/
show_about/draw_commands (each an extsub @bank 4, main keeps thin wrappers).

**The UI-in-overlay pattern (reusable):** an overlay CAN own textio-heavy UI (tview/uiutil both
do; textio is cheap after dead-code elimination). Rules learned:
- The overlay is a SEPARATE blob: it can't call main's subs (xtree/xfiles/txt/draw_frame). It
  only uses its own strings/diskio/textio + KERNAL, and reads main RAM via passed POINTERS
  (main stays mapped below $A000). So only leaf-ish code moves cleanly.
- Keep frame plumbing in main: box_open/box_close (box_close -> draw_frame) and box_left stay
  (main status draws use them). Dialogs become thin main wrappers: box_open -> extsub -> box_close.
- Pass args in R0-R3; delegate the @Rn entry to an inner `str`-param sub so diskio/txt clobber of
  r0-r3 is harmless (miscutil/uiutil pattern). Normal subs can't declare `-> ubyte @A` (only the
  extsub decl in main names the return register).
- Guard every extsub call with the overlay's ok-flag (ui_ok/misc_ok) so a missing .bin degrades
  to a safe default instead of JSRFAR-ing into an unloaded bank.
- Filename/dir literals passed to diskio must be lowercase ([[prog8-filename-literals-lowercase]]).

**BIG WIN DONE (2026-07-05): dir-name slab -> bank 8.** `xtree.dname_buf` was a 3072-byte MAIN-RAM
`memory()` slab; it now lives in NAME_BANK (bank 8) at NAME_BASE=$a000 + `d_name_off[idx]` (names <=
~3072 B fit one 8 KB window, no roll). Freed ~2.9 KB main RAM (668 B -> 3539 B). Mechanism: added
`xarena.far_write_str` (inverse of read_str); `dname_store`/`rename_node` far-WRITE; **`name_ptr(idx)`
far-READS the name into a shared `name_stage` (str "?"*63) and returns THAT**, so every reader keeps
its plain `str` API unchanged (draw_tree/build_path/compares). INVARIANT: never hold a name_ptr result
across another name_ptr call - one staging buffer, each caller consumes it immediately (verified). This
was the "Tier B" name-slab move from [[xfmgr-architecture]]; hot draw_tree tolerates the per-row
far-read fine. See also [[xfmgr-ram-savings-menu]].

**BIG WIN DONE (2026-07-31): part of the d_* node pool -> the DX record.** The GLOBAL browser's
1024-file cap needed `uword` sa_ indices ([[xfmgr-showall-revisit]]), which cost ~830 B main RAM. Funded
by moving three of the redraw-hot `d_*` node-pool arrays into the existing per-node BANKED record (bank 1,
DX_BASE=$a000): DX_REC grew **7 -> 14 bytes**, adding name_off(+7)/depth(+9)/parent(+10), reached via new
`dx_noff`/`dx_depth`/`dx_parent` accessors (replaced `d_name_off`/`d_depth`/`d_parent` at all ~97 sites;
`name_ptr` and `build_path` now go through them). 254*14 = 3556 B ($a000..$ade4), clear of sa at $b000.
`d_first_child`/`d_next_sibling`/`d_flags` stay MAIN-RAM arrays: 44 hot sites (d_flags) net near-zero and
would slow traversal. Moving name_off+depth+parent netted ~540 B (BSS -748 offset by +~210 accessor code).
**Trap (found by adversarial review, not manual test):** growing the record made `dx_clear` (full-record
zero) wipe the moved fields, so `unlog()` (Alt-R Release on a LIVE node) corrupted its name/depth/parent
-> added `dx_clear_files` (clears only the cold +0..+6 file fields); `new_node`'s full `dx_clear` is fine
because it re-sets the fields after. Remaining movable: the rest of d_* (higher effort, hot).

**Backlog / still movable:** the easy wins are done (copy, dialogs, About, command menu).
input_line/hist_popup (~2 KB) are BLOCKED - input_line calls pick_dir (deep xtree), which the
overlay can't call back into; unblocking would mean restructuring so the F2 dir-pick happens
in main around the overlay call. print_trunc / hilite_row / box_open / box_close / box_left stay
in main (hot draw paths + box_close -> draw_frame). ~3.3 KB still free in the uiutil bank.
