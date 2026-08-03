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

.PARAMETER IncludeDrivers
    Include driver updates offered by Windows Update. Software updates only
    are installed by default.

.PARAMETER NoCleanup
    Do not remove superseded package versions or cached installers.

.PARAMETER PatchMyPCPath
    Full path to PatchMyPC.exe. Use this when the portable Patch My PC Home
    Updater is kept somewhere the script does not search, such as a
    downloads folder.

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
#>

[CmdletBinding()]
param(
    [switch]$SystemOnly,
    [switch]$SkipWindowsUpdate,
    [switch]$IncludeDrivers,
    [switch]$NoCleanup,
    [string]$PatchMyPCPath,
    [Alias('Version')]
    [switch]$ShowVersion
)

Set-StrictMode -Version 3.0

$ScriptName = $MyInvocation.MyCommand.Name
$ScriptVersion = '1.0.0'

# Progress bars corrupt the output when an updater writes to the console
# while the script is also writing to it.
$ProgressPreference = 'SilentlyContinue'

$script:Succeeded = @()
$script:Failed = @()
$script:Skipped = @()
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
        $script:Succeeded += $Label
        Write-Info "$Label completed."
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

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$SuccessExitCodes = @(0),
        [switch]$Tolerate
    )

    Write-Info "Running: `"$FilePath`" $($Arguments -join ' ')"

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

function Get-PackageFolderVersion {
    param([Parameter(Mandatory = $true)][string]$Name)

    # A package folder is named Publisher.Package_1.22.3.0_x64__hash, and its
    # version must be compared as a version rather than as a string.
    $match = [regex]::Match($Name, '_(\d+(?:\.\d+){1,3})_')
    if (-not $match.Success) { return [version]'0.0' }

    return [version]$match.Groups[1].Value
}

function Get-WinGetPath {
    $onPath = Get-CommandPath -Names @('winget.exe')
    if ($onPath) { return $onPath }

    # WinGet is not always on the PATH of an elevated session, because the
    # App Execution Alias lives in the invoking user's profile.
    $alias = Join-ExistingPath -Root $env:LOCALAPPDATA -ChildPath 'Microsoft\WindowsApps\winget.exe'
    if ($alias) { return $alias }

    if (-not $env:ProgramFiles) { return $null }

    $packageRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsApps'
    $package = Get-ChildItem -Path $packageRoot -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' `
        -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { Get-PackageFolderVersion -Name $_.Name } } -Descending |
        Select-Object -First 1

    if ($package) { return (Join-ExistingPath -Root $package.FullName -ChildPath 'winget.exe') }

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
    $onPath = Get-CommandPath -Names @('choco.exe')
    if ($onPath) { return $onPath }

    return (Join-ExistingPath -Root $env:ChocolateyInstall -ChildPath 'bin\choco.exe')
}

function Get-PatchMyPCPath {
    if ($PatchMyPCPath) {
        if (Test-Path -LiteralPath $PatchMyPCPath -PathType Leaf) { return $PatchMyPCPath }
        Write-Warn "The path given by -PatchMyPCPath does not exist: $PatchMyPCPath"
        return $null
    }

    $onPath = Get-CommandPath -Names @('PatchMyPC.exe')
    if ($onPath) { return $onPath }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA)
    foreach ($root in $roots) {
        $candidate = Join-ExistingPath -Root $root -ChildPath 'Patch My PC\PatchMyPC.exe'
        if ($candidate) { return $candidate }
    }

    $candidate = Join-ExistingPath -Root $env:SystemDrive -ChildPath 'PatchMyPC\PatchMyPC.exe'
    if ($candidate) { return $candidate }

    $appPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PatchMyPC.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PatchMyPC.exe'
    )

    foreach ($appPath in $appPaths) {
        try {
            $entry = Get-ItemProperty -Path $appPath -ErrorAction Stop
            $registered = $entry.PSObject.Properties['(default)']
            if ($registered -and $registered.Value -and (Test-Path -LiteralPath $registered.Value -PathType Leaf)) {
                return $registered.Value
            }
        } catch {
            Write-Verbose "No App Paths entry at ${appPath}."
        }
    }

    return $null
}

function Update-WindowsUpdate {
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
    }

    try {
        if (Get-WURebootStatus -Silent -ErrorAction Stop) { $script:RebootRequired = $true }
    } catch {
        Write-Verbose "Unable to query the reboot status: $($_.Exception.Message)"
    }
}

