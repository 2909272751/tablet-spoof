<#
================================================================================
 tablet-spoof / app/build.ps1   --  LSPosed (libxposed API 102) companion APK
================================================================================
 Pure command-line build: javac + d8 + aapt2 + zipalign + apksigner.
 NO Android Gradle Plugin, NO NDK, NO network.

   .\build.ps1                     build the PROVEN variant (hooks active)  [default]
   .\build.ps1 -Inert              build the inert variant (no hooks) for A/B
   .\build.ps1 -Sabotage           TEST build: corrupt the hook targets so resolution
                                   must fail, proving the loud-degradation path fires
   .\build.ps1 -KeepBuildDirectory keep the staging dir for inspection
   .\build.ps1 -Install            also adb install to the connected device
   .\build.ps1 -Verify             extra checks on the produced APK

 The default build now produces the PROVEN configuration: the hook set was
 confirmed on-device end-to-end (pad entry appears -> privacy dialog ->
 LoginQrCodeForAndroidPad -> live QR). Variant switches are patched in the
 STAGED COPY ONLY, so the source tree always reflects the default and no
 accidental edit can flip it.

 Toolchain paths are resolved from $PSScriptRoot (never hardcoded absolute
 strings) because this workspace path contains non-ASCII characters. A .ps1
 without a UTF-8 BOM is decoded as ANSI by Windows PowerShell 5.1, so keeping
 this file pure ASCII makes it encoding-independent.

 Override with $env:TS_SDK / $env:TS_JDK / $env:R8_JAR if needed.
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$KeepBuildDirectory,
    [switch]$Install,
    [switch]$Verify,
    [switch]$Inert,
    [switch]$Sabotage
)

$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host "[app-build] $m" }
function Fail([string]$m) { Write-Host "[app-build] ERROR: $m" -ForegroundColor Red; exit 1 }

$app = $PSScriptRoot
$project = Split-Path $app -Parent

# --- locate the toolchain ----------------------------------------------------
# NOTE: The workspace path contains non-ASCII characters. Windows PowerShell 5.1
# decodes a .ps1 without a UTF-8 BOM as ANSI, so any non-ASCII literal in THIS
# file would be corrupted (observed: the SDK path resolved to mojibake and the
# build failed). This script is therefore kept pure ASCII and discovers the
# toolchain by SEARCHING for it rather than by embedding its name.
function Find-Dir([string[]]$candidates, [string]$what) {
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    Fail "Could not locate $what. Checked:`n  $($candidates -join "`n  ")"
}

# Search upward from the project for a directory named "android_build_tools",
# then for "Sdk" / "jdk*" inside it. Pure structural discovery: no non-ASCII.
function Find-BuildToolsRoot([string]$start) {
    $dir = Get-Item -LiteralPath $start
    for ($i = 0; $i -lt 8 -and $dir; $i++) {
        $candidate = Join-Path $dir.FullName 'android_build_tools'
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        $child = Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'android_build_tools\Sdk') } |
            Select-Object -First 1
        if ($child) { return (Resolve-Path -LiteralPath (Join-Path $child.FullName 'android_build_tools')).Path }
        $dir = $dir.Parent
    }
    return $null
}

$buildToolsRoot = if ($env:TS_TOOLS_ROOT) { $env:TS_TOOLS_ROOT } else { Find-BuildToolsRoot $project }
if (-not $buildToolsRoot) {
    Fail "Could not find 'android_build_tools' near $project. Set `$env:TS_TOOLS_ROOT."
}
Info "tools root  : $buildToolsRoot"

$sdk = if ($env:TS_SDK) { $env:TS_SDK } else { Find-Dir @((Join-Path $buildToolsRoot 'Sdk')) 'the Android SDK' }

$jdk = if ($env:TS_JDK) { $env:TS_JDK } else {
    $jdkRoot = Get-ChildItem -LiteralPath $buildToolsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'jdk*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $jdkRoot) { Fail "No jdk* directory under $buildToolsRoot" }
    $jdkRoot.FullName
}
if (-not (Test-Path -LiteralPath (Join-Path $jdk 'bin\javac.exe'))) { Fail "No javac.exe under $jdk" }

$platformDir = Get-ChildItem -LiteralPath (Join-Path $sdk 'platforms') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $platformDir) { Fail "No platform under $sdk\platforms" }
$platform = $platformDir.Name

$toolsDir = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $toolsDir) { Fail "No build-tools under $sdk\build-tools" }
$tools = $toolsDir.FullName

