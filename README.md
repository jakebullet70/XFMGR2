# XFMGR2 — an XTree-style file manager for the Commander X16 (Prog8)

*(build:197)*

A dual-pane, keyboard-driven file manager in the spirit of XTree/XTreeGold:
a collapsible **directory tree** on the left, the selected directory's **files**
on the right, with file **tagging**, a banked **text/hex viewer**, a **BMX image
viewer**, **music playback** (`.zsm`/`.wav`), a whole-disk **Find**, and a full set of file operations — copy, move,
rename, delete, mkdir and prune — plus editing via the ROM-resident X16 Edit and
switchable **color themes**.

<img width="642" height="507" alt="image" src="https://github.com/user-attachments/assets/c4acdb79-510c-4650-8d78-15b4cee30b13" />



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
- **Find file** (`Ctrl-F`) — a whole-disk crawler that walks the tree from the root,
  logs only the directories that contain a match, and shows every hit in a flat modal
  list you can jump straight into.
- **Sorting** — cycle files by name → extension → size (`Alt-S`).
- **File operations** — copy (`C`/`Ctrl-C`), move (`M`/`Ctrl-O`/`Ctrl-M`), rename with `*`/`?`
  wildcards (`R`), delete one (`D`) or all tagged (`Ctrl-X`/`Ctrl-D`). Copy/move
  destinations resolve from the drive root and can be picked interactively from the
  tree (`F2`).
- **Directory operations** — make a subdirectory (`M`), rename (`R`) or delete (`D`) a
  folder, and **prune** (`P`), a guarded recursive delete of a directory and everything
  under it.
- **View** (`V`) — a `.bmx` bitmap opens full-screen in the BMX **image viewer**; any
  other file opens in the full-screen **text/hex viewer** with in-file search. If the
  viewer overlays are missing, `V` falls back to X16 Edit.
- **Play music** (`P`) — `.zsm` chiptunes play through the **zsmkit** engine (FM + PSG +
  PCM); `.wav` plays uncompressed PCM (8/16-bit, mono/stereo, up to ~48 kHz). `Space`
  pauses/resumes, `Q`/`Esc` stops. Needs `zsmkit.bin` and `xmusic.ovl` beside the program.
- **Edit** (`E`) — hands the file off to the ROM-resident **X16 Edit**, then returns.
- **Execute-and-return** (`Alt-X`) — quit XFMGR and chain-run the selected program.
- **File-spec filter** (`F`) — restrict the file list to a wildcard (e.g. `*.prg`).
- **Color themes** (`Alt-F10`) — hands off to a standalone theme picker (`XFSETUP.PRG`)
  that remaps the palette and saves the choice to `xfmgr.cfg`; XFMGR reapplies it at
  startup.
- **Root-anchored startup** — the tree is anchored at the drive root; the folder you
  launched from is pre-selected. Quit returns the shell to the launch dir (`Q`) or to
  the currently selected dir (`Alt-Q`).
- **Input history** — every text prompt remembers recent entries (`↑` to pick),
  persisted per prompt-category under `hist/` on the drive root.

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
| `M` | Make a new subdirectory in the selected folder |
| `R` | Rename the selected directory |
| `D` | Delete the selected folder (empty folders only) |
| `P` | **Prune** — recursively delete the folder and all its contents (type `prune` to confirm) |
| `F3` | Re-log sub-folders (picks up folders made since logging) |
| `A` | About box (version, banked-RAM usage, credits) |

### FILE pane (plain keys)

| Key | Action |
|---|---|
| `T` | Tag current file, then advance |
| `U` | Untag current file, then advance |
| `V` | View file — `.bmx` in the image viewer, otherwise the text/hex viewer |
| `P` | Play music — `.zsm` (ZSound) or `.wav` (PCM) audio |
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
| `Ctrl-F` / `Ctrl-N` | **Find** files across the whole disk (`N` in emulator, `F` on hardware) |
| `Ctrl-C` | Copy all tagged files (from all dirs) to one destination |
| `Ctrl-O` / `Ctrl-M` | Move all tagged files (from all dirs) to one destination (`O` in emulator, `M` on hardware) |
| `Ctrl-X` / `Ctrl-D` | Delete all tagged files in this directory (`X` in emulator, `D` on hardware) |

