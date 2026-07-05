@ECHO OFF
REM Build an XFMGR2 Prog8 source (in SRC\) to a .prg for the Commander X16.
REM Usage:  build.bat <source.p8>      (defaults to xfmgr.p8 if omitted)
REM         The source name is resolved inside the SRC\ directory.
REM         The .prg is written to the project root (-out .).
REM Needs:  java (JRE) and the 64tass assembler. Paths set below.
REM
REM After a successful compile it prints a memory-stats block: the program image
REM (code+data), variable (BSS) and slab sizes, the main-RAM high-water address and
REM how much low RAM is free below the I/O area at $9F00, plus the .prg size on disk.
REM Banked HIRAM ($A000+) is NOT counted - that is used dynamically by the file arena
REM and grows as directories are logged.

SETLOCAL
SET JAVABIN=C:\dev\b4x\java19\bin
SET TASSBIN=C:\8bitProgramming\64tass-1.60
REM quote the whole assignment: an existing PATH entry may contain '&' (e.g. "ADB & Fastboot++"),
REM which cmd would otherwise treat as a command separator and try to run - printing a stray
REM "'Fastboot++\' is not recognized" error. Quoting makes '&' literal.
SET "PATH=%JAVABIN%;%TASSBIN%;%PATH%"

SET SRCDIR=%~dp0SRC
SET SRC=%1
IF "%SRC%"=="" SET SRC=xfmgr.p8
REM the .prg is named after the source (xfmgr.p8 -> xfmgr.prg), written to the root
FOR %%F IN ("%SRC%") DO SET PRGFILE=%~dp0%%~nF.prg

SET BUILDLOG=%TEMP%\xfmgr_build.txt
REM prog8c.jar (root) is the active compiler; prior versions are archived in old-compilers\
REM (swap the name here to roll back to one of those).
java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\%SRC%" > "%BUILDLOG%" 2>&1
SET ERR=%ERRORLEVEL%
TYPE "%BUILDLOG%"
IF NOT "%ERR%"=="0" ( ENDLOCAL & EXIT /B %ERR% )

REM --- memory-stats block parsed from the segment map ---
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memstats.ps1" -Log "%BUILDLOG%" -Prg "%PRGFILE%"

REM --- companion build: the tview viewer overlay (%output library -> headerless tview.bin, which
REM     this script renames to tview.ovl) at $A000, loaded into HIRAM bank 2 at runtime and called
REM     via extsub @bank. Only when building the app itself. %memtop $C000 in tview.p8 fails the
REM     build if it outgrows the bank. (All four overlays are renamed .bin -> .ovl below.)
IF /I "%SRC%"=="xfmgr.p8" (
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\tview.p8" > "%TEMP%\tview_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\tview_build.txt" & ECHO *** tview overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%~dp0tview.bin" "%~dp0tview.ovl" >NUL
    ECHO tview overlay: tview.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\miscutil.p8" > "%TEMP%\miscutil_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\miscutil_build.txt" & ECHO *** miscutil overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%~dp0miscutil.bin" "%~dp0miscutil.ovl" >NUL
    ECHO miscutil overlay: miscutil.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\uiutil.p8" > "%TEMP%\uiutil_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\uiutil_build.txt" & ECHO *** uiutil overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%~dp0uiutil.bin" "%~dp0uiutil.ovl" >NUL
    ECHO uiutil overlay: uiutil.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\ximgview.p8" > "%TEMP%\ximgview_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\ximgview_build.txt" & ECHO *** ximgview overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%~dp0ximgview.bin" "%~dp0ximgview.ovl" >NUL
    ECHO ximgview overlay: ximgview.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\xmusic.p8" > "%TEMP%\xmusic_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\xmusic_build.txt" & ECHO *** xmusic overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%~dp0xmusic.bin" "%~dp0xmusic.ovl" >NUL
    ECHO xmusic overlay: xmusic.ovl built ^($A000 HIRAM bank overlay^).
    REM companion: the standalone colour-theme setup utility (a full $0801 PRG, not an overlay).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%~dp0." "%SRCDIR%\xfsetup.p8" > "%TEMP%\xfsetup_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\xfsetup_build.txt" & ECHO *** xfsetup build FAILED *** & ENDLOCAL & EXIT /B 1 )
    ECHO xfsetup utility: xfsetup.prg built ^(standalone theme picker^).
)

ENDLOCAL & EXIT /B 0
