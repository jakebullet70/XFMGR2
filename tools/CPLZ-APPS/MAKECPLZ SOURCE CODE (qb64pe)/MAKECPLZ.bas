$Console:Only

$If WINDOWS Then
 $EXEICON: './archer.ico'
$End If

Option _Explicit
' $Include: './C64FLOATS.QLB'
' $Include: './FILEPATHS.BM'
' $Include: './TPRINT.QLB'


Dim Shared BFMT$
BFMT$ = "##########,"

Dim Shared SLASH$
Dim Shared CRLF As String * 2
CRLF = Chr$(13) + Chr$(10)

$If WINDOWS Then
    SLASH$ = "\"
    Const SystemOpen$ = "START "
    ' OldRoot$ = _Dir$("APPDATA")
    ' OldRoot$ = Left$(OldRoot$, (Len(OldRoot$) - 1))
    ' OldDir$ = OldRoot$ + Slash$ + "x16vidprojects"
    ' HomeDir$ = _Dir$("DOCUMENTS")
    ' HomeDir$ = Left$(HomeDir$, (Len(HomeDir$) - 1))
    Const NukeDir$ = "RMDIR /s /q "
    Const MOVECMD$ = "MOVE "
$Else
    SLASH$ = "/"
    ' Const NULL$ = "/dev/null"
    ' Const CopyCmd$ = "cp "
    Const MoveCmd$ = "mv "
    ' HomeDir$ = Environ$("HOME")
    Const NUKEDIR$ = "rm -rf "
    $If MAC Then
        CONST SystemOpen$="open "
    $Else
        Const SystemOpen$ = "xdg-open "
    $End If
$End If


Dim Shared COMMAND_ME$
Dim Shared PROG_COMMAND$
Dim Shared WORKING_FOLDER$
Dim Shared TARGET_FOLDER$
Dim Shared CPIONAME$

Dim Shared GO As Integer
Dim Shared KILL_TEMP As Integer
COMMAND_ME$ = Command$(0)

GO = _FileExists(COMMAND_ME$)

If Not GO Then
    Print
    Print "CANT FIND MY EXECUTABLE !"
    Print
    System
End If

If InStr(COMMAND_ME$, Chr$(32)) > 0 Then
    COMMAND_ME$ = Chr$(34) + COMMAND_ME$ + Chr$(34)
End If

ChDir _StartDir$

WORKING_FOLDER$ = _CWD$

If Right$(WORKING_FOLDER$, 1) <> SLASH$ Then WORKING_FOLDER$ = WORKING_FOLDER$ + SLASH$

Dim Shared DEFAULTCHUNK As _Unsigned Long
Dim Shared LAST_CHUNKSIZE As _Unsigned Integer

DEFAULTCHUNK = 45000

Option _Explicit
Type LZXHEADERTYPE
    LZID As String * 4
    OUTSIZE As String * 5
    NUMCHUNKS As String * 5
    DEFAULTCHUNK_SIZE As _Unsigned Integer
    LASTCHK_SIZE As _Unsigned Integer
    OUTNAMELENGTH As _Unsigned _Byte
End Type

Type CHKHEADER
    CHKID As String * 2
    CHK_COMPRESSED_SIZE As _Unsigned Integer
End Type

ReDim Shared CHUNKBUFFER(1) As _Unsigned _Byte
Dim Shared CUR_CHUNKSIZE As _Unsigned Integer

Dim Shared MsgY1 As Integer
Dim Shared MsgY2 As Integer
Dim Shared OUTHEADER As LZXHEADERTYPE
Dim Shared OUTNAME$, OUTFILE$
Dim F$, TMP$, TMP1$, TMP2$
Dim I As Integer
Dim Byt As _Unsigned _Byte
Dim Shared INSIZE As Double
Dim Shared NUM_CHUNKS As Double
Dim Shared GROUP_INCREMENT As _Unsigned Long
Dim Shared NUM_GROUPS As Integer
Dim Shared IN_FILENAME$
Dim Shared TMP_FOLDER$
Dim Shared WORKING_PATH$
Dim Shared STARTING_CHUNK As _Unsigned Long


Dim Shared GO_VAR As Integer
Dim Shared MAKE_CPIOFILE As Integer
Dim Shared CPIO_WORKPATH As String
Dim Shared CPIO_TARGET As String



If _CommandCount > 2 Then
    PARSE_COMMANDLINE
