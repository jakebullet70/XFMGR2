; uiutil - bottom-banner dialog widgets, run from a HIRAM bank overlay (bank 4 = UI_BANK).
;
; Compiled as a %output library headerless blob (org $A000), loaded into reserved HIRAM bank 4
; at startup via diskio.loadlib, and called from XFMGR via `extsub @bank 4`. Moving the (cold,
; user-triggered) confirm / banner / prompt DRAWING here frees scarce main RAM; XFMGR keeps the
; frame plumbing (box_open/box_close -> draw_frame) and thin wrappers that open the box, JSRFAR
; into one of these to draw + interact, then close.
;
; Contract: the caller has ALREADY box_open'd (blanked rows DIVBOT..SCR_BOT to white); each entry
; below draws its content into that box and, for the interactive ones, loops reading keys and
; returns the choice. It does NOT restore the frame - the caller box_close's on return (except
; ui_ask_overwrite, whose box the copy loop redraws over). Message pointers (flash/ask_yn/...)
; point into main RAM, which stays mapped below $A000 while this bank is active.
;
; Fixed entry offsets via %jmptable: $A000 = init, $A003 = ui_flash, $A006 = ui_toast,
; $A009 = ui_ask_yn, $A00C = ui_ask_overwrite, $A00F = ui_ask_confirm_each,
; $A012 = ui_ask_delete_this, $A015 = ui_banner_copymove, $A018 = ui_banner_delete,
; $A01B = ui_copy_diag, $A01E = ui_draw_box, $A021 = ui_box_header, $A024 = ui_show_about,
; $A027 = ui_draw_commands, $A02A = ui_hist_popup.

%import textio
%import strings
%import "shared-const"
%address $A000
%memtop  $C000
%output  library
%zeropage dontuse

