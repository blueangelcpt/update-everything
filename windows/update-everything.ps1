#Requires -Version 5.1

<#
.SYNOPSIS
    Update Windows and every supported application updater that is installed.

.DESCRIPTION
    Installs available Windows updates, then runs each supported application
    updater that is present on the machine. Every updater is run in its own
    silent or unattended mode, so the script never stops to ask a question.

    Supported system updater:
        Windows Update, through the PSWindowsUpdate module when it is
        available, or through the Windows Update Agent COM API otherwise.

    Supported application updaters:
        WinGet, Chocolatey, Scoop, Patch My PC Home Updater, and the
        Microsoft Store.

    A failing updater does not stop the others. The script reports what
    succeeded, what was skipped, and what failed, and exits with a non-zero
    exit code if anything failed.

    This script intentionally does not update project or language
    dependencies such as npm project packages, pip environments, NuGet
    packages, or application-specific self-updaters.

.PARAMETER SystemOnly
    Install Windows updates only, and do not run any application updater.

.PARAMETER SkipWindowsUpdate
    Run the application updaters only, and do not install Windows updates.
    -SkipSystemUpdate is an alias, matching the Linux and macOS
    --skip-system-update option.

.PARAMETER IncludeDrivers
    Include driver updates offered by Windows Update. Software updates only
    are installed by default.

.PARAMETER NoCleanup
    Do not remove superseded package versions or cached installers.

.PARAMETER PatchMyPCPath
    Full path to PatchMyPC.exe. Use this when the portable Patch My PC Home
    Updater is kept somewhere the script does not search, such as a
    downloads folder.

.PARAMETER DryRun
    Detect installed updaters and report the mutating commands that would run,
    without installing updates, accepting EULAs, or cleaning up packages.

.PARAMETER ShowVersion
    Print the script version and exit.

.EXAMPLE
    PS> .\update-everything.ps1

    Install Windows updates and run every detected application updater.

.EXAMPLE
    PS> .\update-everything.ps1 -SkipWindowsUpdate

    Run the application updaters only.

.NOTES
    Run this script from an elevated PowerShell session. Windows Update and
    Chocolatey both require administrator privileges. Scoop refuses to run
    elevated, so it is skipped in an elevated session and updated when the
    script is run as your normal user.

    Exit codes: 0 success, 1 an updater failed, 2 invalid or conflicting
    options or an unsupported platform. Pressing Ctrl+C stops the script
    without printing a summary, and its exit code is then set by PowerShell
    rather than by this script.
#>

[CmdletBinding()]
param(
    [switch]$SystemOnly,
    [Alias('SkipSystemUpdate')]
    [switch]$SkipWindowsUpdate,
    [switch]$IncludeDrivers,
    [switch]$NoCleanup,
    [string]$PatchMyPCPath,
    [switch]$DryRun,
    [Alias('Version')]
    [switch]$ShowVersion,
    # Collected so that an unrecognised option is reported by this script with
    # exit code 2, rather than as a PowerShell parameter binding error.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$UnrecognisedArguments
)

Set-StrictMode -Version 3.0

$ScriptName = $MyInvocation.MyCommand.Name
$ScriptVersion = '2.0.0'

# Progress bars corrupt the output when an updater writes to the console
# while the script is also writing to it.
$ProgressPreference = 'SilentlyContinue'

$script:Succeeded = @()
$script:Failed = @()
$script:Skipped = @()
$script:Planned = @()
$script:RebootRequired = $false
$script:LastExternalExitCode = 0
$script:ExitCode = 0

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# The start-up banner: the Update Everything ring-and-tick logo as ASCII art,
# beside the name, version, tagline and a subtitle. The ring's four arcs are
# coloured light blue, blue, green and grey around a green tick. Consoles
# narrower than 72 columns get a short form instead, and a subtitle too long
# for the console is shortened rather than wrapped.
#
# Colour: consoles that process virtual-terminal sequences (Windows 10 and
# later, Windows Terminal, PowerShell 7) get the brand's 24-bit colours; other
# consoles get the nearest console colours; NO_COLOR turns colour off.
#
# This file stays pure ASCII so that Windows PowerShell 5.1 reads it correctly
# without a byte order mark, so the divider and bullet are built from their
# code points.
$script:BannerMinimumWidth = 72
$script:BannerTextColumn = 45
$script:BannerSgr = @{
    BL = '38;2;96;165;250'
    B  = '38;2;59;130;246'
    G  = '38;2;34;197;94'
    N  = '1;38;2;34;197;94'
    S  = '38;2;156;163;175'
    T  = '38;2;229;231;235'
    D  = '38;2;107;114;128'
}
$script:BannerConsoleColor = @{
    BL = 'DarkCyan'
    B  = 'Blue'
    G  = 'Green'
    N  = 'Green'
    S  = 'Gray'
    T  = 'White'
    D  = 'DarkGray'
}