Else
    If _CommandCount = 0 Then
        GoTo STARTUP
    Else
        PARSE_COMMAND1
        If DEFAULTCHUNK > 60416 Or DEFAULTCHUNK < 4096 Then
            Print
            Print "   BAD CHUNK SIZE ";
            Print Using BFMT$; DEFAULTCHUNK; "  (Max 60,416...Min 4096)"
            Print
            System
        End If
        If MAKE_CPIOFILE Then
            MAKE_CPIOARCHIVE (CPIO_TARGET)
            IN_FILENAME$ = CPIONAME$
        End If
        If GO_VAR Then
            GoTo GOGOGO
        Else
            Print
            Print " COMMAND COUNT: "; _CommandCount
            Print " INVALID ARGUMENTS: ";
            For I = 1 To _CommandCount
                Print Command$(I),
            Next
            Print
            PRINTUSAGE
        End If
    End If
End If

Select Case PROG_COMMAND$
    Case "COMPRESS"
        DO_COMPRESSION
        System
    Case Else
        Print " COMMAND LINE ERROR"
        Print
        PRINTUSAGE
End Select


STARTUP:
Print
Line Input " ENTER A FILE OR FOLDER NAME TO COMPRESS: ", IN_FILENAME$
' IN_FILENAME$ = _OpenFileDialog$("FILE TO COMPRESS", "./", "*", "ALL FILES", _FALSE)

If _FileExists(IN_FILENAME$) Or _DirExists(IN_FILENAME$) Then
    Dim Shared IS_A_FOLDER As Integer
    IS_A_FOLDER = _DirExists(IN_FILENAME$)
    GETCSIZE:
    Print
    Tprint " {WHT}Enter Compressor Data Chunk Size {GRN}(4096{RED}-{GRAY 1}60416{GRN}){ORG}:{YEL} "
    Dim NEWCHUNK As _Unsigned Integer
    Input NEWCHUNK
    Print
    If NEWCHUNK = 0 GoTo SKIPIT
    If DEFAULTCHUNK > 60416 Or DEFAULTCHUNK < 4096 Then
        Print
        Print Using BFMT$; "   BAD CHUNK SIZE "; NEWCHUNK; "  (Max 60416...Min 4096)"
        GoTo GETCSIZE
    End If
    DEFAULTCHUNK = NEWCHUNK
    SKIPIT:
Else
    Print " TARGET FILE WAS NOT FOUND"
    Beep
    System
End If

GOGOGO:

If IS_A_FOLDER Then
    CPIO_TARGET = IN_FILENAME$
    MAKE_CPIOARCHIVE (CPIO_TARGET)
    IN_FILENAME$ = CPIONAME$
End If

TMP1$ = GetFileName$(IN_FILENAME$)
TMP2$ = GetFileExt$(IN_FILENAME$)

If _FileExists(IN_FILENAME$) Then
    INSIZE = GETFILESIZE(IN_FILENAME$)
Else
    Print
    Tprint "{LIGHT GREEN} " + IN_FILENAME$ + " {WHT}NOT FOUND{YEL}! {WHT}"
    Print
    GoTo STARTUP
End If

NUM_CHUNKS = Int(INSIZE / DEFAULTCHUNK)
If (NUM_CHUNKS * DEFAULTCHUNK) < INSIZE Then
    LAST_CHUNKSIZE = INSIZE - (NUM_CHUNKS * DEFAULTCHUNK)
    NUM_CHUNKS = NUM_CHUNKS + 1
Else
    LAST_CHUNKSIZE = DEFAULTCHUNK
End If


If IsInstalled("lzsa") Then
    START_COMPRESSION_SEQUENCE
Else
    Print
    Print " lzsa Utility is not installed. "
    Print " Can't continue."
    Print
    Print " lzsa utility can be downloaded from: "
    Print: Print "  "; "https://github.com/emmanuel-marty/lzsa"
    Print
End If
System

Sub PRINTUSAGE
    Print
    Tprint "{WHT}X6SHRINK {GRAY 1}FILENAME {YEL}CS={GRN}({YEL}DATA CHUNK SIZE{GRN}){RED}.........{GRAY 1}(4096..60416)" + CRLF
    Print
    System
End Sub


