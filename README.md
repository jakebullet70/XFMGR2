# XFMGR2 — an XTree-style file manager for the Commander X16 (Prog8)

A dual-pane, keyboard-driven file manager in the spirit of XTree/XTreeGold:
a collapsible **directory tree** on the left, the selected directory's **files**
on the right, with file **tagging**, a built-in **viewer**, and a full set of
file operations — copy, move, rename, delete, mkdir and prune — plus editing
via the ROM-resident X16 Edit.

<img width="802" height="633" alt="image" src="https://github.com/user-attachments/assets/817859a9-4dc9-4e4c-bc4a-76ed56dec40f" />


## Features

- **Dual-pane layout** (80×30 text): a collapsible directory tree on the left, the
  selected directory's files on the right, a live status line and a live clock.
- **On-demand logging** — directories are scanned only when you enter/expand them
  (`Enter`), keeping startup fast. No blocking whole-disk crawl.
- **File tagging**, XTree-style tag-and-advance: tag/untag one file, tag/untag/invert
  a whole directory, or tag by wildcard (`Ctrl-W`).
- **Cross-directory tagging** — tags persist across every logged directory. The
  **ShowAll** view (`Ctrl-G`) collects every tagged file from all logged dirs into a
  single scrollable list, and global copy/move/delete act on that whole set.
- **Sorting** — cycle files by name → extension → size (`Alt-S`).
- **File operations** — copy (`C`/`Ctrl-C`), move (`M`/`Ctrl-O`), rename with `*`/`?`
  wildcards (`R`), delete one (`D`) or all tagged (`Ctrl-X`/`Ctrl-D`). Copy/move
  destinations resolve from the drive root and can be picked interactively from the
  tree (`F2`).
- **Directory operations** — make a subdirectory (`K`) and **prune** (`P`), a guarded
  recursive delete of a directory and everything under it.
- **View** (`V`) — full-screen text/hex viewer with in-file search, for files up to ~60 KB.
- **Edit** (`E`) — hands the file off to the ROM-resident **X16 Edit**, then returns.
- **Execute-and-return** (`Alt-X`) — quit XFMGR and chain-run the selected program.
- **File-spec filter** (`F`) — restrict the file list to a wildcard (e.g. `*.prg`).
- **Root-anchored startup** — the tree is anchored at the drive root; the folder you
  launched from is pre-selected. Quit returns the shell to the launch dir (`Q`) or to
  the currently selected dir (`Alt-Q`).
- **Input history** — every text prompt remembers recent entries (`↑` to pick),
  persisted per prompt-category under `hist/` on the drive root.


## Build & run

Requires **Java** (JRE) and the **64tass** assembler (v1.60); their paths are baked
into `build.bat`, which drives the bundled `prog8c.jar` Prog8 compiler:

```
build.bat xfmgr.p8        # -> xfmgr.prg   (compiles SRC\xfmgr.p8)
```

The build prints a memory-stats block (image size, BSS/slab, main-RAM high-water,
free low RAM below `$9F00`, and the on-disk `.prg` size).

Run in the emulator:

```
x16emu.exe -fsroot run/ -ram 512 -prg xfmgr.prg -run -rtc -joy1
```

- `-fsroot run/` uses the clean `run/` folder as the X16 host filesystem so the
  project-root `AUTOBOOT.X16` dev menu doesn't hijack boot; `run/` ships with a few
  sample folders and files to browse.
- `-ram 512` pins the machine to 512 KB (banks 0–63) to exercise bank detection and
  the "of 63 banks" About readout.
- `-rtc` drives the live clock; `-joy1` enables joystick input.

**Kernal R49 or newer is required.** XFMGR2 refuses to launch on older/pre-release
ROMs because it depends on R49+ behavior — notably the X16 Edit ROM API used by the
`E` (edit) command. It also detects the emulator at startup (`emudbg.is_emulator()`)
to choose the delete-tagged key: **Ctrl-X** in the emulator (which swallows Ctrl-D),
**Ctrl-D** on real hardware.


## Keys / commands

