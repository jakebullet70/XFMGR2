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
%import xviewer
%import hlprs
%import emudbg
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

    ; selection bar colors (high nibble = bg, low nibble = fg)
    ; (X16 default 16-color: 1=white 6=blue 7=yellow 11=dark gray 14=light blue 0=black)
    const ubyte COL_FG    = 1           ; body text: white
    const ubyte COL_BG    = 11          ; field: dark gray
    const ubyte COL_ACCENT = 7          ; hotkey letters: yellow
    const ubyte COL_TITLE  = 14         ; window / box titles: light blue (matches borders)
    const ubyte COL_BOX   = $be         ; frame / box borders: light blue on dark gray (bg nibble = COL_BG)
    const ubyte HILITE    = $e1         ; focused selection bar: light-blue bg, white text
    const ubyte COL_TAGROW = $e1        ; tagged file row: blue bg, white text

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
    ; (e.g. moving in the file column never touches the directory column)
    bool dirty_tree, dirty_files, dirty_status, dirty_cmd, dirty_full

    ubyte clk_h, clk_m, clk_s, clk_last     ; RTC wall clock shown in the title bar
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

    ; copy/move scratch: source & dest directory paths, and full file paths
    str cm_sdir = "?" * 80
    str cm_ddir = "?" * 80
    str cm_src  = "?" * 132
    str cm_dst  = "?" * 132

    ; shared text-input history (XTreeGold): the last HIST_N accepted entries,
    ; newest first. UP-arrow in any input pops up a scrollable picker.
    const ubyte HIST_N = 10
    const ubyte HIST_W = 50                 ; bytes per slot (<=49 chars + NUL)
    uword hist_buf = memory("inputhist", HIST_N * HIST_W, 0)
    ubyte hist_count                        ; 0..HIST_N, slot 0 = most recent
    str his_fname = "?" * 16                ; scratch: "<category>.his" (longest ~13 chars)

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
        txt.color2(COL_FG, COL_BG)               ; white text on a blue field
        txt.clear_screen()

        ; remember where we were launched from before any diskio call clobbers the
        ; shared buffer curdir() points into
        void strings.copy(diskio.curdir(), pathbuf)

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
                    draw_tree()
                if dirty_files
                    draw_files()
                if dirty_cmd
                    draw_commands()
            }
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
            ubyte k
            if xfiles.ft_count != 0
                for k in 0 to xfiles.ft_count-1
                    cur_blocks += xfiles.get_blocks(k)
        } else {
            xfiles.ft_count = 0
        }
    }

    sub set_tree_cursor_to(ubyte idx) {
        ubyte i
        for i in 0 to xtree.vis_count-1 {
            if xtree.vis_idx[i] == idx {
                tree_cursor = i
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
        ; full fixed-text confirmation: clear the menu area, ask, read Y/N
        msg_begin()
        txt.print(question)
        return yes_no()
    }

    sub confirm_quit() -> bool {
        return confirm("Quit XFMGR2?  (Y/N) ")
    }

    sub confirm_quit_here() -> bool {
        return confirm("Quit to this directory?  (Y/N) ")
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
            'c' -> {                        ; Ctrl-C: copy tagged files (global)
                op_copymove_global(false)
                dirty_full = true
            }
            'o' -> {                        ; Ctrl-O: move tagged files (global)
                                            ; (Ctrl-M is Enter/$0D, eaten by the kernal)
                op_copymove_global(true)
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
                    dirty_tree = true
                    dirty_files = true
                    dirty_status = true
                }
            }
            17 -> {                     ; down
                if tree_cursor + 1 < xtree.vis_count {
                    tree_cursor++
                    select_dir(xtree.vis_idx[tree_cursor])
                    dirty_tree = true
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
                    dirty_files = true
                }
            }
            17 -> {                     ; down
                if file_cursor + 1 < xfiles.ft_count {
                    file_cursor++
                    dirty_files = true
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
            'v' -> {
                xviewer.view_file()
                dirty_full = true               ; viewer used the whole screen
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
                op_copymove(false)
                dirty_tree = true               ; a copy can create a new dest folder in the tree
                dirty_files = true
                dirty_status = true
                dirty_cmd = true
            }
            'm' -> {
                op_copymove(true)
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
        txt.setclr(0, row, COL_BOX)
        ubyte col
        for col in 1 to 78 {
            if col == SPLIT
                txt.setchr(col, row, jc)
            else
                txt.setchr(col, row, SC_H)
            txt.setclr(col, row, COL_BOX)
        }
        txt.setchr(79, row, rc)
        txt.setclr(79, row, COL_BOX)
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
        txt.setclr(0, HDRROW, COL_BOX)
        txt.setclr(79, HDRROW, COL_BOX)
        txt.setclr(0, CMDROW1, COL_BOX)
        txt.setclr(79, CMDROW1, COL_BOX)
        txt.setclr(0, CMDROW2, COL_BOX)
        txt.setclr(79, CMDROW2, COL_BOX)
        ; side + middle borders down the content area
        ubyte r
        for r in PANE_TOP to PANE_BOT {
            txt.setchr(0, r, SC_V)
            txt.setchr(SPLIT, r, SC_V)
            txt.setchr(79, r, SC_V)
            txt.setclr(0, r, COL_BOX)
            txt.setclr(SPLIT, r, COL_BOX)
            txt.setclr(79, r, COL_BOX)
        }
        ; window titles embedded in the divider line
        txt.color(COL_TITLE)
        txt.plot(TREE_TEXT, 2)
        txt.print(" DIRECTORY ")
        txt.plot(FILE_TEXT, 2)
        txt.print(" FILE: ")
        print_trunc(xfiles.spec_lc, 14)
        txt.spc()
        ; program title + clock embedded in the top border
        txt.plot(2, 0)
        txt.print(" XFMGR2 ")
        txt.color(COL_FG)
        read_time()
        clk_last = clk_s
        paint_clock()
    }

    sub draw_status() {
        blank_span(1, 78, HDRROW)
        ; path on the left of the header row
        txt.plot(TREE_TEXT, HDRROW)
        txt.print("Path: ")
        xtree.build_path(cur_dir, pathbuf)
        print_trunc(pathbuf, 24)
        ; disk name, free space and tagged count on the right
        txt.plot(FILE_TEXT, HDRROW)
        txt.print("Disk ")
        print_trunc(xtree.name_ptr(0), 6)
        txt.print("  Free ")
        txt.print_uw(xscan.free_blocks)
        txt.print("  Tag ")
        txt.print_uw(xtree.dx_tag(cur_dir))
    }

    sub draw_tree() {
        if tree_cursor < tree_top
            tree_top = tree_cursor
        if tree_cursor >= tree_top + PANE_H
            tree_top = tree_cursor - PANE_H + 1

        ubyte row
        for row in 0 to PANE_H-1 {
            ubyte srow = PANE_TOP + row
            blank_span(TREE_MARK, TREE_BAR_R, srow)
            ubyte i = tree_top + row
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
                    hilite_row(TREE_MARK, TREE_BAR_R, srow, HILITE)
            }
        }
        ; scroll indicators
        if tree_top != 0
            txt.setchr(TREE_BAR_R, PANE_TOP, sc:'^')
        if tree_top + PANE_H < xtree.vis_count
            txt.setchr(TREE_BAR_R, PANE_BOT, sc:'v')
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
        ubyte k
        if depth >= 2 {
            for k in 1 to depth-1 {
                if levlast[k] != 0
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
        txt.color(COL_ACCENT)
        txt.plot(FILE_TEXT, FILE_HDR)
        txt.print("Name")
        txt.color(COL_FG)
        txt.print("  (")
        txt.print_uw(xfiles.ft_count)
        txt.print(" files, ")
        txt.print_uw(cur_blocks)
        txt.print(" blk)")
        txt.color(COL_ACCENT)
        txt.plot(FILE_SIZE, FILE_HDR)
        txt.print("Size")
        txt.color(COL_FG)
    }

    sub draw_files() {
        draw_file_header()

        if file_cursor < file_top
            file_top = file_cursor
        if file_cursor >= file_top + FILE_VIS
            file_top = file_cursor - FILE_VIS + 1

        ubyte row
        for row in 0 to FILE_VIS-1 {
            ubyte srow = FILE_TOP + row
            blank_span(FILE_MARK, FILE_BAR_R, srow)
            ubyte i = file_top + row
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
                    hilite_row(FILE_MARK, FILE_BAR_R, srow, HILITE)
            }
        }

        if xfiles.ft_count == 0 {
            txt.plot(FILE_TEXT, FILE_TOP)
            if xtree.d_flags[cur_dir] & xtree.FL_SCANNED == 0
                txt.print("(Enter to log)")
            else
                txt.print("(no files)")
        }
        ; scroll indicators
        if file_top != 0
            txt.setchr(FILE_BAR_R, FILE_TOP, sc:'^')
        if file_top + FILE_VIS < xfiles.ft_count
            txt.setchr(FILE_BAR_R, PANE_BOT, sc:'v')
    }

    sub hk(ubyte c) {
        ; print a hotkey letter highlighted in the accent colour (yellow)
        txt.color(COL_ACCENT)
        txt.chrout(c)
        txt.color(COL_FG)
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
        ; CTRL batch / global commands, styled like the MENU/ALT rows: the trigger
        ; letter is highlighted inline. Delete is shown as "<key> Del" because its
        ; CTRL key differs by environment (Ctrl-X emulator / Ctrl-D hardware).
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
        txt.color(COL_ACCENT)
        when menu_mode {
            1 -> {
                txt.print("CTRL: ")
                txt.color(COL_FG)
                menu_ctrl_items()
            }
            2 -> {
                txt.print("ALT:  ")
                txt.color(COL_FG)
                menu_alt_items()
            }
            else -> {
                txt.print("MENU: ")
                txt.color(COL_FG)
                menu_plain_items()
            }
        }
        blank_span(1, 78, CMDROW2)
        txt.plot(TREE_TEXT, CMDROW2)
        txt.color(COL_FG)
        if menu_mode == 0 {
            ; both panes expose CTRL/ALT commands (Alt-Q quit-here, Alt-F3 relog,
            ; Alt-R release, Alt-S sort...), so both show the same hint.
            ; current colour is COL_FG here, so "hold " needs no leading code
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
        msg_begin()
        txt.print("Delete ")
        txt.print(namebuf)
        txt.print("?  (Y/N) ")
        if yes_no() {
            xtree.build_path(cur_dir, pathbuf)
            diskio.chdir(pathbuf)
            diskio.delete(namebuf)
            xfiles.hide(file_cursor, cur_dir)       ; drop from the cached view
            void xfiles.build_index(cur_dir)
            clamp_file_cursor()
        }
    }

    sub op_delete_tagged() {
        if xtree.dx_tag(cur_dir) == 0 {
            flash("no tagged files")
            return
        }
        msg_begin()
        txt.print("Delete ")
        txt.print_uw(xtree.dx_tag(cur_dir))
        txt.print(" tagged files?  (Y/N) ")
        if yes_no() {
            xtree.build_path(cur_dir, pathbuf)
            diskio.chdir(pathbuf)
            ubyte i
            for i in 0 to xfiles.ft_count-1 {
                if xfiles.is_tagged(i) {
                    xfiles.get_name(i, namebuf)
                    diskio.delete(namebuf)
                    xfiles.hide(i, cur_dir)     ; clears its tag + marks deleted
                }
            }
            void xfiles.build_index(cur_dir)
            clamp_file_cursor()
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
        msg_begin()
        txt.print("pruning ")
        print_trunc(namebuf, 40)
        txt.print(" ...")
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
            flash("pruned")
        } else {
            flash("prune failed (partial) - rescan the dir")
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
        msg_begin()
        txt.print("Delete empty folder ")
        print_trunc(namebuf, 24)
        txt.print("?  (Y/N) ")
        if not yes_no()
            return
        ubyte parent = xtree.d_parent[idx]
        ubyte uprow = tree_cursor                           ; land one row up once it vanishes
        if uprow != 0
            uprow--
        xtree.build_path(parent, pathbuf)                   ; parent dir (absolute, trailing '/')
        diskio.chdir(pathbuf)
        diskio.rmdir(namebuf)
        if diskio.status_code() != 0 {
            flash("folder not empty - use Prune for a tree")
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
        flash("folder deleted")
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

    sub copy_one(str fname) -> bool {
        ; stream-copy cm_sdir+fname -> cm_ddir+fname (both absolute paths). Source is
        ; opened on the READ channel, dest on the WRITE channel (different logical
        ; files), so both can be open at once and we copy in 255-byte chunks.
        void strings.copy(cm_sdir, cm_src)
        void strings.append(cm_src, fname)
        void strings.copy(cm_ddir, cm_dst)
        void strings.append(cm_dst, fname)

        if not diskio.f_open(cm_src)
            return false
        if not diskio.f_open_w(cm_dst) {
            diskio.f_close()
            return false
        }
        bool ok = true
        repeat {
            uword n = diskio.f_read(&viewbuf, 255)
            if n == 0
                break
            if not diskio.f_write(&viewbuf, n) {
                ok = false
                break
            }
        }
        diskio.f_close()
        diskio.f_close_w()
        return ok
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
        ; mirroring op_mkdir - otherwise a freshly-created copy/move target never appears
        ubyte par = find_dir_by_path(pathbuf)
        if par != xtree.NONE and xtree.d_flags[par] & xtree.FL_SCANNED != 0 {
            void xtree.add_child(par, namebuf)
            xtree.d_flags[par] |= xtree.FL_EXPANDED
            xtree.rebuild_visible()
        }
    }

    sub ensure_dest_dir(str path) -> bool {
        ; make sure the copy/move destination exists; if not, offer to create it.
        ; returns false only if it is missing AND the user declines (caller then aborts).
        if dir_exists(path)
            return true
        msg_begin()
        txt.print("Dest dir missing. Create it?  (Y/N) ")
        if not yes_no()
            return false
        make_last_dir(path)
        return true
    }

    sub op_copymove(bool is_move) {
        if xfiles.ft_count == 0
            return
        ; working set: all tagged files if any, else just the highlighted file
        bool whole = xtree.dx_tag(cur_dir) != 0

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

        uword done = 0
        uword failed = 0
        ubyte i
        for i in 0 to xfiles.ft_count-1 {
            if whole and not xfiles.is_tagged(i)
                continue
            if not whole and i != file_cursor
                continue
            xfiles.get_name(i, namebuf)
            if copy_one(namebuf) {
                done++
                if is_move {
                    ; remove the source copy and drop it from the cached view
                    void strings.copy(cm_sdir, cm_src)
                    void strings.append(cm_src, namebuf)
                    diskio.delete(cm_src)
                    xfiles.hide(i, cur_dir)
                }
            } else {
                failed++
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

        banner_copymove(is_move, done, failed)
    }

    sub find_dir_by_path(str p) -> ubyte {
        ; locate the tree node whose absolute path equals p (both have trailing '/')
        ubyte d
        for d in 0 to xtree.dir_count-1 {
            xtree.build_path(d, cm_src)         ; cm_src as scratch
            if strings.compare(cm_src, p) == 0
                return d
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
        msg_begin()
        txt.print("Tagged ")
        txt.print_uw(cnt)
        txt.print(" file(s)  -- key --")
        txt.chrout($92)
        void wait_key()
    }

    sub refresh_all_scanned() {
        ; re-read every logged directory's files (used after a global move)
        ubyte d
        for d in 0 to xtree.dir_count-1 {
            if xtree.d_flags[d] & xtree.FL_SCANNED != 0
                void xscan.refresh_files(d)
        }
    }

    sub op_copymove_global(bool is_move) {
        ; Ctrl-C / Ctrl-M: copy or move EVERY tagged file (across all logged dirs) to a
        ; chosen destination. Each file is copied from its own source directory.
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

        uword done = 0
        uword failed = 0
        ubyte i
        for i in 0 to xfiles.sa_count-1 {
            xtree.build_path(xfiles.sa_dir[i], cm_sdir)     ; this file's source dir
            if strings.compare(cm_sdir, cm_ddir) == 0 {
                failed++                                     ; same dir: skip
                continue
            }
            xfiles.sa_name(i, namebuf)
            if copy_one(namebuf) {
                done++
                if is_move {
                    void strings.copy(cm_sdir, cm_src)
                    void strings.append(cm_src, namebuf)
                    diskio.delete(cm_src)
                }
            } else {
                failed++
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

        banner_copymove(is_move, done, failed)
    }

    sub op_sort() {
        ; Alt-S: cycle the file sort order (name -> ext -> size) and re-sort the pane
        xfiles.sort_mode++
        if xfiles.sort_mode > 2
            xfiles.sort_mode = 0
        void xfiles.build_index(cur_dir)
        clamp_file_cursor()
        ; brief 2-line centered banner so the new order is obvious even with 0/1 files
        banner_open()
        banner_line(CMDROW1, "Sort order:")
        when xfiles.sort_mode {
            1 -> banner_line(CMDROW2, "extension")
            2 -> banner_line(CMDROW2, "size")
            else -> banner_line(CMDROW2, "name")
        }
        sys.wait(45)                ; ~0.75s, then the menu repaints over it
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
            banner_open()
            banner_line(CMDROW1, "relogged folders")
            banner_num(CMDROW2, 5 + uw_digits(added))       ; "+<n> new"
            txt.print("+")
            txt.print_uw(added)
            txt.print(" new")
            txt.chrout($92)
            sys.wait(120)
            return
        } else {
            void xscan.refresh_files(cur_dir)
        }
        void xfiles.build_index(cur_dir)
        cur_blocks = 0
        ubyte k
        if xfiles.ft_count != 0
            for k in 0 to xfiles.ft_count-1
                cur_blocks += xfiles.get_blocks(k)
        clamp_file_cursor()
        banner_open()
        banner_line(CMDROW1, "relogged")
        banner_num(CMDROW2, 8 + uw_digits(xfiles.ft_count))     ; "<n> file(s)"
        txt.print_uw(xfiles.ft_count)
        txt.print(" file(s)")
        txt.chrout($92)
        sys.wait(90)               ; show the 2-line banner ~2 seconds, then auto-dismiss
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
            mkword((COL_BG << 4) | COL_FG, diskio.drivenumber),   ; normal: white on dark-gray (app theme), drive
            mkword(HILITE, HILITE))                        ; header / status: light-blue bar (app accent)
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
        msg_begin()
        txt.print("Run ")
        print_trunc(namebuf, 32)
        txt.print("?  exits XFMGR (Y/N) ")
        if yes_no() {
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

    sub hist_popup(uword destptr, ubyte maxlen) -> ubyte {
        ; modal picker of recent entries, shell-style: the NEWEST entry (slot 0) sits at
        ; the BOTTOM of the list, right above the prompt, and is selected by default;
        ; Up walks back into older entries. `sel` is a slot index (0 = newest). On Enter,
        ; copy the choice into destptr (capped at maxlen) and return its length; on Esc
        ; return 255 (no change).
        const ubyte PX0 = 12
        const ubyte PX1 = 67
        ubyte sel = 0
        ubyte c
        repeat {
            ubyte rows = hist_count
            ubyte boxtop = 25 - rows
            draw_box(PX0, boxtop, PX1, boxtop+rows+1, "")
            ; centered " Recent " title on the top border
            txt.plot(PX0 + 1 + (PX1 - PX0 - 1 - 8) / 2, boxtop)       ; " Recent " = 8 chars
            txt.color(COL_TITLE)
            txt.print(" Recent ")
            ; key hints in a centered footer on the bottom border, as ONE embedded-colour
            ; string (\x9e=accent, \x05=fg; ←┘=ENTER glyph). Visible length = 21.
            txt.plot(PX0 + 1 + (PX1 - PX0 - 1 - 21) / 2, boxtop+rows+1)
            txt.print(petscii:"\x9e ←┘\x05 Select  \x9eESC\x05 Exit ")
            ubyte p
            for p in 0 to rows-1 {
                ubyte slot = rows - 1 - p        ; oldest at top, newest at the bottom
                ubyte srow = boxtop + 1 + p
                txt.plot(PX0+2, srow)
                print_trunc(hist_ptr(slot), PX1-PX0-3)
                if slot == sel
                    hilite_row(PX0+1, PX1-1, srow, HILITE)
            }
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
                    if sel + 1 < rows
                        sel++
                }
                17 -> {                      ; down -> newer entry (lower slot)
                    if sel != 0
                        sel--
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

    sub msg_begin() {
        ; clear BOTH command rows' interiors (cols 1..78) so a prompt covers the whole
        ; menu area; the side borders (cols 0/79) stay. CMDROW2 is cleared first, in
        ; normal video; then CMDROW1 becomes a reverse-video prompt field.
        blank_span(1, 78, CMDROW2)
        txt.plot(1, MSGROW)
        txt.chrout($12)
        ubyte c
        for c in 1 to 78
            txt.spc()
        txt.plot(1, MSGROW)
        txt.chrout($12)
    }

    sub flash(str m) {
        msg_begin()
        txt.print(m)
        txt.print("  -- key --")
        txt.chrout($92)
        void wait_key()
    }

    ; ---- 2-line centered completion banner (used after relog / sort etc.) ----
    sub banner_open() {
        ; paint a 2-row reverse-video banner across BOTH command rows (cols 1..78),
        ; ready for centered text. The caller repaints the menu over it afterwards.
        ubyte r
        ubyte c
        for r in CMDROW1 to CMDROW2 {
            txt.plot(1, r)
            txt.chrout($12)                 ; reverse on
            for c in 1 to 78
                txt.spc()
        }
        txt.chrout($92)                     ; reverse off
    }

    sub banner_line(ubyte row, str s) {
        ; print a static string centered (reverse video) on a banner row
        ubyte slen = lsb(strings.length(s))
        txt.plot(1 + (78 - slen) / 2, row)
        txt.chrout($12)
        txt.print(s)
        txt.chrout($92)
    }

    sub banner_num(ubyte row, ubyte width) {
        ; centre a `width`-wide reverse-video field on `row` and turn reverse on; the
        ; caller then prints exactly `width` chars (incl. a number) and a closing $92.
        txt.plot(1 + (78 - width) / 2, row)
        txt.chrout($12)
    }

    sub uw_digits(uword v) -> ubyte {
        ; decimal digit count of v, for sizing a centered line that contains a number
        ubyte d = 1
        while v >= 10 {
            v /= 10
            d++
        }
        return d
    }

    sub banner_copymove(bool is_move, uword done, uword failed) {
        ; 2-line centered banner summarising a copy/move, auto-dismiss like the relog one
        banner_open()
        if failed == 0 {
            if is_move
                banner_line(CMDROW1, "Moved")
            else
                banner_line(CMDROW1, "Copied")
            banner_num(CMDROW2, 8 + uw_digits(done))        ; "<n> file(s)"
            txt.print_uw(done)
            txt.print(" file(s)")
            txt.chrout($92)
            sys.wait(120)
        } else {
            ubyte vl = 7                                     ; "Copied "
            if is_move
                vl = 6                                       ; "Moved "
            banner_num(CMDROW1, vl + uw_digits(done))
            if is_move
                txt.print("Moved ")
            else
                txt.print("Copied ")
            txt.print_uw(done)
            txt.chrout($92)
            banner_num(CMDROW2, 7 + uw_digits(failed))       ; "<n> failed"
            txt.print_uw(failed)
            txt.print(" failed")
            txt.chrout($92)
            sys.wait(200)                                     ; linger a little on problems
        }
    }

    sub edit_render(uword destptr, ubyte n, ubyte curpos, ubyte fieldcol) {
        ; repaint the editable field (fieldcol..78) and show a block cursor. The whole
        ; field is cleared and reprinted each keystroke, so inserts/deletes never leave
        ; stale characters behind.
        blank_span(fieldcol, 78, MSGROW)
        txt.color(COL_FG)
        txt.plot(fieldcol, MSGROW)
        ubyte width = 79 - fieldcol           ; cells available fieldcol..78
        ubyte shown = n
        if shown > width
            shown = width                     ; clamp so we never write past col 78
        ubyte e
        if shown != 0
            for e in 0 to shown-1
                txt.chrout(@(destptr + e))
        ubyte cc = fieldcol + curpos
        if cc > 78
            cc = 78
        txt.setclr(cc, MSGROW, HILITE)       ; block cursor on the current cell
    }

    sub pick_find(ubyte idx) -> ubyte {
        ; index of idx within the current visible tree (0 if not found)
        ubyte q
        if xtree.vis_count != 0
            for q in 0 to xtree.vis_count-1
                if xtree.vis_idx[q] == idx
                    return q
        return 0
    }

    sub pick_dir() -> ubyte {
        ; modal directory picker over the logged tree. Up/Down move, Right expands (and
        ; logs on demand), Left collapses, Enter selects the highlighted dir, Esc cancels.
        ; Returns the selected node index, or xtree.NONE if cancelled.
        const ubyte BX0 = 12
        const ubyte BX1 = 67
        const ubyte BY0 = 3
        const ubyte BY1 = 27
        const ubyte VIS = BY1 - BY0 - 1
        ubyte cur = 0
        ubyte top = 0
        ubyte idx
        ; draw the box chrome ONCE (outside the loop, so it never flickers on scroll): an
        ; empty-title box, then a CENTERED title on the top border and a CENTERED footer on
        ; the bottom border with the hotkeys picked out in the accent colour.
        const ubyte BIW = BX1 - BX0 - 1             ; box interior width
        draw_box(BX0, BY0, BX1, BY1, "")
        txt.plot(BX0 + 1 + (BIW - 18) / 2, BY0)     ; " pick a directory " = 18 chars
        txt.color(COL_TITLE)
        txt.print(" Pick a directory ")
        txt.color(COL_FG)
        ; footer (40 visible chars) as ONE embedded-colour string instead of 8 colour + 8
        ; print calls. In-string PETSCII codes: \x9e = COL_ACCENT (yellow), \x05 = COL_FG
        ; (white); ←┘ is the ENTER glyph. Ends white so the list rows below inherit COL_FG.
        txt.plot(BX0 + 1 + (BIW - 40) / 2, BY1)
        txt.print(petscii:"\x9e >\x05Expand \x9e<\x05Collapse  \x9e←┘\x05Select  \x9eEsc\x05 Exit ")
        repeat {
            ; repaint only the interior list rows (blank each first so longer prior names
            ; don't leave a tail behind when scrolling)
            ubyte row
            for row in 0 to VIS-1 {
                ubyte srow = BY0 + 1 + row
                blank_span(BX0+1, BX1-1, srow)
                ubyte i = top + row
                if i < xtree.vis_count {
                    idx = xtree.vis_idx[i]
                    txt.plot(BX0+2, srow)
                    ubyte d
                    if xtree.d_depth[idx] != 0
                        for d in 1 to xtree.d_depth[idx]
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
                        hilite_row(BX0+1, BX1-1, srow, HILITE)
                }
            }

            g_key = wait_key()
            when g_key {
                27, 3 -> return xtree.NONE
                13 -> return xtree.vis_idx[cur]
                17 -> {                     ; down
                    if cur + 1 < xtree.vis_count {
                        cur++
                        if cur >= top + VIS
                            top++
                    }
                }
                145 -> {                    ; up
                    if cur != 0 {
                        cur--
                        if cur < top
                            top = cur
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
                    }
                }
            }
        }
    }

    sub prompt_hint(bool usehist, bool dirpick) {
        ; key help on the second command row, shown under any text prompt. Each hint is one
        ; embedded-colour string (\x9e=accent \x05=fg; ↑=up-arrow, ←┘=ENTER glyph) instead of
        ; separate colour+print calls; every segment ends fg so the next starts clean.
        txt.plot(TREE_TEXT, CMDROW2)
        if usehist
            txt.print(petscii:"\x9e↑\x05=history  ")
        if dirpick
            txt.print(petscii:"\x9eF2\x05=dir tree  ")
        txt.print(petscii:"\x9e←┘\x05=OK  \x9eESC\x05=cancel")
    }

    sub input_line(str prompt, str dest, ubyte maxlen, str histname, bool dirpick) -> bool {
        ; a small line editor: Left/Right move, Home jumps to start, Backspace deletes
        ; the char to the left, printable keys insert at the cursor, Up recalls history,
        ; F2 (when dirpick) picks a directory from the tree, Enter accepts, Esc cancels.
        ; `histname` selects the history category file.
        bool usehist = strings.length(histname) != 0    ; empty histname -> no history UI
        if usehist
            hist_load(histname)
        hlprs.clear_section(1, CMDROW1, 78, 2, (COL_BG << 4) | COL_FG)
        txt.color(COL_ACCENT)
        txt.plot(1, MSGROW)
        txt.print(prompt)
        txt.color(COL_FG)
        prompt_hint(usehist, dirpick)
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
                    return n != 0
                }
                27, 3 -> return false         ; ESC / STOP -> cancel
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
                        hlprs.clear_section(1, CMDROW1, 78, 2, (COL_BG << 4) | COL_FG)
                        txt.color(COL_ACCENT)
                        txt.plot(1, MSGROW)
                        txt.print(prompt)
                        txt.color(COL_FG)
                        prompt_hint(usehist, dirpick)
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
                        hlprs.clear_section(1, CMDROW1, 78, 2, (COL_BG << 4) | COL_FG)
                        txt.color(COL_ACCENT)
                        txt.plot(1, MSGROW)
                        txt.print(prompt)
                        txt.color(COL_FG)
                        prompt_hint(usehist, dirpick)
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
        ubyte x
        for x in x0 to x1
            txt.setclr(x, row, color)
    }

    sub box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ; drop shadow one column right and one row below a box, for a raised 3D look.
        ; setclr blacks out the cells (fg+bg = 0) so the content under them reads as
        ; shadow; a later full_redraw restores everything.
        ubyte yy
        for yy in y0+1 to y1+1 {
            if x1 + 1 < 80
                txt.setclr(x1+1, yy, 0)
        }
        ubyte xx
        for xx in x0+1 to x1+1 {
            if y1 + 1 < 30 and xx < 80
                txt.setclr(xx, y1+1, 0)
        }
    }

    sub box_row(ubyte x0, ubyte x1, ubyte row) {
        ; one framed, empty interior row: side borders + blank middle (in COL_FG, which
        ; also resets any leftover selection-bar colour on the row)
        txt.color(COL_FG)
        txt.setchr(x0, row, SC_V)
        txt.setchr(x1, row, SC_V)
        blank_span(x0+1, x1-1, row)
        txt.setclr(x0, row, COL_BOX)
        txt.setclr(x1, row, COL_BOX)
    }

    sub draw_box(ubyte x0, ubyte y0, ubyte x1, ubyte y1, str title) {
        ; draw a framed, shadowed, titled popup window. Interior rows are cleared (via
        ; box_row) so the caller just prints content into them. An empty title draws none.
        txt.color(COL_FG)
        txt.setchr(x0, y0, SC_TL)
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        txt.setclr(x0, y0, COL_BOX)
        txt.setclr(x1, y0, COL_BOX)
        txt.setclr(x0, y1, COL_BOX)
        txt.setclr(x1, y1, COL_BOX)
        ubyte c
        for c in x0+1 to x1-1 {
            txt.setchr(c, y0, SC_H)
            txt.setchr(c, y1, SC_H)
            txt.setclr(c, y0, COL_BOX)
            txt.setclr(c, y1, COL_BOX)
        }
        ubyte y
        for y in y0+1 to y1-1
            box_row(x0, x1, y)
        box_shadow(x0, y0, x1, y1)
        if title[0] != 0 {
            txt.color(COL_TITLE)
            txt.plot(x0+2, y0)
            txt.print(title)
            txt.color(COL_FG)
        }
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
        ; like cmd_key() but also reports whether CTRL was held (key_ctrl) and ticks
        ; the wall clock while idle so it stays live.
        ubyte spin = 0
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
            spin++
            if spin == 0          ; ~every 256 polls, cheap throttle
                tick_clock()
        }
    }

    ; ---------- title-bar clock ----------

    sub read_time() {
        ; clock_get_date_time packs each word as (second-named << 8 | first-named):
        ; r1 dayhours -> hours=msb, day=lsb ; r2 minsecs -> secs=msb, mins=lsb
        cx16.r0, cx16.r1, cx16.r2, cx16.r3 = cx16.clock_get_date_time()
        clk_h = msb(cx16.r1)
        clk_m = lsb(cx16.r2)
        clk_s = msb(cx16.r2)
    }

    sub tick_clock() {
        read_time()
        if clk_s != clk_last {
            clk_last = clk_s
            paint_clock()
        }
    }

    sub paint_clock() {
        txt.color(COL_ACCENT)
        txt.plot(68, 0)
        txt.spc()
        put2(clk_h)
        txt.chrout(':')
        put2(clk_m)
        txt.chrout(':')
        put2(clk_s)
        txt.spc()
        txt.color(COL_FG)
    }

    sub put2(ubyte v) {
        txt.chrout('0' + v / 10)
        txt.chrout('0' + v % 10)
    }

    ; ---------- about overlay ----------

    const ubyte HX0 = 24
    const ubyte HX1 = 55
    const ubyte HY0 = 6
    const ubyte HY1 = 22

    sub aboutln(ubyte ln, str s) {
        txt.plot(HX0 + 2, HY0 + ln)
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
            txt.color(COL_ACCENT)
            txt.plot(2, 0)
            txt.print("SHOWALL - tagged files: ")
            txt.print_uw(xfiles.sa_count)
            txt.print("    ")
            txt.color(COL_FG)
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
                        hilite_row(0, 78, srow, HILITE)
                }
            }
            txt.plot(2, 29)
            txt.color(COL_ACCENT)
            txt.print("up/dn move   U untag   ESC/Q exit")
            txt.color(COL_FG)

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
            }
        }
    }

    sub show_about() {
        const ubyte BIW = HX1 - HX0 - 1             ; box interior width
        draw_box(HX0, HY0, HX1, HY1, "")
        txt.plot(HX0 + 1 + (BIW - 7) / 2, HY0)      ; centered " About " (7 chars) on top border
        txt.color(COL_TITLE)
        txt.print(" About ")
        txt.color(COL_FG)
        aboutln(2,  "X F M G R")
        aboutln(4,  "an XTree-style file manager")
        aboutln(5,  "for the Commander X16")
        aboutln(7,  "version 1.0.0")
        ; live banked-RAM usage: banks 1..high_bank are in use (bank 1 = dir-extras,
        ; 2..high_bank = file arena), of max_bank usable on this machine (63 on a 512 KB X16).
        txt.plot(HX0 + 2, HY0 + 9)
        txt.print("banked RAM: ")
        txt.print_ub(xarena.high_bank)
        txt.print(" of ")
        txt.print_ub(xarena.max_bank)
        txt.print(" banks")
        aboutln(12, "written in Prog8")
        aboutln(13, "(c)2026 sadLogic")
        txt.plot(HX0 + 1 + (BIW - 15) / 2, HY1-1)   ; centered " press any key " (15 chars)
        txt.color(COL_ACCENT)
        txt.print(" Press any key ")
        txt.color(COL_FG)
        void wait_key()
    }
}