$androidJarSource = Join-Path $platformDir.FullName 'android.jar'
$javac      = Join-Path $jdk 'bin\javac.exe'
$java       = Join-Path $jdk 'bin\java.exe'
$jar        = Join-Path $jdk 'bin\jar.exe'
$keytool    = Join-Path $jdk 'bin\keytool.exe'
$aapt2      = Join-Path $tools 'aapt2.exe'
$zipalign   = Join-Path $tools 'zipalign.exe'
$apksigner  = Join-Path $tools 'apksigner.bat'

# --- resolve a WORKING d8 jar ------------------------------------------------
# Some build-tools ship a d8.bat whose d8.jar is missing or too old (R8 3.3.20
# dies with "Cannot invoke String.length() because <parameter1> is null" while
# dexing). Resolve the jar explicitly rather than trusting d8.bat.
$d8Candidates = @()
if ($env:R8_JAR) { $d8Candidates += $env:R8_JAR }
$d8Candidates += @(Get-ChildItem -LiteralPath (Join-Path $sdk 'd8') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'r8-*.jar' } | Sort-Object Name -Descending | ForEach-Object FullName)
$d8Candidates += @(Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'd8.jar' } | ForEach-Object FullName)
$d8Jar = $d8Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $d8Jar) { Fail "No D8/R8 jar found. Set `$env:R8_JAR to a com.android.tools:r8 jar." }

Info "sdk         : $sdk (platform $platform)"
Info "build-tools : $tools"
Info "jdk         : $jdk"
Info "d8 jar      : $d8Jar"

$env:JAVA_HOME = $jdk
$env:Path = (Join-Path $jdk 'bin') + ';' + $env:Path

foreach ($needed in @($androidJarSource, $javac, $java, $jar, $keytool, $aapt2, $zipalign, $apksigner)) {
    if (-not (Test-Path -LiteralPath $needed)) { Fail "Build tool missing: $needed" }
}

# --- read the version from the framework metadata ----------------------------
$propPath = Join-Path $app 'META-INF\xposed\module.prop'
if (-not (Test-Path -LiteralPath $propPath)) { Fail "missing META-INF\xposed\module.prop" }
$props = @{}
foreach ($line in Get-Content -LiteralPath $propPath) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = $line -split '=', 2
    $props[$k.Trim()] = $v.Trim()
}
$ver = $props['version']
$modId = $props['id']
if (-not $ver) { Fail "module.prop has no version" }
if (-not $modId) { Fail "module.prop has no id" }
Info "module id=$modId version=$ver"