Sub CREATE_HEADER_ANDOPENOUTPUT
    Dim TMP$
    Dim TMP1$, TMP2$
    Dim BYT As _Unsigned _Byte
    Dim I As Long
    TMP1$ = GetFileName(IN_FILENAME$)
    TMP2$ = GetFileExt(IN_FILENAME$)
    If Len(TMP1$) + Len(TMP2$) < 255 Then
        OUTNAME$ = TMP1$ + TMP2$
    Else
        OUTNAME$ = Left$(TMP1$, 254 - Len(TMP2$)) + LCase$(TMP2$)
    End If

    OUTHEADER.LZID = "LZ16"
    OUTHEADER.DEFAULTCHUNK_SIZE = DEFAULTCHUNK
    OUTHEADER.LASTCHK_SIZE = LAST_CHUNKSIZE
    TMP$ = ""
    DoubleToC64Float (INSIZE)
    For I = 0 To 4
        TMP$ = TMP$ + Chr$(FAC(I))
    Next
    OUTHEADER.OUTSIZE = TMP$
    TMP$ = ""
    DoubleToC64Float (NUM_CHUNKS)
    For I = 0 To 4
        TMP$ = TMP$ + Chr$(FAC(I))
    Next
    OUTHEADER.NUMCHUNKS = TMP$
    OUTHEADER.OUTNAMELENGTH = Len(OUTNAME$)

    TMP1$ = GetFileName(IN_FILENAME$)

    OUTFILE$ = TMP1$ + ".LZ16"
    If _FileExists(OUTFILE$) Then Kill OUTFILE$
    Locate 1, 1
    Print " CREATING -> "; OUTFILE$
    Print
    Open OUTFILE$ For Binary As #12
    Locate 2, 1
    Print " WRITING HEADER.....";
    Put 12, , OUTHEADER
    Print " Storing FileName...."
    For I = 1 To Len(OUTNAME$)
        BYT = Asc(Mid$(OUTNAME$, I, 1))
        Put 12, , BYT
    Next
    Locate 2, 1: Print "                                       ";
End Sub

Sub START_COMPRESSION_SEQUENCE
    Dim GROUPS As Integer
    Dim I As Integer
    Dim Current_Chunk As _Unsigned Long
    Dim POPDIR$

    POPDIR$ = _CWD$
    TMP_FOLDER$ = "." + SLASH$ + GPREFIX$ + "TEMPF"
    Cls
    Locate 19, 1
    Tprint " {WHT}STARTING COMPRESSION {LIGHT GREEN}!{ORG}" + "   " + CRLF
    Tprint " ----------------------{WHT}" + CRLF
    Tprint "{GRAY 1}  Compressing{RED}:{WHT}" + IN_FILENAME$ + CRLF
    Tprint "{GRAY 1}    File Size{RED}:{WHT} {YEL}"
    Select Case INSIZE
        Case Is > 1023999999
            Tprint _Trim$(Str$(INSIZE / 1024000000)) + "{RED} Gb{GRAY 1}"
        Case Is > 1023999
            Tprint _Trim$(Str$(INSIZE / 1024000)) + "{RED} Mb{GRAY 1}"
        Case Else
            Tprint _Trim$(Str$(INSIZE)) + "{RED} Bytes{GRAY 1}"
    End Select
    Print
    Dim x As Integer
    Dim y As Integer


    If _DirExists(TMP_FOLDER$) Then
        KILL_TEMP = _FALSE
    Else
        MkDir TMP_FOLDER$
        KILL_TEMP = _TRUE
    End If

    CHUNK_THE_FILE NUM_CHUNKS
    Locate 23, 1
    Tprint "  {WHT}Compressing {LIGHT RED}"
    Print NUM_CHUNKS;
    Tprint "{WHT} Chunks in {YEL}"
    Print NUM_GROUPS;
    Tprint " {WHT}groups of {LIGHT GREEN}"
    Print GROUP_INCREMENT;
    Tprint " {WHT}Chunks."


    Current_Chunk = 1
    For I = 1 To NUM_GROUPS
        BG_SPAWN "COMPRESS", Current_Chunk, _FALSE
        Current_Chunk = Current_Chunk + GROUP_INCREMENT
    Next

    $If WINDOWS Then
        Locate 4, 1
        Print " EXECUTING GROUP CHUNK COMPRESSION. "
        Locate 5, 1
        Print "   PLEASE STANDBY !"
    $End If

    MONITOR
    Cls
    Print
    Tprint " {WHT}COMPRESSION FINISHED{LIGHT GREEN}!{ORG}" + CRLF
    Tprint " --------------------{WHT}"
    Print
    Tprint "{GRAY 1}   Compressed{RED}:{WHT}" + IN_FILENAME$ + CRLF
    Tprint "{GRAY 1}    File Size{RED}:{WHT} "
    Print Using BFMT$; INSIZE
    Print
    Tprint "   {WHT}Compressed {LIGHT GREEN}" + Str$(NUM_CHUNKS) + "{WHT} Chunks."
    Print
    Tprint "  {GRAY 1} DATA Chunk Size{GRN}: {WHT}"

    Print Using BFMT$; DEFAULTCHUNK

    Tprint "  {GRAY 1} LAST Chunk Size{GRN}: {WHT}"

    Print Using BFMT$; LAST_CHUNKSIZE
    Print
    Tprint "{GRAY 1}   Compressed File{YEL}: {WHT}" + OUTFILE$ + CRLF
    Tprint "{GRAY 1}   Compressed Size{YEL}: {WHT}"

    Print Using BFMT$; GETFILESIZE(OUTFILE$)

    Print
    Tprint " {ORG} DONE {GRN}!{WHT}" + CRLF
    Print
    CLEANUP
    System