### ALT menu

| Key | Action |
|---|---|
| `Alt-S` | Cycle sort order: name → extension → size |
| `Alt-X` | Execute — quit XFMGR and chain-run the selected program |
| `Alt-Q` | Quit, leaving the shell in the **currently selected** directory |
| `Alt-F3` | Re-log the current context (sub-folders in the DIR pane, files in the FILE pane) |
| `Alt-F10` | Open the color-theme setup (quits to the standalone `XFSETUP.PRG`) |

### Global

| Key | Action                                              |
|-----|-----------------------------------------------------|
| `Q` | Quit, leaving the shell in the **launch** directory |

### In text prompts (Copy, Move, Rename, Mkdir, Filespec, Tag-spec, Find)

| Key | Action |
|---|---|
| `↑` | Pop up the recent-entry history picker for this prompt |
| `F2` | Open the interactive directory picker (Copy/Move destinations) |
| `←` / `→` / `Home` | Move the cursor in the field |
| `Enter` / `Esc` | Accept (saved to history) / cancel |

In the **ShowAll**, **Find** and **directory-picker** modals: `↑`/`↓` move, `Enter`
selects/jumps, `Esc`/`Q` cancels; in the picker, `→` expands (logging on demand) and
`←` collapses; in ShowAll, `U` untags the highlighted entry in place.

In the **text/hex viewer** (`V`): `PgDn`/`PgUp` page, `T`/`Home` jump to top, `H`
toggles hex/text, `F` finds a string and `N` repeats the search, `Q`/`Esc` exits. In
the **BMX image viewer**, any key returns to the file list. During **music playback**
(`P`), `Space` pauses/resumes and `Q`/`Esc` stops.


## Architecture (the memory model)

The hard constraint on the X16 is RAM: ~40 KB main, plus 8 KB-windowed banked RAM
(banks at `$A000–$BFFF`, up to 2 MB). A 16-bit pointer can't cross the bank window,
so the design splits data by **access pattern** — redraw-hot data stays in main RAM;
cold, bulky data and cold *code* live in banked RAM behind far pointers / bank
overlays.

The stock machine has banks 0–63. The low banks are reserved: bank 0 is the Kernal,
bank 1 holds the tree's cold dir-extras table (and the ShowAll/Find far-pointer arrays),
banks 2–5 hold four code overlays, bank 6 the **zsmkit** music engine, bank 7 the
**xmusic** overlay, and bank 8 the directory-name slab; the file arena grows upward from
**bank 9** to the detected top bank.

| Module | Lives in | Holds | Why |
|---|---|---|---|
| `xarena.p8` | banks 6+ | append-only bump allocator (~7.8 KB usable per bank, `$A000–$BEFF`) | files are numerous and append-only, then bulk-freed on rescan; no per-record header, no fragmentation |
| `xtree.p8` | main RAM (names in bank 8) | directory tree — a byte-indexed node pool (`DIR_MAX = 254`, `NONE=255`), links/flags/depth; the directory-name slab lives in bank 8 behind a far pointer | few dirs, redrawn on every keystroke; the hot node pool stays in main RAM while the cold name bytes are banked |
| xtree **dir-extras** | bank 1 | per-node cold fields (file count/offset/bank, tag count) in fixed 7-byte records | never touched in the per-row redraw loop, only on scan/tag/file ops; frees main RAM, and bank 1 is never disturbed by an arena reset |
| `xfiles.p8` | banked arena + main RAM | length-prefixed file records in the arena; a small far-pointer display index + sort mode + file-spec in main RAM; ShowAll/Find far-pointer arrays | large records stay in the arena; the insertion sort runs on the small index, not the records |
| `xscan.p8` | main module | on-demand logger + scratch paths | drives diskio's one-listing-at-a-time rule: subdirs → tree, files → arena |
| `tview.ovl` | bank 2 (overlay) | 16-bit page-offset table + shared read buffer | read-only text/hex pager with in-file search; larger files hand off to X16 Edit |
| `miscutil.ovl` | bank 3 (overlay) | wildcard-rename expander, recursive prune engine, input-history ring, file-copy byte pump, whole-disk Find crawler | self-contained cold helpers pulled out of main RAM; their path/copy buffers cost no main RAM |
| `uiutil.ovl` | bank 4 (overlay) | bottom-banner dialogs, modal box borders, the command menu, the About screen | dialog *drawing* is cold; main keeps thin wrappers that `JSRFAR` into the overlay |
| `ximgview.ovl` | bank 5 (overlay) | native BMX bitmap loader/displayer | image decode is bulky and rarely used; kept out of the resident image entirely |
| `xmusic.ovl` | bank 7 (overlay) | `.wav` PCM streaming player (AFLOW-driven) | audio streaming is cold and self-contained; the `.zsm` path drives the `zsmkit.bin` engine in bank 6 |
| `xfmgr.p8` | main module | TUI + key loop, file ops, prompts, screen helpers | dual-pane draw, tagging, all `op_*` operations |