function Get-BannerColorMode {
    if ($env:NO_COLOR) {
        return 'None'
    }
    $virtualTerminal = $false
    try {
        $virtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected
    } catch {
        Write-Verbose "Virtual-terminal support is unknown: $($_.Exception.Message)"
    }
    if ($virtualTerminal) {
        return 'Ansi'
    }
    return 'Console'
}

function Write-BannerLine {
    param(
        [object[]]$Segment = @(),
        [ValidateSet('Ansi', 'Console', 'None')]
        [string]$Mode = 'None'
    )
    if ($Mode -eq 'Console') {
        foreach ($item in $Segment) {
            if ($item[1]) {
                Write-Host ([string]$item[0]) -NoNewline -ForegroundColor $script:BannerConsoleColor[$item[1]]
            } else {
                Write-Host ([string]$item[0]) -NoNewline
            }
        }
        Write-Host ''
        return
    }

    $escape = [string][char]27
    $line = New-Object System.Text.StringBuilder
    foreach ($item in $Segment) {
        if ($Mode -eq 'Ansi' -and $item[1]) {
            [void]$line.Append($escape + '[' + $script:BannerSgr[$item[1]] + 'm' + [string]$item[0] + $escape + '[0m')
        } else {
            [void]$line.Append([string]$item[0])
        }
    }
    Write-Host $line.ToString()
}

function Get-ConsoleWidth {
    $width = 0
    try {
        $width = [int]$Host.UI.RawUI.WindowSize.Width
    } catch {
        Write-Verbose "The console width is unavailable: $($_.Exception.Message)"
    }
    if ($width -le 0) {
        $width = 80
    }
    return $width
}

