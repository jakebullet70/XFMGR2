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
SET BUILDDIR=%~dp0build
SET SRC=%1
IF "%SRC%"=="" SET SRC=xfmgr.p8
REM the .prg is named after the source (xfmgr.p8 -> xfmgr.prg), written to build\
FOR %%F IN ("%SRC%") DO SET PRGFILE=%BUILDDIR%\%%~nF.prg

SET BUILDLOG=%TEMP%\xfmgr_build.txt
REM all compiler output (.prg/.bin/.asm/.vice-mon-list) is directed into build\ (gitignored)
IF NOT EXIST "%BUILDDIR%" MKDIR "%BUILDDIR%"
REM --- sync the build number across xfmgr.p8 / uiutil.p8 / README.md / xfmgr.hlp, leveling every one
REM     UP to the largest value found. Runs BEFORE the compile so this build's binary shows the result.
REM     Bump the number in ANY one of those files and the next build propagates it. Full builds only.
IF /I "%SRC%"=="xfmgr.p8" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0syncbuild.ps1" -Src "%SRCDIR%\xfmgr.p8" -Ui "%SRCDIR%\uiutil.p8" -Readme "%~dp0README.md" -Hlp "%~dp0xfmgr.hlp"

REM prog8c.jar (root) is the active compiler; prior versions are archived in old-compilers\
REM (swap the name here to roll back to one of those).
java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\%SRC%" > "%BUILDLOG%" 2>&1
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
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\tview.p8" > "%TEMP%\tview_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\tview_build.txt" & ECHO *** tview overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\tview.bin" "%BUILDDIR%\tview.ovl" >NUL
    ECHO tview overlay: tview.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\miscutil.p8" > "%TEMP%\miscutil_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\miscutil_build.txt" & ECHO *** miscutil overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\miscutil.bin" "%BUILDDIR%\miscutil.ovl" >NUL
    ECHO miscutil overlay: miscutil.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\uiutil.p8" > "%TEMP%\uiutil_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\uiutil_build.txt" & ECHO *** uiutil overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\uiutil.bin" "%BUILDDIR%\uiutil.ovl" >NUL
    ECHO uiutil overlay: uiutil.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\ximgview.p8" > "%TEMP%\ximgview_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\ximgview_build.txt" & ECHO *** ximgview overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\ximgview.bin" "%BUILDDIR%\ximgview.ovl" >NUL
    ECHO ximgview overlay: ximgview.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\xmusic.p8" > "%TEMP%\xmusic_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\xmusic_build.txt" & ECHO *** xmusic overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\xmusic.bin" "%BUILDDIR%\xmusic.ovl" >NUL
    ECHO xmusic overlay: xmusic.ovl built ^($A000 HIRAM bank overlay^).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\xsyntax.p8" > "%TEMP%\xsyntax_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\xsyntax_build.txt" & ECHO *** xsyntax overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\xsyntax.bin" "%BUILDDIR%\xsyntax.ovl" >NUL
    ECHO xsyntax overlay: xsyntax.ovl built ^($A000 HIRAM bank overlay^).
    REM companion: the standalone settings utility (a full $0801 PRG, not an overlay).
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\xfsetup.p8" > "%TEMP%\xfsetup_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\xfsetup_build.txt" & ECHO *** xfsetup build FAILED *** & ENDLOCAL & EXIT /B 1 )
    ECHO xfsetup utility: xfsetup.prg built ^(standalone settings screen^).
    REM companion: the standalone self-installer (a full $0801 PRG) - run once from the release folder.
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\install.p8" > "%TEMP%\install_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\install_build.txt" & ECHO *** install build FAILED *** & ENDLOCAL & EXIT /B 1 )
    ECHO installer: install.prg built ^(creates /xfmgr + /xt on the SD card^).
)

REM We no longer assemble a release\xfmgr-install deliverable here. The ONLY place the release
REM fileset is written is run\RELEASE, staged by run.bat (from build\ + the root xfmgr.cfg) as the
REM emulator install-test folder. To cut a shippable release, copy build\ + the root assets by hand.
:done

ENDLOCAL & EXIT /B 0
