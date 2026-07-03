; themes - shared colour-theme + config module for XFMGR2 and the XFSETUP utility.
;
; Imported (compiled in) by BOTH SRC/xfmgr.p8 and SRC/xfsetup.p8 so the preset tables and the
; apply/config routines stay in one source of truth. NOT an overlay - plain inline code, so
; initialised tables here are fine (no %jmptable to shove).
;
; A "theme" repaints the VERA palette RGB of the handful of colour INDICES the UI draws with
; (see SRC/shared-const.p8). Because txt.color2() and the embedded \x9e/\x05 footer codes both
; select those same indices, remapping the palette re-themes the WHOLE UI with zero draw-code
; changes. apply_theme() always baselines from cx16.set_default_palette() (the exact ROM default,
; = the "Classic" theme) and then overlays the preset's overrides.
;
; NO %encoding directive here: this module does diskio with a literal filename ("xfmgr.cfg"), which
; must stay PETSCII like every other filename (the emulator host-fs matches petscii bytes). It
; prints no display text, so it never needs CP437.

%import diskio
%import strings

themes {
    %option ignore_unused

    const ubyte FIRST = 1               ; theme ids are 1..LAST (1 = Classic = ROM default)
    const ubyte LAST  = 5

    ; The UI colour INDICES a theme repaints (order matches the RGB rows below):
    ;   0  = black            (shared.BLACK)
    ;   1  = body text        (shared.CLR_FG)
    ;   7  = hotkey accent     (shared.CLR_ACCENT)
    ;   11 = field background  (shared.CLR_BG)
    ;   14 = titles / hilite   (shared.CLR_TITLE, and HILITE bg / CLR_BOX fg)
    ubyte[5] THEME_IDX = [0, 1, 7, 11, 14]

    ; RGB444 (0..15 each) for ids 2..5, five colours per theme, in THEME_IDX order.
    ; id 1 (Classic) has no row - it is just cx16.set_default_palette().
    ;                     black       FGtext       accent       field-bg     title/hilite
    ubyte[60] THEME_RGB = [
        0,0,0,      15,10,0,     15,12,3,     2,1,0,       12,8,0,        ; 2 Amber Mono
        0,0,0,      2,15,2,      8,15,8,      0,2,0,       1,10,1,        ; 3 Green Mono
        0,0,0,      11,13,15,    7,14,15,     1,3,10,      4,6,12,        ; 4 X16 Blue
        0,0,0,      15,15,15,    15,15,0,     0,0,0,       0,8,15         ; 5 High-Contrast
    ]

    ; theme display names (used by the XFSETUP menu; harmless dead data in xfmgr)
    str[5] NAMES = ["Classic", "Amber Mono", "Green Mono", "X16 Blue", "High-Contrast"]

    sub apply_theme(ubyte id) {
        ; Baseline every apply from the ROM default so switching themes (live preview) is clean,
        ; and so Classic / out-of-range restores the exact stock palette.
        cx16.set_default_palette()
        if id < 2 or id > LAST
            return
        ubyte base = (id - 2) * 15          ; 15 bytes (5 colours x rgb) per custom theme
        ubyte slot
        for slot in 0 to 4 {
            ubyte off = base + slot*3
            ubyte r = THEME_RGB[off]
            ubyte g = THEME_RGB[off+1]
            ubyte b = THEME_RGB[off+2]
            uword addr = $fa00 + (THEME_IDX[slot] as uword) * 2   ; VERA palette RAM $1FA00 + idx*2
            cx16.vpoke(1, addr, (g << 4) | b)   ; low byte = (G<<4)|B
            cx16.vpoke(1, addr+1, r)            ; high byte = 0000 R
        }
    }

    ; ---- config file: /xfmgr/xfmgr.cfg, a tiny "theme=N" text line ----
    ; The caller must have chdir'd into the program's /xfmgr/ folder first (same place the .bin
    ; overlays live). Filenames are PETSCII (module default) so the host-fs matches them.

    str  CFG_NAME = "xfmgr.cfg"
    ubyte[24] cfg_line                      ; f_readline scratch / write buffer

    sub cfg_read() -> ubyte {
        ; Return the saved theme id (1..LAST). Missing file / bad content -> 1 (Classic).
        ubyte id = 1
        if diskio.f_open(CFG_NAME) {
            uword ln
            ubyte st
            repeat {
                ln, st = diskio.f_readline(&cfg_line)
                if ln == 0
                    break                   ; EOF or empty
                ; parse "theme=N": find '=' then take the following digit
                ubyte p = 0
                while cfg_line[p] != 0 and cfg_line[p] != '='
                    p++
                if cfg_line[p] == '=' {
                    ubyte d = cfg_line[p+1]
                    if d >= '1' and d <= '9'
                        id = d - '0'
                }
                if st != 0
                    break
            }
            diskio.f_close()
        }
        if id < FIRST or id > LAST
            id = 1
        return id
    }

    sub cfg_write(ubyte id) {
        ; Overwrite /xfmgr/xfmgr.cfg with "theme=<id>\r". Delete-then-open for a portable overwrite
        ; (same trick hist_save uses).
        diskio.delete(CFG_NAME)
        if diskio.f_open_w(CFG_NAME) {
            void strings.copy("theme=", cfg_line)   ; 6 chars + NUL
            cfg_line[6] = '0' + id
            cfg_line[7] = 13                        ; CR
            void diskio.f_write(cfg_line, 8)
            diskio.f_close_w()
        }
    }
}