function Show-Banner {
    param([string]$Subtitle = '')

    $mode = Get-BannerColorMode
    $width = Get-ConsoleWidth
    $previousEncoding = $null
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
    } catch {
        Write-Verbose "The console output encoding cannot be changed: $($_.Exception.Message)"
    }

    try {
        if ($width -lt $script:BannerMinimumWidth) {
            Write-BannerLine -Mode $mode -Segment @(@(([string][char]0x25CF), 'G'), @(' ', $null), @('Update Everything', 'N'), @(' ', $null), @($ScriptVersion, 'D'))
            Write-BannerLine -Mode $mode -Segment @(@('  ', $null), @('Everything, carefully.', 'T'))
            if ($Subtitle) {
                Write-BannerLine -Mode $mode -Segment @(@('  ', $null), @($Subtitle, 'D'))
            }
        } else {
            # Leave the last column free, so a full line never wraps.
            $room = $width - $script:BannerTextColumn - 1
            if ($Subtitle.Length -gt $room) {
                $Subtitle = $Subtitle.Substring(0, $room - 3) + '...'
            }
            $bar = [string][char]0x2502
            $rows = @(
                @(@('                  ', $null), @('%', 'BL')),
                @(@('           ', $null), @('@@@@@@@@', 'BL'), @('  ', $null), @('@@@@@@@%', 'B')),
                @(@('        ', $null), @('@@@@@@@@@@@', 'BL'), @('  ', $null), @('@%%%%@@@@@#', 'B')),
                @(@('      ', $null), @('@@@@@@@@@@@@@%', 'BL'), @(' ', $null), @('@@@@@@%%%@@@@', 'B')),
                @(@('     ', $null), @('@@@@@@@@@@', 'BL'), @('          ', $null), @('@@@@@%%@@@', 'B')),
                @(@('    ', $null), @('@@@@@@@@', 'BL'), @('                ', $null), @('@@@@@@@+', 'B')),
                @(@('  ', $null), @('@@', 'G'), @('   ', $null), @('=@@', 'BL'), @('                    ', $null), @('@@', 'B'), @('    ', $null), @('@@', 'S')),
                @(@('  ', $null), @('@@@@@@', 'G'), @('                  ', $null), @('@@', 'G'), @('    ', $null), @('@@@@@@', 'S')),
                @(@(' ', $null), @('@@%%%@@', 'G'), @('                ', $null), @('@@@@@', 'G'), @('   ', $null), @('@@@@@@@', 'S')),
                @(@(' ', $null), @('@%%%%@@', 'G'), @('              ', $null), @('@@@%@@%', 'G'), @('   ', $null), @(':@@@@@@', 'S'), @('    ', $null), @($bar, 'D'), @(' ', $null), @('Update Everything', 'N'), @(' ', $null), @($ScriptVersion, 'D')),
                @(@(' ', $null), @('@%%%%@', 'G'), @('    ', $null), @('@@@@', 'G'), @('     ', $null), @('*@@%@@@', 'G'), @('      ', $null), @('@@@@@@', 'S'), @('    ', $null), @($bar, 'D'), @(' ', $null), @('Everything, carefully.', 'T')),
                @(@(' ', $null), @('@%%%%@', 'G'), @('    ', $null), @('@@@@@@', 'G'), @('  ', $null), @('@@@@@@', 'G'), @('        ', $null), @('@@@@@@', 'S'), @('    ', $null), @($bar, 'D'), @(' ', $null), @($Subtitle, 'D')),
                @(@(' ', $null), @('@%%%%@@', 'G'), @('    ', $null), @('@@@%@@@@@@@', 'G'), @('          ', $null), @('@@@@@@', 'S')),
                @(@(' ', $null), @('@@%%%@@', 'G'), @('      ', $null), @('@@@%%@@@', 'G'), @('          ', $null), @('@@@@@@@', 'S')),
                @(@('  ', $null), @('@@%%%@@', 'G'), @('       ', $null), @('@@@@', 'G'), @('           ', $null), @('@@@@@@@', 'S')),
                @(@('  ', $null), @('@@@%%%@@', 'G'), @('                    ', $null), @('@@@@@@@@', 'S')),
                @(@('   ', $null), @('@@@%%%@@@', 'G'), @('                ', $null), @('@@@@@@@@@', 'S')),
                @(@('     ', $null), @('@@%%%%@@@@', 'G'), @('          ', $null), @('@@@@@@@@@@', 'S')),
                @(@('      ', $null), @('@@@@%%%%@@@@@@', 'G'), @('=@@@@@@@@@@@@@', 'S')),
                @(@('        ', $null), @('@@@@@%%%%%@', 'G'), @('  ', $null), @('@@@@@@@@@@@', 'S')),
                @(@('           ', $null), @('@@@@@@@@', 'G'), @('  ', $null), @('@@@@@@@@', 'S')),
                @(@('                  ', $null), @('@', 'G'), @('  ', $null), @('@', 'S'))
            )
            foreach ($row in $rows) {
                Write-BannerLine -Mode $mode -Segment $row
            }
        }
        Write-Host ''
    } finally {
        if ($null -ne $previousEncoding) {
            try {
                [Console]::OutputEncoding = $previousEncoding
            } catch {
                Write-Verbose "The console output encoding cannot be restored: $($_.Exception.Message)"
            }
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OperatingSystemName {
    $name = 'Windows'

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $name = $os.Caption.Trim()
    } catch {
        Write-Verbose "Unable to read Win32_OperatingSystem: $($_.Exception.Message)"
    }

    try {
        $current = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $release = $current.PSObject.Properties['DisplayVersion']
        if (-not $release) { $release = $current.PSObject.Properties['ReleaseId'] }
        if ($release -and $release.Value) { $name = "$name $($release.Value)" }
    } catch {
        Write-Verbose "Unable to read the Windows release version: $($_.Exception.Message)"
    }

    return "$name (build $([Environment]::OSVersion.Version.Build))"
}

function Invoke-Task {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Section $Label

    try {
        & $Action
        if ($DryRun) {
            $script:Planned += $Label
            Write-Info "$Label was evaluated; no changes were made."
        } else {
            $script:Succeeded += $Label
            Write-Info "$Label completed."
        }
    } catch {
        $script:Failed += "$Label ($($_.Exception.Message))"
        Write-Fail "$Label failed: $($_.Exception.Message) Continuing with the remaining updaters."
    }
}

function Add-SkippedItem {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $script:Skipped += "$Label - $Reason"
    Write-Info "Skipping $Label - $Reason."
}

function Assert-WindowsUpdateResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($Result.ResultCode -eq 2) { return }

    $hresultText = ''
    if ($Result.PSObject.Properties['HResult']) {
        $hresultText = ' (HRESULT 0x{0:X8})' -f $Result.HResult
    }
    throw "Windows Update $Operation reported result code $($Result.ResultCode)$hresultText."
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Tolerate
    )

    $displayArguments = @($Arguments | ForEach-Object {
        if ($_ -match '[\s`"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
    })

    if ($DryRun) {
        Write-Host "[DRY-RUN] `"$FilePath`" $($displayArguments -join ' ')"
        $script:LastExternalExitCode = 0
        return
    }

    Write-Info "Running: `"$FilePath`" $($displayArguments -join ' ')"

    # The command writes to this function's output stream, which reaches the
    # console unchanged, so its progress stays visible and redirectable.
    & $FilePath @Arguments
    $script:LastExternalExitCode = $LASTEXITCODE

    if ($SuccessExitCodes -notcontains $script:LastExternalExitCode) {
        $name = [System.IO.Path]::GetFileName($FilePath)
        $message = "$name exited with code $($script:LastExternalExitCode)."

        if ($Tolerate) {
            Write-Warn $message
        } else {
            throw $message
        }
    }
}

function Join-ExistingPath {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    if (-not $Root) { return $null }

    $candidate = Join-Path -Path $Root -ChildPath $ChildPath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }

    return $null
}

