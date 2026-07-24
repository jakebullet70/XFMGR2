@ECHO OFF
REM Run XFMGR2 in the emulator from a CLEAN folder. Does NOT compile - it stages the
REM artifacts build.bat already wrote into build\, then launches. Build first:
REM
REM     build.bat            (compiles + BUILD_NUM sync + memory stats)
REM     run.bat              (this - copies build\ into run\ and starts the emulator)
REM
REM Why a clean folder: the project root contains AUTOBOOT.X16 (the SADLOGIC DEV MENU),
REM which the Kernal auto-runs on boot and would hijack the launch. The run\ folder has no
REM AUTOBOOT.X16, so the emulator boots straight into the XT loader. It also holds sample
REM dirs/files (GAMES\, DOCS\, README.TXT) to browse.

SETLOCAL
SET ROOT=%~dp0
SET BUILDDIR=%ROOT%build
SET RUNDIR=%ROOT%run

REM --- require a prior build. run.bat no longer compiles; if build\ is empty or stale,
REM     xfmgr.prg won't be here - bail with a clear pointer rather than launching something old.
IF NOT EXIST "%BUILDDIR%\xfmgr.prg" (
    ECHO *** no build found in build\ - run build.bat first ***
    ENDLOCAL & EXIT /B 1
)

IF NOT EXIST "%RUNDIR%" MKDIR "%RUNDIR%"

REM 1) copy the built app + overlays into run\xfmgr.
REM DESTINATION NAMES ARE UPPERCASE ON PURPOSE. prog8's default PETSCII encodes a lowercase
REM source literal ("xsyntax.ovl", "xfmgr.hlp", ...) to bytes $41-$5A - which ARE the UPPERCASE
REM ASCII letters - and those are the bytes the filesystem is asked to match. So every file the
REM program opens by name must be uppercase on disk, or a case-sensitive filesystem (a real SD
REM card) won't find it. The emulator's Windows host-fs is case-insensitive and hides this
REM completely, so getting it wrong only ever shows up on hardware. build\ stays lowercase (it is
REM just an intermediate dir, and nothing on the X16 reads from it) - this staging step is the
REM boundary where the naming has to become correct.
REM
REM DESTINATION FOLDER = run\UTILS\XFMGR. This MUST match the path baked into the XT loader stub
REM (a tokenized  10 LOAD "/UTILS/XFMGR/XFMGR.PRG"  at the run\ root); the emulator loads the app
REM from there, so staging anywhere else runs a stale binary. MKDIR creates UTILS\ on the way.
SET XFMGRDIR=%RUNDIR%\UTILS\XFMGR
IF NOT EXIST "%XFMGRDIR%" MKDIR "%XFMGRDIR%"
COPY /Y "%BUILDDIR%\xfmgr.prg"     "%XFMGRDIR%\XFMGR.PRG"    >NUL
COPY /Y "%BUILDDIR%\tview.ovl"     "%XFMGRDIR%\TVIEW.OVL"    >NUL
COPY /Y "%BUILDDIR%\miscutil.ovl"  "%XFMGRDIR%\MISCUTIL.OVL" >NUL
COPY /Y "%BUILDDIR%\uiutil.ovl"    "%XFMGRDIR%\UIUTIL.OVL"   >NUL
COPY /Y "%BUILDDIR%\ximgview.ovl"  "%XFMGRDIR%\XIMGVIEW.OVL" >NUL
COPY /Y "%BUILDDIR%\xmusic.ovl"    "%XFMGRDIR%\XMUSIC.OVL"   >NUL
COPY /Y "%BUILDDIR%\xsyntax.ovl"   "%XFMGRDIR%\XSYNTAX.OVL"  >NUL
COPY /Y "%BUILDDIR%\xfsetup.prg"   "%XFMGRDIR%\XFSETUP.PRG"  >NUL
REM the zsmkit music-engine blob (bank 6) - a static library asset (not built), kept at root
COPY /Y "%ROOT%zsmkit.bin"         "%XFMGRDIR%\ZSMKIT.BIN"   >NUL
REM stage the F1 help text (a static asset, not built) alongside the .prg
COPY /Y "%ROOT%xfmgr.hlp"          "%XFMGRDIR%\XFMGR.HLP"    >NUL
REM seed a default theme cfg ONLY if none exists yet, so a theme set via xfsetup in the emulator
REM survives a rebuild (mirrors the installer's preserve-existing-cfg behaviour).
IF NOT EXIST "%XFMGRDIR%\XFMGR.CFG" COPY /Y "%ROOT%xfmgr.cfg" "%XFMGRDIR%\XFMGR.CFG" >NUL

REM 2) stage a RELEASE test folder (NOT /xfmgr) holding every release file plus the installer,
REM    so install.prg can be exercised the way an end user would: boot, CD:RELEASE, then run it -
REM    it creates /xfmgr and /xt from there.
SET RELDIR=%RUNDIR%\RELEASE
IF NOT EXIST "%RELDIR%" MKDIR "%RELDIR%"
COPY /Y "%XFMGRDIR%\*.prg" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.ovl" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.bin" "%RELDIR%\" >NUL
COPY /Y "%XFMGRDIR%\*.hlp" "%RELDIR%\" >NUL
REM the default theme cfg is a release file too (installer ships + preserves it) - stage it from the
REM root so install.prg finds it here; without this a fresh install reports "xfmgr.cfg not found".
COPY /Y "%ROOT%xfmgr.cfg"          "%RELDIR%\XFMGR.CFG"      >NUL
COPY /Y "%BUILDDIR%\install.prg"   "%RELDIR%\INSTALL.PRG"    >NUL

REM 3) stage the sample media (tracked in samples\ / vendored) into the browse root so the
REM    V/P players have something to open. run\ is gitignored; samples\ is the source of truth.
COPY /Y "%ROOT%samples\*.bmx" "%RUNDIR%\" >NUL
COPY /Y "%ROOT%samples\*.wav" "%RUNDIR%\" >NUL
COPY /Y "%ROOT%docs\prog8\examples\zsmkit_v2\SONG1.ZSM" "%RUNDIR%\SONG1.ZSM" >NUL
COPY /Y "%ROOT%docs\prog8\examples\zsmkit_v2\SONG2.ZSM" "%RUNDIR%\SONG2.ZSM" >NUL

REM 4) launch from the run\ root as the host filesystem root (no AUTOBOOT.X16 there),
REM    running the XT loader stub - it LOADs+RUNs /UTILS/XFMGR/XFMGR.PRG from the subfolder.
CALL "%ROOT%LOCAL.BAT"
REM -ram 512 pins the machine to the base 512 KB (banks 0-63) for testing, so the runtime
REM    bank-count detection and the "of 63 banks" About readout are exercised.
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -ram 512 -prg XT -run -rtc -joy1
ENDLOCAL
