; xfsetup - the standalone settings program for XFMGR2.
;
; A normal $0801 PRG (NOT a bank overlay). XFMGR launches it via chain_run (Alt-F10); it edits the
; saved settings with live preview, writes them to <install>/xfmgr.cfg, then chain_runs back to
; xfmgr.prg - which cold-starts, re-reads the cfg and applies everything. Because setup is stateless
; w.r.t. XFMGR's tree/arena, no snapshot of the TREE is needed; the only cost is XFMGR's ~2s reload.
;
; A separate .prg rather than a dialog inside xfmgr.prg, and laid out on x16-MSEDIT's EDCFG model
; (SRC/edcfg.p8 over there) now that there is more than one thing to set:
;
;   - The settings live in SRC/themes.p8, shared with XFMGR. WRITING xfmgr.cfg is THIS program's
;     job alone - XFMGR only reads it - which keeps diskio's write path (f_open_w/f_write) out of
;     XFMGR's low RAM entirely.
;   - The screen is a list of settings under non-selectable section headers, one row per setting.
;     Up/Down picks a row (headers are skipped), Left/Right changes its value, applied LIVE. F10
;     writes the cfg and returns to XFMGR; Esc returns without writing.
;   - Adding a setting = one more SET_ROW entry + a change() arm + a draw arm + its help text,
;     plus its var in themes.p8 and one append_kv line in cfg_write().
;
; It also takes the MACHINE state, exactly as xfmgr.p8 does - screen mode, charset and text color
; captured in start() and put back in return_to_xfmgr() before the hand-off. It has to: the charset
; is changed here (txt.lowercase), and XFMGR re-snapshots on the way back in, so anything left
; changed would be adopted as the user's own setting and never restored.
;
; Themes are palette remaps (see SRC/themes.p8), so this runs in the same PETSCII 80x30 text mode
; XFMGR uses, and every color below is one of the indices a theme repaints - the settings screen
; previews the theme it is setting.

%import textio
%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header
%import strings
%import themes
%import "shared-const"
%zeropage basicsafe
%option no_sysinit