function Get-CommandPath {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) { return $command.Source }
    }

    return $null
}

function Get-ProgramFilesRoot {
    $roots = @(
        $env:ProgramW6432,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )

    return @($roots | Where-Object { $_ } | Select-Object -Unique)
}

function Get-PackageFolderVersion {
    param([Parameter(Mandatory = $true)][string]$Name)

    # A package folder is named Publisher.Package_1.22.3.0_x64__hash, and its
    # version must be compared as a version rather than as a string.
    $match = [regex]::Match($Name, '_(\d+(?:\.\d+){1,3})_')
    if (-not $match.Success) { return [version]'0.0' }

    return [version]$match.Groups[1].Value
}

function Get-WinGetPath {
    param([bool]$IsElevated = $false)

    # Never execute a PATH or per-user App Execution Alias candidate from an
    # elevated session. Both locations can be changed by an unprivileged user.
    if (-not $IsElevated) {
        $onPath = Get-CommandPath -Names @('winget.exe')
        if ($onPath) { return $onPath }

        $alias = Join-ExistingPath -Root $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps\winget.exe'
        if ($alias) { return $alias }
    }

    $packages = @()
    foreach ($root in (Get-ProgramFilesRoot)) {
        $packageRoot = Join-Path -Path $root -ChildPath 'WindowsApps'
        $packages += @(Get-ChildItem -Path $packageRoot -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' `
            -Directory -ErrorAction SilentlyContinue)
    }

    $wingetCandidates = @()
    foreach ($package in $packages) {
        $path = Join-ExistingPath -Root $package.FullName -ChildPath 'winget.exe'
        if ($path) {
            $wingetCandidates += [pscustomobject]@{
                Path = $path
                Version = Get-PackageFolderVersion -Name $package.Name
            }
        }
    }

    $newest = $wingetCandidates |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1

    if ($newest) { return $newest.Path }

    return $null
}

function Get-WinGetVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $raw = & $Path '--version' 2>$null | Select-Object -First 1
    } catch {
        return $null
    }

    if (-not $raw) { return $null }

    $match = [regex]::Match($raw, '(\d+)\.(\d+)')
    if (-not $match.Success) { return $null }

    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value)
}

function Get-ChocolateyPath {
    $configured = Join-ExistingPath -Root $env:ChocolateyInstall -ChildPath 'bin\choco.exe'
    if ($configured) { return $configured }

    return (Join-ExistingPath -Root $env:ProgramData -ChildPath 'chocolatey\bin\choco.exe')
}

function Test-PatchMyPCPublisher {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    } catch {
        Write-Verbose "Unable to verify the Patch My PC signature: $($_.Exception.Message)"
        return $false
    }

    $expectedPublisher = '(?i)(?:^|,\s*)(?:CN|O)=("?Patch My PC(?:\\,|,) LLC"?)(?:,|$)'
    return ($signature.Status -eq 'Valid' -and
        $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match $expectedPublisher)
}

