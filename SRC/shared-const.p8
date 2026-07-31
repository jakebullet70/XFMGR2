; shared-const - color palette and other global constants shared between XFMGR (xfmgr.p8)
; and the banked text-viewer overlay (tview.p8). Import in both with:  %import "shared-const"
; (quoted because the filename has a hyphen, which a bare %import identifier can't contain).
;
; CONSTANTS ONLY. Consts are compile-time values that emit NO code or data, so importing this
; into both programs costs zero bytes in either binary - and it is safe inside tview's
; %output library / %zeropage dontuse overlay (nothing to relocate, no zeropage use).

shared {
    %option ignore_unused               ; not every constant is used by both importers

    ; X16 default 16-color palette indices used here:
    ;   0=black  1=white  6=blue  7=yellow  11=dark gray  14=light blue
    ; A textio color BYTE is (bg<<4)|fg; txt.color2(fg,bg) sets both nibbles.

    ; --- semantic single-nibble colors (pass as fg or bg to txt.color2) ---
    const ubyte CLR_FG     = 1          ; body text: white
    const ubyte CLR_BG     = 11         ; field / content area: dark gray
    const ubyte CLR_ACCENT = 7          ; hotkey letters (main menus): yellow
    const ubyte CLR_TITLE  = 14         ; window / box titles + status bars: light blue
    const ubyte BLACK      = 0          ; black

    ; --- combined attribute bytes (bg<<4)|fg ---
    const ubyte CLR_BOX    = $be        ; frame / box borders: light blue on dark gray
    const ubyte HILITE     = $e1        ; focused selection bar: light-blue bg, white text
    const ubyte CLR_TAGROW = $e1        ; tagged file row: blue bg, white text
    const ubyte CLR_BOTTOM_PROMPT_BG  = $10   ; bottom prompt/dialog box: black text on white bg
    const ubyte CLR_BOTTOM_PROMPT_KEY = $1e   ; bottom prompt/dialog box: light-blue hotkey on white bg

    ; --- viewer (tview) status-bar theme: reuses the palette above ---
    const ubyte BAR_BG     = CLR_TITLE  ; status bar background: light blue
    const ubyte BAR_FG     = CLR_FG     ; status bar text: white
    const ubyte BAR_KEY    = CLR_BG     ; bottom-menu hotkey letters: dark gray (was yellow/black)
    const ubyte CONTENT_BG = CLR_BG     ; viewer content area: dark gray
    const ubyte FIND_FG    = BLACK      ; found-text highlight: black text ...
    const ubyte FIND_BG    = CLR_ACCENT ; ... on yellow, so a search hit stands out on the gray page

    ; --- syntax coloring (tview text pages + the xsyntax overlay) ---
    ; Full ATTRIBUTE bytes (bg<<4)|fg, not nibbles: the colorizer writes one of these per column
    ; and tview passes it straight to txt.setclr. Background is always the content field, so a
    ; colored cell sits flush with the rest of the page.
    ;
    ; Three of the six foregrounds are themed indices (1/7/14 - see themes.THEME_IDX), so they
    ; follow an Alt-F10 theme change for free. STRING/NUMBER/COMMENT use indices themes.p8 does
    ; NOT repaint, so they stay put across themes; re-check those three against Amber/Green Mono.
    const ubyte SYN_DEFAULT  = (CONTENT_BG << 4) | CLR_FG      ; plain text, vars, operators
    const ubyte SYN_KEYWORD  = (CONTENT_BG << 4) | CLR_TITLE   ; BASIC statements / md headings
    const ubyte SYN_FUNCTION = (CONTENT_BG << 4) | CLR_ACCENT  ; built-in functions / md subheadings
    const ubyte SYN_STRING   = (CONTENT_BG << 4) | 13          ; "quoted strings" - light green
    const ubyte SYN_NUMBER   = (CONTENT_BG << 4) | 10          ; numeric constants - light red
    const ubyte SYN_COMMENT  = (CONTENT_BG << 4) | 12          ; REM / ## to end of line - mid gray

    ; --- viewer text-page geometry ---
    ; Shared because xsyntax paints the color pass itself (it walks the same cells with the same
    ; wrap rule tview drew them with), so the two MUST agree on the layout byte for byte.
    const ubyte VIEW_TOP   = 1          ; first text row (row 0 = header bar)
    const ubyte VIEW_ROWS  = 27         ; text rows 1..27 (rows 28-29 are the viewer's 2-line footer)
    const ubyte VIEW_WIDTH = 79         ; wrap column (keep off col 79 to avoid auto-scroll)
    const ubyte VIEW_BOT   = 29         ; footer/status row (the find prompt draws here)
    ; the viewer's footer is TWO bars: keys on VIEW_FOOT1, search/set keys + status on VIEW_FOOT2
    const ubyte VIEW_FOOT1 = 28
    const ubyte VIEW_FOOT2 = 29

    ; Longest logical line the viewer colors. Both main-RAM host buffers (xfmgr's cm_src/cm_dst,
    ; 133 B each) must hold this plus slack; a longer line still DRAWS in full, its tail just stays
    ; default-colored. Shared so xfmgr's buffer sizing and tview's accumulator cap can't drift.
    const ubyte SYN_LINE_MAX = 128
}
