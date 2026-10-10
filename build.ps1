<#
================================================================================
 tablet-spoof / build.ps1
================================================================================
 Builds the flashable Magisk / APatch module zip.

   .\build.ps1              build dist/tablet-spoof-v<ver>.zip
   .\build.ps1 -Clean       wipe dist/ first
   .\build.ps1 -Verify      additionally run the scope-guard + syntax self-test
   .\build.ps1 -Inspect     list zip entries and assert flat root layout

 There is NO native payload to compile: no NDK/clang exists on this machine
 (see README.md "Toolchain verdict"). The module is pure shell.
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Verify,
    [switch]$Inspect
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$ModDir   = Join-Path $Root 'module'
$DistDir  = Join-Path $Root 'dist'
$BuildDir = Join-Path $Root 'build'

function Info([string]$m) { Write-Host "[build] $m" }
function Warn([string]$m) { Write-Host "[build] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[build] ERROR: $m" -ForegroundColor Red; exit 1 }

# --- 0. sanity ---------------------------------------------------------------
if (-not (Test-Path $ModDir)) { Fail "module/ not found at $ModDir" }

$propPath = Join-Path $ModDir 'module.prop'
if (-not (Test-Path $propPath)) { Fail "module.prop not found" }

# --- 1. parse module.prop for the version ------------------------------------
$props = @{}
foreach ($line in Get-Content $propPath) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $props[$k.Trim()] = $v.Trim()
}

$id      = $props['id']
$ver     = $props['version']
$verCode = $props['versionCode']

if ([string]::IsNullOrWhiteSpace($id))  { Fail "module.prop is missing 'id'" }
if ([string]::IsNullOrWhiteSpace($ver)) { Fail "module.prop is missing 'version'" }
if ([string]::IsNullOrWhiteSpace($verCode)) { Warn "module.prop is missing 'versionCode'" }

Info "module id=$id version=$ver versionCode=$verCode"

# Magisk requires the zip filename / id to be safe.
if ($id -notmatch '^[A-Za-z0-9._-]+$') { Fail "module id '$id' has unsafe characters" }

# --- 2. required files --------------------------------------------------------
$required = @(
    'module.prop',
    'customize.sh',
    'uninstall.sh',
    'service.sh',
    'post-fs-data.sh',
    'tablet-spoof.sh',
    'lsposed-enable.sh',
    'install-app.sh',
    'hook-status.sh',
    'verify-targets.sh',
    'check-lsposed-health.sh'
)
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $ModDir $f))) { Fail "required module file missing: $f" }
}
Info "all required files present"

# --- 3. line-ending normalisation --------------------------------------------
# CRLF in a shell script makes it fail on Android with a cryptic error, and
# busybox sh is not forgiving about a UTF-8 BOM either. Normalise to LF, no BOM,
# into a staging copy so the source tree is never mutated.
if ($Clean) {
    if (Test-Path $DistDir)  { Remove-Item $DistDir  -Recurse -Force }
    if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
    Info "cleaned dist/ and build/"
}
New-Item -ItemType Directory -Force -Path $DistDir  | Out-Null
if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$shellExts = @('.sh', '.prop')

function Copy-Normalized([string]$srcFile, [string]$dstFile) {
    $ext = [System.IO.Path]::GetExtension($srcFile).ToLowerInvariant()
    $dstParent = Split-Path -Parent $dstFile
    if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }

    if ($shellExts -contains $ext) {
        $text = [System.IO.File]::ReadAllText($srcFile)
        # strip BOM if present in source
        $text = $text -replace "^\uFEFF", ''
        # normalise any CRLF / lone CR to LF
        $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
        [System.IO.File]::WriteAllText($dstFile, $text, $utf8NoBom)
    } else {
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
    }
}

$staged = 0
Get-ChildItem -LiteralPath $ModDir -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($ModDir.Length).TrimStart('\')
    if ($rel -match '\\\.git\\' -or $_.Name -eq '.DS_Store' -or $_.Name -like '*.orig') { return }
    # The bundled APK is injected separately below (from app/dist), never from module/.
    if ($_.Name -eq 'tablet-spoof.apk' -or $_.Name -eq 'tablet-spoof.apk.version') { return }
    Copy-Normalized $_.FullName (Join-Path $BuildDir $rel)
    $staged++
}
Info "staged $staged file(s) with LF endings"