End Sub

Sub CLEANUP
    If KILL_TEMP Then
        Shell NUKEDIR$ + TMP_FOLDER$
    End If
End Sub

Sub PARSE_COMMAND1
    Dim I As Integer
    Dim CP As Integer
    Dim CC As Integer
    Dim GOTFILE As Integer
    Dim GOTFOLDER As Integer
    Dim GOTCHUNKSIZE As Integer
    Dim TEST$, TMP$, SPLT_R$, SPLT_L$
    Dim T2$, T3$


    CC = _CommandCount
    TEST$ = _Trim$(Command$(1))
    If CC = 2 Then TMP$ = _Trim$(Command$(2))

    If _FileExists(TEST$) Then
        GOTFILE = _TRUE
        IN_FILENAME$ = Command$(1)
        If _CommandCount = 1 Then
            GO_VAR = _TRUE
            Exit Sub
        End If
    Else
        If _DirExists(TEST$) Then
            GOTFOLDER = _TRUE
            GO_VAR = _TRUE
            MAKE_CPIOFILE = _TRUE
            CPIO_TARGET = TEST$
            If _CommandCount = 1 Then Exit Sub
        End If
    End If

    If Not (GOTFILE Or GOTFOLDER) And CC = 2 Then
        TEST$ = UCase$(TEST$)
        CP = InStr(TEST$, "=")
        If Left$(TEST$, 2) = "CS" And (CP > 0) Then
            SPLT_L$ = _Trim$(Left$(TEST$, CP - 1))
            SPLT_R$ = _Trim$(Mid$(TEST$, CP + 1))
            GoSub CHECKCHUNKSIZE
            If Not GOTCHUNKSIZE Then GoTo PARSEERROR
            GOTFILE = _FileExists(TMP$)
            If Not (GOTFILE Or GOTFOLDER) Then
                GOTFOLDER = _DirExists(TMP$)
                If Not GOTFOLDER Then
                    GoTo PARSEERROR
                Else
                    GO_VAR = _TRUE
                    MAKE_CPIOFILE = _TRUE
                    CPIO_TARGET$ = TMP$
                End If
            End If
            IN_FILENAME$ = TMP$
            If (GOTFILE Or GOTFOLDER) And GOTCHUNKSIZE Then
                GO_VAR = _TRUE
                Exit Sub
            End If
        End If
    Else
        If CC = 2 Then
            CP = InStr(TMP$, "=")
            If CP > 0 Then
                SPLT_L$ = _Trim$(Left$(TMP$, CP - 1))
                SPLT_R$ = _Trim$(Mid$(TMP$, CP + 1))
                GOTCHUNKSIZE = _FALSE
                GoSub CHECKCHUNKSIZE
                If GOTCHUNKSIZE Then
                    GO_VAR = 2
                    Exit Sub
                End If
            End If
        End If
    End If


    Exit Sub
    CHECKCHUNKSIZE:
    If SPLT_L$ = "CS" And IsNum(SPLT_R$) Then
        DEFAULTCHUNK = Val(SPLT_R$)
        GOTCHUNKSIZE = _TRUE
    End If
    Return



    PARSEERROR:
    Print " INVALID ARGUMENTS: ";
    For I = 1 To _CommandCount
        Print Command$(I),
    Next
    Print
    System
End Sub

