$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$lock = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-arm64.lock.json') -Raw | ConvertFrom-Json).gameCompatibility
$dependencies = Join-Path $repo 'build\arm64-deps'
$archive = Join-Path $dependencies $lock.filename
$runtime = Join-Path $dependencies $lock.directory
New-Item -ItemType Directory -Path $dependencies -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -ne $lock.size -or
    (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $lock.sha256) {
    $partial = "$archive.partial"
    Invoke-WebRequest -Uri $lock.url -OutFile $partial -TimeoutSec 600 -UseBasicParsing
    if ((Get-Item -LiteralPath $partial).Length -ne $lock.size -or
        (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $lock.sha256) {
        throw 'Game compatibility Java failed its pinned SHA-256 check.'
    }
    Move-Item -LiteralPath $partial -Destination $archive -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'bin\java.exe'))) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $prefix = [IO.Path]::GetFullPath($dependencies).TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $dependencies $entry.FullName.Replace('/', '\')))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Compatibility Java archive contains an invalid path.'
            }
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $dependencies)
    } finally { $zip.Dispose() }
}
return $runtime
