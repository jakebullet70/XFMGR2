; XFMGR2 - an XTree-style file manager for the Commander X16.  v1: navigator.
;
;   Left pane  : collapsible directory tree (main-RAM index pool, xtree)
;   Right pane : files of the selected directory (banked arena, xfiles/xarena)
;
; Directories are LOGGED on demand: press Enter on a directory to scan it.
; Keys:  TAB / left / right  switch pane     up / down  move
;        Enter (tree)  log / expand / collapse
;        T tag   U untag   V view   Q quit

%import textio
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header
%import strings
%import conv               ; str_l only: BCD long->decimal for the blocks total (see box_append_long)
%import xarena
%import xtree
%import xfiles
%import xscan
%import hlprs
%import emudbg
%import themes
%import "shared-const"
%zeropage basicsafe
%option no_sysinit

main {
    ; --- framed XTree-style screen layout (screen mode $01 = 80x30) ----------
    ;  row 0  : top border          row 1  : Path + disk stats header
    ;  row 2  : titled divider (DIRECTORY | FILE)
    ;  3..26  : pane content        row 27 : divider
    ;  row 28 : command menu        row 29 : bottom border
    const ubyte SCREEN_MODE = $01       ; 80x30 text
    const ubyte SPLIT    = 36           ; column of the vertical divider
    const ubyte HDRROW   = 1
    const ubyte PANE_TOP = 3
    const ubyte PANE_BOT = 25
    const ubyte PANE_H   = PANE_BOT - PANE_TOP + 1
    const ubyte DIVBOT   = 26           ; lower divider row
    const ubyte CMDROW1  = 27           ; command menu line 1: plain keys
    const ubyte CMDROW2  = 28           ; command menu line 2: CTRL keys
    const ubyte MSGROW   = 27           ; prompts reuse the first command row
    const ubyte SCR_BOT  = 29           ; bottom border row
    const ubyte BUILD_NUM = 240       ; shown top-right; bump by 1 every build. Keep the About
                                         ; 1.0.N" string in uiutil.p8 in sync with this.
    const ubyte BANNER_LEFT = 2         ; left margin for ALL bottom-banner text (prompts, messages,
                                        ; confirmations) - two white columns, text from col 2

    ; tree pane interior columns
    const ubyte TREE_MARK = 1           ; focus marker column
    const ubyte TREE_TEXT = 2           ; first text column
    const ubyte TREE_BAR_R = SPLIT - 1  ; bar / right edge
    ; file pane interior columns
    const ubyte FILE_MARK = SPLIT + 1
    const ubyte FILE_TEXT = SPLIT + 2
    const ubyte FILE_SIZE = 72          ; size column
    const ubyte FILE_BAR_R = 78
    const ubyte FILE_HDR  = PANE_TOP        ; NAME / SIZE column header row
    const ubyte FILE_TOP  = PANE_TOP + 1    ; first file row
    const ubyte FILE_VIS  = PANE_BOT - FILE_TOP + 1

    const ubyte FOCUS_TREE = 0
    const ubyte FOCUS_FILE = 1

    ; selection bar / box colors now live in SRC/shared-const.p8 (block `shared`),
    ; shared with the tview overlay. Referenced below as shared.CLR_FG, shared.HILITE, etc.

    ; box-drawing SCREENCODES (drawn with setchr so the cursor never moves / scrolls)
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'
    const ubyte SC_JL = sc:'├'
    const ubyte SC_JR = sc:'┤'
    const ubyte SC_JT = sc:'┬'
    const ubyte SC_JB = sc:'┴'

    ; Menu/footer key glyphs are typed straight into the petscii:"" strings that draw them
    ; (the X16 has no CP437): ←=$5f + ┘=$fd form the ENTER/return symbol "←┘"; ↑=$5e is the
    ; up-arrow. Color is likewise embedded (\x9e=accent \x05=fg) - see the memory note on
    ; embedded PETSCII color codes. No named glyph consts needed any more.

    ubyte focus
    ubyte tree_cursor, tree_top
    uword file_cursor, file_top     ; uword: the file index holds up to xfiles.INDEX_MAX rows

    ; File-pane geometry. Variables, not constants, because a scoped listing (Showall) hides the
    ; tree and gives the file list the WHOLE width - XTree's Expanded File Window. Everything that
    ; paints a file row reads these, so there is one renderer rather than a normal one and a
    ; scoped one. set_pane_geometry() is the only writer.
    ubyte pane_mark_col                 ; column of the '>' / '*' markers (name starts 2 further in)
    ubyte pane_name_w                   ; how many characters of the filename fit before the size
    ubyte cur_dir
    ubyte start_node                    ; tree node of the launch directory (selected at startup)
    long cur_blocks                     ; total blocks of everything the file header reports.
                                        ; 32-bit: one directory fits a uword, but a whole-disk
                                        ; scope does not - 65535 blocks is only ~16 MB.
    ubyte saved_mode                    ; screen mode to restore on exit
    ubyte saved_charset                 ; pre-launch charset (2=upper/gfx 3=lower); restored on exit

    ; --- CAPS LOCK: off for the session, restored on exit ---
    ; This is a FUNCTIONAL fix, not a cosmetic one: with caps lock on, the ALT and CTRL command
    ; keys stop working. ALT+letter already returns a graphics code rather than the letter, and
    ; caps shifts what the keyboard reports again on top of that, so the when-blocks that dispatch
    ; those menus no longer match. Typed text (filenames, search terms, wildcards) also comes out
    ; uppercase. Folding at the input sites would fix the text but NOT the command keys, so the
    ; machine state itself has to change.
    ;
    ; The KERNAL gives us a documented way to READ caps - kbdbuf_get_modifiers() bit 4 - but NONE
    ; to clear it: the kbd_leds extapi drives only the LED and says outright that it "does not
    ; change the state of the kernal's caps lock toggle". The toggle itself is the KERNAL's shflag
    ; byte, which lives in RAM BANK 0 (the memory map marks $A000-$BEFF there "System Reserved").
    ; Its address is NOT part of any published API and could move in a future ROM - so caps_off()
    ; proves it is the right byte before writing. See caps_off() for that check.
    const uword KBD_SHFLAG = $a80c      ; KERNAL shflag, in RAM bank 0 (undocumented - verified at runtime)
    const ubyte MOD_CAPS   = $10        ; shflag / kbdbuf_get_modifiers bit 4 = caps lock
    bool caps_was_on                    ; true = caps was on at launch AND we cleared it -> restore on exit
    bool upper_mode                     ; SOFTWARE Caps Lock for the line editor: fold typed letters to
                                        ; capitals at INSERT time (display), normalized back to ASCII on
                                        ; ENTER. Toggled by the Caps Lock key in input_key; the KERNAL
                                        ; caps toggle stays OFF (it breaks the Alt/Ctrl menus - caps_off).
    ubyte saved_color                   ; pre-launch text color (bg<<4|fg); restored on exit

    ; per-keystroke "what changed" flags, so we repaint only the affected regions
    ; (e.g. moving in the file column never touches the directory column). The *_cur
    ; flags are the LIGHT variant: a pure cursor move that only re-inks two rows (old +
    ; new) instead of repainting the whole pane - unless the view scrolled (then full).
    bool dirty_tree, dirty_files, dirty_status, dirty_cmd, dirty_full
    bool dirty_tree_cur, dirty_file_cur

    ; cursor / scroll position last PAINTED, so a light update knows which row to un-ink
    ; and whether the pane scrolled since (top changed -> fall back to a full repaint)
    ubyte tree_cursor_shown, tree_top_shown
    uword file_cursor_shown, file_top_shown

    const ubyte MOD_CTRL = $04              ; kbdbuf_get_modifiers bit: 1=shift 2=alt 4=ctrl
    const ubyte MOD_ALT  = $02
    ; which command menu is currently displayed, driven by the held modifier:
    ; 0 = MENU (no modifier), 1 = CTRL, 2 = ALT.  Keys are dispatched by this mode, so
    ; ALT works exactly like CTRL (hold the modifier, then press the command letter).
    ubyte menu_mode
    ; one shared keystroke scratch reused by every modal/dispatch loop (each read-and-
    ; dispatches its key immediately, so they never need their own copy). Saves a byte
    ; per routine since prog8 allocates each local statically.
    ubyte g_key
    ; likewise a shared loop counter, reused by NON-OVERLAPPING for-loops. Safe only in
    ; "leaf" loops: body calls no other main sub (external txt/xtree/... calls can't touch
    ; main.g_ndx) and no nested loop, so nothing clobbers it mid-iteration. See draw_box.
    ubyte g_ndx
    bool run_exit                           ; Alt-X set: quit XFMGR and run a program
    bool do_quit                            ; Alt-Q set: quit (exit_dir already chosen)
    bool setup_exit                         ; Alt-F10 set: quit XFMGR and run the theme setup PRG
    ; directory the host shell is left in on a normal quit: the startup dir for the
    ; main-menu Quit, or the currently selected dir for the ALT-menu Quit.
    ; (uword alias into cm_src storage - declared in the modal-buffer overlay below)

    ; "delete tagged" CTRL key. The emulator swallows Ctrl-D ($04) before it reaches
    ; us, so under the emulator we bind delete to Ctrl-X; on real hardware Ctrl-D is
    ; free, so we use the classic XTree Ctrl-D there. Set once at startup.
    ubyte del_key                           ; lowercase dispatch key: 'x' (emu) or 'd' (hw)
    ubyte del_char                          ; uppercase display char: 'X' or 'D'

    ; "find files" CTRL key. Same story: the emulator swallows Ctrl-F before it reaches us,
    ; so under the emulator we bind Find to Ctrl-N (fiNd); on real hardware Ctrl-F is free.
    ubyte find_key                          ; lowercase dispatch key: 'n' (emu) or 'f' (hw)
    ubyte find_char                         ; uppercase display char: 'N' or 'F'

    ; "move tagged" CTRL key. Same story: the emulator grabs Ctrl-M, so under the emulator we bind
    ; Move to Ctrl-O (mOve); on real hardware Ctrl-M reaches us ($0D, folded to 'M' by wait_command).
    ubyte move_key                          ; lowercase dispatch key: 'o' (emu) or 'm' (hw)
    ubyte move_char                         ; uppercase display char: 'O' or 'M'

    ; "search file contents" CTRL key (XTree's Ctrl-S). The emulator swallows Ctrl-S too, so under
    ; the emulator we bind Search to Ctrl-E (sEarch); on real hardware Ctrl-S is the classic key.
    ubyte srch_key                          ; lowercase dispatch key: 'e' (emu) or 's' (hw)
    ubyte srch_char                         ; uppercase display char: 'E' or 'S'

    ; "view tagged files in turn" CTRL key (XTree's Ctrl-V). The emulator eats Ctrl-V as its PASTE
    ; shortcut, so under the emulator we bind it to Ctrl-L (Look). L was picked deliberately: several
    ; control codes collide with this app's raw navigation keys (Ctrl-B = $02 = PgDn, Ctrl-Q = $11 =
    ; cursor-down), while Ctrl-L is $0C - no collision, not otherwise used.
    ubyte view_key                          ; lowercase dispatch key: 'l' (emu) or 'v' (hw)
    ubyte view_char                         ; uppercase display char: 'L' or 'V'

    ; The X16 maps ALT to the Commodore (graphics) key, so ALT+letter returns a
    ; PETSCII graphics code in $A1..$BF (161..191) instead of the letter. This table
    ; maps each of those codes (indexed by code-161) back to its base letter, so the
    ; ALT command handler can keep matching on plain 's','x',...  0 = not a letter.
    ; (Verified: ALT+S delivers 174 = $AE = Commodore-S.)
    ubyte[31] alt_letter = [
        'k','i','t', 0 ,'g', 0 ,'m', 0 , 0 ,'n','q','d','z','s','p',
        'a','e','r','w','h','j','l','y','u','o', 0 ,'f','c','x','v','b' ]

    ; last content-search term (Ctrl-S/Ctrl-E), kept so the tagged-file walk can hand it to the
    ; viewer and every file opens ON its first hit. Needs its OWN storage, not one of the cold
    ; modal-buffer slots: it has to survive from the search until a later Ctrl-V, and a copy/move
    ; or Find in between would clobber any shared slot. Cleared when a search finds nothing to do.
    str srch_term = "?" * 32
    str namebuf = "?" * 52
    str pathbuf = "?" * 80
    str inputbuf = "?" * 84             ; holds typed text or a picked directory path
    str treeline = "?" * 48             ; composed tree row (connectors + name)
    ubyte[20] levlast                   ; per-depth: is the ancestor a last child?
    ; sa_line moved into the modal-buffer overlay below (shares cm_src storage)

    ; shared "press any key" footer text (Prog8 has no const str; this str is never
    ; written). Reused by the About box and the 2-line completion banners.
    str MSG_PRESS_ANY_KEY = " Press any key "
    str MSG_ERR_COMMA     = "Can't rename: comma in name"   ; shared by both rename paths (file + dir)

    ; copy/move scratch: source & dest directory paths, and full file paths. These str buffers
    ; double as the shared home for the cold modal buffers overlaid just below.
    str cm_sdir = "?" * 80                  ; Slot B (81 B)
    str cm_ddir = "?" * 80                  ; Slot C (own; also holds the saved FileSpec during Find)
    str cm_src  = "?" * 132                 ; Slot A (133 B)
    str cm_dst  = "?" * 132                 ; hot header/banner compose - NOT shared

    ; --- cold modal-buffer overlay (saves ~215 B main RAM) --------------------------------------
    ; Each guest is a uword pointer ALIASING a copy/move scratch buffer's storage - it owns no bytes
    ; of its own. Safe because each guest is only ever live inside one modal op that never overlaps
    ; its host's use (or a same-slot sibling's); coexistence verified in the RAM-cleanup plan.
    ; Only LIGHTLY-accessed guests are overlaid: pointer indirection adds code, so heavily-used
    ; buffers (inputbuf, hist_line) are left as their own storage - they'd cost more code than saved.
    ; INVARIANT: do NOT add a use of a guest that can be live at the same time as its host or a
    ; sibling on the same slot - they share physical bytes and would silently corrupt each other.
    ; Slot A (cm_src, 133 B): sa_line, exit_dir, syn_line
    uword sa_line  = &cm_src                ; composed ShowAll/Find results row (path + name)
    uword exit_dir = &cm_src                ; dir the host shell is left in on quit
    ; The viewer's syntax-coloring line + color buffers. These MUST be main RAM: tview (bank 2)
    ; fills syn_line, then JSRFARs into xsyntax (bank 9) to fill syn_col - and neither bank can see
    ; the other's RAM, while main RAM stays mapped below $A000 throughout. Aliasing the copy/move
    ; scratch costs zero new bytes and is safe by the slot rule above: V is a top-level file-pane
    ; command, so no copy/move (nor ShowAll/Find) can be in flight while the viewer owns the screen.
    uword syn_line = &cm_src                ; one logical source line, <= SYN_LINE_MAX bytes
    uword syn_col  = &cm_dst                ; one color attribute byte per column (first cm_dst guest)
                                            ; cap = shared.SYN_LINE_MAX (128), well inside both 133 B hosts
    ; Slot B (cm_sdir, 81 B): find_lc
    uword find_lc  = &cm_sdir               ; Ctrl-F lowercased filespec (whole-disk crawl)
    ubyte cm_fail                           ; copy_one failure point: 0 ok/none, 1 src-open, 2 dst-open, 3 write
    ubyte cm_wstat                          ; DOS status code captured when a write fails (diagnostic)
    ubyte ow_mode                           ; overwrite policy for the current copy/move batch:
                                            ; 0 = ask on each conflict, 1 = overwrite all, 2 = skip all

    ; shared text-input history (XTreeGold): the last 10 accepted entries per prompt category,
    ; newest first. UP-arrow in any input pops up a scrollable picker. The ring buffer + its ops
    ; (store/load/save) now live in the miscutil overlay (bank 3) to save ~500 B of main RAM -
    ; see the hist_* extsubs. Main keeps only a cached count (for the "any history?" check and the
    ; picker geometry) and a one-entry scratch line the picker fills from the overlay via hist_get.
    ubyte hist_count                        ; cached copy of the overlay's ring count (0..10)
    ubyte[50] hist_line                     ; picker's receive buffer for one ring entry (<=49 + NUL)
    str VIEWFIND_CAT = "viewfind"           ; history category for the viewer's in-file Find prompt -
                                            ; its OWN ring, separate from Ctrl-F find-file's "find"

    ; --- banked file viewer (tview) overlay ---
    ; tview.p8 is compiled as a %output library headerless blob (org $A000) and loaded into
    ; reserved HIRAM bank 2 (VIEW_BANK) at startup. extsub @bank wraps each call in JSRFAR,
    ; mapping the bank around it. $A000 = library init (jmp start); $A003 = view_file entry.
    const ubyte VIEW_BANK = 2
    extsub @bank 2 $A000 = tview_init()
    extsub @bank 2 $A003 = view_file(uword nameptr @R0, ubyte histcount @R1, ubyte setmode @R2, uword termptr @R3, ubyte setnum @R4, ubyte settot @R5, uword blocks @R6) -> ubyte @A
    ; $A006 hands tview the syntax-coloring setup: whether xsyntax.ovl loaded, and the two
    ; MAIN-RAM buffers the two overlays share. They must be main-RAM (not in either bank),
    ; because while bank 9 is mapped tview's own bank-2 RAM is invisible - see SYN_BANK below.
    extsub @bank 2 $A006 = view_set_syn(ubyte ok @R0, uword lineptr @R1, uword colptr @R2)
    bool viewer_ok                          ; tview.ovl loaded OK -> V uses the banked viewer

    ; --- banked syntax-coloring overlay (xsyntax) ---
    ; xsyntax.p8 is a %output library blob in reserved HIRAM bank 9. UNLIKE every other overlay
    ; here it is NOT called by main - tview (bank 2) JSRFARs into it once per rendered line. That
    ; is legal: the X16 KERNAL's JSRFAR "works independently of which RAM or ROM bank the currently
    ; executing code is residing in" (X16 Reference - 05 - KERNAL, $FF6E). Main only LOADS it and
    ; reports the result to tview via view_set_syn; the extsub decls for its entries live in
    ; tview.p8. It lives in its own bank because bank 2 has ~424 bytes free and this needs ~1.8 KB.
    const ubyte SYN_BANK = 9
    extsub @bank 9 $A000 = xsyntax_init()
    bool syn_ok                             ; xsyntax.ovl loaded OK -> the viewer can color

    ; --- banked BMX image viewer (ximgview) overlay ---
    ; ximgview.p8 is a %output library blob loaded into reserved HIRAM bank 5. It displays a
    ; native X16 "BMX" bitmap file full-screen and returns to text mode on any key. $A000 = init;
    ; $A003 = view_image entry. V dispatches here when the selected file's name ends in ".bmx".
    const ubyte IMG_BANK = 5
    extsub @bank 5 $A000 = ximgview_init()
    extsub @bank 5 $A003 = view_image(uword nameptr @R0)
    bool imgview_ok                         ; ximgview.ovl loaded OK -> V shows .bmx images

    ; --- banked ZSM music engine (zsmkit v2, release 2.8) ---
    ; zsmkit.bin is a pre-built library blob (mooinglemur/zsmkit) loaded at $A000 into reserved
    ; HIRAM bank 6; its jump table is fixed at $A000, $A003, ... Only main calls it, and P
    ; dispatches here for a .zsm.
    ; (NB: "a banked overlay cannot @bank-call a different bank" used to be asserted here and is
    ; NOT true in general - JSRFAR is bank-agnostic and tview->xsyntax relies on that; see
    ; SYN_BANK above. Keep zsmkit main-driven anyway: it is an external blob and its engine state
    ; and low-RAM scratch are managed from here.)
    ; The engine needs a ~255-byte low-RAM scratch: we hand it golden RAM $0400, but
    ; X16 Edit also uses $0400-$07FF, so we re-init at the top of EVERY play_zsm (not once).
    const ubyte ZSM_BANK   = 6
    const uword ZSM_LOWRAM = $0400
    extsub @bank 6 $A000 = zsm_init_engine(uword lowram @XY) clobbers(A,X,Y)
    extsub @bank 6 $A003 = zsm_tick(ubyte type @A) clobbers(A,X,Y)
    extsub @bank 6 $A006 = zsm_play(ubyte prio @X) clobbers(A,X,Y)
    extsub @bank 6 $A009 = zsm_stop(ubyte prio @X) clobbers(A,X,Y)
    extsub @bank 6 $A00F = zsm_close(ubyte prio @X) clobbers(A,X,Y)
    extsub @bank 6 $A01B = zsm_setbank(ubyte prio @X, ubyte bank @A)
    extsub @bank 6 $A01E = zsm_setmem(ubyte prio @X, uword data_ptr @AY) clobbers(A,X,Y)
    extsub @bank 6 $A02A = zsm_getstate(ubyte prio @X) clobbers(X) -> bool @Pc, bool @Pz, uword @AY
    bool zsm_ok                             ; zsmkit.bin loaded OK -> P plays .zsm

    ; --- banked WAV player overlay (xmusic) ---
    ; xmusic.p8 is a %output library blob loaded into reserved HIRAM bank 7. It streams an
    ; uncompressed PCM .wav straight to VERA's audio FIFO (poll-AFLOW) and returns when the file
    ; ends or the user quits. $A000 = init; $A003 = play_wav (0=ok/stopped 1=open-err 2=unsupported).
    const ubyte MUS_BANK = 7
    extsub @bank 7 $A000 = xmusic_init()
    extsub @bank 7 $A003 = play_wav(uword nameptr @R0) -> ubyte @A
    bool music_ok                           ; xmusic.ovl loaded OK -> P plays .wav

    ; --- banked misc-utility overlay (miscutil) ---
    ; miscutil.p8 is a second %output library blob loaded into reserved HIRAM bank 3 at
    ; startup; it holds self-contained helpers moved out of main RAM (the wildcard rename
    ; expander, the recursive directory-prune engine, and the input-history ring). $A000 = init;
    ; $A003 = wildcard_expand(orig @R0, pat @R1, out @R2);
    ; $A006 = prune_dir(parent @R0, name @R1) -> ubyte, ONE dir/call (0=done, 1=more, 255=err);
    ; $A009 = hist_load(cat @R0, instdir @R1) -> count; $A00C = hist_store(str @R0) -> count;
    ; $A00F = hist_save(cat @R0, instdir @R1); $A012 = hist_get(slot @R0, out @R1);
    ; $A015 = stream_copy(src @R0, dst @R1) -> uword (lsb=fail 0/1/2/3, msb=DOS code).
    const ubyte MISC_BANK = 3
    extsub @bank 3 $A000 = miscutil_init()
    extsub @bank 3 $A003 = wildcard_expand(uword origptr @R0, uword patptr @R1, uword outptr @R2)
    extsub @bank 3 $A006 = prune_dir(uword parptr @R0, uword nameptr @R1) -> ubyte @A
    ; history ring lives in the overlay; main caches the count returned by load/store. cat is the
    ; category name; instdir is the ABSOLUTE install folder, which main resolves with
    ; themes.progdir_cd() - the overlay can't reach themes, and it must NOT assume /xfmgr (it used
    ; to chdir base + "xfmgr", which broke anywhere else). It appends "hist" itself, relatively,
    ; because that subfolder has to be creatable with CMDR-DOS's MD. The picker reads slots via
    ; hist_get into hist_line. If misc_ok is false, input_line skips history entirely.
    extsub @bank 3 $A009 = hist_load(uword cat @R0, uword instdir @R1) -> ubyte @A
    extsub @bank 3 $A00C = hist_store(uword sptr @R0) -> ubyte @A
    extsub @bank 3 $A00F = hist_save(uword cat @R0, uword instdir @R1)
    extsub @bank 3 $A012 = hist_get(ubyte slot @R0, uword outptr @R1)
    ; the file-copy byte pump lives in the overlay too (its 255-byte buffer no longer costs main
    ; RAM). src is an absolute path, dst a bare name in the CWD the caller chdir'd into.
    extsub @bank 3 $A015 = stream_copy(uword srcptr @R0, uword dstptr @R1) -> uword @AY
    ; whole-disk "Find file" crawler (also overlay-resident: its path buffers cost no main RAM).
    ; crawl_begin(specptr) starts a fresh crawl for the lowercased filespec; crawl_next_hit(outptr)
    ; visits ONE directory per call, writing its path to outptr and returning 2 = has a match,
    ; 1 = visited/no match, 0 = disk exhausted (so the caller can show live per-dir progress);
    ; crawl_trunc() is 1 if any subtree was skipped for being too deep. Only one listing is ever
    ; open at a time, so main's own diskio (open_path/scan_dir) is free to run between visits.
    extsub @bank 3 $A018 = crawl_begin(uword specptr @R0)
    extsub @bank 3 $A01B = crawl_next_hit(uword outptr @R0) -> ubyte @A
    extsub @bank 3 $A01E = crawl_trunc() -> ubyte @A
    ; content search (XTree "Ctrl-S"): open <dir>/<name> and scan its bytes for <term>, case- and
    ; encoding-insensitive. 1 = term present, 0 = absent / unopenable. ShowAll's S key calls this
    ; per tagged file and untags the misses, collapsing the tag set to the matches.
    extsub @bank 3 $A021 = content_scan(uword dirptr @R0, uword nameptr @R1, uword termptr @R2) -> ubyte @A
    bool misc_ok                            ; miscutil.ovl loaded OK

    ; --- banked UI overlay (uiutil) ---
    ; uiutil.p8 is a %output library blob in reserved HIRAM bank 4; it holds the bottom-banner
    ; dialog DRAWING (confirms / banners / prompts). Main keeps the frame plumbing + thin wrappers
    ; (ask_yn / flash / banner_* / ...) that box_open, JSRFAR into these, then box_close. Message
    ; pointers point into main RAM (mapped below $A000 while the bank is active). $A000 = init.
    const ubyte UI_BANK = 4
    extsub @bank 4 $A000 = uiutil_init()
    extsub @bank 4 $A003 = ui_flash(uword mptr @R0)
    extsub @bank 4 $A006 = ui_toast(uword mptr @R0)
    extsub @bank 4 $A009 = ui_ask_yn(uword qptr @R0, ubyte default_yes @R1) -> ubyte @A
    extsub @bank 4 $A00C = ui_ask_overwrite(uword fnptr @R0) -> ubyte @A
    extsub @bank 4 $A00F = ui_ask_confirm_each(uword n @R0) -> ubyte @A
    extsub @bank 4 $A012 = ui_ask_delete_this(uword nptr @R0) -> ubyte @A
    extsub @bank 4 $A015 = ui_banner_copymove(ubyte is_move @R0, uword done @R1, uword failed @R2, uword skipped @R3)
    extsub @bank 4 $A018 = ui_banner_delete(uword done @R0)
    extsub @bank 4 $A01B = ui_copy_diag(ubyte failcode @R0, ubyte wstat @R1)
    ; modal popup boxes (Recent / Pick-a-dir borders + the full About screen) also draw here.
    extsub @bank 4 $A01E = ui_draw_box(ubyte x0 @R0, ubyte y0 @R1, ubyte x1 @R2, ubyte y1 @R3)
    extsub @bank 4 $A021 = ui_box_header(ubyte x0 @R0, ubyte x1 @R1, ubyte y0 @R2, uword titleptr @R3)
    extsub @bank 4 $A024 = ui_show_about(ubyte high_bank @R0, ubyte max_bank @R1)
    ; the bottom command menu (all its label strings) draws here too; main passes the state it
    ; depends on (menu_mode / focus / del_char / sort_mode) since the overlay can't see globals.
    extsub @bank 4 $A027 = ui_draw_commands(ubyte menu_mode @R0, ubyte focus @R1, ubyte del_char @R2, ubyte sort_mode @R3, ubyte find_char @R4, ubyte move_char @R5, ubyte srch_char @R6, ubyte view_char @R7)
    bool ui_ok                              ; uiutil.ovl loaded OK -> dialogs use the overlay

    sub start() {
        ; XFMGR2 depends on R49+ Kernal behaviour (notably the X16 Edit ROM API used by
        ; the E command). Refuse to run on older or pre-release ROMs instead of booting
        ; into a UI that would misbehave when the editor is invoked.
        ubyte romver
        bool prerelease
        romver, prerelease = cx16.rom_version()
        if prerelease or romver < 49 {
            txt.print("\rxfmgr2 requires kernal r49 or newer.\r")
            return
        }

        ; remember the current mode (returns mode, width, height) to restore on exit
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        snapshot_machine_state()                 ; capture charset + text color before we change anything
        caps_off()                               ; CAPS LOCK off (it breaks the ALT/CTRL menus); restored on exit
        cx16.set_screen_mode(SCREEN_MODE)        ; 80x30

        ; pick the environment-specific CTRL keys (the emulator swallows Ctrl-D/F/M/S)
        if emudbg.is_emulator() {
            del_key  = 'x'
            del_char = 'X'
            find_key  = 'n'
            find_char = 'N'
            move_key  = 'o'
            move_char = 'O'
            srch_key  = 'e'
            srch_char = 'E'
            view_key  = 'l'
            view_char = 'L'
        } else {
            del_key  = 'd'
            del_char = 'D'
            find_key  = 'f'
            find_char = 'F'
            move_key  = 'm'
            move_char = 'M'
            srch_key  = 's'
            srch_char = 'S'
            view_key  = 'v'
            view_char = 'V'
        }
        txt.lowercase()
        txt.color2(shared.CLR_FG, shared.CLR_BG)               ; white text on a blue field
        txt.clear_screen()

        ; remember where we were launched from before any diskio call clobbers the
        ; shared buffer curdir() points into
        void strings.copy(diskio.curdir(), pathbuf)

        ; The .ovl overlays live in the program's own folder, which is NOT the boot cwd when we are
        ; launched via the root XT loader. Every load below goes through themes.path_to(), which
        ; prefixes the install folder parsed out of the XT launcher itself (see themes.find_progdir)
        ; - so the install location is the installer's business and nothing here is hard-coded. The
        ; paths are absolute, so no chdir hop (and no restore) is needed: cwd stays where we were
        ; launched, which is exactly where the tree wants to anchor.

        ; load the tview viewer overlay into its reserved bank (VIEW_BANK) at $A000, then run
        ; its one-time library init.
        cx16.push_rambank(VIEW_BANK)
        viewer_ok = diskio.loadlib(themes.path_to("tview.ovl"), $a000) != 0
        cx16.pop_rambank()
        if viewer_ok
            tview_init()                ; extsub @bank 2: clears the overlay's in-bank BSS ONCE

        ; load the xsyntax coloring overlay into its reserved bank (SYN_BANK), then tell tview
        ; whether it is there and where the two shared main-RAM buffers live. tview verifies the
        ; bank independently (its probe entry) before it ever colors anything, so a half-loaded
        ; or mis-linked overlay degrades to plain text rather than JSRFARing into garbage.
        cx16.push_rambank(SYN_BANK)
        syn_ok = diskio.loadlib(themes.path_to("xsyntax.ovl"), $a000) != 0
        cx16.pop_rambank()
        if syn_ok
            xsyntax_init()              ; extsub @bank 9: clears the overlay's in-bank BSS ONCE
        if viewer_ok {
            ubyte syn_flag = 0
            if syn_ok
                syn_flag = 1
            view_set_syn(syn_flag, syn_line, syn_col)
        }

        ; load the miscutil overlay into its reserved bank (MISC_BANK) the same way
        cx16.push_rambank(MISC_BANK)
        misc_ok = diskio.loadlib(themes.path_to("miscutil.ovl"), $a000) != 0
        cx16.pop_rambank()
        if misc_ok
            miscutil_init()             ; extsub @bank 3: clears the overlay's in-bank BSS ONCE

        ; load the uiutil dialog overlay into its reserved bank (UI_BANK) the same way
        cx16.push_rambank(UI_BANK)
        ui_ok = diskio.loadlib(themes.path_to("uiutil.ovl"), $a000) != 0
        cx16.pop_rambank()
        if ui_ok
            uiutil_init()               ; extsub @bank 4: clears the overlay's in-bank BSS ONCE

        ; load the ximgview BMX image viewer overlay into its reserved bank (IMG_BANK) the same way
        cx16.push_rambank(IMG_BANK)
        imgview_ok = diskio.loadlib(themes.path_to("ximgview.ovl"), $a000) != 0
        cx16.pop_rambank()
        if imgview_ok
            ximgview_init()             ; extsub @bank 5: clears the overlay's in-bank BSS ONCE

        ; load the zsmkit v2 music engine blob into its reserved bank (ZSM_BANK), same headerless
        ; loadlib pattern - the blob's fixed jump table sits at $A000. NOT init'd here: golden RAM
        ; is volatile (X16 Edit uses it), so zsm_init_engine(ZSM_LOWRAM) runs per play_zsm.
        cx16.push_rambank(ZSM_BANK)
        zsm_ok = diskio.loadlib(themes.path_to("zsmkit.bin"), $a000) != 0
        cx16.pop_rambank()

        ; load the xmusic WAV player overlay into its reserved bank (MUS_BANK), same as the others
        cx16.push_rambank(MUS_BANK)
        music_ok = diskio.loadlib(themes.path_to("xmusic.ovl"), $a000) != 0
        cx16.pop_rambank()
        if music_ok
            xmusic_init()               ; extsub @bank 7: clears the overlay's in-bank BSS ONCE

        ; every overlay above must have loaded - report any that didn't, by name, before the UI
        ; comes up (see check_overlays for why this is worth a full-screen stop)
        ovl_missing = 0
        if not viewer_ok
            ovl_missing |= %00000001
        if not syn_ok
            ovl_missing |= %00000010
        if not misc_ok
            ovl_missing |= %00000100
        if not ui_ok
            ovl_missing |= %00001000
        if not imgview_ok
            ovl_missing |= %00010000
        if not zsm_ok
            ovl_missing |= %00100000
        if not music_ok
            ovl_missing |= %01000000
        check_overlays()

        ; apply the saved color theme. cfg_read() reads the cfg by ABSOLUTE path (themes.path_to),
        ; so it works regardless of where we are here and leaves the cwd alone.
        ; A palette remap - full_redraw below repaints in the themed colors. Missing cfg -> Classic.
        themes.apply_theme(themes.cfg_read())

        diskio.chdir(pathbuf)           ; back to the launch dir so the tree anchors where we started

        xarena.reset()
        xfiles.reset()
        xtree.init()                    ; creates root (index 0) = the drive root "/"
        void xscan.scan_dir(0)          ; log the drive root
        xtree.d_flags[0] |= xtree.FL_EXPANDED

        ; open the tree down to the launch directory and start with that folder selected
        ; (XTree-style: the whole drive is logged from the root, current folder highlighted)
        start_node = xscan.open_path(pathbuf)
        void xscan.scan_dir(start_node)
        xtree.d_flags[start_node] |= xtree.FL_EXPANDED
        xtree.rebuild_visible()

        focus = FOCUS_TREE
        xfiles.file_scope = xfiles.SCOPE_DIR    ; explicit: the pane geometry and half the file ops
        xfiles.scope_partial = false            ; branch on this before anything else writes it
        tree_top = 0
        set_tree_cursor_to(start_node)
        select_dir(start_node)

        full_redraw()
        repeat {
            g_key = wait_command()
            dirty_tree = false
            dirty_files = false
            dirty_status = false
            dirty_cmd = false
            dirty_full = false
            dirty_tree_cur = false
            dirty_file_cur = false
            ; dispatch by the active menu mode (set live from the held modifier)
            when menu_mode {
                1 -> handle_ctrl(g_key)             ; CTRL held
                2 -> handle_alt(g_key)              ; ALT held
                else -> {
                    when g_key {
                        'q'  -> {
                            if confirm_quit() {
                                xtree.build_path(start_node, exit_dir)  ; quit to the launch dir
                                break
                            }
                            dirty_cmd = true        ; restore the menu the prompt covered
                        }
                        133  -> {                                  ; F1: show the help file
                            op_help()
                            dirty_full = true                      ; viewer took the whole screen
                        }
                        27   -> {                                  ; Esc: leave a scoped listing
                            if xfiles.file_scope != xfiles.SCOPE_DIR
                                leave_scope()
                        }
                        9    -> change_focus(FOCUS_FILE - focus)   ; TAB toggles pane
                        29   -> {                                  ; cursor-right: enter files,
                            change_focus(FOCUS_FILE)               ; but only if the folder has
                            if focus == FOCUS_FILE and xfiles.ft_count == 0
                                change_focus(FOCUS_TREE)           ; files - an empty one stays in the tree
                        }
                        157  -> {                                  ; cursor-left
                            if focus == FOCUS_TREE
                                handle_tree(157)                   ; in the tree: collapse expanded dir
                            else
                                change_focus(FOCUS_TREE)           ; in the files: hop back to the tree
                        }
                        else -> {
                            if focus == FOCUS_TREE
                                handle_tree(g_key)
                            else
                                handle_file(g_key)
                        }
                    }
                }
            }
            if run_exit
                break                       ; Alt-X: leave XFMGR to run a program
            if setup_exit
                break                       ; Alt-F10: leave XFMGR to run the theme setup PRG
            if do_quit
                break                       ; Alt-Q: quit to the current directory
            ; repaint only what changed
            if dirty_full {
                full_redraw()
            } else {
                if dirty_status
                    draw_status()
                if dirty_tree
                    draw_tree()                 ; full pane repaint
                else if dirty_tree_cur
                    draw_tree_cursor()          ; light: only the two rows that changed
                if dirty_files
                    draw_files()                ; full pane repaint
                else if dirty_file_cur
                    draw_files_cursor()         ; light: only the two rows that changed
                if dirty_cmd
                    draw_commands()
            }
            ; eat any keystrokes that piled up in the buffer while we dispatched+redrew
            ; (hardware key-repeat keeps stuffing it): otherwise a held up/down arrow keeps
            ; scrolling after release. One fresh keypress per command cycle - no overshoot.
            cx16.kbdbuf_clear()
        }

        txt.clear_screen()
        cx16.set_screen_mode(saved_mode)         ; restore the original screen mode
        restore_machine_state()                  ; re-apply the user's charset + text color (CINT reset them)
        caps_restore()                           ; and put CAPS LOCK back as we found it
        ; NB: this sits before ALL three exit branches (run_exit / setup_exit / plain quit), so
        ; every way out of XFMGR restores caps - including the chain_run hand-offs.
        if run_exit {
            ; hand off to BASIC: load + run the selected program via the dynamic keyboard
            diskio.chdir(pathbuf)               ; the selected file's directory
            chain_run(namebuf)
        } else if setup_exit {
            ; hand off to the theme setup PRG. Its path is built from the install folder parsed out
            ; of the root /xt launcher (themes.path_to), NOT hard-coded "/xfmgr/" - the app can be
            ; installed anywhere (e.g. /utils/xfmgr/), and a hard-coded path made Alt-F10 fail with
            ; FILE NOT FOUND there. It writes xfmgr.cfg then relaunches xfmgr.prg from the same
            ; folder, which re-reads + applies the theme.
            chain_run(themes.path_to("xfsetup.prg"))
        } else {
            diskio.chdir(exit_dir)              ; leave the shell in the chosen directory
            txt.clear_screen()                  ; clean screen (in the restored charset/colors) before the sign-off
            txt.print("xfmgr done.\n")
        }
    }

    sub snapshot_machine_state() {
        ; capture the user's charset + text color so exit can put them back (set_screen_mode's CINT
        ; resets both to X16 defaults). Read while STILL in the launch screen mode.
        saved_charset = cx16.get_charset()          ; 1=ISO 2=PETSCII upper/gfx 3=PETSCII lower (0=unknown)
        ; text color = the color matrix at the cursor cell. MUST use txt.getclr, not a hand-computed
        ; VERA address: the text matrix has a fixed 256-byte row stride (128 cols), so row*width*2 is
        ; wrong for row>0 - that was the earlier "bad background" bug. High nibble=bg, low nibble=fg.
        ubyte cx_col
        ubyte cx_row
        cx_col, cx_row = txt.get_cursor()
        saved_color = txt.getclr(cx_col, cx_row)
    }

    sub caps_off() {
        ; Remember whether CAPS LOCK is on and, if so, turn it off for the session.
        caps_was_on = false
        ubyte mods = cx16.kbdbuf_get_modifiers()
        ; parens are redundant - prog8 binds & (prec 7) TIGHTER than == (11), the opposite of C -
        ; but they cost nothing and stop this reading as a bug to anyone carrying C habits.
        if (mods & MOD_CAPS) == 0
            return                              ; already off: nothing to save, and nothing to poke

        ; Caps IS on, so we have to write the KERNAL's shflag - there is no API for it (see the
        ; KBD_SHFLAG note above). Guard the write: the byte at KBD_SHFLAG must read back EXACTLY
        ; what the DOCUMENTED kbdbuf_get_modifiers() just returned. That is a strong check,
        ; because we only get here when caps is set, so we are matching a specific non-zero value
        ; ($10 plus whatever else is held) rather than a likely-coincidental zero. If a future
        ; ROM relocates shflag the two disagree and we leave caps alone - the feature quietly
        ; does nothing instead of corrupting an unrelated KERNAL variable.
        caps_was_on = caps_clear(mods)          ; guarded shflag write; true iff it actually cleared
    }

    sub caps_clear(ubyte mods) -> bool {
        ; Clear the KERNAL Caps bit in shflag and report whether it happened. `mods` MUST be the
        ; value kbdbuf_get_modifiers() just returned WITH MOD_CAPS set - the same guard caps_off
        ; documents: write only if the byte at KBD_SHFLAG reads back EXACTLY that (a specific
        ; non-zero value), so a ROM that relocated shflag leaves the toggle untouched. Shared by
        ; caps_off (startup) and input_key (the software-caps toggle in the line editor).
        bool cleared = false
        cx16.push_rambank(0)
        if @(KBD_SHFLAG) == mods {
            @(KBD_SHFLAG) = mods & (255 - MOD_CAPS)
            cleared = true
        }
        cx16.pop_rambank()
        return cleared
    }

    sub caps_restore() {
        ; Put CAPS LOCK back exactly as we found it. Only ever runs when caps_off() confirmed the
        ; address and actually cleared the bit, so this never writes on an unverified ROM.
        if not caps_was_on
            return
        cx16.push_rambank(0)
        @(KBD_SHFLAG) = @(KBD_SHFLAG) | MOD_CAPS
        cx16.pop_rambank()
    }

    sub restore_machine_state() {
        ; undo XFMGR's charset + color changes: re-apply what snapshot_machine_state() captured (the
        ; set_screen_mode call just above already reset them to X16 defaults via its CINT).
        if saved_charset >= 1 and saved_charset <= 3
            cx16.screen_set_charset(saved_charset, 0)       ; 0 ptr = built-in ROM charset
        if saved_color != 0                                 ; 0 = black-on-black -> skip a bad read
            txt.color2(saved_color & 15, saved_color >> 4)  ; low nibble = fg, high nibble = bg
    }

    sub select_dir(ubyte idx) {
        cur_dir = idx
        file_cursor = 0
        file_top = 0
        if xtree.d_flags[idx] & xtree.FL_SCANNED != 0
            void xfiles.build_index(idx)
        else
            xfiles.ft_count = 0
        recount_blocks()
    }

    sub set_tree_cursor_to(ubyte idx) {
        for g_ndx in 0 to xtree.vis_count-1 {
            if xtree.vis_idx[g_ndx] == idx {
                tree_cursor = g_ndx
                return
            }
        }
        tree_cursor = 0
    }

    sub confirm(str question, bool default_yes) -> bool {
        ; bracketed Yes/No confirmation box; default_yes picks which side ENTER selects.
        return ask_yn(question, default_yes)
    }

    sub confirm_enter(str question) -> bool {
        ; ENTER-or-ESC confirm (no Yes/No pair): ENTER accepts, ESC cancels, other keys ignored.
        ; Draws the input box + question, then its OWN row-2 hint "[Yes]   Esc Cancel" (distinct
        ; from the text-input prompts' "←┘ OK  ESC Cancel" that prompt_hint draws).
        box_open()
        txt.plot(BANNER_LEFT, MSGROW)
        txt.print(question)
        hilite_row(0, 79, MSGROW, shared.CLR_BOTTOM_PROMPT_BG)
        ; "[Yes]   Esc Cancel", right-justified so " Cancel" ends at col 78 (matches prompt_hint)
        ubyte hcol = 79 - (5 + 3 + 3 + 7)               ; "[Yes]"(5)+"   "(3)  "Esc"(3)+" Cancel"(7)
        hcol = hint_key(hcol, "", "[")                  ; bracket in normal text color
        hcol = hint_key(hcol, "Y", "es]   ")            ; only the Y is the hotkey color
        hcol = hint_key(hcol, "Esc", " Cancel")
        repeat {
            when cmd_key() {                    ; case-folded, so Y works shifted or not
                13, 'y' -> {                    ; ENTER or Y = accept
                    box_close()
                    return true
                }
                27, 3 -> {                      ; ESC / STOP = cancel
                    box_close()
                    return false
                }
            }
        }
    }

    sub confirm_quit() -> bool {
        return confirm("Quit XFMGR2?", true)
    }

    sub confirm_quit_here() -> bool {
        return confirm("Quit to this directory?", true)
    }

    sub handle_ctrl(ubyte letter) {
        ; XTree CTRL hotkeys (work from either pane; act on the current directory)
        if letter == del_key {              ; Ctrl-X (emu) / Ctrl-D (hw): delete tagged
            op_delete_tagged()
            dirty_files = true
            dirty_status = true
            dirty_cmd = true
            return
        }
        if letter == find_key {             ; Ctrl-N (emu) / Ctrl-F (hw): find files across the disk
            op_find()                       ; (runtime key, so it can't be a constant when-case)
            dirty_full = true
            return
        }
        if letter == move_key {             ; Ctrl-O (emu) / Ctrl-M (hw): move all tagged files
            op_copymove(true, true)         ; (runtime key, so it can't be a constant when-case)
            dirty_full = true
            return
        }
        if letter == srch_key {             ; Ctrl-E (emu) / Ctrl-S (hw): search tagged files' CONTENTS
            op_search_tagged()              ; (runtime key, so it can't be a constant when-case)
            dirty_full = true
            return
        }
        if letter == view_key {             ; Ctrl-L (emu) / Ctrl-V (hw): view every tagged file in turn
            view_tagged()                   ; (runtime key, so it can't be a constant when-case)
            dirty_full = true
            return
        }
        when letter {
            't' -> {                        ; Ctrl-T: tag ALL files
                xfiles.tag_all()
                dirty_files = true
                dirty_status = true
            }
            'u' -> {                        ; Ctrl-U: untag all
                xfiles.untag_all()
                dirty_files = true
                dirty_status = true
            }
            'i' -> {                        ; Ctrl-I: invert tags
                xfiles.invert_all()
                dirty_files = true
                dirty_status = true
            }
            'c' -> {                        ; Ctrl-C: copy this dir's tagged files
                op_copymove(false, true)
                dirty_full = true
            }
            'w' -> {                        ; Ctrl-W: tag files by wildcard
                                            ; (Ctrl-S is captured by the emulator)
                op_tag_by_spec()
                dirty_files = true
                dirty_status = true
                dirty_cmd = true
            }
        }
    }

    sub handle_alt(ubyte letter) {
        ; ALT-key commands
        when letter {
            $15 -> {                        ; Alt-F10: open the color-theme setup (either pane)
                                            ; ($15 = F10; passes through unchanged like Alt-F3=134)
                op_setup()
                if not setup_exit
                    dirty_full = true       ; cancelled: repaint the screen the confirm covered
            }
            's' -> {                        ; Alt-S: cycle the file sort order (file pane only)
                if focus == FOCUS_FILE
                    op_sort()
            }
            'x' -> {                        ; Alt-X: execute / run the selected file (file pane only)
                if focus == FOCUS_FILE {
                    op_execute()
                    if not run_exit
                        dirty_full = true   ; cancelled: repaint the screen
                }
            }
            'q' -> {                        ; Alt-Q: quit, leaving the shell in THIS dir
                if confirm_quit_here() {
                    xtree.build_path(cur_dir, exit_dir)
                    do_quit = true
                } else {
                    dirty_cmd = true        ; restore the menu the prompt covered
                }
            }
            134 -> {                        ; Alt-F3: relog (re-read) the current dir
                op_relog()
                dirty_full = true
            }
            'r' -> {                        ; Alt-R: release (un-log) the current folder
                op_release()
                dirty_full = true           ; tree rows vanished + flash may cover the menu
            }
            'j' -> {                        ; Alt-J: jump to a typed directory (XTree's Treespec)
                op_jump_dir()
                dirty_full = true
            }
            't' -> op_tag_branch()          ; Alt-T: tag this folder + everything below it
            'u' -> op_untag_disk()          ; Alt-U: clear every tag on the disk
            'p' -> {                        ; Alt-P: prune (dir pane only) - delete the subtree
                if focus == FOCUS_TREE {
                    op_prune()
                    dirty_full = true       ; confirm + banner covered the screen
                }
            }
            else -> { }
        }
    }

    sub change_focus(ubyte newfocus) {
        ; A scoped listing HIDES the tree, so there is no tree row to move a highlight onto: every
        ; route back to the directory pane (Enter, TAB, cursor-left, an op emptying the list) has to
        ; leave the scope first. Funnelling that through here means each of those keeps working
        ; without knowing scopes exist - which is how XTree behaves too: "Press Enter or Esc while
        ; in any Expanded File Window to return to the Directory Window".
        if newfocus == FOCUS_TREE and xfiles.file_scope != xfiles.SCOPE_DIR {
            leave_scope()
            return
        }
        ; Entering the FILE column on a directory that hasn't been logged yet logs it now
        ; (scan folders + files) so the file pane has something to show, instead of landing
        ; on an empty column. Mirrors the Enter key's first-time scan. Covers TAB and
        ; cursor-right; switching back to the tree never triggers a scan.
        bool scanned_now = false
        if newfocus == FOCUS_FILE and xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0 {
            void xscan.scan_dir(cur_dir)
            if xtree.has_kids(cur_dir)
                xtree.d_flags[cur_dir] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
            set_tree_cursor_to(cur_dir)
            select_dir(cur_dir)
            scanned_now = true
            dirty_status = true
        }
        focus = newfocus
        if scanned_now {
            dirty_tree = true               ; the scan added tree rows and rebuilt the file list
            dirty_files = true
        } else {
            ; Nothing moved and no content changed - the ONLY visual difference is on the two
            ; cursor rows, whose selection indicator flips between a bar (focused) and '>'
            ; (unfocused). Use the light two-row repaints; redrawing both whole panes here made
            ; every TAB / left-right flash the screen.
            dirty_tree_cur = true
            dirty_file_cur = true
        }
        dirty_cmd = true                    ; the plain menu is per-pane
    }

    sub handle_tree(ubyte key) {
        when key {
            145 -> {                    ; up
                if tree_cursor != 0 {
                    tree_cursor--
                    select_dir(xtree.vis_idx[tree_cursor])
                    dirty_tree_cur = true       ; light: only two dir rows re-ink
                    dirty_files = true
                    dirty_status = true
                }
            }
            17 -> {                     ; down
                if tree_cursor + 1 < xtree.vis_count {
                    tree_cursor++
                    select_dir(xtree.vis_idx[tree_cursor])
                    dirty_tree_cur = true       ; light: only two dir rows re-ink
                    dirty_files = true
                    dirty_status = true
                }
            }
            2 -> {                      ; PgDn: jump down one page
                if xtree.vis_count != 0 {
                    ubyte last = xtree.vis_count - 1
                    if tree_cursor != last {
                        if last - tree_cursor > PANE_H
                            tree_cursor += PANE_H
                        else
                            tree_cursor = last
                        select_dir(xtree.vis_idx[tree_cursor])
                        dirty_tree_cur = true   ; light (falls back to full if it scrolled)
                        dirty_files = true
                        dirty_status = true
                    }
                }
            }
            130 -> {                    ; PgUp: jump up one page
                if tree_cursor != 0 {
                    if tree_cursor > PANE_H
                        tree_cursor -= PANE_H
                    else
                        tree_cursor = 0
                    select_dir(xtree.vis_idx[tree_cursor])
                    dirty_tree_cur = true       ; light (falls back to full if it scrolled)
                    dirty_files = true
                    dirty_status = true
                }
            }
            13 -> {                     ; enter: log / expand / collapse / drill into files
                ubyte idx = cur_dir
                if xtree.d_flags[idx] & xtree.FL_SCANNED == 0 {
                    void xscan.scan_dir(idx)        ; 1st Enter: log this dir
                    if xtree.has_kids(idx)
                        xtree.d_flags[idx] |= xtree.FL_EXPANDED
                    xtree.rebuild_visible()
                    set_tree_cursor_to(idx)
                    select_dir(idx)
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                } else if xtree.has_kids(idx) {
                    xtree.toggle_expand(idx)        ; already logged, has subdirs: expand/collapse
                    set_tree_cursor_to(idx)
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                } else {
                    change_focus(FOCUS_FILE)        ; logged, no subdirs: drill into the file pane
                }
            }
            157, '-' -> {                ; left / '-': collapse the expanded dir (like ENTER's collapse)
                if xtree.has_kids(cur_dir) and xtree.is_expanded(cur_dir) {
                    xtree.toggle_expand(cur_dir)
                    set_tree_cursor_to(cur_dir)
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                }
            }
            '+' -> {                     ; '+': log / expand the dir (like ENTER's expand, never collapses)
                ubyte pidx = cur_dir
                if xtree.d_flags[pidx] & xtree.FL_SCANNED == 0 {
                    void xscan.scan_dir(pidx)       ; not logged yet: log it
                    if xtree.has_kids(pidx)
                        xtree.d_flags[pidx] |= xtree.FL_EXPANDED
                    xtree.rebuild_visible()
                    set_tree_cursor_to(pidx)
                    select_dir(pidx)
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                } else if xtree.has_kids(pidx) and not xtree.is_expanded(pidx) {
                    xtree.toggle_expand(pidx)       ; logged, collapsed, has subdirs: expand
                    set_tree_cursor_to(pidx)
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                }
            }
            'm' -> {                    ; M: make a new directory
                op_mkdir()
                dirty_tree = true
                dirty_files = true
                dirty_status = true
                dirty_cmd = true        ; prompt was drawn over the menu
            }
            'r' -> {                    ; R: rename the selected directory
                op_rename_dir()
                dirty_tree = true
                dirty_files = true
                dirty_status = true
                dirty_cmd = true        ; prompt was drawn over the menu
            }
            'd' -> {                    ; D: delete the selected folder (empty folders only)
                op_delete_dir()
                dirty_full = true       ; confirm / result flash covered the screen
            }
            's' -> {                    ; S: Showall - every logged file on the disk, as one list
                enter_scope(xfiles.SCOPE_DISK)
            }
            'b' -> {                    ; B: Branch - this directory and everything logged below it
                enter_scope(xfiles.SCOPE_BRANCH)
            }
            'a' -> {                    ; A: about (replaces the old '?')
                show_about()
                dirty_full = true
            }
        }
    }

    ; Root of a SCOPE_BRANCH listing: the directory the user pressed B on. Kept separate from
    ; cur_dir because cur_dir follows the tree cursor and the branch must not drift with it.
    ubyte branch_root

    sub enter_scope(ubyte new_scope) {
        ; Switch the file pane to a scoped listing (XTree Showall) and move the highlight into it.
        ; Entered from the DIRECTORY pane only, exactly as XTree does it - the scope is a property
        ; of the file window, and you leave it the same way you leave any file window (Esc/Enter).
        ; Gathering + sorting a whole disk's worth of files takes a visible moment (every comparison
        ; re-reads a name out of banked RAM), and until it finishes the screen still shows the old
        ; pane - so it reads as a hang rather than as work. Say so first.
        box_open()
        box_left(CMDROW1, "Working...")
        branch_root = cur_dir                       ; only read when new_scope is SCOPE_BRANCH
        xfiles.file_scope = new_scope
        if rebuild_view() == 0 {
            xfiles.file_scope = xfiles.SCOPE_DIR    ; nothing to show - don't strand the user in an
            void rebuild_view()                     ; empty pane they then have to Esc out of
            flash("no logged files match the filespec")
            dirty_full = true                       ; the box we opened covered the menu rows
            return
        }
        file_cursor = 0
        file_top = 0
        recount_blocks()                            ; header total now covers the whole scope
        focus = FOCUS_FILE
        dirty_full = true                           ; the pane changes shape - repaint everything
    }

    sub recount_blocks() {
        ; Total blocks of everything the file header REPORTS (its "(Total blocks: N)").
        ;
        ; One index means one loop: it covers a directory listing and a scoped view alike. Only if
        ; the disk holds more than xfiles.INDEX_MAX matches does this go partial, and the header
        ; says so.
        cur_blocks = 0
        uword row = 0
        while row < xfiles.ft_count {
            cur_blocks += xfiles.get_blocks(row)
            row++
        }
    }

    sub leave_scope() {
        ; Back to the current directory's own listing, highlight returned to the tree.
        xfiles.file_scope = xfiles.SCOPE_DIR
        void rebuild_view()
        file_cursor = 0
        file_top = 0
        recount_blocks()
        focus = FOCUS_TREE
        dirty_full = true
    }

    sub handle_file(ubyte key) {
        when key {
            13 -> {                     ; enter: hop back to the dir tree column
                change_focus(FOCUS_TREE)
            }
            145 -> {                    ; up
                if file_cursor != 0 {
                    file_cursor--
                    dirty_file_cur = true       ; light: only two file rows re-ink
                }
            }
            17 -> {                     ; down
                if file_cursor + 1 < xfiles.ft_count {
                    file_cursor++
                    dirty_file_cur = true       ; light: only two file rows re-ink
                }
            }
            2 -> {                      ; PgDn: jump down one page
                if xfiles.ft_count != 0 {
                    uword last = xfiles.ft_count - 1
                    if file_cursor != last {
                        if last - file_cursor > FILE_VIS
                            file_cursor += FILE_VIS
                        else
                            file_cursor = last
                        dirty_file_cur = true   ; light (falls back to full if it scrolled)
                    }
                }
            }
            130 -> {                    ; PgUp: jump up one page
                if file_cursor != 0 {
                    if file_cursor > FILE_VIS
                        file_cursor -= FILE_VIS
                    else
                        file_cursor = 0
                    dirty_file_cur = true       ; light (falls back to full if it scrolled)
                }
            }
            't' -> {
                if xfiles.ft_count != 0 {
                    xfiles.toggle_tag(file_cursor)
                    if file_cursor + 1 < xfiles.ft_count
                        file_cursor++           ; tag-and-advance, like XTree
                    dirty_files = true
                    dirty_status = true
                }
            }
            'u' -> {
                if xfiles.ft_count != 0 {
                    if xfiles.is_tagged(file_cursor)
                        xfiles.toggle_tag(file_cursor)
                    if file_cursor + 1 < xfiles.ft_count
                        file_cursor++           ; untag-and-advance
                    dirty_files = true
                    dirty_status = true
                }
            }
            'v' -> {                            ; View: .bmx -> banked image viewer, else text/hex viewer
                if xfiles.ft_count != 0 {
                    xfiles.get_name(file_cursor, namebuf)
                    cd_to_entry(file_cursor)    ; so bmx.open/f_open(namebuf) resolve in the file's dir
                    if imgview_ok and sniff_kind(&namebuf) == 1 {   ; 1 = BMX image
                        view_image(&namebuf)            ; bank-5 overlay: shows the BMX, returns on any key
                        cx16.set_screen_mode(SCREEN_MODE)  ; image viewer left VERA in bitmap mode -> back to 80x30
                        txt.lowercase()                 ; CINT/set_screen_mode reset the charset to uppercase
                        txt.color2(shared.CLR_FG, shared.CLR_BG)   ; restore app theme after CINT reset the palette
                    } else if viewer_ok {
                        ; Prime the viewer's in-file Find history: load the "viewfind" ring BEFORE the
                        ; viewer (read_find recalls from it) and save it AFTER (read_find added any
                        ; accepted term to the in-memory ring). hist_load/hist_save chdir to the install
                        ; dir, so restore the file's dir each time - the viewer f_opens namebuf
                        ; RELATIVE to cwd. progdir_cd() hoisted into a local (its result is hist_*'s
                        ; @R1, and passing the call inline would clobber @R0 first - see input_line).
                        ubyte vhc = 255                 ; 255 = Find history unavailable (miscutil absent)
                        if misc_ok {
                            uword hd = themes.progdir_cd()
                            vhc = hist_load(VIEWFIND_CAT, hd)
                            diskio.chdir(pathbuf)
                        }
                        ; blocks: the directory entry's size, for the viewer's "n%" position. Hoisted
                        ; into a local - passing the call inline would clobber r0 before we set it.
                        uword vblk = xfiles.get_blocks(file_cursor)
                        void view_file(&namebuf, vhc, 0, 0, 0, 0, vblk)  ; single file (setmode 0, no seeded term)
                        if misc_ok {
                            uword hd2 = themes.progdir_cd()
                            hist_save(VIEWFIND_CAT, hd2)
                            diskio.chdir(pathbuf)       ; leave cwd where the pre-history code did
                        }
                        txt.color2(shared.CLR_FG, shared.CLR_BG)   ; viewer left the text color blue; restore app theme
                                                     ; (full_redraw's blanks use the current color)
                    } else {
                        op_edit()               ; overlays missing -> fall back to X16 Edit
                    }
                    dirty_full = true           ; viewer/editor took the screen; repaint
                }
            }
            'p' -> {                            ; Play: .zsm -> zsmkit engine, .wav -> PCM streamer
                if xfiles.ft_count != 0 {
                    xfiles.get_name(file_cursor, namebuf)
                    cd_to_entry(file_cursor)    ; so the player's f_open(namebuf) resolves in the dir
                    ubyte fk = sniff_kind(&namebuf)
                    if fk == 2
                        play_zsm()
                    else if fk == 3
                        op_play_wav()
                    else
                        flash("not a music file (zsm/wav)")
                    dirty_full = true           ; player took the bottom rows / status; repaint
                }
            }
            'e' -> {
                op_edit()
                dirty_full = true               ; X16 Edit took over the screen
            }
            'd' -> {
                op_delete()
                dirty_files = true
                dirty_status = true
                dirty_cmd = true                ; prompt was drawn over the menu
            }
            'r' -> {
                op_rename()
                dirty_files = true
                dirty_status = true
                dirty_cmd = true
            }
            'c' -> {
                op_copymove(false, false)       ; copy the single highlighted file (ignores tags)
                dirty_tree = true               ; a copy can create a new dest folder in the tree
                dirty_files = true
                dirty_status = true
                dirty_cmd = true
            }
            'm' -> {
                op_copymove(true, false)        ; move the single highlighted file (ignores tags)
                dirty_tree = true               ; dest dir's tree counts may change
                dirty_files = true
                dirty_status = true
                dirty_cmd = true
            }
            'f' -> {
                op_filespec()
                dirty_full = true               ; refresh files + the FILE: title
            }
        }
    }

    ; ---------- drawing ----------

    sub set_pane_geometry() {
        ; Where the file rows live: right of the divider normally, full width when a scoped
        ; listing has taken the tree's half of the screen.
        if xfiles.file_scope == xfiles.SCOPE_DIR {
            pane_mark_col = FILE_MARK
            pane_name_w   = 27
        } else {
            pane_mark_col = 1
            pane_name_w   = FILE_SIZE - 4       ; up to the size column, less the two marker cells
        }
    }

    sub full_redraw() {
        ; No full clear_screen: the static frame is overwritten with setchr and the
        ; dynamic regions blank+repaint their own lines, which avoids the whole-screen
        ; wipe that caused flicker.
        set_pane_geometry()
        draw_frame()
        draw_status()
        if xfiles.file_scope == xfiles.SCOPE_DIR
            draw_tree()                     ; a scoped listing occupies the tree's half of the screen
        draw_files()
        draw_commands()
    }

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        ; erase a horizontal run to spaces in the base color (resets any bar color)
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
    }

    sub hline(ubyte row, ubyte lc, ubyte jc, ubyte rc) {
        ; a horizontal frame line with a junction at the vertical divider.
        ; setchr writes straight to the screen matrix - no cursor move, no scroll.
        txt.setchr(0, row, lc)
        txt.setclr(0, row, shared.CLR_BOX)
        for g_ndx in 1 to 78 {
            if g_ndx == SPLIT
                txt.setchr(g_ndx, row, jc)
            else
                txt.setchr(g_ndx, row, SC_H)
            txt.setclr(g_ndx, row, shared.CLR_BOX)
        }
        txt.setchr(79, row, rc)
        txt.setclr(79, row, shared.CLR_BOX)
    }

    sub draw_frame() {
        ; With no divider column in a scoped listing, the two rows that would carry a T-junction
        ; get a plain horizontal there instead - otherwise a stub of the removed wall is left
        ; poking into the top and bottom of the file list.
        ubyte join_top = SC_JT
        ubyte join_bot = SC_JB
        if xfiles.file_scope != xfiles.SCOPE_DIR {
            join_top = SC_H
            join_bot = SC_H
        }
        hline(0, SC_TL, SC_H, SC_TR)        ; top border
        hline(2, SC_JL, join_top, SC_JR)    ; header / panes divider (carries titles)
        hline(DIVBOT, SC_JL, join_bot, SC_JR)   ; panes / command divider
        hline(SCR_BOT, SC_BL, SC_H, SC_BR)  ; bottom border
        ; side borders of the header and the two command rows
        txt.setchr(0, HDRROW, SC_V)
        txt.setchr(79, HDRROW, SC_V)
        txt.setchr(0, CMDROW1, SC_V)
        txt.setchr(79, CMDROW1, SC_V)
        txt.setchr(0, CMDROW2, SC_V)
        txt.setchr(79, CMDROW2, SC_V)
        txt.setclr(0, HDRROW, shared.CLR_BOX)
        txt.setclr(79, HDRROW, shared.CLR_BOX)
        txt.setclr(0, CMDROW1, shared.CLR_BOX)
        txt.setclr(79, CMDROW1, shared.CLR_BOX)
        txt.setclr(0, CMDROW2, shared.CLR_BOX)
        txt.setclr(79, CMDROW2, shared.CLR_BOX)
        ; side + middle borders down the content area. A scoped listing spans the full width, so
        ; the divider column is content there, not frame - drawing it would put a wall through the
        ; middle of the file names.
        bool scoped = xfiles.file_scope != xfiles.SCOPE_DIR
        for g_ndx in PANE_TOP to PANE_BOT {
            txt.setchr(0, g_ndx, SC_V)
            txt.setchr(79, g_ndx, SC_V)
            txt.setclr(0, g_ndx, shared.CLR_BOX)
            txt.setclr(79, g_ndx, shared.CLR_BOX)
            if not scoped {
                txt.setchr(SPLIT, g_ndx, SC_V)
                txt.setclr(SPLIT, g_ndx, shared.CLR_BOX)
            }
        }
        ; window titles embedded in the divider line
        txt.color(shared.CLR_TITLE)
        if scoped {
            ; One title across the whole width, naming the scope. XTree retitles its statistics
            ; panel for the same reason: a flat list of files from everywhere looks exactly like a
            ; normal directory listing until something says otherwise.
            txt.plot(TREE_TEXT, 2)
            if xfiles.file_scope == xfiles.SCOPE_BRANCH {
                ; Name the SUBTREE, not just the filespec - "BRANCH" alone doesn't say which
                ; branch, and the Path line follows the highlighted file rather than the root.
                txt.print(" BRANCH: ")
                xtree.build_path(branch_root, pathbuf)
                print_trunc(pathbuf, 22)
                txt.print(" : ")
                print_trunc(xfiles.spec_lc, 10)
            } else {
                txt.print(" SHOWALL: ")
                print_trunc(xfiles.spec_lc, 14)
            }
            txt.spc()
            if xfiles.scope_partial {
                txt.plot(50, 2)
                txt.print(" (partial) ")   ; more matches on disk than xfiles.INDEX_MAX rows
            }
        } else {
            txt.plot(TREE_TEXT, 2)
            txt.print(" DIRECTORY ")
            txt.plot(FILE_TEXT, 2)
            txt.print(" FILE: ")
            print_trunc(xfiles.spec_lc, 14)
            txt.spc()
        }
        ; program title embedded in the top border
        txt.plot(2, 0)
        txt.print(" XFMGR2 ")
        ; build number on the right of the top border (bump BUILD_NUM every build)
        void strings.copy(" build ", cm_dst)
        box_append_uw(BUILD_NUM)
        void strings.append(cm_dst, " ")
        txt.plot(78 - lsb(strings.length(cm_dst)), 0)
        txt.print(cm_dst)
        txt.color(shared.CLR_FG)
    }

    sub draw_status() {
        blank_span(1, 78, HDRROW)
        ; Path on the left of the header row. In a scoped listing this is the ONE place that says
        ; where the highlighted file actually lives - the rows themselves show only names, and
        ; without this a flat list of 200 files from all over the disk is unreadable. (This is
        ; exactly XTree's Path Identification line, and why it follows the file rather than the
        ; directory.) Rebuilt on every cursor move, which is one parent-walk - nothing.
        txt.plot(TREE_TEXT, HDRROW)
        txt.print("Path: ")
        if xfiles.file_scope != xfiles.SCOPE_DIR and xfiles.ft_count != 0
            xtree.build_path(xfiles.row_dir(file_cursor), pathbuf)
        else
            xtree.build_path(cur_dir, pathbuf)
        print_trunc(pathbuf, 40)                ; leave room for the counts on the right
        ; File + tag counts, pushed to the far right of the header row (border at col 79).
        ; Only a list past INDEX_MAX rows is truncated now, and it reads "1024 of 1837 Files" -
        ; the bare row count alone would claim a 1837-file disk held 1024 files.
        cm_dst[0] = 0
        box_append_uw(xfiles.ft_count)
        if xfiles.scope_partial {
            void strings.append(cm_dst, " of ")
            box_append_uw(xfiles.match_total)
        }
        void strings.append(cm_dst, " Files ")
        box_append_uw(tagged_in_view())
        void strings.append(cm_dst, " Tagged")
        txt.plot(79 - lsb(strings.length(cm_dst)), HDRROW)
        txt.print(cm_dst)
    }

    sub draw_tree_row(ubyte i) {
        ; paint ONE tree row: visible entry i at its screen row (assumes i is within the
        ; current window). Blanks first, so it also clears a slot that is now past the end.
        ubyte srow = PANE_TOP + (i - tree_top)
        blank_span(TREE_MARK, TREE_BAR_R, srow)
        if i < xtree.vis_count {
            ubyte idx = xtree.vis_idx[i]
            txt.plot(TREE_MARK, srow)
            ; '>' marks the selection in the UNFOCUSED pane; focused gets a bar
            if i == tree_cursor and focus != FOCUS_TREE
                txt.chrout('>')
            else
                txt.spc()
            build_tree_line(idx)
            txt.print(treeline)
            if i == tree_cursor and focus == FOCUS_TREE
                hilite_row(TREE_MARK, TREE_BAR_R, srow, shared.HILITE)
        }
    }

    sub tree_scroll_marks() {
        ; the ^/v indicators sit in the pane's right edge column, which blank_span wipes;
        ; re-assert them (only when there is more above / below the window)
        if tree_top != 0
            txt.setchr(TREE_BAR_R, PANE_TOP, sc:'^')
        if tree_top + PANE_H < xtree.vis_count
            txt.setchr(TREE_BAR_R, PANE_BOT, sc:'v')
    }

    sub draw_tree() {
        if tree_cursor < tree_top
            tree_top = tree_cursor
        if tree_cursor >= tree_top + PANE_H
            tree_top = tree_cursor - PANE_H + 1
        ubyte row
        for row in 0 to PANE_H-1
            draw_tree_row(tree_top + row)
        tree_scroll_marks()
        tree_top_shown = tree_top
        tree_cursor_shown = tree_cursor
    }

    sub draw_tree_cursor() {
        ; light update after a pure cursor move: if the pane scrolled (top changed) fall
        ; back to a full repaint; otherwise just un-ink the old row and ink the new one.
        if tree_cursor < tree_top
            tree_top = tree_cursor
        if tree_cursor >= tree_top + PANE_H
            tree_top = tree_cursor - PANE_H + 1
        if tree_top != tree_top_shown {
            draw_tree()
            return
        }
        draw_tree_row(tree_cursor_shown)        ; erase the old highlight/marker
        draw_tree_row(tree_cursor)              ; draw the new one
        tree_scroll_marks()                     ; a corner indicator may have been blanked
        tree_cursor_shown = tree_cursor
    }

    sub build_tree_line(ubyte idx) {
        ; compose connectors + expand marker + name into treeline[], bounded to the
        ; tree pane width so it can never spill into the divider.
        ubyte depth = xtree.dx_depth(idx)
        ; for each ancestor level, record whether that node is its parent's last child
        ubyte n = idx
        ubyte dd = depth
        while dd != 0 {
            levlast[dd] = 0
            if xtree.d_next_sibling[n] == xtree.NONE
                levlast[dd] = 1
            n = xtree.dx_parent(n)
            dd--
        }
        ubyte p = 0
        ; ancestor prefix: a continuation bar where the ancestor still has siblings below
        if depth >= 2 {
            for g_ndx in 1 to depth-1 {
                if levlast[g_ndx] != 0
                    treeline[p] = ' '
                else
                    treeline[p] = '│'
                p++
                treeline[p] = ' '
                p++
            }
        }
        ; this node's own connector
        if depth >= 1 {
            if levlast[depth] != 0
                treeline[p] = '└'
            else
                treeline[p] = '├'
            p++
            treeline[p] = '─'
            p++
        }
        ; expand state: + collapsed, - expanded, ─ for a leaf directory
        if xtree.has_kids(idx) {
            if xtree.is_expanded(idx)
                treeline[p] = '-'
            else
                treeline[p] = '+'
        } else {
            treeline[p] = '─'
        }
        p++
        treeline[p] = ' '
        p++
        ; name, clamped to the remaining width of the tree pane
        const ubyte maxp = TREE_BAR_R - TREE_TEXT + 1
        uword nm = xtree.name_ptr(idx)
        ubyte ni = 0
        while p < maxp and @(nm+ni) != 0 {
            treeline[p] = @(nm+ni)
            p++
            ni++
        }
        treeline[p] = 0
    }

    sub draw_file_header() {
        ubyte name_col = pane_mark_col + 1      ; column heads sit over the names, wherever those are
        blank_span(pane_mark_col, FILE_BAR_R, FILE_HDR)
        txt.color(shared.CLR_ACCENT)
        txt.plot(name_col, FILE_HDR)
        txt.print("Name")
        txt.color(shared.CLR_FG)
        ; "(Total blocks: N)" centered in the file pane, between the Name and Size labels
        void strings.copy("(Total blocks: ", cm_dst)
        box_append_long(cur_blocks)
        void strings.append(cm_dst, ")")
        txt.plot(name_col + (FILE_BAR_R - name_col + 1 - lsb(strings.length(cm_dst))) / 2, FILE_HDR)
        txt.print(cm_dst)
        txt.color(shared.CLR_ACCENT)
        txt.plot(FILE_SIZE, FILE_HDR)
        txt.print("Size")
        txt.color(shared.CLR_FG)
    }

    sub draw_file_row(uword i) {
        ; paint ONE file row: file entry i at its screen row (assumes i is in the window)
        ubyte srow = FILE_TOP + lsb(i - file_top)       ; (i - file_top) is always 0..FILE_VIS-1
        blank_span(pane_mark_col, FILE_BAR_R, srow)
        if i < xfiles.ft_count {
            txt.plot(pane_mark_col, srow)
            if i == file_cursor and focus != FOCUS_FILE
                txt.chrout('>')
            else
                txt.spc()
            if xfiles.is_tagged(i)
                txt.chrout('*')
            else
                txt.spc()
            xfiles.get_name(i, namebuf)
            print_trunc(namebuf, pane_name_w)
            txt.plot(FILE_SIZE, srow)
            txt.print_uw(xfiles.get_blocks(i))
            ; tagged files are flagged by the '*' marker only - the row keeps the
            ; normal colors (no bar). The focused selection bar still wins on the cursor.
            if i == file_cursor and focus == FOCUS_FILE
                hilite_row(pane_mark_col, FILE_BAR_R, srow, shared.HILITE)
        }
    }

    sub file_scroll_marks() {
        if file_top != 0
            txt.setchr(FILE_BAR_R, FILE_TOP, sc:'^')
        if file_top + FILE_VIS < xfiles.ft_count
            txt.setchr(FILE_BAR_R, PANE_BOT, sc:'v')
    }

    sub draw_files() {
        draw_file_header()
        if file_cursor < file_top
            file_top = file_cursor
        if file_cursor >= file_top + FILE_VIS
            file_top = file_cursor - FILE_VIS + 1
        ubyte row
        for row in 0 to FILE_VIS-1
            draw_file_row(file_top + row)
        if xfiles.ft_count == 0 {
            txt.plot(pane_mark_col + 1, FILE_TOP)
            if xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0
                txt.print("(Enter to log)")
            else
                txt.print("(no files)")
        }
        file_scroll_marks()
        file_top_shown = file_top
        file_cursor_shown = file_cursor
    }

    sub draw_files_cursor() {
        ; light update after a pure cursor move (see draw_tree_cursor). The file HEADER
        ; (Total blocks) is untouched - a cursor move never changes those counts.
        if file_cursor < file_top
            file_top = file_cursor
        if file_cursor >= file_top + FILE_VIS
            file_top = file_cursor - FILE_VIS + 1
        ; In a scoped listing the header path belongs to the HIGHLIGHTED FILE, so it is no longer
        ; static across a cursor move - it is the only thing telling you which directory the row
        ; under the bar came from, and a stale one is worse than none.
        if xfiles.file_scope != xfiles.SCOPE_DIR
            draw_status()
        if file_top != file_top_shown {
            draw_files()
            return
        }
        draw_file_row(file_cursor_shown)
        draw_file_row(file_cursor)
        file_scroll_marks()
        file_cursor_shown = file_cursor
    }

    sub draw_commands() {
        ; the bottom command menu (rows CMDROW1/CMDROW2) is drawn by the uiutil overlay - all its
        ; label strings live there now. Pass the state it varies on (the overlay can't see globals).
        if ui_ok
            ui_draw_commands(menu_mode, focus, del_char, xfiles.sort_mode, find_char, move_char, srch_char, view_char)
    }

    ; ---------- file operations ----------

    sub cd_to_entry(uword i) {
        ; chdir to the directory that OWNS file-pane row i, and leave its path in pathbuf.
        ;
        ; Every per-file operation goes through this instead of building cur_dir's path directly.
        ; In a normal single-directory listing a row's dir IS cur_dir, so nothing changes; in a scoped
        ; view (Showall) the rows come from all over the disk and the owning directory is the only
        ; correct answer. Getting this wrong does not fail loudly - it operates on a same-named file
        ; in the wrong directory - so the rule is that NO file op may call build_path(cur_dir).
        xtree.build_path(xfiles.row_dir(i), pathbuf)
        diskio.chdir(pathbuf)
    }

    sub rebuild_view() -> uword {
        ; Rebuild whatever the pane is listing, in place. Every op that mutates files (delete,
        ; rename, copy/move) or changes the listing rules (FileSpec, Sort) calls this instead of
        ; build_index(cur_dir) directly - in a scoped view that would silently swap the whole list
        ; back to the current directory mid-operation.
        if xfiles.file_scope == xfiles.SCOPE_DIR
            return xfiles.build_index(cur_dir)
        if xfiles.file_scope == xfiles.SCOPE_BRANCH
            return xfiles.build_scoped_index(branch_root)
        return xfiles.build_scoped_index(xtree.NONE)
    }

    sub tagged_in_view() -> uword {
        ; Number of tagged files IN THE CURRENT LISTING.
        ;
        ; xtree.dx_tag(cur_dir) is a per-directory counter and is the right answer only for a
        ; single-directory view; a scoped listing draws from many directories, so the count has to
        ; come from the rows actually on display. O(n) over the index, which is nothing next to the
        ; disk work every caller is about to do.
        if xfiles.file_scope == xfiles.SCOPE_DIR
            return xtree.dx_tag(cur_dir)
        uword tagged = 0
        uword row = 0
        while row < xfiles.ft_count {
            if xfiles.is_tagged(row)
                tagged++
            row++
        }
        return tagged
    }

    sub clamp_file_cursor() {
        ; keep file_cursor within the current file list (0 when the list is empty).
        ; factored out of the ~8 ops that rebuild the file index (relog/copy/move/etc.)
        if xfiles.ft_count == 0
            file_cursor = 0
        else if file_cursor >= xfiles.ft_count
            file_cursor = xfiles.ft_count - 1
    }

    sub op_delete() {
        if xfiles.ft_count == 0
            return
        xfiles.get_name(file_cursor, namebuf)
        box_compose_name("Delete ", namebuf, "?")
        if confirm(cm_dst, false) {                 ; default No (destructive)
            cd_to_entry(file_cursor)
            diskio.delete(namebuf)
            xfiles.hide(file_cursor)   ; drop from the cached view
            void rebuild_view()
            clamp_file_cursor()
            if xfiles.ft_count == 0                 ; last file gone -> hop back to the dir pane
                change_focus(FOCUS_TREE)
            draw_status()                           ; repaint the panes FIRST so the file is
            draw_tree()                             ; visibly gone before the "done" banner
            draw_files()                            ; (the banner box only covers CMDROW1..CMDROW2)
            banner_delete(1)                        ; result banner, like copy/move
        }
    }

    sub op_delete_tagged() {
        uword ntag = tagged_in_view()
        if ntag == 0 {
            flash("no tagged files")
            return
        }
        ubyte mode = ask_confirm_each(ntag)         ; 1 = confirm each, 0 = delete all, 255 = cancel
        if mode == 255
            return
        ; NB: no chdir here - a scoped listing spans directories, so each file is chdir'd to
        ; individually inside the loop (see cd_to_entry).
        bool allrem = mode == 0                     ; "No" at the top prompt -> delete all, no asking
        uword ndel = 0
        uword total = ntag                          ; tagged count, for the "(n of N)" progress
        uword cur = 0                               ; tagged files processed so far
        ; Walk DOWNWARD: deleting a file + reindexing only shifts indices ABOVE it, which we've
        ; already visited, so lower indices stay valid. Local `fi` (not g_ndx): the per-file
        ; prompt and the live repaint both clobber the shared g_ndx counter.
        uword fi = xfiles.ft_count
        while fi != 0 {
            fi--
            if xfiles.is_tagged(fi) {
                cur++
                xfiles.get_name(fi, namebuf)
                ubyte act = 1                       ; default action: delete
                if not allrem {
                    act = ask_delete_this(namebuf)  ; 1=del 0=skip 2=all 255=cancel
                    if act == 2 {
                        allrem = true               ; "All Files" -> stop asking, delete the rest
                        act = 1
                    } else if act == 255
                        break                       ; cancel the remaining files
                }
                if act == 1 {
                    cd_to_entry(fi)                 ; this row's OWN directory
                    diskio.delete(namebuf)
                    xfiles.hide(fi)  ; clears its tag + marks deleted
                    ndel++
                    void rebuild_view()    ; recompact the cached view...
                    clamp_file_cursor()
                    draw_files()                        ; ...and repaint so the file leaves the screen live
                    box_open()                          ; live "Deleting... (n of N)" progress, like copy/move
                    box_left(CMDROW1, "Deleting...")
                    box_progress(cur, total)            ; "(n of N)" on CMDROW2
                }
            }
        }
        clamp_file_cursor()
        if xfiles.ft_count == 0                     ; last file gone -> hop back to the dir pane
            change_focus(FOCUS_TREE)
        banner_delete(ndel)                         ; result banner, like copy/move
    }

    sub op_mkdir() {
        ; create a new subdirectory inside the selected (tree) directory
        if not input_line("New dir:", inputbuf, 49, "mkdir", false, false)
            return
        xtree.build_path(cur_dir, pathbuf)
        diskio.chdir(pathbuf)
        diskio.mkdir(inputbuf)
        ; reflect it in the tree if this directory is already logged
        if xtree.d_flags[cur_dir] & xtree.FL_SCANNED != 0 {
            void xtree.add_child(cur_dir, inputbuf)
            xtree.d_flags[cur_dir] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
            set_tree_cursor_to(cur_dir)
        }
    }

    sub op_prune() {
        ; P (tree col): recursively delete the selected directory and EVERYTHING under it.
        ; Guarded by a typed confirmation - the user must retype the directory's exact name.
        ; The prune engine (miscutil overlay, bank 3) does the disk work; on success we unlink
        ; the node from the tree.
        ubyte idx = cur_dir
        if idx == 0 {
            flash("can't prune the drive root")
            return
        }
        ; The EMPTY history category is deliberate - it switches the history UI off for this one
        ; prompt (input_line: usehist = misc_ok and length(histname) != 0). Typing "prune" out in
        ; full is the speed bump in front of an irreversible subtree delete; with history, UP+ENTER
        ; would confirm it in two keys. Do not "fix" this by naming a category.
        if not input_line("PRUNE - type 'prune' to confirm:", inputbuf, 49, "", false, false)
            return
        if strings.compare(inputbuf, "prune") != 0 {
            flash("not confirmed - prune cancelled")
            return
        }
        ubyte parent = xtree.dx_parent(idx)
        ubyte uprow = tree_cursor                       ; pruned dir's visible row (>=1; root
        if uprow != 0                                   ; is never prunable) -> land ONE row up,
            uprow--                                     ; i.e. on the previous entry, not the top
        xtree.build_path(parent, pathbuf)               ; parent dir (absolute, trailing '/')
        void strings.copy(xtree.name_ptr(idx), namebuf) ; stable copy of the target name
        box_compose_name("pruning ", namebuf, " ...")   ; transient status; the result box follows
        box_open()
        box_left(CMDROW1, cm_dst)
        bool ok = false
        if misc_ok {
            ; the engine removes ONE directory per call (deepest leaf first); loop until the target
            ; itself goes (0) or it errors (255), showing a live "(Dir: N)" counter like Find does.
            uword nremoved = 0
            repeat {
                ubyte pr = prune_dir(&pathbuf, &namebuf)    ; banked engine (miscutil overlay, bank 3)
                if pr == 255
                    break                                   ; error -> ok stays false (partial delete)
                nremoved++
                txt.plot(BANNER_LEFT, CMDROW2)              ; live counter on row 2 of the status box
                txt.print("(Dir: ")
                txt.print_uw(nremoved)
                txt.chrout(')')
                hilite_row(0, 79, CMDROW2, shared.CLR_BOTTOM_PROMPT_BG)
                if pr == 0 {
                    ok = true                               ; target removed -> whole subtree gone
                    break
                }
            }
        }
        diskio.chdir(pathbuf)                           ; restore cwd to the parent
        if ok {
            xtree.unlink(idx)
            xtree.rebuild_visible()
            if uprow >= xtree.vis_count                 ; safety clamp after the node vanished
                uprow = xtree.vis_count - 1
            tree_cursor = uprow
            if tree_cursor < tree_top                   ; keep the cursor on-screen
                tree_top = tree_cursor
            select_dir(xtree.vis_idx[uprow])
            box_open()                                      ; 2-row white box, like relog/copy
            box_left(CMDROW1, "Prune OK")
            wait_or_key(90)                                  ; ~1.5s, or any key to dismiss sooner
            box_close()
        } else {
            flash("Prune failed (partial) - rescan the dir")
        }
    }

    sub op_delete_dir() {
        ; D (tree col): delete the selected directory, but ONLY if it is empty. rmdir on
        ; CMDR-DOS / hostfs refuses a non-empty directory, so we let it enforce emptiness;
        ; use Prune (Alt-P) to delete a whole non-empty subtree.
        ubyte idx = cur_dir
        if idx == 0 {
            flash("can't delete the drive root")
            return
        }
        void strings.copy(xtree.name_ptr(idx), namebuf)     ; stable copy of the dir name
        xtree.build_path(idx, pathbuf)                      ; the folder's own path
        if not xscan.dir_is_empty(pathbuf) {                ; check emptiness up front, so a
            flash("folder not empty - use Prune for a tree") ; non-empty folder is refused
            return                                          ; before we bother confirming
        }
        box_compose_name("Delete empty folder ", namebuf, "?")
        if not confirm(cm_dst, false)               ; default No (destructive)
            return
        ubyte parent = xtree.dx_parent(idx)
        ubyte uprow = tree_cursor                           ; land one row up once it vanishes
        if uprow != 0
            uprow--
        xtree.build_path(parent, pathbuf)                   ; parent dir (absolute, trailing '/')
        diskio.chdir(pathbuf)
        diskio.rmdir(namebuf)
        if diskio.status_code() != 0 {
            flash("delete failed - relog the folder")        ; emptiness was pre-checked
            return
        }
        xtree.unlink(idx)                                   ; gone on disk -> drop it from the tree
        xtree.rebuild_visible()
        if uprow >= xtree.vis_count
            uprow = xtree.vis_count - 1
        tree_cursor = uprow
        if tree_cursor < tree_top
            tree_top = tree_cursor
        select_dir(xtree.vis_idx[uprow])
        toast("folder deleted")
    }

    sub op_rename_dir() {
        ; R (tree col): rename the selected directory, on disk and in the tree.
        ubyte idx = cur_dir
        if idx == 0 {
            flash("can't rename the drive root")
            return
        }
        if not input_line("Rename dir to:", inputbuf, 49, "rename", false, false)
            return
        if strings.length(inputbuf) == 0
            return
        ; Capture the old name AFTER input_line (see op_rename): input_line's history/dir-pick
        ; repaint runs draw_file_row, which overwrites the shared namebuf with the last FILE.
        void strings.copy(xtree.name_ptr(idx), namebuf)     ; stable copy of the old name
        if strings.compare_nocase(inputbuf, namebuf) == 0 {
            flash("same name (case is ignored on this disk)")
            return                                          ; unchanged, incl. case-only (Foo==foo)
        }
        ; a scanned parent lists ALL its sub-dirs, so a name clash is a visible sibling
        ubyte parent = xtree.dx_parent(idx)
        ubyte sib = xtree.d_first_child[parent]
        while sib != xtree.NONE {
            if sib != idx and strings.compare_nocase(xtree.name_ptr(sib), inputbuf) == 0 {
                flash("a folder named that already exists")
                return
            }
            sib = xtree.d_next_sibling[sib]
        }
        ; a comma in either name breaks the "r:new=old" DOS command (comma = separator)
        if strings.contains(inputbuf, ',') or strings.contains(namebuf, ',') {
            flash(MSG_ERR_COMMA)
            return
        }
        xtree.build_path(parent, pathbuf)                   ; parent dir (absolute, trailing '/')
        diskio.chdir(pathbuf)
        diskio.rename(namebuf, inputbuf)                    ; r:new=old on the renamed sub-dir
        if diskio.status_code() != 0 {
            flash("rename failed")                          ; DOS refused it - don't desync the tree
            return
        }
        xtree.rename_node(idx, inputbuf)                    ; keep the tree's name in sync
    }

    ; wildcard rename expansion (last_dot / merge_seg / wildcard_name) now lives in the
    ; miscutil.p8 bank-3 overlay, called via the wildcard_expand extsub. See op_rename.

    sub op_rename() {
        if xfiles.ft_count == 0
            return
        if not input_line("Rename to (* ? ok):", inputbuf, 49, "rename", false, false)
            return
        ; Capture the old name AFTER input_line: namebuf is shared scratch that the file-list
        ; redraw (draw_file_row) overwrites with the LAST file's name, and input_line repaints the
        ; panes via full_redraw() on history recall (Up) / dir pick (F2). Fetching it here - once
        ; the prompt is done and file_cursor is final - keeps it the ACTUAL highlighted file.
        xfiles.get_name(file_cursor, namebuf)       ; old name
        ; Reject commas on the RAW typed input, BEFORE wildcard expansion: in a no-dot pattern
        ; like "*,dat" the '*' swallows the whole segment (comma included), so a post-expansion
        ; check would miss it. CMDR-DOS RENAME is "r:new=old" - a comma in either name is a
        ; command separator and would fail silently. (To change an extension, use a dot: "*.dat".)
        if strings.contains(inputbuf, ',') or strings.contains(namebuf, ',') {
            flash(MSG_ERR_COMMA)
            return
        }
        ; if the typed name uses wildcards, merge them with the old name in place
        ; (banked: the expander lives in the miscutil overlay, called via extsub @bank 3)
        if misc_ok and (strings.contains(inputbuf, '*') or strings.contains(inputbuf, '?')) {
            wildcard_expand(&namebuf, &inputbuf, &cm_dst)
            void strings.copy(cm_dst, inputbuf)
        }
        cd_to_entry(file_cursor)
        ; refuse to clobber an existing file (unless it's the same name we started with).
        ; f_open succeeds only if the target already exists, so use it as the probe.
        if strings.compare_nocase(inputbuf, namebuf) != 0 {
            if diskio.f_open(inputbuf) {
                diskio.f_close()
                flash("a file named that already exists")
                return
            }
        }
        diskio.rename(namebuf, inputbuf)
        if diskio.status_code() != 0 {
            ; the DOS rename failed (e.g. a comma/other separator in the on-disk name that the
            ; "r:new=old" command can't express) - report it instead of silently syncing the
            ; display to a name that isn't actually on disk
            flash("rename failed")
            return
        }
        if strings.length(inputbuf) <= xfiles.name_cap(file_cursor) {
            ; new name fits the existing record slot: overwrite in place (keeps tags)
            void xfiles.rename_inplace(file_cursor, inputbuf)
            void rebuild_view()
        } else {
            ; longer than the slot: re-read the directory so the full-length name shows
            ; (the append-only arena can't grow a record). This resets the dir's tags.
            void xscan.refresh_files(cur_dir)
            void rebuild_view()
        }
        ; keep the cursor on the same row (don't chase the file to its new sorted slot,
        ; which made it look like the bottom file got renamed)
        clamp_file_cursor()
    }

    sub ensure_slash(str s) {
        ; make sure path string s ends in '/'
        ubyte l = lsb(strings.length(s))
        if l == 0 or s[l-1] != '/' {
            s[l] = '/'
            s[l+1] = 0
        }
    }

    sub dest_exists(str fname) -> bool {
        ; true if a file named fname already exists in the CURRENT directory (the dest dir
        ; the caller chdir'd into). f_open of a missing file returns false, so a clean open
        ; (which we immediately close) means the name is taken.
        if diskio.f_open(fname) {
            diskio.f_close()
            return true
        }
        return false
    }

    sub ask_overwrite(str fname) -> ubyte {
        ; name-conflict dialog (drawn by uiutil): "Overwrite <name>?" + "Yes [No] All Skip all
        ; Esc Cancel". ENTER/N skip this, Esc = skip all. Returns folded 'y'/'n'/'a'/'s'.
        ; NO box_close - the copy loop's "Copying..." / result box redraws over it. Degrades to
        ; 's' (skip all remaining) if the overlay isn't loaded.
        box_open()
        if ui_ok
            return ui_ask_overwrite(fname)
        return 's'
    }

    sub copy_one(str fname) -> ubyte {
        ; stream-copy cm_sdir+fname (absolute source, READ channel) into fname in the
        ; CURRENT directory (WRITE channel). The caller has chdir'd into the dest dir, so
        ; the dest is opened by BARE NAME: hostfs lands writes in the current dir, and an
        ; absolute write path is the case that fails to resolve. The two channels are
        ; different logical files, so both stay open while we copy in 255-byte chunks.
        ; Returns 0 = failed (cm_fail set), 1 = copied, 2 = skipped (target exists, not
        ; overwritten). Honours the batch overwrite policy ow_mode (0 ask / 1 all / 2 skip).
        if not misc_ok {
            cm_fail = 4                          ; copy byte-pump lives in the overlay; it's not loaded
            return 0
        }
        void strings.copy(cm_sdir, cm_src)
        void strings.append(cm_src, fname)

        if dest_exists(fname) {                  ; a file of this name is already in the dest
            if ow_mode == 2
                return 2                         ; policy: skip all existing
            if ow_mode == 0 {                    ; ask; A / S also set the batch policy
                ubyte ans = ask_overwrite(fname)
                if ans == 'a' {
                    ow_mode = 1                  ; overwrite this + all remaining
                } else if ans == 's' {
                    ow_mode = 2                  ; skip this + all remaining
                    return 2
                } else if ans != 'y' {
                    return 2                     ; 'n' / anything else: skip just this one
                }
            }
            ; ow_mode == 1, or 'y' / 'a' chosen: fall through and overwrite
        }

        ; hand the actual byte-copy to the overlay (its 255-byte buffer no longer costs main RAM).
        ; cm_src = absolute source path, fname = bare dest name in the CWD we chdir'd into.
        uword res = stream_copy(cm_src, fname)
        cm_fail = lsb(res)                       ; 0 copied, 1 src-open, 2 dst-open, 3 write
        if cm_fail == 0
            return 1
        cm_wstat = msb(res)                      ; DOS code (meaningful on dst-open / write fail)
        return 0
    }

    sub dir_exists(str path) -> bool {
        ; true if `path` is a directory we can cd into. chdir, then read the DOS status:
        ; code 0 == the cd landed (dir is there). status_code() is already linked (xscan
        ; uses it after rmdir), so this adds no new machinery.
        diskio.chdir(path)
        return diskio.status_code() == 0
    }

    sub make_last_dir(str fullpath) {
        ; create the final segment of an absolute dir path (with trailing '/') inside its
        ; parent, which is assumed to exist. Splits into pathbuf(parent) + namebuf(leaf).
        ubyte e = lsb(strings.length(fullpath))
        if e != 0 and fullpath[e-1] == '/'
            e--                                 ; e = one past the leaf (drop trailing '/')
        ubyte s = e
        while s != 0 and fullpath[s-1] != '/'
            s--                                 ; s = first char of the leaf segment
        ubyte k = 0
        ubyte i = s
        while i < e {
            namebuf[k] = fullpath[i]            ; leaf -> namebuf
            k++
            i++
        }
        namebuf[k] = 0
        i = 0
        while i < s {
            pathbuf[i] = fullpath[i]            ; parent (keeps trailing '/') -> pathbuf
            i++
        }
        pathbuf[i] = 0
        diskio.chdir(pathbuf)
        diskio.mkdir(namebuf)
        ; show the new folder in the tree right away (if its parent is a logged node),
        ; mirroring op_mkdir - otherwise a freshly-created copy/move target never appears.
        ; The new node is marked SCANNED: it is a brand-new EMPTY dir (make_dirs only calls
        ; us for levels that failed dir_exists), so its contents are fully known - nothing.
        ; That also lets a multi-level chain register: the NEXT deeper level finds this one
        ; already scanned, so add_child fires for it too instead of waiting for a relog.
        ubyte par = find_dir_by_path(pathbuf)
        if par != xtree.NONE and xtree.d_flags[par] & xtree.FL_SCANNED != 0 {
            ubyte kid = xtree.add_child(par, namebuf)
            if kid != xtree.NONE
                xtree.d_flags[kid] |= xtree.FL_SCANNED
            xtree.d_flags[par] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
        }
    }

    sub make_dirs(str fullpath) {
        ; Create EVERY missing directory along an absolute path (leading '/', trailing '/'),
        ; shallowest first: "/dir1/dir2/" makes dir1, then dir2 inside it. Walks the '/'
        ; boundaries, temporarily NUL-terminating `fullpath` after each slash to test that
        ; prefix; a missing level is made with make_last_dir (whose parent is guaranteed to
        ; exist because we created it on the previous pass). No extra buffer needed - the
        ; terminator is put back each step, so `fullpath` is intact on return.
        ubyte n = lsb(strings.length(fullpath))
        ubyte i = 1                             ; skip the leading '/'
        while i < n {
            if fullpath[i] == '/' {
                ubyte saved = fullpath[i+1]
                fullpath[i+1] = 0              ; prefix = fullpath[0..i]  (ends in '/')
                if not dir_exists(fullpath)
                    make_last_dir(fullpath)   ; make this one level inside its existing parent
                fullpath[i+1] = saved
            }
            i++
        }
    }

    sub ensure_dest_dir(str path) -> bool {
        ; make sure the copy/move destination exists; if not, offer to create it. Returns
        ; false if it is missing AND the user declines, OR the create failed (caller aborts).
        ; On a true return the CWD is left inside `path` (dir_exists chdir'd into it), which
        ; is exactly what copy_one needs - it writes each file by bare name into the CWD.
        if dir_exists(path)
            return true
        if not confirm_enter("Destination dir missing. Create?")     ; ENTER = create, ESC = cancel
            return false
        make_dirs(path)                         ; create the whole chain, not just the leaf
        if dir_exists(path)                     ; confirm it really got created (and enter it)
            return true
        flash("could not create dest folder")
        return false
    }

    sub op_copymove(bool is_move, bool use_tags) {
        ; use_tags=false (plain C/M): act on the single highlighted file, IGNORING tags.
        ; use_tags=true  (CTRL C/O):  act on every tagged file in the CURRENT LISTING - which in a
        ; scoped view (Showall) spans the whole disk. copy_one reads through an absolute cm_sdir and
        ; writes by bare name into the cwd, so gathering files from many directories into one
        ; destination only needs cm_sdir rebuilt per row; the destination cwd never moves.
        if xfiles.ft_count == 0
            return
        if use_tags and tagged_in_view() == 0 {
            flash("no tagged files")
            return
        }

        if is_move {
            if not input_line("Move to dir:", inputbuf, 79, "copymove", true, false)   ; shared C/M history
                return
        } else {
            if not input_line("Copy to dir:", inputbuf, 79, "copymove", true, false)   ; shared C/M history
                return
        }

        ; source dir (absolute, trailing slash)
        xtree.build_path(cur_dir, cm_sdir)
        ; dest dir: absolute as typed, else relative to the drive root (base_path)
        if inputbuf[0] == '/' {
            void strings.copy(inputbuf, cm_ddir)
        } else {
            void strings.copy(xtree.base_path, cm_ddir)
            ensure_slash(cm_ddir)
            void strings.append(cm_ddir, inputbuf)
        }
        ensure_slash(cm_ddir)

        ; Only a single-directory listing has ONE source dir to compare up front. A scoped listing
        ; may legitimately contain files that already live in the destination; those are skipped
        ; individually inside the loop instead of aborting the whole batch.
        if xfiles.file_scope == xfiles.SCOPE_DIR and strings.compare(cm_sdir, cm_ddir) == 0 {
            flash("source and dest are the same dir")
            return
        }
        if not ensure_dest_dir(cm_ddir)         ; offer to create a missing destination
            return
        diskio.chdir(cm_ddir)                   ; run the copy with the DEST as cwd - hostfs lands
                                                ; writes in the current dir, so a freshly created
                                                ; target must be entered (an existing one already is)
        box_open()                              ; status box during the copy (covers the prompt)
        if is_move
            box_left(CMDROW1, "Moving...")
        else
            box_left(CMDROW1, "Copying...")
        uword done = 0
        uword failed = 0
        uword skipped = 0
        cm_fail = 0
        ow_mode = 0                             ; ask on the first overwrite conflict this batch
        uword total = 1                         ; files we'll actually touch (for "n of N")
        if use_tags
            total = tagged_in_view()
        uword cur = 0
        ; a while loop, not `for i in 0 to ft_count-1`: ft_count is a uword now and prog8 wants the
        ; loop variable to match. next_row is stepped before the body so the two `continue`s below
        ; can't skip the increment.
        uword i
        uword next_row = 0
        while next_row < xfiles.ft_count {
            i = next_row
            next_row++
            if use_tags and not xfiles.is_tagged(i)
                continue
            if not use_tags and i != file_cursor
                continue
            cur++
            box_progress(cur, total)
            ; this row's OWN source directory - the whole point of the scoped batch. (In a
            ; single-directory listing this rebuilds the same string every pass, which is cheap
            ; next to the file copy that follows.)
            xtree.build_path(xfiles.row_dir(i), cm_sdir)
            if strings.compare(cm_sdir, cm_ddir) == 0 {
                skipped++                       ; already living in the destination
                continue
            }
            xfiles.get_name(i, namebuf)
            when copy_one(namebuf) {
                1 -> {
                    done++
                    if is_move {
                        ; remove the source copy and drop it from the cached view
                        void strings.copy(cm_sdir, cm_src)
                        void strings.append(cm_src, namebuf)
                        diskio.delete(cm_src)
                        xfiles.hide(i)
                    }
                }
                2 -> skipped++
                else -> failed++
            }
        }

        ; refresh the source view (moved files vanish) and the destination
        if is_move
            void rebuild_view()
        ubyte dd = find_dir_by_path(cm_ddir)
        if dd == xtree.NONE {
            ; The destination did not exist and ensure_dest_dir CREATED it. make_dirs only makes
            ; the folder on disk - nothing told the tree about it - so without this the new folder
            ; and everything just copied into it stay invisible until the user manually re-logs the
            ; parent. open_new_path re-lists each logged level on the way down, which is what finds
            ; a child made after its parent was logged.
            dd = xscan.open_new_path(cm_ddir)
            if dd != xtree.NONE {
                void xscan.scan_dir(dd)         ; the descent logs the PARENT's children, not dd's files
                xtree.rebuild_visible()
                set_tree_cursor_to(cur_dir)     ; new rows shifted the visible list under the cursor
                dirty_full = true
            }
        } else if xtree.d_flags[dd] & xtree.FL_SCANNED != 0 {
            void xscan.refresh_files(dd)
            if dd == cur_dir
                void rebuild_view()
        }

        clamp_file_cursor()
        if is_move and xfiles.ft_count == 0     ; moved the last file out -> back to the dir pane
            change_focus(FOCUS_TREE)

        if done == 0 and skipped == 0
            copy_diag()
        else
            banner_copymove(is_move, done, failed, skipped)
    }

    sub find_dir_by_path(str p) -> ubyte {
        ; locate the tree node whose absolute path equals p (both have trailing '/')
        for g_ndx in 0 to xtree.dir_count-1 {
            xtree.build_path(g_ndx, cm_src)         ; cm_src as scratch
            if strings.compare(cm_src, p) == 0
                return g_ndx
        }
        return xtree.NONE
    }

    sub op_filespec() {
        ; set the file-display wildcard (e.g. *.prg). ENTER on a blank line inserts * (= show all).
        if not input_line(petscii:"File spec (eg *.prg, ←┘ = *):", inputbuf, 31, "filespec", false, true)
            return
        if strings.length(inputbuf) == 0
            void strings.copy("*", inputbuf)        ; blank ENTER -> show all
        xfiles.set_spec(inputbuf)
        void rebuild_view()
        file_top = 0
        clamp_file_cursor()
    }

    sub op_tag_by_spec() {
        ; Ctrl-S: tag every visible file in the current dir matching a wildcard
        if not input_line("Tag matching (eg *.bak):", inputbuf, 31, "tagspec", false, false)
            return
        void strings.copy(inputbuf, cm_dst)         ; lowercase a copy for nocase match
        void strings.lower(cm_dst)
        uword cnt = xfiles.tag_by_spec(cm_dst)
        void strings.copy("Tagged ", cm_dst)
        box_append_uw(cnt)
        void strings.append(cm_dst, " file(s)")
        box_open()
        box_left(CMDROW1, cm_dst)
        box_left(CMDROW2, MSG_PRESS_ANY_KEY)
        void wait_key()
        box_close()
    }

    sub op_sort() {
        ; Alt-S: cycle the file sort order (name -> ext -> size) and re-sort the pane
        xfiles.sort_mode++
        if xfiles.sort_mode > 2
            xfiles.sort_mode = 0
        void rebuild_view()
        clamp_file_cursor()
        ; brief 4-row white box so the new order is obvious even with 0/1 files
        box_open()
        box_left(CMDROW1, "Sort order:")
        when xfiles.sort_mode {
            1 -> box_left(CMDROW2, "extension")
            2 -> box_left(CMDROW2, "size")
            else -> box_left(CMDROW2, "name")
        }
        wait_or_key(45)             ; ~0.75s, or any key; then the menu repaints over it
        box_close()
        dirty_files = true
        dirty_cmd = true            ; the ALT menu shows the active sort mode
    }

    sub op_relog() {
        ; Alt-F3: re-read the current directory from disk so changes show up. Which side
        ; gets relogged follows the focused pane: on the DIRECTORY column we re-scan the
        ; sub-folders (picking up new directories); on the FILE column we re-read files.
        ; A first-time (unlogged) directory always gets a full scan (folders + files).
        diskio.chdir(xtree.base_path)           ; relog from ROOT: reset the CWD so a stale one
                                                ; (left by copy/move/prune) can't misdirect the
                                                ; build_path chdir the re-read does next
        if xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0 {
            void xscan.scan_dir(cur_dir)
            if xtree.has_kids(cur_dir)
                xtree.d_flags[cur_dir] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
            set_tree_cursor_to(cur_dir)
        } else if focus == FOCUS_TREE {
            ; relog FOLDERS: add any sub-directories created since the last log
            ubyte added = xscan.refresh_dirs(cur_dir)
            if xtree.has_kids(cur_dir)
                xtree.d_flags[cur_dir] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
            set_tree_cursor_to(cur_dir)
            box_open()
            box_left(CMDROW1, "relogged folders")
            void strings.copy("+", cm_dst)
            box_append_uw(added)
            void strings.append(cm_dst, " new")
            box_left(CMDROW2, cm_dst)
            wait_or_key(120)
            box_close()
            return
        } else {
            void xscan.refresh_files(cur_dir)
        }
        void rebuild_view()
        recount_blocks()
        clamp_file_cursor()
        box_open()
        box_left(CMDROW1, "relogged")
        cm_dst[0] = 0
        box_append_uw(xfiles.ft_count)
        void strings.append(cm_dst, " file(s)")
        box_left(CMDROW2, cm_dst)
        wait_or_key(90)            ; ~1.5s, or any key to dismiss sooner
        box_close()
    }

    sub op_edit() {
        ; E (file pane): open the selected file in the ROM-resident X16 Edit. We give
        ; the editor the banks ABOVE our file arena so its text buffer doesn't clobber
        ; the cached records. X16Edit runs modally  way to and returns here when the user exits.
        if xfiles.ft_count == 0
            return
        ubyte ebank = cx16.search_x16edit()
        if ebank == 255 {
            flash("X16 Edit not present in ROM")
            return
        }
        if xarena.high_bank >= xarena.max_bank {
            ; arena has consumed every usable bank - nothing left to hand the editor
            ; (also avoids high_bank+1 wrapping to 0 when high_bank == 255)
            flash("No free RAM banks for editor")
            return
        }
        xfiles.get_name(file_cursor, namebuf)
        cd_to_entry(file_cursor)
        ubyte firstbank = xarena.high_bank + 1
        sys.enable_caseswitch()                 ; X16Edit charset workaround
        ubyte oldrom = cx16.getrombank()
        cx16.rombank(ebank)
        cx16.x16edit_loadfile_options(
            firstbank, xarena.max_bank, namebuf,    ; last bank = this machine's real top bank
            mkword(%00000011, strings.length(namebuf)),   ; opts: auto-indent + word-wrap
            mkword(80, 4),                                 ; wrap col 80, tab stop 4
            mkword((shared.CLR_BG << 4) | shared.CLR_FG, diskio.drivenumber),   ; normal: white on dark-gray (app theme), drive
            mkword(shared.HILITE, shared.HILITE))                        ; header / status: light-blue bar (app accent)
        cx16.rombank(oldrom)
        sys.disable_caseswitch()
        ; X16 Edit's Ctrl-E ("change font") OVERWRITES the charset glyphs in VRAM and can leave the
        ; machine in ISO mode - and restores neither on exit. Two independent breakages:
        ;   1) ISO mode = KERNAL flag $0372 bit $40. With it set, CHROUT reads bytes as ISO/ASCII, so
        ;      file names (raw ASCII) render fine but XFMGR's PETSCII UI + box chrome garble.
        ;   2) The PETSCII font copy in VRAM is clobbered by Ctrl-E's glyph upload.
        ; txt.lowercase() is only CHROUT($0e): it just toggles the KERNAL's selected mode and no-ops when
        ; that mode is unchanged, so it never re-copies the ROM glyphs and can't repair (2). Only
        ; screen_set_charset(n,0) FORCE-reloads the ROM font into VRAM (0 ptr = built-in). Recover fully:
        ; reinit the 80x30 layer, reload charset 3 (PETSCII upper/lower = XFMGR's RUNNING display font,
        ; the one txt.lowercase() selects at startup - NOT saved_charset, which is the pre-launch charset
        ; kept only for final exit), then clear the ISO flag, then restore theme colors. Reloading the
        ; wrong charset (e.g. 2/upper-graphics) renders letters but garbles the box chrome, whose codes
        ; are laid out for charset 3. Caller's dirty_full repaints over it.
        cx16.set_screen_mode(SCREEN_MODE)               ; reinit 80x30 layer + charset tile base
        cx16.screen_set_charset(3, 0)                   ; FORCE-reload PETSCII upper/lower ROM font to VRAM
        %asm {{
            lda  $0372
            and  #$bf                       ; clear bit $40 -> leave ISO mode, back to PETSCII CHROUT
            sta  $0372
        }}
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        diskio.chdir(pathbuf)                   ; X16Edit can change dir; restore ours
    }

    sub play_zsm() {
        ; P on a .zsm: play it through the zsmkit engine (bank 6). Modal - ticks once per frame
        ; until the song ends (non-looping) or the user quits. The whole song must be RESIDENT, so
        ; we BORROW banks above the arena (exactly as op_edit lends banks to X16 Edit); the modal
        ; loop means the arena can't grow meanwhile, and the borrowed banks are simply abandoned
        ; after. The caller (the P handler) has already loaded namebuf and chdir'd into the file's dir.
        if not zsm_ok {
            flash("zsm engine not loaded (zsmkit.bin)")
            return
        }
        if xarena.high_bank >= xarena.max_bank {        ; also stops high_bank+1 wrapping to 0
            flash("no free RAM banks for song")
            return
        }
        ubyte song_bank = xarena.high_bank + 1
        ; blocks are 254 bytes; a bank holds 8192 -> /32 (+1) is a safe overestimate of banks used.
        ; MANDATORY: KERNAL LOAD wraps banks blindly and bank 64 aliases bank 0 on a 512 KB machine,
        ; so refuse a song that would run past the top usable bank.
        uword banks_needed = xfiles.get_blocks(file_cursor) / 32 + 1
        uword free_banks   = xarena.max_bank - song_bank + 1
        if banks_needed > free_banks {
            flash("song too big for free RAM banks")
            return
        }
        cx16.push_rambank(song_bank)
        bool loaded = diskio.load_raw(namebuf, $a000) != 0      ; whole file; KERNAL wraps banks up
        cx16.pop_rambank()
        if not loaded {
            flash("song load failed")
            return
        }
        zsm_init_engine(ZSM_LOWRAM)             ; EVERY play - X16 Edit clobbers golden RAM $0400
        zsm_setbank(0, song_bank)
        zsm_setmem(0, $a000)
        box_open()
        box_compose_name("Playing ", namebuf, " - SPACE pause  Q stop")
        box_left(CMDROW1, cm_dst)
        zsm_play(0)
        bool playing = true
        repeat {
            sys.waitvsync()
            zsm_tick(0)                         ; 60 Hz; zsmkit rescales non-60 Hz songs itself
            ubyte k = cbm.GETIN2()
            if k >= $c1 and k <= $da
                k -= $80                        ; fold shifted letters, like cmd_key()
            if k == 'q' or k == 27 or k == 3
                break                           ; Q / ESC / STOP
            if k == ' ' {
                if playing
                    zsm_stop(0)
                else
                    zsm_play(0)
                playing = not playing
            }
            if playing {
                bool st
                st, void, void = zsm_getstate(0)
                if not st
                    break                       ; non-looping song reached its end
            }
        }
        zsm_stop(0)
        zsm_close(0)                            ; silence YM/PSG/PCM; borrowed song banks abandoned
        box_close()
    }

    sub op_play_wav() {
        ; P on a .wav: stream it via the xmusic overlay (bank 7). The overlay does all the work in
        ; its own bank; main just frames a status line and shows any error. The caller (P handler)
        ; has loaded namebuf and chdir'd into the file's dir, so play_wav's f_open resolves there.
        if not music_ok {
            flash("wav player not loaded (xmusic.ovl)")
            return
        }
        box_open()
        box_compose_name("Playing ", namebuf, " - SPACE pause  Q stop")
        box_left(CMDROW1, cm_dst)
        ubyte rc = play_wav(&namebuf)
        box_close()
        if rc == 2
            flash("unsupported wav (need PCM 8/16-bit)")
        else if rc == 1
            flash("can't open file")
    }

    sub op_setup() {
        ; Alt-F10: open the standalone color-theme setup. It is a separate PRG, so launching it
        ; QUITS XFMGR - all logged folders and tags are lost. On save it relaunches XFMGR, which
        ; re-reads and applies the chosen theme. ENTER = go, ESC = cancel (no No option).
        if confirm_enter("Setup? loses logged dirs + tags") {
            setup_exit = true
        }
    }

    ; ---- startup overlay verification ----
    ; Names in load order; bit N of ovl_missing corresponds to OVL_NAMES[N].
    str[7] OVL_NAMES = ["tview.ovl", "xsyntax.ovl", "miscutil.ovl", "uiutil.ovl",
                        "ximgview.ovl", "zsmkit.bin", "xmusic.ovl"]
    ubyte ovl_missing                   ; bit set = that overlay failed to load

    sub check_overlays() {
        ; A missing overlay used to fail SILENTLY - the feature just went dead, and the first
        ; visible sign was usually a mangled bottom menu rather than anything naming a file. That
        ; is a miserable thing to debug (it cost us a session when the install moved to a folder
        ; the launcher didn't name), so say plainly which files are missing and where we looked.
        ;
        ; We report ONLY the loadlib results already in hand. We deliberately do NOT f_open the
        ; files to double-check them: a read-channel open on an ABSENT file is exactly what
        ; corrupts the following UI draw (the same trap that forced cfg_read onto load_raw), so a
        ; "verify everything exists" probe would risk causing the very corruption it reports on.
        if ovl_missing == 0
            return
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        txt.clear_screen()
        txt.print("\n xfmgr2 - startup problem\n\n")
        txt.print(" not found in ")
        txt.print(themes.path_to(""))            ; the install folder, empty filename = folder itself
        txt.print("\n\n")
        ubyte i
        for i in 0 to len(OVL_NAMES) - 1 {
            if (ovl_missing & (1 << i)) != 0 {   ; parens: '&' binds TIGHTER than '==' in prog8
                txt.print("   ")
                txt.print(OVL_NAMES[i])
                txt.nl()
            }
        }
        txt.print("\n that folder is read from the /xt launcher\n")
        txt.print(" in the drive root. either re-run\n")
        txt.print(" install.prg, or point /xt at the folder\n")
        txt.print(" that actually holds these files.\n")
        txt.print("\n press a key to continue anyway.\n")
        repeat {
            if cbm.GETIN2() != 0
                break
        }
    }

    sub op_help() {
        ; F1: show the help text (xfmgr.hlp, shipped alongside the .prg) in the text viewer.
        ; Mirrors the V text path, but by ABSOLUTE path: the help file lives with the .prg and
        ; overlays, wherever those were installed (themes.path_to). The old version chdir'd to a
        ; hard-coded /xfmgr and never changed back, leaving the cwd somewhere the caller didn't
        ; expect. Restores the theme color the viewer left blue; caller sets dirty_full - the
        ; viewer took the whole screen.
        if not viewer_ok {
            flash("viewer overlay missing")
            return
        }
        void strings.copy(themes.path_to("xfmgr.hlp"), namebuf)
        void view_file(&namebuf, 255, 0, 0, 0, 0, 0)   ; single file; returns on Q/ESC (255 = no Find
                                                       ; history, 0 blocks = size unknown -> no "n%")
        txt.color2(shared.CLR_FG, shared.CLR_BG)    ; viewer left the color blue; restore app theme
    }

    sub op_execute() {
        ; Alt-X: run the selected program. The X16 can't return to XFMGR afterwards
        ; (loading the program overwrites us), so we confirm, then quit to BASIC with a
        ; LOAD + RUN queued in the keyboard buffer. The main loop sees run_exit and breaks.
        if xfiles.ft_count == 0
            return
        xfiles.get_name(file_cursor, namebuf)
        box_compose_name("Run ", namebuf, "? exits XFMGR")
        if confirm_enter(cm_dst) {                  ; ENTER = run, ESC = cancel (no No option)
            xtree.build_path(xfiles.row_dir(file_cursor), pathbuf)   ; the program's OWN directory
            run_exit = true
        }
    }

    sub op_tag_branch() {
        ; Alt-T: tag every logged file in this folder and everything below it, without first
        ; entering the Branch view to do it. Borrows the shared file index for the gather and
        ; hands it straight back - tags live in the file RECORDS, so they outlive the index that
        ; set them. Honours the FileSpec, which is the point: "F *.prg" then Alt-T tags every
        ; program in the branch.
        xfiles.collect_root = cur_dir
        xfiles.collect_all()
        uword touched = xfiles.ft_count
        xfiles.tag_all()
        void rebuild_view()                 ; put the pane's own listing back
        clamp_file_cursor()
        void strings.copy("Tagged ", cm_dst)
        box_append_uw(touched)
        void strings.append(cm_dst, " file(s) in this branch")
        toast(cm_dst)
        dirty_full = true
    }

    sub op_untag_disk() {
        ; Alt-U: clear every tag on the disk. After a Showall session the tags are scattered over
        ; directories you are no longer looking at, and Ctrl-U only reaches the current listing -
        ; so without this, starting clean means hunting them down. See xfiles.untag_disk for why
        ; it deliberately does NOT go through the index.
        uword cleared = xfiles.untag_disk()
        void rebuild_view()
        clamp_file_cursor()
        void strings.copy("Untagged ", cm_dst)
        box_append_uw(cleared)
        void strings.append(cm_dst, " file(s) disk-wide")
        toast(cm_dst)
        dirty_full = true
    }

    sub op_jump_dir() {
        ; Alt-J: type a path and go there, logging every level on the way down. This is XTree's
        ; Treespec. On a card with a deep layout it beats walking the tree, and it is the only way
        ; to reach a folder that exists on disk but has never been logged - Showall and Branch can
        ; only ever show you LOGGED directories, so this is how you widen what they can see.
        ;
        ; Leaves any scoped view first: this moves the tree cursor, which is a two-pane result.
        if xfiles.file_scope != xfiles.SCOPE_DIR
            leave_scope()
        if not input_line("Go to dir:", inputbuf, 79, "godir", true, false)
            return
        if inputbuf[0] == 0
            return
        ; Normalise exactly like a copy destination: absolute wins, otherwise it hangs off the
        ; drive root, and either way it ends in '/' so it matches build_path's format.
        if inputbuf[0] == '/' {
            void strings.copy(inputbuf, pathbuf)
        } else {
            void strings.copy(xtree.base_path, pathbuf)
            ensure_slash(pathbuf)
            void strings.append(pathbuf, inputbuf)
        }
        ensure_slash(pathbuf)
        if not dir_exists(pathbuf) {
            flash("no such folder")
            return
        }
        ; open_NEW_path, not open_path: the folder may have been made outside XFMGR (or by a copy)
        ; since its parent was logged, and a plain descent cannot see those - see xscan.
        ubyte node = xscan.open_new_path(pathbuf)
        if node == xtree.NONE {
            flash("could not log that path")
            return
        }
        void xscan.scan_dir(node)               ; log its files, so the pane has something to show
        xtree.rebuild_visible()
        set_tree_cursor_to(node)
        select_dir(node)
        focus = FOCUS_TREE
        dirty_full = true
    }

    sub op_release() {
        ; Alt-R (file pane): un-log the current folder to free the memory it holds. Clears
        ; its scanned state, drops its logged subfolders + file records, and collapses it
        ; back to the "(Enter to log)" state; a later Enter re-scans it fresh. The banked
        ; bytes are reclaimed on the next full reset (the arena is append-only, see xarena),
        ; so this releases the folder LOGICALLY. Nothing to release if it was never logged.
        ;
        ; Alt-R is not focus-guarded, so it can fire from inside a scoped view. Leave the scope
        ; first: unlog drops this folder's subfolders and file records, and a scoped index holds
        ; far pointers INTO those records - keeping it would leave rows aimed at released storage.
        if xfiles.file_scope != xfiles.SCOPE_DIR
            leave_scope()
        if xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0 {
            flash("folder not logged")
            return
        }
        xtree.unlog(cur_dir)
        set_tree_cursor_to(cur_dir)             ; visible rows shrank; re-anchor the cursor
        select_dir(cur_dir)                     ; file pane -> empty / (Enter to log)
        focus = FOCUS_TREE                      ; released folder is empty; land back in the tree
    }

    sub chain_run(str name) {
        ; Launch another program after we quit. The X16 keyboard buffer is only 10 bytes
        ; (verified), far too small for  LOAD"longname" + RUN  (~20 bytes), so we use the
        ; "dynamic keyboard": PRINT the LOAD line on screen, move the cursor back UP onto
        ; it, then feed only CR + RUN through the buffer. BASIC's editor re-reads the LOAD
        ; line straight off the screen. This mirrors AUTOBOOT.BASL's COMP_TO_BASLOAD.
        txt.chrout($93)                     ; clear screen, cursor home (row 0)
        txt.nl()                            ; row 1  (BASIC's "READY." overwrites this)
        ;txt.print("running ")
        ;txt.print(name)
        ;txt.print("...")
        ;txt.nl()                            ; row 2
        txt.print("load")                   ; row 2:  LOAD"name"
        txt.chrout($22)
        txt.print(name)
        txt.chrout($22)
        txt.chrout($91)                     ; cursor UP -> row 1
        txt.chrout($91)                     ; cursor UP -> row 0
        cx16.kbdbuf_clear()
        cx16.kbdbuf_put($0d)                ; CR: submit the on-screen LOAD line
        cx16.kbdbuf_put('r')
        cx16.kbdbuf_put('u')
        cx16.kbdbuf_put('n')
        cx16.kbdbuf_put($0d)                ; RUN + CR
    }

    ; ---------- shared input history (picker UI; the ring + its ops live in the miscutil
    ;            overlay, bank 3 - see the hist_* extsubs) ----------

    const ubyte HIST_PX0 = 12                   ; Recent-popup box left/right columns
    const ubyte HIST_PX1 = 67

    sub hist_draw_row(ubyte srow, uword textptr, bool selected) {
        ; (re)draw a single history row: clear it, print the entry, highlight if selected.
        ; Matches how draw_box's box_row + the list loop paint a base row, so an
        ; unselected redraw is pixel-identical to the original (resets any bar color).
        txt.color(shared.CLR_FG)
        blank_span(HIST_PX0+1, HIST_PX1-1, srow)
        txt.plot(HIST_PX0+2, srow)
        print_trunc(textptr, HIST_PX1-HIST_PX0-3)
        if selected
            hilite_row(HIST_PX0+1, HIST_PX1-1, srow, shared.HILITE)
    }

    sub hist_popup(uword destptr, ubyte maxlen) -> ubyte {
        ; modal picker of recent entries, shell-style: the NEWEST entry (slot 0) sits at
        ; the BOTTOM of the list, right above the prompt, and is selected by default;
        ; Up walks back into older entries. `sel` is a slot index (0 = newest). On Enter,
        ; copy the choice into destptr (capped at maxlen) and return its length; on Esc
        ; return 255 (no change). Only reached when hist_count != 0.
        ubyte sel = 0
        ubyte c
        ; geometry is fixed while the popup is open (hist_count can't change): a blank
        ; spacer line sits under the header at boxtop+1, the list fills boxtop+2.., and the
        ; bottom border anchors at row 26. srow for a slot = boxtop+rows+1-slot.
        ubyte rows = hist_count
        ubyte boxtop = 24 - rows
        ; --- draw the chrome + full list ONCE; the key loop below only repaints the two
        ;     rows that change on Up/Down instead of redrawing the whole list ---
        if ui_ok {
            ui_draw_box(HIST_PX0, boxtop, HIST_PX1, boxtop+rows+2)
            ui_box_header(HIST_PX0, HIST_PX1, boxtop, " Recent ")
        }
        ; key hints in a centered footer on the bottom border, as ONE embedded-color
        ; string (\x9e=accent, \x05=fg; ←┘=ENTER glyph). Visible length = 23.
        txt.plot(HIST_PX0 + 1 + (HIST_PX1 - HIST_PX0 - 1 - 23) / 2, boxtop+rows+2)
        txt.print(petscii:"\x9e ←┘\x05 Select  \x9eESC\x05 Cancel ")
        ubyte p
        for p in 0 to rows-1 {
            ubyte slot = rows - 1 - p        ; oldest at top, newest at the bottom
            hist_get(slot, &hist_line)       ; pull the entry out of the overlay ring
            hist_draw_row(boxtop+2+p, &hist_line, slot == sel)
        }
        repeat {
            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3 -> return 255          ; ESC / STOP: cancel
                13 -> {                      ; Enter: take the selected entry
                    hist_get(sel, &hist_line)
                    ubyte j = 0
                    repeat {
                        c = hist_line[j]
                        if c == 0 or j >= maxlen
                            break
                        @(destptr + j) = c
                        j++
                    }
                    @(destptr + j) = 0
                    return j
                }
                145 -> {                     ; up -> older entry (higher slot)
                    if sel + 1 < rows {
                        hist_get(sel, &hist_line)
                        hist_draw_row(boxtop+rows+1-sel, &hist_line, false)
                        sel++
                        hist_get(sel, &hist_line)
                        hist_draw_row(boxtop+rows+1-sel, &hist_line, true)
                    }
                }
                17 -> {                      ; down -> newer entry (lower slot)
                    if sel != 0 {
                        hist_get(sel, &hist_line)
                        hist_draw_row(boxtop+rows+1-sel, &hist_line, false)
                        sel--
                        hist_get(sel, &hist_line)
                        hist_draw_row(boxtop+rows+1-sel, &hist_line, true)
                    }
                }
            }
        }
    }

    ; per-prompt history persistence (/xfmgr/hist/<category>.his in the install folder) now lives in the
    ; miscutil overlay (hist_load / hist_save extsubs); str_copy_cap stays here (still used by the
    ; F2 dir-pick and ShowAll).
    sub str_copy_cap(uword src, uword dst, ubyte cap) {
        ; copy a NUL-terminated string src -> dst, never writing more than `cap` chars
        ubyte j = 0
        ubyte ch
        repeat {
            ch = @(src + j)
            if ch == 0 or j >= cap
                break
            @(dst + j) = ch
            j++
        }
        @(dst + j) = 0
    }

    ; ---------- bottom-line prompts ----------

    ; The dialog DRAWING/interaction lives in the uiutil overlay (bank 4); these thin wrappers
    ; open the bottom box (frame plumbing stays in main), JSRFAR in to draw + wait/interact, then
    ; close. If the overlay isn't loaded they degrade to a safe default rather than crashing.
    sub flash(str m) {
        box_open()
        if ui_ok
            ui_flash(m)
        box_close()
    }

    ; Hold a message for `jiffies` (1/60s each) OR until a key is pressed, whichever comes first.
    ; uiutil has its own copy of this for the toasts it owns - a few dozen bytes duplicated is
    ; cheaper than adding a jmptable entry and a cross-bank call just to share it.
    ;
    ; The buffer is DRAINED first: these boxes go up immediately after the command key that
    ; caused them, so a still-queued keypress would blink the message away before it can be read.
    sub wait_or_key(uword jiffies) {
        while cbm.GETIN2() != 0 {
            ; drain typeahead left over from the command that triggered this message
        }
        uword n = 0
        while n < jiffies {
            sys.waitvsync()                 ; one jiffy, same tick sys.wait() counts
            if cbm.GETIN2() != 0
                return
            n++
        }
    }

    sub toast(str m) {
        ; brief self-dismissing status (~1.5 s), or any key to dismiss it sooner.
        box_open()
        if ui_ok
            ui_toast(m)
        box_close()
    }

    ; ---- unified bottom dialog box: white bg, black text, hotkeys in light blue (same look as
    ;      ask_overwrite). A full-width 4-line white box spanning DIVBOT..SCR_BOT (rows 26..29),
    ;      every column 0..79 - it covers the side borders too. Prompts/banners write their text on
    ;      the two middle rows (CMDROW1/2); DIVBOT/SCR_BOT are the box's own blank top/bottom margin.
    ;      box_close's draw_frame restores every border cell the box erased.
    sub box_open() {
        ubyte r
        for r in DIVBOT to SCR_BOT {         ; 4 lines; outer stays local, inner leaf loop uses g_ndx
            for g_ndx in 0 to 79 {           ; full width, side borders included
                txt.setchr(g_ndx, r, sc:' ')
                txt.setclr(g_ndx, r, shared.CLR_BOTTOM_PROMPT_BG)
            }
        }
        txt.color(shared.CLR_FG)
    }

    sub box_close() {
        ; the box erased the four bottom rows edge-to-edge (borders included); draw_frame restores
        ; every border cell. Callers repaint the command menu over CMDROW1/2 via dirty_cmd.
        draw_frame()
    }

    sub box_left(ubyte row, str s) {
        ; print s left-aligned at BANNER_LEFT on row, then force that row black-on-white.
        ; the house style for every bottom-banner line (see BANNER_LEFT). Full width (0..79).
        txt.plot(BANNER_LEFT, row)
        txt.print(s)
        hilite_row(0, 79, row, shared.CLR_BOTTOM_PROMPT_BG)
    }

    sub box_compose_name(str prefix, str name, str suffix) {
        ; cm_dst = prefix + name(capped) + suffix, for a centered prompt/msg with a filename
        void strings.copy(prefix, cm_dst)
        ubyte cl = lsb(strings.length(cm_dst))
        ubyte fi = 0
        while name[fi] != 0 and cl < 58 {
            cm_dst[cl] = name[fi]
            cl++
            fi++
        }
        cm_dst[cl] = 0
        void strings.append(cm_dst, suffix)
    }

    sub box_append_uw(uword v) {
        ; append decimal v to cm_dst (for composing "<n> ..." lines)
        ubyte[6] tmp
        ubyte nd = 0
        if v == 0 {
            tmp[0] = '0'
            nd = 1
        } else {
            while v != 0 {
                tmp[nd] = '0' + lsb(v % 10)
                nd++
                v /= 10
            }
        }
        ubyte l = lsb(strings.length(cm_dst))
        while nd != 0 {
            nd--
            cm_dst[l] = tmp[nd]
            l++
        }
        cm_dst[l] = 0
    }

    sub box_append_long(long v) {
        ; append decimal v to cm_dst. Only the blocks total needs this - a whole-disk scope runs
        ; past what box_append_uw can say, and a wrapped total looks like a plausible number.
        ; Uses conv.str_l (BCD) rather than box_append_uw's digit loop: a 32-bit / and % drag in
        ; prog8's general long-divide and cost ~790 B, which this build does not have.
        void strings.append(cm_dst, conv.str_l(v))
    }

    sub box_progress(uword cur, uword total) {
        ; live "(n of N)" counter on CMDROW2 during a copy/move batch. cur only grows and total is
        ; fixed, so the line only lengthens - no stale trailing digits to clear.
        void strings.copy("(", cm_dst)
        box_append_uw(cur)
        void strings.append(cm_dst, " of ")
        box_append_uw(total)
        void strings.append(cm_dst, ")")
        box_left(CMDROW2, cm_dst)
    }

    ; ---- thin wrappers over the uiutil overlay dialogs (bank 4) ----
    ; Each opens the bottom box (frame plumbing stays here), JSRFARs into uiutil to draw +
    ; interact, then closes. box_compose_name / box_append_uw stay in main (callers build the
    ; question in cm_dst before calling ask_yn). If the overlay is missing, degrade to a safe
    ; default rather than JSRFAR into an unloaded bank.

    sub ask_yn(str question, bool default_yes) -> bool {
        box_open()
        ubyte r = default_yes as ubyte
        if ui_ok
            r = ui_ask_yn(question, default_yes as ubyte)
        box_close()
        return r != 0
    }

    sub ask_confirm_each(uword n) -> ubyte {
        ; 1 = confirm each, 0 = delete all (no per-file), 255 = cancel
        box_open()
        ubyte r = 255
        if ui_ok
            r = ui_ask_confirm_each(n)
        box_close()
        return r
    }

    sub ask_delete_this(str name) -> ubyte {
        ; 1 = delete this, 0 = skip, 2 = delete this + all remaining, 255 = cancel rest.
        ; NO box_close - like ask_overwrite, the delete-tagged loop keeps the box open across
        ; files (draw_files repaints only the pane, rows 4..25); the final banner_delete restores
        ; the frame. Closing per file redrew the frame on rows 26/29 while 27/28 kept the reverse
        ; prompt, so those two border rows flickered back to box chars between prompts.
        box_open()
        if ui_ok
            return ui_ask_delete_this(name)
        return 255
    }

    sub banner_copymove(bool is_move, uword done, uword failed, uword skipped) {
        box_open()
        if ui_ok
            ui_banner_copymove(is_move as ubyte, done, failed, skipped)
        box_close()
    }

    sub banner_delete(uword done) {
        box_open()
        if ui_ok
            ui_banner_delete(done)
        box_close()
    }

    sub copy_diag() {
        ; "Nothing copied - <cause>" box; cause comes from cm_fail / cm_wstat.
        box_open()
        if ui_ok
            ui_copy_diag(cm_fail, cm_wstat)
        box_close()
    }

    sub edit_render(uword destptr, ubyte n, ubyte curpos, ubyte fieldcol) {
        ; repaint the editable field (fieldcol..78) black-on-white with a light-blue block
        ; cursor. The whole field is cleared and reprinted each keystroke, so inserts /
        ; deletes never leave stale characters behind.
        for g_ndx in fieldcol to 78 {
            txt.setchr(g_ndx, MSGROW, sc:' ')
            txt.setclr(g_ndx, MSGROW, shared.CLR_BOTTOM_PROMPT_BG)
        }
        txt.plot(fieldcol, MSGROW)
        ubyte width = 79 - fieldcol           ; cells available fieldcol..78
        ubyte shown = n
        if shown > width
            shown = width                     ; clamp so we never write past col 78
        if shown != 0
            for g_ndx in 0 to shown-1
                txt.chrout(@(destptr + g_ndx))
        hilite_row(fieldcol, 78, MSGROW, shared.CLR_BOTTOM_PROMPT_BG)   ; force the field black-on-white
        ubyte cc = fieldcol + curpos
        if cc > 78
            cc = 78
        txt.setclr(cc, MSGROW, shared.HILITE)       ; light-blue block cursor (visible on white)
    }

    sub pick_find(ubyte idx) -> ubyte {
        ; index of idx within the current visible tree (0 if not found)
        if xtree.vis_count != 0
            for g_ndx in 0 to xtree.vis_count-1
                if xtree.vis_idx[g_ndx] == idx
                    return g_ndx
        return 0
    }

    const ubyte PICK_X0 = 12                        ; Pick-a-directory box rectangle
    const ubyte PICK_X1 = 67
    const ubyte PICK_Y0 = 3
    const ubyte PICK_Y1 = 27
    const ubyte PICK_VIS = PICK_Y1 - PICK_Y0 - 2    ; visible list rows (row Y0+1 is a spacer)

    sub pick_draw_row(ubyte row, ubyte cur, ubyte top) {
        ; draw one visible list row (0..PICK_VIS-1): the SAME tree connectors + markers + name the
        ; main dir pane draws (build_tree_line), plus a selection bar if it is the cursor entry.
        ; Same draw path as the full repaint, so a non-cursor redraw exactly restores the base row
        ; (blank_span resets any bar color).
        ubyte srow = PICK_Y0 + 2 + row
        txt.color(shared.CLR_FG)
        blank_span(PICK_X0+1, PICK_X1-1, srow)
        ubyte i = top + row
        if i < xtree.vis_count {
            ubyte idx = xtree.vis_idx[i]
            txt.plot(PICK_X0+2, srow)
            build_tree_line(idx)                ; connectors (│ ├ └ ─) + expand marker + name
            txt.print(treeline)
            if i == cur
                hilite_row(PICK_X0+1, PICK_X1-1, srow, shared.HILITE)
        }
    }

    sub pick_draw_all(ubyte cur, ubyte top) {
        ; repaint the whole visible list (used on first draw, scroll, and expand/collapse)
        ubyte row
        for row in 0 to PICK_VIS-1
            pick_draw_row(row, cur, top)
    }

    sub pick_dir() -> ubyte {
        ; modal directory picker over the logged tree. Up/Down move, Right expands (and
        ; logs on demand), Left collapses, Enter selects the highlighted dir, Esc cancels.
        ; Returns the selected node index, or xtree.NONE if cancelled.
        ubyte cur = 0
        ubyte top = 0
        ubyte oldcur = 0
        ubyte idx
        ; draw the box chrome ONCE (outside the loop, so it never flickers on scroll): an
        ; empty-title box, a white header bar, a blank spacer line under it, then a centered
        ; hotkey footer on the bottom border with the keys picked out in the accent color.
        const ubyte BIW = PICK_X1 - PICK_X0 - 1         ; box interior width
        if ui_ok {
            ui_draw_box(PICK_X0, PICK_Y0, PICK_X1, PICK_Y1)
            ui_box_header(PICK_X0, PICK_X1, PICK_Y0, " Pick a dir ")
        }
        ; footer (42 visible chars) as ONE embedded-color string instead of 8 color + 8
        ; print calls. In-string PETSCII codes: \x9e = shared.CLR_ACCENT (yellow), \x05 = shared.CLR_FG
        ; (white); ←┘ is the ENTER glyph. Ends white so the list rows below inherit shared.CLR_FG.
        txt.plot(PICK_X0 + 1 + (BIW - 42) / 2, PICK_Y1)
        txt.print(petscii:"\x9e +\x05Expand \x9e-\x05Collapse  \x9e←┘\x05Select  \x9eEsc\x05 Cancel ")
        pick_draw_all(cur, top)                         ; initial full list
        repeat {
            g_key = wait_key()
            when g_key {
                27, 3 -> return xtree.NONE
                13 -> return xtree.vis_idx[cur]
                17 -> {                     ; down
                    if cur + 1 < xtree.vis_count {
                        oldcur = cur
                        cur++
                        if cur >= top + PICK_VIS {
                            top++
                            pick_draw_all(cur, top)             ; scrolled: repaint all
                        } else {
                            pick_draw_row(oldcur - top, cur, top)   ; else just the 2 rows
                            pick_draw_row(cur - top, cur, top)      ; that change
                        }
                    }
                }
                145 -> {                    ; up
                    if cur != 0 {
                        oldcur = cur
                        cur--
                        if cur < top {
                            top = cur
                            pick_draw_all(cur, top)             ; scrolled: repaint all
                        } else {
                            pick_draw_row(oldcur - top, cur, top)
                            pick_draw_row(cur - top, cur, top)
                        }
                    }
                }
                2 -> {                      ; PgDn: jump down one page (like the main dir pane)
                    if xtree.vis_count != 0 {
                        ubyte last = xtree.vis_count - 1
                        if cur != last {
                            if last - cur > PICK_VIS
                                cur += PICK_VIS
                            else
                                cur = last
                            if cur >= top + PICK_VIS
                                top = cur - PICK_VIS + 1
                            pick_draw_all(cur, top)
                        }
                    }
                }
                130 -> {                    ; PgUp: jump up one page
                    if cur != 0 {
                        if cur > PICK_VIS
                            cur -= PICK_VIS
                        else
                            cur = 0
                        if cur < top
                            top = cur
                        pick_draw_all(cur, top)
                    }
                }
                29, '+' -> {                ; right / '+': expand (log on demand)
                    idx = xtree.vis_idx[cur]
                    if xtree.d_flags[idx] & xtree.FL_SCANNED == 0
                        void xscan.scan_dir(idx)
                    if xtree.has_kids(idx) {
                        xtree.d_flags[idx] |= xtree.FL_EXPANDED
                        xtree.rebuild_visible()
                        cur = pick_find(idx)
                        if cur < top
                            top = cur
                        pick_draw_all(cur, top)                 ; structure changed: repaint all
                    }
                }
                157, '-' -> {               ; left / '-': collapse
                    idx = xtree.vis_idx[cur]
                    if xtree.is_expanded(idx) {
                        xtree.d_flags[idx] &= %11111110
                        xtree.rebuild_visible()
                        cur = pick_find(idx)
                        if cur < top
                            top = cur
                        pick_draw_all(cur, top)                 ; structure changed: repaint all
                    }
                }
            }
        }
    }

    sub hint_key(ubyte col, str keys, str label) -> ubyte {
        ; print `keys` (light blue) then `label` (black) at col on CMDROW2; return next col
        txt.plot(col, CMDROW2)
        txt.print(keys)
        txt.print(label)
        ubyte kl = lsb(strings.length(keys))
        ubyte ll = lsb(strings.length(label))
        if kl != 0
            for g_ndx in col to col + kl - 1
                txt.setclr(g_ndx, CMDROW2, shared.CLR_BOTTOM_PROMPT_KEY)
        if ll != 0
            for g_ndx in col + kl to col + kl + ll - 1
                txt.setclr(g_ndx, CMDROW2, shared.CLR_BOTTOM_PROMPT_BG)
        return col + kl + ll
    }

    sub prompt_hint(bool usehist, bool dirpick) {
        ; key help on row 2 under a text prompt: black text with the hotkeys in light blue.
        ; RIGHT-justified to end at col 78, matching the bracketed dialogs' row-2 choices.
        ; measure the total run width first (keys + labels of each shown segment), then start
        ; at 79 - width so the last char lands on col 78.
        ubyte w = 2 + 5 + 3 + 7                  ; "←┘"+" OK  "  and  "ESC"+" Cancel" (always shown)
        if usehist
            w += 1 + 10                          ; "↑" + " History  "
        if dirpick
            w += 2 + 11                          ; "F2" + " Dir tree  "
        ubyte col = 79 - w
        if usehist
            col = hint_key(col, petscii:"↑", " History  ")
        if dirpick
            col = hint_key(col, "F2", " Dir tree  ")
        col = hint_key(col, petscii:"←┘", " OK  ")
        col = hint_key(col, "ESC", " Cancel")
    }

    sub input_frame(str prompt, bool usehist, bool dirpick) {
        ; white 2-row box (CMDROW1/2) with the prompt label (black) on row 1 and key hints on row 2
        box_open()
        txt.plot(BANNER_LEFT, MSGROW)
        txt.print(prompt)
        hilite_row(0, 79, MSGROW, shared.CLR_BOTTOM_PROMPT_BG)     ; full width (0..79)
        prompt_hint(usehist, dirpick)
        draw_caps_hint()                        ; software-caps (CAPS) indicator, if upper_mode is on
    }

    sub draw_caps_hint() {
        ; Software Caps Lock indicator on the LEFT of the prompt's row 2. The key hints are RIGHT-
        ; justified (prompt_hint), so the two never collide. Light-blue "CAPS" when on, else blanked.
        txt.plot(BANNER_LEFT, CMDROW2)
        ubyte c = shared.CLR_BOTTOM_PROMPT_BG
        if upper_mode {
            txt.print("CAPS")
            c = shared.CLR_BOTTOM_PROMPT_KEY
        } else {
            txt.print("    ")
        }
        for g_ndx in BANNER_LEFT to BANNER_LEFT + 3
            txt.setclr(g_ndx, CMDROW2, c)
    }

    sub input_key() -> ubyte {
        ; wait_key for the line editor, but it also watches the Caps Lock KEY. XFMGR keeps the KERNAL
        ; Caps toggle OFF (a real caps lock breaks the Alt/Ctrl command menus - see caps_off), so it
        ; can't be used to type capitals. Instead, pressing Caps Lock here clears the KERNAL bit again
        ; (guarded, via caps_clear) and flips the SOFTWARE upper_mode the char branch folds with. Flip
        ; EXACTLY once per press: a successful clear makes the next modifier poll read 0, so no loop.
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
            ubyte hold = cx16.kbdbuf_get_modifiers()
            if (hold & MOD_CAPS) != 0 and caps_clear(hold) {
                upper_mode = not upper_mode
                draw_caps_hint()
            }
        }
    }

    sub input_line(str prompt, str dest, ubyte maxlen, str histname, bool dirpick, bool allow_empty) -> bool {
        ; a small line editor: Left/Right move, Home jumps to start, Backspace deletes
        ; the char to the left, printable keys insert at the cursor, Up recalls history,
        ; F2 (when dirpick) picks a directory from the tree, Enter accepts, Esc cancels.
        ; `histname` selects the history category file. `allow_empty` makes a blank ENTER accept
        ; (return true with an empty dest) instead of behaving like Cancel - the caller then supplies
        ; its own default (e.g. filespec's "*"). ESC always returns false.
        bool usehist = misc_ok and strings.length(histname) != 0    ; no overlay / empty histname -> no history UI
        ; MUST hoist progdir_cd() into a local before any hist_* call. Those take their args in
        ; cx16.r0/r1, and prog8 stores the FIRST arg into r0 and only THEN evaluates the second -
        ; so calling progdir_cd() inline there destroys the category pointer already sitting in r0
        ; (it uses strings.copy/length, which clobber r0-r3). The compiler does NOT warn about this.
        ; The symptom was perfect: mkdir("hist") is a literal so the folder appeared, but the
        ; filename was built from garbage and nothing was ever written. progpath is stable until
        ; the next path_to/progdir_cd call, so holding the pointer across the call is safe.
        uword histdir = themes.progdir_cd()
        if usehist
            hist_count = hist_load(histname, histdir)      ; banked ring; cache the returned count
        input_frame(prompt, usehist, dirpick)
        ubyte fieldcol = BANNER_LEFT + 1 + lsb(strings.length(prompt))     ; one space after the prompt label
        ubyte n = 0
        ubyte curpos = 0
        ubyte j
        dest[0] = 0
        edit_render(dest, n, curpos, fieldcol)
        repeat {
            g_key = input_key()
            when g_key {
                13 -> {                      ; Enter -> accept (non-empty, or empty when allow_empty)
                    ; software-caps captures capitals as their DISPLAY byte ($C1-$DA) so they show
                    ; uppercase while typing; fold them back to ASCII uppercase ($41-$5A) here so the
                    ; accepted / stored / history value is byte-identical to before caps existed.
                    if n != 0 {
                        for j in 0 to n-1
                            if dest[j] >= $c1 and dest[j] <= $da
                                dest[j] -= $80
                    }
                    dest[n] = 0
                    if n != 0 and usehist {
                        hist_count = hist_store(dest)
                        hist_save(histname, histdir)        ; histdir hoisted above - see the note there
                    }
                    box_close()
                    return n != 0 or allow_empty
                }
                27, 3 -> {                    ; ESC / STOP -> cancel
                    box_close()
                    return false
                }
                157 -> {                      ; left
                    if curpos != 0
                        curpos--
                }
                29 -> {                       ; right
                    if curpos < n
                        curpos++
                }
                19 -> curpos = 0              ; HOME
                20 -> {                       ; backspace: delete char left of cursor
                    if curpos != 0 {
                        j = curpos - 1
                        while j + 1 < n {
                            dest[j] = dest[j+1]
                            j++
                        }
                        n--
                        curpos--
                    }
                }
                145 -> {                      ; up-arrow -> recall from history
                    if usehist and hist_count != 0 {
                        ubyte r = hist_popup(dest, maxlen)
                        ; the picker drew over the panes; repaint, then re-show the prompt
                        full_redraw()
                        dirty_full = true
                        input_frame(prompt, usehist, dirpick)
                        if r != 255 {
                            n = r
                            curpos = n
                        }
                    }
                }
                137 -> {                      ; F2 -> pick a directory from the tree
                    if dirpick {
                        ubyte picked = pick_dir()
                        full_redraw()
                        dirty_full = true
                        input_frame(prompt, usehist, dirpick)
                        if picked != xtree.NONE {
                            xtree.build_path(picked, pathbuf)
                            str_copy_cap(pathbuf, dest, maxlen)
                            n = lsb(strings.length(dest))
                            curpos = n
                        }
                    }
                }
                else -> {
                    ; Insert a printable key at the cursor. Case (see input_key + the ENTER handler):
                    ; a letter is captured as its DISPLAY byte so the field shows the real case while
                    ; typing - unshifted = lowercase $41-$5A, SHIFT = capital $C1-$DA - and software-caps
                    ; (upper_mode) folds an unshifted letter UP to its capital. ENTER folds every
                    ; $C1-$DA back to ASCII uppercase $41-$5A, so nothing downstream (disk open, history)
                    ; ever sees the >127 byte that would garble a name.
                    if upper_mode and g_key >= $41 and g_key <= $5a
                        g_key += $80
                    if n < maxlen and ((g_key >= 32 and g_key < 127) or (g_key >= 193 and g_key <= 218)) {
                        j = n
                        while j > curpos {
                            dest[j] = dest[j-1]
                            j--
                        }
                        dest[curpos] = g_key
                        n++
                        curpos++
                    }
                }
            }
            edit_render(dest, n, curpos, fieldcol)
        }
    }

    sub hilite_row(ubyte x0, ubyte x1, ubyte row, ubyte color) {
        ; paint a full-width selection bar over an already-drawn row
        ; (the single-row case of hlprs.clr_section; kept inline as it's smaller in the
        ;  hot draw loops than a by-variable call into the shared 5-arg helper)
        for g_ndx in x0 to x1
            txt.setclr(g_ndx, row, color)
    }

    sub bar_fill(ubyte row) {
        ; full-width reverse status bar (cols 0..79), viewer-style. setchr/setclr (not chrout) so
        ; filling col 79 / the bottom row never triggers an auto-scroll. Matches tview.bar_fill.
        for g_ndx in 0 to 79 {
            txt.setchr(g_ndx, row, sc:' ')
            txt.setclr(g_ndx, row, (shared.BAR_BG << 4) | shared.BAR_FG)
        }
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    sub bar_key(str s) {
        ; a highlighted hotkey on the bar, accent color on blue (matches the main command menu's
        ; hotkey look), then revert to white-on-blue. Single-letter keys are printed letter-in-word:
        ; bar_key("U") then the rest of "Untag", so only the U is picked out - like "MENU:" below.
        txt.color2(shared.CLR_ACCENT, shared.BAR_BG)
        txt.print(s)
        txt.color2(shared.BAR_FG, shared.BAR_BG)
    }

    ; draw_box / box_row / box_shadow / box_header now live in the uiutil overlay (bank 4),
    ; called via ui_draw_box / ui_box_header. print_trunc stays here - it's on the hot draw path
    ; (draw_status / draw_file_row), so a per-cell JSRFAR would be far too slow.

    sub print_trunc(str s, ubyte maxlen) {
        ubyte i = 0
        while i < maxlen and s[i] != 0 {
            txt.chrout(s[i])
            i++
        }
    }

    sub sniff_kind(uword nameptr) -> ubyte {
        ; Classify a file by its MAGIC BYTES (raw content, so no filename-encoding ambiguity - the
        ; host-fs may return names as lowercase ASCII, which broke extension matching). One
        ; open/read(12)/close covers all four. The caller must have chdir'd into the file's dir.
        ;   0 = other   1 = BMX image   2 = ZSM music   3 = WAV audio
        ubyte[12] magic
        for g_ndx in 0 to 11
            magic[g_ndx] = 0
        if not diskio.f_open(nameptr)
            return 0
        ubyte got = lsb(diskio.f_read(&magic, 12))
        diskio.f_close()
        ; BMX: $42,$4D,$58 (= ascii "BMX", matching bmx.p8's FILEID)
        if got >= 3 and magic[0]==$42 and magic[1]==$4d and magic[2]==$58
            return 1
        ; ZSM: "zm" = $7a,$6d at offset 0 (matches tview's zsm_detect + Appendix G)
        if got >= 2 and magic[0]==$7a and magic[1]==$6d
            return 2
        ; WAV: "RIFF" at 0 + "WAVE" at 8
        if got >= 12 and magic[0]==$52 and magic[1]==$49 and magic[2]==$46 and magic[3]==$46
                     and magic[8]==$57 and magic[9]==$41 and magic[10]==$56 and magic[11]==$45
            return 3
        return 0
    }

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub cmd_key() -> ubyte {
        ; read a key for COMMAND dispatch, case-insensitively. Prog8 lowercase char
        ; literals ('q','d',...) are PETSCII $41..$5A, which is exactly what an
        ; UNSHIFTED letter key produces. A SHIFTED letter arrives as $C1..$DA, so we
        ; fold it down by $80 onto the same range. Non-letters pass through unchanged.
        ubyte k = wait_key()
        if k >= $c1 and k <= $da
            k -= $80
        return k
    }

    sub wait_command() -> ubyte {
        ; like cmd_key() but also switches the displayed menu to match a held modifier
        ; (CTRL / ALT) while idle, so the next keypress dispatches as that command.
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0 {
                if menu_mode == 1 {
                    ; CTRL menu: normalise CTRL+letter (control code $01..$1A, or shifted
                    ; $C1..$DA) onto the unshifted letter range $41..$5A
                    if k >= $c1 and k <= $da
                        k -= $80
                    else if k >= 1 and k <= 26
                        k += $40
                } else if menu_mode == 2 {
                    ; ALT menu: ALT is the Commodore key, so a letter arrives as a
                    ; graphics code ($A1..$BF). Map it back to the base letter; other
                    ; keys (e.g. F3 = 134) pass through unchanged for handle_alt.
                    if k >= 161 and k <= 191 {
                        ubyte t = alt_letter[k - 161]
                        if t != 0
                            k = t
                    }
                } else {
                    if k >= $c1 and k <= $da
                        k -= $80
                }
                return k
            }
            ; no key pending: switch the displayed menu to match the held modifier, so
            ; the next keypress is dispatched as a CTRL or ALT command (see main loop)
            ubyte hold = cx16.kbdbuf_get_modifiers()
            ubyte want = 0
            ; CTRL/ALT command menus work from BOTH panes: the DIR column now has ALT ops
            ; (Alt-Q quit-here, Alt-F3 relog, Alt-R release) and the CTRL tag/copy/move ops
            ; act on the highlighted dir's files - matching the "hold CTRL or ALT" hint.
            if (hold & MOD_CTRL) != 0
                want = 1
            else if (hold & MOD_ALT) != 0
                want = 2
            if want != menu_mode {
                menu_mode = want
                draw_commands()
            }
        }
    }

    ; ---------- about overlay ----------

    ; the About modal (draw_box + version text + banked-RAM line) now lives in the uiutil overlay
    ; (ui_show_about); show_about() below is just the thin wrapper.

    ; ---------- CTRL-V: sequential view of the tagged files ----------

    sub view_tagged() {
        ; XTree CTRL-V: view every TAGGED file in THIS directory in turn, starting at the first one.
        ; In the viewer, + steps to the next tagged file and - back to the previous (so does paging
        ; past EOF, forwards): setmode 1 makes view_file return 1 = next, 2 = previous, 0 = quit.
        ; N/Space stay on find-next WITHIN the file, as in native XTree. Every candidate lives in the
        ; same directory, so we chdir ONCE up front (the viewer f_opens namebuf relative to cwd).
        ; Find-history is skipped during a walk (histcount 255) to keep this loop small; the plain
        ; file-pane V still primes it for a single file.
        if not viewer_ok {
            flash("viewer overlay missing")
            return
        }
        if xfiles.ft_count == 0
            return
        ; NB: no chdir here - each file is chdir'd to as the walk reaches it (the viewer opens
        ; namebuf relative to the cwd), so a scoped set can walk files from different directories.
        ; Hand the viewer the last content-search term (if any) so each file opens ON its first hit
        ; with the find highlight lit. 0 = no term -> files open at the top, unhighlighted.
        uword seedp = 0
        if srch_term[0] != 0
            seedp = &srch_term
        ; count the set first, so the viewer can show "File N of M" and the walk's progress is
        ; visible instead of guessed at
        uword total = 0
        uword i = 0
        while i < xfiles.ft_count {
            if xfiles.is_tagged(i)
                total++
            i++
        }
        if total == 0 {
            flash("Tag files first (T), then view tagged")
            return
        }
        ; Walk by INDEX rather than a for-loop, so the viewer can send us backwards as well as
        ; forwards. `cur` is the ft_ index of the file on screen, `seen` its 1-based position in
        ; the tagged set (shown as "File n/m"). A step that would fall off either end simply
        ; re-shows the current file, so the ends of the set are soft stops rather than an exit.
        uword cur = 0
        while cur < xfiles.ft_count and not xfiles.is_tagged(cur)
            cur++
        uword seen = 1
        uword j
        ; The viewer's "File n of m" counters are bytes (they are R4/R5 of the tview jmptable entry).
        ; The walk stays uword and exact; only the DISPLAY saturates at 255, which beats wrapping to
        ; "File 45 of 44" on a tagged set that spans the disk.
        ubyte shown_tot = 255
        if total < 256
            shown_tot = lsb(total)
        repeat {
            xfiles.get_name(cur, namebuf)
            file_cursor = cur                           ; leave the pane cursor on the file we stop at
            cd_to_entry(cur)                            ; this file's own directory
            uword wblk = xfiles.get_blocks(cur)         ; size for the footer's "n%"; own local, since
                                                        ; a call in the arg list would clobber r0 first
            ubyte shown_num = 255
            if seen < 256
                shown_num = lsb(seen)
            ubyte r = view_file(&namebuf, 255, 1, seedp, shown_num, shown_tot, wblk)
            if r == 0
                break                                   ; Q/ESC ends the walk
            if r == 1 {
                j = cur + 1                             ; next tagged file after cur
                while j < xfiles.ft_count and not xfiles.is_tagged(j)
                    j++
                if j < xfiles.ft_count {
                    cur = j
                    seen++
                }
            } else {
                j = cur                                 ; previous tagged file before cur
                while j != 0 {
                    j--
                    if xfiles.is_tagged(j) {
                        cur = j
                        seen--
                        break
                    }
                }
            }
        }
        txt.color2(shared.CLR_FG, shared.CLR_BG)        ; viewer left the text color blue; restore theme
    }

    sub op_search_tagged() {
        ; XTree CTRL-S: prompt for a text term, scan the TAGGED files in THIS directory and untag
        ; every one whose CONTENTS don't contain it - so the tag set collapses to the matches and
        ; CTRL-V then walks exactly those. Untagged files are never candidates: tag first (T for one,
        ; CTRL-T for all), then search. The per-file byte scan lives in the miscutil overlay
        ; (content_scan); here we drive it and show a live "(n of N)" counter with any-key abort.
        if not misc_ok {
            flash("Search needs the misc overlay")
            return
        }
        if xfiles.ft_count == 0
            return
        uword tagged = 0                                ; how many candidates (tagged files) to scan
        uword i = 0
        while i < xfiles.ft_count {
            if xfiles.is_tagged(i)
                tagged++
            i++
        }
        if tagged == 0 {
            flash("Tag files first (T), then search")
            return
        }
        if not input_line("Search tagged for:", inputbuf, 32, "content", false, false)  ; 32 = SCAN_TCAP
            return
        if inputbuf[0] == 0
            return
        void strings.copy(inputbuf, srch_term)          ; remember it for the Ctrl-V walk's highlight
        while cbm.GETIN2() != 0 { }                     ; drain the ENTER/typeahead before scanning

        ; NB: pathbuf is rebuilt per candidate inside the loop - in a scoped listing the tagged
        ; files come from all over the disk, which is what turns this into a whole-disk content
        ; search rather than a single-directory one.
        box_open()
        box_left(CMDROW1, "Searching...")
        uword n = 0                                     ; candidates scanned so far
        uword next_row = 0                              ; stepped before the body: it `continue`s
        while next_row < xfiles.ft_count {
            i = next_row
            next_row++
            if not xfiles.is_tagged(i)
                continue
            n++
            box_progress(n, tagged)
            ; walk the file pane's highlight bar onto the file being scanned, so you can watch the
            ; search move down the list instead of just reading a counter. The status box only
            ; covers the bottom rows, so the pane above stays live; draw_files_cursor is the light
            ; two-row repaint (it falls back to a full pane draw only when the window scrolls).
            file_cursor = i
            draw_files_cursor()
            if cbm.GETIN2() != 0                        ; any key aborts; remaining tags stay as-is
                break
            xfiles.get_name(i, namebuf)
            xtree.build_path(xfiles.row_dir(i), pathbuf)     ; this candidate's own directory
            if content_scan(&pathbuf, &namebuf, &inputbuf) == 0 {
                xfiles.toggle_tag(i)  ; miss -> untag (keeps the dir count in step)
                draw_status()                           ; live "N Tagged" in the top-right header:
                                                        ; the count only changes on a miss, so redraw
                                                        ; here rather than every iteration
            }
        }
        ; No closing "Still tagged: n of m" banner - the live counter above already showed the
        ; progress, and the header's Tagged count plus the '*' markers show the result. One less
        ; keypress between searching and reading what matched.
        box_close()
    }

    ; ---------- Ctrl-F: whole-disk Find ----------

    sub op_find() {
        ; Ctrl-F: prompt for a filespec, crawl the WHOLE disk from "/", log every directory that
        ; contains a match (match-less dirs are never logged, so the tree stays clean and the
        ; 128-dir cap is respected), then show the matches as a flat modal list you can jump from.
        ;
        ; The crawler lives in the miscutil overlay (bank 3) and yields one matching-dir path at a
        ; time via its OWN diskio; between hits we log that one dir with main's diskio. Only one
        ; listing is ever open at any instant, so the two never collide.
        if not misc_ok {
            flash("Find needs the misc overlay")
            return
        }
        ; Drop any scoped view FIRST. Find rebuilds the tree from scratch (every node id changes,
        ; so a stored branch_root would point at the wrong folder) and lands you on one specific
        ; directory, which is a normal two-pane result. Staying "in" Showall/Branch would leave the
        ; title bar and the full-width geometry claiming a scope the listing no longer has.
        if xfiles.file_scope != xfiles.SCOPE_DIR
            leave_scope()
        if not input_line("Find (eg *.prg):", inputbuf, 31, "find", false, false)
            return
        if inputbuf[0] == 0
            return
        void strings.copy(inputbuf, find_lc)        ; lowercase a copy for nocase matching
        void strings.lower(find_lc)

        ; Remember where the user is browsing: the reset below rebuilds the tree from scratch
        ; (invalidating every node id), so we re-anchor on this path afterwards for a clean
        ; return on ESC / "no matches". (pathbuf and cm_ddir are free during a Find.)
        xtree.build_path(cur_dir, pathbuf)
        void strings.copy(xfiles.spec_lc, cm_ddir)  ; and the active FileSpec (reset() clears it)

        ; Fresh slate for EACH Find - a whole-disk search that stands on its own. Without this
        ; the match-dirs logged by a PRIOR Find linger in the tree, so dir_count is already at
        ; the 128-dir cap and the very first hit trips "(partial - capped)" even when this run
        ; matched only a handful of files. Clearing here also reclaims the arena the last crawl
        ; used, so repeated Finds don't slowly exhaust it.
        xarena.reset()
        xfiles.reset()
        xtree.init()                                ; root (node 0) = the drive root "/"
        void xscan.scan_dir(0)                      ; log the drive root
        xtree.d_flags[0] |= xtree.FL_EXPANDED

        box_open()                                  ; "Searching..." over the bottom rows
        box_left(CMDROW1, "Searching...")

        ubyte partial = 0                           ; bit0=too deep  bit1=dir cap  bit2=result cap
        uword nvisited = 0                          ; every directory the crawler walks (live counter)
        crawl_begin(find_lc)
        repeat {
            ubyte cr = crawl_next_hit(&cm_dst)      ; cm_dst (132 B) fits a full crawl path
            if cr == 0
                break                               ; disk exhausted
            nvisited++
            ; live "(Dir: N)" counter on row 2 of the box - counts EVERY dir scanned, so it keeps
            ; ticking through long match-less stretches (not just on hits). nvisited only grows, so
            ; no stale digits. (cm_dst holds the crawl path open_path needs, so print it straight.)
            txt.plot(BANNER_LEFT, CMDROW2)
            txt.print("(Dir: ")
            txt.print_uw(nvisited)
            txt.chrout(')')
            hilite_row(0, 79, CMDROW2, shared.CLR_BOTTOM_PROMPT_BG)   ; keep the row black-on-white
            if cr == 2 {                            ; this dir contains a match -> log it into the tree
                ubyte node = xscan.open_path(cm_dst)    ; log + expand ancestors, return deepest node
                void xscan.scan_dir(node)               ; log THIS dir's files (open_path only did ancestors)
                if xtree.dir_count >= xtree.DIR_MAX {
                    partial |= 2                        ; 254-dir cap: stop logging further hits
                    break
                }
            }
        }
        if crawl_trunc() != 0
            partial |= 1                            ; some subtree skipped (path too long)
        box_close()

        xtree.rebuild_visible()

        ; Re-anchor the dual-pane on the folder the user came from (recreated by open_path as it
        ; descends the saved path). If it matched nothing it isn't a crawl hit, so open_path lands
        ; on its deepest logged ancestor - still a sane spot rather than a stale/invalid node.
        ;
        ; This has to happen BEFORE the matches are gathered: select_dir rebuilds the file index,
        ; and the matches are gathered into that same index. Gathering first would leave the results
        ; overwritten by this directory's listing before the browser ever drew them.
        tree_top = 0
        ubyte back = xscan.open_path(pathbuf)
        void xscan.scan_dir(back)
        xtree.rebuild_visible()
        set_tree_cursor_to(back)
        xfiles.set_spec(cm_ddir)                    ; restore the pre-Find FileSpec before reindexing
        select_dir(back)

        xfiles.collect_matching(find_lc)            ; index now holds the matches, not the listing
        if xfiles.scope_partial
            partial |= 4                            ; results capped at INDEX_MAX

        if xfiles.ft_count == 0 {
            select_dir(back)                        ; nothing to browse - put the listing back
            if partial != 0
                flash("No matches (search was partial)")
            else
                flash("No matches")
            return
        }
        show_find_results(partial)
    }

    ; Flat-list modal layout for the Find panel (show_find_results): viewer-style reverse-blue header
    ; (row 0) + footer (SCR_BOT) bars, white-on-gray list body (rows SF_TOP..SF_TOP+SF_VIS-1). The bars
    ; are painted ONCE on entry; the body redraws a whole page only when it scrolls, otherwise just the
    ; two rows the cursor left and landed on. Rows come from the file index (which Find has loaded with
    ; its matches) via draw_find_row/draw_find_page over the sf_top window.
    const ubyte SF_TOP = 2
    const ubyte SF_VIS = 27                 ; list rows 2..28 (row 0 header bar, row 1 col headers, row 29 footer)
    ubyte sf_partial
    uword sf_top                            ; window top index; module-level so draw_find_row sees it

    sub draw_find_row(uword i, uword cursor) {
        ; paint the absolute-index entry i onto its screen row; caller keeps i within the visible
        ; window, so the row is SF_TOP + (i - sf_top). Highlights when i == cursor.
        ubyte srow = SF_TOP + lsb(i - sf_top)           ; (i - sf_top) is always 0..SF_VIS-1
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)    ; white on gray body
        blank_span(0, 79, srow)
        if i < xfiles.ft_count {
            txt.plot(0, srow)
            if i == cursor
                txt.chrout('>')
            else
                txt.spc()
            if xfiles.is_tagged(i)                  ; '*' tag marker, same convention as the file pane
                txt.chrout('*')
            else
                txt.spc()
            xtree.build_path(xfiles.row_dir(i), sa_line)
            xfiles.get_name(i, namebuf)
            ubyte sl = lsb(strings.length(sa_line))     ; append the filename with a cap so
            if sl < 99                                  ; path+name can't overflow the 100-byte
                str_copy_cap(namebuf, sa_line + sl, 99 - sl)  ; sa_line buffer
            print_trunc(sa_line, 69)
            txt.plot(73, srow)
            txt.print_uw(xfiles.get_blocks(i))
            if i == cursor
                hilite_row(0, 78, srow, shared.HILITE)
        }
    }

    sub draw_find_page(uword cursor) {
        ubyte row
        for row in 0 to SF_VIS-1
            draw_find_row(sf_top + row, cursor)
    }

    sub show_find_results(ubyte partial) {
        ; full-screen modal listing the Find matches the file index now holds (path + name + blocks).
        ; Enter jumps to the highlighted file; ESC/Q exits. Both exits must leave the file index back
        ; on a real directory listing - browsing borrowed it.
        sf_partial = partial
        sf_top = 0
        uword cursor = 0
        uword oldc

        ; static frame (drawn once): blue header + footer bars, gray body
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)
        txt.clear_screen()
        bar_fill(0)                                     ; header bar
        txt.plot(2, 0)
        txt.print("FIND matches: ")
        txt.print_uw(xfiles.ft_count)
        if sf_partial != 0
            txt.print("  (partial - capped)")
        txt.color2(shared.CLR_ACCENT, shared.CONTENT_BG) ; row 1: column headers over the gray body
        txt.plot(2, 1)
        txt.print("Name")
        txt.plot(73, 1)
        txt.print("Size")
        bar_fill(SCR_BOT)                               ; footer bar
        txt.plot(2, SCR_BOT)
        bar_key("Up/Dn")
        txt.print(" Move  ")
        bar_key(petscii:"←┘")
        txt.print(" Go Dir  ")
        bar_key("ESC")
        txt.print(" Exit")
        draw_find_page(cursor)

        repeat {
            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3, 'q' -> {
                    select_dir(cur_dir)     ; hand the index back to the directory listing
                    return
                }
                13 -> {                     ; enter: jump to the highlighted match, close the modal
                    if xfiles.ft_count != 0
                        jump_to_result(cursor)      ; does its own select_dir on the target
                    else
                        select_dir(cur_dir)
                    return
                }
                17 -> {                     ; down
                    if cursor + 1 < xfiles.ft_count {
                        oldc = cursor
                        cursor++
                        if cursor >= sf_top + SF_VIS {
                            sf_top++
                            draw_find_page(cursor)            ; scrolled: whole page
                        } else {
                            draw_find_row(oldc, cursor)      ; un-highlight the row we left
                            draw_find_row(cursor, cursor)    ; highlight the new row
                        }
                    }
                }
                145 -> {                    ; up
                    if cursor != 0 {
                        oldc = cursor
                        cursor--
                        if cursor < sf_top {
                            sf_top = cursor
                            draw_find_page(cursor)
                        } else {
                            draw_find_row(oldc, cursor)
                            draw_find_row(cursor, cursor)
                        }
                    }
                }
                2 -> {                      ; PgDn: next page (not shown in the footer, keys only)
                    if sf_top + SF_VIS < xfiles.ft_count {
                        sf_top += SF_VIS                     ; advance a whole page, cursor at its top
                        cursor = sf_top
                        draw_find_page(cursor)
                    } else if cursor + 1 != xfiles.ft_count {
                        cursor = xfiles.ft_count - 1         ; last page already shown: land on the end
                        draw_find_page(cursor)
                    }
                }
                130 -> {                    ; PgUp ($82): previous page
                    if sf_top != 0 {
                        if sf_top >= SF_VIS
                            sf_top -= SF_VIS
                        else
                            sf_top = 0
                        cursor = sf_top
                        draw_find_page(cursor)
                    } else if cursor != 0 {
                        cursor = 0
                        draw_find_page(cursor)
                    }
                }
            }
        }
    }

    sub jump_to_result(uword i) {
        ; land the dual-pane view on the file at index row i: expand every ancestor of its dir,
        ; put the tree cursor on the dir, filter the file pane to the search spec (so the match
        ; shows), and drop focus into the file pane on the matching row.
        ; Read the row FIRST - select_dir below rebuilds the very index i points into.
        ubyte dir = xfiles.row_dir(i)
        xfiles.get_name(i, namebuf)                  ; the matched filename
        ubyte a = xtree.dx_parent(dir)
        while a != xtree.NONE {
            xtree.d_flags[a] |= xtree.FL_EXPANDED
            a = xtree.dx_parent(a)
        }
        xtree.rebuild_visible()
        set_tree_cursor_to(dir)
        xfiles.set_spec(inputbuf)                    ; file pane shows the found set (draw clamps tops)
        select_dir(dir)                              ; rebuild the index with that spec (resets cursor/top)
        file_cursor = 0
        uword row = 0
        while row < xfiles.ft_count {
            xfiles.get_name(row, pathbuf)            ; pathbuf: name scratch (>= namebuf capacity)
            if strings.compare(pathbuf, namebuf) == 0 {
                file_cursor = row
                break
            }
            row++
        }
        focus = FOCUS_FILE
    }

    sub show_about() {
        ; the whole About modal is drawn by the uiutil overlay; pass it the live banked-RAM
        ; figures from xarena (it can't see main's blocks). Caller repaints (dirty_full) after.
        if ui_ok
            ui_show_about(xarena.high_bank, xarena.max_bank)
    }
}