function Get-PatchMyPCPath {
    if ($PatchMyPCPath) {
        if (-not (Test-Path -LiteralPath $PatchMyPCPath -PathType Leaf)) {
            throw "The path given by -PatchMyPCPath does not exist: $PatchMyPCPath"
        }
        if (-not (Test-PatchMyPCPublisher -Path $PatchMyPCPath)) {
            throw 'The file given by -PatchMyPCPath does not have a valid Patch My PC Authenticode signature.'
        }
        return $PatchMyPCPath
    }

    # Automatic discovery is limited to machine-wide locations. Portable
    # copies in user-writable directories require an explicit parameter.
    foreach ($root in (Get-ProgramFilesRoot)) {
        $candidate = Join-ExistingPath -Root $root -ChildPath 'Patch My PC\PatchMyPC.exe'
        if ($candidate -and (Test-PatchMyPCPublisher -Path $candidate)) { return $candidate }
        if ($candidate) { Write-Warn "Ignoring an untrusted Patch My PC candidate: $candidate" }
    }

    $appPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PatchMyPC.exe')

    foreach ($appPath in $appPaths) {
        try {
            $entry = Get-ItemProperty -Path $appPath -ErrorAction Stop
            $registered = $entry.PSObject.Properties['(default)']
            if ($registered -and $registered.Value -and
                (Test-Path -LiteralPath $registered.Value -PathType Leaf) -and
                (Test-PatchMyPCPublisher -Path $registered.Value)) {
                return $registered.Value
            }
        } catch {
            Write-Verbose "No App Paths entry at ${appPath}."
        }
    }

    return $null
}

function Update-WindowsUpdate {
    if ($DryRun) {
        Write-Info 'Using the Windows Update Agent COM API for a read-only update search.'
        Update-WindowsUpdateWithComApi
        return
    }

    $module = Get-Module -ListAvailable -Name 'PSWindowsUpdate' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($module) {
        Write-Info "Using the PSWindowsUpdate module (version $($module.Version))."
        Update-WindowsUpdateWithModule
    } else {
        Write-Info 'Using the Windows Update Agent COM API.'
        Update-WindowsUpdateWithComApi
    }
}

function Update-WindowsUpdateWithModule {
    Import-Module -Name 'PSWindowsUpdate' -ErrorAction Stop

    $arguments = @{
        Install      = $true
        AcceptAll    = $true
        IgnoreReboot = $true
        Confirm      = $false
        ErrorAction  = 'Stop'
    }

    if (-not $IncludeDrivers) { $arguments['NotCategory'] = 'Drivers' }

    $results = Get-WindowsUpdate @arguments

    if (-not $results) {
        Write-Info 'No applicable Windows updates were found.'
    } else {
        foreach ($result in $results) {
            Write-Info "Installed: $($result.Title)"
        }

        $failedResults = @($results | Where-Object {
            $_.PSObject.Properties['Result'] -and $_.Result -match 'Failed|Aborted'
        })
        if ($failedResults.Count -gt 0) {
            throw "$($failedResults.Count) Windows update(s) reported a failed or aborted result."
        }
    }

    try {
        if (Get-WURebootStatus -Silent -ErrorAction Stop) { $script:RebootRequired = $true }
    } catch {
        Write-Verbose "Unable to query the reboot status: $($_.Exception.Message)"
    }
}

function Get-WindowsUpdateCriterion {
    $criteria = 'IsInstalled=0 AND IsHidden=0'
    if (-not $IncludeDrivers) { $criteria += " AND Type='Software'" }
    return $criteria
}