function Update-WindowsUpdateWithComApi {
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $session.ClientApplicationID = 'update-everything'

    $criteria = 'IsInstalled=0 AND IsHidden=0'
    if (-not $IncludeDrivers) { $criteria += " AND Type='Software'" }

    Write-Info 'Searching for available updates...'
    $searchResult = $session.CreateUpdateSearcher().Search($criteria)

    if ($searchResult.Updates.Count -eq 0) {
        Write-Info 'No applicable Windows updates were found.'
        return
    }

    $selected = New-Object -ComObject 'Microsoft.Update.UpdateColl'

    foreach ($update in $searchResult.Updates) {
        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Warn "Skipping `"$($update.Title)`" because it requires user input."
            continue
        }

        if (-not $update.EulaAccepted) { $update.AcceptEula() }

        Write-Info "Selected: $($update.Title)"
        $null = $selected.Add($update)
    }

    if ($selected.Count -eq 0) {
        Write-Info 'Every available update requires user input, so none were installed.'
        return
    }

    Write-Info "Downloading $($selected.Count) update(s)..."
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $selected
    $null = $downloader.Download()

    $installable = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($update in $selected) {
        if ($update.IsDownloaded) {
            $null = $installable.Add($update)
        } else {
            Write-Warn "Skipping `"$($update.Title)`" because it did not download."
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

    # ResultCode: 2 succeeded, 3 succeeded with errors, 4 failed, 5 aborted.
    switch ($installResult.ResultCode) {
        2 { Write-Info 'All selected updates were installed.' }
        3 { Write-Warn 'The updates were installed, but one or more reported an error.' }
        default {
            $hresult = '0x{0:X8}' -f $installResult.HResult
            throw "Windows Update reported result code $($installResult.ResultCode) (HRESULT $hresult)."
        }
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
    if (-not $version -or $version -ge [version]'1.2') {
        $arguments += '--include-unknown'
    }

    if ($version -and $version -ge [version]'1.4') {
        $arguments += '--disable-interactivity'
    }

    Invoke-External -FilePath $Path -Arguments @('source', 'update') -Tolerate

    # 0x8A15002B is "no applicable upgrade found", which is a normal outcome.
    Invoke-External -FilePath $Path -Arguments $arguments -SuccessExitCodes @(0, -1978335189)
}

function Update-ChocolateyPackage {
    param([Parameter(Mandatory = $true)][string]$Path)

    # 1641 and 3010 mean a package installed successfully and wants a reboot.
    Invoke-External -FilePath $Path `
        -Arguments @('upgrade', 'all', '--yes', '--no-progress') `
        -SuccessExitCodes @(0, 1641, 3010)

    if ($script:LastExternalExitCode -in @(1641, 3010)) { $script:RebootRequired = $true }
}

function Update-ScoopPackage {
    param([Parameter(Mandatory = $true)][string]$Path)

    Invoke-External -FilePath $Path -Arguments @('update')
    Invoke-External -FilePath $Path -Arguments @('update', '*')

    if (-not $NoCleanup) {
        Invoke-External -FilePath $Path -Arguments @('cleanup', '*') -Tolerate
        Invoke-External -FilePath $Path -Arguments @('cache', 'rm', '*') -Tolerate
    }
}

function Update-PatchMyPCApplication {
    param([Parameter(Mandatory = $true)][string]$Path)

    # /auto updates every out-of-date application without showing the
    # selection interface, and closes the updater when it has finished.
    Write-Info "Running: `"$Path`" /auto"
    $process = Start-Process -FilePath $Path -ArgumentList '/auto' -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "PatchMyPC.exe exited with code $($process.ExitCode)."
    }
}

function Update-MicrosoftStoreApplication {
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
        Write-Info 'All detected updaters completed successfully.'
    }
}

function Invoke-SystemUpdate {
    param([Parameter(Mandatory = $true)][bool]$IsElevated)

    if ($SkipWindowsUpdate) {
        Add-SkippedItem -Label 'Windows Update' -Reason 'requested with -SkipWindowsUpdate'
        return
    }

    if (-not $IsElevated) {
        $script:Failed += 'Windows Update (administrator privileges are required)'
        Write-Fail 'Windows Update needs an elevated PowerShell session. Re-run this script as an administrator.'
        return
    }

    Invoke-Task -Label 'Windows Update' -Action { Update-WindowsUpdate }
}

function Invoke-ApplicationUpdate {
    param([Parameter(Mandatory = $true)][bool]$IsElevated)

    $wingetPath = Get-WinGetPath
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

    $patchMyPcPath = Get-PatchMyPCPath
    if ($patchMyPcPath) {
        Invoke-Task -Label 'Patch My PC applications' -Action { Update-PatchMyPCApplication -Path $patchMyPcPath }
    } else {
        Add-SkippedItem -Label 'Patch My PC Home Updater' -Reason 'not found, or pass -PatchMyPCPath to point at it'
    }

    $storeClass = Get-CimClass -Namespace 'Root\cimv2\mdm\dmmap' `
        -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction SilentlyContinue

    if ($storeClass) {
        Invoke-Task -Label 'Microsoft Store applications' -Action { Update-MicrosoftStoreApplication }
    } else {
        Add-SkippedItem -Label 'Microsoft Store' -Reason 'the application management class is not available'
    }
}

function Invoke-Main {
    if ($ShowVersion) {
        Write-Host "$ScriptName $ScriptVersion"
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Write-Fail 'This script supports Windows only.'
        $script:ExitCode = 2
        return
    }

    $operatingSystem = Get-OperatingSystemName
    $isElevated = Test-Administrator

    Write-Host "$ScriptName $ScriptVersion"
    Write-Info "Detected operating system: $operatingSystem"

    if ($isElevated) {
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

Invoke-Main
exit $script:ExitCode
