$script:IsWindowsHost = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)

Describe 'update-everything Windows updater' {
    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:UpdaterPath = Join-Path $script:RepositoryRoot 'windows\update-everything.ps1'
        $env:UPDATE_EVERYTHING_TESTING = '1'
        . $script:UpdaterPath
        if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
            function Get-AuthenticodeSignature { throw 'Windows-only command was not mocked.' }
        }
        if (-not (Get-Command Get-CimClass -ErrorAction SilentlyContinue)) {
            function Get-CimClass { throw 'Windows-only command was not mocked.' }
        }
        if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
            function Get-WindowsUpdate { throw 'PSWindowsUpdate command was not mocked.' }
        }
        if (-not (Get-Command Get-WURebootStatus -ErrorAction SilentlyContinue)) {
            function Get-WURebootStatus { throw 'PSWindowsUpdate command was not mocked.' }
        }
    }

    BeforeEach {
        $SystemOnly = $false
        $SkipWindowsUpdate = $false
        $IncludeDrivers = $false
        $NoCleanup = $false
        $PatchMyPCPath = $null
        $DryRun = $false
        $ShowVersion = $false
        $UnrecognisedArguments = @()
        $script:Succeeded = @()
        $script:Failed = @()
        $script:Skipped = @()
        $script:Planned = @()
        $script:RebootRequired = $false
        $script:LastExternalExitCode = 0
        $script:ExitCode = 0
    }

    It 'uses the consolidated repository version' {
        $ScriptVersion | Should -Be '2.1.0'
    }

    It 'rejects conflicting system modes with exit code 2' {
        $SystemOnly = $true
        $SkipWindowsUpdate = $true
        Invoke-Main
        $script:ExitCode | Should -Be 2
    }

    It 'accepts -SkipSystemUpdate as an alias of -SkipWindowsUpdate' {
        $parameter = (Get-Command -Name $script:UpdaterPath).Parameters['SkipWindowsUpdate']
        $parameter.Aliases | Should -Contain 'SkipSystemUpdate'
        $parameter.ParameterType | Should -Be ([switch])
    }

    It 'names the alias in the conflicting-mode error' {
        $SystemOnly = $true
        $SkipWindowsUpdate = $true
        $output = Invoke-Main 6>&1 | Out-String
        $output | Should -Match '-SkipSystemUpdate'
        $script:ExitCode | Should -Be 2
    }

    It 'isolates one updater failure from the next task' {
        Invoke-Task -Label 'broken' -Action { throw 'test failure' }
        Invoke-Task -Label 'working' -Action { return }
        $script:Failed.Count | Should -Be 1
        $script:Succeeded | Should -Contain 'working'
    }

    It 'returns exit code 1 when the summary contains failures' {
        Mock Test-PendingReboot { $false }
        $script:Failed = @('broken updater')
        Write-Summary -OperatingSystem 'Test Windows'
        $script:ExitCode | Should -Be 1
    }

    It 'keeps exit code 0 for a successful summary' {
        Mock Test-PendingReboot { $false }
        Write-Summary -OperatingSystem 'Test Windows'
        $script:ExitCode | Should -Be 0
    }

    It 'does not execute an external process during a dry run' {
        $DryRun = $true
        $output = Invoke-External -FilePath 'C:\Path With Spaces\missing.exe' `
            -Arguments @('argument;with punctuation') *>&1 | Out-String
        $output | Should -Match '\[DRY-RUN\]'
        $output | Should -Match 'Path With Spaces'
        $script:LastExternalExitCode | Should -Be 0
    }

    It 'interprets Windows Update result code 2 as success' {
        { Assert-WindowsUpdateResult -Result ([pscustomobject]@{ ResultCode = 2 }) -Operation 'test' } |
            Should -Not -Throw
    }

    It 'interprets Windows Update partial success as a failure' {
        $result = [pscustomobject]@{ ResultCode = 3; HResult = -1 }
        { Assert-WindowsUpdateResult -Result $result -Operation 'test' } |
            Should -Throw '*result code 3*'
    }

    It 'filters drivers by default and includes them only when requested' {
        $IncludeDrivers = $false
        Get-WindowsUpdateCriterion | Should -Match "Type='Software'"
        $IncludeDrivers = $true
        Get-WindowsUpdateCriterion | Should -Not -Match "Type='Software'"
    }

    It 'uses the COM search path for dry runs without loading PSWindowsUpdate' {
        $DryRun = $true
        Mock Update-WindowsUpdateWithComApi {}
        Mock Get-Module { [pscustomobject]@{ Version = [version]'2.2.1' } }
        Update-WindowsUpdate
        Should -Invoke Update-WindowsUpdateWithComApi -Times 1 -Exactly
        Should -Invoke Get-Module -Times 0 -Exactly
    }

    It 'marks non-terminating PSWindowsUpdate failed results as a failure' {
        Mock Import-Module {}
        Mock Get-WindowsUpdate {
            [pscustomobject]@{ Title = 'Failed update'; Result = 'Failed' }
        }
        Mock Get-WURebootStatus { $false }
        { Update-WindowsUpdateWithModule } | Should -Throw '*reported a failed*'
    }

    It 'sets reboot state for Chocolatey 1641 and 3010 success codes' -TestCases @(
        @{ ExitCode = 1641 }
        @{ ExitCode = 3010 }
    ) {
        param($ExitCode)
        Mock Invoke-External { $script:LastExternalExitCode = $ExitCode }
        Update-ChocolateyPackage -Path 'C:\Chocolatey\choco.exe'
        $script:RebootRequired | Should -BeTrue
    }

    It 'accepts only the exit codes Chocolatey documents as valid' {
        $accepted = $null
        Mock Invoke-External {
            param($FilePath, $Arguments, $SuccessExitCodes)
            $script:AcceptedExitCodes = $SuccessExitCodes
            $script:LastExternalExitCode = 0
        }
        Update-ChocolateyPackage -Path 'C:\Chocolatey\choco.exe'
        $accepted = $script:AcceptedExitCodes
        # 0, 1605, 1614, 1641 and 3010 are documented as valid; 350 and 1604 are
        # accepted only so the reboot can be reported before the task fails.
        $accepted | Should -Contain 0
        $accepted | Should -Contain 1605
        $accepted | Should -Contain 1614
        $accepted | Should -Contain 1641
        $accepted | Should -Contain 3010
        # Exit code 2 is not a documented Chocolatey success code and must not
        # be silently swallowed.
        $accepted | Should -Not -Contain 2
    }

    It 'reports Chocolatey pending-reboot code 350 as a failure requiring reboot' {
        Mock Invoke-External { $script:LastExternalExitCode = 350 }
        { Update-ChocolateyPackage -Path 'C:\Chocolatey\choco.exe' } |
            Should -Throw '*pending*'
        $script:RebootRequired | Should -BeTrue
    }

    It 'reports Chocolatey partial-run code 1604 as a failure requiring reboot' {
        Mock Invoke-External { $script:LastExternalExitCode = 1604 }
        { Update-ChocolateyPackage -Path 'C:\Chocolatey\choco.exe' } |
            Should -Throw '*part-way*'
        $script:RebootRequired | Should -BeTrue
    }

    It 'uses Patch My PC silent mode instead of the graphical automatic mode' {
        $DryRun = $true
        $output = Update-PatchMyPCApplication -Path 'C:\Tools With Spaces\PatchMyPC.exe' *>&1 |
            Out-String
        $output | Should -Match '/s'
        $output | Should -Not -Match '/auto'
    }

    It 'requires a valid Patch My PC publisher signature' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Patch My PC, LLC' }
            }
        }
        Test-PatchMyPCPublisher -Path 'C:\PatchMyPC.exe' | Should -BeTrue
    }

    It 'rejects a valid signature from a look-alike publisher' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Evil Patch My PC Tools, LLC' }
            }
        }
        Test-PatchMyPCPublisher -Path 'C:\PatchMyPC.exe' | Should -BeFalse
    }

    It 'rejects an explicitly supplied untrusted Patch My PC executable' {
        $PatchMyPCPath = 'C:\Users\Test User\Patch;MyPC.exe'
        Mock Test-Path { $true }
        Mock Test-PatchMyPCPublisher { $false }
        { Get-PatchMyPCPath } | Should -Throw '*valid Patch My PC*'
    }

    It 'accepts a signed explicit Patch My PC path containing punctuation' {
        $PatchMyPCPath = 'C:\Users\Test User\Patch;MyPC.exe'
        Mock Test-Path { $true }
        Mock Test-PatchMyPCPublisher { $true }
        Get-PatchMyPCPath | Should -BeExactly $PatchMyPCPath
    }

    It 'does not trust PATH or a per-user WinGet alias when elevated' {
        Mock Get-CommandPath { throw 'PATH must not be queried' }
        Mock Get-ProgramFilesRoot { @() }
        Get-WinGetPath -IsElevated $true | Should -BeNullOrEmpty
        Should -Invoke Get-CommandPath -Times 0 -Exactly
    }

    It 'includes both 64-bit and 32-bit Program Files roots without duplicates' {
        $env:ProgramW6432 = 'C:\Program Files'
        $env:ProgramFiles = 'C:\Program Files'
        ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'
        (@(Get-ProgramFilesRoot) -join '|') | Should -Be 'C:\Program Files|C:\Program Files (x86)'
    }

    It 'selects the newest App Installer package that actually contains WinGet' {
        $programFiles = Join-Path $TestDrive 'Program Files'
        $missingPackage = Join-Path $programFiles 'WindowsApps\missing-newest'
        $workingPackage = Join-Path $programFiles 'WindowsApps\working'
        $expectedPath = Join-Path $workingPackage 'winget.exe'
        Mock Get-ProgramFilesRoot { $programFiles }
        Mock Get-ChildItem {
            @(
                [pscustomobject]@{
                    Name = 'Microsoft.DesktopAppInstaller_3.0.0.0_x86__8wekyb3d8bbwe'
                    FullName = $missingPackage
                },
                [pscustomobject]@{
                    Name = 'Microsoft.DesktopAppInstaller_2.0.0.0_x64__8wekyb3d8bbwe'
                    FullName = $workingPackage
                }
            )
        }
        Mock Join-ExistingPath {
            param($Root, $ChildPath)
            if ($Root -eq $workingPackage -and $ChildPath -eq 'winget.exe') {
                return $expectedPath
            }
            return $null
        }
        Get-WinGetPath -IsElevated $true | Should -Be $expectedPath
    }

    It 'omits unsupported WinGet flags when the version cannot be determined' {
        $DryRun = $true
        Mock Get-WinGetVersion { $null }
        $output = Update-WinGetPackage -Path 'C:\winget.exe' *>&1 | Out-String
        $output | Should -Not -Match ([regex]::Escape('--include-unknown'))
        $output | Should -Not -Match ([regex]::Escape('--disable-interactivity'))
    }

    It 'uses supported WinGet noninteractive flags for version 1.4' {
        $DryRun = $true
        Mock Get-WinGetVersion { [version]'1.4' }
        $output = Update-WinGetPackage -Path 'C:\winget.exe' *>&1 | Out-String
        $output | Should -Match ([regex]::Escape('--include-unknown'))
        $output | Should -Match ([regex]::Escape('--disable-interactivity'))
    }

    It 'still attempts WinGet upgrades but reports a failed source refresh' {
        Mock Get-WinGetVersion { [version]'1.4' }
        Mock Invoke-External {
            param($FilePath, $Arguments)
            if ($Arguments[0] -eq 'source') {
                $script:LastExternalExitCode = 5
            } else {
                $script:LastExternalExitCode = 0
            }
        }
        { Update-WinGetPackage -Path 'C:\winget.exe' } | Should -Throw '*source update exited with code 5*'
        Should -Invoke Invoke-External -Times 2 -Exactly
    }

    It 'honours the Scoop cleanup switch' {
        $DryRun = $true
        $NoCleanup = $true
        $output = Update-ScoopPackage -Path 'C:\Users\Test User\scoop.cmd' *>&1 | Out-String
        $output | Should -Not -Match 'cleanup'
        $output | Should -Not -Match 'cache rm'

        $NoCleanup = $false
        $output = Update-ScoopPackage -Path 'C:\Users\Test User\scoop.cmd' *>&1 | Out-String
        $output | Should -Match 'cleanup'
        $output | Should -Match 'cache rm'
    }

    It 'attempts both Scoop cleanups and reports partial cleanup failure' {
        Mock Invoke-External {
            param($FilePath, $Arguments)
            if ($Arguments[0] -in @('cleanup', 'cache')) { throw 'cleanup failed' }
        }
        { Update-ScoopPackage -Path 'C:\scoop.cmd' } | Should -Throw '*2 cleanup operation*'
        Should -Invoke Invoke-External -Times 4 -Exactly
    }

    It 'skips Scoop in an elevated session' {
        Mock Get-WinGetPath { $null }
        Mock Get-ChocolateyPath { $null }
        Mock Get-CommandPath { 'C:\Users\Test User\scoop.cmd' }
        Mock Get-PatchMyPCPath { $null }
        Mock Get-CimClass { $null }
        Invoke-ApplicationUpdate -IsElevated $true
        ($script:Skipped -join "`n") | Should -Match 'Scoop.*must be updated.*not elevated'
    }

    It 'skips the Microsoft Store scan in a session that is not elevated' {
        Mock Get-WinGetPath { $null }
        Mock Get-ChocolateyPath { $null }
        Mock Get-CommandPath { $null }
        Mock Get-PatchMyPCPath { $null }
        Mock Get-CimClass { [pscustomobject]@{ CimClassName = 'MDM_EnterpriseModernAppManagement_AppManagement01' } }
        Mock Update-MicrosoftStoreApplication { throw 'the scan must not be attempted' }
        Invoke-ApplicationUpdate -IsElevated $false
        ($script:Skipped -join "`n") | Should -Match 'Microsoft Store.*elevated'
        $script:Failed.Count | Should -Be 0
        Should -Invoke Update-MicrosoftStoreApplication -Times 0 -Exactly
    }

    It 'runs the Microsoft Store scan in an elevated session' {
        Mock Get-WinGetPath { $null }
        Mock Get-ChocolateyPath { $null }
        Mock Get-CommandPath { $null }
        Mock Get-PatchMyPCPath { $null }
        Mock Get-CimClass { [pscustomobject]@{ CimClassName = 'MDM_EnterpriseModernAppManagement_AppManagement01' } }
        Mock Update-MicrosoftStoreApplication {}
        Invoke-ApplicationUpdate -IsElevated $true
        Should -Invoke Update-MicrosoftStoreApplication -Times 1 -Exactly
        $script:Succeeded | Should -Contain 'Microsoft Store update scan'
    }

    It 'records Windows Update as failed when the session is not elevated' {
        Mock Invoke-Task { throw 'Windows Update must not be attempted' }
        Invoke-SystemUpdate -IsElevated $false
        ($script:Failed -join "`n") | Should -Match 'Windows Update.*administrator'
        Should -Invoke Invoke-Task -Times 0 -Exactly
    }

    It 'reports an unrecognised option with exit code 2' {
        $UnrecognisedArguments = @('-DefinitelyInvalid')
        Invoke-Main
        $script:ExitCode | Should -Be 2
    }

    It 'continues to Microsoft Store detection after Patch My PC discovery fails' {
        Mock Get-WinGetPath { $null }
        Mock Get-ChocolateyPath { $null }
        Mock Get-CommandPath { $null }
        Mock Get-PatchMyPCPath { throw 'bad signature' }
        Mock Get-CimClass { $null }
        Invoke-ApplicationUpdate -IsElevated $false
        ($script:Failed -join "`n") | Should -Match 'Patch My PC.*bad signature'
        ($script:Skipped -join "`n") | Should -Match 'Microsoft Store'
    }

    Context 'start-up banner' {
        BeforeEach {
            $script:BannerText = New-Object System.Text.StringBuilder
            Mock Write-Host {
                [void]$script:BannerText.Append([string]$Object)
                if (-not $NoNewline) { [void]$script:BannerText.Append("`n") }
            }
            Mock Get-ConsoleWidth { 100 }
        }

        It 'draws the full logo with the name, tagline and subtitle aligned' {
            Mock Get-BannerColorMode { 'None' }
            Show-Banner -Subtitle 'Windows 11 Pro 23H2 - dry run'
            $bar = [string][char]0x2502
            $text = $script:BannerText.ToString()
            $lines = $text -split "`n"
            $text | Should -BeLikeExactly "*$bar Update Everything 2.0.0*"
            $text | Should -BeLikeExactly "*$bar Everything, carefully.*"
            $text | Should -BeLikeExactly "*$bar Windows 11 Pro 23H2 - dry run*"
            $lines.Count | Should -Be 24
            $columns = @($lines | Where-Object { $_.Contains($bar) } | ForEach-Object { $_.IndexOf($bar) } | Sort-Object -Unique)
            $columns | Should -Be @(43)
            $lines[0] | Should -BeExactly ((' ' * 18) + '%')
            $lines[18] | Should -BeExactly '      @@@@%%%%@@@@@@=@@@@@@@@@@@@@'
            $text | Should -Not -Match ([regex]::Escape([string][char]27))
        }

        It 'shortens a subtitle that would wrap' {
            Mock Get-BannerColorMode { 'None' }
            Mock Get-ConsoleWidth { 72 }
            Show-Banner -Subtitle 'Windows 11 Pro 23H2 (build 22631) - dry run'
            $lines = $script:BannerText.ToString() -split "`n"
            $script:BannerText.ToString() | Should -BeLikeExactly '*Windows 11 Pro 23H2 (bu...*'
            @($lines | Where-Object { $_.Length -gt 71 }).Count | Should -Be 0
        }

        It 'shortens a long subtitle in the compact form too' {
            Mock Get-BannerColorMode { 'None' }
            Mock Get-ConsoleWidth { 40 }
            Show-Banner -Subtitle 'Windows 11 Pro 23H2 (build 22631) - dry run'
            $lines = $script:BannerText.ToString() -split "`n"
            $lines[2] | Should -BeExactly '  Windows 11 Pro 23H2 (build 22631) ...'
            $lines[2].Length | Should -Be 39
        }

        It 'prints the compact form in a console narrower than 72 columns' {
            Mock Get-BannerColorMode { 'None' }
            Mock Get-ConsoleWidth { 71 }
            Show-Banner -Subtitle 'Windows 11'
            $expected = ([string][char]0x25CF) + " Update Everything 2.0.0`n  Everything, carefully.`n  Windows 11`n`n"
            $script:BannerText.ToString() | Should -BeExactly $expected
        }

        It 'turns colour off when NO_COLOR is set' {
            $previous = $env:NO_COLOR
            try {
                $env:NO_COLOR = '1'
                Get-BannerColorMode | Should -Be 'None'
            } finally {
                $env:NO_COLOR = $previous
            }
        }

        It 'uses the brand colours as 24-bit escape sequences on a virtual-terminal console' {
            Mock Get-BannerColorMode { 'None' }
            Show-Banner -Subtitle 'Windows 11'
            $plain = $script:BannerText.ToString()

            $script:BannerText = New-Object System.Text.StringBuilder
            Mock Get-BannerColorMode { 'Ansi' }
            Show-Banner -Subtitle 'Windows 11'
            $coloured = $script:BannerText.ToString()
            $escape = [string][char]27
            $coloured.Contains($escape + '[1;38;2;34;197;94mUpdate Everything' + $escape + '[0m') | Should -BeTrue
            $coloured.Contains($escape + '[38;2;96;165;250m') | Should -BeTrue
            ($coloured -replace "$escape\[[0-9;]*m", '') | Should -BeExactly $plain
        }

        It 'falls back to console colours elsewhere' {
            Mock Get-BannerColorMode { 'Console' }
            Show-Banner
            Should -Invoke Write-Host -ParameterFilter { $ForegroundColor -eq 'Green' -and $Object -eq 'Update Everything' }
            Should -Invoke Write-Host -ParameterFilter { $ForegroundColor -eq 'DarkCyan' }
            $script:BannerText.ToString() | Should -Not -Match ([regex]::Escape([string][char]27))
        }

    It 'names the operating system and dry-run mode in the run banner' -Skip:(-not $script:IsWindowsHost) {
            $DryRun = $true
            Mock Show-Banner {}
            Mock Get-OperatingSystemName { 'Windows 11 Pro 23H2' }
            Mock Test-Administrator { $false }
            Mock Invoke-SystemUpdate {}
            Mock Invoke-ApplicationUpdate {}
            Mock Write-Summary {}
            Invoke-Main
            Should -Invoke Show-Banner -Times 1 -Exactly -ParameterFilter { $Subtitle -eq 'Windows 11 Pro 23H2 - dry run' }
        }
    }
}