`xfsetup.p8` builds to a **separate** `XFSETUP.PRG` (a full `$0801` program, not an
overlay) — the `Alt-F10` color-theme picker; `themes.p8` does the palette remap and
reads/writes `xfmgr.cfg`.

Key decisions:

- A **bump/arena allocator**, not malloc/free — XTree's file data is written in one
  append-only pass per directory and bulk-freed on rescan, so a bump pointer with no
  per-record header beats a general heap. Individual records are never reclaimed; dead
  space from refreshes/renames is only recovered on a full reset.
- **Index arrays, not pointer-chasing lists** — a 16-bit pointer can't span the bank
  window, so the tree uses byte indices (`NONE=255`) and files use `(bank, offset)`
  far pointers.
- **Cold code in bank overlays** — rarely-hit code paths (viewer, dialogs, image
  decode, wildcard/prune/history/Find helpers) live in HIRAM overlays reached via
  `extsub @bank`, freeing main RAM for the redraw-hot tree, file index and key loop.
- **Editor bank handoff** — `op_edit` finds X16 Edit in ROM, refuses if there's no
  free bank above the arena, then calls it with `firstbank = high_bank + 1` and
  `lastbank = max_bank` (the machine's real top bank, never `255`) so the editor can't
  clobber cached records or run off the installed RAM.

`test_arena.p8` verifies the allocator across a real multi-bank spill.

## Startup & persistence

The tree is **anchored at the drive root** (`base_path = "/"`), so every path built
from a tree node is absolute. At startup XFMGR captures the launch folder
(`diskio.curdir()`) before any disk call can clobber it, loads the five overlays into
their reserved banks, applies the saved color theme, then descends the tree from root,
logging and expanding each level so the launch folder is pre-selected and visible.

Because navigation is root-relative, copy/move destinations resolve from the **drive
root** (XTree's global-navigation model), and the two quit paths differ: plain `Q`
returns the shell to the **launch** directory, while `Alt-Q` returns it to the
**currently selected** directory.

**Input history** is per prompt-category, stored under `hist/` on the drive root
(e.g. `hist/copy.his`, `hist/move.his`). Each ring keeps the most-recent entries,
newest first; the folder is created on first save and missing files load silently as
empty. The **color theme** is stored in `xfmgr.cfg` next to the program.

## Installing

XFMGR2 ships as a folder of files plus a self-installer, `install.prg`. Unpack the
release folder onto your SD card, then on the X16:

1. `CD` into the unpacked folder (the one holding `install.prg` and the app files).
2. Run it: `/install*` (or `^install*`).
3. It creates `/xfmgr` on the drive root, stream-copies the program files into it, and
   writes a tiny `/xt` BASIC launcher at the root.

Then launch XFMGR from anywhere with the caret-run command:

```
^/xt
```

The installer ships a default `xfmgr.cfg` (Classic theme) so a fresh install boots with a
theme; on a re-install it **preserves** an existing `xfmgr.cfg`, so a theme you set via
`Alt-F10` survives updates. It reports the release build number and, when `/xfmgr` already
exists, compares it against the installed build (older / newer / same). Press `T` at the
prompt for a dry run that does everything except copy the files. Run it from a folder that
is already `/xfmgr` and it skips the copy, only (re)writing the `/xt` launcher.

## Build & run

Requires **Java** (JRE) and the **64tass** assembler (v1.60); their paths are baked
into `build.bat`, which drives the bundled `prog8c.jar` Prog8 compiler:

```
build.bat xfmgr.p8        # -> build\xfmgr.prg + the .ovl overlays + xfsetup.prg
```

Building `xfmgr.p8` also compiles its companions:

- **five banked overlays** — `tview.ovl` (text/hex viewer), `miscutil.ovl` (wildcard
  rename / prune / history / copy pump / Find crawler), `uiutil.ovl` (dialogs, menu,
  About), `ximgview.ovl` (BMX image viewer) and `xmusic.ovl` (`.wav` PCM player). Each
  is a headerless `%output` library loaded into a reserved HIRAM bank at runtime (the
  build renames prog8's `.bin` to `.ovl`).
- **`xfsetup.prg`** — the standalone color-theme picker launched by `Alt-F10`.
- **`install.prg`** — the standalone self-installer (see [Installing](#installing)).

All compiler output (`.prg`, `.ovl`, and the intermediate `.asm`/`.vice-mon-list`) is
written into a gitignored `build\` folder, so the project root stays clean. Static
assets that are *not* built — `xfmgr.hlp`, `zsmkit.bin` and the default `xfmgr.cfg` —
stay at the root.

The build prints a memory-stats block (image size, BSS/slab, main-RAM high-water,
free low RAM below `$9F00`, and the on-disk `.prg` size). Banked HIRAM is not counted —
it holds the overlays and the dynamically-growing file arena.

`run.bat` compiles, stages the built `xfmgr.prg`, the `.ovl` overlays and `xfsetup.prg`
(from `build\`) into `run/xfmgr/`, copies the sample `.bmx` images into the browse root,
and launches the emulator:

```
run.bat                   # build + stage + launch in the emulator
```

- It boots from the clean `run/` folder as the X16 host filesystem root (no
  `AUTOBOOT.X16` there to hijack boot) via a small loader stub that `LOAD`+`RUN`s
  `/XFMGR/XFMGR.PRG`. `run/` ships with sample folders and files to browse.
- `-ram 512` pins the machine to 512 KB (banks 0–63) to exercise bank detection and
  the "of 63 banks" About readout.
- `-rtc` drives the live clock; `-joy1` enables joystick input.

**Kernal R49 or newer is required.** XFMGR2 refuses to launch on older/pre-release
ROMs because it depends on R49+ behavior — notably the X16 Edit ROM API used by the
`E` (edit) command. It also detects the emulator at startup (`emudbg.is_emulator()`)
to choose the environment-specific CTRL keys the emulator would otherwise swallow:
**delete-tagged** is `Ctrl-X` in the emulator / `Ctrl-D` on hardware, **Find** is
`Ctrl-N` in the emulator / `Ctrl-F` on hardware, and **move-tagged** is `Ctrl-O` in the
emulator / `Ctrl-M` on hardware.



## Status & known limitations

**v1.0.184 — working.** Dual-pane navigation, on-demand logging, tagging (including
cross-directory) and ShowAll, whole-disk Find, sorting, the full file-operation set
(copy / move / rename / delete / mkdir / prune), the banked text/hex viewer, the BMX
image viewer, `.zsm`/`.wav` music playback, edit via X16 Edit, execute-and-return,
switchable color themes, root-anchored startup and persistent input history are all
implemented, with confirmation prompts on destructive actions and status banners for
errors.

Remaining limitations:

- **No recursive whole-disk *logging*.** Directories are logged on demand; only `Find`
  crawls the whole disk, and it logs solely the directories that contain a match.
- **Append-only arena.** Individual file records are never freed; dead space from
  refreshes/renames accumulates and is only reclaimed on a full reset/reload.
- **Fixed capacity caps:** `DIR_MAX = 254` directories, 255 files per displayed
  directory, 255 files collected for ShowAll / Find (excess → "(partial)"), and a
  bounded directory-name slab.
- **Single drive.** All operations are relative to one mounted drive; there is no
  multi-volume or `.d64` image support.
