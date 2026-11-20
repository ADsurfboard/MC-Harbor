param([Parameter(Mandatory)][string]$CompilerJavaHome)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-arm64.lock.json') -Raw | ConvertFrom-Json
$dependencies = Join-Path $build 'arm64-deps'
$archive = Join-Path $dependencies $lock.filename
$jdk = Join-Path $dependencies $lock.directory
$runtime = Join-Path $build 'runtime-arm64'
New-Item -ItemType Directory -Path $dependencies -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive) -or
    (Get-Item -LiteralPath $archive).Length -ne $lock.size -or
    (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $lock.sha256) {
    $partial = "$archive.partial"
    Invoke-WebRequest -Uri $lock.url -OutFile $partial -TimeoutSec 600 -UseBasicParsing
    if ((Get-Item -LiteralPath $partial).Length -ne $lock.size -or
        (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $lock.sha256) {
        throw 'ARM64 Java/JavaFX download failed its pinned SHA-256 check.'
    }
    Move-Item -LiteralPath $partial -Destination $archive -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $jdk 'jmods\javafx.controls.jmod'))) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $prefix = [IO.Path]::GetFullPath($dependencies).TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $dependencies $name))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ARM64 Java archive contains an invalid path.'
            }
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $dependencies)
    } finally { $zip.Dispose() }
}
foreach ($module in @('java.base', 'javafx.base', 'javafx.graphics', 'javafx.controls')) {
    if (-not (Test-Path -LiteralPath (Join-Path $jdk "jmods\$module.jmod"))) {
        throw "ARM64 full JDK is missing $module."
    }
}
$jlink = Join-Path $CompilerJavaHome 'bin\jlink.exe'
if (-not (Test-Path -LiteralPath $jlink)) { throw 'JDK 21 jlink is required on the build host.' }
$stamp = Join-Path $runtime 'harbor-runtime.json'
$layoutVersion = 2
if (Test-Path -LiteralPath $stamp) {
    $prior = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
    if ($prior.layoutVersion -eq $layoutVersion -and $prior.sha256 -eq $lock.sha256 -and $prior.modules -eq $lock.modules -and
        (Test-Path -LiteralPath (Join-Path $runtime 'bin\server\jvm.dll'))) {
        return $runtime
    }
}
$stage = Join-Path $build ('runtime-arm64-' + [guid]::NewGuid().ToString('N'))
& $jlink --module-path (Join-Path $jdk 'jmods') --add-modules $lock.modules `
    --strip-debug --no-header-files --no-man-pages --compress=2 --output $stage
if ($LASTEXITCODE -ne 0) { throw 'ARM64 runtime image could not be linked.' }
foreach ($file in @('bin\java.exe','bin\server\jvm.dll','bin\glass.dll','lib\modules')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $file))) { throw "ARM64 runtime is missing $file." }
}
# The pinned Full JDK includes an unused x64 VC runtime alongside its ARM64 DLLs.
# Remove only the exact reviewed file, and fail if another binary references it.
foreach ($unused in $lock.excludedUnusedLibraries) {
    $file = [IO.Path]::GetFullPath((Join-Path $stage $unused.path))
    if (-not $file.StartsWith($stage.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Excluded runtime file escaped the staging directory.'
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $unused.sha256) {
        throw 'Unexpected contents in the unused compatibility library.'
    }
    $name = [IO.Path]::GetFileName($file)
    foreach ($binary in (Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll') -and $_.FullName -ne $file })) {
        $bytes = [IO.File]::ReadAllBytes($binary.FullName)
        if ([Text.Encoding]::ASCII.GetString($bytes).IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            [Text.Encoding]::Unicode.GetString($bytes).IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Runtime binary references excluded library: $($binary.Name)"
        }
    }
    Remove-Item -LiteralPath $file -Force
}
@{sha256=$lock.sha256;version=$lock.version;modules=$lock.modules;architecture='arm64';layoutVersion=$layoutVersion} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'harbor-runtime.json') -Encoding utf8
$prefix = $build.TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($runtime)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runtime replacement must stay inside build/.'
}
if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
Move-Item -LiteralPath $stage -Destination $runtime
return $runtime