Describe 'PowerShell command-line parsing' {
    BeforeAll {
        $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:UpdaterPath = Join-Path $script:RepositoryRoot 'windows\update-everything.ps1'
    }

    BeforeEach {
        Remove-Item Env:UPDATE_EVERYTHING_TESTING -ErrorAction SilentlyContinue
    }

    AfterEach {
        $env:UPDATE_EVERYTHING_TESTING = '1'
    }

    It 'prints version without running updates' -Skip:(-not $script:IsWindowsHost) {
        & powershell.exe -NoLogo -NoProfile -File $script:UpdaterPath -Version
        $LASTEXITCODE | Should -Be 0
    }

    It 'shows standard help without running updates' -Skip:(-not $script:IsWindowsHost) {
        & powershell.exe -NoLogo -NoProfile -File $script:UpdaterPath '-?'
        $LASTEXITCODE | Should -Be 0
    }

    It 'returns 2 for conflicting options' -Skip:(-not $script:IsWindowsHost) {
        & powershell.exe -NoLogo -NoProfile -File $script:UpdaterPath -SystemOnly -SkipWindowsUpdate
        $LASTEXITCODE | Should -Be 2
    }

    It 'returns 2 for conflicting options given through the alias' -Skip:(-not $script:IsWindowsHost) {
        & powershell.exe -NoLogo -NoProfile -File $script:UpdaterPath -SystemOnly -SkipSystemUpdate
        $LASTEXITCODE | Should -Be 2
    }

    It 'rejects an unknown option with exit code 2' -Skip:(-not $script:IsWindowsHost) {
        & powershell.exe -NoLogo -NoProfile -File $script:UpdaterPath -DefinitelyInvalid
        $LASTEXITCODE | Should -Be 2
    }
}