The command menu (rows 27–28) is **modifier-driven**. By default it shows **MENU**
(plain keys). Holding **CTRL** switches it to the **CTRL:** menu; holding **ALT**
(the Commodore key on the X16) switches it to the **ALT:** menu. Release the modifier
to return to MENU. The plain-key menu is **context-sensitive**: the DIRECTORY pane and
the FILE pane offer different commands.

### Navigation (either pane)

| Key | Action |
|---|---|
| `↑` / `↓` | Move the cursor within the focused pane |
| `TAB` | Switch focus between the DIRECTORY and FILE panes |
| `→` | Focus the FILE pane |
| `←` | Focus the DIRECTORY pane |

Entering the FILE pane on an unscanned directory logs its files on the fly.

### DIRECTORY pane (plain keys)

| Key | Action |
|---|---|
| `Enter` | Log the directory if new; otherwise expand / collapse it |
| `K` | Make a new subdirectory in the selected folder |
| `P` | **Prune** — recursively delete the folder and all its contents (type `prune` to confirm) |
| `F3` | Re-log sub-folders (`+N new` banner) |
| `A` | About box (version, banked-RAM usage, credits) |

### FILE pane (plain keys)

| Key | Action |
|---|---|
| `T` | Tag current file, then advance |
| `U` | Untag current file, then advance |
| `V` | View file (full-screen text/hex viewer) |
| `E` | Edit file in the ROM X16 Edit, then return |
| `D` | Delete current file (confirm) |
| `R` | Rename (supports `*` / `?` wildcards) |
| `C` | Copy selected (or all tagged) file(s) to a directory |
| `M` | Move selected (or all tagged) file(s) to a directory |
| `F` | Set the file-spec filter (e.g. `*.prg`, `*` = all) |

### CTRL menu (acts on the current directory / all tagged)

| Key | Action |
|---|---|
| `Ctrl-T` | Tag all files in this directory |
| `Ctrl-U` | Untag all files in this directory |
| `Ctrl-I` | Invert tags in this directory |
| `Ctrl-W` | Tag files matching a wildcard |
| `Ctrl-G` | **ShowAll** — modal list of every tagged file across all logged dirs |
| `Ctrl-C` | Copy all tagged files (from all dirs) to one destination |
| `Ctrl-O` | Move all tagged files (from all dirs) to one destination |
| `Ctrl-X` / `Ctrl-D` | Delete all tagged files in this directory (`X` in emulator, `D` on hardware) |

### ALT menu

| Key | Action |
|---|---|
| `Alt-S` | Cycle sort order: name → extension → size |
| `Alt-X` | Execute — quit XFMGR and chain-run the selected program |
| `Alt-Q` | Quit, leaving the shell in the **currently selected** directory |
| `Alt-F3` | Re-log the current context (sub-folders in the DIR pane, files in the FILE pane) |

### Global

| Key | Action                                              |
|-----|-----------------------------------------------------|
| `Q` | Quit, leaving the shell in the **launch** directory |

### In text prompts (Copy, Move, Rename, Mkdir, Filespec, Tag-spec)

| Key | Action |
|---|---|
| `↑` | Pop up the recent-entry history picker for this prompt |
| `F2` | Open the interactive directory picker (Copy/Move destinations) |
| `←` / `→` / `Home` | Move the cursor in the field |
| `Enter` / `Esc` | Accept (saved to history) / cancel |

In the **ShowAll** and **directory-picker** modals: `↑`/`↓` move, `Enter` selects,
`Esc`/`Q` cancels; in the picker, `→` expands (logging on demand) and `←` collapses;
in ShowAll, `U` untags the highlighted entry in place.

In the **viewer** (`V`): `PgDn`/`PgUp` page, `T`/`Home` jump to top, `H` toggles
hex/text, `F` finds a string and `N` repeats the search, `Q`/`Esc` exits.


## Architecture (the memory model)

The hard constraint on the X16 is RAM: ~40 KB main, plus 8 KB-windowed banked RAM
(banks at `$A000–$BFFF`, up to 2 MB). A 16-bit pointer can't cross the bank window,
so the design splits data by **access pattern** — redraw-hot data stays in main RAM;
cold, bulky data lives in banked RAM behind far pointers.

