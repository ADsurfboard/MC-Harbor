param(
    [string]$Version = "10.0.404",
    [ValidateSet('auto','x64','arm64')][string]$Architecture = 'auto'
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$toolRoot = Split-Path -Parent $repo
if ($Architecture -eq 'auto') {
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $Architecture = if ($native -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$folder = if ($Architecture -eq 'arm64') { '_tools\dotnet-arm64' } else { '_tools\dotnet' }
$installDir = Join-Path $toolRoot $folder
$installer = Join-Path $toolRoot "_tools\dotnet-install.ps1"
$toolsDir = Split-Path -Parent $installDir
$dotnet = Join-Path $installDir "dotnet.exe"
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

if (Test-Path -LiteralPath $dotnet) {
    $installed = (& $dotnet --version).Trim()
    if ($installed -eq $Version) {
        Write-Host ".NET SDK $installed 已位于 $installDir"
        return
    }
}

if (-not (Test-Path -LiteralPath $installer)) {
    Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installer
}

& $installer -Version $Version -InstallDir $installDir -Architecture $Architecture

$env:DOTNET_ROOT = $installDir
$env:PATH = "$installDir;$env:PATH"
$installed = (& $dotnet --version).Trim()
if ($installed -notlike "10.0.*") {
    throw "预期安装 .NET 10 SDK，实际版本为 $installed。"
}
Write-Host ".NET SDK $installed 已安装到 $installDir"
