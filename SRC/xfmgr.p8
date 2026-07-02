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
%import diskio
%import strings
%import xarena
%import xtree
%import xfiles
%import xscan
%import hlprs
%import emudbg
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
    ; directory the host shell is left in on a normal quit: the startup dir for the
    ; main-menu Quit, or the currently selected dir for the ALT-menu Quit.
    str exit_dir = "?" * 80

    ; "delete tagged" CTRL key. The emulator swallows Ctrl-D ($04) before it reaches
    ; us, so under the emulator we bind delete to Ctrl-X; on real hardware Ctrl-D is
    ; free, so we use the classic XTree Ctrl-D there. Set once at startup.
    ubyte del_key                           ; lowercase dispatch key: 'x' (emu) or 'd' (hw)
    ubyte del_char                          ; uppercase display char: 'X' or 'D'

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
    ubyte[256] viewbuf                  ; file read buffer (viewer / copy / history load)

    ; shared "press any key" footer text (Prog8 has no const str; this str is never
    ; written). Reused by the About box and the 2-line completion banners.
    str PRESS_ANY_KEY = " Press any key "

    ; copy/move scratch: source & dest directory paths, and full file paths
    str cm_sdir = "?" * 80
    str cm_ddir = "?" * 80
    str cm_src  = "?" * 132
    str cm_dst  = "?" * 132
    ubyte cm_fail                           ; copy_one failure point: 0 ok/none, 1 src-open, 2 dst-open, 3 write
    ubyte cm_wstat                          ; DOS status code captured when a write fails (diagnostic)
    ubyte ow_mode                           ; overwrite policy for the current copy/move batch:
                                            ; 0 = ask on each conflict, 1 = overwrite all, 2 = skip all

    ; shared text-input history (XTreeGold): the last HIST_N accepted entries,
    ; newest first. UP-arrow in any input pops up a scrollable picker.
    const ubyte HIST_N = 10
    const ubyte HIST_W = 50                 ; bytes per slot (<=49 chars + NUL)
    uword hist_buf = memory("inputhist", HIST_N * HIST_W, 0)
    ubyte hist_count                        ; 0..HIST_N, slot 0 = most recent
    str his_fname = "?" * 16                ; scratch: "<category>.his" (longest ~13 chars)

    ; --- banked file viewer (tview) overlay ---
    ; tview.p8 is compiled as a %output library headerless blob (org $A000) and loaded into
    ; reserved HIRAM bank 2 (VIEW_BANK) at startup. extsub @bank wraps each call in JSRFAR,
    ; mapping the bank around it. $A000 = library init (jmp start); $A003 = view_file entry.
    const ubyte VIEW_BANK = 2
    extsub @bank 2 $A000 = tview_init()
    extsub @bank 2 $A003 = view_file(uword nameptr @R0)
    bool viewer_ok                          ; tview.bin loaded OK -> V uses the banked viewer

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
        cx16.set_screen_mode(SCREEN_MODE)        ; 80x30

        ; pick the "delete tagged" CTRL key for this environment
        if emudbg.is_emulator() {
            del_key  = 'x'
            del_char = 'X'
        } else {
            del_key  = 'd'
            del_char = 'D'
        }
        txt.lowercase()
        txt.color2(shared.CLR_FG, shared.CLR_BG)               ; white text on a blue field
        txt.clear_screen()

        ; remember where we were launched from before any diskio call clobbers the
        ; shared buffer curdir() points into
        void strings.copy(diskio.curdir(), pathbuf)

        ; load the tview viewer overlay into its reserved bank (VIEW_BANK) at $A000, from the
        ; launch dir (cwd, where run.bat stages tview.bin), then run its one-time library init.
        cx16.push_rambank(VIEW_BANK)
        viewer_ok = diskio.loadlib("tview.bin", $a000) != 0
        cx16.pop_rambank()
        if viewer_ok
            tview_init()                ; extsub @bank 2: clears the overlay's in-bank BSS ONCE

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
                        157  -> change_focus(FOCUS_TREE)           ; cursor-left
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
        if run_exit {
            ; hand off to BASIC: load + run the selected program via the dynamic keyboard
            diskio.chdir(pathbuf)               ; the selected file's directory
            chain_run(namebuf)
        } else {
            diskio.chdir(exit_dir)              ; leave the shell in the chosen directory
            txt.print("xfmgr done.\n")
        }
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

    sub yes_no() -> bool {
        ; reverse-video cursor, then read a command key: true on 'y'/'Y'. Shared tail of
        ; every confirmation prompt (the caller prints the question + "(Y/N) " first).
        txt.chrout($92)
        return cmd_key() == 'y'
    }

    sub confirm(str question) -> bool {
        ; full fixed-text confirmation as a centered white box (question + Y/N)
        return box_confirm(question)
    }

    sub confirm_quit() -> bool {
        return confirm("Quit XFMGR2?")
    }

    sub confirm_quit_here() -> bool {
        return confirm("Quit to this directory?")
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
            'v' -> {                            ; View: run the banked tview overlay
                if xfiles.ft_count != 0 {
                    if viewer_ok {
                        xfiles.get_name(file_cursor, namebuf)
                        xtree.build_path(cur_dir, pathbuf)
                        diskio.chdir(pathbuf)   ; so tview's f_open(namebuf) resolves
                        view_file(&namebuf)     ; extsub @bank 2: JSRFAR into the overlay; returns on Q/ESC
                        txt.color2(shared.CLR_FG, shared.CLR_BG)   ; viewer left the text colour blue; restore app theme
                                                     ; (full_redraw's blanks use the current colour)
                    } else {
                        op_edit()               ; overlay missing -> fall back to X16 Edit
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

    sub hk(ubyte c) {
        ; print a hotkey letter highlighted in the accent colour (yellow)
        txt.color(shared.CLR_ACCENT)
        txt.chrout(c)
        txt.color(shared.CLR_FG)
    }

    sub menu_plain_items() {
        ; the no-modifier commands, context-sensitive (tree vs file pane)
        if focus == FOCUS_TREE {
            ; embedded-colour string (\x9e=accent \x05=fg; ←┘=ENTER glyph) - see memory note
            txt.print(petscii:"\x9e←┘\x05log  m\x9eK\x05dir  \x9eR\x05ename  \x9eD\x05elete  \x9eTAB\x05 files")
            txt.plot(74, CMDROW1)       ; About pinned to the far right of row 1 (key: A)
            txt.print(petscii:"\x9eA\x05bout")
        } else {
            txt.print(petscii:"\x9eT\x05ag \x9eU\x05ntag \x9eV\x05iew \x9eE\x05dit \x9eC\x05opy \x9eM\x05ove \x9eF\x05ilespec \x9eR\x05ename \x9eD\x05elete")
        }
    }

    sub menu_ctrl_items() {
        ; CTRL batch / global commands, acting on the CURRENT directory's file index. Most
        ; only make sense in the file pane; the dir pane shows just Tag / Untag, which tag
        ; or untag every file in the highlighted directory (a no-op until it has been logged).
        ; The trigger letter is highlighted inline; Delete is shown as "<key> Del" because
        ; its CTRL key differs by environment (Ctrl-X emulator / Ctrl-D hardware).
        if focus == FOCUS_TREE {
            txt.print(petscii:"\x9eT\x05ag  \x9eU\x05ntag")
            return
        }
        ; one embedded-colour string; keys: T ag, U ntag, I nvert, G lobal(ShowAll),
        ; C opy, m O ve(Ctrl-O), W ildcard. Del stays a call (del_char is runtime-chosen).
        txt.print(petscii:"\x9eT\x05ag  \x9eU\x05ntag  \x9eI\x05nvert  \x9eG\x05lobal  \x9eC\x05opy  m\x9eO\x05ve  \x9eW\x05ildcard  ")
        hk(del_char)
        txt.print(" Del")               ; Ctrl-X (emu) / Ctrl-D (hw)
    }

    sub menu_alt_items() {
        ; ALT commands. eXecute + Sort are file-only, so the dir panel drops them and
        ; shows relog + prune + release (Quit-here sits at the far right of row 2 for both).
        if focus == FOCUS_TREE {
            txt.print(petscii:"\x9eF3\x05 relog  \x9eP\x05rune  \x9eR\x05elease")
        } else {
            txt.print(petscii:"e\x9eX\x05ecute  \x9eS\x05ort: ")
            when xfiles.sort_mode {
                1 -> txt.print("ext")
                2 -> txt.print("size")
                else -> txt.print("name")
            }
            txt.print(petscii:"\x9e  F3\x05 relog  \x9eR\x05elease")
        }
    }

    sub draw_commands() {
        ; Row 1 shows the active command menu, chosen by the held modifier:
        ;   MENU (none) / CTRL / ALT.  Row 2 is a hint about the modifiers.
        blank_span(1, 78, CMDROW1)
        txt.plot(TREE_TEXT, CMDROW1)
        txt.color(shared.CLR_ACCENT)
        when menu_mode {
            1 -> {
                txt.print("CTRL: ")
                txt.color(shared.CLR_FG)
                menu_ctrl_items()
            }
            2 -> {
                txt.print("ALT:  ")
                txt.color(shared.CLR_FG)
                menu_alt_items()
            }
            else -> {
                txt.print("MENU: ")
                txt.color(shared.CLR_FG)
                menu_plain_items()
            }
        }
        blank_span(1, 78, CMDROW2)
        txt.plot(TREE_TEXT, CMDROW2)
        txt.color(shared.CLR_FG)
        if menu_mode == 0 {
            ; both panes expose CTRL/ALT commands (Alt-Q quit-here, Alt-F3 relog,
            ; Alt-R release, Alt-S sort...), so both show the same hint.
            ; current colour is shared.CLR_FG here, so "hold " needs no leading code
            txt.print(petscii:"hold \x9eCTRL\x05 or \x9eALT\x05 for more commands")
        }
        ; Quit pinned to the far right of row 2 on every menu. In the ALT menu it is the
        ; "Quit-here" variant (Alt-Q quits to the CURRENT dir); elsewhere it's plain Quit.
        if menu_mode == 2 {
            txt.plot(70, CMDROW2)
            txt.print(petscii:"\x9eQ\x05uit-here")
        } else {
            txt.plot(75, CMDROW2)
            txt.print(petscii:"\x9eQ\x05uit")
        }
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
        if confirm(cm_dst) {
            xtree.build_path(cur_dir, pathbuf)
            diskio.chdir(pathbuf)
            diskio.delete(namebuf)
            xfiles.hide(file_cursor, cur_dir)       ; drop from the cached view
            void xfiles.build_index(cur_dir)
            clamp_file_cursor()
            if xfiles.ft_count == 0                 ; last file gone -> hop back to the dir pane
                change_focus(FOCUS_TREE)
        }
    }

    sub op_delete_tagged() {
        if xtree.dx_tag(cur_dir) == 0 {
            flash("no tagged files")
            return
        }
        void strings.copy("Delete ", cm_dst)
        box_append_uw(xtree.dx_tag(cur_dir))
        void strings.append(cm_dst, " tagged files?")
        if confirm(cm_dst) {
            xtree.build_path(cur_dir, pathbuf)
            diskio.chdir(pathbuf)
            for g_ndx in 0 to xfiles.ft_count-1 {
                if xfiles.is_tagged(g_ndx) {
                    xfiles.get_name(g_ndx, namebuf)
                    diskio.delete(namebuf)
                    xfiles.hide(g_ndx, cur_dir)     ; clears its tag + marks deleted
                }
            }
            void xfiles.build_index(cur_dir)
            clamp_file_cursor()
            if xfiles.ft_count == 0                 ; last file gone -> hop back to the dir pane
                change_focus(FOCUS_TREE)
        }
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
        ; xscan.prune does the disk work; on success we unlink the node from the tree.
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
        box_center(CMDROW1, cm_dst)
        bool ok = xscan.prune(pathbuf, namebuf)
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
            box_center(CMDROW1, "Prune OK")
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
        if not confirm(cm_dst)
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
        void strings.copy(xtree.name_ptr(idx), namebuf)     ; stable copy of the old name
        if not input_line("Rename dir to:", inputbuf, 49, "rename", false)
            return
        if strings.length(inputbuf) == 0
            return
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
        xtree.build_path(parent, pathbuf)                   ; parent dir (absolute, trailing '/')
        diskio.chdir(pathbuf)
        diskio.rename(namebuf, inputbuf)                    ; r:new=old on the renamed sub-dir
        xtree.rename_node(idx, inputbuf)                    ; keep the tree's name in sync
    }

    sub last_dot(str s) -> ubyte {
        ; index of the last '.' in s, or 255 if none
        ubyte i = lsb(strings.length(s))
        while i != 0 {
            i--
            if s[i] == '.'
                return i
        }
        return 255
    }

    sub merge_seg(str pat, ubyte ps, ubyte pe, str orig, ubyte os, ubyte oe, str out, ubyte outpos) -> ubyte {
        ; merge one filename segment: pattern pat[ps..pe) against orig[os..oe), writing
        ; into out from outpos. '*' copies the rest of the original segment, '?' copies
        ; one original char, any other char is literal (and consumes one original char).
        ubyte pi = ps
        ubyte oi = os
        while pi < pe {
            ubyte pc = pat[pi]
            if pc == '*' {
                while oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                return outpos                    ; '*' ends this segment
            } else if pc == '?' {
                if oi < oe {
                    out[outpos] = orig[oi]
                    outpos++
                    oi++
                }
                pi++
            } else {
                out[outpos] = pc
                outpos++
                if oi < oe
                    oi++
                pi++
            }
        }
        return outpos
    }

    sub wildcard_name(str orig, str pat, str out) {
        ; expand a DOS/XTree-style rename pattern (pat) against the original name (orig)
        ; into out, e.g. orig "test.dat" + pat "*.tmp" -> "test.tmp". Base and extension
        ; (split at the last '.') are merged independently.
        ubyte olen = lsb(strings.length(orig))
        ubyte plen = lsb(strings.length(pat))
        ubyte pd = last_dot(pat)
        ubyte pos
        if pd == 255 {
            ; no '.' in the pattern: treat the whole name as a single segment
            pos = merge_seg(pat, 0, plen, orig, 0, olen, out, 0)
        } else {
            ubyte obase_e = olen
            ubyte oext_s = olen
            ubyte od = last_dot(orig)
            if od != 255 {
                obase_e = od
                oext_s = od + 1
            }
            pos = merge_seg(pat, 0, pd, orig, 0, obase_e, out, 0)
            out[pos] = '.'
            pos++
            pos = merge_seg(pat, pd+1, plen, orig, oext_s, olen, out, pos)
        }
        out[pos] = 0
    }

    sub op_rename() {
        if xfiles.ft_count == 0
            return
        xfiles.get_name(file_cursor, namebuf)       ; old name
        if not input_line("Rename to (* ? ok):", inputbuf, 49, "rename", false)
            return
        ; if the typed name uses wildcards, merge them with the old name in place
        if strings.contains(inputbuf, '*') or strings.contains(inputbuf, '?') {
            wildcard_name(namebuf, inputbuf, cm_dst)
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
        ; 4-row white dialog box (rows DIVBOT..SCR_BOT) shown on a name conflict. Text is
        ; black on white with the Y/N/A/S keys in light blue; the box chars underneath are
        ; erased and restored by draw_frame() after the batch. Returns the folded key:
        ; 'y' overwrite this, 'n' skip this, 'a' overwrite all, 's' skip all remaining.
        box_compose_name("Overwrite ", fname, "?")
        box_open()
        box_center(CMDROW1, cm_dst)
        const ubyte KW = 30                      ; "Y=yes  N=no  A=all  S=skip all" width
        ubyte kstart = (80 - KW) / 2
        box_center(CMDROW2, "Y=yes  N=no  A=all  S=skip all")
        box_key(kstart,      CMDROW2)            ; Y
        box_key(kstart + 7,  CMDROW2)            ; N
        box_key(kstart + 13, CMDROW2)            ; A
        box_key(kstart + 20, CMDROW2)            ; S
        ; no box_close here: the copy loop keeps running, and the "Copying..." / result box
        ; that follows redraws over this one (a box_close now would flash the 2-line frame)
        return cmd_key()
    }

    sub copy_one(str fname) -> ubyte {
        ; stream-copy cm_sdir+fname (absolute source, READ channel) into fname in the
        ; CURRENT directory (WRITE channel). The caller has chdir'd into the dest dir, so
        ; the dest is opened by BARE NAME: hostfs lands writes in the current dir, and an
        ; absolute write path is the case that fails to resolve. The two channels are
        ; different logical files, so both stay open while we copy in 255-byte chunks.
        ; Returns 0 = failed (cm_fail set), 1 = copied, 2 = skipped (target exists, not
        ; overwritten). Honours the batch overwrite policy ow_mode (0 ask / 1 all / 2 skip).
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

        diskio.delete(fname)                     ; allow overwrite: CBM-DOS/hostfs won't truncate
                                                 ; an existing file on open, so clear this name in
                                                 ; the dest dir first (no-op when it isn't there)
        if not diskio.f_open(cm_src) {
            cm_fail = 1                          ; source file wouldn't open
            return 0
        }
        if not diskio.f_open_w(fname) {
            diskio.f_close()
            cm_fail = 2                          ; dest wouldn't open (missing dir / name clash?)
            cm_wstat = diskio.status_code()      ; grab the DOS code for the diagnostic
            return 0
        }
        bool ok = true
        repeat {
            uword n = diskio.f_read(&viewbuf, 255)
            if n == 0
                break
            if not diskio.f_write(&viewbuf, n) {
                cm_fail = 3                       ; write failed
                cm_wstat = diskio.status_code()   ; grab the DOS error code for the diagnostic
                ok = false
                break
            }
        }
        diskio.f_close()
        diskio.f_close_w()
        if ok
            return 1
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
        if not confirm("Dest dir missing. Create it?")
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
            box_center(CMDROW1, "Moving...")
        else
            box_center(CMDROW1, "Copying...")
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
        ; set the file-display wildcard (e.g. *.prg). Enter empty/* shows all files.
        if not input_line("File spec (eg *.prg, * = all):", inputbuf, 31, "filespec", false)
            return
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
        box_center(CMDROW1, cm_dst)
        box_center(CMDROW2, PRESS_ANY_KEY)
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
            box_center(CMDROW1, "Moving...")
        else
            box_center(CMDROW1, "Copying...")
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
        box_center(CMDROW1, "Sort order:")
        when xfiles.sort_mode {
            1 -> box_center(CMDROW2, "extension")
            2 -> box_center(CMDROW2, "size")
            else -> box_center(CMDROW2, "name")
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
            box_center(CMDROW1, "relogged folders")
            void strings.copy("+", cm_dst)
            box_append_uw(added)
            void strings.append(cm_dst, " new")
            box_center(CMDROW2, cm_dst)
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
        box_center(CMDROW1, "relogged")
        cm_dst[0] = 0
        box_append_uw(xfiles.ft_count)
        void strings.append(cm_dst, " file(s)")
        box_center(CMDROW2, cm_dst)
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
            flash("no free RAM banks for editor")
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

    sub op_execute() {
        ; Alt-X: run the selected program. The X16 can't return to XFMGR afterwards
        ; (loading the program overwrites us), so we confirm, then quit to BASIC with a
        ; LOAD + RUN queued in the keyboard buffer. The main loop sees run_exit and breaks.
        if xfiles.ft_count == 0
            return
        xfiles.get_name(file_cursor, namebuf)
        box_compose_name("Run ", namebuf, "? exits XFMGR")
        if confirm(cm_dst) {
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
        txt.print("running ")
        txt.print(name)
        txt.print("...")
        txt.nl()                            ; row 2
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

    ; ---------- shared input history ----------

    sub hist_ptr(ubyte k) -> uword {
        uword off = k                       ; widen before the multiply (k*50 > 255)
        off *= HIST_W
        return hist_buf + off
    }

    sub hist_store(uword sptr) {
        ; insert the string at sptr as the newest entry (slot 0), de-duplicating and
        ; capping at HIST_N. Empty strings are ignored.
        if @(sptr) == 0
            return
        ; if it's already present, drop that older copy (so it moves to the front)
        ubyte i
        if hist_count != 0 {
            for i in 0 to hist_count-1 {
                if strings.compare(hist_ptr(i), sptr) == 0 {
                    while i + 1 < hist_count {
                        void strings.copy(hist_ptr(i+1), hist_ptr(i))
                        i++
                    }
                    hist_count--
                    break
                }
            }
        }
        ; shift everything down one slot to free slot 0 (oldest falls off if full)
        ubyte top = hist_count
        if top >= HIST_N
            top = HIST_N - 1
        while top != 0 {
            void strings.copy(hist_ptr(top-1), hist_ptr(top))
            top--
        }
        str_copy_cap(sptr, hist_ptr(0), HIST_W - 1)  ; cap: prompts accept up to 79 chars,
                                                     ; a slot is only HIST_W (50) bytes wide
        if hist_count < HIST_N
            hist_count++
    }

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
        draw_box(HIST_PX0, boxtop, HIST_PX1, boxtop+rows+2, "")
        box_header(HIST_PX0, HIST_PX1, boxtop, " Recent ")
        ; key hints in a centered footer on the bottom border, as ONE embedded-colour
        ; string (\x9e=accent, \x05=fg; ←┘=ENTER glyph). Visible length = 21.
        txt.plot(HIST_PX0 + 1 + (HIST_PX1 - HIST_PX0 - 1 - 21) / 2, boxtop+rows+2)
        txt.print(petscii:"\x9e ←┘\x05 Select  \x9eESC\x05 Exit ")
        ubyte p
        for p in 0 to rows-1 {
            ubyte slot = rows - 1 - p        ; oldest at top, newest at the bottom
            hist_draw_row(boxtop+2+p, hist_ptr(slot), slot == sel)
        }
        repeat {
            g_key = wait_key()
            if g_key >= $c1 and g_key <= $da
                g_key -= $80
            when g_key {
                27, 3 -> return 255          ; ESC / STOP: cancel
                13 -> {                      ; Enter: take the selected entry
                    uword sp = hist_ptr(sel)
                    ubyte j = 0
                    repeat {
                        c = @(sp + j)
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
                        hist_draw_row(boxtop+rows+1-sel, hist_ptr(sel), false)
                        sel++
                        hist_draw_row(boxtop+rows+1-sel, hist_ptr(sel), true)
                    }
                }
                17 -> {                      ; down -> newer entry (lower slot)
                    if sel != 0 {
                        hist_draw_row(boxtop+rows+1-sel, hist_ptr(sel), false)
                        sel--
                        hist_draw_row(boxtop+rows+1-sel, hist_ptr(sel), true)
                    }
                }
            }
        }
    }

    ; ---------- per-prompt history persistence (hist/<category>.his) ----------
    ; Each kind of text prompt (copy, move, rename, mkdir, filespec, ...) keeps its own
    ; history file under a "hist" directory at the drive root. The in-memory ring holds
    ; whichever category's prompt is currently open: hist_load() fills it when a prompt
    ; opens, hist_save() writes it back when an entry is accepted.

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

    sub his_set_fname(str cat) {
        ; build "<cat>.his" into his_fname
        void strings.copy(cat, his_fname)
        void strings.append(his_fname, ".his")
    }

    sub hist_enter_hist() {
        ; make the cwd be <root>/hist, creating hist/ on first use
        diskio.chdir(xtree.base_path)
        diskio.mkdir("hist")                ; harmless if it already exists
        diskio.chdir("hist")
    }

    sub hist_save(str cat) {
        ; write the ring (newest first, one entry per line) to hist/<cat>.his
        his_set_fname(cat)
        hist_enter_hist()
        diskio.delete(his_fname)            ; replace any previous file cleanly
        if diskio.f_open_w(his_fname) {
            ubyte nl = 13
            if hist_count != 0 {
                ubyte i
                for i in 0 to hist_count-1 {
                    uword p = hist_ptr(i)
                    void diskio.f_write(p, strings.length(p))
                    void diskio.f_write(&nl, 1)
                }
            }
            diskio.f_close_w()
        }
        diskio.chdir(xtree.base_path)        ; restore cwd for the next operation
    }

    sub hist_load(str cat) {
        ; load hist/<cat>.his into the ring (silently empty if hist/ or file absent)
        his_set_fname(cat)
        hist_count = 0
        diskio.chdir(xtree.base_path)
        diskio.chdir("hist")                 ; if missing, cwd just stays at root
        if diskio.f_open(his_fname) {
            repeat {
                ubyte ln
                ubyte st
                ln, st = diskio.f_readline(&viewbuf)
                if ln == 0
                    break                       ; blank line or EOF: stop
                str_copy_cap(&viewbuf, hist_ptr(hist_count), HIST_W - 1)
                hist_count++
                if st != 0 or hist_count >= HIST_N
                    break
            }
            diskio.f_close()
        }
        diskio.chdir(xtree.base_path)        ; restore cwd
    }

    ; ---------- bottom-line prompts ----------

    sub flash(str m) {
        box_open()
        box_center(CMDROW1, m)
        box_center(CMDROW2, PRESS_ANY_KEY)
        void wait_key()
        box_close()
    }

    sub toast(str m) {
        ; brief self-dismissing status: message only (no "press any key"), auto-closes
        ; after ~1.5 s (90 jiffies at 60 Hz). For confirmations that need no acknowledgement.
        box_open()
        box_center(CMDROW1, m)
        sys.wait(90)
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

    sub box_center(ubyte row, str s) {
        ; print s centered on row, then force that row black-on-white
        txt.plot((80 - lsb(strings.length(s))) / 2, row)
        txt.print(s)
        hilite_row(0, 79, row, shared.OW_BLACK)
    }

    sub box_key(ubyte col, ubyte row) {
        txt.setclr(col, row, shared.OW_KEY)        ; recolour one hotkey cell light blue
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

    sub box_confirm(str question) -> bool {
        ; centered Y/N dialog: question on row 1, "(Y/N)" with keys light blue on row 2
        box_open()
        box_center(CMDROW1, question)
        box_center(CMDROW2, "(Y/N)")
        ubyte c = (80 - 5) / 2
        box_key(c + 1, CMDROW2)             ; Y
        box_key(c + 3, CMDROW2)             ; N
        bool r = yes_no()
        box_close()
        return r
    }

    sub banner_copymove(bool is_move, uword done, uword failed, uword skipped) {
        ; 4-row white box summarising a copy/move, auto-dismiss like the relog one.
        ; Line 1: "<Copied|Moved> N file(s)".  Line 2: failed / skipped counts, if any.
        box_open()
        if is_move
            void strings.copy("Moved ", cm_dst)
        else
            void strings.copy("Copied ", cm_dst)
        box_append_uw(done)
        void strings.append(cm_dst, " file(s)")
        box_center(CMDROW1, cm_dst)
        if failed == 0 and skipped == 0 {
            sys.wait(120)
            box_close()
            return
        }
        cm_dst[0] = 0
        box_append_uw(failed)
        void strings.append(cm_dst, " failed  ")
        box_append_uw(skipped)
        void strings.append(cm_dst, " skipped")
        box_center(CMDROW2, cm_dst)
        sys.wait(200)                                        ; linger a little on problems
        box_close()
    }

    sub copy_diag() {
        ; shown when a copy/move produced 0 files: a boxed "Nothing copied" plus the cause.
        void strings.copy("Nothing copied", cm_dst)
        when cm_fail {
            1 -> void strings.append(cm_dst, " - source open failed")
            2 -> void strings.append(cm_dst, " - dest open failed")
            3 -> {
                void strings.append(cm_dst, " - write error ")
                box_append_uw(cm_wstat)
            }
            else -> void strings.append(cm_dst, " - nothing selected")
        }
        box_open()
        box_center(CMDROW1, cm_dst)
        box_center(CMDROW2, PRESS_ANY_KEY)
        void wait_key()
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
        ; draw one visible list row (0..PICK_VIS-1): indent by depth, +/- marker, name, and
        ; a selection bar if it is the cursor entry. Same draw path as the full repaint, so
        ; a non-cursor redraw exactly restores the base row (blank_span resets any bar colour).
        ubyte srow = PICK_Y0 + 2 + row
        txt.color(shared.CLR_FG)
        blank_span(PICK_X0+1, PICK_X1-1, srow)
        ubyte i = top + row
        if i < xtree.vis_count {
            ubyte idx = xtree.vis_idx[i]
            txt.plot(PICK_X0+2, srow)
            if xtree.d_depth[idx] != 0
                for g_ndx in 1 to xtree.d_depth[idx]
                    txt.print("  ")
            if xtree.has_kids(idx) {
                if xtree.is_expanded(idx)
                    txt.chrout('-')
                else
                    txt.chrout('+')
            } else {
                txt.spc()
            }
            txt.spc()
            print_trunc(xtree.name_ptr(idx), 40)
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
        draw_box(PICK_X0, PICK_Y0, PICK_X1, PICK_Y1, "")
        box_header(PICK_X0, PICK_X1, PICK_Y0, " Pick a directory ")
        ; footer (40 visible chars) as ONE embedded-colour string instead of 8 colour + 8
        ; print calls. In-string PETSCII codes: \x9e = shared.CLR_ACCENT (yellow), \x05 = shared.CLR_FG
        ; (white); ←┘ is the ENTER glyph. Ends white so the list rows below inherit shared.CLR_FG.
        txt.plot(PICK_X0 + 1 + (BIW - 40) / 2, PICK_Y1)
        txt.print(petscii:"\x9e >\x05Expand \x9e<\x05Collapse  \x9e←┘\x05Select  \x9eEsc\x05 Exit ")
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
                29 -> {                     ; right: expand (log on demand)
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
                157 -> {                    ; left: collapse
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
        ubyte col = TREE_TEXT
        if usehist
            col = hint_key(col, petscii:"↑", "=history  ")
        if dirpick
            col = hint_key(col, "F2", "=dir tree  ")
        col = hint_key(col, petscii:"←┘", "=OK  ")
        col = hint_key(col, "ESC", "=cancel")
    }

    sub input_frame(str prompt, bool usehist, bool dirpick) {
        ; white 4-row box with the prompt label (black) on row 1 and the key hints on row 2
        box_open()
        txt.plot(1, MSGROW)
        txt.print(prompt)
        hilite_row(0, 79, MSGROW, shared.OW_BLACK)
        prompt_hint(usehist, dirpick)
    }

    sub input_line(str prompt, str dest, ubyte maxlen, str histname, bool dirpick) -> bool {
        ; a small line editor: Left/Right move, Home jumps to start, Backspace deletes
        ; the char to the left, printable keys insert at the cursor, Up recalls history,
        ; F2 (when dirpick) picks a directory from the tree, Enter accepts, Esc cancels.
        ; `histname` selects the history category file.
        bool usehist = strings.length(histname) != 0    ; empty histname -> no history UI
        if usehist
            hist_load(histname)
        input_frame(prompt, usehist, dirpick)
        ubyte fieldcol = 2 + lsb(strings.length(prompt))
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
                        hist_store(dest)
                        hist_save(histname)
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

    sub box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ; drop shadow one column right and one row below a box, for a raised 3D look.
        ; setclr blacks out the cells (fg+bg = 0) so the content under them reads as
        ; shadow; a later full_redraw restores everything.
        for g_ndx in y0+1 to y1+1 {
            if x1 + 1 < 80
                txt.setclr(x1+1, g_ndx, 0)
        }
        for g_ndx in x0+1 to x1+1 {
            if y1 + 1 < 30 and g_ndx < 80
                txt.setclr(g_ndx, y1+1, 0)
        }
    }

    sub box_row(ubyte x0, ubyte x1, ubyte row) {
        ; one framed, empty interior row: side borders + blank middle (in shared.CLR_FG, which
        ; also resets any leftover selection-bar colour on the row)
        txt.color(shared.CLR_FG)
        txt.setchr(x0, row, SC_V)
        txt.setchr(x1, row, SC_V)
        blank_span(x0+1, x1-1, row)
        txt.setclr(x0, row, shared.CLR_BOX)
        txt.setclr(x1, row, shared.CLR_BOX)
    }

    sub draw_box(ubyte x0, ubyte y0, ubyte x1, ubyte y1, str title) {
        ; draw a framed, shadowed, titled popup window. Interior rows are cleared (via
        ; box_row) so the caller just prints content into them. An empty title draws none.
        txt.color(shared.CLR_FG)
        txt.setchr(x0, y0, SC_TL)
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        txt.setclr(x0, y0, shared.CLR_BOX)
        txt.setclr(x1, y0, shared.CLR_BOX)
        txt.setclr(x0, y1, shared.CLR_BOX)
        txt.setclr(x1, y1, shared.CLR_BOX)
        for g_ndx in x0+1 to x1-1 {
            txt.setchr(g_ndx, y0, SC_H)
            txt.setchr(g_ndx, y1, SC_H)
            txt.setclr(g_ndx, y0, shared.CLR_BOX)
            txt.setclr(g_ndx, y1, shared.CLR_BOX)
        }
        for g_ndx in y0+1 to y1-1            ; box_row uses a LOCAL counter, so g_ndx survives
            box_row(x0, x1, g_ndx)
        box_shadow(x0, y0, x1, y1)
        if title[0] != 0 {
            txt.color(shared.CLR_TITLE)
            txt.plot(x0+2, y0)
            txt.print(title)
            txt.color(shared.CLR_FG)
        }
    }

    sub box_header(ubyte x0, ubyte x1, ubyte y0, str title) {
        ; solid blue title bar spanning the full top border (between the corners), with the
        ; title centered in white. Blank the border line to spaces, print the title, then
        ; recolour the whole span to white-on-blue ($e1 = bg 14 / fg 1, same as shared.HILITE).
        for g_ndx in x0+1 to x1-1
            txt.setchr(g_ndx, y0, sc:' ')
        ubyte tlen = lsb(strings.length(title))
        txt.plot(x0 + 1 + (x1 - x0 - 1 - tlen) / 2, y0)
        txt.print(title)
        for g_ndx in x0+1 to x1-1
            txt.setclr(g_ndx, y0, $e1)
        txt.color(shared.CLR_FG)               ; body text below prints white again
    }

    sub print_trunc(str s, ubyte maxlen) {
        ubyte i = 0
        while i < maxlen and s[i] != 0 {
            txt.chrout(s[i])
            i++
        }
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

    ; screen rectangle of the About box (columns/rows), shared by the two subs
    ; below: aboutln() (positions each text line) and show_about() (draws the box).
    const ubyte ABOUT_LEFT   = 19
    const ubyte ABOUT_RIGHT  = 60
    const ubyte ABOUT_TOP    = 6
    const ubyte ABOUT_BOTTOM = 20

    sub about_col(ubyte slen) -> ubyte {
        ; leftmost column that horizontally centers a `slen`-char string in the box interior
        return ABOUT_LEFT + 1 + (ABOUT_RIGHT - ABOUT_LEFT - 1 - slen) / 2
    }

    sub about_digits(ubyte n) -> ubyte {
        ; how many characters txt.print_ub will emit for n (used to center a line with a number in it)
        if n >= 100
            return 3
        if n >= 10
            return 2
        return 1
    }

    sub aboutln(ubyte ln, str s) {
        txt.plot(about_col(lsb(strings.length(s))), ABOUT_TOP + ln)
        txt.print(s)
    }

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
            txt.print("up/dn  U untag  C copy  M move  ESC/Q exit")
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

    sub show_about() {
        draw_box(ABOUT_LEFT, ABOUT_TOP, ABOUT_RIGHT, ABOUT_BOTTOM, "")
        box_header(ABOUT_LEFT, ABOUT_RIGHT, ABOUT_TOP, " About ")
        aboutln(2,  "X F M G R")
        aboutln(4,  "An XTree-style file manager")
        aboutln(5,  "for the Commander X16")
        aboutln(7,  "Version 1.0.0")
        ; live banked-RAM usage: banks 1..high_bank are in use (bank 1 = dir-extras,
        ; 2..high_bank = file arena), of max_bank usable on this machine (63 on a 512 KB X16).
        ; length = "Banked RAM: "(12) + digits + " of "(4) + digits + " banks"(6) = 22 + digits
        txt.plot(about_col(22 + about_digits(xarena.high_bank) + about_digits(xarena.max_bank)), ABOUT_TOP + 9)
        txt.print("Banked RAM: ")
        txt.print_ub(xarena.high_bank)
        txt.print(" of ")
        txt.print_ub(xarena.max_bank)
        txt.print(" banks")
        aboutln(10, "Written in Prog8")
        aboutln(11, "(c)2025-26 sadLogic")
        txt.plot(about_col(lsb(strings.length(PRESS_ANY_KEY))), ABOUT_BOTTOM-1)   ; centered "Press any key"
        txt.color(shared.CLR_ACCENT)
        txt.print(PRESS_ANY_KEY)
        txt.color(shared.CLR_FG)
        void wait_key()
    }
}