function Update-WindowsUpdateWithComApi {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = 'update-everything'

    $criteria = Get-WindowsUpdateCriterion

    Write-Info 'Searching for available updates...'
    $searchResult = $session.CreateUpdateSearcher().Search($criteria)

    Assert-WindowsUpdateResult -Result $searchResult -Operation 'search'

    if ($searchResult.Updates.Count -eq 0) {
        Write-Info 'No applicable Windows updates were found.'
        return
    }

    $selected = New-Object -ComObject 'Microsoft.Update.UpdateColl'

    foreach ($update in $searchResult.Updates) {
        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Warn "Skipping `"$($update.Title)`" because it requires user input."
            Add-SkippedItem -Label "Windows update: $($update.Title)" -Reason 'requires user input'
            continue
        }

        if (-not $DryRun -and -not $update.EulaAccepted) { $update.AcceptEula() }

        Write-Info "Selected: $($update.Title)"
        $null = $selected.Add($update)
    }

    if ($selected.Count -eq 0) {
        Write-Info 'Every available update requires user input, so none were installed.'
        return
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] Would download and install $($selected.Count) selected Windows update(s)."
        return
    }

    Write-Info "Downloading $($selected.Count) update(s)..."
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $selected
    $downloadResult = $downloader.Download()
    $downloadHadErrors = ($downloadResult.ResultCode -ne 2)
    if ($downloadHadErrors) {
        Write-Warn "Windows Update download reported result code $($downloadResult.ResultCode). Installable downloads will still be attempted."
    }

    $installable = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $selected) {
        if ($update.IsDownloaded) {
            $null = $installable.Add($update)
        } else {
            Write-Warn "Skipping `"$($update.Title)`" because it did not download."
            Add-SkippedItem -Label "Windows update: $($update.Title)" -Reason 'download failed'
            $downloadHadErrors = $true
        }
    }

    if ($installable.Count -eq 0) {
        throw 'No update could be downloaded.'
    }

    Write-Info "Installing $($installable.Count) update(s)..."
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $installable
    $installResult = $installer.Install()

    if ($installResult.RebootRequired) { $script:RebootRequired = $true }

    # ResultCode 3 is partial success and must still make the task fail.
    Assert-WindowsUpdateResult -Result $installResult -Operation 'installation'
    Write-Info 'All selected updates were installed.'

    if ($downloadHadErrors) {
        throw 'One or more selected Windows updates failed to download.'
    }
}

function Update-WinGetPackage {
    param([Parameter(Mandatory = $true)][string]$Path)

    $version = Get-WinGetVersion -Path $Path
    if ($version) { Write-Info "Detected WinGet version $version." }

    $arguments = @(
        'upgrade',
        '--all',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )

    # Packages whose installed version cannot be determined are left alone
    # unless --include-unknown is passed, which WinGet added in 1.2.
    if ($version -and $version -ge [version]'1.2') {
        $arguments += '--include-unknown'
    }

    if ($version -and $version -ge [version]'1.4') {
        $arguments += '--disable-interactivity'
    }

    Invoke-External -FilePath $Path -Arguments @('source', 'update') -Tolerate
    $sourceUpdateExitCode = $script:LastExternalExitCode

    # 0x8A15002B is "no applicable upgrade found", which is a normal outcome.
    Invoke-External -FilePath $Path -Arguments $arguments -SuccessExitCodes @(0, -1978335189)

    if ($sourceUpdateExitCode -ne 0) {
        throw "WinGet upgraded packages, but source update exited with code $sourceUpdateExitCode."
    }
}

function Update-ChocolateyPackage {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Chocolatey documents 0, 1605, 1614, 1641 and 3010 as its valid exit codes.
    # 1641 and 3010 mean a package installed successfully and wants a reboot.
    # 350 and 1604 are the reboot-detection codes; they are accepted here only
    # so that the reboot can be reported before the task is failed below. Any
    # other code, including 2, is a genuine failure and must not be swallowed.
    Invoke-External -FilePath $Path `
        -Arguments @('upgrade', 'all', '--yes', '--no-progress', '--use-package-exit-codes') `
        -SuccessExitCodes @(0, 1605, 1614, 1641, 3010, 350, 1604)

    if ($script:LastExternalExitCode -in @(1641, 3010)) { $script:RebootRequired = $true }

    if ($script:LastExternalExitCode -eq 350) {
        $script:RebootRequired = $true
        throw 'Chocolatey did not run because a reboot is already pending.'
    }

    if ($script:LastExternalExitCode -eq 1604) {
        $script:RebootRequired = $true
        throw 'Chocolatey stopped part-way through because a package requested a reboot.'
    }
}

function Update-ScoopPackage {
    param([Parameter(Mandatory = $true)][string]$Path)

    Invoke-External -FilePath $Path -Arguments @('update')
    Invoke-External -FilePath $Path -Arguments @('update', '*')

    if (-not $NoCleanup) {
        $cleanupErrors = @()
        try {
            Invoke-External -FilePath $Path -Arguments @('cleanup', '*')
        } catch {
            $cleanupErrors += $_.Exception.Message
            Write-Warn $_.Exception.Message
        }
        try {
            Invoke-External -FilePath $Path -Arguments @('cache', 'rm', '*')
        } catch {
            $cleanupErrors += $_.Exception.Message
            Write-Warn $_.Exception.Message
        }
        if ($cleanupErrors.Count -gt 0) {
            throw "Scoop update succeeded, but $($cleanupErrors.Count) cleanup operation(s) failed."
        }
    }
}

