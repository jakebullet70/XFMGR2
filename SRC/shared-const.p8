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
    const ubyte OW_BLACK   = $10        ; overwrite box: black text on white bg
    const ubyte OW_KEY     = $1e        ; overwrite box: light-blue key on white bg

    ; --- viewer (tview) status-bar theme: reuses the palette above ---
    const ubyte BAR_BG     = CLR_TITLE  ; status bar background: light blue
    const ubyte BAR_FG     = CLR_FG     ; status bar text: white
    const ubyte BAR_KEY    = CLR_BG     ; bottom-menu hotkey letters: dark gray (was yellow/black)
    const ubyte CONTENT_BG = CLR_BG     ; viewer content area: dark gray
    const ubyte FIND_FG    = BLACK      ; found-text highlight: black text ...
    const ubyte FIND_BG    = CLR_ACCENT ; ... on yellow, so a search hit stands out on the gray page
}