# --- 3a. embed the NATIVE Zygisk payload -------------------------------------
# The native payload is the primary mechanism (no LSPosed dependency). It is
# compiled ON-DEVICE via the Termux toolchain (src/build-on-device.sh) because
# this host has no NDK, then pulled back here for packaging.
$nativeSo = Join-Path $Root 'src\dist\arm64-v8a.so'
if (Test-Path -LiteralPath $nativeSo) {
    $zygiskDir = Join-Path $BuildDir 'zygisk'
    New-Item -ItemType Directory -Force -Path $zygiskDir | Out-Null
    Copy-Item -LiteralPath $nativeSo -Destination (Join-Path $zygiskDir 'arm64-v8a.so') -Force
    $soSize = (Get-Item -LiteralPath (Join-Path $zygiskDir 'arm64-v8a.so')).Length
    Info "embedded native payload: zygisk/arm64-v8a.so ($soSize bytes)"

    # Sanity: it must be an aarch64 ELF, and it must export the Zygisk entry point.
    $head = [System.IO.File]::ReadAllBytes($nativeSo)
    if ($head.Length -lt 20 -or $head[0] -ne 0x7F -or $head[1] -ne 0x45 -or $head[2] -ne 0x4C -or $head[3] -ne 0x46) {
        Fail "native payload is not an ELF file"
    }
    if ($head[4] -ne 2) { Fail "native payload is not 64-bit" }
    if ($head[18] -ne 0xB7 -or $head[19] -ne 0x00) { Fail "native payload is not AArch64 (e_machine != 0xB7)" }
    # Scan the string table for the loader's entry symbol.
    $txt = [System.Text.Encoding]::ASCII.GetString($head)
    if ($txt -notmatch 'zygisk_module_entry') {
        Fail "native payload does not export zygisk_module_entry - the loader would not find it"
    }
    Info "native payload checks: ELF64 AArch64, exports zygisk_module_entry"
} else {
    Warn "no native payload at $nativeSo - build it on-device first:"
    Warn "  adb push src\\*.hpp src\\*.cpp /data/local/tmp/ ; adb shell su -c 'sh /data/local/tmp/build-on-device.sh'"
    Warn "  then pull /data/local/tmp/tablet-spoof/arm64-v8a.so to src\\dist\\"
}

# --- 3b. embed the LSPosed companion APK -------------------------------------
# The module is the single flashable package, so it carries the hook APK and
# installs it on boot. The APK is NOT compiled here -- app/build.ps1 owns that --
# but we require it to exist so a module zip can never ship without its payload.
$appApk = Join-Path $Root 'app\dist\tablet-spoof-0.1.0.apk'
if (-not (Test-Path -LiteralPath $appApk)) {
    Fail "companion APK not found: $appApk`n  Build it first:  powershell -File .\app\build.ps1"
}
$apkDest = Join-Path $BuildDir 'tablet-spoof.apk'
Copy-Item -LiteralPath $appApk -Destination $apkDest -Force
$apkSize = (Get-Item -LiteralPath $apkDest).Length
Info "embedded companion APK: tablet-spoof.apk ($apkSize bytes)"

# Record the APK's versionCode so the on-device installer can decide whether a
# reinstall is needed, without needing aapt on the device.
#
# aapt2 is resolved by SEARCHING for the toolchain rather than embedding a
# non-ASCII path literal (see the note at the top of this file).
$aapt2Path = $null
$sdkCandidates = New-Object System.Collections.Generic.List[string]
if ($env:TS_SDK) { $sdkCandidates.Add($env:TS_SDK) }
foreach ($cand in @(
        (Join-Path (Split-Path $Root -Parent) '开发工具链\android_build_tools\Sdk'),
        (Join-Path $Root '..\..\开发工具链\android_build_tools\Sdk')
    )) { $sdkCandidates.Add($cand) }
# Structural fallback: look for an "android_build_tools\Sdk" sibling anywhere
# near the project, which works regardless of the parent folder's name.
foreach ($parent in @((Split-Path $Root -Parent), (Split-Path (Split-Path $Root -Parent) -Parent))) {
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { continue }
    Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName 'android_build_tools\Sdk'
        if (Test-Path -LiteralPath $candidate) { $sdkCandidates.Add($candidate) }
    }
}
foreach ($cand in $sdkCandidates) {
    if (-not $cand) { continue }
    $bt = Join-Path $cand 'build-tools'
    if (-not (Test-Path -LiteralPath $bt)) { continue }
    $aapt2Path = Get-ChildItem -LiteralPath $bt -Recurse -Filter 'aapt2.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if ($aapt2Path) { break }
}
$apkVersionCode = ''
if ($aapt2Path) {
    Info "reading APK versionCode via $aapt2Path"
    $badging = & $aapt2Path dump badging $appApk 2>$null
    foreach ($line in $badging) {
        if ($line -match "versionCode='(\d+)'") { $apkVersionCode = $Matches[1]; break }
    }
} else {
    Warn "aapt2 not found; cannot read the APK versionCode"
}
if ($apkVersionCode) {
    Set-Content -LiteralPath (Join-Path $BuildDir 'tablet-spoof.apk.version') -Value $apkVersionCode -NoNewline -Encoding Ascii
    Info "companion APK versionCode = $apkVersionCode"
} else {
    # Not fatal: install-app.sh falls back to "always reinstall".
    Warn "could not read the APK versionCode; installer will always reinstall"
}