function Update-PatchMyPCApplication {
    param([Parameter(Mandatory = $true)][string]$Path)

    # /s is Patch My PC Home Updater's fully silent automatic mode. /auto
    # performs automatic updates but still opens its graphical interface.
    if ($DryRun) {
        Write-Host "[DRY-RUN] `"$Path`" /s"
        return
    }

    Write-Info "Running: `"$Path`" /s"
    $process = Start-Process -FilePath $Path -ArgumentList '/s' -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "PatchMyPC.exe exited with code $($process.ExitCode)."
    }
}

function Update-MicrosoftStoreApplication {
    if ($DryRun) {
        Write-Host '[DRY-RUN] Would request a Microsoft Store application update scan.'
        return
    }

    $instance = Get-CimInstance -Namespace 'Root\cimv2\mdm\dmmap' `
        -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
        Select-Object -First 1

    if (-not $instance) {
        throw 'The application management class returned no instance.'
    }

    $result = Invoke-CimMethod -InputObject $instance -MethodName 'UpdateScanMethod' -ErrorAction Stop

    if ($result.ReturnValue -ne 0) {
        throw "The Microsoft Store update scan returned $($result.ReturnValue)."
    }

    Write-Info 'The Microsoft Store update scan started. It installs whatever it finds in the background.'
}

function Test-PendingReboot {
    if ($script:RebootRequired) { return $true }

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { return $true }
    }

    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name 'PendingFileRenameOperations' -ErrorAction Stop
        if ($sessionManager.PendingFileRenameOperations) { return $true }
    } catch {
        Write-Verbose 'No pending file rename operations are queued.'
    }

    return $false
}

function Write-Summary {
    param([Parameter(Mandatory = $true)][string]$OperatingSystem)

    Write-Section 'Summary'
    Write-Host "Operating system: $OperatingSystem"

    if ($script:Succeeded.Count -gt 0) {
        Write-Host ''
        Write-Host 'Completed:'
        foreach ($item in $script:Succeeded) { Write-Host "  - $item" }
    }

    if ($script:Planned.Count -gt 0) {
        Write-Host ''
        Write-Host 'Evaluated (dry run; not executed):'
        foreach ($item in $script:Planned) { Write-Host "  - $item" }
    }

    if ($script:Skipped.Count -gt 0) {
        Write-Host ''
        Write-Host 'Not installed or skipped:'
        foreach ($item in $script:Skipped) { Write-Host "  - $item" }
    }

    if ($script:Failed.Count -gt 0) {
        Write-Host ''
        Write-Host 'Failed:' -ForegroundColor Red
        foreach ($item in $script:Failed) { Write-Host "  - $item" -ForegroundColor Red }
    }

    if (Test-PendingReboot) {
        Write-Host ''
        Write-Host '[NOTICE] A system reboot is required to finish installing one or more updates.'
    }

    if ($script:Failed.Count -gt 0) {
        Write-Fail 'Updates finished with one or more failures.'
        $script:ExitCode = 1
    } else {
        if ($DryRun) {
            Write-Info 'Dry run completed without executing mutating commands.'
        } else {
            Write-Info 'All detected updaters completed successfully.'
        }
    }
}

function Invoke-SystemUpdate {
    param([Parameter(Mandatory = $true)][bool]$IsElevated)

    if ($SkipWindowsUpdate) {
        Add-SkippedItem -Label 'Windows Update' -Reason 'requested with -SkipWindowsUpdate'
        return
    }

    if (-not $IsElevated -and -not $DryRun) {
        $script:Failed += 'Windows Update (administrator privileges are required)'
        Write-Fail 'Windows Update needs an elevated PowerShell session. Re-run this script as an administrator.'
        return
    }

    Invoke-Task -Label 'Windows Update' -Action { Update-WindowsUpdate }
}

function Invoke-ApplicationUpdate {
    param([Parameter(Mandatory = $true)][bool]$IsElevated)

    $wingetPath = Get-WinGetPath -IsElevated $IsElevated
    if ($wingetPath) {
        Invoke-Task -Label 'WinGet packages' -Action { Update-WinGetPackage -Path $wingetPath }
    } else {
        Add-SkippedItem -Label 'WinGet' -Reason 'not installed'
    }

    $chocolateyPath = Get-ChocolateyPath
    if (-not $chocolateyPath) {
        Add-SkippedItem -Label 'Chocolatey' -Reason 'not installed'
    } elseif (-not $IsElevated) {
        Add-SkippedItem -Label 'Chocolatey' -Reason 'requires an elevated PowerShell session'
    } else {
        Invoke-Task -Label 'Chocolatey packages' -Action { Update-ChocolateyPackage -Path $chocolateyPath }
    }

    $scoopPath = Get-CommandPath -Names @('scoop.cmd', 'scoop.exe')
    if (-not $scoopPath) {
        Add-SkippedItem -Label 'Scoop' -Reason 'not installed'
    } elseif ($IsElevated) {
        # Scoop refuses to run elevated, because it installs into the profile
        # of the user who owns the installation.
        Add-SkippedItem -Label 'Scoop' -Reason 'must be updated from a session that is not elevated'
    } else {
        Invoke-Task -Label 'Scoop packages' -Action { Update-ScoopPackage -Path $scoopPath }
    }

    $patchMyPcPath = $null
    $patchLookupFailed = $false
    try {
        $patchMyPcPath = Get-PatchMyPCPath
    } catch {
        $patchLookupFailed = $true
        $script:Failed += "Patch My PC applications ($($_.Exception.Message))"
        Write-Fail "Patch My PC discovery failed: $($_.Exception.Message) Continuing with the remaining updaters."
    }

    if ($patchMyPcPath) {
        Invoke-Task -Label 'Patch My PC applications' -Action { Update-PatchMyPCApplication -Path $patchMyPcPath }
    } elseif (-not $patchLookupFailed) {
        Add-SkippedItem -Label 'Patch My PC Home Updater' -Reason 'not found, or pass -PatchMyPCPath to point at it'
    }

    $storeClass = Get-CimClass -Namespace 'Root\cimv2\mdm\dmmap' `
        -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction SilentlyContinue

    if (-not $storeClass) {
        Add-SkippedItem -Label 'Microsoft Store' -Reason 'the application management class is not available'
    } elseif (-not $IsElevated -and -not $DryRun) {
        # The MDM bridge provider only answers an administrator, so calling it
        # from a normal session fails with access denied rather than scanning.
        Add-SkippedItem -Label 'Microsoft Store' -Reason 'the update scan requires an elevated PowerShell session'
    } else {
        Invoke-Task -Label 'Microsoft Store update scan' -Action { Update-MicrosoftStoreApplication }
    }
}

