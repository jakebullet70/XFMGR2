---
name: xfmgr-find-file
description: XFMGR2 whole-disk Find (Ctrl-F hw / Ctrl-N emu) - resumable overlay crawler yields match-dir paths; log-on-match; flat modal + jump-to-file
metadata: 
  node_type: memory
  type: project
  originSessionId: f3d00c60-c71e-4045-88f8-0aa07cdf93f6
---

Added 2026-07-03 (implemented the reloaded "Find file" plan). A CTRL-menu command (both panes)
prompts for a filespec (e.g. `*.prg`), searches the WHOLE disk from `/`, shows matches as a flat
modal list, and jumps to a selected match in the dual pane. Partially covers the
[[xfmgr-showall-revisit]] backlog (whole-disk browse).

**Hotkey is environment-specific (the emulator swallows Ctrl-F, confirmed by testing):** exactly
like the delete key, `start()` picks `find_key`/`find_char` via `emudbg.is_emulator()` — **Ctrl-F**
(display "Find") on real hardware, **Ctrl-N** (display "N Find") under the emulator. Dispatch is an
`if letter == find_key` BEFORE the `when` in `handle_ctrl` (a runtime var can't be a constant
when-case, same as `del_key`). The menu label is rendered by `uiutil.find_label(find_char)` — so
`ui_draw_commands` gained a 5th arg `find_char @R4`. Swallowed CTRL keys so far: D, S, F, M.

**Three phases, single-listing-safe.** diskio allows only ONE open listing at a time, so a
recursive walk can't hold a parent open while descending.
- **Crawl (miscutil overlay, bank 3):** a resumable O(depth) pre-order DFS keeping only the
  current path (`cr_cur[102]`) + ~200 B scratch — no worklist. New jmptable entries
  `crawl_begin=$A018`, `crawl_next_hit=$A01B`, `crawl_trunc=$A01E` (appended after
  `stream_copy=$A015`; all `cr_*` vars are UNINITIALIZED so the table stays put, per
  [[prog8-jmptable-init-vars-gotcha]]). `crawl_next_hit` lists `cr_cur` once (computing has-match
  + first subdir in one pass), closes it, then `cr_advance()` moves to the next DFS node —
  descending into the first subdir, else re-listing an ancestor via `cr_next_sibling` to find the
  sibling after the one we came up from. Uses the overlay's OWN diskio; everyone chdir's absolute,
  so churn between hits is harmless.
- **Log + collect (main):** per hit, `xscan.open_path(path)` logs/expands ancestors and returns
  the deepest node, then `xscan.scan_dir(node)` logs THAT dir's files (open_path only logs each
  level's *children*). After the crawl, `xfiles.collect_matching(find_lc)` fills the `sa_*` arrays
  (clone of `collect_tagged`, name-match instead of REC_TAGGED).
- **Modal + jump (main):** `show_find_results(partial)` clones `show_all`; Enter -> `jump_to_result`
  expands ancestors, `set_tree_cursor_to`, `xfiles.set_spec(inputbuf)` (so the pane shows the found
  set), `select_dir`, scans `ft_` for the name to set `file_cursor`, `focus = FOCUS_FILE`.

**Log-on-match:** only dirs that contain a match are ever logged — the tree stays clean and the
128-dir cap is respected. **Caps surfaced (no silent truncation):** `(partial)` in the modal title
via `partial` bits — bit0 too-deep (`crawl_trunc()`), bit1 128-dir cap (`dir_count>=DIR_MAX`), bit2
255-result cap (`sa_count>=GLOBAL_MAX`).

**Crash fixed 2026-07-03 (whole-disk scan exposed two latent buffer overflows on long hostfs
filenames):** (1) `xarena.read_str` was uncapped -> now takes a `cap` and every caller passes
its buffer size (`xfiles.NAME_RD_CAP=51`); (2) prog8's bundled `diskio` overran its 50-byte
`list_filename` on any 50+ char listing entry -> fixed via a vendored patch, see
[[prog8-diskio-vendored-patch]]. Both were reachable because Find lists EVERY dir (e.g. a
folder with a 58-char PDF name). Names now truncate uniformly at 51 chars in RAM copies.

**Files:** `SRC/miscutil.p8` (crawl engine), `SRC/xfmgr.p8` (extsub decls, Ctrl-F,
op_find/show_find_results/jump_to_result, `str find_lc`), `SRC/xfiles.p8` (collect_matching),
`SRC/uiutil.p8` (F label in `menu_ctrl_items`). Only new main-RAM data is `find_lc` (~32 B) — the
crawl code + path buffers live in bank 3. Post-build low-RAM free ~3.9 KB. Build green
([[prog8-build-toolchain]]); [[user-tests-in-emulator-themselves]].
