[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PublishDirectory,
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture,
    [ValidateSet('Portable', 'Installer')]
    [string]$Format = 'Portable',
    [string]$OutputPath,
    [string]$Wix,
    [string]$WixUiExtension,
    [string]$DotNet
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$publish = (Resolve-Path -LiteralPath $PublishDirectory).Path.TrimEnd('\')
function ReadPeMachine([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid executable: $path" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE offset: $path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}
$machine = ReadPeMachine (Join-Path $publish 'MC Harbor.exe')
if (-not $Architecture) {
    $Architecture = switch ($machine) { 0x8664 {'x64'} 0xAA64 {'arm64'} default {throw 'Unsupported application architecture.'} }
}
$expectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
if ($machine -ne $expectedMachine) { throw 'Application architecture differs from requested package.' }
foreach ($name in @('coreclr.dll','Microsoft.UI.Xaml.dll','Runtime\bin\java.exe','Runtime\bin\server\jvm.dll')) {
    if ((ReadPeMachine (Join-Path $publish $name)) -ne $expectedMachine) { throw "Wrong $Architecture binary: $name" }
}
if ((ReadPeMachine (Join-Path $publish 'Translation\Python\python.exe')) -ne 0x8664) { throw 'Expected the pinned x64 translation worker.' }
$payloadName = if ($Architecture -eq 'arm64') { 'MC-Harbor-Windows-arm64' } else { 'MC-Harbor-Windows' }
if (-not $PSBoundParameters.ContainsKey('Format') -and [IO.Path]::GetExtension($OutputPath) -eq '.msi') {
    $Format = 'Installer'
}
$extension = if ($Format -eq 'Installer') { '.msi' } else { '.zip' }
if (-not $OutputPath) {
    $filename = if ($Format -eq 'Installer') { "MC-Harbor-Windows-$Architecture-Setup.msi" } else { "MC-Harbor-Windows-$Architecture-portable.zip" }
    $OutputPath = Join-Path (Join-Path $root 'build') $filename
}
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDirectory = [IO.Path]::GetDirectoryName($output)
if ($output.StartsWith($publish + '\', [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetExtension($output) -ne $extension) {
    throw "Set an $extension output path outside the publish directory."
}

$required = @(
    'MC Harbor.exe', 'MC Harbor.dll', 'MC Harbor.deps.json', 'MC Harbor.runtimeconfig.json',
    'MC Harbor.pri', 'App.xbf', 'MainWindow.xbf', 'Controls\WallpaperLibraryDialog.xbf',
    'coreclr.dll', 'Microsoft.UI.Xaml.dll',
    'Assets\App.ico', 'Assets\Icon.png', 'Assets\Services.json', 'Assets\Skins\wide\steve.png',
    'Assets\Fonts\FluentSystemIcons-Regular.ttf', 'Assets\Fonts\SourceHanSerifCN-Regular.otf',
    'Assets\Fonts\SourceHanSerifCN-Bold.otf', 'Backend\Backend.jar', 'Backend\HMCLCore.jar',
    'Backend\javafx\javafx-base.jar', 'Backend\javafx\javafx-controls.jar', 'Backend\javafx\javafx-graphics.jar',
    'Runtime\bin\java.exe', 'Runtime\bin\server\jvm.dll', 'Translation\worker.py',
    'Translation\requirements.txt', 'Translation\Python\python.exe'
)
if ($Architecture -eq 'arm64') {
    $required += @('Runtime\bin\glass.dll','Backend\runtime.json','Compatibility\JavaX64\bin\java.exe','Compatibility\JavaX64\bin\server\jvm.dll')
    foreach ($name in @('Compatibility\JavaX64\bin\java.exe','Compatibility\JavaX64\bin\server\jvm.dll')) {
        if ((ReadPeMachine (Join-Path $publish $name)) -ne 0x8664) { throw "Wrong game compatibility binary: $name" }
    }
}
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $publish $file) -PathType Leaf)) {
        throw "Missing required publish file: $file"
    }
}

$intermediate = Join-Path (Join-Path $root 'build') ('package-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $intermediate $payloadName
New-Item -Path $outputDirectory, $payload -ItemType Directory -Force | Out-Null
$files = Get-ChildItem -LiteralPath $publish -Force |
    Where-Object { $_.Name -notin @('MCHarborData', 'ShengganData', 'MCHarbor.portable') } |
    ForEach-Object {
        if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File }
        else { $_ }
    } | Where-Object {
        $parts = $_.FullName.Substring($publish.Length + 1).Split([char]'\')
        $blockedFolders = @('.git', '.codex', '.claude', '.cursor', '.copilot', '.vs', '.idea',
            '.vscode', '.minecraft', 'MCHarborData', 'ShengganData', 'voice-assets', 'sessions',
            'rollouts', 'chat-history', 'chat_history', '__pycache__')
        $blockedSuffixes = @('.pdb', '.dpapi', '.pfx', '.p12', '.key', '.jsonl', '.log', '.suo', '.user', '.pyc', '.pyo')
        $blockedNames = @('AGENTS.md', 'CLAUDE.md', '.cursorrules', 'accounts.json', 'credentials.json',
            'hmcl.json', 'auth.json', 'hosts.yml')
        -not ($parts | Where-Object { $_ -in $blockedFolders }) -and
            $_.Extension -notin $blockedSuffixes -and $_.Name -notin $blockedNames -and
            $_.Name -ne '.env' -and $_.Name -notlike '.env.*'
    }
foreach ($file in $files) {
    $relative = $file.FullName.Substring($publish.Length + 1)
    $destination = Join-Path $payload $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::Copy($file.FullName, $destination)
}
$license = Join-Path $root 'LICENSE'
Copy-Item -LiteralPath $license -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md') -Destination $payload -Force
$licenseDirectory = Join-Path $payload 'Licenses'
New-Item -Path $licenseDirectory -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $root 'Licenses') -File |
    Copy-Item -Destination $licenseDirectory -Force

$payloadFiles = @(Get-ChildItem -LiteralPath $payload -Recurse -File)
$artifact = Join-Path $intermediate ([IO.Path]::GetFileName($output))
if ($Format -eq 'Portable') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.File]::WriteAllText((Join-Path $payload 'MCHarbor.portable'), '')
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $artifact,
        [IO.Compression.CompressionLevel]::Optimal, $true)
    $archive = [IO.Compression.ZipFile]::OpenRead($artifact)
    try {
        $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($entries.Count -ne $payloadFiles.Count + 1) { throw 'The portable archive file count differs from its payload.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) { [void]$names.Add($entry.FullName.Replace('\', '/')) }
        foreach ($file in $required + 'MCHarbor.portable') {
            if (-not $names.Contains($payloadName + '/' + $file.Replace('\', '/'))) {
                throw "The portable archive is missing $file."
            }
        }
    } finally { $archive.Dispose() }
}
else {
    $toolRoot = Join-Path (Split-Path -Parent $root) '_tools'
    if (-not $DotNet) {
        $DotNet = Join-Path $toolRoot 'dotnet\dotnet.exe'
        if (-not (Test-Path -LiteralPath $DotNet)) { $DotNet = 'dotnet' }
    }
    if (-not $Wix) {
        $Wix = Join-Path $toolRoot 'wix-5.0.2-binaries\wix\tools\net6.0\any\wix.dll'
        if (-not (Test-Path -LiteralPath $Wix)) { $Wix = 'wix' }
    }
    if (-not $WixUiExtension) {
        $WixUiExtension = Join-Path $toolRoot 'wix-5.0.2-binaries\wixtoolset.ui.wixext\wixext5\WixToolset.UI.wixext.dll'
        if (-not (Test-Path -LiteralPath $WixUiExtension)) { $WixUiExtension = 'WixToolset.UI.wixext' }
    }
    $version = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $payload 'MC Harbor.dll')).Version.ToString(3)
    $licensePath = Join-Path $intermediate 'License.rtf'
    $text = (Get-Content -LiteralPath $license -Raw -Encoding utf8).Replace('\', '\\').Replace('{', '\{').Replace('}', '\}')
    $text = $text -replace '\r?\n', ('\par' + [Environment]::NewLine)
    [IO.File]::WriteAllText($licensePath, ('{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\f0\fs20 ' + $text + '}'))
    $minimumBuild = if ($Architecture -eq 'arm64') { 26100 } else { 17763 }
    $arguments = @('build', (Join-Path $root 'windows\Installer\Package.wxs'), '-arch', $Architecture, '-wx',
        '-culture', 'zh-cn', '-ext', $WixUiExtension, '-intermediateFolder', $intermediate,
        '-d', "ProductVersion=$version", '-d', "PublishDir=$payload", '-d', "LicenseRtf=$licensePath",
        '-d', "MinimumWindowsBuild=$minimumBuild", '-d', "ProductArchitecture=$Architecture",
        '-pdbtype', 'none', '-o', $artifact)
    $priorRollForward = $env:DOTNET_ROLL_FORWARD
    try {
        $env:DOTNET_ROLL_FORWARD = 'Major'
        if ([IO.Path]::GetExtension($Wix) -eq '.dll') { & $DotNet $Wix @arguments }
        else { & $Wix @arguments }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw 'Windows Installer build did not complete.'
        }
    } finally { $env:DOTNET_ROLL_FORWARD = $priorRollForward }

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($artifact, 0)
    $view = $database.OpenView(('SELECT {0}File{0} FROM {0}File{0}' -f [char]96))
    try {
        $view.Execute()
        $packagedFiles = 0
        while ($null -ne ($record = $view.Fetch())) {
            $packagedFiles++
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
        }
        if ($packagedFiles -ne $payloadFiles.Count) {
            throw "The installer contains $packagedFiles files. Expected $($payloadFiles.Count) payload files."
        }
        $propertyQuery = 'SELECT {0}Value{0} FROM {0}Property{0} WHERE {0}Property{0} = ''SecureCustomProperties''' -f [char]96
        $propertyView = $database.OpenView($propertyQuery)
        $propertyRecord = $null
        try {
            $propertyView.Execute()
            $propertyRecord = $propertyView.Fetch()
            if ($null -eq $propertyRecord -or ($propertyRecord.StringData(1) -split ';') -notcontains 'HARBOR_WINDOWS_BUILD') {
                throw 'The Windows build check must be passed to the elevated installer.'
            }
        } finally {
            if ($null -ne $propertyRecord) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($propertyRecord) }
            $propertyView.Close()
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($propertyView)
        }
    } finally {
        $view.Close()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}
Move-Item -LiteralPath $artifact -Destination $output -Force
Get-Item -LiteralPath $output
