[CmdletBinding()]
param([string]$Sdk = $env:TS_SDK)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Sdk) { $Sdk = Join-Path (Split-Path (Split-Path $root -Parent) -Parent) '..\开发工具链\android_build_tools\Sdk' }
$Sdk = (Resolve-Path -LiteralPath $Sdk).Path
$bt = Get-ChildItem -LiteralPath (Join-Path $Sdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$androidJar = Get-ChildItem -LiteralPath (Join-Path $Sdk 'platforms') -Filter android.jar -Recurse | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
$stage = Join-Path $env:TEMP 'tablet-spoof-native-bridge'
New-Item -ItemType Directory -Path "$stage\classes", "$stage\dex", "$root\output" -Force | Out-Null
& javac -encoding UTF-8 -source 8 -target 8 -cp $androidJar -d "$stage\classes" "$root\Bridge.java"
if ($LASTEXITCODE -ne 0) { throw 'Java build failed' }
$classes = @(Get-ChildItem "$stage\classes" -Recurse -Filter *.class | Select-Object -ExpandProperty FullName)
& "$($bt.FullName)\d8.bat" --min-api 26 --lib $androidJar --output "$stage\dex" @classes
if ($LASTEXITCODE -ne 0) { throw 'DEX build failed' }
Copy-Item -LiteralPath "$stage\dex\classes.dex" -Destination "$root\output\bridge.dex"
Write-Host 'BRIDGE_BUILD_OK'
