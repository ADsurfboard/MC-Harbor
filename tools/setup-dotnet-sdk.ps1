param(
    [string]$Version = "10.0.404"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$toolRoot = Split-Path -Parent $repo
$installDir = Join-Path $toolRoot "_tools\dotnet"
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

& $installer -Version $Version -InstallDir $installDir -Architecture x64

$env:DOTNET_ROOT = $installDir
$env:PATH = "$installDir;$env:PATH"
$installed = (& $dotnet --version).Trim()
if ($installed -notlike "10.0.*") {
    throw "预期安装 .NET 10 SDK，实际版本为 $installed。"
}
Write-Host ".NET SDK $installed 已安装到 $installDir"
