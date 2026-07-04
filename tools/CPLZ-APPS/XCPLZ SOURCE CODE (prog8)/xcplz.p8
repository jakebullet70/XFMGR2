%encoding iso
%option no_sysinit
%import textio
%import conv
%import diskio
%import strings
%import sprites
%import floats
%import verafx
%import lzcommon
%import cpio
%import LZFILES
%zeropage basicsafe
%zpreserved $22, $40

ROM {
      ubyte VERSION
      bool  IsPreRelease
}

PENV {
           str HOST = "?"*5
           str PETSCII_VERSTR="VER \x991.\x990 "
           str ISOASC_VERSTR="\x05 Ver \x991.0 "
           str CPU="\x9B65\x99C\x9B02\x00" + "?"*2
           uword cpu=6502
           bool IS_HOST
           bool ON_HARDWARE
           bool ON_EMU
           sub FIND_CPU() { if sys.cpu_is_65816() { strings.copy("\x9B65\x99816",CPU) cpu=816} }
           sub IS_HOST_FS()-> bool {
               cbm.SETNAM(11, "$")
               cbm.SETLFS(11, 8, 0)
               cbm.OPEN()
               cbm.CHKIN(11)
               ubyte ctr = 0
               while ctr<2 { if cbm.GETIN2()==34 {ctr++} }
               void cbm.GETIN2()
               for ctr in 0 to 3 {HOST[ctr] = cbm.GETIN2()}
               HOST[4] = 0
               cbm.CLRCHN()
               cbm.CLOSE(11)
               return ((HOST=="HOST") and ON_EMU)
             }

&ubyte EMUIndicator1 = $9FBE
&ubyte EMUIndicator2 = $9FBF

sub GetRunEnvironment() {
         FIND_CPU()
         ROM.VERSION, ROM.IsPreRelease = cx16.rom_version()
         ON_EMU = ( (EMUIndicator1==49) and (EMUIndicator2==54) )
         IS_HOST=IS_HOST_FS()
         ON_HARDWARE = not ON_EMU
     }
}


