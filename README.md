# XFMGR2 — an XTree-style file manager for the Commander X16 (Prog8)

A dual-pane, keyboard-driven file manager in the spirit of XTree/XTreeGold:
a collapsible **directory tree** on the left, the selected directory's **files**
on the right, with file **tagging** and a built-in **viewer**.  

<img width="802" height="633" alt="image" src="https://github.com/user-attachments/assets/817859a9-4dc9-4e4c-bc4a-76ed56dec40f" />


## Build & run

Requires Java and the 64tass assembler (paths are baked into `build.bat`):

```
build.bat xfmgr.p8        # -> xfmgr.prg
```

Run in the emulator from a folder that contains files to browse (the emulator uses
its working directory as the X16 host filesystem):

```
x16emu -prg xfmgr.prg -run
```

Keys: `TAB`/`←`/`→` switch pane · `↑`/`↓` move · `Enter` log/expand/collapse a
directory · `T` tag · `U` untag · `V` view file · `Q` quit.

## Architecture (the memory model)

The hard constraint on the X16 is RAM: ~40 KB main, plus 8 KB-windowed banked RAM
(banks at `$A000–$BFFF`, up to 2 MB). A 16-bit pointer can't cross the bank window,
so the design splits data by access pattern:

| Module | Lives in | Holds | Why |
|---|---|---|---|
| `xarena.p8` | banked RAM | bump allocator | files don't fit in main RAM (~640 cap); ~400/bank |
| `xfiles.p8` | banked RAM | file records | append-only, length-prefixed, bank-roll sentinels |
| `xtree.p8` | main RAM | directory tree | few dirs, redraw-hot; byte-indexed node pool (no pointers) |
| `xscan.p8` | — | on-demand logger | drives diskio listing: subdirs→tree, files→arena |
| `xfmgr.p8` | — | TUI + key loop | dual-pane draw, tagging, viewer |

Key decisions: a **bump/arena allocator**, not malloc/free (XTree's data is
append-only then bulk-freed); **index arrays**, not pointer-chasing linked lists
(pointers can't span banks). `test_arena.p8` verifies the allocator across a real
3-bank spill.

## Status

**v1 (navigator): working.** Logs directories on demand, dual-pane navigation,
tagging, text viewer.

**Deferred to v2:** recursive whole-disk logging, ShowAll + global cross-directory
tagging, file sorting, file operations (copy/move/delete/rename), in-pane scroll polish.
