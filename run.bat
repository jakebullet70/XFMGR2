@ECHO OFF
REM Build XFMGR2 and run it in the emulator from a CLEAN folder.
REM
REM Why a clean folder: the project root contains AUTOBOOT.X16 (the SADLOGIC
REM DEV MENU), which the Kernal auto-runs on boot and would hijack the launch.
REM The run\ folder has no AUTOBOOT.X16, so the emulator boots straight into
REM xfmgr.prg. It also holds sample dirs/files (GAMES\, DOCS\, README.TXT) to
REM browse.
REM
REM Usage:  run.bat [source.p8]    (defaults to xfmgr.p8)

SETLOCAL
SET SRC=%1
IF "%SRC%"=="" SET SRC=xfmgr.p8

REM 1) compile (build.bat writes xfmgr.prg + overlays into build\)
CALL "%~dp0build.bat" %SRC%
IF ERRORLEVEL 1 GOTO :EOF

REM 2) stage the fresh .prg into the clean run folder
SET RUNDIR=%~dp0run
IF NOT EXIST "%RUNDIR%" MKDIR "%RUNDIR%"
rem 'COPY /Y "%~dp0xfmgr.prg" "%RUNDIR%\xfmgr.prg" >NUL
rem 'REM stage the tview viewer overlay (loaded into HIRAM bank 2 at runtime) alongside it
rem 'COPY /Y "%~dp0tview.ovl" "%RUNDIR%\tview.ovl" >NUL
REM stage the miscutil overlay (loaded into HIRAM bank 3 at runtime)
rem 'COPY /Y "%~dp0miscutil.ovl" "%RUNDIR%\miscutil.ovl" >NUL

REM 2b) also copy all built files into run\xfmgr
SET XFMGRDIR=%RUNDIR%\xfmgr
IF NOT EXIST "%XFMGRDIR%" MKDIR "%XFMGRDIR%"
REM DESTINATION NAMES ARE UPPERCASE ON PURPOSE. prog8's default PETSCII encodes a lowercase
REM source literal ("xsyntax.ovl", "xfmgr.hlp", ...) to bytes $41-$5A - which ARE the UPPERCASE
REM ASCII letters - and those are the bytes the filesystem is asked to match. So every file the
REM program opens by name must be uppercase on disk, or a case-sensitive filesystem (a real SD
REM card) won't find it. The emulator's Windows host-fs is case-insensitive and hides this
REM completely, so getting it wrong only ever shows up on hardware. build\ stays lowercase (it is
REM just an intermediate dir, and nothing on the X16 reads from it) - this staging step is the
REM boundary where the naming has to become correct.
COPY /Y "%~dp0build\xfmgr.prg" "%XFMGRDIR%\XFMGR.PRG" >NUL
COPY /Y "%~dp0build\tview.ovl" "%XFMGRDIR%\TVIEW.OVL" >NUL
COPY /Y "%~dp0build\miscutil.ovl" "%XFMGRDIR%\MISCUTIL.OVL" >NUL
COPY /Y "%~dp0build\uiutil.ovl" "%XFMGRDIR%\UIUTIL.OVL" >NUL
COPY /Y "%~dp0build\ximgview.ovl" "%XFMGRDIR%\XIMGVIEW.OVL" >NUL
COPY /Y "%~dp0build\xmusic.ovl" "%XFMGRDIR%\XMUSIC.OVL" >NUL
COPY /Y "%~dp0build\xsyntax.ovl" "%XFMGRDIR%\XSYNTAX.OVL" >NUL
COPY /Y "%~dp0build\xfsetup.prg" "%XFMGRDIR%\XFSETUP.PRG" >NUL
REM the zsmkit music-engine blob (bank 6) - a static library asset (not built), kept at root
COPY /Y "%~dp0zsmkit.bin" "%XFMGRDIR%\ZSMKIT.BIN" >NUL
REM stage the F1 help text (a static asset, not built) alongside the .prg
COPY /Y "%~dp0xfmgr.hlp" "%XFMGRDIR%\XFMGR.HLP" >NUL
REM seed a default theme cfg ONLY if none exists yet, so a theme set via xfsetup in the emulator
REM survives a rebuild (mirrors the installer's preserve-existing-cfg behaviour).
IF NOT EXIST "%XFMGRDIR%\XFMGR.CFG" COPY /Y "%~dp0xfmgr.cfg" "%XFMGRDIR%\XFMGR.CFG" >NUL

REM 2b') stage a RELEASE test folder (NOT /xfmgr) holding every release file plus the
REM      installer, so install.prg can be exercised the way an end user would:
REM      boot, CD:RELEASE, then run it - it creates /xfmgr and /xt from there.
SET RELDIR=%RUNDIR%\RELEASE
IF NOT EXIST "%RELDIR%" MKDIR "%RELDIR%"
COPY /Y "%XFMGRDIR%\*.prg" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.ovl" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.bin" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.hlp" "%RELDIR%\" >NUL
REM the default theme cfg is a release file too (installer ships + preserves it) - stage it from the
REM root so install.prg finds it here; without this a fresh install reports "xfmgr.cfg not found".
COPY /Y "%~dp0xfmgr.cfg" "%RELDIR%\XFMGR.CFG" >NUL
COPY /Y "%~dp0build\install.prg" "%RELDIR%\INSTALL.PRG" >NUL

REM 2c) stage the sample media (tracked in samples\ / vendored) into the browse root so the
REM     V/P players have something to open. run\ is gitignored; samples\ is the source of truth.
COPY /Y "%~dp0samples\*.bmx" "%RUNDIR%\" >NUL
COPY /Y "%~dp0samples\*.wav" "%RUNDIR%\" >NUL
COPY /Y "%~dp0docs\prog8\examples\zsmkit_v2\SONG1.ZSM" "%RUNDIR%\SONG1.ZSM" >NUL
COPY /Y "%~dp0docs\prog8\examples\zsmkit_v2\SONG2.ZSM" "%RUNDIR%\SONG2.ZSM" >NUL

REM 3) launch from the run\ root as the host filesystem root (no AUTOBOOT.X16 there),
REM    running the XT loader stub - it LOADs+RUNs /XFMGR/XFMGR.PRG from the subfolder.
CALL "%~dp0LOCAL.BAT"
REM -ram 512 pins the machine to the base 512 KB (banks 0-63) for testing, so the
REM    runtime bank-count detection and the "of 63 banks" About readout are exercised.
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -ram 512 -prg XT -run -rtc -joy1
ENDLOCAL
