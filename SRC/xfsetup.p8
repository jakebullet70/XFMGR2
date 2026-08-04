; xfsetup - standalone color-theme picker for XFMGR2.
;
; A normal $0801 PRG (NOT a bank overlay). XFMGR launches it via chain_run (Alt-F10); it lets the
; user pick a color theme with live preview, writes the choice to /xfmgr/xfmgr.cfg, then
; chain_runs back to /xfmgr/xfmgr.prg - which cold-starts, reads the cfg and applies the theme.
; Because setup is stateless w.r.t. XFMGR's tree/arena, no snapshot of the TREE is needed; the only
; cost is XFMGR's ~2s reload. Themes are palette remaps (see SRC/themes.p8), so this runs in the
; same PETSCII 80x30 text mode XFMGR uses.
;
; It does still take the MACHINE state, exactly as xfmgr.p8 does - screen mode, charset and text
; color captured in start() and put back in return_to_xfmgr() before the hand-off. It has to: the
; charset is changed here (txt.lowercase), and XFMGR re-snapshots on the way back in, so anything
; left changed would be adopted as the user's own setting and never restored.

%import textio
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header
%import strings
%import themes
%import "shared-const"
%zeropage basicsafe
%option no_sysinit

main {
    const ubyte SCREEN_MODE = $01           ; 80x30 text (matches XFMGR)

    ; single-line PETSCII box screencodes (drawn with setchr, no cursor move)
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'

    const ubyte BX0 = 26                     ; theme box: left / right / top / bottom
    const ubyte BX1 = 53
    const ubyte BY0 = 6
    const ubyte BY1 = 20
    const ubyte LIST_ROW = 10                ; row of the first theme entry

    ubyte saved_mode
    ubyte saved_charset                      ; charset we were launched in (1=ISO 2=upper/gfx 3=lower)
    ubyte saved_color                        ; and the text color (bg<<4|fg) - both put back on exit
    ubyte sel                                ; currently highlighted theme id (themes.FIRST..LAST)

    ; every input-history category XFMGR writes as hist/<cat>.his (current + legacy move/copy,
    ; which merged into "copymove"). "Clear history" deletes each of these from /xfmgr/hist/.
    str[8] HIST_CATS = ["copymove", "mkdir", "rename", "tagspec", "find", "filespec", "move", "copy"]
    ubyte[20] fnbuf                          ; "<cat>.his" scratch for the delete loop

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        snapshot_machine_state()            ; charset + color, read while STILL in the launch mode
        cx16.set_screen_mode(SCREEN_MODE)
        txt.lowercase()                     ; our own UI needs the mixed-case charset - and this is
                                            ; exactly the change restore_machine_state undoes

        ; The config lives in the program's own folder, alongside the .prg + overlays. No chdir:
        ; themes.cfg_read/cfg_write build an ABSOLUTE path from the install folder parsed out of
        ; the root XT launcher (themes.find_progdir), so they find it wherever XFMGR was installed
        ; and whatever directory we happen to be launched in.
        sel = themes.cfg_read()

        draw_static()
        refresh()

        repeat {
            ubyte k = getkey()
            when k {
                145 -> {                            ; cursor up
                    if sel > themes.FIRST {
                        sel--
                        refresh()
                    }
                }
                17 -> {                             ; cursor down
                    if sel < themes.LAST {
                        sel++
                        refresh()
                    }
                }
                13 -> {                             ; ENTER: save + return
                    themes.cfg_write(sel)
                    break
                }
                'h', 'H' -> ask_clear_history()      ; delete the saved input-history files
                27 -> break                         ; ESC: cancel (no save)
                else -> { }
            }
        }
        return_to_xfmgr()
    }

    sub draw_static() {
        themes.apply_theme(sel)                     ; preview the current theme before first paint
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        txt.clear_screen()
        drawbox(BX0, BY0, BX1, BY1)
        txt.color(shared.CLR_TITLE)
        txt.plot(BX0 + 2, BY0)
        txt.print(" XFSETUP ")
        txt.color(shared.CLR_FG)
        txt.plot(BX0 + 3, BY0 + 2)
        txt.print("Color theme:")
        txt.plot(BX0 + 2, BY1 - 2)
        txt.print(petscii:"\x9eH\x05 Clear history")
        txt.plot(BX0 + 2, BY1 - 1)
        txt.print(petscii:"\x9e←┘\x05 Save  \x9eESC\x05 Cancel")
    }

    sub ask_clear_history() {
        ; delete every hist/<cat>.his file right away (no confirm), flash the result on the box row
        ; above the hints for ~2s, then blank it. refresh() repaints the theme rows, not this line.
        clear_history()
        clear_msg_row()
        txt.plot(BX0 + 2, BY1 - 4)
        txt.print("History cleared")
        ; ~2s at 60 Hz, or any key to dismiss sooner. Drain first: the 'H' that triggered this
        ; is often still queued and would blink the message away unread.
        while cbm.GETIN2() != 0 {
        }
        ubyte n
        for n in 0 to 119 {
            sys.waitvsync()
            if cbm.GETIN2() != 0
                break
        }
        clear_msg_row()
    }

    sub clear_msg_row() {
        ; blank the message row (BY1-4) inside the box, in the current bg color
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        txt.plot(BX0 + 1, BY1 - 4)
        ubyte c
        for c in BX0 + 1 to BX1 - 1
            txt.spc()
    }

    sub clear_history() {
        ; Delete each <progdir>hist/<cat>.his. Save + restore the cwd (curdir() is a transient
        ; buffer, so copy it out first); a missing hist/ just leaves cwd put and the deletes miss
        ; harmlessly.
        ; The chdir target MUST be absolute (themes.path_to): this used to be a bare chdir("hist"),
        ; which only worked because start() had already chdir'd into /xfmgr. That hop is gone now
        ; that the cfg is reached by absolute path, so a relative "hist" would resolve against
        ; whatever directory we were launched in and silently delete nothing.
        ubyte[80] savedir
        void strings.copy(diskio.curdir(), savedir)
        diskio.chdir(themes.path_to("hist"))
        ubyte i
        for i in 0 to len(HIST_CATS) - 1 {
            void strings.copy(HIST_CATS[i], fnbuf)
            void strings.append(fnbuf, ".his")
            diskio.delete(fnbuf)
        }
        diskio.chdir(savedir)
    }

    sub refresh() {
        themes.apply_theme(sel)                     ; live preview: recolor the whole screen
        ubyte i
        for i in 0 to themes.LAST - themes.FIRST {  ; 0..4
            ubyte id  = themes.FIRST + i            ; 1..5
            ubyte row = LIST_ROW + i
            if id == sel
                txt.color2(shared.CLR_FG, shared.CLR_TITLE)     ; highlight bar (white on title)
            else
                txt.color2(shared.CLR_FG, shared.CLR_BG)
            ; fill the row interior so the bar spans the box and clears old text
            ubyte c
            txt.plot(BX0 + 1, row)
            for c in BX0 + 1 to BX1 - 1
                txt.spc()
            txt.plot(BX0 + 3, row)
            if id == sel
                txt.chrout('>')
            else
                txt.chrout(' ')
            txt.spc()
            txt.print(themes.NAMES[i])
        }
        txt.color2(shared.CLR_FG, shared.CLR_BG)
    }

    sub drawbox(ubyte x0, ubyte y0, ubyte x1, ubyte y1) {
        txt.color(shared.CLR_FG)
        txt.setchr(x0, y0, SC_TL)
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        ubyte c
        for c in x0 + 1 to x1 - 1 {
            txt.setchr(c, y0, SC_H)
            txt.setchr(c, y1, SC_H)
        }
        for c in y0 + 1 to y1 - 1 {
            txt.setchr(x0, c, SC_V)
            txt.setchr(x1, c, SC_V)
        }
        for c in x0 to x1 {
            txt.setclr(c, y0, shared.CLR_BOX)
            txt.setclr(c, y1, shared.CLR_BOX)
        }
        for c in y0 to y1 {
            txt.setclr(x0, c, shared.CLR_BOX)
            txt.setclr(x1, c, shared.CLR_BOX)
        }
    }

    sub snapshot_machine_state() {
        ; Capture the charset + text color we were launched with, so the hand-off back to XFMGR
        ; leaves the machine as we found it. Mirrors xfmgr.p8's sub of the same name and exists for
        ; the same reason: set_screen_mode's CINT resets both to the X16 defaults, and txt.lowercase()
        ; changes the charset again on top of that.
        ;
        ; This was missing, and it did not go missing quietly. XFMGR restores the user's charset
        ; before it chain_runs us; we switched to charset 3 and never went back, so when XFMGR
        ; restarted it snapshotted OUR charset as though it were the user's. One trip through
        ; Alt-F10 and the font XFMGR would put back on quit was gone for the rest of the session.
        saved_charset = cx16.get_charset()      ; 1=ISO 2=PETSCII upper/gfx 3=PETSCII lower (0=unknown)
        ; text color = the color matrix at the cursor cell. txt.getclr, never a hand-computed VERA
        ; address - the text matrix row stride is a fixed 256 bytes, so row*width*2 is wrong for
        ; any row past the first (see the same note in xfmgr.p8).
        ubyte cx_col
        ubyte cx_row
        cx_col, cx_row = txt.get_cursor()
        saved_color = txt.getclr(cx_col, cx_row)
    }

    sub restore_machine_state() {
        ; Undo our charset + color changes: re-apply what snapshot_machine_state() captured. The
        ; set_screen_mode call that precedes every caller has already reset both to X16 defaults.
        if saved_charset >= 1 and saved_charset <= 3
            cx16.screen_set_charset(saved_charset, 0)       ; 0 ptr = built-in ROM charset
        if saved_color != 0                                 ; 0 = black-on-black -> skip a bad read
            txt.color2(saved_color & 15, saved_color >> 4)  ; low nibble = fg, high nibble = bg
    }

    sub getkey() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    sub return_to_xfmgr() {
        ; dynamic-keyboard LOAD + RUN of XFMGR (mirrors xfmgr.p8's chain_run): PRINT the LOAD line,
        ; cursor back up onto it, then feed CR + RUN + CR (5 bytes - fits the 10-byte kbd buffer).
        txt.clear_screen()
        cx16.set_screen_mode(saved_mode)
        restore_machine_state()             ; charset + color back BEFORE the hand-off - the same
                                            ; order xfmgr.p8 uses on every one of its exits,
                                            ; chain_run branches included
        txt.chrout($93)                     ; clear, cursor home (row 0)
        txt.nl()                            ; row 1 (BASIC "READY." overwrites)
        txt.print("load")                   ; row 2: LOAD"<install>/xfmgr.prg"
        txt.chrout($22)
        ; install folder from the /xt launcher (themes.path_to), NOT hard-coded "/xfmgr/" - so the
        ; relaunch finds xfmgr.prg wherever it was installed (e.g. /utils/xfmgr/). cfg_read at start()
        ; already primed progdir, so this is just a buffer build.
        txt.print(themes.path_to("xfmgr.prg"))
        txt.chrout($22)
        txt.chrout($91)                     ; cursor UP -> row 1
        txt.chrout($91)                     ; cursor UP -> row 0
        cx16.kbdbuf_clear()
        cx16.kbdbuf_put($0d)                ; CR submits the on-screen LOAD line
        cx16.kbdbuf_put('r')
        cx16.kbdbuf_put('u')
        cx16.kbdbuf_put('n')
        cx16.kbdbuf_put($0d)                ; RUN + CR
    }
}
