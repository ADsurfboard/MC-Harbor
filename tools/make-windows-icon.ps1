[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\Assets\Brand\Icon.png'),
    [string]$Output = (Join-Path $PSScriptRoot '..\windows\Assets\App.ico')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$png = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
try {
    $frames = foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $memory = [IO.MemoryStream]::new()
        try {
            $drawing = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $drawing.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                $drawing.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $drawing.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
                $scale = $size / [Math]::Max($png.Width, $png.Height)
                $width = [int][Math]::Round($png.Width * $scale)
                $height = [int][Math]::Round($png.Height * $scale)
                $drawing.DrawImage($png, [Drawing.Rectangle]::new(
                    [int](($size - $width) / 2), [int](($size - $height) / 2), $width, $height))
            } finally { $drawing.Dispose() }
            $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
            [pscustomobject]@{ Size = $size; Bytes = $memory.ToArray() }
        } finally {
            $memory.Dispose()
            $bitmap.Dispose()
        }
    }
} finally { $png.Dispose() }

$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
$stream = [IO.File]::Create($outputPath)
$ico = [IO.BinaryWriter]::new($stream)
try {
    $ico.Write([uint16]0)
    $ico.Write([uint16]1)
    $ico.Write([uint16]$frames.Count)
    $offset = 6 + $frames.Count * 16
    foreach ($frame in $frames) {
        $sizeByte = [byte]($frame.Size % 256)
        $ico.Write($sizeByte)
        $ico.Write($sizeByte)
        $ico.Write([uint16]0)
        $ico.Write([uint16]1)
        $ico.Write([uint16]32)
        $ico.Write([uint32]$frame.Bytes.Length)
        $ico.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $ico.Write([byte[]]$frame.Bytes) }
} finally { $ico.Dispose() }
Get-Item -LiteralPath $outputPath