main  {

const uword joystick_get = $FF56
uword tmpw
uword tmpw2
alias i = lzcommon.i
ubyte drivenumber = 8
str AnyMessage = iso:"\x9BAny \x05KEY\x9B to continue\x99."

alias f_size_low = cx16.r2
alias f_size_high = cx16.r3

ubyte[85] butterfly = [$8F,$93,$9C,$12,$DF,$92,$20,$20,$20,$20,$20,$12,$A9,$0D,$9A,$12,$A5,$DF,$92,$20,$20,$20,$12,$A9,$A7,
                       $92,$0D,$9F,$12,$B5,$20,$DF,$92,$20,$12,$A9,$20,$B6,$0D,$1E,$20,$B7,$12,$BB,$92,$20,$12,$AC,$92,$B7,
                       $0D,$9E,$20,$AF,$12,$BE,$92,$20,$12,$BC,$92,$AF,$0D,$81,$AA,$12,$20,$92,$A9,$20,$DF,$12,$20,$92,$B4,
                       $0D,$1C,$B6,$A9,$20,$20,$20,$DF,$B5,0]

asmsub Flush15() clobbers(A,X,Y) {
  %asm {{
          ldx #15
          jsr cbm.CHKIN
          jmp p8s_FExists.flushchars
       }}
}

asmsub FExists(uword FName @ XY, ubyte NameLength @ A) clobbers(A,X,Y) -> bool @Pc  {
   %asm  {{
             jsr cbm.SETNAM
             lda #11
             ldx p8v_drivenumber
             ldy #0
             jsr cbm.SETLFS
             jsr cbm.OPEN
             lda #11
             jsr cbm.CLOSE
             lda #0
             ldx #<dummy
             ldy #>dummy
             jsr cbm.SETNAM
             lda #15
             ldx p8v_drivenumber
             ldy #15
             jsr cbm.SETLFS
             jsr cbm.OPEN
             ldx #15
             jsr cbm.CHKIN
             jsr cbm.GETIN
             cmp #"0"
             bne NotFound
             jsr cbm.GETIN
             cmp #"0"
             beq Found
NotFound:    jsr flushchars
             clc
             rts
Found:       jsr flushchars
             sec
             rts
flushchars:  jsr cbm.GETIN
             cmp #13
             bne flushchars
             lda #15
             jsr cbm.CLOSE
             jsr cbm.CLRCHN
             jmp cbm.READST
dummy        .byte 0
; !notreached!
          }}
}

str TMPFILE = "?"*128

sub directory() -> bool {
        ubyte @zp lastchar = 1
        bool inquote = false

        ; -- Prints the directory contents to the screen. Returns success.

        cbm.SETNAM(11, "$:*=P")
internal_dir:
        cbm.SETLFS(11, drivenumber, 0)
        ubyte status = 1
        void cbm.OPEN()          ; open 11,8,0,"$"
        if_cs
            goto io_error

        %asm {{
                ldx #11
                jsr cbm.CHKIN
             }}

        repeat 4 {
            void cbm.CHRIN()     ; skip the 4 prologue bytes
        }

        ; while not stop key pressed / EOF encountered, read data.
        status = cbm.READST()
        if status!=0 {
            status = 1
            goto io_error
        }
        ubyte LineCount = 0
        while status==0 {
            ubyte low = cbm.CHRIN()
            ubyte high = cbm.CHRIN()
            if LineCount == 27 { txt.print("\x0D\x99...\x96more  \x99[\x9ELeft\x9F-\x9ECtrl\x99]     [\x9EENTER\x99] \x9F- \x05Done")
                          %asm {{
getnextbut:                      lda #0
                                 jsr p8c_joystick_get
                                 and #%00010000
                                 beq p8l_io_error
                                 txa
                                 and #128
                                 bne getnextbut
donewaitlist:                    nop
                               }}
                             txt.print("\x0D")
                                 LineCount=0}
            ubyte @zp character
            i = 0
            repeat {
                character = cbm.CHRIN()
                if character==0
                    break
                if character == 34 { inquote = not inquote }
                if inquote and character != 34 { TMPFILE[i] = character i++ }
            }
            TMPFILE[i] = 0
            ISOUpper(TMPFILE)
skipPartCMP:
            if strings.compare(&TMPFILE + (i-4) as uword,"LZ16") == 0 {
               txt.print(" \x9E") txt.print_uw(mkword(high, low)) txt.column(10)
               txt.color(3)
               txt.print(TMPFILE) LineCount++ txt.nl()
            }

            if strings.compare(&TMPFILE + (i-4) as uword,"CPIO") == 0 {
               txt.print(" \x9E") txt.print_uw(mkword(high, low)) txt.column(10)
               txt.color(14)
               txt.print(TMPFILE) LineCount++ txt.nl()
            }

            void cbm.CHRIN()     ; skip 2 bytes
            void cbm.CHRIN()
            status = cbm.READST()
            void cbm.STOP()
breaker:
            if_z
                break
        }
        status = cbm.READST()

io_error:
        %asm {{                                 ; restore default i/o devices
               jsr cbm.CLRCHN
               lda #11
               jsr cbm.CLOSE
             }}
        if status!=0 and status & $40 == 0 {            ; bit 6=end of file
            txt.print("\ni/o error, status: ")
            txt.print_ub(status)
            txt.nl()
            return false
        }
        return true
}

sub ShowDirectory_LIST() {
       txt.clear_screen()
       txt.print("\x0D\x05")
       directory();
       %asm {{
gl:            jsr cbm.GETIN
               bne gl
            }}
       txt.print("\x0D\x0D")
       WaitForKey_RestoreColor()
}

sub MyPlot(ubyte y, ubyte x) {
    txt.row(y)
    txt.column(x)
}

sub ProgramBanner() {
    i=0
    repeat 85 { cbm.CHROUT(butterfly[i]) i +=1 }
    MyPlot(1,10)
    txt.print ("\x9C*\x9A*\x99* \x05X16 FILE DECOMPRESSOR/DEARCHIVER ") txt.print(PENV.PETSCII_VERSTR) txt.print(" \x9E*\x81*\x1C*\x05")
    MyPlot(2,14)
    txt.print("\x05CPU\x1E:\x9B") txt.print(PENV.CPU) txt.print("\x05  ")
    if PENV.ON_EMU { txt.print("EMULATOR") } else { txt.print("HARDWARE") }
    MyPlot(3,10)
    txt.print ("\x9BAUTHOR\x1E: \x05ANTHONY W. HENRY")
    MyPlot(5,10)
    txt.print("\x9ETHIS SOFTWARE IS UNDER THE MIT LICENSE")
    MyPlot(6,10)
    txt.print("    \x05(\x9BPERMISSIVE\x05)")
}

sub ISOUpper(str s) {
  i=0
  while s[i] != 0 {
      if s[i] > 96 and s[i]<123 { s[i] -= 32 }
      i+=1
    }
}

sub FILE_EXT(str F) -> str {
str tmpE="?"*6
bool GotE
ubyte L

    L = strings.length(F)
    i = L
    do {
      GotE = (F[i]=='.')
      if not GotE { i-- }
    }  until i==0 or GotE
    if GotE {
       strings.right(F,L-i,tmpE)
    } else tmpE[0] =0
  return tmpE
}


sub FLOAT_TO_INT32(float src, ubyte[] target) {
    tmpw = src/65536.0 as uword
    target[3] = msb(tmpw)
    target[2] = lsb(tmpw)
    tmpw2 = (src - (tmpw as float * 65536.0)) as uword
    target[1] = msb(tmpw2)
    target[0] = lsb(tmpw2)
}

sub INT32_TO_FLOAT(ubyte[] src) -> float {
    tmpw = src[2] + (src[3] as uword * 256)
    return (src[0] as float) + (src[1] as float * 256.0) + (tmpw as float * 65536)
}

sub read4hex() -> uword {
    str hex = "0000"
    for cx16.r4L in 0 to 3 {
        hex[cx16.r4L] = cbm.CHRIN()
    }
    return conv.hex2uword(hex)
}

bool success
sub my_f_tell(ubyte channel) {
        ; gets the (32 bits) position + file size of the opened read file channel
        ubyte[2] command = ['T',0]
        command[1] = channel       ; f_open uses this secondary address
        cbm.SETNAM(sizeof(command), &command)
        cbm.SETLFS(15, drivenumber, 15)
        void cbm.OPEN()
        void cbm.CHKIN(15)        ; use #15 as input channel
        success=false
        ; valid response starts with "07," followed by hex notations of the position and filesize
        if cbm.CHRIN()=='0' and cbm.CHRIN()=='7' and cbm.CHRIN()==',' {
            cx16.r1 = read4hex()
            cx16.r0 = read4hex()        ; position in R1:R0
            void cbm.CHRIN()            ; separator space
            cx16.r3 = read4hex()
            cx16.r2 = read4hex()        ; filesize in R3:R2
            success = true
        }
        %asm {{ jmp p8s_Flush15 }}
    }


sub F_POS(ubyte channel) -> float {
    my_f_tell(channel)
    if success {
    return  ((cx16.r1 as float * 65536.0) + cx16.r0 as float) }
    else { return -1.0 }
}


sub f_seek(ubyte channel, float seekpos) {
        ; gets the (32 bits) position + file size of the opened read file channel
        cx16.r2 = floats.floor(seekpos/65536.0) as uword
        cx16.r1 = (seekpos - (cx16.r2 as float * 65536.0)) as uword
        cx16.r0 = mkword(channel,'P')   ; complete building the P command
        cbm.SETNAM(6, &cx16.r0)
        cbm.SETLFS(15, drivenumber, 15)
        void cbm.OPEN()
        %asm {{
              jmp p8s_Flush15
            }}
}


sub Print_RUN_Environment() {
  MyPlot(29,7)
  if PENV.ON_EMU and PENV.IS_HOST { txt.print("\x1C(\x99HOST \x05File System\x1C)") } else { txt.print("\x1C(\x99Fat\x1E32 \x05File System\x1C)") }

  MyPlot(28,1)
  txt.print(PENV.CPU)
  txt.print("  ") txt.print ("\x9BOn\x1E: \x05")
  if PENV.ON_EMU { txt.print("X16 Emulator") }
  if PENV.ON_HARDWARE { txt.print("X16 Hardware") }
  txt.print("  ")
  txt.print("\x9BROM\x1E: \x9Cr\x99") txt.print(conv.str_ub(ROM.VERSION))
  if ROM.IsPreRelease { txt.print("\x1E(\x9BPre-Release\x1E)") }
}

sub WaitForKey_RestoreColor() {
   txt.print(AnyMessage)
   txt.waitkey()
   txt.color2(1,6)
}

sub BAD_ROM_MESSAGE() {
       txt.print("\x07\x0D\x9B   THIS PROGRAM \x05REQUIRES\x9B ROM VERSION \x99R\x0549 \x9BOR \x05 HIGHER\x96 !")
       txt.print("\x0D\x05   VERSION\x1E: \x99") txt.print(conv.str_ub(ROM.VERSION)) txt.print("\x9B WAS FOUND.\x0D")
       if ROM.IsPreRelease { txt.print("\x0D\x05   PRE-RELEASE ROM\x0D") }
}

bool IS_CPIO
bool IS_LZ16
str F_EXTENSION = "?"*8

str INPUTNAME="?"*255

sub GetFILENAME_FromUser() {
bool GOTIT
    IS_LZ16 = false
    IS_CPIO = false
    txt.cp437()
GOGET:
    txt.color2(1,6)
    txt.clear_screen()
    MyPlot(2,2)
    txt.print ("\x9C*\x9A*\x99* \x05X16 \x99lz16 \x1C& \x99cpio \x05File Decompressor\x1C/\x05Extractor \x9E*\x81*\x1C*")
    MyPlot(3,2)
      txt.print ("    \x05Version\x1E: ") txt.print(PENV.ISOASC_VERSTR)

    MyPlot(8,1)
    txt.print("\x0D\x0D  \x99[\x05LIST\x99] \x9Bfor a Archive & Compressed File Listing \x1E(\x9E*.LZ16\x1C/\x9E*.CPIO\x1E)\x0D")
    txt.print("\x0D\x0D  \x99[\x05EXIT\x99] \x9Bto close program and abort \x9B!\x05\x0D")
    MyPlot(7,1)
    txt.print(" \x05Enter complete File Name\x1E:\x9E ")
    INPUTNAME[0]=0
    txt.input_chars(&INPUTNAME)
    ISOUpper(INPUTNAME)

    if strings.compare(INPUTNAME,"LIST")==0 {
       ShowDirectory_LIST()
       goto GOGET
    }

    if strings.compare(INPUTNAME,"EXIT")==0 { txt.clear_screen() txt.nl() txt.print(" \x0D\x05DONE !\x0D") cx16.enter_basic(false) }

    strings.copy(FILE_EXT(INPUTNAME),F_EXTENSION)

    if (strings.compare(F_EXTENSION,".CPIO")==0) { IS_CPIO = true }

    if (strings.compare(F_EXTENSION,".LZ16")==0) { IS_LZ16 = true }

    GOTIT = (IS_CPIO or IS_LZ16) and FExists(INPUTNAME,strings.length(INPUTNAME))

    if not GOTIT {
       MyPlot(7,1)
       txt.print(" \x96") txt.print(INPUTNAME) txt.print(" \x05Not a valid compressed or archive file \x96!\x07")
       sys.wait(240)
       goto GOGET
    }
}



alias hideGraphicsLayer = lzcommon.hideGraphicsLayer

alias showGraphicsLayer = lzcommon.showGraphicsLayer
alias hideTextLayer = lzcommon.hideTextLayer
alias showTextLayer = lzcommon.showTextLayer
alias HideBothLayers = lzcommon.HideBothLayers

alias ShowBothLayers = lzcommon.ShowBothLayers


ubyte UP_Choice
bool Do_Blank
ubyte CCOUNT
float Current_CHK
float END_CHK

sub FlushKeys() {
    while cbm.GETIN2() > 0 { %asm {{ nop }} }
}

sub Yes(ubyte y @R9, ubyte x @R10) -> bool {
  ubyte InChar=0
  ubyte StoredChar=32

  printit:
     MyPlot(y, x)
     cbm.CHROUT(StoredChar)
  skipprint:
     InChar = cbm.GETIN2()
     if InChar==217 or InChar==121 { InChar=89 }  ; force PETSCII or ISO to UpperCase for Y
     if InChar==110 or InChar==206 { InChar=78 }  ; ditto for N
     when InChar {
         0 -> { goto skipprint }
     89,78 -> { StoredChar=InChar goto printit }
        27 -> { StoredChar = 78 }
        13 -> { if not (StoredChar==89 or StoredChar==78) { cbm.CHROUT(7) goto skipprint }  }
      else -> { cbm.CHROUT(7) goto skipprint }
    }
    return (StoredChar==89)
}

ubyte Cx
ubyte Cy
sub Get_TIMESTAMP_Choice(str ARCNAME) {
    txt.clear_screen()
    MyPlot(9,1)
    txt.color2(0,3)
    if PENV.IS_HOST {
       MyPlot(3,1)
       txt.print("                                                      ")
       cbm.CHROUT(7)
       MyPlot(4,1)
       txt.print(" FILE TIME STAMPS NOT PRESERVED ON EMULATOR HOST FS ! ")
       MyPlot(5,1)
       txt.print("                                                      ")
       sys.wait(180)
       cpio.TIME_PRESERVE = false ; even if TRUE the method
                                  ; used for time stamping files
                                  ; does not work on the emu HOSTFS
       goto NOSTAMP
    }
    txt.print("  If Choosing Yes and you lose power or abort, then    ")
    MyPlot(10,1)
    txt.print("  the system Clock & Date may be left set incorrectly! ")
    MyPlot(11,1)
    txt.print("  CLOCK is reset properly on successful completion.    ")
    txt.color2(1,6)
    MyPlot(2,0)
    txt.print("  \x9BPreparing extraction from \x1E-\x99> \x05") txt.print(ARCNAME)
    repeat 3 { txt.nl() }
    txt.print(" \x9B Preserve Archive Time Stamps \x99? \x05")
    txt.print( " \x1E<\x05Y\x1E>\x9Bes\x81/\x1E<\x05N\x1E>\x9Bo \x81-\x9E>  ")
    Cy,Cx = cbm.PLOT(Cy, Cx,true)
    txt.color2(7,0)
    cpio.TIME_PRESERVE = Yes(Cx,Cy)
NOSTAMP:
    txt.color2(1,6)
}

sub start() {
    cx16.set_screen_mode(1)
    PENV.GetRunEnvironment()
    if ROM.VERSION < 49 { BAD_ROM_MESSAGE() txt.nl() cx16.enter_basic(false) }
    ProgramBanner()
    sys.wait(220)
RESTART:
    GetFILENAME_FromUser()
    diskio.fastmode(3)
    void diskio.status()
    if IS_CPIO {
       Get_TIMESTAMP_Choice(INPUTNAME)
       cpio.HANDLE_FILE(INPUTNAME)
    }

    if IS_LZ16 {
       LZFILES.HANDLE_FILE(INPUTNAME)
       if LZFILES.OUTPUT_IS_ARCHIVE {
          Get_TIMESTAMP_Choice(LZFILES.OUTNAME)
          cpio.HANDLE_FILE(LZFILES.OUTNAME)
          txt.nl()
          txt.print(" \x9BRemove uncompressed archive \x1E-\x99> \x05") txt.print(LZFILES.OUTNAME)
          txt.nl()
          txt.print( " \x1E<\x05Y\x1E>\x9Bes\x81/\x1E<\x05N\x1E>\x9Bo \x81-\x9E>  ")
          txt.color2(5,0)
          Cy,Cx = cbm.PLOT(Cy, Cx,true)
          if Yes(Cx,Cy) {
             diskio.delete(LZFILES.OUTNAME)
             txt.color2(1,6)
             txt.print("\x0D\x0D  \x9BRemoved\x1E:\x99 ") txt.print(LZFILES.OUTNAME)
             txt.nl()
          }
          txt.color2(1,6)
       }
    }

theend:
ALLDONE:
void diskio.status()
txt.nl()
txt.print("\x0D \x05 Restart System \x99?  ")
Cy,Cx = cbm.PLOT(Cy, Cx,true)
txt.color2(7,0)
if Yes(Cx,Cy) { txt.color2(1,6) cx16.enter_basic(true) }
txt.color2(1,6)
txt.print("\x0D\x0D")
over:
%asm {{ nop }}

}
}
