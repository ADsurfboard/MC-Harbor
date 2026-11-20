param(
    [string]$Destination = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repo "build"))
$target = if ($Destination) { [IO.Path]::GetFullPath($Destination) } else { [IO.Path]::GetFullPath((Join-Path $buildRoot "windows-javafx")) }
$requiredPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "JavaFX 依赖必须写入仓库 build 目录。"
}
New-Item -ItemType Directory -Force -Path $target | Out-Null

$lock = Get-Content -Raw (Join-Path $PSScriptRoot "windows-javafx.lock.json") | ConvertFrom-Json
$base = "https://repo.maven.apache.org/maven2/$($lock.group.Replace('.', '/'))"
foreach ($artifact in $lock.artifacts) {
    $filename = "$($artifact.module)-$($lock.version)-$($lock.classifier).jar"
    $output = Join-Path $target $filename
    if (Test-Path -LiteralPath $output) {
        $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA1).Hash.ToLowerInvariant()
        if ($hash -eq $artifact.sha1) { continue }
    }

    $url = "$base/$($artifact.module)/$($lock.version)/$filename"
    $partial = "$output.partial"
    Invoke-WebRequest -Uri $url -OutFile $partial
    $downloadHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($downloadHash -ne $artifact.sha1) {
        Remove-Item -LiteralPath $partial -Force
        throw "JavaFX 文件校验失败：$filename"
    }
    Move-Item -LiteralPath $partial -Destination $output -Force
}

Write-Host "Windows x64 OpenJFX $($lock.version) 已校验并准备好。"
