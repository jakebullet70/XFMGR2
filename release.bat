@ECHO OFF
REM Cut a shippable XFMGR2 release ZIP.
REM
REM Usage:  release.bat            (full build, then package)
REM         release.bat nobuild    (package whatever is already in build\)
REM
REM Produces  release\XFMGR-<BUILD>.ZIP  containing a single INST-XFMGR\ folder with
REM every file an end user needs. The user unzips it, copies INST-XFMGR to the SD card,
REM then from the X16 does  CD:INST-XFMGR  and runs INSTALL.PRG - which creates /XFMGR
REM and the /XT launcher stub.
REM
REM The fileset below MUST stay in sync with the FILES manifest in SRC\install.p8
REM (that array is what install.prg actually copies), plus INSTALL.PRG itself.
REM
REM DESTINATION NAMES ARE UPPERCASE ON PURPOSE - same reason as run.bat: prog8's default
REM PETSCII encodes a lowercase source literal to bytes $41-$5A, which ARE uppercase ASCII,
REM and those are the bytes the filesystem is asked to match. A real SD card is case
REM sensitive, so lowercase names here would fail on hardware while working fine in the
REM emulator. This packaging step is the boundary where the naming has to become correct.

SETLOCAL ENABLEDELAYEDEXPANSION

SET ROOT=%~dp0
SET BUILDDIR=%ROOT%build
SET RELROOT=%ROOT%release
SET STAGE=%RELROOT%\INST-XFMGR

REM 1) build, unless explicitly skipped. build.bat runs syncbuild.ps1 first, which levels the
REM    build number across the sources - so BUILD_NUM must be read AFTER this, not before.
IF /I "%1"=="nobuild" (
    ECHO [release] skipping build, packaging build\ as-is
) ELSE (
    CALL "%ROOT%build.bat" xfmgr.p8
    IF ERRORLEVEL 1 (
        ECHO *** build FAILED - no release cut ***
        ENDLOCAL & EXIT /B 1
    )
)

REM 2) read the build number back out of the compiled source. The pattern deliberately does NOT
REM    name the declared type: BUILD_NUM was widened from ubyte to uword when build 255 hit the
REM    byte ceiling, which made the old 'const ubyte BUILD_NUM' pattern stop matching - and this
REM    step's only symptom would have been "could not read BUILD_NUM" at release time. It is the
REM    same pattern syncbuild.ps1 uses, for the same reason.
FOR /F "usebackq delims=" %%N IN (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Select-String -Path '%ROOT%SRC\xfmgr.p8' -Pattern 'BUILD_NUM\s*=\s*(\d+)').Matches[0].Groups[1].Value"`) DO SET BUILDNUM=%%N
IF "%BUILDNUM%"=="" (
    ECHO *** could not read BUILD_NUM from SRC\xfmgr.p8 ***
    ENDLOCAL & EXIT /B 1
)
SET ZIPNAME=XFMGR-%BUILDNUM%.ZIP
SET ZIPPATH=%RELROOT%\%ZIPNAME%

ECHO.
ECHO [release] building %ZIPNAME%

REM 3) stage a CLEAN INST-XFMGR folder (wipe first, so a file dropped from the manifest
REM    doesn't linger in the next zip)
IF NOT EXIST "%RELROOT%" MKDIR "%RELROOT%"
IF EXIST "%STAGE%" RMDIR /S /Q "%STAGE%"
MKDIR "%STAGE%"

CALL :STAGEFILE "%BUILDDIR%\xfmgr.prg"     XFMGR.PRG
CALL :STAGEFILE "%BUILDDIR%\xfsetup.prg"   XFSETUP.PRG
CALL :STAGEFILE "%BUILDDIR%\install.prg"   INSTALL.PRG
CALL :STAGEFILE "%BUILDDIR%\tview.ovl"     TVIEW.OVL
CALL :STAGEFILE "%BUILDDIR%\miscutil.ovl"  MISCUTIL.OVL
CALL :STAGEFILE "%BUILDDIR%\uiutil.ovl"    UIUTIL.OVL
CALL :STAGEFILE "%BUILDDIR%\ximgview.ovl"  XIMGVIEW.OVL
CALL :STAGEFILE "%BUILDDIR%\xmusic.ovl"    XMUSIC.OVL
CALL :STAGEFILE "%BUILDDIR%\xsyntax.ovl"   XSYNTAX.OVL
REM static assets from the project root (not built)
CALL :STAGEFILE "%ROOT%zsmkit.bin"         ZSMKIT.BIN
CALL :STAGEFILE "%ROOT%xfmgr.hlp"          XFMGR.HLP
CALL :STAGEFILE "%ROOT%xfmgr.cfg"          XFMGR.CFG
REM human-facing docs - ignored by the X16, read by whoever downloads the zip
CALL :STAGEFILE "%ROOT%README.md"          README.md
CALL :STAGEFILE "%ROOT%LICENSE"            LICENSE

IF DEFINED MISSING (
    ECHO.
    ECHO *** release ABORTED - missing file^(s^):%MISSING%
    ECHO     ^(run a full build first, or fix the fileset in release.bat^)
    RMDIR /S /Q "%STAGE%"
    ENDLOCAL & EXIT /B 1
)

REM 4) zip it. -Path the FOLDER so INST-XFMGR\ is the single root entry inside the archive.
IF EXIST "%ZIPPATH%" (
    ECHO [release] overwriting existing %ZIPNAME%
    DEL /Q "%ZIPPATH%"
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%STAGE%' -DestinationPath '%ZIPPATH%' -CompressionLevel Optimal -Force"
IF ERRORLEVEL 1 (
    ECHO *** zip FAILED ***
    ENDLOCAL & EXIT /B 1
)

REM 5) drop the staging folder - the zip is the deliverable
RMDIR /S /Q "%STAGE%"

ECHO.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$z=Get-Item '%ZIPPATH%'; Write-Host ('[release] {0}  {1:N0} bytes' -f $z.Name, $z.Length); Add-Type -AssemblyName System.IO.Compression.FileSystem; $a=[IO.Compression.ZipFile]::OpenRead($z.FullName); $a.Entries | ForEach-Object { Write-Host ('           {0,-24} {1,8:N0}' -f $_.FullName, $_.Length) }; $a.Dispose()"
ECHO.
ECHO [release] done -^> release\%ZIPNAME%
ENDLOCAL & EXIT /B 0

REM --- helper: copy one file into the staging folder under an explicit name, or record it as
REM     missing. Deliberately does NOT abort on the first miss - listing every missing file at
REM     once is more useful than fixing them one build at a time.
:STAGEFILE
IF NOT EXIST "%~1" (
    SET MISSING=!MISSING! %~nx1
    GOTO :EOF
)
COPY /Y "%~1" "%STAGE%\%~2" >NUL
GOTO :EOF
