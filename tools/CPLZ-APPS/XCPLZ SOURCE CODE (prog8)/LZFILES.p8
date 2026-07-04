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
%zeropage basicsafe
%zpreserved $22, $40


LZFILES {


alias FlushKeys = lzcommon.FlushKeys
alias ISOUpper = lzcommon.ISOUpper
alias MyPlot = lzcommon.MyPlot
alias HideBothLayers = lzcommon.HideBothLayers
alias hideTextLayer = lzcommon.hideTextLayer
alias hideGraphicsLayer = lzcommon.hideGraphicsLayer

alias showGraphicsLayer = lzcommon.showGraphicsLayer
alias showTextLayer = lzcommon.showTextLayer
alias ShowBothLayers = lzcommon.ShowBothLayers



str OUTNAME = "?"*128
str INNAME = "?"*255
str TEMP = "?"*255
ubyte INLFN = 10
ubyte OUTLFN = 9
ubyte DEVICE = 8
ubyte EOF
uword OUT_BUFFER
uword CURRENT_OUTSIZE
uword CURRENT_INSIZE
bool Do_Blank
bool Blanked
float Current_CHK
float END_CHK
bool OUTPUT_IS_ARCHIVE

sub OPEN_INPUT(str INFILE) -> bool {
    Blanked = false
    strings.copy(INFILE,INNAME)
    strings.copy(INNAME,TEMP)
    strings.append(TEMP,",S,R")
    cbm.SETLFS(INLFN,DEVICE,INLFN)
    cbm.SETNAM(strings.length(TEMP), TEMP)
    void cbm.OPEN()
    return zHDR.Read()
}

sub OPEN_OUTPUT() {
    strings.copy("@:",TEMP)
    strings.append(TEMP,OUTNAME)
    strings.append(TEMP,",S,W")
    cbm.SETLFS(OUTLFN,DEVICE,OUTLFN)
    cbm.SETNAM(strings.length(TEMP), TEMP)
    void cbm.OPEN()
}

sub CLOSE() {
    cbm.CLOSE(OUTLFN)
    cbm.CLOSE(INLFN)
}

sub READ_COMPRESSEDCHUNK(uword NumberOfBytes) {
uword BytesLeft
uword Bytes_TOGET
uword BytesRead
bool MACError

      BytesLeft = NumberOfBytes
      cbm.CHKIN(INLFN)
      cx16.VERA_CTRL = 0
      cx16.VERA_ADDR_L = 0
      cx16.VERA_ADDR_M = $00
      cx16.VERA_ADDR_H = %00010001
      cbm.CHKIN(INLFN)
       while BytesLeft > 0 {
            if BytesLeft > 512 { Bytes_TOGET = 0} else { Bytes_TOGET = 255 }
            if Bytes_TOGET > BytesLeft { Bytes_TOGET = BytesLeft }
            MACError, BytesRead = cx16.MACPTR(lsb(Bytes_TOGET), $9F23, true)
            BytesLeft = BytesLeft - BytesRead
       }
      ; repeat NumberOfBytes { cx16.VERA_DATA0 = cbm.ACPTR() }
      ; repeat NumberOfBytes { cx16.VERA_DATA0 = cbm.ACPTR() }
      cbm.CLRCHN()
}


sub HANDLE_FILE(str THE_LZFILE) -> bool {
    if OPEN_INPUT(THE_LZFILE) {
       Current_CHK = 1.0
       END_CHK = zHDR.NumChks + 1
       txt.clear_screen()
       MyPlot(3,0)
       Show_FILEINFO()
       Check_INBUFFERSIZE()
       txt.print("\x0D\x0D\x9B Starting Decompression \x0D")
       txt.print(" \x9C---------------------- \x0D")
       txt.nl()
       OPEN_OUTPUT()
       while Current_CHK < END_CHK {
         MyPlot(13,1)
         txt.print( "  \x05CHUNK\x1E: \x99") floats.print(Current_CHK)
         if Chunk.Verify() {
            if Do_Blank
               { Chunk.checkBlanking() }
            else
               { Chunk.PrintINSIZE() }
            READ_COMPRESSEDCHUNK(Chunk.INPUT_SIZE)
            Chunk.DECOMPRESS()
            if Current_CHK < zHDR.NumChks {
               Chunk.Write_Bytes_FromVRAM(zHDR.Def_Chk_Size)
            } else { Chunk.Write_Bytes_FromVRAM(zHDR.Last_Chk_Size) }
         }
         Current_CHK += 1.0
       }
     Show_FILEINFO()
     cbm.CLOSE(OUTLFN)
     cbm.CLOSE(INLFN)
     cbm.CLRCHN()
     HideBothLayers()
     %asm {{ stz $9F2C }}
     showTextLayer()
     txt.print("\x0D\x0D\x05 Done !")
     return true
   }
  return false
}

ubyte Cx
ubyte Cy
ubyte Ch
ubyte UP_Choice
sub Check_INBUFFERSIZE() {
    if zHDR.Def_Chk_Size > 45025  {
       txt.nl()
       txt.print("\x0D\x05 This files Chunk Size: \x99") txt.print_uw(zHDR.Def_Chk_Size)
       txt.print("\x0D\x05 May cause screen corruption on some buffers!\x0D\x0D")
       txt.print("\x99 GRAPHICS SCREEN WILL BE ACTIVATED FOR LARGE BUFFERS\x0D")
       txt.print("\x9C ---------------------------------------------------\x0D\x0D\x0D")

       cbm.CHROUT($05)
       txt.print(" WILL CONTINUE ON KEYPRESS OR IN ")
       Cy,Cx = cbm.PLOT(Cy, Cx,true)
       cbm.PLOT(Cy,Cx, false)
       txt.print("   SECONDS \x99! ")
       txt.nl()

       FlushKeys()
       cbm.SETTIM(0,0,0)
       do {
         Ch = cbm.GETIN2()
         cbm.PLOT(Cy,Cx, false)
         cbm.CHROUT($9E)
         txt.print_uw((600-cbm.RDTIM16())/60) cbm.CHROUT(32)
       } until (Ch > 0) or (cbm.RDTIM16() > 600)

getChoice:
       UP_Choice = 3
       Do_Blank = true
       FlushKeys()
       txt.clear_screen() txt.nl() txt.nl() txt.nl()
       Show_FILEINFO()
    }
}

sub Show_FILEINFO() {
 txt.print("  \x05Uncompressed Size\x1E: \x9E") floats.print(zHDR.FullSize)
 txt.nl()
 txt.print(" \x05Default Chunk size\x1E: \x9E") txt.print_uw(zHDR.Def_Chk_Size)
 txt.nl()
 txt.print("   \x05Final Chunk size\x1E: \x9E") txt.print_uw(zHDR.Last_Chk_Size)
 txt.nl() txt.nl()
 txt.print(" \x9E") floats.print(zHDR.NumChks) txt.print("\x05 Compressed chunks in \x99") txt.print(LZFILES.INNAME) txt.nl()
 txt.nl()
 txt.print("  \x05 DECOMPRESSING\x1E: \x99") txt.print(OUTNAME)
}




} ; files


