; themes - shared color-theme + config module for XFMGR2 and the XFSETUP utility.
;
; Imported (compiled in) by BOTH SRC/xfmgr.p8 and SRC/xfsetup.p8 so the preset tables and the
; apply/config routines stay in one source of truth. NOT an overlay - plain inline code, so
; initialised tables here are fine (no %jmptable to shove).
;
; A "theme" repaints the VERA palette RGB of the handful of color INDICES the UI draws with
; (see SRC/shared-const.p8). Because txt.color2() and the embedded \x9e/\x05 footer codes both
; select those same indices, remapping the palette re-themes the WHOLE UI with zero draw-code
; changes. apply_theme() always baselines from cx16.set_default_palette() (the exact ROM default,
; = the "Classic" theme) and then overlays the preset's overrides.
;
; NO %encoding directive here: this module does diskio with a literal filename ("xfmgr.cfg"), which
; must stay PETSCII like every other filename (the emulator host-fs matches petscii bytes). It
; prints no display text, so it never needs CP437.

%import diskio_patched     ; vendored + bounds-patched diskio (block still named 'diskio'); see its header
%import strings
; (no textio: the cfg-not-found DEBUG block that needed it is gone - it froze the program in a
;  bare `repeat {}` whenever xfmgr.cfg was missing, which find_progdir's absolute paths now fix)

themes {
    %option ignore_unused

    const ubyte FIRST = 1               ; theme ids are 1..LAST (1 = Classic = ROM default)
    const ubyte LAST  = 5

    ; The UI color INDICES a theme repaints (order matches the RGB rows below):
    ;   0  = black / drop-shadow (shared.BLACK; box_shadow recolors cells to index 0, so a theme
    ;                          with a pure-black field-bg must give index 0 a dark grey or the box
    ;                          shadow is invisible - see High-Contrast below)
    ;   1  = body text        (shared.CLR_FG)
    ;   7  = hotkey accent     (shared.CLR_ACCENT)
    ;   11 = field background  (shared.CLR_BG)
    ;   14 = titles / hilite   (shared.CLR_TITLE, and HILITE bg / CLR_BOX fg)
    ubyte[5] THEME_IDX = [0, 1, 7, 11, 14]

    ; RGB444 (0..15 each) for ids 2..5, five colors per theme, in THEME_IDX order.
    ; id 1 (Classic) has no row - it is just cx16.set_default_palette().
    ;                     black       FGtext       accent       field-bg     title/hilite
    ubyte[60] THEME_RGB = [
        0,0,0,      15,10,0,     15,15,8,     2,1,0,       7,4,0,         ; 2 Amber Mono
        0,0,0,      2,15,2,      8,15,8,      0,2,0,       1,10,1,        ; 3 Green Mono
        0,0,0,      11,13,15,    15,13,2,     0,1,6,       3,6,13,        ; 4 X16 Blue
        4,4,4,      15,15,15,    15,15,0,     0,0,0,       0,8,15         ; 5 High-Contrast (idx0 dark grey = visible drop-shadow on the black field)
    ]

    ; theme display names (used by the XFSETUP menu; harmless dead data in xfmgr)
    str[5] NAMES = ["Classic", "Amber Mono", "Green Mono", "X16 Blue", "High-Contrast"]

    sub apply_theme(ubyte id) {
        ; Baseline every apply from the ROM default so switching themes (live preview) is clean,
        ; and so Classic / out-of-range restores the exact stock palette.
        cx16.set_default_palette()
        if id < 2 or id > LAST
            return
        ubyte base = (id - 2) * 15          ; 15 bytes (5 colors x rgb) per custom theme
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
    ; The caller must have chdir'd into the program's /xfmgr/ folder first (same place the .ovl
    ; overlays live). Filenames are PETSCII (module default) so the host-fs matches them.

    str  CFG_NAME = "xfmgr.cfg"
    ubyte[24] cfg_line                      ; cfg load buffer (read) / write buffer

    ; ---- where the program lives (cfg + the .ovl overlays) ----
    ; NOT hard-coded: the root launcher `XT` (a tokenized `10 LOAD"/XFMGR/XFMGR.PRG"`) already names
    ; the folder XFMGR was installed into, so we read the path out of ITS quotes and keep everything
    ; up to the last '/'. That makes the install location the installer's business alone - move the
    ; programs, point XT at them, and the cfg + every overlay follow automatically. Ported from
    ; x16-MSEDIT's SRC/theme.p8 (find_progdir / path_to), which does the same with its `ED` launcher.
    ;
    ; The bytes inside XT are the same PETSCII our string literals compile to (both put a-z at
    ; $41-$5A), so the path can be copied straight out with no re-encoding.
    ;
    ; There is deliberately NO save/restore of the working directory anywhere below, and none is
    ; needed: XT is read via an ABSOLUTE path ("/xt") and the folder parsed out of it is absolute
    ; too, so every path path_to() builds resolves the same whatever cwd we were launched in. That
    ; replaced an 80-byte savedir buffer and a chdir dance in cfg_read.
    str  XT_NAME  = "/xt"                   ; the launcher, at the fsroot ROOT. ABSOLUTE on purpose:
                                            ; it must be readable no matter which folder we were
                                            ; launched from, and a bare "xt" would miss it.
    str  DEF_DIR  = "/xfmgr/"               ; fallback when XT is missing/unparsable. Matches what the
                                            ; installer creates, and what the old hard-coded
                                            ; chdir("/xfmgr") assumed - so this is never a regression.
    str  progdir  = "?" * 32                ; install folder incl. trailing slash (empty = at root)
    str  progpath = "?" * 44                ; progdir + a filename, built by path_to()
    ubyte[32] xtbuf                         ; XT launcher load buffer (the launcher is 28 bytes)
    bool dir_known = false

    sub find_progdir() {
        ; Parse the install folder out of the root XT launcher; called once, lazily, by path_to().
        dir_known = true
        void strings.copy(DEF_DIR, progdir)
        uword endaddr = diskio.load_raw(XT_NAME, &xtbuf)
        if endaddr == 0 {
            void diskio.status()            ; drop the FILE NOT FOUND (else the activity LED blinks)
            return                          ; no launcher -> keep DEF_DIR
        }
        ubyte n = lsb(endaddr - &xtbuf)
        if n > 32
            n = 32
        ; the quoted path inside the tokenized BASIC line:  LOAD "<path>"
        ubyte i = 0
        while i < n and xtbuf[i] != $22                 ; opening quote
            i++
        if i >= n
            return                                      ; no quote -> keep DEF_DIR
        i++
        ubyte j = 0
        ubyte cut = 0                                   ; chars up to and including the LAST '/'
        while i < n and xtbuf[i] != $22 and j < 31 {
            progdir[j] = xtbuf[i]
            j++
            if xtbuf[i] == '/'
                cut = j
            i++
        }
        progdir[cut] = 0                                ; drop the filename, keep the folder
    }

    sub progdir_cd() -> str {
        ; The install folder with the trailing '/' stripped, ready for chdir().
        ; Why this exists: CMDR-DOS `CD:` accepts a whole path, but `MD` is `MD[path]:name` - the
        ; path goes BEFORE the colon, and diskio.mkdir() only ever emits "md:"+name. So a caller
        ; that needs to CREATE a subfolder must chdir here first and then mkdir RELATIVELY;
        ; mkdir("/xfmgr/hist") would ask for a directory whose *name* contains slashes.
        ; ("/" at the root stays "/" - a bare "" is not a valid chdir target.)
        if not dir_known
            find_progdir()
        void strings.copy(progdir, progpath)
        ubyte n = lsb(strings.length(progpath))
        if n > 1 and progpath[n-1] == '/'
            progpath[n-1] = 0
        return progpath
    }

    sub path_to(str fname) -> str {
        ; progdir + fname, e.g. "/xfmgr/" + "tview.ovl". NOTE: one shared buffer - consume the
        ; result before the next path_to() call (every caller passes it straight into a disk call).
        if not dir_known
            find_progdir()
        void strings.copy(progdir, progpath)
        void strings.append(progpath, fname)
        return progpath
    }

    sub cfg_read() -> ubyte {
        ; Return the saved theme id (1..LAST). Missing file / bad content -> 1 (Classic).
        ; Reads <progdir>xfmgr.cfg by ABSOLUTE path (see find_progdir), so it needs no chdir and
        ; leaves the caller's working directory untouched. Uses the headerless KERNAL LOAD
        ; (diskio.load_raw - the same cbm.LOAD the overlays' loadlib uses, just the honest name for
        ; raw data rather than a library blob); NEVER f_open, whose read-channel traffic on an
        ; ABSENT file corrupted the following UI draw / bottom-menu colors. load_raw returns 0 when
        ; the file isn't there.
        ubyte id = 1
        uword endaddr = diskio.load_raw(path_to(CFG_NAME), &cfg_line)
        if endaddr != 0 {
            @(endaddr) = 0                  ; NUL-terminate the loaded bytes for the parser
            ; parse "theme=N": find '=' then take the following digit
            ubyte p = 0
            while cfg_line[p] != 0 and cfg_line[p] != '='
                p++
            if cfg_line[p] == '=' {
                ubyte d = cfg_line[p+1]
                if d >= '1' and d <= '9'
                    id = d - '0'
            }
        }
        if id < FIRST or id > LAST
            id = 1
        return id
    }

    sub cfg_write(ubyte id) {
        ; Overwrite <progdir>xfmgr.cfg with "theme=<id>\r". Delete-then-open for a portable
        ; overwrite (same trick hist_save uses). Absolute path -> no chdir needed, and the caller's
        ; working directory is left alone. path_to() is called twice rather than stashing its result
        ; in another 44-byte buffer: it rebuilds the same string deterministically, so the second
        ; call is just a strings.copy+append - far cheaper than the RAM here.
        diskio.delete(path_to(CFG_NAME))
        if diskio.f_open_w(path_to(CFG_NAME)) {
            void strings.copy("theme=", cfg_line)   ; 6 chars + NUL
            cfg_line[6] = '0' + id
            cfg_line[7] = 13                        ; CR
            void diskio.f_write(cfg_line, 8)
            diskio.f_close_w()
        }
    }
}
