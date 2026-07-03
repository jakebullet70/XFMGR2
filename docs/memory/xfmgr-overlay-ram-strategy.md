---
name: xfmgr-overlay-ram-strategy
description: How XFMGR frees main RAM by moving code into bank overlays, current bank map, and what's left to move
metadata:
  type: project
---

XFMGR is main-RAM constrained; the lever for headroom is moving cold code into HIRAM bank
overlays (%output library blobs, org $A000, loaded via diskio.loadlib, called via `extsub @bank`).

**Bank map** (see [[x16-banked-ram-min-config]], xarena.FIRST_BANK): 0=Kernal, 1=xtree dir-extras,
2=tview (viewer), 3=miscutil (wildcard/prune/history + stream_copy byte-pump), 4=uiutil (bottom
dialogs + About/modal-box drawing). Arena = banks 5..max_bank. Each overlay keeps a fixed
`%jmptable` at $A003+ (KEEP module vars UNINITIALIZED or they shove the table — see
[[prog8-jmptable-init-vars-gotcha]]).

**As of 2026-07-03: 5.9 KB free to $9F00** (was ~2.2 KB before this push). Won by: copy byte-pump
-> miscutil.stream_copy (+deleted viewbuf), and the whole confirm/banner/prompt + About UI ->
uiutil (+~2.9 KB).

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

**Backlog / still movable:** command menu (draw_commands + menu_* + labels, ~0.3 KB) is the last
easy one. input_line/hist_popup (~2 KB) are BLOCKED - input_line calls pick_dir (deep xtree),
which the overlay can't call back into. print_trunc / hilite_row stay (hot draw paths).