zHDR {
&ubyte[4] id = $450
&float FullSize = $454
&float NumChks = $459
&uword Def_Chk_Size = $45E
&uword Last_Chk_Size = $460
&ubyte OutNameLEN = $462
&ubyte[19] HdrBytes = $450
&ubyte[255] OName = $463
&ubyte i = $22

alias ISOUpper = lzcommon.ISOUpper

sub Parse() -> bool {
    LZFILES.OUTPUT_IS_ARCHIVE = false
    bool is_valid_file = (id[0]=='L' and id[1]=='Z' and id[2]=='1' and id[3]=='6')
    if is_valid_file { LOAD_OUTNAME() }
    return is_valid_file
}

sub LOAD_OUTNAME() {
    ubyte LEN = OutNameLEN - 1
    cbm.CHKIN(LZFILES.INLFN)
    for i in 0 to LEN { LZFILES.OUTNAME[i] = cbm.ACPTR() }
    LZFILES.OUTNAME[LEN+1] = 0
    ISOUpper(LZFILES.OUTNAME)
    cbm.CLRCHN()
    if strings.length(LZFILES.OUTNAME) > 5 {
       strings.right(LZFILES.OUTNAME,5,LZFILES.TEMP)
       LZFILES.OUTPUT_IS_ARCHIVE = (strings.compare(LZFILES.TEMP,".CPIO")==0)
    }
}

sub Read() -> bool {
bool Error
    cbm.CHKIN(LZFILES.INLFN)
    for i in 0 to 18 { HdrBytes[i] = cbm.ACPTR() }
    cbm.CLRCHN()
    return Parse()
}



}

