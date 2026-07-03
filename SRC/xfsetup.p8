; xfsetup - standalone colour-theme picker for XFMGR2.
;
; A normal $0801 PRG (NOT a bank overlay). XFMGR launches it via chain_run (Alt-C); it lets the
; user pick a colour theme with live preview, writes the choice to /xfmgr/xfmgr.cfg, then
; chain_runs back to /xfmgr/xfmgr.prg - which cold-starts, reads the cfg and applies the theme.
; Because setup is stateless w.r.t. XFMGR's tree/arena, no state snapshot is needed; the only cost
; is XFMGR's ~2s reload. Themes are palette remaps (see SRC/themes.p8), so this runs in the same
; PETSCII 80x30 text mode XFMGR uses - no charset change.

%import textio
%import diskio
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
    ubyte sel                                ; currently highlighted theme id (themes.FIRST..LAST)

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        cx16.set_screen_mode(SCREEN_MODE)
        txt.lowercase()

        ; the config lives in the program's own /xfmgr/ folder (alongside the .prg + overlays).
        ; chdir is a harmless no-op if we were launched directly from that folder.
        diskio.chdir("xfmgr")
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
        txt.print("Colour theme:")
        txt.plot(BX0 + 2, BY1 - 2)
        txt.print(petscii:"\x9eup/dn\x05 select")
        txt.plot(BX0 + 2, BY1 - 1)
        txt.print(petscii:"\x9e←┘\x05 save  \x9eESC\x05 cancel")
    }

    sub refresh() {
        themes.apply_theme(sel)                     ; live preview: recolour the whole screen
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
        txt.chrout($93)                     ; clear, cursor home (row 0)
        txt.nl()                            ; row 1 (BASIC "READY." overwrites)
        txt.print("load")                   ; row 2: LOAD"/xfmgr/xfmgr.prg"
        txt.chrout($22)
        txt.print("/xfmgr/xfmgr.prg")
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
