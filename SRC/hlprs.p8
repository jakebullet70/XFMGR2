; hlprs - small shared screen helpers.

%import textio

hlprs {
    %option ignore_unused

    sub clear_section(ubyte col, ubyte row, ubyte width, ubyte height, ubyte colors) {
        ; fill a rectangular region with spaces in the given colour
        ; (high nibble = background, low nibble = foreground)
        txt.color2(colors & 15, colors >> 4)
        repeat height {
            txt.plot(col, row)
            repeat width
                txt.chrout(' ')
            row++
        }
    }

/*  sub clr_section(ubyte col, ubyte row, ubyte width, ubyte height, ubyte colors) {
        ; recolour a rectangular region in place: set bg+fg on the existing cells,
        ; leaving the characters untouched (high nibble = background, low nibble = foreground)
        repeat height {
            ubyte i = 0
            repeat width {
                txt.setclr(col + i, row, colors)
                i++
            }
            row++
        }
    } */
}