function Invoke-Main {
    if ($UnrecognisedArguments) {
        Write-Fail "Unknown option: $($UnrecognisedArguments -join ' ')"
        Write-Host "Run 'Get-Help $ScriptName -Detailed' for the supported options."
        $script:ExitCode = 2
        return
    }

    if ($ShowVersion) {
        Write-Host "$ScriptName $ScriptVersion"
        return
    }

    if ($SystemOnly -and $SkipWindowsUpdate) {
        Write-Fail '-SystemOnly and -SkipWindowsUpdate (-SkipSystemUpdate) cannot be used together.'
        $script:ExitCode = 2
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Write-Fail 'This script supports Windows only.'
        $script:ExitCode = 2
        return
    }

    $operatingSystem = Get-OperatingSystemName
    $isElevated = Test-Administrator

    $bannerSubtitle = $operatingSystem
    if ($DryRun) {
        $bannerSubtitle += ' - dry run'
    }
    Show-Banner -Subtitle $bannerSubtitle
    Write-Info "Detected operating system: $operatingSystem"

    if ($DryRun) {
        Write-Info 'Dry-run mode will not require elevation or execute mutating commands.'
    } elseif ($isElevated) {
        Write-Info 'Running with administrator privileges.'
    } else {
        Write-Warn 'Running without administrator privileges. Windows Update and Chocolatey cannot run.'
    }

    Invoke-SystemUpdate -IsElevated $isElevated

    if ($SystemOnly) {
        Add-SkippedItem -Label 'Application updaters' -Reason 'requested with -SystemOnly'
    } else {
        Invoke-ApplicationUpdate -IsElevated $isElevated
    }

    Write-Summary -OperatingSystem $operatingSystem
}

# Unlike the shell scripts, this one does not print a summary when it is
# interrupted. A try/finally around Invoke-Main would run on Ctrl+C, but only
# after a blocking Windows Update COM call returns, inside a pipeline that is
# already stopping, and with an exit code PowerShell 5.1 does not let the
# script choose, so it could not report an interruption reliably.
if ($env:UPDATE_EVERYTHING_TESTING -ne '1') {
    Invoke-Main
    exit $script:ExitCode
}
