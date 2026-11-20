param(
    [ValidateSet("Build", "Publish", "Installer")]
    [string]$Mode = "Build"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$toolRoot = Split-Path -Parent $repo
$cliHome = Join-Path $toolRoot "_tools\dotnet-home"
$env:DOTNET_CLI_HOME = $cliHome
$env:NUGET_PACKAGES = Join-Path $toolRoot "_tools\nuget"
$env:APPDATA = Join-Path $cliHome "Roaming"
$env:LOCALAPPDATA = Join-Path $cliHome "Local"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
New-Item -ItemType Directory -Force -Path $env:DOTNET_CLI_HOME,$env:NUGET_PACKAGES,$env:APPDATA,$env:LOCALAPPDATA | Out-Null

$sdk = Join-Path $toolRoot "_tools\dotnet\dotnet.exe"
if (-not (Test-Path -LiteralPath $sdk)) {
    $sdkCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $sdkCommand) {
        throw "找不到 .NET 10 SDK。请先运行 tools\setup-dotnet-sdk.ps1。"
    }
    $sdk = $sdkCommand.Source
}
$env:DOTNET_ROOT = Split-Path -Parent $sdk
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"
$sdkVersion = (& $sdk --version).Trim()
if ($LASTEXITCODE -ne 0 -or $sdkVersion -notlike "10.0.*") {
    throw "Windows 客户端需要 .NET 10 SDK，当前版本为 $sdkVersion。"
}

$localJdk = Join-Path (Split-Path -Parent $repo) "_tools\jdk-21"
if (-not $env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $localJdk "bin\javac.exe"))) {
    $env:JAVA_HOME = $localJdk
}
if (-not $env:JAVA_HOME -or -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\javac.exe"))) {
    throw "需要 JDK 21。请设置 JAVA_HOME 后重试。"
}

if (-not $env:HMCL_FX_DIR) {
    $candidate = Join-Path $env:APPDATA ".hmcl\dependencies\windows-x64\openjfx"
    if (Test-Path -LiteralPath $candidate) { $env:HMCL_FX_DIR = $candidate }
}
if (-not $env:HMCL_FX_DIR -and (Test-Path -LiteralPath (Join-Path $repo "vendor\javafx-windows-x64"))) {
    $env:HMCL_FX_DIR = Join-Path $repo "vendor\javafx-windows-x64"
}
if (-not $env:HMCL_FX_DIR) {
    $env:HMCL_FX_DIR = Join-Path $repo "build\windows-javafx"
    & (Join-Path $PSScriptRoot "setup-windows-javafx.ps1") -Destination $env:HMCL_FX_DIR
}

Push-Location $repo
try {
    python tools/build-backend-windows.py
    if ($LASTEXITCODE -ne 0) { throw "Java 后端构建失败。" }
    python tools/make-soundbank.py
    if ($LASTEXITCODE -ne 0) { throw "界面音效库构建失败。" }

    $buildRoot = [IO.Path]::GetFullPath((Join-Path $repo "build"))
    $runtime = [IO.Path]::GetFullPath((Join-Path $buildRoot "Runtime"))
    $requiredPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $runtime.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "运行时输出目录越出了 build 目录。"
    }
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    & (Join-Path $env:JAVA_HOME "bin\jlink.exe") `
        --add-modules ALL-MODULE-PATH `
        --strip-debug --no-header-files --no-man-pages --compress=2 `
        --output $runtime
    if ($LASTEXITCODE -ne 0) { throw "Java 运行时构建失败。" }

    & (Join-Path $PSScriptRoot 'setup-windows-translation.ps1')
    & (Join-Path $PSScriptRoot 'make-windows-icon.ps1')
    $project = Join-Path $repo "windows\MCHarbor.Windows.csproj"
    & $sdk restore $project -r win-x64 --configfile (Join-Path $repo "windows\NuGet.Config") --ignore-failed-sources -p:NuGetAudit=false
    if ($LASTEXITCODE -ne 0) { throw ".NET 依赖还原失败。" }
    if ($Mode -in @('Publish', 'Installer')) {
        $publish = Join-Path $repo "build\MC-Harbor-Windows"
        & $sdk publish $project -c Release -r win-x64 --self-contained true `
            --no-restore -p:HMCL_FX_DIR=$env:HMCL_FX_DIR -o $publish
        if ($LASTEXITCODE -ne 0) { throw ".NET 客户端发布失败。请确认旧版本已退出。" }
        $packageFormat = if ($Mode -eq 'Installer') { 'Installer' } else { 'Portable' }
        & (Join-Path $PSScriptRoot 'package-windows.ps1') -PublishDirectory $publish -Format $packageFormat -DotNet $sdk
    }
    else {
        & $sdk build $project -c Debug --no-restore -p:HMCL_FX_DIR=$env:HMCL_FX_DIR
    }
    if ($LASTEXITCODE -ne 0) { throw ".NET 客户端构建失败。" }
}
finally {
    Pop-Location
}
