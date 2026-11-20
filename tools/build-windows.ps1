param(
    [ValidateSet('Build','Publish','Installer')][string]$Mode = 'Build',
    [ValidateSet('x64','arm64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$toolRoot = Split-Path -Parent $repo
$cliHome = Join-Path $toolRoot '_tools\dotnet-home'
$env:DOTNET_CLI_HOME = $cliHome
$env:NUGET_PACKAGES = Join-Path $toolRoot '_tools\nuget'
$env:APPDATA = Join-Path $cliHome 'Roaming'
$env:LOCALAPPDATA = Join-Path $cliHome 'Local'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:PYTHONDONTWRITEBYTECODE = '1'
New-Item -ItemType Directory -Force -Path $cliHome,$env:NUGET_PACKAGES,$env:APPDATA,$env:LOCALAPPDATA | Out-Null
$sdk = Join-Path $toolRoot '_tools\dotnet\dotnet.exe'
$native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$armSdk = Join-Path $toolRoot '_tools\dotnet-arm64\dotnet.exe'
if ($native -eq 'ARM64' -and (Test-Path -LiteralPath $armSdk)) { $sdk = $armSdk }
if (-not (Test-Path -LiteralPath $sdk)) {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw 'Run tools/setup-dotnet-sdk.ps1 to install .NET 10.' }
    $sdk = $command.Source
}
$env:DOTNET_ROOT = Split-Path -Parent $sdk
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"
$version = (& $sdk --version).Trim()
if ($LASTEXITCODE -ne 0 -or $version -notlike '10.0.*') { throw 'The Windows client requires .NET SDK 10.' }
if (-not $env:JAVA_HOME) {
    $candidate = Join-Path $toolRoot '_tools\jdk-21'
    if (Test-Path -LiteralPath (Join-Path $candidate 'bin\javac.exe')) { $env:JAVA_HOME = $candidate }
}
if (-not $env:JAVA_HOME -or -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
    throw 'Set JAVA_HOME to a JDK 21 that runs on the build host.'
}
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) {
    $candidate = Join-Path $repo 'build\translation-python\tools\python.exe'
    if (-not (Test-Path -LiteralPath $candidate)) { throw 'Python 3 is required for backend and payload checks.' }
    $pythonPath = $candidate
} else { $pythonPath = $python.Source }
$fx = if ($env:HMCL_FX_DIR) { $env:HMCL_FX_DIR } else { Join-Path $repo 'build\windows-javafx' }
if (-not $env:HMCL_FX_DIR) { & (Join-Path $PSScriptRoot 'setup-windows-javafx.ps1') -Destination $fx }
$env:HMCL_FX_DIR = $fx
$rid = "win-$Architecture"
$platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
$build = Join-Path $repo 'build'
Push-Location $repo
try {
    & $pythonPath tools/build-backend-windows.py
    if ($LASTEXITCODE -ne 0) { throw 'Java backend compilation failed.' }
    & $pythonPath tools/make-soundbank.py
    if ($LASTEXITCODE -ne 0) { throw 'Interface soundbank preparation failed.' }
    $gameRuntime = & (Join-Path $PSScriptRoot 'setup-windows-game-compat.ps1')
    if ($Architecture -eq 'arm64') {
        $runtime = & (Join-Path $PSScriptRoot 'setup-windows-arm64.ps1') -CompilerJavaHome $env:JAVA_HOME
    } else { $runtime = $gameRuntime }
    & (Join-Path $PSScriptRoot 'setup-windows-translation.ps1')
    & (Join-Path $PSScriptRoot 'make-windows-icon.ps1')
    $manifestDirectory = Join-Path $build $rid
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $manifest = [ordered]@{
        schemaVersion=1;clientArchitecture=$Architecture;javaArchitecture=$Architecture
        javaFxMode=$(if($Architecture -eq 'arm64'){'modules'}else{'classpath'})
        gameArchitecture='x64';gameJavaFxMode='classpath';translationPythonArchitecture='x64'
        minimumWindowsBuild=$(if($Architecture -eq 'arm64'){26100}else{17763})
    }
    $manifestPath = Join-Path $manifestDirectory 'runtime.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $project = Join-Path $repo 'windows\MCHarbor.Windows.csproj'
    # MSBuild cannot normalize a command-line global property; use an absolute
    # extensions path so NuGet's generated WinUI imports are found from any cwd.
    $intermediate = (Join-Path $repo "windows\obj\$rid").TrimEnd('\') + '\'
    $properties = @("-p:Platform=$platform", "-p:HMCL_FX_DIR=$fx", "-p:HarborRuntimeDirectory=$runtime",
        "-p:HarborGameRuntimeDirectory=$gameRuntime", "-p:HarborRuntimeManifest=$manifestPath",
        "-p:BaseIntermediateOutputPath=$intermediate", "-p:MSBuildProjectExtensionsPath=$intermediate")
    & $sdk restore $project -r $rid --configfile windows/NuGet.Config --ignore-failed-sources -p:NuGetAudit=false @properties
    if ($LASTEXITCODE -ne 0) { throw '.NET dependency restore failed.' }
    if ($Mode -eq 'Build') {
        & $sdk build $project -c Debug -r $rid --no-restore @properties
        if ($LASTEXITCODE -ne 0) { throw '.NET build failed.' }
    } else {
        $name = if ($Architecture -eq 'x64') { 'MC-Harbor-Windows' } else { 'MC-Harbor-Windows-arm64' }
        $publish = Join-Path $build $name
        if (Test-Path -LiteralPath $publish) {
            $resolved = [IO.Path]::GetFullPath($publish)
            if (-not $resolved.StartsWith([IO.Path]::GetFullPath($build).TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Publish output must stay inside build/.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
        & $sdk publish $project -c Release -r $rid --self-contained true --no-restore @properties -o $publish
        if ($LASTEXITCODE -ne 0) { throw '.NET publish failed.' }
        & $pythonPath tools/check-windows-payload.py --directory $publish --architecture $Architecture
        if ($LASTEXITCODE -ne 0) { throw 'Published payload architecture checks failed.' }
        $format = if ($Mode -eq 'Installer') { 'Installer' } else { 'Portable' }
        & (Join-Path $PSScriptRoot 'package-windows.ps1') -PublishDirectory $publish -Architecture $Architecture -Format $format -DotNet $sdk
    }
} finally { Pop-Location }
