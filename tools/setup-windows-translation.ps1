$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo 'build'
$runtime = Join-Path $build 'translation-python'
$python = Join-Path $runtime 'tools\python.exe'
if (Test-Path -LiteralPath $python -PathType Leaf) { return }

$downloads = Join-Path $build 'translation-downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$archive = Join-Path $downloads 'python.3.12.10.nupkg'
$sha256 = '0EB85C2DFCCCCF1B17352DE4C397F69194035B7D37149EACC16F1147D93DE3B8'
if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ne $sha256) {
    $stage = "$archive.partial"
    $url = 'https://api.nuget.org/v3-flatcontainer/python/3.12.10/python.3.12.10.nupkg'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 90 -Uri $url -OutFile $stage
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $stage).Hash -ne $sha256) { throw '本机翻译 Python 包校验失败。' }
    Move-Item -LiteralPath $stage -Destination $archive -Force
}

$expanded = Join-Path $build "translation-python-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $expanded | Out-Null
& tar.exe -xf $archive -C $expanded tools
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath (Join-Path $expanded 'tools\python.exe'))) {
    throw '本机翻译 Python 环境解包失败。'
}
Move-Item -LiteralPath $expanded -Destination $runtime