Sub PARSE_COMMANDLINE
    Dim I As Integer
    ' GOCMD$ = COMMAND_ME$ + " " + CMD$ + " " + FP$ + " " + Str$(CHUNKNUM) + " " + Str$(NUM_CHUNKS) + " " + Str$(DEFAULTCHUNK) + " " + Str$(LAST_CHUNKSIZE) + " " + Str$(INSIZE) + " " + Str$(NUM_GROUPS) + " " + Str$(GROUP_INCREMENT)
    If _CommandCount = 9 Then
        PROG_COMMAND$ = Command$(1)
        IN_FILENAME$ = Command$(2)
        STARTING_CHUNK = Val(Command$(3))
        NUM_CHUNKS = Val(Command$(4))
        DEFAULTCHUNK = Val(Command$(5))
        LAST_CHUNKSIZE = Val(Command$(6))
        INSIZE = Val(Command$(7))
        NUM_GROUPS = Val(Command$(8))
        GROUP_INCREMENT = Val(Command$(9))
        TMP_FOLDER$ = "." + SLASH$ + GPREFIX$ + "TEMPF"
    Else
        Print
        Print "BAD COMMAND LINE"
        Print
        System
    End If
End Sub


Sub COMPRESSCHUNKS_FROMTO (STARTC As _Unsigned Long, ENDC As _Unsigned Long, MSGY As Integer)
    Dim I As _Unsigned Long
    For I = STARTC To ENDC
        COMPRESSCHUNK I, MSGY
    Next


End Sub

Sub WAIT_PROCESSCOUNT
    Dim TF$
    Dim CK As _Unsigned Integer
    Dim FNUM As Long
    TF$ = GPREFIX$ + ".PROCESSCOUNT"
    CHECKWAIT:
    If _FileExists(TF$) Then
        FNUM = FreeFile
        Open TF$ For Binary As FNUM
        Get FNUM, , CK
        Close FNUM
    End If
    If CK > 10 Then
        _Delay .15
        GoTo CHECKWAIT
    End If
End Sub

Sub INC_PROCESSCOUNT
    Dim TF$
    Dim CK As _Unsigned Integer
    Dim FNUM As Long
    TF$ = GPREFIX$ + ".PROCESSCOUNT"
    CHECKWAIT:
    If _FileExists(TF$) Then
        FNUM = FreeFile
        Open TF$ For Binary As FNUM
        Get FNUM, , CK
        Close FNUM
    Else
        CK = 0
    End If
    CK = CK + 1
    FNUM = FreeFile
    Open TF$ For Binary As FNUM
    Put FNUM, , CK
    Close FNUM
End Sub

Sub DEC_PROCESSCOUNT
    Dim TF$
    Dim CK As _Unsigned Integer
    Dim FNUM As Long
    TF$ = GPREFIX$ + ".PROCESSCOUNT"
    CHECKWAIT:
    If _FileExists(TF$) Then
        FNUM = FreeFile
        Open TF$ For Binary As FNUM
        Get FNUM, , CK
        Close FNUM
    Else
        CK = 1
    End If
    CK = CK - 1
    FNUM = FreeFile
    Open TF$ For Binary As FNUM
    Put FNUM, , CK
    Close FNUM
End Sub

Sub WAIT_LOCK
    LOCKWAIT:
    If _FileExists(GPREFIX + "LOCK") Then
        _Delay .15
        GoTo LOCKWAIT
    End If
End Sub

Sub LOCK_UP
    Dim LLFN As Long
    LLFN = FreeFile
    Open GPREFIX + "LOCK" For Binary As LLFN
    Put #LLFN, , LLFN
    Close LLFN
End Sub

Sub UN_LOCK
    Dim TF$
    TF$ = GPREFIX + "LOCK"
    If _FileExists(TF$) Then
        Kill TF$
    End If
End Sub



Sub DO_COMPRESSION
    Dim I As _Unsigned Long
    Dim LLFN As _Unsigned Long
    Dim END_CHUNK As _Unsigned Long
    Dim PRINT_STATUS As Integer
    Dim TF$
    Dim POPDIR$
    Dim PCOUNT As Integer
    Dim MSGY As Integer
    POPDIR$ = _CWD$


    ChDir TMP_FOLDER$
    ChDir POPDIR$

    ChDir TMP_FOLDER$

    END_CHUNK = STARTING_CHUNK + (GROUP_INCREMENT - 1)
    If END_CHUNK > NUM_CHUNKS Then END_CHUNK = NUM_CHUNKS

    MSGY = 3 + Int(STARTING_CHUNK / GROUP_INCREMENT)

    If END_CHUNK < STARTING_CHUNK Then
        Locate MSGY, 1
        Print " "; " GROUP ERROR: "; STARTING_CHUNK, END_CHUNK;
        System
    End If

    COMPRESSCHUNKS_FROMTO STARTING_CHUNK, END_CHUNK, MSGY

    Locate MSGY, 1
    For I = 1 To 70: Print " ";: Next
    Locate MSGY, 1
    Print " GROUP COMPRESS DONE ->"; STARTING_CHUNK; "-"; END_CHUNK;
    TF$ = GPREFIX + "." + _Trim$(Str$(STARTING_CHUNK)) + ".GROUPDONE"
    I = FreeFile
    Open TF$ For Output As I
    Print #I, " DONE "
    Close I
    ChDir POPDIR$

