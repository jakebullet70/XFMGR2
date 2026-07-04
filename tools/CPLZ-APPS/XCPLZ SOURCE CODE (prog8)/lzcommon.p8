%import textio
%import conv
%encoding iso


Errors {

sub Halt(str Msg) {
ubyte LF

    cbm.CLRCHN()
    for LF in 0 to 15 {
      cbm.CLOSE(LF)
    }
    void diskio.status()
    txt.print("\x07\x0D\x0D")
    txt.print(" \x05ERROR HALT\x99:\x05 ")
    txt.print(Msg)
    txt.nl() txt.nl()
    cx16.enter_basic(false)
}

}

lzcommon {

ubyte @zp i
ubyte drivenumber = 8

sub MyPlot(ubyte y, ubyte x) {
    txt.row(y)
    txt.column(x)
}


sub ISOUpper(str s) {
  i=0
  while s[i] != 0 {
      if s[i] > 96 and s[i]<123 { s[i] -= 32 }
      i+=1
    }
}


sub read4hex() -> uword {
    str hex = "0000"
    for cx16.r4L in 0 to 3 {
        hex[cx16.r4L] = cbm.CHRIN()
    }
    return conv.hex2uword(hex)
}


sub FlushKeys() {
    while cbm.GETIN2() > 0 { %asm {{ nop }} }
}

sub hideGraphicsLayer() {
    cx16.VERA_DC_VIDEO = cx16.VERA_DC_VIDEO & 239
}

sub showGraphicsLayer() {
    cx16.VERA_DC_VIDEO = cx16.VERA_DC_VIDEO | 16
}

sub hideTextLayer() {
    cx16.VERA_DC_VIDEO = cx16.VERA_DC_VIDEO & 223
}

sub showTextLayer() {
    cx16.VERA_DC_VIDEO = cx16.VERA_DC_VIDEO | 32
}

sub HideBothLayers() {
    hideGraphicsLayer()
    hideTextLayer()
}

sub ShowBothLayers() {
    showGraphicsLayer()
    showTextLayer()
}

}