; Size of zHDR is 17
Chunk {

alias FlushKeys = lzcommon.FlushKeys
alias ISOUpper = lzcommon.ISOUpper
alias MyPlot = lzcommon.MyPlot
alias HideBothLayers = lzcommon.HideBothLayers
alias hideTextLayer = lzcommon.hideTextLayer
alias hideGraphicsLayer = lzcommon.hideGraphicsLayer

alias showGraphicsLayer = lzcommon.showGraphicsLayer
alias showTextLayer = lzcommon.showTextLayer
alias ShowBothLayers = lzcommon.ShowBothLayers


uword BufferDefaultSize
uword LastBufferSize
ubyte OB

inline asmsub VRAM_Ptr_ZERO() {
  %asm {{
       stz $9F25
       stz $9F20
       stz $9F21
       lda #%00010000
       sta $9F22
  }}
}

inline asmsub PushVERA() {
  %asm {{
     lda $9F20
     pha
     lda $9F21
     pha
     lda $9F22
     pha
     lda $9F25
     pha
  }}
}

inline asmsub PopVERA() {
  %asm {{
     pla
     sta $9F25
     pla
     sta $9F22
     pla
     sta $9F21
     pla
     sta $9F20
  }}
}

sub PrintINSIZE() { txt.print("\x0D\x0D \x05IN SIZE\x1E: \x9E") txt.print_uw(INPUT_SIZE) txt.print("        ") }


bool Blanked
sub checkBlanking() {
    if Chunk.INPUT_SIZE > 45000 {
        %asm {{ inc $9F2C }}
        if not Blanked {
          Blanked = true
          if LZFILES.UP_Choice == 3 {
             cx16.set_screen_mode($80)
             %asm {{
               lda #2
               sta $9F25
               lda #8
               sta $9F2B
               stz $9F25 }}
               showGraphicsLayer()
          }
          hideTextLayer()
        }
      } else {
        if Blanked {
           %asm {{ stz $9F2C }}
           if LZFILES.UP_Choice==3
              { cx16.set_screen_mode(1) }
           else { txt.clear_screen() }
           hideGraphicsLayer()
           showTextLayer()
           MyPlot(3,0)
           LZFILES.Show_FILEINFO()
           MyPlot(13,1) txt.print( "  \x05CHUNK\x1E: \x99") floats.print(LZFILES.Current_CHK)
           Chunk.PrintINSIZE()
           Blanked = false
        } else { Chunk.PrintINSIZE() }
      }
}


sub Write_Bytes_FromVRAM(uword HowMany) {
bool Error
uword ByteCount
uword BytesLeft
uword LoopCount
ubyte OB

   LoopCount = HowMany / 4096
   BytesLeft = (HowMany - (LoopCount * 4096))

   OB = @(0)
   cx16.rambank(12)

   cbm.CHKOUT(LZFILES.OUTLFN)
   VRAM_Ptr_ZERO()

   repeat LoopCount {
     cx16.memory_copy($9F23, $A000, 4096)
     WriteVChunk(4096)
   }
   if BytesLeft > 0 {
      cx16.memory_copy($9F23, $A000, BytesLeft)
      WriteVChunk(BytesLeft)
   }
   cx16.rambank(OB)
}


sub WriteVChunk(uword DAT_Chunk) {
uword DATA_PTR
uword BytesRead
ubyte Bytes_IO
uword BytesLeft

      BytesLeft = DAT_Chunk
      cbm.CHKOUT(LZFILES.OUTLFN)
      DATA_PTR = $A000
      do {
          if BytesLeft > 512
            { Bytes_IO = 0 }
          else
            { if BytesLeft > 255 { Bytes_IO = 255 } else {Bytes_IO = lsb(BytesLeft)} }
          void, BytesRead = cx16.MCIOUT(Bytes_IO,DATA_PTR, false)
          BytesLeft = BytesLeft - BytesRead
          DATA_PTR = DATA_PTR + BytesRead
      } until BytesLeft == 0
      cbm.CLRCHN()
}


sub DECOMPRESS() {
    VRAM_Ptr_ZERO()
    INIT_LZDATA()
    cx16.memory_decompress_from_func(&GET_LZDATA, $9F23)
    ; cx16.memory_decompress($A000, $9F23)
}

 &ubyte[2] id = $470
 &uword IN_SIZE = $472
 bool Error
 uword OUTPUT_SIZE
 uword INPUT_SIZE

 &ubyte SAVE_DC_CTRL = $40
 &ubyte SAVE_VLOW = $41
 &ubyte SAVE_VMID = $42
 &ubyte SAVE_VHIGH = $43

 &ubyte ZPTR_LOW = $44
 &ubyte ZPTR_MID = $45
 &ubyte ZPTR_HIGH = $46
 &ubyte CUR_VINDX = $47

sub INIT_LZDATA() {
    ZPTR_LOW = $00
    ZPTR_MID = $00
    CUR_VINDX = $FF
}

asmsub GET_LZDATA()  {
  %asm {{
          phx
          inc $47
          bne getbyte
          bra cachebytes
getbyte:
          ldx $47
          lda VCache, x
          plx
          rts

cachebytes:
     lda cx16.VERA_CTRL
     sta p8v_SAVE_DC_CTRL
     lda cx16.VERA_ADDR_L
     sta p8v_SAVE_VLOW
     lda cx16.VERA_ADDR_M
     sta p8v_SAVE_VMID
     lda cx16.VERA_ADDR_H
     sta p8v_SAVE_VHIGH

     lda #1
     sta cx16.VERA_CTRL
     lda p8v_ZPTR_LOW
     sta cx16.VERA_ADDR_L
     lda p8v_ZPTR_MID
     sta cx16.VERA_ADDR_M
     lda #%00010001
     sta cx16.VERA_ADDR_H
     ldx #0
cacheloop:
     lda $9F24
     sta VCache, x
     inx
     bne cacheloop
     lda cx16.VERA_ADDR_L
     sta p8v_ZPTR_LOW
     lda cx16.VERA_ADDR_M
     sta p8v_ZPTR_MID

     lda p8v_SAVE_DC_CTRL
     sta cx16.VERA_CTRL

     lda p8v_SAVE_VLOW
     sta cx16.VERA_ADDR_L

     lda p8v_SAVE_VMID
     sta cx16.VERA_ADDR_M

     lda p8v_SAVE_VHIGH
     sta cx16.VERA_ADDR_H
     jmp getbyte

.align
VCache:
     .fill 256
   ; !notreached!
  }}
}


sub Parse() -> bool {
   INPUT_SIZE = peekw($472)
   return id[0]=='z' and id[1]=='c'
 }

 sub Verify() -> bool {
     cbm.CHKIN(LZFILES.INLFN)
     Error, cx16.r0 = cx16.MACPTR(4, $0470, false)
     cbm.CLRCHN()
     if Error { return false }
     return Parse()
  }


} ; Chunk





