# XFMGR2 — an XTree-style file manager for the Commander X16 (Prog8)

*(build:258)*

A dual-pane, keyboard-driven file manager in the spirit of XTree/XTreeGold:
a collapsible **directory tree** on the left, the selected directory's **files**
on the right, with file **tagging**, a banked **text/hex viewer**, a **BMX image
viewer**, **music playback** (`.zsm`/`.wav`), a whole-disk **Find**, and a full set
of file operations — copy, move, rename, delete, mkdir and prune — plus editing via
the ROM-resident X16 Edit and switchable **color themes**.

<img width="642" height="507" alt="image" src="https://github.com/user-attachments/assets/c4acdb79-510c-4650-8d78-15b4cee30b13" />

---

## Contents

**[1. Main Display](#1-main-display)** — [1.1 Directory Window](#11-directory-window) ·
[1.2 File Window](#12-file-window) ·
[1.3 Expanded File Windows](#13-expanded-file-windows--showall-branch-global) ·
[1.4 The Command Menu](#14-the-command-menu) · [1.5 FileSpec](#15-filespec)

**[2. Commands](#2-commands)** — [2.1 Either Pane](#21-standard-operation-keys-either-pane) ·
[2.2 Directory — Normal](#22-directory-window--normal) ·
[2.3 File — Normal](#23-file-window--normal) ·
[2.4 Ctrl](#24-ctrl-commands-either-pane) · [2.5 Alt](#25-alt-commands) ·
[2.6 The Input Line](#26-the-input-line) · [2.7 Tagging](#27-tagging-files)

**[3. Feature Descriptions](#3-feature-descriptions)** —
[3.1 Copy/Move](#31-copying-and-moving) · [3.2 Rename](#32-renaming) ·
[3.3 Content Search](#33-searching-tagged-files-by-content) ·
[3.4 Sequential Viewing](#34-sequential-viewing) · [3.5 Find File](#35-find-file) ·
[3.6 The Viewer](#36-the-internal-viewer) · [3.7 Music](#37-music-playback) ·
[3.8 Images](#38-image-viewer) · [3.9 Themes](#39-color-themes) ·
[3.10 History](#310-history-lists) · [3.11 Launching](#311-launching-programs)

**[4. Installation](#4-installation)** · **[5. Implementation Notes](#5-implementation-notes)** ·
**[6. Status and Limits](#6-status-and-limits)**

---

## 1. Main Display

80×30 text. A **directory tree** on the left, the selected directory's **files** on
the right, a title bar with the current path and counts, a live clock, and a
two-row command menu across the bottom.

### 1.1 Directory Window

The tree is **anchored at the drive root**, so every path built from a node is
absolute and copy/move destinations resolve from `/` — XTree's global-navigation
model. Directories are **logged on demand**: a folder is scanned only when you
enter or expand it, so startup never blocks on a whole-disk crawl.

The folder you launched from is pre-selected and visible at startup, with every
level above it logged and expanded on the way down.

### 1.2 File Window

Lists the selected directory's files with size in blocks and a tag marker. Entering
the file pane on an unlogged directory logs it on the fly rather than showing an
empty column.

### 1.3 Expanded File Windows — Showall, Branch, Global

XTree's Expanded File Window. From the directory pane these widen the file pane to
the full screen and fill it from more than one folder:

| Key | Scope |
|---|---|
| `S` | **Showall** — every logged file on the disk, as one flat list |
| `B` | **Branch** — the selected folder and everything logged below it |
| `G` | **Global** — every logged *disk* |

It is the **same file window with the same commands**, not a separate screen. Tag,
Untag, View, Play, Edit, Copy, Move, Rename, Delete and every Ctrl command work
exactly as in a normal listing, and each file is acted on **in its own folder** — so
`Ctrl-C` gathers tagged files from all over the disk into one destination, and
`Ctrl-S` searches their contents wherever they live.

Because rows come from many folders, the **path line follows the highlighted file**
rather than the tree cursor; it is the only thing telling you which folder the row
under the bar belongs to. `Esc`, or `TAB` back to the tree, returns to the two-pane
view.

Only files in **logged** directories appear — log more of the tree (`Enter`, or
`Alt-J` to reach somewhere directly) to widen what Showall can see.

> **On `G`:** XFMGR drives a single volume — one tree, anchored at one root — so
> "every logged disk" and "the whole disk" are the same set of files, and `G` shares
> Showall's handler outright. It is present so the menu matches XTree's; it is where
> the two would diverge if multi-volume support is ever added.

### 1.4 The Command Menu

The bottom two rows are **modifier-driven**. By default they show **MENU** (plain
keys); holding **CTRL** switches to the CTRL menu and holding **ALT** (the Commodore
key on real hardware) switches to the ALT menu. Release to return to MENU.

The plain-key menu is **context-sensitive** — the directory pane and the file pane
offer different commands — and the menu always shows the binding that is *active
right now*, which matters because some CTRL keys differ between emulator and
hardware (see [4.3](#43-emulator-vs-real-hardware)).

### 1.5 FileSpec

`F` in the file pane restricts the listing to a wildcard (`*.prg`, `readme.*`;
`Enter` alone means `*`). The filespec applies to scoped views too, so `F *.prg`
followed by `S` lists every program on the disk, and it is honoured by `Alt-T`
(tag branch).

---

## 2. Commands

### 2.1 Standard Operation Keys (either pane)

| Key | Action |
|---|---|
| `↑` / `↓` | Move the cursor in the focused pane |
| `PgUp` / `PgDn` | Page the focused pane |
| `TAB` | Switch focus between the directory and file panes |
| `→` | Focus the file pane (logs the directory's files if needed) |
| `←` | Focus the directory pane — or, in the tree, collapse the folder |
| `Esc` | Leave a scoped listing, back to the two-pane view |
| `F1` | Help |
| `Q` | Quit, leaving the shell in the **launch** directory |

### 2.2 Directory Window — Normal

| Key | Action |
|---|---|
| `Enter` | Log the directory if new; otherwise expand / collapse it |
| `+` / `−` | Expand / collapse |
| `M` | Make a new subdirectory |
| `R` | Rename the selected directory |
| `D` | Delete the selected folder (empty folders only) |
| `S` | **Showall** — see [1.3](#13-expanded-file-windows--showall-branch-global) |
| `B` | **Branch** |
| `G` | **Global** |
| `A` | About box (version, banked-RAM usage, credits) |

### 2.3 File Window — Normal

| Key | Action |
|---|---|
| `T` | Tag the current file, then advance |
| `U` | Untag the current file, then advance |
| `V` | View — `.bmx` in the image viewer, anything else in the text/hex viewer |
| `P` | Play music — `.zsm` or `.wav` |
| `E` | Edit in the ROM-resident X16 Edit, then return |
| `C` | Copy the selected (or all tagged) file(s) to a directory |
| `M` | Move the selected (or all tagged) file(s) to a directory |
| `R` | Rename (supports `*` and `?` wildcards) |
| `D` | Delete the current file (confirm) |
| `F` | Set the FileSpec filter |

### 2.4 Ctrl Commands (either pane)

Act on the current directory, or on every tagged file.

| Key | Action |
|---|---|
| `Ctrl-T` | Tag all files in this directory |
| `Ctrl-U` | Untag all files in this directory |
| `Ctrl-I` | Invert tags in this directory |
| `Ctrl-W` | Tag files matching a wildcard |
| `Ctrl-C` | Copy all tagged files (from all directories) to one destination |
| `Ctrl-V` / `Ctrl-L` | **View tagged** — read every tagged file in turn |
| `Ctrl-S` / `Ctrl-E` | **Search tagged** for text — untags every file that lacks it |
| `Ctrl-F` / `Ctrl-N` | **Find** files across the whole disk |
| `Ctrl-M` / `Ctrl-O` | Move all tagged files to one destination |
| `Ctrl-D` / `Ctrl-X` | Delete all tagged files |

Where two keys are shown, the first is real hardware and the second the emulator —
see [4.3](#43-emulator-vs-real-hardware). The menu shows whichever is live.

### 2.5 Alt Commands

ALT is the **Commodore (C=) key** on real hardware, the left Alt key in the emulator.

| Key | Pane | Action |
|---|---|---|
| `Alt-J` | either | **Jump to dir** — type a path and go there, logging every level on the way down (XTree's Treespec). Reaches folders never logged before, which is how you widen what Showall and Branch can see. `F2` picks from the tree. |
| `Alt-R` | either | **Release** — un-log the current folder, freeing the memory it holds |
| `Alt-T` | either | **Tag branch** — tag every logged file in this folder and below, without entering Branch view. Honours the FileSpec |
| `Alt-U` | either | **Untag all** — clear every tag on the disk |
| `Alt-F3` | either | **Re-log** the current context (sub-folders in the tree, files in the file pane) |
| `Alt-Q` | either | Quit, leaving the shell in the **currently selected** directory |
| `Alt-F10` | either | Open the color-theme setup (quits to `XFSETUP.PRG`) |
| `Alt-P` | directory | **Prune** — recursively delete the folder and everything under it |
| `Alt-S` | file | Cycle the sort order: name → extension → size |
| `Alt-X` | file | **Execute** — quit XFMGR and chain-run the selected program |

`Alt-U` deliberately ignores the FileSpec and the index row cap: after a Showall
session tags are spread across folders you are no longer looking at, and a tag you
cannot see is still a tag.

`Alt-S` **selects** an order rather than applying it — each tap advances the mode and
repaints the menu label, and the list re-sorts once, when ALT is released. Three taps
therefore cost one rebuild, not three.

### 2.6 The Input Line

Used by Copy, Move, Rename, Mkdir, FileSpec, Tag-spec and Find.

| Key | Action |
|---|---|
| `↑` | Pop up the recent-entry history for this prompt |
| `F2` | Open the directory picker (Copy/Move destinations) |
| `←` / `→` / `Home` | Move the cursor in the field |
| `Caps Lock` | Toggle capital-letter entry |
| `Enter` | Accept (saved to history) |
| `Esc` | Cancel |

In the **Find results** and **directory-picker** modals: `↑`/`↓` move, `Enter`
selects or jumps to the file, `Esc`/`Q` cancels; in the picker `+` expands (logging
on demand) and `−` collapses.

### 2.7 Tagging Files

XTree-style tag-and-advance. `T`/`U` tag one file and move on; `Ctrl-T`/`Ctrl-U`/
`Ctrl-I` tag, untag or invert a whole directory; `Ctrl-W` tags by wildcard; `Alt-T`
tags a whole branch and `Alt-U` clears every tag on the disk.

Tags are stored **on the file record**, not in the display list, so they survive
re-sorting, re-logging and moving between scopes. Tagging spans directories: a
`Ctrl-C` from a Showall gathers files from everywhere into one destination.

---

## 3. Feature Descriptions

### 3.1 Copying and Moving

`C`/`M` act on the highlighted file, or on every tagged file if any are tagged.
`Ctrl-C`/`Ctrl-M` always act on the full tagged set across all directories.

Destinations resolve from the **drive root** and can be typed or picked from the tree
with `F2`. A destination folder that does not exist is created. On a name collision
you are asked, with **All** and **Skip all** to answer once for the rest of the run.
Newly created destination folders are registered in the tree, so they appear without
a manual re-log.

### 3.2 Renaming

`R` renames the highlighted file, and supports `*` and `?` wildcards so a tagged set
can be renamed in one operation (`*.bak` → `*.old`). Directories are renamed with `R`
in the directory pane.

### 3.3 Searching Tagged Files by Content

`Ctrl-S` (hardware) / `Ctrl-E` (emulator) is the XTree working model: type a string,
and every tagged file that does **not** contain it is untagged. The tag set collapses
to the hits. Tag broadly, then search to narrow.

### 3.4 Sequential Viewing

`Ctrl-V` (hardware) / `Ctrl-L` (emulator) reads through the tagged files one after
another, starting at the first. `+` moves to the next tagged file and `−` back to the
previous — paging past the end also moves on — with a `File n/m` counter in the footer.

It pairs with the search above: narrow the tags, then read exactly what matched. Each
file opens **on its first hit** with the match highlighted, and `N`/`Space` walks the
hits and rolls straight into the next file when one file's hits run out, so a single
key carries you through every occurrence in the whole set.

### 3.5 Find File

`Ctrl-F` (hardware) / `Ctrl-N` (emulator) crawls the whole disk from the root and
logs **only** the directories that contain a match. Results appear in a flat modal
list you can jump straight into.

### 3.6 The Internal Viewer

`V` opens the full-screen text/hex viewer. Files too large for the pager fall back to
the ROM X16 Edit.

#### 3.6.1 Viewer Modes

| Mode | Notes |
|---|---|
| **Text** | Any file opens as text. Non-printable bytes show as `.` |
| **Hex** | `H` toggles a hex + ASCII dump, `H` again returns to text |
| **ZSM** | `.zsm` files are auto-detected and show a parsed header — version, tick rate, loop point, PCM, FM (YM) and PSG voices. `H` shows the raw bytes |

The encoding is **chosen from the file itself**. Text written through the KERNAL — a BASLOAD
source saved from BASIC, an MSEDIT buffer, a `.SEQ` file off a real disk — holds its letters as
PETSCII, and read as ASCII every one of them would come out as `.`; so the viewer counts the
letters that can only be PETSCII against the ones that can only be ASCII and opens the file in
whichever it is. The footer says which you got: `ISO` or `I PET`.

`I` overrides that guess in either direction. It is a display switch only — nothing is
re-encoded and the file is never written.

#### 3.6.2 Long Lines and Wrapping

`W` cycles how a line too long for the screen is laid out:

| Mode | Behaviour |
|---|---|
| **Wrap off** *(default)* | One file line = one screen row, cut at the right edge; `←`/`→` pan across it |
| **Wrap char** | Break anywhere, so every byte is on screen |
| **Wrap word** | Break at spaces, for prose |

Off is the default because it is the only mode that does not **invent line breaks the
file does not contain** — a wrapped line reads as two. Tabs expand to real 4-column
stops, so tab-indented source lines up as its author saw it.

Changing the mode keeps your place, but `PgUp` cannot go back past the point where you
changed it. Syntax coloring switches **off** while a line is panned sideways, and on
word-wrapped lines wider than the screen: in both cases the colors could not be placed
on the right characters, so they are left off rather than wrong.

#### 3.6.3 Syntax Coloring

BASIC/BASLOAD source (`.bas`, `.bas.txt`, `.basl`, `.bl`) and Markdown (`.md`) are
colored automatically. Statement keywords, built-in functions, strings, numbers and
`REM` / `##` comments each get their own color; a dotted BASLOAD label
(`DIR.READ.BIN`) stays plain, because it is one name.

`C` toggles coloring off and on. Switching back on uses the mode for the file's
extension, or BASIC if the extension was not recognised — so `C` also colors a listing
saved under any name. Requires `xsyntax.ovl`; without it the viewer shows plain text
and the `C` key is not offered.

#### 3.6.4 Navigation and Searching

`PgDn`/`PgUp` page, `T` jumps to the top and `B` to the bottom. `F` finds a string
(always from the top of the file) and `N`/`Space` repeats the search, wrapping back to
the top and reporting `wrapped to top` rather than stopping silently. `Q`/`Esc` exits.

The footer shows the active keys plus `Ofs $xxxxxx nn%` — the byte offset of what you
are looking at and how far into the file that is. When a find hit is on screen the
offset shown is the **hit's**, not the page top's, so it moves with every `N`.

### 3.7 Music Playback

`P` plays the highlighted file; the format is detected from its magic bytes.

| Format | Notes |
|---|---|
| **ZSM** | `.zsm` songs play through the **zsmkit** engine (FM + PSG + PCM). The whole song loads into free RAM banks, so a very large song may report `no free RAM banks` — release or re-log a folder to free some |
| **WAV** | Uncompressed PCM: 8- or 16-bit, mono or stereo, up to ~48 kHz. Compressed (ADPCM) wavs are not supported |

`Space` pauses and resumes; `Q`, `Esc` or `Stop` stops and returns. Requires
`zsmkit.bin` (ZSM) and `xmusic.ovl` (WAV); if either is missing, `P` reports it and
does nothing. `V` on a `.zsm` still shows the header breakout — `P` plays it.

### 3.8 Image Viewer

`V` on a `.bmx` bitmap sends it full-screen to the native BMX viewer; any key returns
to the file list. A `png2bmx` converter is included under `tools/`.

### 3.9 Color Themes

`Alt-F10` hands off to a standalone theme picker (`XFSETUP.PRG`) which remaps the
palette and saves the choice to `xfmgr.cfg`; XFMGR re-applies it at startup. A
re-install preserves an existing `xfmgr.cfg`, so a theme survives updates.

### 3.10 History Lists

Every text prompt remembers recent entries — `↑` opens the picker. History is stored
**per prompt category** under `hist/` on the drive root (`hist/copy.his`,
`hist/move.his`, …). Each ring keeps the most recent entries, newest first; the folder
is created on first save and missing files load silently as empty.

### 3.11 Launching Programs

`Alt-X` quits XFMGR and chain-runs the selected program, `chdir`-ing to its directory
first. The two quit paths differ deliberately: plain `Q` returns the shell to the
**launch** directory, `Alt-Q` to the **currently selected** one.

---

## 4. Installation

### 4.1 Installing

XFMGR2 ships as a folder of files plus a self-installer, `install.prg`. Unpack the
release folder onto your SD card, then on the X16:

1. `CD` into the unpacked folder (the one holding `install.prg` and the app files).
2. Run it: `/install*` (or `^install*`).
3. It creates `/xfmgr` on the drive root, stream-copies the program files into it, and
   writes a tiny `/xt` BASIC launcher at the root.

Then launch from anywhere with the caret-run command:

```
^/xt
```

The installer reports the release build number and, when `/xfmgr` already exists,
compares it against the installed build (older / newer / same). Press `T` at the
prompt for a dry run that does everything except copy files. Run it from a folder that
*is* `/xfmgr` and it skips the copy, only re-writing the `/xt` launcher. The install
folder can be deleted afterwards.

### 4.2 Folder Layout

Everything lives in one folder, with a tiny launcher in the drive root so you can
start it from anywhere:

```
/                     drive root
├── XT                one-line BASIC launcher  (LOAD "/XFMGR/XFMGR.PRG")
└── XFMGR/            everything else lives here
     ├── XFMGR.PRG        the main program
     ├── *.OVL            banked overlays (viewer, image, music, ui, misc, syntax)
     ├── XFSETUP.PRG      the color-theme setup (Alt-F10)
     ├── ZSMKIT.BIN       the ZSM music engine
     ├── XFMGR.HLP        the help file
     └── XFMGR.CFG        your saved theme (kept across updates)
```

XFMGR always presents the tree rooted at `/`, so you can roam the whole drive no
matter where you started it.

### 4.3 Emulator vs Real Hardware

**Kernal R49 or newer is required** — XFMGR refuses to launch on older ROMs because it
depends on R49+ behaviour, notably the X16 Edit ROM API behind the `E` command.

At startup it detects the emulator (`emudbg.is_emulator()`) and rebinds the CTRL
commands the emulator window grabs before they reach the app. The CTRL menu always
shows the binding that is live.

| Command | Real hardware | Emulator |
|---|---|---|
| Delete tagged | `Ctrl-D` | `Ctrl-X` |
| Find files | `Ctrl-F` | `Ctrl-N` |
| Move tagged | `Ctrl-M` | `Ctrl-O` |
| Search tagged | `Ctrl-S` | `Ctrl-E` |
| View tagged | `Ctrl-V` | `Ctrl-L` |

Tag-by-wildcard is `Ctrl-W` in both. **ALT is the Commodore (C=) key** on a real X16
and the left Alt key in the emulator. Everything else — plain keys, function keys,
arrows — behaves identically.

---

## 5. Implementation Notes

### 5.1 The Memory Model

The hard constraint on the X16 is RAM: ~40 KB main, plus 8 KB-windowed banked RAM
(banks at `$A000–$BFFF`, up to 2 MB). A 16-bit pointer cannot cross the bank window, so
the design splits data by **access pattern** — redraw-hot data stays in main RAM; cold,
bulky data and cold *code* live in banked RAM behind far pointers and bank overlays.

### 5.2 Bank Map

The stock machine has banks 0–63. The low banks are reserved:

| Bank | Holds |
|---|---|
| 0 | Kernal |
| 1 | tree dir-extras (cold per-node fields) |
| 2–5 | `tview`, `miscutil`, `uiutil`, `ximgview` overlays |
| 6 | `zsmkit` music engine |
| 7 | `xmusic` overlay |
| 8 | directory-name slab |
| 9 | `xsyntax` overlay |
| 10–11 | the file index (2048 × 8-byte rows) |
| 12+ | the file arena, growing to the detected top bank |

### 5.3 Modules

| Module | Lives in | Holds | Why |
|---|---|---|---|
| `xarena.p8` | banks 12+ | append-only bump allocator (~7.8 KB usable per bank) | files are numerous and append-only, then bulk-freed on rescan; no per-record header, no fragmentation |
| `xtree.p8` | main RAM (names in bank 8) | directory tree — a byte-indexed node pool (`DIR_MAX = 254`, `NONE = 255`), links/flags/depth | few dirs, redrawn on every keystroke; the hot node pool stays in main RAM while the cold name bytes are banked |
| xtree **dir-extras** | bank 1 | per-node cold fields (file count/offset/bank, tag count) | never touched in the per-row redraw loop; bank 1 is never disturbed by an arena reset |
| `xfiles.p8` | arena + banks 10–11 + main RAM | length-prefixed file records in the arena; the display index as 2048 8-byte rows (far pointer + owning dir + 4-char sort key) | a 2048-row index would be 8 KB of main RAM it does not have; the shell sort decides most comparisons from the inline key without re-reading a name |
| `xscan.p8` | main module | on-demand logger + scratch paths | drives diskio's one-listing-at-a-time rule: subdirs → tree, files → arena |
| `tview.ovl` | bank 2 | text/hex pager, page-offset table, read buffer | read-only viewer with in-file search; larger files hand off to X16 Edit |
| `miscutil.ovl` | bank 3 | wildcard-rename expander, prune engine, history ring, copy byte-pump, Find crawler | self-contained cold helpers; their path/copy buffers cost no main RAM |
| `uiutil.ovl` | bank 4 | bottom-banner dialogs, modal borders, the command menu, About | dialog *drawing* is cold; main keeps thin wrappers that `JSRFAR` in |
| `ximgview.ovl` | bank 5 | native BMX bitmap loader/displayer | image decode is bulky and rarely used |
| `xmusic.ovl` | bank 7 | `.wav` PCM streaming player (AFLOW-driven) | audio streaming is cold and self-contained |
| `xsyntax.ovl` | bank 9 | syntax classifier, viewer footer, ZSM header page | called by `tview`, which is full to the byte |
| `xfmgr.p8` | main module | TUI + key loop, file ops, prompts, screen helpers | dual-pane draw, tagging, all `op_*` operations |

`xfsetup.p8` builds to a **separate** `XFSETUP.PRG` (a full `$0801` program, not an
overlay) — the `Alt-F10` theme picker; `themes.p8` does the palette remap and
reads/writes `xfmgr.cfg`.

### 5.4 Key Design Decisions

- **A bump/arena allocator, not malloc/free** — file data is written in one
  append-only pass per directory and bulk-freed on rescan, so a bump pointer with no
  per-record header beats a general heap. Individual records are never reclaimed; dead
  space is only recovered on a full reset.
- **Index arrays, not pointer-chasing lists** — a 16-bit pointer cannot span the bank
  window, so the tree uses byte indices (`NONE = 255`) and files use `(bank, offset)`
  far pointers.
- **Cold code in bank overlays** — rarely-hit paths (viewer, dialogs, image decode,
  wildcard/prune/history/Find helpers) live in HIRAM overlays reached via
  `extsub @bank`, freeing main RAM for the redraw-hot tree, file index and key loop.
- **One index for every file list** — a directory listing, a scoped view and the Find
  results are three views of the same records, so they share one banked index rather
  than three parallel tables.
- **Editor bank handoff** — `op_edit` finds X16 Edit in ROM, refuses if there is no
  free bank above the arena, then calls it with `firstbank = high_bank + 1` and
  `lastbank = max_bank` (the machine's real top bank, never `255`) so the editor cannot
  clobber cached records or run off the installed RAM.

### 5.5 Startup and Persistence

At startup XFMGR captures the launch folder (`diskio.curdir()`) before any disk call
can clobber it, loads the overlays into their reserved banks, applies the saved color
theme, then descends the tree from root — logging and expanding each level so the
launch folder is pre-selected and visible.

Because navigation is root-relative, copy/move destinations resolve from the drive
root. The color theme lives in `xfmgr.cfg` beside the program; input history lives
under `hist/` on the drive root.

### 5.6 Build and Run

Requires **Java** (JRE) and the **64tass** assembler (v1.60); their paths are baked
into `build.bat`, which drives the bundled `prog8c.jar` Prog8 compiler:

```
build.bat xfmgr.p8        # -> build\xfmgr.prg + the .ovl overlays + xfsetup.prg
```

Building `xfmgr.p8` also compiles its companions:

- **six banked overlays** — `tview.ovl`, `miscutil.ovl`, `uiutil.ovl`, `ximgview.ovl`,
  `xmusic.ovl` and `xsyntax.ovl`. Each is a headerless `%output library` loaded into a
  reserved HIRAM bank at runtime (the build renames prog8's `.bin` to `.ovl`).
- **`xfsetup.prg`** — the standalone color-theme picker launched by `Alt-F10`.
- **`install.prg`** — the standalone self-installer (see [4.1](#41-installing)).

All compiler output (`.prg`, `.ovl`, and the intermediate `.asm` / `.vice-mon-list`)
goes to a gitignored `build\` folder. Static assets that are *not* built —
`xfmgr.hlp`, `zsmkit.bin` and the default `xfmgr.cfg` — stay at the root.

The build prints a memory-stats block: image size, BSS/slab, main-RAM high-water, free
low RAM below `$9F00`, and the on-disk `.prg` size. Banked HIRAM is not counted — it
holds the overlays and the growing file arena.

```
run.bat                   # build + stage + launch in the emulator
```

`run.bat` stages the built program and overlays into `run/xfmgr/`, copies sample
images into the browse root, and launches the emulator from a clean `run/` folder as
the host filesystem root. `-ram 512` pins the machine to 512 KB (banks 0–63) to
exercise bank detection; `-rtc` drives the live clock and `-joy1` enables joystick
input.

---

## 6. Status and Limits

**Working.** Dual-pane navigation, on-demand logging, cross-directory tagging, scoped
file views (Showall / Branch / Global), tagged-file content search and sequential
viewing, whole-disk Find, sorting, the full file-operation set (copy / move / rename /
delete / mkdir / prune), the banked text/hex viewer with wrap modes and syntax
coloring, the BMX image viewer, `.zsm`/`.wav` playback, edit via X16 Edit,
execute-and-return, switchable color themes, root-anchored startup and persistent
input history — with confirmation prompts on destructive actions and status banners
for errors.

Known limits:

- **No recursive whole-disk logging.** Directories are logged on demand; only `Find`
  crawls the whole disk, and it logs solely the directories containing a match.
- **Append-only arena.** Individual file records are never freed; dead space from
  refreshes and renames accumulates and is reclaimed only on a full reset/reload.
- **Fixed capacity caps.** `DIR_MAX = 254` directories, and 2048 rows in the file
  index — the cap on a single directory's listing, a scoped view and a Find result set
  alike (excess is marked `(partial)`) — plus a bounded directory-name slab.
- **Single drive.** All operations are relative to one mounted drive; there is no
  multi-volume or `.d64` image support, which is why `G` (Global) matches `S`.
- **No archive support.** Browsing inside `.zip`/`.arc` is not implemented.

---

## Credits

© 2025-26 sadLogic, JakeInErope — written in Prog8 with help from AI.
Thanks to the many Discord members keeping this cool retro computer alive.