| Module | Lives in | Holds | Why |
|---|---|---|---|
| `xarena.p8` | banks 2+ | append-only bump allocator (~7.8 KB usable per bank, `$A000–$BEFF`) | files are numerous and append-only, then bulk-freed on rescan; no per-record header, no fragmentation |
| `xtree.p8` | main RAM | directory tree — a 192-node byte-indexed pool (`NONE=255`), links/flags/depth, and a 3 KB name arena (`dname_buf`) | few dirs, redrawn on every keystroke; no bank-switch cost |
| xtree **dir-extras** | bank 1 | per-node cold fields (file count/offset/bank, tag count) in fixed 7-byte records | never touched in the per-row redraw loop, only on scan/tag/file ops; frees ~1.3 KB of main RAM, and bank 1 is never disturbed by an arena reset |
| `xfiles.p8` | banked arena + main RAM | length-prefixed file records in the arena; a small far-pointer display index + sort mode + file-spec in main RAM; ShowAll far-pointer arrays | large records stay in the arena; the insertion sort runs on the small index, not the records |
| `xscan.p8` | main module | on-demand logger + scratch paths | drives diskio's one-listing-at-a-time rule: subdirs → tree, files → arena |
| `xviewer.p8` | main module (modal) | 16-bit page-offset table + shared read buffer | read-only pager for files up to ~60 KB; larger files hand off to X16 Edit |
| `xfmgr.p8` | main module | TUI + key loop, file ops, prompts, screen helpers | dual-pane draw, tagging, all `op_*` operations |

Key decisions:

- A **bump/arena allocator**, not malloc/free — XTree's file data is written in one
  append-only pass per directory and bulk-freed on rescan, so a bump pointer with no
  per-record header beats a general heap. Individual records are never reclaimed; dead
  space from refreshes/renames is only recovered on a full reset.
- **Index arrays, not pointer-chasing lists** — a 16-bit pointer can't span the bank
  window, so the tree uses byte indices (`NONE=255`) and files use `(bank, offset)`
  far pointers.
- A separate banked **dir-extras** table (bank 1) keeps cold per-directory fields out
  of the redraw-hot main-RAM node pool.
- **Editor bank handoff** — `op_edit` finds X16 Edit in ROM, refuses if there's no
  free bank above the arena, then calls it with `firstbank = high_bank + 1` and
  `lastbank = max_bank` (the machine's real top bank, never `255`) so the editor can't
  clobber cached records or run off the installed RAM.

`test_arena.p8` verifies the allocator across a real multi-bank spill.

## Startup & persistence

The tree is **anchored at the drive root** (`base_path = "/"`), so every path built
from a tree node is absolute. At startup XFMGR captures the launch folder
(`diskio.curdir()`) before any disk call can clobber it, then descends the tree from
root, logging and expanding each level so the launch folder is pre-selected and
visible in the tree.

Because navigation is root-relative, copy/move destinations resolve from the **drive
root** (XTree's global-navigation model), and the two quit paths differ: plain `Q`
returns the shell to the **launch** directory, while `Alt-Q` returns it to the
**currently selected** directory.

**Input history** is per prompt-category, stored under `hist/` on the drive root
(e.g. `hist/copy.his`, `hist/move.his`). Each ring keeps the 15 most-recent entries,
newest first; the folder is created on first save and missing files load silently as
empty.

## Status & known limitations

**v1.0.0 — working.** Dual-pane navigation, on-demand logging, tagging (including
cross-directory) and ShowAll, sorting, the full file-operation set (copy / move /
rename / delete / mkdir / prune), the text/hex viewer, edit via X16 Edit,
execute-and-return, root-anchored startup and persistent input history are all
implemented, with confirmation prompts on destructive actions and status banners for
errors.

Remaining limitations:

- **No recursive whole-disk logging.** Directories are logged on demand; there is no
  automatic crawl of the entire disk tree at startup.
- **Append-only arena.** Individual file records are never freed; dead space from
  refreshes/renames accumulates and is only reclaimed on a full reset/reload.
- **Fixed capacity caps:** `DIR_MAX = 192` directories, 255 files per directory, 255
  tagged files in ShowAll, filenames up to 249 chars, and 3072 bytes total of
  directory-name storage.
- **Single drive.** All operations are relative to one mounted drive; there is no
  multi-volume or `.d64` image support.
