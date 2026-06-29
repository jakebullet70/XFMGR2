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

REM 1) compile (build.bat writes xfmgr.prg to the project root)
CALL "%~dp0build.bat" %SRC%
IF ERRORLEVEL 1 GOTO :EOF

REM 2) stage the fresh .prg into the clean run folder
SET RUNDIR=%~dp0run
IF NOT EXIST "%RUNDIR%" MKDIR "%RUNDIR%"
COPY /Y "%~dp0xfmgr.prg" "%RUNDIR%\xfmgr.prg" >NUL

REM 3) launch with the clean folder as the host filesystem root (no AUTOBOOT.X16
REM    there), so the emulator boots straight into xfmgr.prg.
CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -prg xfmgr.prg -run -rtc -joy1
ENDLOCAL
