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
    const ubyte BUILD_NUM = 122          ; shown top-right; bump by 1 every build. Keep the About
                                         ; "Version 1.0.N" string in uiutil.p8 in sync with this.
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
    ; up-arrow. Colour is likewise embedded (\x9e=accent \x05=fg) - see the memory note on
    ; embedded PETSCII colour codes. No named glyph consts needed any more.

    ubyte focus
    ubyte tree_cursor, tree_top
    ubyte file_cursor, file_top
    ubyte cur_dir
    ubyte start_node                    ; tree node of the launch directory (selected at startup)
    uword cur_blocks                    ; total blocks of visible files in cur_dir
    ubyte saved_mode                    ; screen mode to restore on exit
    ubyte saved_charset                 ; pre-launch charset (2=upper/gfx 3=lower); restored on exit
    ubyte saved_color                   ; pre-launch text colour (bg<<4|fg); restored on exit

    ; per-keystroke "what changed" flags, so we repaint only the affected regions
    ; (e.g. moving in the file column never touches the directory column). The *_cur
    ; flags are the LIGHT variant: a pure cursor move that only re-inks two rows (old +
    ; new) instead of repainting the whole pane - unless the view scrolled (then full).
    bool dirty_tree, dirty_files, dirty_status, dirty_cmd, dirty_full
    bool dirty_tree_cur, dirty_file_cur

    ; cursor / scroll position last PAINTED, so a light update knows which row to un-ink
    ; and whether the pane scrolled since (top changed -> fall back to a full repaint)
    ubyte tree_cursor_shown, tree_top_shown
    ubyte file_cursor_shown, file_top_shown

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
    str exit_dir = "?" * 80

    ; "delete tagged" CTRL key. The emulator swallows Ctrl-D ($04) before it reaches
    ; us, so under the emulator we bind delete to Ctrl-X; on real hardware Ctrl-D is
    ; free, so we use the classic XTree Ctrl-D there. Set once at startup.
    ubyte del_key                           ; lowercase dispatch key: 'x' (emu) or 'd' (hw)
    ubyte del_char                          ; uppercase display char: 'X' or 'D'

    ; "find files" CTRL key. Same story: the emulator swallows Ctrl-F before it reaches us,
    ; so under the emulator we bind Find to Ctrl-N (fiNd); on real hardware Ctrl-F is free.
    ubyte find_key                          ; lowercase dispatch key: 'n' (emu) or 'f' (hw)
    ubyte find_char                         ; uppercase display char: 'N' or 'F'

    ; The X16 maps ALT to the Commodore (graphics) key, so ALT+letter returns a
    ; PETSCII graphics code in $A1..$BF (161..191) instead of the letter. This table
    ; maps each of those codes (indexed by code-161) back to its base letter, so the
    ; ALT command handler can keep matching on plain 's','x',...  0 = not a letter.
    ; (Verified: ALT+S delivers 174 = $AE = Commodore-S.)
    ubyte[31] alt_letter = [
        'k','i','t', 0 ,'g', 0 ,'m', 0 , 0 ,'n','q','d','z','s','p',
        'a','e','r','w','h','j','l','y','u','o', 0 ,'f','c','x','v','b' ]

    str namebuf = "?" * 52
    str pathbuf = "?" * 80
    str inputbuf = "?" * 84             ; holds typed text or a picked directory path
    str treeline = "?" * 48             ; composed tree row (connectors + name)
    str sa_line  = "?" * 100            ; composed ShowAll row (path + name)
    ubyte[20] levlast                   ; per-depth: is the ancestor a last child?

    ; shared "press any key" footer text (Prog8 has no const str; this str is never
    ; written). Reused by the About box and the 2-line completion banners.
    str MSG_PRESS_ANY_KEY = " Press any key "
    str MSG_ERR_COMMA     = "Can't rename: comma in name"   ; shared by both rename paths (file + dir)

    ; copy/move scratch: source & dest directory paths, and full file paths
    str cm_sdir = "?" * 80
    str cm_ddir = "?" * 80
    str cm_src  = "?" * 132
    str cm_dst  = "?" * 132
    str find_lc = "?" * 32                  ; Ctrl-F: lowercased filespec for the whole-disk crawl
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

    ; --- banked file viewer (tview) overlay ---
    ; tview.p8 is compiled as a %output library headerless blob (org $A000) and loaded into
    ; reserved HIRAM bank 2 (VIEW_BANK) at startup. extsub @bank wraps each call in JSRFAR,
    ; mapping the bank around it. $A000 = library init (jmp start); $A003 = view_file entry.
    const ubyte VIEW_BANK = 2
    extsub @bank 2 $A000 = tview_init()
    extsub @bank 2 $A003 = view_file(uword nameptr @R0)
    bool viewer_ok                          ; tview.ovl loaded OK -> V uses the banked viewer

    ; --- banked BMX image viewer (ximgview) overlay ---
    ; ximgview.p8 is a %output library blob loaded into reserved HIRAM bank 5. It displays a
    ; native X16 "BMX" bitmap file full-screen and returns to text mode on any key. $A000 = init;
    ; $A003 = view_image entry. V dispatches here when the selected file's name ends in ".bmx".
    const ubyte IMG_BANK = 5
    extsub @bank 5 $A000 = ximgview_init()
    extsub @bank 5 $A003 = view_image(uword nameptr @R0)
    bool imgview_ok                         ; ximgview.ovl loaded OK -> V shows .bmx images

    ; --- banked misc-utility overlay (miscutil) ---
    ; miscutil.p8 is a second %output library blob loaded into reserved HIRAM bank 3 at
    ; startup; it holds self-contained helpers moved out of main RAM (the wildcard rename
    ; expander, the recursive directory-prune engine, and the input-history ring). $A000 = init;
    ; $A003 = wildcard_expand(orig @R0, pat @R1, out @R2);
    ; $A006 = prune_dir(parent @R0, name @R1) -> ubyte (1=ok, 0=fail);
    ; $A009 = hist_load(cat @R0, base @R1) -> count; $A00C = hist_store(str @R0) -> count;
    ; $A00F = hist_save(cat @R0, base @R1); $A012 = hist_get(slot @R0, out @R1);
    ; $A015 = stream_copy(src @R0, dst @R1) -> uword (lsb=fail 0/1/2/3, msb=DOS code).
    const ubyte MISC_BANK = 3
    extsub @bank 3 $A000 = miscutil_init()
    extsub @bank 3 $A003 = wildcard_expand(uword origptr @R0, uword patptr @R1, uword outptr @R2)
    extsub @bank 3 $A006 = prune_dir(uword parptr @R0, uword nameptr @R1) -> ubyte @A
    ; history ring lives in the overlay; main caches the count returned by load/store. cat/base
    ; are string pointers (the category name and xtree.base_path); the picker reads slots via
    ; hist_get into hist_line. If misc_ok is false, input_line skips history entirely.
    extsub @bank 3 $A009 = hist_load(uword cat @R0, uword base @R1) -> ubyte @A
    extsub @bank 3 $A00C = hist_store(uword sptr @R0) -> ubyte @A
    extsub @bank 3 $A00F = hist_save(uword cat @R0, uword base @R1)
    extsub @bank 3 $A012 = hist_get(ubyte slot @R0, uword outptr @R1)
    ; the file-copy byte pump lives in the overlay too (its 255-byte buffer no longer costs main
    ; RAM). src is an absolute path, dst a bare name in the CWD the caller chdir'd into.
    extsub @bank 3 $A015 = stream_copy(uword srcptr @R0, uword dstptr @R1) -> uword @AY
    ; whole-disk "Find file" crawler (also overlay-resident: its path buffers cost no main RAM).
    ; crawl_begin(specptr) starts a fresh crawl for the lowercased filespec; crawl_next_hit(outptr)
    ; writes the next matching-dir path to outptr and returns 1 (0 = disk exhausted); crawl_trunc()
    ; is 1 if any subtree was skipped for being too deep. Only one listing is ever open at a time,
    ; so main's own diskio (open_path/scan_dir) is free to run between hits.
    extsub @bank 3 $A018 = crawl_begin(uword specptr @R0)
    extsub @bank 3 $A01B = crawl_next_hit(uword outptr @R0) -> ubyte @A
    extsub @bank 3 $A01E = crawl_trunc() -> ubyte @A
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
    extsub @bank 4 $A027 = ui_draw_commands(ubyte menu_mode @R0, ubyte focus @R1, ubyte del_char @R2, ubyte sort_mode @R3, ubyte find_char @R4)
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
        snapshot_machine_state()                 ; capture charset + text colour before we change anything
        cx16.set_screen_mode(SCREEN_MODE)        ; 80x30

        ; pick the environment-specific CTRL keys (the emulator swallows Ctrl-D and Ctrl-F)
        if emudbg.is_emulator() {
            del_key  = 'x'
            del_char = 'X'
            find_key  = 'n'
            find_char = 'N'
        } else {
            del_key  = 'd'
            del_char = 'D'
            find_key  = 'f'
            find_char = 'F'
        }
        txt.lowercase()
        txt.color2(shared.CLR_FG, shared.CLR_BG)               ; white text on a blue field
        txt.clear_screen()

        ; remember where we were launched from before any diskio call clobbers the
        ; shared buffer curdir() points into
        void strings.copy(diskio.curdir(), pathbuf)

        ; the .ovl overlays are staged in the program's own /XFMGR/ folder (run.bat), which is
        ; NOT the boot cwd when launched via the root XT loader. Hop into it to load them; if
        ; there's no XFMGR subdir (dev/direct-run layout) chdir is a no-op and they load from cwd.
        diskio.chdir("xfmgr")           ; lowercase: prog8 petscii maps a-z -> $41-5A, the bytes the FS matches

        ; load the tview viewer overlay into its reserved bank (VIEW_BANK) at $A000, then run
        ; its one-time library init.
        cx16.push_rambank(VIEW_BANK)
        viewer_ok = diskio.loadlib("tview.ovl", $a000) != 0
        cx16.pop_rambank()
        if viewer_ok
            tview_init()                ; extsub @bank 2: clears the overlay's in-bank BSS ONCE

        ; load the miscutil overlay into its reserved bank (MISC_BANK) the same way
        cx16.push_rambank(MISC_BANK)
        misc_ok = diskio.loadlib("miscutil.ovl", $a000) != 0
        cx16.pop_rambank()
        if misc_ok
            miscutil_init()             ; extsub @bank 3: clears the overlay's in-bank BSS ONCE

        ; load the uiutil dialog overlay into its reserved bank (UI_BANK) the same way
        cx16.push_rambank(UI_BANK)
        ui_ok = diskio.loadlib("uiutil.ovl", $a000) != 0
        cx16.pop_rambank()
        if ui_ok
            uiutil_init()               ; extsub @bank 4: clears the overlay's in-bank BSS ONCE

        ; load the ximgview BMX image viewer overlay into its reserved bank (IMG_BANK) the same way
        cx16.push_rambank(IMG_BANK)
        imgview_ok = diskio.loadlib("ximgview.ovl", $a000) != 0
        cx16.pop_rambank()
        if imgview_ok
            ximgview_init()             ; extsub @bank 5: clears the overlay's in-bank BSS ONCE

        ; apply the saved colour theme. cfg_read() is self-contained - it hops into /xfmgr/ to LOAD
        ; the cfg and restores the cwd itself - so it works regardless of where we are here.
        ; A palette remap - full_redraw below repaints in the themed colours. Missing cfg -> Classic.
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
        restore_machine_state()                  ; re-apply the user's charset + text colour (CINT reset them)
        if run_exit {
            ; hand off to BASIC: load + run the selected program via the dynamic keyboard
            diskio.chdir(pathbuf)               ; the selected file's directory
            chain_run(namebuf)
        } else if setup_exit {
            ; hand off to the theme setup PRG (absolute path -> cwd doesn't matter). It writes
            ; xfmgr.cfg then relaunches /xfmgr/xfmgr.prg, which re-reads + applies the theme.
            chain_run("/xfmgr/xfsetup.prg")
        } else {
            diskio.chdir(exit_dir)              ; leave the shell in the chosen directory
            txt.clear_screen()                  ; clean screen (in the restored charset/colours) before the sign-off
            txt.print("xfmgr done.\n")
        }
    }

    sub snapshot_machine_state() {
        ; capture the user's charset + text colour so exit can put them back (set_screen_mode's CINT
        ; resets both to X16 defaults). Read while STILL in the launch screen mode.
        saved_charset = cx16.get_charset()          ; 1=ISO 2=PETSCII upper/gfx 3=PETSCII lower (0=unknown)
        ; text colour = the colour matrix at the cursor cell. MUST use txt.getclr, not a hand-computed
        ; VERA address: the text matrix has a fixed 256-byte row stride (128 cols), so row*width*2 is
        ; wrong for row>0 - that was the earlier "bad background" bug. High nibble=bg, low nibble=fg.
        ubyte cx_col
        ubyte cx_row
        cx_col, cx_row = txt.get_cursor()
        saved_color = txt.getclr(cx_col, cx_row)
    }

    sub restore_machine_state() {
        ; undo XFMGR's charset + colour changes: re-apply what snapshot_machine_state() captured (the
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
        cur_blocks = 0
        if xtree.d_flags[idx] & xtree.FL_SCANNED != 0 {
            void xfiles.build_index(idx)
            if xfiles.ft_count != 0
                for g_ndx in 0 to xfiles.ft_count-1
                    cur_blocks += xfiles.get_blocks(g_ndx)
        } else {
            xfiles.ft_count = 0
        }
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
        when letter {
            't' -> {                        ; Ctrl-T: tag ALL files
                xfiles.tag_all(cur_dir)
                dirty_files = true
                dirty_status = true
            }
            'u' -> {                        ; Ctrl-U: untag all
                xfiles.untag_all(cur_dir)
                dirty_files = true
                dirty_status = true
            }
            'i' -> {                        ; Ctrl-I: invert tags
                xfiles.invert_all(cur_dir)
                dirty_files = true
                dirty_status = true
            }
            'g' -> {                        ; Ctrl-G: ShowAll (global tagged view)
                show_all()
                dirty_full = true
            }
            'c' -> {                        ; Ctrl-C: copy this dir's tagged files
                op_copymove(false, true)
                dirty_full = true
            }
            'o' -> {                        ; Ctrl-O: move this dir's tagged files
                                            ; (Ctrl-M is Enter/$0D, eaten by the kernal)
                op_copymove(true, true)
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
            $15 -> {                        ; Alt-F10: open the colour-theme setup (either pane)
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
        ; Entering the FILE column on a directory that hasn't been logged yet logs it now
        ; (scan folders + files) so the file pane has something to show, instead of landing
        ; on an empty column. Mirrors the Enter key's first-time scan. Covers TAB and
        ; cursor-right; switching back to the tree never triggers a scan.
        if newfocus == FOCUS_FILE and xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0 {
            void xscan.scan_dir(cur_dir)
            if xtree.has_kids(cur_dir)
                xtree.d_flags[cur_dir] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
            set_tree_cursor_to(cur_dir)
            select_dir(cur_dir)
            dirty_status = true
        }
        focus = newfocus
        ; both panes' selection indicators flip (bar <-> '>') and the menu changes
        dirty_tree = true
        dirty_files = true
        dirty_cmd = true
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
            'k' -> {
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
            'a' -> {                    ; A: about (replaces the old '?')
                show_about()
                dirty_full = true
            }
        }
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
                    ubyte last = xfiles.ft_count - 1
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
                    xfiles.toggle_tag(file_cursor, cur_dir)
                    if file_cursor + 1 < xfiles.ft_count
                        file_cursor++           ; tag-and-advance, like XTree
                    dirty_files = true
                    dirty_status = true
                }
            }
            'u' -> {
                if xfiles.ft_count != 0 {
                    if xfiles.is_tagged(file_cursor)
                        xfiles.toggle_tag(file_cursor, cur_dir)
                    if file_cursor + 1 < xfiles.ft_count
                        file_cursor++           ; untag-and-advance
                    dirty_files = true
                    dirty_status = true
                }
            }
            'v' -> {                            ; View: .bmx -> banked image viewer, else text/hex viewer
                if xfiles.ft_count != 0 {
                    xfiles.get_name(file_cursor, namebuf)
                    xtree.build_path(cur_dir, pathbuf)
                    diskio.chdir(pathbuf)       ; so bmx.open/f_open(namebuf) resolve in the file's dir
                    if imgview_ok and file_is_bmx(&namebuf) {
                        view_image(&namebuf)            ; bank-5 overlay: shows the BMX, returns on any key
                        cx16.set_screen_mode(SCREEN_MODE)  ; image viewer left VERA in bitmap mode -> back to 80x30
                        txt.lowercase()                 ; CINT/set_screen_mode reset the charset to uppercase
                        txt.color2(shared.CLR_FG, shared.CLR_BG)   ; restore app theme after CINT reset the palette
                    } else if viewer_ok {
                        view_file(&namebuf)             ; tview reads via its own bank-2 buffer (returns on Q/ESC)
                        txt.color2(shared.CLR_FG, shared.CLR_BG)   ; viewer left the text colour blue; restore app theme
                                                     ; (full_redraw's blanks use the current colour)
                    } else {
                        op_edit()               ; overlays missing -> fall back to X16 Edit
                    }
                    dirty_full = true           ; viewer/editor took the screen; repaint
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

    sub full_redraw() {
        ; No full clear_screen: the static frame is overwritten with setchr and the
        ; dynamic regions blank+repaint their own lines, which avoids the whole-screen
        ; wipe that caused flicker.
        draw_frame()
        draw_status()
        draw_tree()
        draw_files()
        draw_commands()
    }

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        ; erase a horizontal run to spaces in the base colour (resets any bar colour)
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
        hline(0, SC_TL, SC_H, SC_TR)        ; top border
        hline(2, SC_JL, SC_JT, SC_JR)       ; header / panes divider (carries titles)
        hline(DIVBOT, SC_JL, SC_JB, SC_JR)  ; panes / command divider
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
        ; side + middle borders down the content area
        for g_ndx in PANE_TOP to PANE_BOT {
            txt.setchr(0, g_ndx, SC_V)
            txt.setchr(SPLIT, g_ndx, SC_V)
            txt.setchr(79, g_ndx, SC_V)
            txt.setclr(0, g_ndx, shared.CLR_BOX)
            txt.setclr(SPLIT, g_ndx, shared.CLR_BOX)
            txt.setclr(79, g_ndx, shared.CLR_BOX)
        }
        ; window titles embedded in the divider line
        txt.color(shared.CLR_TITLE)
        txt.plot(TREE_TEXT, 2)
        txt.print(" DIRECTORY ")
        txt.plot(FILE_TEXT, 2)
        txt.print(" FILE: ")
        print_trunc(xfiles.spec_lc, 14)
        txt.spc()
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
        ; path on the left of the header row
        txt.plot(TREE_TEXT, HDRROW)
        txt.print("Path: ")
        xtree.build_path(cur_dir, pathbuf)
        print_trunc(pathbuf, 40)                ; leave room for the counts on the right
        ; file + tag counts, pushed to the far right of the header row (border at col 79)
        cm_dst[0] = 0
        box_append_uw(xfiles.ft_count)
        void strings.append(cm_dst, " Files ")
        box_append_uw(xtree.dx_tag(cur_dir))
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
        ubyte depth = xtree.d_depth[idx]
        ; for each ancestor level, record whether that node is its parent's last child
        ubyte n = idx
        ubyte dd = depth
        while dd != 0 {
            levlast[dd] = 0
            if xtree.d_next_sibling[n] == xtree.NONE
                levlast[dd] = 1
            n = xtree.d_parent[n]
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
        blank_span(FILE_MARK, FILE_BAR_R, FILE_HDR)
        txt.color(shared.CLR_ACCENT)
        txt.plot(FILE_TEXT, FILE_HDR)
        txt.print("Name")
        txt.color(shared.CLR_FG)
        ; "(Total blocks: N)" centered in the file pane, between the Name and Size labels
        void strings.copy("(Total blocks: ", cm_dst)
        box_append_uw(cur_blocks)
        void strings.append(cm_dst, ")")
        txt.plot(FILE_TEXT + (FILE_BAR_R - FILE_TEXT + 1 - lsb(strings.length(cm_dst))) / 2, FILE_HDR)
        txt.print(cm_dst)
        txt.color(shared.CLR_ACCENT)
        txt.plot(FILE_SIZE, FILE_HDR)
        txt.print("Size")
        txt.color(shared.CLR_FG)
    }

    sub draw_file_row(ubyte i) {
        ; paint ONE file row: file entry i at its screen row (assumes i is in the window)
        ubyte srow = FILE_TOP + (i - file_top)
        blank_span(FILE_MARK, FILE_BAR_R, srow)
        if i < xfiles.ft_count {
            txt.plot(FILE_MARK, srow)
            if i == file_cursor and focus != FOCUS_FILE
                txt.chrout('>')
            else
                txt.spc()
            if xfiles.is_tagged(i)
                txt.chrout('*')
            else
                txt.spc()
            xfiles.get_name(i, namebuf)
            print_trunc(namebuf, 27)
            txt.plot(FILE_SIZE, srow)
            txt.print_uw(xfiles.get_blocks(i))
            ; tagged files are flagged by the '*' marker only - the row keeps the
            ; normal colours (no bar). The focused selection bar still wins on the cursor.
            if i == file_cursor and focus == FOCUS_FILE
                hilite_row(FILE_MARK, FILE_BAR_R, srow, shared.HILITE)
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
            txt.plot(FILE_TEXT, FILE_TOP)
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
            ui_draw_commands(menu_mode, focus, del_char, xfiles.sort_mode, find_char)
    }

    ; ---------- file operations ----------

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
            xtree.build_path(cur_dir, pathbuf)
            diskio.chdir(pathbuf)
            diskio.delete(namebuf)
            xfiles.hide(file_cursor, cur_dir)       ; drop from the cached view
            void xfiles.build_index(cur_dir)
            clamp_file_cursor()
            if xfiles.ft_count == 0                 ; last file gone -> hop back to the dir pane
                change_focus(FOCUS_TREE)
            banner_delete(1)                        ; result banner, like copy/move
        }
    }

    sub op_delete_tagged() {
        if xtree.dx_tag(cur_dir) == 0 {
            flash("no tagged files")
            return
        }
        uword ntag = xtree.dx_tag(cur_dir)
        ubyte mode = ask_confirm_each(ntag)         ; 1 = confirm each, 0 = delete all, 255 = cancel
        if mode == 255
            return
        xtree.build_path(cur_dir, pathbuf)
        diskio.chdir(pathbuf)
        bool allrem = mode == 0                     ; "No" at the top prompt -> delete all, no asking
        uword ndel = 0
        ; Walk DOWNWARD: deleting a file + reindexing only shifts indices ABOVE it, which we've
        ; already visited, so lower indices stay valid. Local `fi` (not g_ndx): the per-file
        ; prompt and the live repaint both clobber the shared g_ndx counter.
        ubyte fi = xfiles.ft_count
        while fi != 0 {
            fi--
            if xfiles.is_tagged(fi) {
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
                    diskio.delete(namebuf)
                    xfiles.hide(fi, cur_dir)        ; clears its tag + marks deleted
                    ndel++
                    void xfiles.build_index(cur_dir)    ; recompact the cached view...
                    clamp_file_cursor()
                    draw_files()                        ; ...and repaint so the file leaves the screen live
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
        if not input_line("New dir:", inputbuf, 49, "mkdir", false)
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
        if not input_line("PRUNE - type 'prune' to confirm:", inputbuf, 49, "", false)
            return
        if strings.compare(inputbuf, "prune") != 0 {
            flash("not confirmed - prune cancelled")
            return
        }
        ubyte parent = xtree.d_parent[idx]
        ubyte uprow = tree_cursor                       ; pruned dir's visible row (>=1; root
        if uprow != 0                                   ; is never prunable) -> land ONE row up,
            uprow--                                     ; i.e. on the previous entry, not the top
        xtree.build_path(parent, pathbuf)               ; parent dir (absolute, trailing '/')
        void strings.copy(xtree.name_ptr(idx), namebuf) ; stable copy of the target name
        box_compose_name("pruning ", namebuf, " ...")   ; transient status; the result box follows
        box_open()
        box_left(CMDROW1, cm_dst)
        bool ok = false
        if misc_ok
            ok = prune_dir(&pathbuf, &namebuf) != 0     ; banked engine (miscutil overlay, bank 3)
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
            box_open()                                      ; 4-row white box, like relog/copy
            box_left(CMDROW1, "Prune OK")
            sys.wait(90)                                     ; show ~1.5s, then auto-dismiss (no keypress)
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
        ubyte parent = xtree.d_parent[idx]
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
        if not input_line("Rename dir to:", inputbuf, 49, "rename", false)
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
        ubyte parent = xtree.d_parent[idx]
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
        if not input_line("Rename to (* ? ok):", inputbuf, 49, "rename", false)
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
        xtree.build_path(cur_dir, pathbuf)
        diskio.chdir(pathbuf)
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
            void xfiles.build_index(cur_dir)
        } else {
            ; longer than the slot: re-read the directory so the full-length name shows
            ; (the append-only arena can't grow a record). This resets the dir's tags.
            void xscan.refresh_files(cur_dir)
            void xfiles.build_index(cur_dir)
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
        if not confirm("Dest dir missing. Create it?", true)     ; default Yes
            return false
        make_dirs(path)                         ; create the whole chain, not just the leaf
        if dir_exists(path)                     ; confirm it really got created (and enter it)
            return true
        flash("could not create dest folder")
        return false
    }

    sub op_copymove(bool is_move, bool use_tags) {
        ; use_tags=false (plain C/M): act on the single highlighted file, IGNORING tags.
        ; use_tags=true  (CTRL C/O):  act on every tagged file in THIS directory only.
        ; (cross-directory batch copy/move lives in ShowAll - see op_copymove_global.)
        if xfiles.ft_count == 0
            return
        if use_tags and xtree.dx_tag(cur_dir) == 0 {
            flash("no tagged files in this dir")
            return
        }

        if is_move {
            if not input_line("Move to dir:", inputbuf, 79, "move", true)
                return
        } else {
            if not input_line("Copy to dir:", inputbuf, 79, "copy", true)
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

        if strings.compare(cm_sdir, cm_ddir) == 0 {
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
        ubyte i
        for i in 0 to xfiles.ft_count-1 {
            if use_tags and not xfiles.is_tagged(i)
                continue
            if not use_tags and i != file_cursor
                continue
            xfiles.get_name(i, namebuf)
            when copy_one(namebuf) {
                1 -> {
                    done++
                    if is_move {
                        ; remove the source copy and drop it from the cached view
                        void strings.copy(cm_sdir, cm_src)
                        void strings.append(cm_src, namebuf)
                        diskio.delete(cm_src)
                        xfiles.hide(i, cur_dir)
                    }
                }
                2 -> skipped++
                else -> failed++
            }
        }

        ; refresh the source view (moved files vanish) and the dest dir if it's logged
        if is_move
            void xfiles.build_index(cur_dir)
        ubyte dd = find_dir_by_path(cm_ddir)
        if dd != xtree.NONE and xtree.d_flags[dd] & xtree.FL_SCANNED != 0 {
            void xscan.refresh_files(dd)
            if dd == cur_dir
                void xfiles.build_index(cur_dir)
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
        ; set the file-display wildcard (e.g. *.prg). ENTER on a blank line inserts *.* (= all).
        if not input_line(petscii:"File spec (eg *.prg, ←┘ = *.*):", inputbuf, 31, "filespec", false)
            return
        if strings.length(inputbuf) == 0
            void strings.copy("*.*", inputbuf)      ; blank ENTER -> DOS-style show-all
        xfiles.set_spec(inputbuf)
        void xfiles.build_index(cur_dir)
        file_top = 0
        clamp_file_cursor()
    }

    sub op_tag_by_spec() {
        ; Ctrl-S: tag every visible file in the current dir matching a wildcard
        if not input_line("Tag matching (eg *.bak):", inputbuf, 31, "tagspec", false)
            return
        void strings.copy(inputbuf, cm_dst)         ; lowercase a copy for nocase match
        void strings.lower(cm_dst)
        ubyte cnt = xfiles.tag_by_spec(cm_dst, cur_dir)
        void strings.copy("Tagged ", cm_dst)
        box_append_uw(cnt)
        void strings.append(cm_dst, " file(s)")
        box_open()
        box_left(CMDROW1, cm_dst)
        box_left(CMDROW2, MSG_PRESS_ANY_KEY)
        void wait_key()
        box_close()
    }

    sub refresh_all_scanned() {
        ; re-read every logged directory's files (used after a global move)
        for g_ndx in 0 to xtree.dir_count-1 {
            if xtree.d_flags[g_ndx] & xtree.FL_SCANNED != 0
                void xscan.refresh_files(g_ndx)
        }
    }

    sub op_copymove_global(bool is_move) {
        ; ShowAll C/M: copy or move EVERY tagged file (across all logged dirs) to a chosen
        ; destination. Each file is copied from its own source directory. This is the one
        ; cross-directory batch; the CTRL menu's Copy/Move act on the current dir only.
        xfiles.collect_tagged()
        if xfiles.sa_count == 0 {
            flash("no tagged files anywhere")
            return
        }
        if is_move {
            if not input_line("Move tagged to:", inputbuf, 79, "move", true)
                return
        } else {
            if not input_line("Copy tagged to:", inputbuf, 79, "copy", true)
                return
        }
        ; resolve dest dir (absolute as typed, else relative to the drive root)
        if inputbuf[0] == '/' {
            void strings.copy(inputbuf, cm_ddir)
        } else {
            void strings.copy(xtree.base_path, cm_ddir)
            ensure_slash(cm_ddir)
            void strings.append(cm_ddir, inputbuf)
        }
        ensure_slash(cm_ddir)
        if not ensure_dest_dir(cm_ddir)         ; offer to create a missing destination
            return
        diskio.chdir(cm_ddir)                   ; copy with the dest as cwd (hostfs writes there)
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
        ubyte i
        for i in 0 to xfiles.sa_count-1 {
            xtree.build_path(xfiles.sa_dir[i], cm_sdir)     ; this file's source dir
            if strings.compare(cm_sdir, cm_ddir) == 0 {
                failed++                                     ; same dir: skip
                continue
            }
            xfiles.sa_name(i, namebuf)
            when copy_one(namebuf) {
                1 -> {
                    done++
                    if is_move {
                        void strings.copy(cm_sdir, cm_src)
                        void strings.append(cm_src, namebuf)
                        diskio.delete(cm_src)
                    }
                }
                2 -> skipped++
                else -> failed++
            }
        }

        if is_move {
            refresh_all_scanned()
        } else {
            ubyte dd = find_dir_by_path(cm_ddir)
            if dd != xtree.NONE and xtree.d_flags[dd] & xtree.FL_SCANNED != 0
                void xscan.refresh_files(dd)
        }
        void xfiles.build_index(cur_dir)
        clamp_file_cursor()

        if done == 0 and skipped == 0
            copy_diag()
        else
            banner_copymove(is_move, done, failed, skipped)
    }

    sub op_sort() {
        ; Alt-S: cycle the file sort order (name -> ext -> size) and re-sort the pane
        xfiles.sort_mode++
        if xfiles.sort_mode > 2
            xfiles.sort_mode = 0
        void xfiles.build_index(cur_dir)
        clamp_file_cursor()
        ; brief 4-row white box so the new order is obvious even with 0/1 files
        box_open()
        box_left(CMDROW1, "Sort order:")
        when xfiles.sort_mode {
            1 -> box_left(CMDROW2, "extension")
            2 -> box_left(CMDROW2, "size")
            else -> box_left(CMDROW2, "name")
        }
        sys.wait(45)                ; ~0.75s, then the menu repaints over it
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
            sys.wait(120)
            box_close()
            return
        } else {
            void xscan.refresh_files(cur_dir)
        }
        void xfiles.build_index(cur_dir)
        cur_blocks = 0
        if xfiles.ft_count != 0
            for g_ndx in 0 to xfiles.ft_count-1
                cur_blocks += xfiles.get_blocks(g_ndx)
        clamp_file_cursor()
        box_open()
        box_left(CMDROW1, "relogged")
        cm_dst[0] = 0
        box_append_uw(xfiles.ft_count)
        void strings.append(cm_dst, " file(s)")
        box_left(CMDROW2, cm_dst)
        sys.wait(90)               ; show the box ~2 seconds, then auto-dismiss
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
        xtree.build_path(cur_dir, pathbuf)
        diskio.chdir(pathbuf)
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
        diskio.chdir(pathbuf)                   ; X16Edit can change dir; restore ours
    }

    sub op_setup() {
        ; Alt-F10: open the standalone colour-theme setup. It is a separate PRG, so launching it
        ; QUITS XFMGR - all logged folders and tags are lost. On save it relaunches XFMGR, which
        ; re-reads and applies the chosen theme. Confirm (default No) before the destructive hop.
        if confirm("Setup? loses logged dirs + tags", false) {
            setup_exit = true
        }
    }

    sub op_execute() {
        ; Alt-X: run the selected program. The X16 can't return to XFMGR afterwards
        ; (loading the program overwrites us), so we confirm, then quit to BASIC with a
        ; LOAD + RUN queued in the keyboard buffer. The main loop sees run_exit and breaks.
        if xfiles.ft_count == 0
            return
        xfiles.get_name(file_cursor, namebuf)
        box_compose_name("Run ", namebuf, "? exits XFMGR")
        if confirm(cm_dst, true) {                  ; default Yes
            xtree.build_path(cur_dir, pathbuf)
            run_exit = true
        }
    }

    sub op_release() {
        ; Alt-R (file pane): un-log the current folder to free the memory it holds. Clears
        ; its scanned state, drops its logged subfolders + file records, and collapses it
        ; back to the "(Enter to log)" state; a later Enter re-scans it fresh. The banked
        ; bytes are reclaimed on the next full reset (the arena is append-only, see xarena),
        ; so this releases the folder LOGICALLY. Nothing to release if it was never logged.
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
        ; unselected redraw is pixel-identical to the original (resets any bar colour).
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
        ; key hints in a centered footer on the bottom border, as ONE embedded-colour
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

    ; per-prompt history persistence (hist/<category>.his under the drive root) now lives in the
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

    sub toast(str m) {
        ; brief self-dismissing status (~1.5 s), no keypress.
        box_open()
        if ui_ok
            ui_toast(m)
        box_close()
    }

    ; ---- unified bottom dialog box (rows DIVBOT..SCR_BOT): white bg, black text, hotkeys
    ;      in light blue (same look as ask_overwrite). box_open blanks the four rows,
    ;      erasing the frame chars underneath; box_close restores them with draw_frame.
    sub box_open() {
        ubyte r
        for r in DIVBOT to SCR_BOT {         ; outer stays local; inner leaf loop uses g_ndx
            for g_ndx in 0 to 79 {
                txt.setchr(g_ndx, r, sc:' ')
                txt.setclr(g_ndx, r, shared.OW_BLACK)
            }
        }
        txt.color(shared.CLR_FG)
    }

    sub box_close() {
        draw_frame()                        ; restore the borders the box erased
    }

    sub box_left(ubyte row, str s) {
        ; print s left-aligned at BANNER_LEFT on row, then force that row black-on-white.
        ; the house style for every bottom-banner line (see BANNER_LEFT).
        txt.plot(BANNER_LEFT, row)
        txt.print(s)
        hilite_row(0, 79, row, shared.OW_BLACK)
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
        ; 1 = delete this, 0 = skip, 2 = delete this + all remaining, 255 = cancel rest
        box_open()
        ubyte r = 255
        if ui_ok
            r = ui_ask_delete_this(name)
        box_close()
        return r
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
            txt.setclr(g_ndx, MSGROW, shared.OW_BLACK)
        }
        txt.plot(fieldcol, MSGROW)
        ubyte width = 79 - fieldcol           ; cells available fieldcol..78
        ubyte shown = n
        if shown > width
            shown = width                     ; clamp so we never write past col 78
        if shown != 0
            for g_ndx in 0 to shown-1
                txt.chrout(@(destptr + g_ndx))
        hilite_row(fieldcol, 78, MSGROW, shared.OW_BLACK)   ; force the field black-on-white
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
        ; (blank_span resets any bar colour).
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
        ; hotkey footer on the bottom border with the keys picked out in the accent colour.
        const ubyte BIW = PICK_X1 - PICK_X0 - 1         ; box interior width
        if ui_ok {
            ui_draw_box(PICK_X0, PICK_Y0, PICK_X1, PICK_Y1)
            ui_box_header(PICK_X0, PICK_X1, PICK_Y0, " Pick a directory ")
        }
        ; footer (42 visible chars) as ONE embedded-colour string instead of 8 colour + 8
        ; print calls. In-string PETSCII codes: \x9e = shared.CLR_ACCENT (yellow), \x05 = shared.CLR_FG
        ; (white); ←┘ is the ENTER glyph. Ends white so the list rows below inherit shared.CLR_FG.
        txt.plot(PICK_X0 + 1 + (BIW - 42) / 2, PICK_Y1)
        txt.print(petscii:"\x9e >\x05Expand \x9e<\x05Collapse  \x9e←┘\x05Select  \x9eEsc\x05 Cancel ")
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
                txt.setclr(g_ndx, CMDROW2, shared.OW_KEY)
        if ll != 0
            for g_ndx in col + kl to col + kl + ll - 1
                txt.setclr(g_ndx, CMDROW2, shared.OW_BLACK)
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
        ; white 4-row box with the prompt label (black) on row 1 and the key hints on row 2
        box_open()
        txt.plot(BANNER_LEFT, MSGROW)
        txt.print(prompt)
        hilite_row(0, 79, MSGROW, shared.OW_BLACK)
        prompt_hint(usehist, dirpick)
    }

    sub input_line(str prompt, str dest, ubyte maxlen, str histname, bool dirpick) -> bool {
        ; a small line editor: Left/Right move, Home jumps to start, Backspace deletes
        ; the char to the left, printable keys insert at the cursor, Up recalls history,
        ; F2 (when dirpick) picks a directory from the tree, Enter accepts, Esc cancels.
        ; `histname` selects the history category file.
        bool usehist = misc_ok and strings.length(histname) != 0    ; no overlay / empty histname -> no history UI
        if usehist
            hist_count = hist_load(histname, &xtree.base_path)      ; banked ring; cache the returned count
        input_frame(prompt, usehist, dirpick)
        ubyte fieldcol = BANNER_LEFT + 1 + lsb(strings.length(prompt))     ; one space after the prompt label
        ubyte n = 0
        ubyte curpos = 0
        ubyte j
        dest[0] = 0
        edit_render(dest, n, curpos, fieldcol)
        repeat {
            g_key = wait_key()
            when g_key {
                13 -> {                      ; Enter -> accept (if non-empty)
                    dest[n] = 0
                    if n != 0 and usehist {
                        hist_count = hist_store(dest)
                        hist_save(histname, &xtree.base_path)
                    }
                    box_close()
                    return n != 0
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
                    ; Filenames are stored/written as ASCII. Fold a shifted letter
                    ; ($C1..$DA) down to $41..$5A so it's a valid ASCII char; otherwise
                    ; the raw >127 byte garbles the name on disk. Then accept any
                    ; printable ASCII ($20..$7E) and insert it at the cursor.
                    if g_key >= 193 and g_key <= 218
                        g_key -= $80
                    if n < maxlen and g_key >= 32 and g_key < 127 {
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
        ; a highlighted hotkey on the bar (dark-gray on blue), then revert to white-on-blue
        txt.color2(shared.BAR_KEY, shared.BAR_BG)
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

    sub file_is_bmx(uword nameptr) -> bool {
        ; True if the file's first 3 bytes are the BMX magic (raw content, so no filename-encoding
        ; ambiguity - the host-fs may return names as lowercase ASCII). On-disk magic is $42,$4D,$58
        ; (= petscii "bmx" = ascii "BMX"), matching bmx.p8's FILEID. Mirrors tview's zsm_detect.
        ; The caller must have chdir'd into the file's directory first.
        ubyte[3] magic
        magic[0] = 0
        magic[1] = 0
        magic[2] = 0
        if not diskio.f_open(nameptr)
            return false
        ubyte got = lsb(diskio.f_read(&magic, 3))
        diskio.f_close()
        return got >= 3 and magic[0]==$42 and magic[1]==$4d and magic[2]==$58
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
    ; (ui_show_about); show_about() below is just the thin wrapper. show_all stays here - it walks
    ; xfiles/xtree state the overlay can't reach.

    sub show_all() {
        ; full-screen modal: every tagged file across all logged directories
        const ubyte SA_TOP = 2
        const ubyte SA_VIS = 26             ; list rows 2..27
        xfiles.collect_tagged()
        ubyte top = 0
        ubyte cursor = 0
        txt.clear_screen()
        repeat {
            txt.color(shared.CLR_ACCENT)
            txt.plot(2, 0)
            txt.print("SHOWALL - tagged files: ")
            txt.print_uw(xfiles.sa_count)
            txt.print("    ")
            txt.color(shared.CLR_FG)
            ubyte row
            for row in 0 to SA_VIS-1 {
                ubyte srow = SA_TOP + row
                blank_span(0, 79, srow)
                ubyte i = top + row
                if i < xfiles.sa_count {
                    txt.plot(0, srow)
                    if i == cursor
                        txt.chrout('>')
                    else
                        txt.spc()
                    xtree.build_path(xfiles.sa_dir[i], sa_line)
                    xfiles.sa_name(i, namebuf)
                    ubyte sl = lsb(strings.length(sa_line))     ; append the filename with a cap
                    if sl < 99                                  ; so path+name can't overflow the
                        str_copy_cap(namebuf, &sa_line + sl, 99 - sl)  ; 100-byte sa_line buffer
                    print_trunc(sa_line, 70)
                    txt.plot(73, srow)
                    txt.print_uw(xfiles.sa_blocks(i))
                    if i == cursor
                        hilite_row(0, 78, srow, shared.HILITE)
                }
            }
            txt.plot(2, 29)
            txt.color(shared.CLR_ACCENT)
            txt.print("Up/Dn  U untag  C copy  M move  ESC/Q exit")
            txt.color(shared.CLR_FG)

            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3, 'q' -> return
                17 -> {                     ; down
                    if cursor + 1 < xfiles.sa_count {
                        cursor++
                        if cursor >= top + SA_VIS
                            top++
                    }
                }
                145 -> {                    ; up
                    if cursor != 0 {
                        cursor--
                        if cursor < top
                            top = cursor
                    }
                }
                'u' -> {                    ; untag highlighted entry, refresh list
                    if xfiles.sa_count != 0 {
                        xfiles.sa_untag(cursor)
                        xfiles.collect_tagged()
                        if xfiles.sa_count == 0
                            cursor = 0
                        else if cursor >= xfiles.sa_count
                            cursor = xfiles.sa_count - 1
                        if cursor < top
                            top = cursor
                    }
                }
                'c' -> {                    ; copy EVERY tagged file (across all dirs) to one dest
                    if xfiles.sa_count != 0 {
                        op_copymove_global(false)
                        xfiles.collect_tagged()
                        top = 0
                        if cursor >= xfiles.sa_count
                            cursor = 0
                        txt.clear_screen()  ; the copy prompt/banner drew over the modal
                    }
                }
                'm' -> {                    ; move EVERY tagged file (across all dirs) to one dest
                    if xfiles.sa_count != 0 {
                        op_copymove_global(true)
                        xfiles.collect_tagged()
                        top = 0
                        if cursor >= xfiles.sa_count
                            cursor = 0
                        txt.clear_screen()
                    }
                }
            }
        }
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
        if not input_line("Find (eg *.prg):", inputbuf, 31, "find", false)
            return
        if inputbuf[0] == 0
            return
        void strings.copy(inputbuf, find_lc)        ; lowercase a copy for nocase matching
        void strings.lower(find_lc)

        box_open()                                  ; "Searching..." over the bottom rows
        box_left(CMDROW1, "Searching...")

        ubyte partial = 0                           ; bit0=too deep  bit1=dir cap  bit2=result cap
        crawl_begin(&find_lc)
        while crawl_next_hit(&cm_dst) != 0 {        ; cm_dst (132 B) fits a full crawl path
            ubyte node = xscan.open_path(cm_dst)    ; log + expand ancestors, return deepest node
            void xscan.scan_dir(node)               ; log THIS dir's files (open_path only did ancestors)
            if xtree.dir_count >= xtree.DIR_MAX {
                partial |= 2                        ; 128-dir cap: stop logging further hits
                break
            }
        }
        if crawl_trunc() != 0
            partial |= 1                            ; some subtree skipped (path too long)
        box_close()

        xtree.rebuild_visible()
        xfiles.collect_matching(find_lc)
        if xfiles.sa_count >= xfiles.GLOBAL_MAX
            partial |= 4                            ; results capped at GLOBAL_MAX

        if xfiles.sa_count == 0 {
            if partial != 0
                flash("No matches (search was partial)")
            else
                flash("No matches")
            return
        }
        show_find_results(partial)
    }

    ; Find modal: viewer-style layout - reverse blue header (row 0) + footer (SCR_BOT) bars,
    ; white-on-gray list body (rows SA_TOP..SA_TOP+SA_VIS-1). The bars are painted ONCE on entry;
    ; the body redraws a whole page only when it scrolls, otherwise just the two rows the cursor
    ; left and landed on. sf_partial is stashed so the row helpers stay 2-arg on the hot path.
    const ubyte SF_TOP = 2
    const ubyte SF_VIS = 27                 ; list rows 2..28 (row 0 header bar, row 1 col headers, row 29 footer)
    ubyte sf_partial
    ubyte sf_top                            ; window top index; module-level so draw_find_row sees it

    sub draw_find_row(ubyte i, ubyte cursor) {
        ; paint the absolute-index entry i onto its screen row; caller keeps i within the visible
        ; window, so the row is SF_TOP + (i - sf_top). Highlights when i == cursor.
        ubyte srow = SF_TOP + (i - sf_top)
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)    ; white on gray body
        blank_span(0, 79, srow)
        if i < xfiles.sa_count {
            txt.plot(0, srow)
            if i == cursor
                txt.chrout('>')
            else
                txt.spc()
            xtree.build_path(xfiles.sa_dir[i], sa_line)
            xfiles.sa_name(i, namebuf)
            ubyte sl = lsb(strings.length(sa_line))     ; append the filename with a cap so
            if sl < 99                                  ; path+name can't overflow the 100-byte
                str_copy_cap(namebuf, &sa_line + sl, 99 - sl)  ; sa_line buffer
            print_trunc(sa_line, 70)
            txt.plot(73, srow)
            txt.print_uw(xfiles.sa_blocks(i))
            if i == cursor
                hilite_row(0, 78, srow, shared.HILITE)
        }
    }

    sub draw_find_page(ubyte cursor) {
        ubyte row
        for row in 0 to SF_VIS-1
            draw_find_row(sf_top + row, cursor)
    }

    sub show_find_results(ubyte partial) {
        ; full-screen modal listing the Find matches gathered in sa_* (path + name + blocks).
        ; Enter jumps to the highlighted file; ESC/Q exits.
        sf_partial = partial
        sf_top = 0
        ubyte cursor = 0
        ubyte oldc

        ; static frame (drawn once): blue header + footer bars, gray body
        txt.color2(shared.BAR_FG, shared.CONTENT_BG)
        txt.clear_screen()
        bar_fill(0)                                     ; header bar
        txt.plot(2, 0)
        txt.print("FIND matches: ")
        txt.print_uw(xfiles.sa_count)
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
        txt.print(" Go to file  ")
        bar_key("ESC")
        txt.print(" Exit")
        draw_find_page(cursor)

        repeat {
            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3, 'q' -> return
                13 -> {                     ; enter: jump to the highlighted match, close the modal
                    if xfiles.sa_count != 0
                        jump_to_result(cursor)
                    return
                }
                17 -> {                     ; down
                    if cursor + 1 < xfiles.sa_count {
                        oldc = cursor
                        cursor++
                        if cursor >= sf_top + SF_VIS {
                            sf_top++
                            draw_find_page(cursor)              ; scrolled: whole page
                        } else {
                            draw_find_row(oldc, cursor)        ; un-highlight the row we left
                            draw_find_row(cursor, cursor)      ; highlight the new row
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
                    if sf_top + SF_VIS < xfiles.sa_count {
                        sf_top += SF_VIS                     ; advance a whole page, cursor at its top
                        cursor = sf_top
                        draw_find_page(cursor)
                    } else if cursor + 1 != xfiles.sa_count {
                        cursor = xfiles.sa_count - 1         ; last page already shown: land on the end
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

    sub jump_to_result(ubyte i) {
        ; land the dual-pane view on the file at sa_ index i: expand every ancestor of its dir,
        ; put the tree cursor on the dir, filter the file pane to the search spec (so the match
        ; shows), and drop focus into the file pane on the matching row.
        ubyte dir = xfiles.sa_dir[i]
        xfiles.sa_name(i, namebuf)                   ; the matched filename
        ubyte a = xtree.d_parent[dir]
        while a != xtree.NONE {
            xtree.d_flags[a] |= xtree.FL_EXPANDED
            a = xtree.d_parent[a]
        }
        xtree.rebuild_visible()
        set_tree_cursor_to(dir)
        xfiles.set_spec(inputbuf)                    ; file pane shows the found set (draw clamps tops)
        select_dir(dir)                              ; build ft_ index with that spec (resets cursor/top)
        file_cursor = 0
        if xfiles.ft_count != 0 {
            for g_ndx in 0 to xfiles.ft_count-1 {
                xfiles.get_name(g_ndx, pathbuf)      ; pathbuf: name scratch (>= namebuf capacity)
                if strings.compare(pathbuf, namebuf) == 0 {
                    file_cursor = g_ndx
                    break
                }
            }
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