main {
    const ubyte SCREEN_MODE = $01           ; 80x30 text (matches XFMGR)
    const ubyte SCR_W = 80
    const ubyte SCR_H = 30

    ; setting rows. NSET counts the SELECTABLE rows only - the section headers between them are
    ; drawn by draw_all() and never highlighted.
    const ubyte NSET = 3
    ubyte[3] SET_ROW = [8, 11, 14]          ; Display: Color theme@8 (hdr 7)
                                            ; Keyboard: Command keys@11 (hdr 10)
                                            ; Maintenance: Input history@14 (hdr 13)
    const ubyte ROW_HISTORY = 2             ; the one row that ACTS (on RETURN) instead of holding
                                            ; a value - see change() and do_clear_history()
    const ubyte LABEL_COL = 4               ; setting name
    const ubyte VALUE_COL = 24              ; its value
    const ubyte HELP_ROW  = 20              ; two-line explanation of the highlighted setting

    ; attribute bytes (bg<<4)|fg built from the themed indices in shared-const, so every one of
    ; them follows the theme being previewed.
    const ubyte CB_BAR  = (shared.CLR_TITLE << 4) | shared.CLR_FG      ; top / bottom bars
    const ubyte CB_BODY = (shared.CLR_BG    << 4) | shared.CLR_FG      ; ordinary setting row
    const ubyte CB_SEL  = (shared.CLR_TITLE << 4) | shared.CLR_FG      ; highlighted setting row
    const ubyte CB_HDR  = (shared.CLR_BG    << 4) | shared.CLR_ACCENT  ; section-header chip
    const ubyte CB_HELP = (shared.CLR_BG    << 4) | shared.CLR_ACCENT  ; the help lines

    ; single-line PETSCII box screencodes (drawn with setchr, no cursor move)
    const ubyte SC_TL = sc:'┌'
    const ubyte SC_TR = sc:'┐'
    const ubyte SC_BL = sc:'└'
    const ubyte SC_BR = sc:'┘'
    const ubyte SC_H  = sc:'─'
    const ubyte SC_V  = sc:'│'

    ; one help line pair per setting row, shown under the list for whichever row is highlighted.
    str[3] HELP1 = [
        "Repaints the whole XFMGR palette. Previewed live as you change it.",
        "Auto: use the emulator-safe CTRL keys when x16emu is detected.",
        "Deletes the saved input-history rings (find, rename, filespec, ...)."
    ]
    str[3] HELP2 = [
        "",
        "Hardware: always Ctrl-D/F/M/S/V - correct on a real X16.",
        "Press RETURN to clear them now. This one acts immediately."
    ]

    ubyte saved_mode
    ubyte saved_charset                      ; charset we were launched in (1=ISO 2=upper/gfx 3=lower)
    ubyte saved_color                        ; and the text color (bg<<4|fg) - both put back on exit
    ubyte sel                                ; highlighted SETTING row (0..NSET-1)
    ubyte theme_id                           ; the theme being previewed (themes.FIRST..LAST)
    ubyte orig_theme                         ; the theme we opened with - restored on Esc
    ubyte[40] cfg_line                       ; cfg write buffer (see themes.cfg_line's note on size)

    ; every input-history category XFMGR writes as hist/<cat>.his (current + legacy move/copy,
    ; which merged into "copymove"). "Clear history" deletes each of these from <install>/hist/.
    str[8] HIST_CATS = ["copymove", "mkdir", "rename", "tagspec", "find", "filespec", "move", "copy"]
    ubyte[20] fnbuf                          ; "<cat>.his" scratch for the delete loop

    sub start() {
        saved_mode, cx16.r0L, cx16.r0H = cx16.get_screen_mode()
        snapshot_machine_state()            ; charset + color, read while STILL in the launch mode
        cx16.set_screen_mode(SCREEN_MODE)
        txt.lowercase()                     ; our own UI needs the mixed-case charset - and this is
                                            ; exactly the change restore_machine_state undoes

        ; The config lives in the program's own folder, alongside the .prg + overlays. No chdir:
        ; themes.cfg_read builds an ABSOLUTE path from the install folder parsed out of the root XT
        ; launcher (themes.find_progdir), so it is found wherever XFMGR was installed and whatever
        ; directory we happen to be launched in. It also fills themes.hw_keys.
        theme_id = themes.cfg_read()
        orig_theme = theme_id

        draw_all()
        repeat {
            ubyte k = getkey()
            when k {
                17 -> {                             ; cursor down
                    sel++
                    if sel >= NSET
                        sel = 0
                    draw_all()
                }
                145 -> {                            ; cursor up
                    if sel == 0
                        sel = NSET - 1
                    else
                        sel--
                    draw_all()
                }
                29, ' ' -> {                        ; cursor right / space: next value
                    change(true)
                    draw_all()
                }
                157 -> {                            ; cursor left: previous value
                    change(false)
                    draw_all()
                }
                13 -> {                             ; RETURN: only the action row uses it
                    if sel == ROW_HISTORY
                        do_clear_history()
                }
                21 -> {                             ; F10 ($15): write the settings, back to XFMGR
                    alert_box("Saving...")          ; centred alert - the write is near-instant, so
                    sys.wait(30)                    ; hold it ~0.5s or it never registers
                    if not cfg_write(theme_id) {
                        txt.plot(2, SCR_H - 3)
                        txt.print("could not write the settings file!")
                        void getkey()
                    }
                    break
                }
                27 -> {                             ; ESC: cancel, cfg untouched
                    themes.apply_theme(orig_theme)  ; hand XFMGR back the theme that is really saved
                    break
                }
                else -> { }
            }
        }
        return_to_xfmgr()
    }

    sub change(bool forward) {
        ; adjust the highlighted setting. One `when` arm per setting row.
        when sel {
            0 -> {                                  ; color theme: wrap through the presets
                if forward {
                    theme_id++
                    if theme_id > themes.LAST
                        theme_id = themes.FIRST
                } else {
                    if theme_id <= themes.FIRST
                        theme_id = themes.LAST
                    else
                        theme_id--
                }
                themes.apply_theme(theme_id)        ; live preview - draw_all repaints in the new colors
            }
            1 -> themes.hw_keys = not themes.hw_keys    ; command keys: Auto <-> Force hardware
            ROW_HISTORY -> { }                  ; an ACTION row, not a value: deliberately deaf to
                                                ; Left/Right. Clearing the history cannot be undone
                                                ; by arrowing back, so it takes the explicit RETURN
                                                ; the row and its help line both name.
        }
    }

    ; ---------- the settings file ----------

    sub cfg_write(ubyte id) -> bool {
        ; Overwrite the cfg with one "key=<value>\r" line per setting. Kept in step with
        ; themes.cfg_read()'s parser - same keys, first letters distinct.
        ;
        ; CHDIR IN, THEN WRITE BY BARE NAME. Handing f_open_w an absolute path does not work here:
        ; a WRITE open lands the file in the CURRENT directory. It is the same rule op_copymove
        ; documents when it enters the destination folder before copying, and the reason hist_save
        ; chdirs before writing its ring.
        ;
        ; It failed DESTRUCTIVELY when it was wrong, which is why setup once looked like it "would
        ; not save": DOS SCRATCH *does* take a path, so the delete below removed the real cfg and
        ; the open that should have recreated it did nothing - losing the settings rather than
        ; failing to store them. Hence the bool return, and the message the caller prints.
        ubyte[80] savedir
        void strings.copy(diskio.curdir(), savedir)     ; transient buffer - copy before chdir'ing
        diskio.chdir(themes.progdir_cd())
        diskio.delete(themes.CFG_NAME)                  ; delete-then-create = portable overwrite
        void diskio.status()                            ; drop FILE NOT FOUND if it wasn't there
        bool ok = false
        if diskio.f_open_w(themes.CFG_NAME) {
            ubyte n = 0
            n = append_kv(n, "theme=", id)
            ubyte hw = 0
            if themes.hw_keys
                hw = 1
            n = append_kv(n, "hwkeys=", hw)             ; 1 = force the hardware CTRL keys
            ok = diskio.f_write(cfg_line, n)
            diskio.f_close_w()
        }
        diskio.chdir(savedir)                           ; leave the caller's cwd as we found it
        return ok
    }

    sub append_kv(ubyte n, str key, ubyte value) -> ubyte {
        ; append "key<digit>\r" to cfg_line at offset n, return the new offset. Every value here is
        ; a single digit (theme 1..5, flags 0/1), which keeps this trivial.
        ubyte j = 0
        while key[j] != 0 {
            cfg_line[n] = key[j]
            n++
            j++
        }
        cfg_line[n] = '0' + value
        n++
        cfg_line[n] = 13
        n++
        return n
    }

    ; ---------- the history-clearing action ----------

    sub do_clear_history() {
        ; delete every hist/<cat>.his file right away (no confirm), flash the result on the help
        ; rows for ~2s, then repaint. Nothing about this is saved - it has already happened.
        clear_history()
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        put_str_at(LABEL_COL, HELP_ROW, "History cleared.                                          ")
        put_str_at(LABEL_COL, HELP_ROW + 1, "                                                          ")
        set_color_run(LABEL_COL, SCR_W - 3, HELP_ROW, CB_HELP)
        ; ~2s at 60 Hz, or any key to dismiss sooner. Drain first: the RETURN that triggered this
        ; is often still queued and would blink the message away unread.
        while cbm.GETIN2() != 0 {
        }
        ubyte n
        for n in 0 to 119 {
            sys.waitvsync()
            if cbm.GETIN2() != 0
                break
        }
        draw_all()
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

    ; ---------- drawing ----------

    sub draw_all() {
        ; The whole screen is repainted on every keystroke. At 80x30 that is imperceptible, and it
        ; is what makes the theme preview honest: the bars, headers and help lines are redrawn in
        ; the palette that was just selected, not left over from the previous one.
        themes.apply_theme(theme_id)
        txt.color2(shared.CLR_FG, shared.CLR_BG)
        txt.clear_screen()

        bar_fill(0, CB_BAR)
        put_str_centered(0, "XFMGR  Settings")
        set_color_run(0, SCR_W - 1, 0, CB_BAR)

        put_str_at(2, 3, "Up/Down picks a setting.  Left/Right changes it.")
        set_color_run(0, SCR_W - 1, 3, CB_BODY)

        draw_header(7,  "Display")
        draw_header(10, "Keyboard")
        draw_header(13, "Maintenance")

        ubyte i
        for i in 0 to NSET - 1 {
            ubyte row = SET_ROW[i]
            when i {
                0 -> {
                    put_str_at(LABEL_COL, row, "Color theme")
                    put_str_at(VALUE_COL, row, themes.NAMES[theme_id - themes.FIRST])
                }
                1 -> {
                    put_str_at(LABEL_COL, row, "Command keys")
                    if themes.hw_keys
                        put_str_at(VALUE_COL, row, "Force hardware")
                    else
                        put_str_at(VALUE_COL, row, "Auto-detect   ")
                }
                ROW_HISTORY -> {
                    put_str_at(LABEL_COL, row, "Input history")
                    put_str_at(VALUE_COL, row, "RETURN clears it")
                }
            }
            ubyte c = CB_BODY
            if i == sel
                c = CB_SEL                          ; highlight the whole row, like XFMGR's pickers
            set_color_run(2, SCR_W - 3, row, c)
        }

        put_str_at(LABEL_COL, HELP_ROW,     HELP1[sel])
        put_str_at(LABEL_COL, HELP_ROW + 1, HELP2[sel])
        set_color_run(LABEL_COL, SCR_W - 3, HELP_ROW,     CB_HELP)
        set_color_run(LABEL_COL, SCR_W - 3, HELP_ROW + 1, CB_HELP)

        bar_fill(SCR_H - 1, CB_BAR)
        put_str_centered(SCR_H - 1, "Up/Dn Pick   Lt/Rt Change   F10 Save+Exit   Esc Cancel")
        set_color_run(0, SCR_W - 1, SCR_H - 1, CB_BAR)
    }

    sub draw_header(ubyte row, str s) {
        ; non-selectable section label. A short highlight chip at col 2 (never a full-width run, so
        ; it cannot be mistaken for a selected setting row) sets it apart from the settings below.
        put_str_at(2, row, s)
        set_color_run(2, 2 + lsb(strings.length(s)) - 1, row, CB_HDR)
    }

    sub alert_box(str msg) {
        ; a small centred message box (e.g. "Saving...") drawn over the settings screen, in the box
        ; colors of the current theme (same look as XFMGR's popups).
        ubyte mlen = lsb(strings.length(msg))
        ubyte w = mlen + 18                          ; msg + 2 spaces + 1 border each side, + 12 wider
        ubyte x0 = (SCR_W - w) / 2
        ubyte x1 = x0 + w - 1
        ubyte y0 = SCR_H / 2 - 2
        ubyte y1 = y0 + 4                            ; 5 rows tall
        ubyte r
        ubyte c
        for r in y0 to y1 {                          ; fill
            set_color_run(x0, x1, r, CB_BODY)
            for c in x0 to x1
                txt.setchr(c, r, sc:' ')
        }
        txt.setchr(x0, y0, SC_TL)                    ; corners + edges
        txt.setchr(x1, y0, SC_TR)
        txt.setchr(x0, y1, SC_BL)
        txt.setchr(x1, y1, SC_BR)
        for c in x0 + 1 to x1 - 1 {
            txt.setchr(c, y0, SC_H)
            txt.setchr(c, y1, SC_H)
        }
        for r in y0 + 1 to y1 - 1 {
            txt.setchr(x0, r, SC_V)
            txt.setchr(x1, r, SC_V)
        }
        set_color_run(x0, x1, y0, shared.CLR_BOX)
        set_color_run(x0, x1, y1, shared.CLR_BOX)
        for r in y0 + 1 to y1 - 1 {
            txt.setclr(x0, r, shared.CLR_BOX)
            txt.setclr(x1, r, shared.CLR_BOX)
        }
        ubyte mcol = x0 + (w - mlen) / 2                            ; centred message...
        ubyte mrow = (y0 + y1) / 2
        put_str_at(mcol, mrow, msg)
        set_color_run(mcol, mcol + mlen - 1, mrow, CB_BODY)         ; ...recolored to the box interior
    }

    sub put_str_at(ubyte col, ubyte row, str s) {
        txt.plot(col, row)
        txt.print(s)
    }

    sub put_str_centered(ubyte row, str s) {
        ; centre s across the full screen width - used for the title and key-hint BARS, which span
        ; the whole row. The settings, their headers and the help lines stay left-aligned: they are
        ; a column of related rows and centring each one would ragged them against each other.
        ubyte n = lsb(strings.length(s))
        ubyte col = 0
        if n < SCR_W
            col = (SCR_W - n) / 2
        put_str_at(col, row, s)
    }

    sub set_color_run(ubyte c0, ubyte c1, ubyte row, ubyte color) {
        ubyte c
        for c in c0 to c1 {
            if c < SCR_W
                txt.setclr(c, row, color)
        }
    }

    sub bar_fill(ubyte row, ubyte color) {
        ubyte c
        for c in 0 to SCR_W - 1 {
            txt.setchr(c, row, sc:' ')
            txt.setclr(c, row, color)
        }
    }

    sub getkey() -> ubyte {
        repeat {
            ubyte k = cbm.GETIN2()
            if k != 0
                return k
        }
    }

    ; ---------- machine state + the hand-off back to XFMGR ----------

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
