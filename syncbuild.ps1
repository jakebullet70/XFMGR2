# Sync the F1 readme (xfmgr.hlp) "(Build N)" line with BUILD_NUM - the number shown on the XFMGR
# About box - and verify the About string (uiutil.p8) and the README.md build marker agree with it.
# Called by build.bat on a full build, BEFORE xfmgr.hlp is copied into the release / run folders.
#   -Src     SRC\xfmgr.p8   source of truth:  const ubyte BUILD_NUM = N
#   -Ui      SRC\uiutil.p8  About box string: "Version 1.0.N"   (verify only - warns on drift)
#   -Readme  README.md      marker:           (build:N)         (verify only - warns on drift)
#   -Hlp     xfmgr.hlp      F1 readme:        "(Build N)"       (STAMPED to match BUILD_NUM)
param([string]$Src, [string]$Ui, [string]$Readme, [string]$Hlp)

# --- source of truth: BUILD_NUM in xfmgr.p8 ---
if (-not (Test-Path $Src)) {
    Write-Host '  build-sync: xfmgr.p8 not found - skipped.' -ForegroundColor Yellow; return
}
if ((Get-Content $Src -Raw) -notmatch 'BUILD_NUM\s*=\s*(\d+)') {
    Write-Host '  build-sync: BUILD_NUM not found in xfmgr.p8 - skipped.' -ForegroundColor Yellow; return
}
$build = [int]$matches[1]

# --- verify the About box (uiutil.p8) and README marker; warn (do not fail) on any mismatch ---
if ((Test-Path $Ui) -and ((Get-Content $Ui -Raw) -match 'Version\s+1\.0\.(\d+)') -and ([int]$matches[1] -ne $build)) {
    Write-Host ("  build-sync: WARNING - About box (uiutil.p8) is 1.0.{0}, BUILD_NUM is {1}. Fix uiutil.p8." -f $matches[1], $build) -ForegroundColor Red
}
if ($Readme -and (Test-Path $Readme) -and ((Get-Content $Readme -Raw) -match 'build:\s*(\d+)') -and ([int]$matches[1] -ne $build)) {
    Write-Host ("  build-sync: WARNING - README.md marker is build:{0}, BUILD_NUM is {1}. Fix README.md." -f $matches[1], $build) -ForegroundColor Red
}

# --- stamp the F1 readme (xfmgr.hlp) "(Build N)" to match BUILD_NUM ---
# Byte-preserving edit: read/write as Latin-1 (a 1:1 byte<->char map) so any high-bit bytes elsewhere
# in the help text survive untouched - only the ASCII "(Build N)" token is rewritten.
if (-not (Test-Path $Hlp)) {
    Write-Host '  build-sync: xfmgr.hlp not found - hlp not stamped.' -ForegroundColor Yellow; return
}
$enc = [System.Text.Encoding]::GetEncoding('iso-8859-1')
$old = $enc.GetString([System.IO.File]::ReadAllBytes($Hlp))
if ($old -notmatch '\(Build\s+\d+\)') {
    Write-Host '  build-sync: no "(Build N)" marker in xfmgr.hlp - hlp not stamped.' -ForegroundColor Yellow; return
}
$new = $old -replace '\(Build\s+\d+\)', "(Build $build)"
if ($new -ne $old) {
    [System.IO.File]::WriteAllBytes($Hlp, $enc.GetBytes($new))
    Write-Host ("  build-sync: xfmgr.hlp F1 readme stamped to Build {0} (matches About box)." -f $build) -ForegroundColor Green
} else {
    Write-Host ("  build-sync: xfmgr.hlp F1 readme already at Build {0}." -f $build) -ForegroundColor Cyan
}