End Sub


Sub MONITOR
    Dim WATCHCHUNK As _Unsigned Long
    Dim LAST_CHUNK_NUMBER As _Unsigned Long
    Dim WATCHNAME$
    Dim POPDIR$

    POPDIR$ = _CWD$
    CREATE_HEADER_ANDOPENOUTPUT
    ChDir TMP_FOLDER$
    WATCHCHUNK = 1
    Do
        LAST_CHUNK_NUMBER = WATCHCHUNK + (GROUP_INCREMENT - 1)
        If LAST_CHUNK_NUMBER > NUM_CHUNKS Then LAST_CHUNK_NUMBER = NUM_CHUNKS
        WATCHNAME$ = GPREFIX + "." + _Trim$(Str$(WATCHCHUNK)) + ".GROUPDONE"
        Do While Not _FileExists(WATCHNAME$)
            _Limit 20
        Loop
        SAVE_COMPRESSEDCHUNKS WATCHCHUNK, LAST_CHUNK_NUMBER
        ' Kill WATCHNAME$
        WATCHCHUNK = WATCHCHUNK + GROUP_INCREMENT
    Loop Until LAST_CHUNK_NUMBER = NUM_CHUNKS
    Close 12
    ChDir POPDIR$
End Sub


Function GPREFIX$
    Dim TMP$
    Dim I As _Unsigned Long
    TMP$ = GetFileName$(IN_FILENAME$) + "-CHUNK-"
    For I = 1 To Len(TMP$)
        If Mid$(TMP$, I, 1) = Chr$(32) Then
            Mid$(TMP$, I, 1) = "-"
        End If
    Next
    GPREFIX$ = TMP$
End Function

Function CHUNK_PREFIX$ (ChunkNumber As _Unsigned Long)
    Dim TMP$
    Dim I As _Unsigned Long
    TMP$ = GPREFIX$
    TMP$ = TMP$ + _Trim$(Str$(ChunkNumber))
    CHUNK_PREFIX$ = TMP$
End Function

Sub CHUNK_THE_FILE (NUMCHKS As Double)
    Dim I As _Unsigned Long
    Dim INC_DIVISOR As Integer
    Dim EndLoop As _Unsigned Long
    EndLoop = NUM_CHUNKS
    INC_DIVISOR = 8
    ' Dim Shared GROUP_INCREMENT As _Unsigned Long
    ' Dim Shared NUM_GROUPS As Integer

    NUDGE_THE_NUMBERS:
    If NUM_CHUNKS < 200 Then
        If NUM_CHUNKS < 100 Then
            GROUP_INCREMENT = NUM_CHUNKS
        Else
            GROUP_INCREMENT = 100
        End If
    Else
        GROUP_INCREMENT = Int(NUM_CHUNKS / INC_DIVISOR)
    End If
    NUM_GROUPS = Int(NUM_CHUNKS / GROUP_INCREMENT)

    If (NUM_GROUPS * GROUP_INCREMENT) < NUM_CHUNKS Then NUM_GROUPS = NUM_GROUPS + 1


    If GROUP_INCREMENT > 1000 And NUM_GROUPS < 15 Then
        INC_DIVISOR = INC_DIVISOR + 1
        GoTo NUDGE_THE_NUMBERS
    End If

    I = 1
    Open IN_FILENAME$ For Binary As #11
    Do
        If I < EndLoop Then
            CUR_CHUNKSIZE = DEFAULTCHUNK
        Else
            CUR_CHUNKSIZE = LAST_CHUNKSIZE
        End If
        Locate 2, 6
        Print " GETTING CHUNK ->"; I
        GetChunk (I)
        I = I + 1
    Loop Until I > EndLoop
    Close 11
    Locate 2, 6
    For I = 1 To 60: Print Chr$(32);: Next
End Sub

Sub GetChunk (ChunkNumber As _Unsigned Long)
    Dim CHUNKNAME$
    ReDim CHUNKBUFFER(0 To CUR_CHUNKSIZE - 1) As _Unsigned _Byte
    CHUNKNAME$ = TMP_FOLDER$ + SLASH$ + CHUNK_PREFIX$(ChunkNumber) + ".RAWCHUNK"
    Get #11, , CHUNKBUFFER()
    ' If _FileExists(CHUNKNAME$) Then Kill CHUNKNAME$
    Open CHUNKNAME$ For Binary As #20
    Put #20, , CHUNKBUFFER()
    Close #20
