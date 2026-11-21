param([Parameter(Mandatory)][string]$InstallerPath, [ValidateSet('x64','arm64')][string]$Architecture = 'x64')

$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $InstallerPath).Path
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null
$session = $null

function Read-MsiRows([string]$query, [scriptblock]$readRow) {
    $view = $database.OpenView($query)
    try {
        $view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try { & $readRow $record }
            finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
        }
    } finally {
        $view.Close()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
    }
}

try {
    $installer.UILevel = 2
    $database = $installer.OpenDatabase($package, 0)
    $conditions = @(Read-MsiRows 'SELECT `Condition` FROM `LaunchCondition`' { param($record) $record.StringData(1) })
    $systemCondition = @($conditions | Where-Object { $_ -match '\bHARBOR_WINDOWS_BUILD\b' })
    if ($systemCondition.Count -ne 1) { throw 'Expected one system gate using the registry build number.' }

    foreach ($table in @('InstallUISequence', 'InstallExecuteSequence')) {
        $query = 'SELECT {0}Action{0}, {0}Sequence{0} FROM {0}{1}{0}' -f [char]96, $table
        $actions = @{}
        Read-MsiRows $query { param($record) $actions[$record.StringData(1)] = $record.IntegerData(2) }
        if ($actions['AppSearch'] -le 0 -or $actions['LaunchConditions'] -le $actions['AppSearch']) {
            throw "AppSearch must precede LaunchConditions in $table."
        }
    }

    # IGNOREMACHINESTATE gives a restricted handle that cannot install the package.
    $session = $installer.OpenPackage($package, 1)
    $session.Property('Installed') = ''
    $session.Property('VersionNT64') = '603'
    $session.Property('WindowsBuild') = '9600'
    $session.Property('HARBOR_WINDOWS_BUILD') = ''
    if ($session.DoAction('AppSearch') -ne 1) { throw 'The system build registry lookup failed.' }

    $minimumBuild = if ($Architecture -eq 'arm64') { 26100 } else { 17763 }
    $actualBuild = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber)
    if ($session.Property('HARBOR_WINDOWS_BUILD') -ne [string]$actualBuild -or
        $session.EvaluateCondition($systemCondition[0]) -ne [int]($actualBuild -ge $minimumBuild)) {
        throw 'The MSI decision does not match the real Windows build with a legacy WindowsBuild value.'
    }

    $cases = @(
        @{ Name = 'Below minimum build'; Build = [string]($minimumBuild - 1); Bitness = '603'; Installed = ''; Expected = 0 }
        @{ Name = 'Minimum build';       Build = [string]$minimumBuild; Bitness = '603'; Installed = ''; Expected = 1 }
        @{ Name = 'Windows 10 22H2';    Build = '19045'; Bitness = '603'; Installed = ''; Expected = [int]($minimumBuild -le 19045) }
        @{ Name = 'Windows 11 24H2';   Build = '26100'; Bitness = '603'; Installed = ''; Expected = 1 }
        @{ Name = 'Missing build';        Build = '';      Bitness = '603'; Installed = ''; Expected = 0 }
        @{ Name = 'No 64-bit Windows';    Build = '19045'; Bitness = '';    Installed = ''; Expected = 0 }
        @{ Name = 'Existing installation';Build = '';      Bitness = '603'; Installed = '1';Expected = 1 }
    )
    foreach ($case in $cases) {
        $session.Property('HARBOR_WINDOWS_BUILD') = $case.Build
        $session.Property('VersionNT64') = $case.Bitness
        $session.Property('Installed') = $case.Installed
        if ($session.EvaluateCondition($systemCondition[0]) -ne $case.Expected) {
            throw "MSI system gate did not match the expected result: $($case.Name)."
        }
    }
    Write-Output "MSI system gate passed $($cases.Count) cases and the native registry lookup (build $actualBuild)."
} finally {
    foreach ($object in @($session, $database, $installer)) {
        if ($null -ne $object) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($object) }
    }
}