# --- staging -----------------------------------------------------------------
$stage = Join-Path $env:TEMP ('tspoof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$aapt2Dir = Join-Path $stage 'aapt2'
New-Item -ItemType Directory -Path $aapt2Dir -Force | Out-Null

function Run-Native([string]$name, [scriptblock]$action) {
    & $action
    if ($LASTEXITCODE -ne 0) { Fail "$name failed with exit code $LASTEXITCODE" }
}

try {
    Copy-Item -LiteralPath $androidJarSource -Destination $stage
    $androidJar = Join-Path $stage 'android.jar'
    foreach ($folder in @('stub-src', 'src', 'res', 'META-INF', 'libs')) {
        Copy-Item -LiteralPath (Join-Path $app $folder) -Destination $stage -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $app 'AndroidManifest.xml') -Destination $stage
    foreach ($folder in @('stubs', 'classes', 'dex', 'out')) {
        New-Item -ItemType Directory -Path (Join-Path $stage $folder) -Force | Out-Null
    }

    # --- select the variant in the STAGED COPY ONLY ---------------------------
    # The source tree always holds the PROVEN configuration (INSTALL_HOOKS=true).
    # -Inert patches the staged copy to false. Patching the staged copy means the
    # built artifact can never drift from what the source says.
    $stagedHook = Join-Path $stage 'src\io\github\tabletspoof\TabletSpoofHook.java'
    if (-not (Test-Path -LiteralPath $stagedHook)) { Fail "staged TabletSpoofHook.java not found" }
    $text = [System.IO.File]::ReadAllText($stagedHook)
    if ($Inert) {
        $patched = $text -replace 'INSTALL_HOOKS = true', 'INSTALL_HOOKS = false'
        if ($patched -eq $text) { Fail "could not find 'INSTALL_HOOKS = true' to make inert" }
        [System.IO.File]::WriteAllText($stagedHook, $patched, (New-Object System.Text.UTF8Encoding($false)))
        Info "VARIANT: INERT - INSTALL_HOOKS=false (no hooks; A/B control build)"
    } else {
        if ($text -notmatch 'INSTALL_HOOKS = true') {
            Fail "source TabletSpoofHook.java is not in the proven (INSTALL_HOOKS=true) state"
        }
        Info "VARIANT: PROVEN - INSTALL_HOOKS=true (hook set active)"
    }

    # --- sabotage variant: corrupt hook targets so resolution MUST fail -------
    # A fallback that has never been observed firing is indistinguishable from no
    # fallback at all. This build exists solely to prove the loud-degradation path
    # writes its status file, instead of the miss going unnoticed.
    if ($Sabotage) {
        $stagedHooks = Join-Path $stage 'src\io\github\tabletspoof\Hooks.java'
        if (-not (Test-Path -LiteralPath $stagedHooks)) { Fail "staged Hooks.java not found" }
        $h = [System.IO.File]::ReadAllText($stagedHooks)
        $patched = $h -replace 'SABOTAGE_FORCE_MISS = false', 'SABOTAGE_FORCE_MISS = true'
        if ($patched -eq $h) { Fail "could not find 'SABOTAGE_FORCE_MISS = false' to sabotage" }
        [System.IO.File]::WriteAllText($stagedHooks, $patched, (New-Object System.Text.UTF8Encoding($false)))
        Info "VARIANT: SABOTAGE - hook targets deliberately corrupted; miss path must fire"
    }

    # --- 1. compile the libxposed API stubs ----------------------------------
    $stubs = @(Get-ChildItem -LiteralPath (Join-Path $stage 'stub-src') -Recurse -Filter '*.java' | ForEach-Object FullName)
    if ($stubs.Count -eq 0) { Fail "no API stubs found in stub-src" }
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $stage 'src') -Recurse -Filter '*.java' | ForEach-Object FullName)
    if ($sources.Count -eq 0) { Fail "no module sources found in src" }
    $serviceJar = Join-Path $stage 'libs\service-classes.jar'
    if (-not (Test-Path -LiteralPath $serviceJar)) { Fail "libs\service-classes.jar missing" }

    Info "compiling API stubs ($($stubs.Count) files)"
    Run-Native 'API stub compilation' {
        & $javac -encoding UTF-8 -nowarn -source 8 -target 8 -bootclasspath $androidJar -d (Join-Path $stage 'stubs') @stubs
    }

    Info "compiling module ($($sources.Count) files)"
    $compilePath = (Join-Path $stage 'stubs') + ';' + $serviceJar
    Run-Native 'Module compilation' {
        & $javac -encoding UTF-8 -nowarn -source 8 -target 8 -bootclasspath $androidJar -classpath $compilePath -d (Join-Path $stage 'classes') @sources
    }

    $classesJar = Join-Path $stage 'classes.jar'
    Run-Native 'JAR creation' { & $jar -cf $classesJar -C (Join-Path $stage 'classes') . }

    Info "dexing"
    Run-Native 'DEX conversion' {
        & $java -Xmx3072M -cp $d8Jar com.android.tools.r8.D8 --min-api 26 --lib $androidJar --output (Join-Path $stage 'dex') $classesJar $serviceJar
    }

    Info "packaging resources"
    $compiledRes = Join-Path $stage 'resources.zip'
    Run-Native 'Resource compilation' { & $aapt2 compile --dir (Join-Path $stage 'res') -o $compiledRes }
    $unsigned = Join-Path $stage 'out\module.apk'
    Run-Native 'APK linking' {
        & $aapt2 link -o $unsigned --manifest (Join-Path $stage 'AndroidManifest.xml') -I $androidJar --min-sdk-version 26 --target-sdk-version 34 $compiledRes
    }

    # --- 2. inject classes.dex + META-INF -------------------------------------
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $archive = [System.IO.Compression.ZipFile]::Open($unsigned, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $dex = Join-Path $stage 'dex\classes.dex'
        if (-not (Test-Path -LiteralPath $dex)) { Fail "dexing produced no classes.dex" }
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $dex, 'classes.dex') | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $stage 'META-INF') -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $relative) | Out-Null
        }
    } finally { $archive.Dispose() }

    $aligned = Join-Path $stage 'out\module-aligned.apk'
    Run-Native 'APK alignment' { & $zipalign -f 4 $unsigned $aligned }

    # --- 3. sign ---------------------------------------------------------------
    $dist = Join-Path $app 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    # Inert builds get a distinct filename so the A/B control can never be
    # mistaken for the deliverable.
    $variant = if ($Inert) { '-inert' } elseif ($Sabotage) { '-sabotage' } else { '' }
    $output = Join-Path $dist "tablet-spoof-$ver$variant.apk"
    $keystore = Join-Path $app 'debug.keystore'
    $env:TSPOOF_KEYPASS = 'android'
    if (-not (Test-Path -LiteralPath $keystore)) {
        Info "generating local test keystore"
        Run-Native 'Test key generation' {
            & $keytool -genkeypair -keystore $keystore -storepass:env TSPOOF_KEYPASS -keypass:env TSPOOF_KEYPASS `
                -alias tabletspoof -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=TabletSpoof, O=Local, C=CN'
        }
    }
    Run-Native 'APK signing' {
        & $apksigner sign --ks $keystore --ks-key-alias tabletspoof --ks-pass env:TSPOOF_KEYPASS --key-pass env:TSPOOF_KEYPASS --out $output $aligned
    }
    Run-Native 'Signature verification' { & $apksigner verify $output }

    # --- 4. verify -------------------------------------------------------------
    if ($Verify -or $true) {
        $za = [System.IO.Compression.ZipFile]::OpenRead($output)
        try { $names = $za.Entries | ForEach-Object { $_.FullName } } finally { $za.Dispose() }
        foreach ($required in @('classes.dex', 'META-INF/xposed/module.prop', 'META-INF/xposed/scope.list', 'META-INF/xposed/java_init.list', 'AndroidManifest.xml')) {
            if ($names -notcontains $required) { Fail "APK is missing $required" }
        }
        Info "APK layout OK ($($names.Count) entries; xposed metadata present)"

        # The xposed metadata and classes.dex must be covered by the JAR manifest
        # digests, otherwise the signature does not protect them and LSPosed (or
        # Android) may reject the package.
        $mf = $null
        $za = [System.IO.Compression.ZipFile]::OpenRead($output)
        try {
            $entry = $za.Entries | Where-Object { $_.FullName -eq 'META-INF/MANIFEST.MF' } | Select-Object -First 1
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $mf = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } finally { $za.Dispose() }
        if (-not $mf) { Fail "APK has no META-INF/MANIFEST.MF (v1 signature missing)" }
        foreach ($protected in @('classes.dex', 'META-INF/xposed/module.prop', 'META-INF/xposed/scope.list', 'META-INF/xposed/java_init.list')) {
            if ($mf -notmatch [regex]::Escape($protected)) { Fail "$protected is NOT covered by the JAR signature" }
        }
        Info "signature covers classes.dex + xposed metadata"

        # Echo the scope whitelist so a wrong scope can never pass silently.
        $scope = $null
        $za = [System.IO.Compression.ZipFile]::OpenRead($output)
        try {
            $entry = $za.Entries | Where-Object { $_.FullName -eq 'META-INF/xposed/scope.list' } | Select-Object -First 1
            if ($entry) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $scope = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        } finally { $za.Dispose() }
        $scopePkgs = ($scope -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        Info "scope.list = $($scopePkgs -join ', ')"
        if ($scopePkgs.Count -ne 2 -or $scopePkgs -notcontains 'com.tencent.mm' -or $scopePkgs -notcontains 'com.tencent.wework') {
            Fail "scope.list must contain EXACTLY com.tencent.mm and com.tencent.wework (found: $($scopePkgs -join ', '))"
        }

        if ($Inert) {
            Info "VARIANT: inert (INSTALL_HOOKS=false) - installs no hooks; A/B control"
        } elseif ($Sabotage) {
            Info "VARIANT: SABOTAGE (INSTALL_HOOKS=true + corrupted targets) - miss path must fire"
        } else {
            Info "VARIANT: PROVEN (INSTALL_HOOKS=true) - the confirmed working configuration"
        }
    }

    $size = (Get-Item -LiteralPath $output).Length
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    Write-Host ''
    Write-Host '=== app build OK ===' -ForegroundColor Green
    Write-Host "  apk      : $output"
    Write-Host "  size     : $size bytes"
    Write-Host "  sha256   : $hash"

    if ($Install) {
        $adb = 'E:\Desktop\platform-tools\adb.exe'
        if (-not (Test-Path -LiteralPath $adb)) { Fail "adb not found at $adb" }
        Info "installing to device"
        Run-Native 'adb install' { & $adb install -r $output }
    }
} finally {
    Remove-Item Env:TSPOOF_KEYPASS -ErrorAction SilentlyContinue
    if (-not $KeepBuildDirectory -and (Test-Path -LiteralPath $stage)) {
        $resolved = [IO.Path]::GetFullPath($stage)
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.Path]::GetFileName($resolved).StartsWith('tspoof-')) {
            Fail "Refusing to remove unexpected build directory: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0