End Sub

Sub COMPRESSCHUNK (CHKNUMBER As _Unsigned Long, MSGY As Integer)
    Dim CHUNKIN$
    Dim CHUNKOUT$
    Dim PREFIX$
    Dim POPDIR$
    Dim CMD$
    Locate MSGY, 3
    Print " COMPRESSING CHUNK ->"; CHKNUMBER; "       ";

    PREFIX$ = CHUNK_PREFIX$(CHKNUMBER)
    CHUNKIN$ = PREFIX$ + ".RAWCHUNK"
    CHUNKOUT$ = PREFIX$ + ".COMPCHUNK"
    If _FileExists(CHUNKOUT$) Then System
    If Not _FileExists(CHUNKIN$) Then
        _MessageBox "FILE NOT FOUND" + CHUNKIN$ + " WASN'T FOUND !", "warning"
        System
    End If
    CMD$ = "lzsa -r -f2 " + " " + CHUNKIN$ + " " + CHUNKOUT$
    Shell CMD$
    ' Kill CHUNKIN$
End Sub

Sub SAVE_COMPRESSEDCHUNKS (STARTC As _Unsigned Long, ENDC As _Unsigned Long)
    Dim I As _Unsigned Long
    Locate 2, 1
    For I = 1 To 70: Print Chr$(32);: Next
    For I = STARTC To ENDC
        Write_The_Chunk I
    Next
End Sub

Sub Write_The_Chunk (THECHUNK As _Unsigned Long)
    Static CHKTAG As CHKHEADER
    Dim I As Integer
    Dim CHUNKNAME$

    CHUNKNAME$ = CHUNK_PREFIX$(THECHUNK) + ".COMPCHUNK"
    Locate 2, 1
    For I = 1 To 70: Print Chr$(32);: Next
    Locate 2, 1
    Print " WRITING CHUNK ->"; THECHUNK; " ";

    Open CHUNKNAME$ For Binary As 3
    CHKTAG.CHKID = "zc"
    CHKTAG.CHK_COMPRESSED_SIZE = LOF(3)
    If CHKTAG.CHK_COMPRESSED_SIZE = 0 Then
        Print
        Cls
        Print "ERROR"
        Print "ZERO SIZE OUT CHUNK !"
        Print " "; CHUNKNAME$
        Print _CWD$
        _Delay 5
        Print
        System
        End
    End If
    ReDim TMPBUFFER(0 To CHKTAG.CHK_COMPRESSED_SIZE - 1) As _Unsigned _Byte
    Get 3, , TMPBUFFER()
    Put 12, , CHKTAG
    Put 12, , TMPBUFFER()
    Close 3
    '  Kill CHUNKNAME$
End Sub

'If NUM_CHUNKS < 600 Then
'   GROUP_INCREMENT = 100
'Else
'   GROUP_INCREMENT = Int(NUM_CHUNKS / 6)
'End If
' NUM_GROUPS = _Round(NUM_CHUNKS / GROUP_INCREMENT)


Sub BG_SPAWN (CMD$, CHUNKNUM As _Unsigned Long, DOEXIT As Integer)
    Dim FP$
    Dim GOCMD$
    FP$ = IN_FILENAME$
    If InStr(FP$, Chr$(32)) > 0 Then
        FP$ = Chr$(34) + FP$ + Chr$(34)
    End If
    GOCMD$ = COMMAND_ME$ + " " + CMD$ + " " + FP$ + " " + Str$(CHUNKNUM) + " " + Str$(NUM_CHUNKS) + " " + Str$(DEFAULTCHUNK) + " " + Str$(LAST_CHUNKSIZE) + " " + Str$(INSIZE) + " " + Str$(NUM_GROUPS) + " " + Str$(GROUP_INCREMENT)


    SPAWN GOCMD$, _TRUE
    If DOEXIT Then
        _Delay 10
        System
    End If
End Sub

Sub FG_SPAWN (CMD$, CHUNKNUM As _Unsigned Long)
    Dim FP$
    Dim GOCMD$
    FP$ = IN_FILENAME$
    If InStr(FP$, Chr$(32)) > 0 Then
        FP$ = Chr$(34) + FP$ + Chr$(34)
    End If
    GOCMD$ = COMMAND_ME$ + " " + CMD$ + " " + FP$ + " " + Str$(CHUNKNUM) + " " + Str$(NUM_CHUNKS) + " " + Str$(DEFAULTCHUNK) + " " + Str$(LAST_CHUNKSIZE) + " " + Str$(INSIZE) + " " + Str$(NUM_GROUPS) + " " + Str$(GROUP_INCREMENT)
    SPAWN GOCMD$, _FALSE