main {
    %option ignore_unused

    ; KEEP THIS BLOCK FREE OF INITIALIZED VARIABLES (same %jmptable gotcha as miscutil/tview):
    ; a module-level initialized var would be emitted before the code and shove the table off its
    ; fixed offsets. cm_dst below is UNINITIALIZED (-> BSS tail); all strings used here are inline
    ; literals inside subs (those are fine - it's only module init-data that moves the table).
    %jmptable ( main.ui_flash, main.ui_toast, main.ui_ask_yn, main.ui_ask_overwrite, main.ui_ask_confirm_each, main.ui_ask_delete_this, main.ui_banner_copymove, main.ui_banner_delete, main.ui_copy_diag, main.ui_draw_box, main.ui_box_header, main.ui_show_about, main.ui_draw_commands, main.ui_hist_popup )

    ; miscutil (bank 3) owns the history ring. A bank overlay CAN cross-bank call another overlay -
    ; prog8 emits a JSRFAR, which runs from ROM and restores our bank on return. What does NOT
    ; cross is DATA: while bank 3 is mapped, this bank's own storage is gone, so the line buffer
    ; hist_get writes into has to live in MAIN RAM (below $A000, always mapped) - main passes us
    ; its pointer rather than us keeping a local one.
    extsub @bank 3 $A012 = hist_get(ubyte slot @R0, uword outptr @R1)

    const ubyte HIST_PX0 = 12                   ; Recent-popup box left/right columns
    const ubyte HIST_PX1 = 67

    ; bottom-banner layout (must match xfmgr.p8's constants)
    const ubyte DIVBOT   = 26
    const ubyte CMDROW1  = 27
    const ubyte CMDROW2  = 28
    const ubyte MSGROW   = 27
    const ubyte SCR_BOT  = 29
    const ubyte BANNER_LEFT = 2
    const ubyte TREE_TEXT   = 2          ; menu text left column
    const ubyte FOCUS_TREE  = 0          ; focus values (match xfmgr.p8)

    ; box-drawing screencodes + About-box rectangle (mirror xfmgr.p8's constants)
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'
    const ubyte ABOUT_LEFT   = 19
    const ubyte ABOUT_RIGHT  = 60
    const ubyte ABOUT_TOP    = 6
    const ubyte ABOUT_BOTTOM = 20

    ubyte[132] cm_dst                       ; message-compose scratch (UNINITIALIZED -> BSS tail)
    ubyte[16] MSG_PRESS_ANY                  ; " Press any key " - filled in start() (see below)

    sub start() {
        ; library init ($A000): the compiler emits the BSS-clear here. We also seed MSG_PRESS_ANY
        ; from an INLINE literal (inline literals are safe; a named `str =` would shove the jmptable).
        void strings.copy(" Press any key ", MSG_PRESS_ANY)
    }

    ; ------------------------------------------------------------------ public entries

    sub ui_flash(uword mptr @R0) {
        ; message on row 1, "Press any key" on row 2, block until a key. (caller box_open'd)
        do_flash(mptr)
    }
    sub do_flash(str m) {
        box_left(CMDROW1, m)
        box_left(CMDROW2, MSG_PRESS_ANY)
        void wait_key()
    }

    sub ui_toast(uword mptr @R0) {
        ; brief self-dismissing message (~1.5s), or any key to dismiss it sooner.
        do_toast(mptr)
    }
    sub do_toast(str m) {
        box_left(CMDROW1, m)
        wait_or_key(90)
    }

    ; Hold a message for `jiffies` (1/60s each) OR until a key is pressed, whichever comes first.
    ; Replaces a bare sys.wait() at every toast site: the full linger is right when you want to
    ; read the result, but maddening when you already know what it says and want to carry on.
    ;
    ; The buffer is DRAINED first. Toasts are shown immediately after the command key that caused
    ; them, and on a repeat/typeahead that key is often still queued - without the drain the
    ; message would blink past before it could be read, which is the opposite of the point.
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

    sub ui_ask_yn(uword qptr @R0, ubyte default_yes @R1) -> ubyte {
        ; bracketed Yes/No: question on row 1, "[Yes] No / Yes [No]" + "Esc Cancel" on row 2.
        ; ENTER = bracketed default; Y/N pick; ESC/STOP -> No. Returns 1 = yes, 0 = no.
        return do_ask_yn(qptr, default_yes)
    }
    sub do_ask_yn(str question, ubyte default_yes) -> ubyte {
        box_left(CMDROW1, question)
        ubyte cs
        if default_yes != 0 {
            cs = choices_row(CMDROW2, "", "[Yes]  No  Esc Cancel")
            box_keyrun(cs + 1,  1, CMDROW2)         ; Y (inside the [ ])
            box_keyrun(cs + 7,  1, CMDROW2)         ; N
            box_keyrun(cs + 11, 3, CMDROW2)         ; Esc
        } else {
            cs = choices_row(CMDROW2, "", "Yes  [No]  Esc Cancel")
            box_keyrun(cs,      1, CMDROW2)         ; Y
            box_keyrun(cs + 6,  1, CMDROW2)         ; N (inside the [ ])
            box_keyrun(cs + 11, 3, CMDROW2)         ; Esc
        }
        repeat {
            when cmd_key() {
                'y'   -> return 1
                'n'   -> return 0
                27, 3 -> return 0
                13    -> return default_yes
            }
        }
    }

    sub ui_ask_overwrite(uword fnptr @R0) -> ubyte {
        ; "Overwrite <name>?" + "Yes [No] All Skip all  Esc Cancel" (default No = skip this).
        ; Returns folded 'y' overwrite this / 'n' skip this / 'a' overwrite all / 's' skip all.
        ; No frame restore here - the copy loop redraws over this box.
        return do_ask_overwrite(fnptr)
    }
    sub do_ask_overwrite(str fname) -> ubyte {
        compose_name("Overwrite ", fname, "?")
        box_left(CMDROW1, cm_dst)
        ubyte cs = choices_row(CMDROW2, "", "Yes  [No]  All  Skip all  Esc Cancel")
        box_keyrun(cs,      1, CMDROW2)         ; Y
        box_keyrun(cs + 6,  1, CMDROW2)         ; N (inside the [ ])
        box_keyrun(cs + 11, 1, CMDROW2)         ; A
        box_keyrun(cs + 16, 1, CMDROW2)         ; S (Skip all)
        box_keyrun(cs + 26, 3, CMDROW2)         ; Esc
        repeat {
            when cmd_key() {
                'y'        -> return 'y'
                'n', 13    -> return 'n'         ; N / ENTER (default) = skip this one
                'a'        -> return 'a'
                's', 27, 3 -> return 's'         ; Skip all / Esc = skip all remaining
            }
        }
    }

    sub ui_ask_confirm_each(uword n @R0) -> ubyte {
        ; heading "Delete N tagged files" on row 1; "Confirm delete for each file?" + choices on
        ; row 2. Returns 1 = confirm each, 0 = delete all (no per-file), 255 = cancel.
        return do_ask_confirm_each(n)
    }
    sub do_ask_confirm_each(uword n) -> ubyte {
        void strings.copy("Delete ", cm_dst)
        append_uw(n)
        void strings.append(cm_dst, " tagged files")
        box_left(CMDROW1, cm_dst)
        ubyte cs = choices_row(CMDROW2, "Confirm delete for each file?", "[Yes]  No  Esc Cancel")
        box_keyrun(cs + 1,  1, CMDROW2)         ; Y (inside the [ ])
        box_keyrun(cs + 7,  1, CMDROW2)         ; N
        box_keyrun(cs + 11, 3, CMDROW2)         ; Esc
        repeat {
            when cmd_key() {
                13, 'y' -> return 1             ; Enter (default) / Y
                'n'     -> return 0
                27, 3   -> return 255
            }
        }
    }

    sub ui_ask_delete_this(uword nptr @R0) -> ubyte {
        ; "Delete <name>?" on row 1; "Yes [No] All Files  Esc Cancel" on row 2 (default No).
        ; Returns 1 = delete this, 0 = skip, 2 = delete this + all remaining, 255 = cancel rest.
        return do_ask_delete_this(nptr)
    }
    sub do_ask_delete_this(str name) -> ubyte {
        compose_name("Delete ", name, "?")
        box_left(CMDROW1, cm_dst)
        ubyte cs = choices_row(CMDROW2, "", "Yes  [No]  All Files  Esc Cancel")
        box_keyrun(cs,      1, CMDROW2)         ; Y (Yes)
        box_keyrun(cs + 6,  1, CMDROW2)         ; N (inside the [ ])
        box_keyrun(cs + 11, 1, CMDROW2)         ; A (All Files)
        box_keyrun(cs + 22, 3, CMDROW2)         ; Esc
        repeat {
            when cmd_key() {
                'y'     -> return 1
                13, 'n' -> return 0             ; Enter (default) / N -> skip
                'a'     -> return 2
                27, 3   -> return 255
            }
        }
    }

    sub ui_banner_copymove(ubyte is_move @R0, uword done @R1, uword failed @R2, uword skipped @R3) {
        ; "<Copied|Moved> N file(s)" on row 1; failed/skipped counts on row 2 if any. Auto-dismiss.
        do_banner_copymove(is_move, done, failed, skipped)
    }
    sub do_banner_copymove(ubyte is_move, uword done, uword failed, uword skipped) {
        if is_move != 0
            void strings.copy("Moved ", cm_dst)
        else
            void strings.copy("Copied ", cm_dst)
        append_uw(done)
        void strings.append(cm_dst, " file(s)")
        box_left(CMDROW1, cm_dst)
        if failed == 0 and skipped == 0 {
            wait_or_key(120)
            return
        }
        cm_dst[0] = 0
        append_uw(failed)
        void strings.append(cm_dst, " failed  ")
        append_uw(skipped)
        void strings.append(cm_dst, " skipped")
        box_left(CMDROW2, cm_dst)
        wait_or_key(200)                         ; linger a little on problems
    }

    sub ui_banner_delete(uword done @R0) {
        ; auto-dismiss "Deleted N file(s)".
        do_banner_delete(done)
    }
    sub do_banner_delete(uword done) {
        void strings.copy("Deleted ", cm_dst)
        append_uw(done)
        void strings.append(cm_dst, " file(s)")
        box_left(CMDROW1, cm_dst)
        wait_or_key(120)
    }

    sub ui_copy_diag(ubyte failcode @R0, ubyte wstat @R1) {
        ; "Nothing copied - <cause>" + press any key. failcode/wstat come from main's cm_fail/cm_wstat.
        do_copy_diag(failcode, wstat)
    }
    sub do_copy_diag(ubyte failcode, ubyte wstat) {
        void strings.copy("Nothing copied", cm_dst)
        when failcode {
            1 -> void strings.append(cm_dst, " - source open failed")
            2 -> void strings.append(cm_dst, " - dest open failed")
            3 -> {
                void strings.append(cm_dst, " - write error ")
                append_uw(wstat)
            }
            4 -> void strings.append(cm_dst, " - copy overlay missing")
            else -> void strings.append(cm_dst, " - nothing selected")
        }
        box_left(CMDROW1, cm_dst)
        box_left(CMDROW2, MSG_PRESS_ANY)
        void wait_key()
    }

    ; ---- modal popup boxes (Recent / Pick-a-dir borders drawn here for main; About in full) ----

    sub ui_draw_box(ubyte x0 @R0, ubyte y0 @R1, ubyte x1 @R2, ubyte y1 @R3) {
        ; framed, shadowed, EMPTY-title popup window (callers add a title bar via ui_box_header).
        do_draw_box(x0, y0, x1, y1)
    }
    sub do_draw_box(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ubyte i
        txt.color(shared.CLR_FG)
        txt.setchr(x0, y0, SC_TL)
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        txt.setclr(x0, y0, shared.CLR_BOX)
        txt.setclr(x1, y0, shared.CLR_BOX)
        txt.setclr(x0, y1, shared.CLR_BOX)
        txt.setclr(x1, y1, shared.CLR_BOX)
        for i in x0+1 to x1-1 {
            txt.setchr(i, y0, SC_H)
            txt.setchr(i, y1, SC_H)
            txt.setclr(i, y0, shared.CLR_BOX)
            txt.setclr(i, y1, shared.CLR_BOX)
        }
        for i in y0+1 to y1-1
            box_row(x0, x1, i)
        box_shadow(x0, y0, x1, y1)
    }

    sub box_row(ubyte x0, ubyte x1, ubyte row) {
        txt.color(shared.CLR_FG)
        txt.setchr(x0, row, SC_V)
        txt.setchr(x1, row, SC_V)
        blank_span(x0+1, x1-1, row)
        txt.setclr(x0, row, shared.CLR_BOX)
        txt.setclr(x1, row, shared.CLR_BOX)
    }

    sub box_shadow(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        ubyte i
        for i in y0+1 to y1+1 {
            if x1 + 1 < 80
                txt.setclr(x1+1, i, 0)
        }
        for i in x0+1 to x1+1 {
            if y1 + 1 < 30 and i < 80
                txt.setclr(i, y1+1, 0)
        }
    }

    sub ui_box_header(ubyte x0 @R0, ubyte x1 @R1, ubyte y0 @R2, uword titleptr @R3) {
        ; solid blue title bar across the top border, title centered white-on-blue ($e1).
        do_box_header(x0, x1, y0, titleptr)
    }
    sub do_box_header(ubyte x0, ubyte x1, ubyte y0, str title) {
        ubyte i
        for i in x0+1 to x1-1
            txt.setchr(i, y0, sc:' ')
        ubyte tlen = lsb(strings.length(title))
        txt.plot(x0 + 1 + (x1 - x0 - 1 - tlen) / 2, y0)
        txt.print(title)
        for i in x0+1 to x1-1
            txt.setclr(i, y0, $e1)
        txt.color(shared.CLR_FG)
    }

    sub blank_span(ubyte col0, ubyte col1, ubyte row) {
        txt.plot(col0, row)
        ubyte c
        for c in col0 to col1
            txt.spc()
    }

    sub print_trunc(uword sptr, ubyte maxlen) {
        ubyte i = 0
        ubyte ch
        while i < maxlen {
            ch = @(sptr + i)
            if ch == 0
                break
            txt.chrout(ch)
            i++
        }
    }

    ; ---- the "Recent entries" history picker (Up-arrow in any text prompt) ----

    sub hist_draw_row(ubyte srow, uword textptr, bool selected) {
        ; (re)draw a single history row: clear it, print the entry, highlight if selected.
        ; Matches how do_draw_box's box_row paints a base row, so an unselected redraw is
        ; pixel-identical to the original (it resets any bar color).
        txt.color(shared.CLR_FG)
        blank_span(HIST_PX0+1, HIST_PX1-1, srow)
        txt.plot(HIST_PX0+2, srow)
        print_trunc(textptr, HIST_PX1-HIST_PX0-3)
        if selected
            hilite_row(HIST_PX0+1, HIST_PX1-1, srow, shared.HILITE)
    }

    sub ui_hist_popup(uword destptr @R0, ubyte maxlen @R1, ubyte count @R2, uword linebuf @R3) -> ubyte {
        ; (only the extsub decl in main names the return register - a normal sub here can't)
        ; @Rn args die the moment anything else is called, so hand them straight to a normal sub.
        return do_hist_popup(destptr, maxlen, count, linebuf)
    }

    sub do_hist_popup(uword destptr, ubyte maxlen, ubyte count, uword linebuf) -> ubyte {
        ; modal picker of recent entries, shell-style: the NEWEST entry (slot 0) sits at
        ; the BOTTOM of the list, right above the prompt, and is selected by default;
        ; Up walks back into older entries. `sel` is a slot index (0 = newest). On Enter,
        ; copy the choice into destptr (capped at maxlen) and return its length; on Esc
        ; return 255 (no change). Only called when count != 0.
        ;
        ; `linebuf` is main's staging buffer - see the hist_get note at the top of this file.
        ubyte sel = 0
        ubyte c
        ; geometry is fixed while the popup is open (count can't change): a blank spacer line
        ; sits under the header at boxtop+1, the list fills boxtop+2.., and the bottom border
        ; anchors at row 26. srow for a slot = boxtop+rows+1-slot.
        ubyte rows = count
        ubyte boxtop = 24 - rows
        ; --- draw the chrome + full list ONCE; the key loop below only repaints the two
        ;     rows that change on Up/Down instead of redrawing the whole list ---
        do_draw_box(HIST_PX0, boxtop, HIST_PX1, boxtop+rows+2)
        do_box_header(HIST_PX0, HIST_PX1, boxtop, " Recent ")
        ; key hints in a centered footer on the bottom border, as ONE embedded-color
        ; string (\x9e=accent, \x05=fg; ←┘=ENTER glyph). Visible length = 23.
        txt.plot(HIST_PX0 + 1 + (HIST_PX1 - HIST_PX0 - 1 - 23) / 2, boxtop+rows+2)
        txt.print(petscii:"\x9e ←┘\x05 Select  \x9eESC\x05 Cancel ")
        ubyte p
        for p in 0 to rows-1 {
            ubyte slot = rows - 1 - p        ; oldest at top, newest at the bottom
            hist_get(slot, linebuf)          ; pull the entry out of the miscutil ring
            hist_draw_row(boxtop+2+p, linebuf, slot == sel)
        }
        repeat {
            ubyte k = wait_key()
            if k >= $c1 and k <= $da
                k -= $80
            when k {
                27, 3 -> return 255          ; ESC / STOP: cancel
                13 -> {                      ; Enter: take the selected entry
                    hist_get(sel, linebuf)
                    ubyte j = 0
                    repeat {
                        c = @(linebuf + j)
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
                        hist_get(sel, linebuf)
                        hist_draw_row(boxtop+rows+1-sel, linebuf, false)
                        sel++
                        hist_get(sel, linebuf)
                        hist_draw_row(boxtop+rows+1-sel, linebuf, true)
                    }
                }
                17 -> {                      ; down -> newer entry (lower slot)
                    if sel != 0 {
                        hist_get(sel, linebuf)
                        hist_draw_row(boxtop+rows+1-sel, linebuf, false)
                        sel--
                        hist_get(sel, linebuf)
                        hist_draw_row(boxtop+rows+1-sel, linebuf, true)
                    }
                }
            }
        }
    }

    ; ---- the About modal (full box; banked-RAM figures passed in from main's xarena) ----

    sub ui_show_about(ubyte high_bank @R0, ubyte max_bank @R1) {
        do_show_about(high_bank, max_bank)
    }
    sub do_show_about(ubyte high_bank, ubyte max_bank) {
        do_draw_box(ABOUT_LEFT, ABOUT_TOP, ABOUT_RIGHT, ABOUT_BOTTOM)
        do_box_header(ABOUT_LEFT, ABOUT_RIGHT, ABOUT_TOP, " About ")
        aboutln(2,  "X F M G R")
        aboutln(4,  "An XTree-style file manager")
        aboutln(5,  "for the Commander X16")
        aboutln(7,  "Beta Version 1.0.262")     ; bump the last number with BUILD_NUM in xfmgr.p8
        ; "Banked RAM: "(12) + digits + " of "(4) + digits + " banks"(6) = 22 + digits
        txt.plot(about_col(22 + about_digits(high_bank) + about_digits(max_bank)), ABOUT_TOP + 9)
        txt.print("Banked RAM: ")
        txt.print_ub(high_bank)
        txt.print(" of ")
        txt.print_ub(max_bank)
        txt.print(" banks")
        aboutln(10, "Written in Prog8")
        aboutln(11, "(c)2025-26 sadLogic")
        txt.plot(about_col(15), ABOUT_BOTTOM-1)         ; centered " Press any key " (15 chars)
        txt.color(shared.CLR_ACCENT)
        txt.print(MSG_PRESS_ANY)
        txt.color(shared.CLR_FG)
        void wait_key()
    }

    sub about_col(ubyte slen) -> ubyte {
        return ABOUT_LEFT + 1 + (ABOUT_RIGHT - ABOUT_LEFT - 1 - slen) / 2
    }
    sub about_digits(ubyte n) -> ubyte {
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

    ; ---- bottom command menu (all the label strings live here now) ----
    ; State the menu depends on is passed in from main (the overlay can't see main's globals):
    ; menu_mode 0/1/2 = MENU/CTRL/ALT, focus 0 = tree pane, del_char = env-specific Del key char,
    ; sort_mode 0/1/2 = name/ext/size.

    sub ui_draw_commands(ubyte menu_mode @R0, ubyte focus @R1, ubyte del_char @R2, ubyte sort_mode @R3, ubyte find_char @R4, ubyte move_char @R5, ubyte srch_char @R6, ubyte view_char @R7) {
        do_draw_commands(menu_mode, focus, del_char, sort_mode, find_char, move_char, srch_char, view_char)
    }
    sub do_draw_commands(ubyte menu_mode, ubyte focus, ubyte del_char, ubyte sort_mode, ubyte find_char, ubyte move_char, ubyte srch_char, ubyte view_char) {
        blank_span(1, 78, CMDROW1)
        txt.plot(TREE_TEXT, CMDROW1)
        txt.color(shared.CLR_ACCENT)
        when menu_mode {
            1 -> {
                txt.print("CTRL: ")
                txt.color(shared.CLR_FG)
                menu_ctrl_items(focus, del_char, find_char, move_char, srch_char, view_char)
            }
            2 -> {
                txt.print("ALT:  ")
                txt.color(shared.CLR_FG)
                menu_alt_items(focus, sort_mode)
            }
            else -> {
                txt.print("MENU: ")
                txt.color(shared.CLR_FG)
                menu_plain_items(focus)
            }
        }
        blank_span(1, 78, CMDROW2)
        txt.plot(TREE_TEXT, CMDROW2)
        txt.color(shared.CLR_FG)
        if menu_mode == 0 {
            txt.print(petscii:"Hold \x9eCTRL\x05 or \x9eALT\x05 for more commands")
            ; TAB Files sits on THIS row, beside the modifier hint: both are about GETTING somewhere
            ; rather than acting on the folder under the bar, which is what all of row 1 does.
            if focus == FOCUS_TREE {
                txt.plot(58, CMDROW2)
                txt.print(petscii:"\x9eTAB\x05 Files")
            }
        }
        if menu_mode == 2 {
            txt.plot(70, CMDROW2)
            txt.print(petscii:"\x9eQ\x05uit-here")
        } else {
            txt.plot(75, CMDROW2)
            txt.print(petscii:"\x9eQ\x05uit")
        }
    }

    sub draw_hkey(ubyte c) {
        ; print a hotkey letter highlighted in the accent color (yellow)
        txt.color(shared.CLR_ACCENT)
        txt.chrout(c)
        txt.color(shared.CLR_FG)
    }

    sub menu_plain_items(ubyte focus) {
        if focus == FOCUS_TREE {
            ; Row 1 is the commands that ACT on the selected folder; 53 visible chars from col 2,
            ; ending at 54. TAB Files is on row 2 with the other navigation text - it moves you
            ; between panes rather than doing anything to the folder under the bar.
            txt.print(petscii:"\x9e←┘\x05Log  \x9eM\x05kdir  \x9eR\x05ename  \x9eD\x05elete  \x9eS\x05howall  \x9eB\x05ranch  \x9eG\x05lobal")
            txt.plot(65, CMDROW1)                   ; right-justified: 14 chars ending at col 78
            txt.print(petscii:"\x9eF1\x05 Help  \x9eA\x05bout")
        } else {
            txt.print(petscii:"\x9eT\x05ag \x9eU\x05ntag \x9eV\x05iew \x9eP\x05lay \x9eE\x05dit \x9eC\x05opy \x9eM\x05ove \x9eF\x05ilespec \x9eR\x05ename \x9eD\x05elete")
        }
    }

    sub menu_ctrl_items(ubyte focus, ubyte del_char, ubyte find_char, ubyte move_char, ubyte srch_char, ubyte view_char) {
        if focus == FOCUS_TREE {
            txt.print(petscii:"\x9eT\x05ag  \x9eU\x05ntag  ")
            find_label(find_char)
            return
        }
        txt.print(petscii:"\x9eT\x05ag \x9eU\x05ntag \x9eI\x05nvert ")
        view_label(view_char)
        txt.chrout(' ')
        srch_label(srch_char)
        txt.chrout(' ')
        find_label(find_char)
        txt.print(petscii:" \x9eC\x05opy ")
        move_label(move_char)
        txt.print(petscii:" \x9eW\x05ild ")
        del_label(del_char)
    }

    sub view_label(ubyte view_char) {
        ; the view-tagged hotkey varies by environment (Ctrl-V on hw - the classic XTree key - and
        ; Ctrl-L under the emulator, which eats Ctrl-V as its paste shortcut). Show the active key:
        ; "View" with V picked out on hw, "L-View" on emu. Mirrors del/find/move/srch_label.
        if view_char == 'V' {
            txt.print(petscii:"\x9eV\x05iew")
        } else {
            draw_hkey(view_char)
            txt.print("-View")
        }
    }

    sub srch_label(ubyte srch_char) {
        ; the content-search hotkey varies by environment (Ctrl-S on hw - the classic XTree key - and
        ; Ctrl-E under the emulator, which swallows Ctrl-S). Show the active key: "Srch" with S picked
        ; out on hw, "E-Srch" on emu. Mirrors del/find/move_label.
        if srch_char == 'S' {
            txt.print(petscii:"\x9eS\x05rch")
        } else {
            draw_hkey(srch_char)
            txt.print("-Srch")
        }
    }

    sub move_label(ubyte move_char) {
        ; the move-tagged hotkey varies by environment (Ctrl-M on hw, Ctrl-O on emu, which grabs
        ; Ctrl-M). Show the active key: "Move" with M picked out on hw, "O-Move" on emu (matches the
        ; X-Del / N-Find style, since the emu key O isn't Move's first letter). Mirrors del/find_label.
        if move_char == 'M' {
            txt.print(petscii:"\x9eM\x05ove")
        } else {
            draw_hkey(move_char)
            txt.print("-Move")
        }
    }

    sub del_label(ubyte del_char) {
        ; the delete-tagged hotkey varies by environment (Ctrl-D on hw, Ctrl-X under the emulator,
        ; which swallows Ctrl-D). Show the active key inside the word: "Delete" with D picked out on
        ; hw, "X Del" on emu (Delete doesn't start with X). Mirrors find_label.
        if del_char == 'D' {
            txt.print(petscii:"\x9eD\x05elete")
        } else {
            draw_hkey(del_char)
            txt.print("-Del")
        }
    }

    sub find_label(ubyte find_char) {
        ; the Find hotkey varies by environment (Ctrl-F on hw, Ctrl-N under the emulator, which
        ; swallows Ctrl-F). Show the active key: "Find" with F picked out on hw, "N Find" on emu.
        if find_char == 'F' {
            txt.print(petscii:"\x9eF\x05ind")
        } else {
            draw_hkey(find_char)
            txt.print("-Find")
        }
    }

    sub menu_alt_items(ubyte focus, ubyte sort_mode) {
        if focus == FOCUS_TREE {
            txt.print(petscii:"\x9eF3\x05 Relog  \x9eP\x05rune  \x9eR\x05elease  \x9eJ\x05ump  \x9eT\x05ag branch  \x9eU\x05ntag all")
            ; Config hotkey right-justified at the row's right edge (ends at col 78, like "About").
            ; Tree pane only - the file pane's ALT row is already full (eXecute/Sort/relog/Release).
            txt.plot(69, CMDROW1)
            txt.print(petscii:"\x9eF10\x05 Config")
        } else {
            txt.print(petscii:"e\x9eX\x05ecute  \x9eS\x05ort: ")
            ; bit 7 = main's sort_pending: Alt-S has SELECTED this order but ALT is still held, so
            ; it hasn't been applied. Highlighting it makes tapping S through the orders visible.
            ; The trailing string's own \x9e..\x05 puts the color back, so no restore call here.
            if sort_mode >= $80
                txt.color(shared.CLR_ACCENT)
            when sort_mode & $7f {
                1 -> txt.print("ext")
                2 -> txt.print("size")
                else -> txt.print("name")
            }
            txt.print(petscii:"\x9e  F3\x05 relog  \x9eR\x05elease")
        }
    }

    ; ------------------------------------------------------------------ in-bank helpers

    sub box_left(ubyte row, str s) {
        txt.plot(BANNER_LEFT, row)
        txt.print(s)
        hilite_row(0, 79, row, shared.CLR_BOTTOM_PROMPT_BG)     ; full width (0..79)
    }

    sub box_keyrun(ubyte col, ubyte n, ubyte row) {
        ubyte c
        ubyte e = col + n - 1
        for c in col to e
            txt.setclr(c, row, shared.CLR_BOTTOM_PROMPT_KEY)
    }

    sub choices_row(ubyte row, str q, str ch) -> ubyte {
        ; question q left at BANNER_LEFT, choices ch right-aligned ending at col 78; returns cstart.
        txt.plot(BANNER_LEFT, row)
        txt.print(q)
        ubyte cstart = 79 - lsb(strings.length(ch))     ; right-aligned; last char lands on col 78
        txt.plot(cstart, row)
        txt.print(ch)
        hilite_row(0, 79, row, shared.CLR_BOTTOM_PROMPT_BG)          ; full width (0..79)
        return cstart
    }

    sub hilite_row(ubyte x0, ubyte x1, ubyte row, ubyte color) {
        ubyte c
        for c in x0 to x1
            txt.setclr(c, row, color)
    }

    sub compose_name(str prefix, str name, str suffix) {
        ; cm_dst = prefix + name(capped at 58) + suffix
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

    sub append_uw(uword v) {
        ; append decimal v to cm_dst
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

    sub wait_key() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub cmd_key() -> ubyte {
        ; read a key case-insensitively: fold a SHIFTED letter ($c1..$da) down onto $41..$5a.
        ubyte k = wait_key()
        if k >= $c1 and k <= $da
            k -= $80
        return k
    }
}
