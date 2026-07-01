---
name: xfmgr-architecture
description: Module layout and memory model of the XFMGR2 XTree-clone for the X16
metadata: 
  node_type: memory
  type: project
  originSessionId: ff94bf97-5839-406e-b6b3-a755dab25e6a
---

XFMGR2 = an XTree-style file manager for the Commander X16 in Prog8. v1 (navigator)
is built and verified on the emulator. Modules (project root .p8 files):

- `xarena.p8` — banked **bump allocator** over HIRAM banks ($A000-$BFFF window).
  Append-only, bulk-free (`reset`); no malloc/free. Far ptr = (bank, offset). Rolls to
  next bank when a record won't fit. far_peek/far_poke/read_str/add_str helpers.
  Verified across a real 3-bank roll by `test_arena.p8`. NOTE: `FIRST_BANK = 2` — bank 1
  is reserved for the xtree dir-extras table (see below); the allocator never touches it.
- `xtree.p8` — directory tree, byte-indexed parallel-array node pool (NONE=255, root=index 0).
  Holds DIRECTORIES ONLY. SPLIT by access pattern: redraw-hot fields
  (`d_parent/d_first_child/d_next_sibling/d_name_off/d_flags/d_depth`) + name slab stay in
  MAIN RAM; the COLD per-dir fields (file_count, file_off, file_bank, tagged_count) live in
  a 7-byte-per-node "dir-extras" record in BANKED RAM bank 1 ($A000+id*7), reached via
  `dx_*` accessor subs (`dx_fcount/dx_set_foff/dx_inc_tag/dx_dec_tag`…). This reclaimed
  ~974 B net main RAM (Tier A). `rebuild_visible()` flattens expanded nodes iteratively.
- `xfiles.p8` — per-dir FILE records in the banked arena: `[reclen][blocksLo][blocksHi]`
  `[ftype][flags][name+NUL]`; reclen==0 byte is a bank-roll SENTINEL the walker follows.
  Tag bit in flags; `build_index()` fills ft_bank[]/ft_off[] for the shown dir.
- `xscan.p8` — logs ONE dir on demand via diskio `lf_start_list`/`lf_next_entry`/`lf_end_list`
  (one session at a time): subdirs→xtree.add_child, files→xfiles.add_file. Also `refresh_files`
  / `refresh_dirs` for in-place relog.
- `xviewer.p8` — read-only paged file viewer (text + hex + case-insensitive find), extracted
  from xfmgr. Reaches back into `main.` for shared buffers (viewbuf/namebuf/pathbuf), helpers
  (blank_span/print_trunc/msg_begin/wait_key), `g_key`, file_cursor/cur_dir and op_edit.
- `xfmgr.p8` — main: dual-pane TUI (tree left, files right), key loop, tagging, all ops.

Memory decision: files MUST be banked; dir tree stays in main RAM (few dirs, redraw-hot,
`^^` pointers can't cross banks). Use an arena, NOT a string heap; index arrays, NOT linked lists.

STATUS (newer than README): copy/move/delete/rename, mkdir, sort, wildcard filespec+tag,
ShowAll + global copy/move, untag-all/invert, edit/execute, and the viewer are all DONE.
The main remaining XTree feature is **recursive whole-disk logging** — the only one that
needs the dir tree to exceed DIR_MAX(192), which is the trigger for Tier B/C (moving the
name slab / full tree pool to banks). See [[x16-banked-ram-min-config]] and
[[prog8-module-split-cost]]. Build/run: see [[prog8-build-toolchain]].