End Sub

Sub SPAWN (CMD$, BACKGROUND As Integer)
    Dim C$
    If BACKGROUND Then
        C$ = CMD$
        $If WINDOWS Then
            C$ = "start /min " + C$
        $End If
        Shell _DontWait C$
    Else
        Shell CMD$
    End If
End Sub


Sub CLEANUP_TEMPS
    Dim X$
    If IsNum(X$) Then Print
    Rem PLACEHOLDER
End Sub


Sub MAKE_CPIOARCHIVE (PATH As String)
    Dim POPD$
    Dim TNAME$
    Dim PNAME$
    Dim NAMEIT$
    Dim CMD$
    Dim N1$, N2$
    Dim I As Integer
    POPD$ = _CWD$
    If _DirExists(PATH) Then
        ChDir PATH
        If _CWD$ = "/" Then
            ChDir POPD$
            Print " CAN'T ARCHIVE YOUR ROOT PATH !!! "
            Print Chr$(7)
            System
        End If
        ChDir ".."
    Else
        ChDir POPD$
        Print " ARCHIVE PATH NOT FOUND !!! "
        Print Chr$(7)
        System
    End If

    If InStr(SLASH$, PATH) > 0 Then
        I = Len(PATH)
        If Mid$(PATH, I, 1) = SLASH$ Then I = I - 1
        Do
            PNAME$ = Mid$(PATH, I, 1) + PNAME$
            I = I - 1
        Loop Until Mid$(PATH, I, 1) = SLASH$
    Else
        PNAME$ = PATH
    End If
    If Right$(PNAME$, 1) = SLASH$ Then PNAME$ = Left$(PNAME$, Len(PNAME$) - 1)
    NAMEIT$ = PNAME$ + ".CPIO"
    GoSub MAKEIT
    If Not _FileExists(NAMEIT$) Then
        Print
        Print "ERROR: UNABLE TO CREATE --> "; PNAME$
        Print
        System
    End If

    CPIONAME$ = NAMEIT$
    Exit Sub

    MAKEIT:
    TNAME$ = TMP_FILENAME$
    $If WINDOWS OR MAC Then
        If InStr(Chr$(32), PNAME$) > 0 Then
            N1$ = Chr$(34) + PNAME$ + Chr$(34)
        Else
            N1$ = PNAME$
        End If
        CMD$ = "tar -cf " + TNAME$ + " --format=newc "
        CMD$ = CMD$ + N1$
    $End If

    $If LINUX Then
        CMD$ = PNAME$ + SLASH$ + "*"
        If InStr(Chr$(32), CMD$) > 0 Then
            CMD$ = Chr$(34) + CMD$ + Chr$(34)
        End If
        CMD$ = "find " + CMD$ + " -depth -print0 | cpio -o -H newc --null > " + TNAME$
    $End If
    Print
    Print " EXECUTING "
    Print CMD$
    Shell CMD$
    If InStr(Chr$(32), NAMEIT$) > 0 Then
        NAMEIT$ = Chr$(34) + NAMEIT$ + Chr$(34)
    End If

    CMD$ = MoveCmd$ + TNAME$ + " ." + SLASH$ + NAMEIT$
    Print
    Print "MOVE COMMAND ->  "; CMD$
    $If WINDOWS Then
        CMD$ = CMD$ + " 2> NUL "
    $End If
    Shell CMD$
    Return
End Sub

Function TMP_FILENAME$ ()
    Dim TMP$
    Dim L As Integer
    Dim I As Integer
    Do
        TMP$ = ".TMP"
        Randomize (Timer)
        L = Int(Rnd * 5) + 5
        For I = 1 To L
            TMP$ = Chr$(Int(Rnd * 26) + 65) + TMP$
        Next
    Loop Until Not _FileExists(TMP$)
    TMP_FILENAME = TMP$
End Function

Function IsInstalled% (trycmd$)
    Dim GetInstalled As Integer
    $If WINDOWS Then
        GetInstalled = (Shell("where " + trycmd$) = 0)
    $Else
        GetInstalled = (Shell("which " + trycmd$) = 0)
    $End If

    IsInstalled = GetInstalled
End Function