# --- 4. pre-flight: shell syntax check if a shell is available ---------------
$sh = $null
foreach ($cand in @('sh', 'bash', 'busybox')) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($c) { $sh = $c.Source; break }
}
if ($sh) {
    Info "shell found ($sh) - running syntax pre-flight"
    Get-ChildItem -LiteralPath $BuildDir -Recurse -Filter '*.sh' | ForEach-Object {
        $out = & $sh -n $_.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { Fail "shell syntax error in $($_.Name):`n$out" }
    }
    Info "shell syntax OK"
} else {
    Warn "no sh/bash on PATH - skipping shell -n syntax check"
}

# --- 5. build the zip, files at ROOT -----------------------------------------
# We write the archive ourselves rather than using Compress-Archive, because
# Compress-Archive (a) nests everything under a top folder and (b) writes
# backslash separators, which Magisk's unzip rejects.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zipName = "$id-$ver.zip"
# prefer dist/tablet-spoof-v1.0.0.zip style naming
$zipName = "$id-$ver.zip"
$zipPath = Join-Path $DistDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $buildFull = (Resolve-Path $BuildDir).Path
        $files = Get-ChildItem -LiteralPath $BuildDir -Recurse -File | Sort-Object FullName
        foreach ($f in $files) {
            # entry name must be relative, forward-slashed, no leading separator
            $rel = $f.FullName.Substring($buildFull.Length).TrimStart('\', '/')
            $entryName = $rel -replace '\\', '/'
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $es = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                $es.Write($bytes, 0, $bytes.Length)
            } finally { $es.Dispose() }
            Info "  + $entryName ($($f.Length) bytes)"
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$zipLen = (Get-Item $zipPath).Length
Info "wrote $zipPath ($zipLen bytes)"

# --- 6. inspect: assert flat root layout -------------------------------------
if ($Inspect -or $true) {
    $za = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = $za.Entries | ForEach-Object { $_.FullName }
    } finally { $za.Dispose() }

    if ($names -notcontains 'module.prop')     { Fail "zip root is missing module.prop - layout is NOT flat" }
    if ($names -notcontains 'customize.sh')    { Fail "zip root is missing customize.sh - layout is NOT flat" }
    if ($names -notcontains 'tablet-spoof.sh') { Fail "zip root is missing tablet-spoof.sh" }
    if ($names -notcontains 'tablet-spoof.apk') { Fail "zip root is missing the bundled companion APK (tablet-spoof.apk)" }
    if ($names -notcontains 'install-app.sh')  { Fail "zip root is missing install-app.sh" }

    $nested = $names | Where-Object { $_ -match '/' -and $_ -notmatch '/' -eq $false }
    # any entry whose FIRST segment is a directory that is not a real module dir
    $badPrefix = @('tablet-spoof/', 'module/', './')
    foreach ($n in $names) {
        foreach ($bp in $badPrefix) {
            if ($n.StartsWith($bp)) { Fail "entry '$n' is nested under '$bp' - zip must be flat" }
        }
    }
    Info "zip layout OK: $($names.Count) entries, module.prop at root"
}

# --- 7. optional self-test ---------------------------------------------------
if ($Verify) {
    $testScript = Join-Path $Root 'tests\scope-guard-test.ps1'
    if (Test-Path $testScript) {
        Info "running scope-guard self-test"
        & $testScript -Root $Root
        if ($LASTEXITCODE -ne 0) { Fail "scope-guard self-test FAILED" }
        Info "scope-guard self-test PASSED"
    } else {
        Warn "tests\scope-guard-test.ps1 not found - skipping self-test"
    }
}

# --- 8. summary --------------------------------------------------------------
Write-Host ''
Write-Host '=== build OK ===' -ForegroundColor Green
Write-Host "  module id : $id"
Write-Host "  version   : $ver ($verCode)"
Write-Host "  artifact  : $zipPath"
Write-Host "  size      : $zipLen bytes"
Write-Host ''
Write-Host '  Flash via Magisk app -> Modules -> Install from storage'
Write-Host '         or APatch app -> Patch/Modules -> Install module'
Write-Host ''
exit 0
