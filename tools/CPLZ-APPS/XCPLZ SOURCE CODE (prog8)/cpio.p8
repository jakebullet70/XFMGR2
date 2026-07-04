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
%import time_t
%zeropage basicsafe
%zpreserved $22, $40



cpio {

alias FlushKeys = lzcommon.FlushKeys
alias ISOUpper = lzcommon.ISOUpper
alias MyPlot = lzcommon.MyPlot
alias HideBothLayers = lzcommon.HideBothLayers
alias hideTextLayer = lzcommon.hideTextLayer
alias hideGraphicsLayer = lzcommon.hideGraphicsLayer

alias showGraphicsLayer = lzcommon.showGraphicsLayer
alias showTextLayer = lzcommon.showTextLayer
alias ShowBothLayers = lzcommon.ShowBothLayers

alias drivenumber = lzcommon.drivenumber

bool TIME_PRESERVE = false

float TotalFiles
float TotalBytes

ubyte OverWrite
bool OverWriteAll

ubyte WORKBANK1 = 10
ubyte WORKBANK2 = 11
ubyte OB

bool ARCHIVE_DONE

str cpMAGIC = "070701"
str cpCMP = "?"*8

float OUT_FileSize
str FileOutName = "?"*255
str OUTNAME = "?"*255

str INFILENAME = "?"*255
str TEMP = "?"*255
ubyte INLFN = 10
ubyte OUTLFN = 9
ubyte DEVICE = 8
ubyte EOF
uword OUT_BUFFER
uword CURRENT_OUTSIZE
uword CURRENT_INSIZE


ubyte HeaderTotalSize

&ubyte[110] HdrBytes = $0400

ubyte NameLength
ubyte NamePadLength

ubyte DataPadLength

&ubyte[6] hMagic = $0400
&ubyte[8] iNode = $0406
&ubyte[8] iPermissions = $040E
&ubyte[8] iUid = $0416
&ubyte[8] iGid = $041E
&ubyte[8] iNLinks = $0426
&ubyte[8] iMTime = $042E
&ubyte[8] iFileSize = $0436
&ubyte[8] devMajor = $043E
&ubyte[8] devMinor = $0446
&ubyte[8] rDevMajor = $044E
&ubyte[8] rDevMinor = $0456
&ubyte[8] iNameLength = $045E
&ubyte[8] CRC = $0466

ubyte FCODE
str FMSG="?"*60
str STARTDIR = "?"*240

asmsub Flush15() clobbers(A,X,Y) {
  %asm {{
             ldx #15
             jsr cbm.CHKIN
flushchars:  jsr cbm.GETIN
             cmp #13
             bne flushchars
             lda #15
             jsr cbm.CLOSE
             jsr cbm.CLRCHN
             jmp cbm.READST
       }}
}


sub HANDLE_FILE(str THE_CPFILE) -> bool {
    INIT_FOLDER_PTRS()
    strings.copy(diskio.curdir(),STARTDIR)
    if OPEN_INPUT(THE_CPFILE) {
       if TIME_PRESERVE {
         time_t.GetStartTime()
         time_t.sTimer = cbm.RDTIML()
         cbm.SETTIM(0,0,0)
       }
       EXTRACT_THE_ARCHIVE()
       if TIME_PRESERVE { time_t.Reset_CLOCKS() }
    } else {
       MyPlot(7,1)
       txt.print(INFILENAME) txt.print("\x99 NOT A CPIO ARCHIVE \x96! \x07")
       cbm.CLRCHN()
       cbm.CLOSE(INLFN)
       sys.wait(180)
       return false
    }
    txt.nl()
    txt.print("\x0D \x05Done \x1E!\x05\x0D\x0D")
    return true
}


sub getCODES() -> bool {
str tmp = "?"*60
str tmpc = "?"*2
ubyte tl
   strings.copy(diskio.status(),tmp)
   strings.left(tmp,2,tmpc)
   FCODE = conv.str2ubyte(tmpc)
   strings.right(tmp,strings.length(tmp)-3,FMSG)
   strings.trim(FMSG)
   strings.copy(FMSG, tmp)
   tl,void = strings.find(tmp,',')
   strings.left(tmp,tl,FMSG)
   return (strings.compare(FMSG,"OK")==0)
}

sub OPEN_INPUT(str CFILE) -> bool {
    TotalFiles = 0
    TotalBytes = 0
    strings.copy(CFILE, INFILENAME)
    strings.copy(CFILE,TEMP)
    strings.append(TEMP,",S,R")
    cbm.SETLFS(INLFN,DEVICE,INLFN)
    cbm.SETNAM(strings.length(TEMP), TEMP)
    void cbm.OPEN()
    if getCODES() {
       %asm {{ nop }}
    } else { Errors.Halt(FMSG) }
    return ReadHeader()
}

ubyte[50] Folder_PTRS
ubyte i
sub INIT_FOLDER_PTRS() {
    Folder_PTRS[0] = $A0
    for i in 1 to 49 { Folder_PTRS[i] = Folder_PTRS[i-1]+1 }
}

float CUR_POSITION
sub SEEK_NEXTFILE() {
      ; txt.print("FILE POSITION: ") floats.print(CUR_POSITION) txt.nl()
      f_seek(INLFN,CUR_POSITION + OUT_FileSize + (DataPadLength as Float))
}



sub OPEN_OUTPUT() {
    strings.copy("@:",TEMP)
    strings.append(TEMP,FileOutName)
    strings.append(TEMP,",S,W")
    cbm.SETLFS(OUTLFN,DEVICE,OUTLFN)
    cbm.SETNAM(strings.length(TEMP), TEMP)
    void cbm.OPEN()
}

sub CLOSE() {
    cbm.CLOSE(OUTLFN)
    cbm.CLOSE(INLFN)
}

sub zVRAM() {
        cx16.VERA_CTRL = 0
      cx16.VERA_ADDR_L = 0
      cx16.VERA_ADDR_M = $00
      cx16.VERA_ADDR_H = %00010001
}


sub ParseLONGHex_INPLACE(str HStr) -> float {
ubyte Saver1
ubyte Saver2
float tmp
      Saver1 = @(HStr-1)
      Saver2 = @(HStr+8)
      @(HStr-1)='$'
      @(HStr+8) = 0
      ISOUpper(HStr-1)
      tmp = floats.parse(HStr-1)
      @(HStr-1)= Saver1
      @(HStr+8) = Saver2
      return tmp
}

ubyte FOLDER_LEVELS
ubyte CUR_FOLDER_LEVEL


sub POPDIRS() {
    repeat FOLDER_LEVELS { diskio.chdir("..") }
}

sub FORCE_CD(str PATH) -> bool {
ubyte NumTrys
   NumTrys = 0
RETRY:
   diskio.chdir(PATH)
   if getCODES()
     { return true }
   else {
     if NumTrys < 1 { diskio.mkdir(PATH) void getCODES() NumTrys++ goto RETRY } else { void getCODES() Errors.Halt(FMSG) }
     return false
   }
}

uword TMP1 = $BD00
uword TMP2 = $BE00
uword TMP3 = $BF00
uword CURPTR1
uword CURPTR2

sub CreateOpen(str THEFILE) {
    strings.copy("@:",TMP1)
    strings.append(TMP1,THEFILE)
    strings.append(TMP1,",S,W")
    if TIME_PRESERVE { time_t.UnixTimeT_TO_RTC(ParseLONGHex_INPLACE(&iMTime)) }
    cbm.SETNAM(strings.length(TMP1), TMP1)
    cbm.SETLFS(OUTLFN,8,OUTLFN)
    void cbm.OPEN()
}


uword ChunkSize

sub WRITE_OUTPUTFILE() {
float fBytesLeft
    TotalFiles++
    TotalBytes = TotalBytes + OUT_FileSize
    OB = @(0)
    cx16.rambank(WORKBANK2)
    fBytesLeft = OUT_FileSize
    do {
        if fBytesLeft > 4096
           { ChunkSize = 4096 }
        else
           { ChunkSize = fBytesLeft as uword }
        WriteChunk(ChunkSize)
        fBytesLeft = fBytesLeft - ChunkSize as float
    } until fBytesLeft == 0
    cx16.rambank(OB)
    cbm.CLOSE(OUTLFN)
}

sub WriteChunk(uword Chunk) {
uword DATA_PTR
uword BytesRead
ubyte Bytes_IO
uword BytesLeft

      BytesLeft = Chunk
      DATA_PTR = $A000
      cbm.CHKIN(INLFN)
      do {
          if BytesLeft > 512
            { Bytes_IO = 0 }
          else
            { if BytesLeft > 255 { Bytes_IO = 255 } else {Bytes_IO = lsb(BytesLeft)} }
          void, BytesRead = cx16.MACPTR(Bytes_IO,DATA_PTR, false)
          EOF = cbm.READST()
          if EOF != 0 { Errors.Halt( "UNEXPECTED END OF FILE" ) }
          BytesLeft = BytesLeft - BytesRead
          DATA_PTR = DATA_PTR + BytesRead
      } until BytesLeft == 0
      cbm.CLRCHN()
      BytesLeft = Chunk
      cbm.CHKOUT(OUTLFN)
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
      cbm.CHROUT('.')
}

bool OVERWRITE_ALL
bool SKIP_THIS_FILE
sub CheckExist(str OFILE) {
ubyte ch
    SKIP_THIS_FILE = false
    OVERWRITE_ALL = false
    if diskio.exists(OFILE) {
       txt.print("\x0D\x07 ") txt.print(OFILE) txt.print( "\x9B already exists \x96! \x0D\x0D")
       txt.print(" \x1E<\x05S\x1E>\x9Bkip \x96, \x1E<\x05O\x1E>\x9Bverwrite \x96, \x9BOverwrite\x1E <\x05A\x1E>\x9Bll \x96, \x1E<\x05ESC\x1E>\x81-\x9BAbort")
       bool Proceed = false
       FlushKeys()
       cbm.CLRCHN()
       do {
         void, ch = cbm.GETIN()
         if ch==27 { Errors.Halt(" \x05USER ABORTED ! ") }
         if ch > 96 { ch = ch - 32 } ; Capitilization
         if ch==83 {
            SKIP_THIS_FILE=true
            Proceed=true
         }
         if ch == 79 {
            Proceed=true
            SKIP_THIS_FILE = false
         }
         if ch == 65 {
            Proceed=true
            OVERWRITE_ALL=true
         }
       } until Proceed
       FlushKeys()
    }
}


sub OPEN_OUTPUT_FILEPATH() -> bool {
    txt.clear_screen()
    txt.nl()
    txt.print(" \x05EXTRACTING\x1E: ")
    OB = @(0)
    if FOLDER_LEVELS > 0 {
       cx16.rambank(WORKBANK1)
       i = 0
       repeat FOLDER_LEVELS {
         CURPTR1 = mkword(Folder_PTRS[i],0)
         if FORCE_CD(CURPTR1) { cbm.CHROUT($99) txt.print(CURPTR1) txt.print("\x1E/") }
         i++
       }
    }
    if strings.length(OUTNAME) > 65 {
       txt.nl()
       txt.print("\x0D \x05FILE NAME TRUNCATED \x96!\x07\x0D")
       txt.nl()
       strings.right(OUTNAME,65,TEMP)
       strings.copy(TEMP,OUTNAME)
       sys.wait(30)
    }

    cbm.CHROUT($99) txt.print(OUTNAME)
    txt.print("\x0D\x0D \x9E") floats.print(OUT_FileSize) txt.print(" \x96bytes\x1E..")
    txt.color(3)
    if OVERWRITE_ALL { goto DOIT }
    CheckExist(OUTNAME)
    if SKIP_THIS_FILE { goto SKIPOPEN }
DOIT:
    CreateOpen(OUTNAME)
SKIPOPEN:
    cx16.rambank(OB)
    return getCODES()
}


sub EXTRACT_THE_ARCHIVE() {
OverWriteAll = false
while not cpio.ARCHIVE_DONE {
     if cpio.OUT_FileSize > 0 {
       OPEN_OUTPUT_FILEPATH()
       if SKIP_THIS_FILE { goto SKIPIT }
       WRITE_OUTPUTFILE()
SKIPIT:
       if FOLDER_LEVELS > 0 { POPDIRS() }
       if DataPadLength > 0 or SKIP_THIS_FILE { SEEK_NEXTFILE() }
     } else { cpio.SEEK_NEXTFILE() }
     if not ReadHeader() { txt.print(cpCMP) txt.nl() return }
   }
   txt.clear_screen()
   txt.nl() txt.nl()
   txt.print(" \x05 EXTRACTION OF FILES COMPLETE\x0D")
   txt.color(8)
   txt.print("  ----------------------------\x0D\x0D")
   txt.print(" \x05 Extracted \x9E") floats.print(TotalBytes) txt.print(" \x96bytes\x1E.\x0D")
   txt.print(" \x05           \x9E") floats.print(TotalFiles) txt.print(" \x99files\x96.\x0D")
}

sub SPLIT_OUTPUTPATH() {
bool DONE
bool FOUND
    DONE = false
    FOLDER_LEVELS = 0
    CUR_FOLDER_LEVEL = 0
    OB = @(0)
    cx16.rambank(WORKBANK1)
    strings.copy(FileOutName,TMP1)
    while not DONE {
      CURPTR1 = mkword(Folder_PTRS[CUR_FOLDER_LEVEL], 0)
      i, FOUND = strings.find(TMP1,'/')
      if FOUND {
         strings.left(TMP1,i,CURPTR1)
         CUR_FOLDER_LEVEL++
         strings.right(TMP1,strings.length(TMP1)-(i+1),TMP2)
         strings.copy(TMP2,TMP1)
      } else { DONE = true}
    }
    strings.copy(TMP1, OUTNAME)
    FOLDER_LEVELS=CUR_FOLDER_LEVEL
    cx16.rambank(OB)
}

sub LOAD_OUTNAME() {
    cbm.CHKIN(INLFN)
    ubyte i = 0
    repeat NameLength { FileOutName[i] = cbm.ACPTR() i++ }
    if NamePadLength > 0 { repeat NamePadLength {void cbm.ACPTR() } }
    CUR_POSITION = F_POS(INLFN)
    ISOUpper(FileOutName)
    SPLIT_OUTPUTPATH()
    cbm.CLRCHN()
}

sub GetFileDATA_PAD() {
    DataPadLength = 0
    if  floats.floor(OUT_FileSize / 4) == (OUT_FileSize/4)
        { %asm {{ nop }} }
    else {
      do { DataPadLength++ } until floats.floor((DataPadLength as float + OUT_FileSize)/4) == ((DataPadLength as float + OUT_FileSize)/4)
    }
}

sub READ_DATA() {
    GetFileDATA_PAD()
}


sub Parse() -> bool {
    bool is_valid_file = (strings.compare(cpCMP,cpMAGIC)==0)
    if is_valid_file {
       NameLength = ParseLONGHex_INPLACE(&iNameLength) as ubyte
       OUT_FileSize = ParseLONGHex_INPLACE(&iFileSize)
       GetFileDATA_PAD()
       NamePadLength = 0
       uword DIV4 = 110 + NameLength
       if (DIV4 & $0003) != 0 { while (DIV4 & $0003) != 0 { NamePadLength++ DIV4++ }  }
       LOAD_OUTNAME()
    }
    ARCHIVE_DONE = (strings.compare(FileOutName,"TRAILER!!!")==0)
    return is_valid_file
}


sub ReadHeader() -> bool {
bool Error
ubyte i
    cbm.CHKIN(INLFN)
    for i in 0 to 109 { HdrBytes[i] = cbm.ACPTR() }
    for i in 0 to 5 { cpCMP[i] = HdrBytes[i] }
    cpCMP[6] = 0
    cbm.CLRCHN()
    return Parse()
}


sub Write_Bytes_FromVRAM(uword HowMany) {
bool Error
uword BytesWritten
uword ByteCount
uword BytesLeft
ubyte BytesToGet

BytesLeft = HowMany
ByteCount = 0
cbm.CHKOUT(OUTLFN)
zVRAM()
     while BytesLeft > 0 {
        if BytesLeft > 128
           { BytesToGet=128 }
        else
           { BytesToGet = lsb(BytesLeft) }
        Error, BytesWritten = cx16.MCIOUT(BytesToGet, $9F23, true)
        BytesLeft = BytesLeft - BytesWritten
        if Error { Errors.Halt(" ERROR WRITING FILE !")}
     }
cbm.CLRCHN()
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
        void cbm.CHKIN(15)        ; use #15 as input channel
        %asm {{
              jmp p8s_Flush15
            }}
}

} ; cpio






